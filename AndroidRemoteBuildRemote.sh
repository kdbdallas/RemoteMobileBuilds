#!/usr/bin/env bash
# Executed on the Android build Mac by XcodeRemoteBuild.sh for Android builds.

set -u

usage() {
  cat <<'EOF'
Usage: AndroidRemoteBuildRemote.sh --repo <repository-name> --branch <branch> --shortCode <short-code> --buildType <Release|Debug|BrowserStack|Play Store> --buildPackage <APK|Bundle> [options]

Options:
  --type <account-type>       Repository subdirectory under ~/Code.
  --features <flags>          Space-separated Gradle -P values (without -P).
  --devApis <true|false>      BrowserStack development APIs setting.
  --bundleId <id>             Play Store application ID to publish.
EOF
}

failure() {
  printf 'FAILURE: %s\n' "$1" >&2
  exit 1
}

# Exit status 3 means the result was delivered but the checkout was not reset.
# XcodeRemoteBuild.sh and the Shortcut report it separately from a failure, so
# that nobody repeats a run that already published or uploaded a build.
delivered_but_not_reset() {
  printf 'WARNING: %s, but the remote repository could not be fully reset. It does not need to run again.\n' "$1" >&2
  exit 3
}

# XcodeRemoteBuild.sh exports these from config.sh ahead of this script.
for config_name in RMB_BUILDS_HOST RMB_BUILDS_DIR RMB_ANDROID_PROJECT_DIR; do
  [[ -n "${!config_name:-}" ]] || failure "$config_name is not set; run this through XcodeRemoteBuild.sh with config.sh filled in"
done

is_path_segment() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$1" != "." && "$1" != ".." ]]
}

configure_java() {
  local candidate registered_java_home java_version

  use_supported_java() {
    candidate="$1"
    [[ -x "$candidate/bin/java" ]] || return 1
    java_version="$("$candidate/bin/java" -version 2>&1 | head -n 1)"
    [[ "$java_version" == *'version "17.'* || "$java_version" == *'version "17"'* || "$java_version" == *'version "21.'* || "$java_version" == *'version "21"'* ]] || return 1
    export JAVA_HOME="$candidate"
    export PATH="$JAVA_HOME/bin:$PATH"
    return 0
  }

  # SSH starts a non-interactive shell, so it does not receive the Java setup
  # that Android Studio or a user's shell profile normally supplies.
  if [[ -n "${JAVA_HOME:-}" ]] && use_supported_java "$JAVA_HOME"; then
    return 0
  fi

  # This project's Gradle wrapper does not support the installed Java 25.
  # Use Java 17 or 21, which are compatible Android build JDKs. Do not fall
  # back to macOS's default JDK.
  registered_java_home="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
  if [[ -n "$registered_java_home" ]] && use_supported_java "$registered_java_home"; then
    return 0
  fi
  registered_java_home="$(/usr/libexec/java_home -v 21 2>/dev/null || true)"
  if [[ -n "$registered_java_home" ]] && use_supported_java "$registered_java_home"; then
    return 0
  fi

  for candidate in \
    '/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
    /opt/homebrew/opt/openjdk@21 \
    /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
    /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
    "$HOME"/.jenv/versions/17*/Contents/Home \
    "$HOME"/.jenv/versions/21*/Contents/Home \
    "$HOME"/.sdkman/candidates/java/17* \
    "$HOME"/.sdkman/candidates/java/21*; do
    use_supported_java "$candidate" && return 0
  done

  return 1
}

configure_android_sdk() {
  local candidate

  # local.properties may not exist on the build Mac. Set the SDK path
  # explicitly so both builds and tests work in an SSH session.
  for candidate in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk"; do
    [[ -n "$candidate" && -d "$candidate/platforms" ]] || continue
    export ANDROID_HOME="$candidate"
    export ANDROID_SDK_ROOT="$candidate"
    export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
    return 0
  done
  return 1
}

repo=""
account_type=""
branch=""
short_code=""
build_type=""
build_package=""
bundle_id=""
dev_apis=""
features=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) [[ $# -ge 2 ]] || failure "--type requires a value"; account_type="$2"; shift 2 ;;
    --repo) [[ $# -ge 2 ]] || failure "--repo requires a value"; repo="$2"; shift 2 ;;
    --branch) [[ $# -ge 2 ]] || failure "--branch requires a value"; branch="$2"; shift 2 ;;
    --shortCode) [[ $# -ge 2 ]] || failure "--shortCode requires a value"; short_code="$2"; shift 2 ;;
    --buildType) [[ $# -ge 2 ]] || failure "--buildType requires a value"; build_type="$2"; shift 2 ;;
    --buildPackage) [[ $# -ge 2 ]] || failure "--buildPackage requires a value"; build_package="$2"; shift 2 ;;
    --bundleId) [[ $# -ge 2 ]] || failure "--bundleId requires a value"; bundle_id="$2"; shift 2 ;;
    --devApis) [[ $# -ge 2 ]] || failure "--devApis requires a value"; dev_apis="$2"; shift 2 ;;
    --features) [[ $# -ge 2 ]] || failure "--features requires a value"; features="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) failure "Unknown argument: $1" ;;
  esac
done

[[ -n "$repo" ]] || failure "--repo is required"
[[ -n "$branch" ]] || failure "--branch is required"
[[ -n "$short_code" ]] || failure "--shortCode is required"
[[ "$short_code" =~ ^[A-Za-z0-9_-]+$ ]] || failure "--shortCode may only contain letters, numbers, underscores, and hyphens"
[[ "$build_type" == "Release" || "$build_type" == "Debug" || "$build_type" == "BrowserStack" || "$build_type" == "Play Store" ]] || failure "--buildType must be Release, Debug, BrowserStack, or Play Store"
[[ "$build_package" == "APK" || "$build_package" == "Bundle" ]] || failure "--buildPackage must be APK or Bundle"
if [[ "$build_type" == "Play Store" ]]; then
  [[ "$build_package" == "Bundle" ]] || failure "Play Store builds require --buildPackage Bundle"
  [[ "$bundle_id" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]] || failure "--bundleId must be a valid Android application ID"
  [[ -n "${GOOGLE_PLAY_SERVICE_ACCOUNT_JSON:-}" ]] || failure "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON is not set for Play Store publishing"
fi
[[ -z "$dev_apis" || "$dev_apis" == "true" || "$dev_apis" == "false" ]] || failure "--devApis must be true or false"
is_path_segment "$repo" || failure "--repo must be a single directory name"
[[ -z "$account_type" ]] || is_path_segment "$account_type" || failure "--type must be a single directory name"
[[ "$branch" != -* ]] || failure "--branch must not begin with a dash"

repo_path="$HOME/Code"
[[ -z "$account_type" ]] || repo_path="$repo_path/$account_type"
repo_path="$repo_path/$repo"
project_path="$repo_path/$RMB_ANDROID_PROJECT_DIR"
[[ -d "$repo_path" ]] || failure "Could not find repository: $repo_path"
# The project is checked after checkout, not here: it belongs to the requested
# branch, and whatever an earlier run left behind must not block this one.

# local.properties is deliberately ignored and holds machine-local paths such
# as KEYSTORE_DIR. Keep a copy outside the checkout so the required cleans can
# still remove every generated build artifact. The copy is deleted once it has
# been restored, so finding one here with no local.properties means an earlier
# run was interrupted or could not restore it, and this run finishes that job.
local_properties_path="$project_path/local.properties"
local_properties_backup="$HOME/.remote-mobile-builds/${account_type:+$account_type/}$repo/local.properties"
(umask 077 && mkdir -p "$(dirname "$local_properties_backup")") || failure "Could not create the local.properties backup folder"
if [[ -f "$local_properties_path" ]]; then
  (umask 077 && cp "$local_properties_path" "$local_properties_backup") || failure "Could not back up local.properties"
elif [[ -f "$local_properties_backup" ]]; then
  printf '=== Recovering local.properties saved by an earlier run ===\n'
fi
restore_local_properties() {
  [[ ! -f "$local_properties_backup" ]] || cp "$local_properties_backup" "$local_properties_path"
}

cd "$repo_path" || failure "Could not enter repository: $repo_path"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || failure "Repository is not a Git work tree: $repo_path"
git check-ref-format --branch "$branch" >/dev/null 2>&1 || failure "Invalid branch name: $branch"

# From this point onward, return the remote checkout to a clean state on both
# successful and failed builds. This mirrors the iOS remote runner and removes
# Gradle outputs as well as any other generated, ignored files.
cleanup_done=0
cleanup_status=0
cleanup_repo() {
  [[ $cleanup_done -eq 0 ]] || return
  # A signal here would otherwise exit partway through, and the EXIT trap could
  # not finish the job because cleanup_done is already set.
  trap '' HUP INT TERM
  cleanup_done=1
  printf '\n=== Resetting remote repository ===\n'
  # The run usually ends inside the Android project, and `git clean` covers only
  # the current directory, so name the repository root explicitly.
  git -C "$repo_path" reset --hard || cleanup_status=1
  git -C "$repo_path" clean -ffdx || cleanup_status=1
  if [[ -f "$local_properties_backup" ]]; then
    if restore_local_properties; then
      rm -f "$local_properties_backup"
    else
      cleanup_status=1
      printf 'Could not restore local.properties; the copy at %s stays there and the next run will restore it\n' "$local_properties_backup" >&2
    fi
  fi
}
trap cleanup_repo EXIT
trap 'exit 130' HUP INT TERM

printf '=== Preparing remote repository ===\n'
git reset --hard || failure "Could not reset remote repository before checkout"
git clean -ffdx || failure "Could not clean remote repository before checkout"
printf '=== Checking out branch: %s ===\n' "$branch"
git fetch origin "+refs/heads/$branch:refs/remotes/origin/$branch" || failure "Could not fetch branch from origin: $branch"
git checkout -B "$branch" "origin/$branch" || failure "Could not check out branch: $branch"
cd "$project_path" || failure "Could not enter Android project: $project_path"
restore_local_properties || failure "Could not restore local.properties"
[[ -x ./gradlew ]] || failure "Could not find executable Gradle wrapper: $project_path/gradlew"
configure_java || failure "Could not find a Java runtime on the remote Mac"
printf '=== Using Java: %s ===\n' "$JAVA_HOME"
configure_android_sdk || failure "Could not find the Android SDK on the remote Mac"
printf '=== Using Android SDK: %s ===\n' "$ANDROID_HOME"

if [[ "$build_type" == "BrowserStack" ]]; then
  # BrowserStack must build the flavor requested in the Shortcut, not the
  # configured default flavor (which is commonly CONTAINER).
  gradle_command=( ./gradlew "assemble${short_code}Debug" -Pbrowserstack=true )
  artifact_extension="apk"
elif [[ "$build_type" == "Play Store" ]]; then
  gradle_command=( "./gradlew" "bundle${short_code}Release" )
  artifact_extension="aab"
else
  artifact_extension="apk"
  if [[ "$build_package" == "APK" ]]; then
    gradle_command=( "./gradlew" "assemble${short_code}${build_type}" )
  else
    gradle_command=( "./gradlew" "bundle${short_code}${build_type}" )
    artifact_extension="aab"
  fi
fi

if [[ "$build_type" == "BrowserStack" ]]; then
  # Preserve either explicit selection in the Gradle invocation.
  gradle_command+=( "-PAPI_DEV_ENABLED=${dev_apis:-false}" )
fi
# A blank value gives an empty array, and expanding one is an error under
# `set -u` in the Bash 3.2 that ships with macOS.
read -r -a feature_arguments <<< "$features"
if [[ ${#feature_arguments[@]} -gt 0 ]]; then
  for feature_argument in "${feature_arguments[@]}"; do
    [[ "$feature_argument" != -P* ]] || failure "Other Feature Flags should not include -P"
    gradle_command+=( "-P$feature_argument" )
  done
fi

printf '\n=== Running Android build ===\nCommand:'
printf ' %q' "${gradle_command[@]}"
printf '\n'
gradle_log="$(mktemp -t remote-mobile-gradle)" || failure "Could not create Gradle log"
"${gradle_command[@]}" 2>&1 | tee "$gradle_log"
gradle_status=${PIPESTATUS[0]}
if [[ $gradle_status -ne 0 ]]; then
  # The Shortcut shows only the final twelve lines. Clean the checkout first,
  # then emit the actionable Gradle block so it remains visible in that alert.
  cleanup_repo
  trap - EXIT HUP INT TERM
  printf '\n=== Gradle failure summary ===\n' >&2
  gradle_summary="$(awk '
    /^\* What went wrong:/ { printing = 1 }
    printing { print }
    printing && /^\* Try:/ { exit }
  ' "$gradle_log")"
  if [[ -z "$gradle_summary" ]]; then
    gradle_summary="$(grep -Ei 'execution failed for task|^> |^e: |error:|caused by:|could not resolve|a problem occurred' "$gradle_log" | tail -n 12 || true)"
  fi
  [[ -n "$gradle_summary" ]] || gradle_summary="$(tail -n 12 "$gradle_log")"
  printf '%s\n' "$gradle_summary" >&2
  rm -f "$gradle_log"
  failure "Gradle build failed"
fi
rm -f "$gradle_log"

artifact_path=""
artifact_mtime=-1
while IFS= read -r candidate; do
  # Do not pick an artifact this runner already renamed during a prior run.
  [[ "$(basename "$candidate")" != *"-$short_code.$artifact_extension" ]] || continue
  # Gradle variants normally include the short code in their output path. This
  # also avoids selecting a build from a different flavor.
  [[ "$candidate" == *"$short_code"* ]] || continue
  candidate_mtime="$(stat -f %m "$candidate" 2>/dev/null || true)"
  [[ "$candidate_mtime" =~ ^[0-9]+$ ]] || continue
  if (( candidate_mtime > artifact_mtime )); then
    artifact_path="$candidate"
    artifact_mtime=$candidate_mtime
  fi
done < <(find app/build/outputs -type f -name "*.${artifact_extension}" -print 2>/dev/null)
[[ -n "$artifact_path" ]] || failure "Could not find a ${short_code} .${artifact_extension} build artifact"
printf '=== Using build artifact: %s ===\n' "$artifact_path"

ticket="${branch##*/}"
if [[ "$branch" =~ (CM-[0-9]+) ]]; then
  ticket="${BASH_REMATCH[1]}"
fi
renamed_artifact_path="$(dirname "$artifact_path")/$ticket-$short_code.$artifact_extension"
if [[ "$artifact_path" != "$renamed_artifact_path" ]]; then
  mv -f "$artifact_path" "$renamed_artifact_path" || failure "Could not rename build artifact"
fi

if [[ "$build_type" == "BrowserStack" ]]; then
  [[ -f "$HOME/Code/BrowserStackAuth" ]] || failure "Could not find BrowserStack access-key file: $HOME/Code/BrowserStackAuth"
  access_key="$(<"$HOME/Code/BrowserStackAuth")"
  [[ -n "$access_key" ]] || failure "BrowserStack access-key file is empty"
  printf '\n=== Uploading %s to BrowserStack ===\n' "$(basename "$renamed_artifact_path")"
  curl --fail --show-error -u "$access_key" -X POST \
    'https://api-cloud.browserstack.com/app-live/upload' \
    -F "file=@$renamed_artifact_path" || failure "Could not upload build to BrowserStack"
  success_message="Uploaded to BrowserStack"
elif [[ "$build_type" == "Play Store" ]]; then
  release_tool="tools/play_release.py"
  [[ -f "$repo_path/$release_tool" ]] || failure "Could not find Play Store release tool: $repo_path/$release_tool"
  absolute_artifact_path="$project_path/$renamed_artifact_path"
  play_release_command=( python3 "$release_tool" --package-name "$bundle_id" --bundle "$absolute_artifact_path" --track production --status auto --confirm-production )
  printf '\n=== Publishing %s to Google Play ===\nCommand:' "$(basename "$renamed_artifact_path")"
  printf ' %q' "${play_release_command[@]}"
  printf '\n'
  play_release_output="$(cd "$repo_path" && "${play_release_command[@]}" 2>&1)"
  play_release_status=$?
  printf '%s\n' "$play_release_output"
  if [[ $play_release_status -ne 0 ]]; then
    # Cleanup emits several lines after the publisher's response, which would
    # otherwise hide the API error from the Shortcut's 12-line failure alert.
    cleanup_repo
    trap - EXIT HUP INT TERM
    printf '\n=== Google Play publishing failure ===\n%s\n' "$play_release_output" >&2
    failure "Google Play publishing failed"
  fi
  printf 'PLAY_STORE_RESULT: %s\n' "$play_release_output"
  success_message="Published to Play Store"
else
  printf '\n=== Saving %s to the build folder ===\n' "$(basename "$renamed_artifact_path")"
  scp "$renamed_artifact_path" "$RMB_BUILDS_HOST:$RMB_BUILDS_DIR/" || failure "Could not copy build to $RMB_BUILDS_HOST"
  success_message="Saved to Build Folder"
fi

cleanup_repo
trap - EXIT HUP INT TERM
[[ $cleanup_status -eq 0 ]] || delivered_but_not_reset "$success_message"
printf 'SUCCESS: %s\n' "$success_message"
