#!/usr/bin/env bash
# Run an Android Gradle build or unit tests on a repository on a configured SSH
# host. iOS runs use XcodeRemoteBuild.sh.
#
# Example:
#   ./AndroidRemoteBuild.sh android-build-mac --type work --repo android-app \
#     --branch develop --buildType Release --buildPackage Bundle \
#     --shortCode MyFlavor
#
# Machine-specific settings are read from config.sh next to this script.
# Copy config.example.sh to config.sh and fill it in.

set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/LocalCommon.sh" || { printf 'FAILURE: Could not load %s\n' "$script_dir/LocalCommon.sh" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: AndroidRemoteBuild.sh <ssh-host> --repo <repository-name> [options]

Options:
  --type <account-type>       Repository subdirectory under ~/Code (for example, personal).
  --repo <repository-name>    Name of the repository directory (required).
  --branch <branch>           Git branch to check out on the remote host (required).
  --shortCode <short-code>    Gradle flavor (required).
  --buildType <type>          Release, Debug, BrowserStack, or Play Store (required for builds).
  --buildPackage <type>       APK or Bundle (required for builds).
  --bundleId <id>             Play Store: application ID to publish.
  --devApis <true|false>      BrowserStack: enable development APIs.
  --features <flags>          Optional space-separated Gradle properties, without -P.
  --unitTests                 Run the Android unit-test runner instead of a build.
  -h, --help                  Show this help text.

The remote repository path is ~/Code/<type>/<repo> when --type is present,
or ~/Code/<repo> when it is omitted. SSH authentication (including the key)
is taken from your normal SSH configuration.

For iOS builds and tests, use XcodeRemoteBuild.sh.
USAGE
}

[[ $# -gt 0 ]] || { usage >&2; exit 2; }
[[ "$1" != "-h" && "$1" != "--help" ]] || { usage; exit 0; }

host="$1"
shift
repo=""
account_type=""
branch=""
short_code=""
features=""
build_type=""
build_package=""
bundle_id=""
dev_apis=""
unit_tests=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)
      [[ $# -ge 2 ]] || fail "--type requires a value"
      account_type="$2"
      shift 2
      ;;
    --repo)
      [[ $# -ge 2 ]] || fail "--repo requires a value"
      repo="$2"
      shift 2
      ;;
    --branch)
      [[ $# -ge 2 ]] || fail "--branch requires a value"
      branch="$2"
      shift 2
      ;;
    --shortCode)
      [[ $# -ge 2 ]] || fail "--shortCode requires a value"
      short_code="$2"
      shift 2
      ;;
    --features)
      [[ $# -ge 2 ]] || fail "--features requires a value"
      features="$2"
      shift 2
      ;;
    --buildType)
      [[ $# -ge 2 ]] || fail "--buildType requires a value"
      build_type="$2"
      shift 2
      ;;
    --buildPackage)
      [[ $# -ge 2 ]] || fail "--buildPackage requires a value"
      build_package="$2"
      shift 2
      ;;
    --bundleId)
      [[ $# -ge 2 ]] || fail "--bundleId requires a value"
      bundle_id="$2"
      shift 2
      ;;
    --devApis)
      [[ $# -ge 2 ]] || fail "--devApis requires a value"
      dev_apis="$2"
      shift 2
      ;;
    --unitTests)
      unit_tests=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$repo" ]] || fail "--repo is required"
[[ -n "$branch" ]] || fail "--branch is required"
[[ -n "$short_code" ]] || fail "--shortCode is required"
is_path_segment "$repo" || fail "--repo must be a single directory name"
[[ -z "$account_type" ]] || is_path_segment "$account_type" || fail "--type must be a single directory name"

if [[ $unit_tests -eq 1 ]]; then
  remote_files=( "$script_dir/AndroidCommon.sh" "$script_dir/AndroidUnitTestRemote.sh" )
else
  [[ "$build_type" == "Release" || "$build_type" == "Debug" || "$build_type" == "BrowserStack" || "$build_type" == "Play Store" ]] || fail "--buildType must be Release, Debug, BrowserStack, or Play Store"
  [[ "$build_package" == "APK" || "$build_package" == "Bundle" ]] || fail "--buildPackage must be APK or Bundle"
  if [[ "$build_type" == "Play Store" ]]; then
    [[ "$build_package" == "Bundle" ]] || fail "Play Store builds require --buildPackage Bundle"
    [[ "$bundle_id" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]] || fail "--bundleId must be a valid Android application ID"
  fi
  [[ -z "$dev_apis" || "$dev_apis" == "true" || "$dev_apis" == "false" ]] || fail "--devApis must be true or false"
  remote_files=( "$script_dir/AndroidCommon.sh" "$script_dir/AndroidRemoteBuildRemote.sh" )
fi
require_remote_files
load_config RMB_BUILDS_HOST RMB_BUILDS_DIR RMB_ANDROID_PROJECT_DIR

play_service_account_json="${RMB_ANDROID_PLAY_SERVICE_ACCOUNT_JSON:-}"
[[ "$play_service_account_json" != *$'\n'* ]] || fail "RMB_ANDROID_PLAY_SERVICE_ACCOUNT_JSON must not contain a newline"
if [[ $unit_tests -eq 0 && "$build_type" == "Play Store" ]]; then
  [[ -n "$play_service_account_json" ]] || fail "RMB_ANDROID_PLAY_SERVICE_ACCOUNT_JSON is required for Play Store builds"
fi
[[ -z "$play_service_account_json" ]] || add_to_preamble GOOGLE_PLAY_SERVICE_ACCOUNT_JSON "$play_service_account_json"

remote_arguments=( --repo "$repo" )
[[ -z "$account_type" ]] || remote_arguments+=( --type "$account_type" )
remote_arguments+=( --branch "$branch" --shortCode "$short_code" )
if [[ $unit_tests -eq 0 ]]; then
  remote_arguments+=( --buildType "$build_type" --buildPackage "$build_package" )
  [[ -z "$bundle_id" ]] || remote_arguments+=( --bundleId "$bundle_id" )
  [[ -z "$dev_apis" ]] || remote_arguments+=( --devApis "$dev_apis" )
  [[ -z "$features" ]] || remote_arguments+=( --features "$features" )
fi
quote_remote_arguments "${remote_arguments[@]}"

{ printf '%s' "$remote_preamble"; stream_runner; } | ssh "$host" "bash -s --$quoted_remote_arguments"
finish_remote_run "$?"
