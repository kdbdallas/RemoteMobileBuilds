#!/usr/bin/env bash
# Executed on the Android build Mac by XcodeRemoteBuild.sh for Android builds.

set -u

usage() {
  cat <<'EOF'
Usage: AndroidRemoteBuildRemote.sh --repo <repository-name> --branch <branch> --shortCode <short-code> --buildType <Release|Debug|BrowserStack> --buildPackage <APK|Bundle> [options]

Options:
  --type <account-type>       Repository subdirectory under ~/Code.
  --features <flags>          Space-separated Gradle -P values (without -P).
  --devApis <true|false>      BrowserStack development APIs setting.
EOF
}

failure() {
  printf 'FAILURE: %s\n' "$1" >&2
  exit 1
}

# XcodeRemoteBuild.sh exports these from config.sh ahead of this script.
for config_name in RMB_BUILDS_HOST RMB_BUILDS_DIR; do
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

repo=""
account_type=""
branch=""
short_code=""
build_type=""
build_package=""
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
[[ "$build_type" == "Release" || "$build_type" == "Debug" || "$build_type" == "BrowserStack" ]] || failure "--buildType must be Release, Debug, or BrowserStack"
[[ "$build_package" == "APK" || "$build_package" == "Bundle" ]] || failure "--buildPackage must be APK or Bundle"
[[ -z "$dev_apis" || "$dev_apis" == "true" || "$dev_apis" == "false" ]] || failure "--devApis must be true or false"
is_path_segment "$repo" || failure "--repo must be a single directory name"
[[ -z "$account_type" ]] || is_path_segment "$account_type" || failure "--type must be a single directory name"
[[ "$branch" != -* ]] || failure "--branch must not begin with a dash"

repo_path="$HOME/Code"
[[ -z "$account_type" ]] || repo_path="$repo_path/$account_type"
repo_path="$repo_path/$repo"
project_path="$repo_path/ShowCase"
[[ -d "$repo_path" ]] || failure "Could not find repository: $repo_path"
[[ -d "$project_path" ]] || failure "Could not find Android project: $project_path"

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
  cleanup_done=1
  printf '\n=== Resetting remote repository ===\n'
  git reset --hard || cleanup_status=1
  git clean -ffdx || cleanup_status=1
}
trap cleanup_repo EXIT
trap 'exit 130' HUP INT TERM

printf '=== Checking out branch: %s ===\n' "$branch"
git checkout "$branch" || failure "Could not check out branch: $branch"
cd "$project_path" || failure "Could not enter Android project: $project_path"
[[ -x ./gradlew ]] || failure "Could not find executable Gradle wrapper: $project_path/gradlew"
configure_java || failure "Could not find a Java runtime on the remote Mac"
printf '=== Using Java: %s ===\n' "$JAVA_HOME"

if [[ "$build_type" == "BrowserStack" ]]; then
  gradle_command=( ./gradlew assembleCONTAINERDebug -Pbrowserstack=true )
  artifact_extension="apk"
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
if [[ -n "$features" ]]; then
  read -r -a feature_arguments <<< "$features"
  for feature_argument in "${feature_arguments[@]}"; do
    [[ "$feature_argument" != -P* ]] || failure "Other Feature Flags should not include -P"
    gradle_command+=( "-P$feature_argument" )
  done
fi

printf '\n=== Running Android build ===\nCommand:'
printf ' %q' "${gradle_command[@]}"
printf '\n'
"${gradle_command[@]}" || failure "Gradle build failed"

artifact_path=""
artifact_mtime=-1
while IFS= read -r candidate; do
  # Do not pick an artifact this runner already renamed during a prior run.
  [[ "$(basename "$candidate")" != *"-$short_code.$artifact_extension" ]] || continue
  # Gradle variants normally include the short code in their output path. This
  # also avoids selecting a build from a different flavor.
  [[ "$candidate" == *"$short_code"* || "$build_type" == "BrowserStack" ]] || continue
  candidate_mtime="$(stat -f %m "$candidate" 2>/dev/null || true)"
  [[ "$candidate_mtime" =~ ^[0-9]+$ ]] || continue
  if (( candidate_mtime > artifact_mtime )); then
    artifact_path="$candidate"
    artifact_mtime=$candidate_mtime
  fi
done < <(find app/build/outputs -type f -name "*.${artifact_extension}" -print 2>/dev/null)
[[ -n "$artifact_path" ]] || failure "Could not find a ${short_code} .${artifact_extension} build artifact"
printf '=== Using build artifact: %s ===\n' "$artifact_path"

if [[ "$branch" =~ (CM-[0-9]+) ]]; then
  ticket="${BASH_REMATCH[1]}"
else
  ticket="${branch//\//-}"
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
  printf 'SUCCESS: Uploaded to BrowserStack\n'
else
  printf '\n=== Saving %s to the build folder ===\n' "$(basename "$renamed_artifact_path")"
  scp "$renamed_artifact_path" "$RMB_BUILDS_HOST:$RMB_BUILDS_DIR/" || failure "Could not copy build to $RMB_BUILDS_HOST"
  printf 'SUCCESS: Saved to Build Folder\n'
fi
