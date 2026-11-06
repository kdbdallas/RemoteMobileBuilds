#!/usr/bin/env bash
# Executed on the Android build Mac by XcodeRemoteBuild.sh for Android builds.

# XcodeRemoteBuild.sh streams AndroidCommon.sh ahead of this script.
if ! declare -F prepare_android_checkout >/dev/null; then
  printf 'FAILURE: Run this through XcodeRemoteBuild.sh, which supplies AndroidCommon.sh\n' >&2
  exit 1
fi

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

open_android_repository
prepare_android_checkout

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
