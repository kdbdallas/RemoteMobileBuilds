#!/usr/bin/env bash
# Run a Fastlane job on a repository available on a configured SSH host.
#
# Example:
#   ./XcodeRemoteBuild.sh ios-build-mac --type work --repo ios-app \
#     --branch feature/CM-123-Test --lane createAppForBrowserStack \
#     --shortCode MyApp --features apiDev:true --newApple
#
# Machine-specific settings are read from config.sh next to this script.
# Copy config.example.sh to config.sh and fill it in.

set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_remote_runner="$script_dir/XcodeRemoteBuildRemote.sh"
android_remote_runner="$script_dir/AndroidRemoteBuildRemote.sh"
ios_test_remote_runner="$script_dir/IOSUnitTestRemote.sh"
android_test_remote_runner="$script_dir/AndroidUnitTestRemote.sh"
android_common="$script_dir/AndroidCommon.sh"
config_file="$script_dir/config.sh"

usage() {
  cat <<'EOF'
Usage: XcodeRemoteBuild.sh <ssh-host> --repo <repository-name> [options]

Options:
  --type <account-type>       Repository subdirectory under ~/Code (for example, personal).
  --repo <repository-name>    Name of the repository directory (required).
  --branch <branch>           Git branch to check out on the remote host (required).
  --lane <lane>               Fastlane lane to run (required).
  --shortCode <short-code>    Value passed to Fastlane as name:<short-code> (required).
  --features <features>       Optional Fastlane parameter, for example apiDev:true.
  --newApple                  Use the new Fastlane environment; defaults to old.
  --platform <ios|android>    Build platform; defaults to ios.
  --buildType <type>          Android: Release, Debug, BrowserStack, or Play Store.
  --buildPackage <type>       Android: APK or Bundle.
  --bundleId <id>             Android Play Store: application ID to publish.
  --devApis <true|false>      Android BrowserStack: enable development APIs.
  --unitTests                 Run the selected platform's unit-test runner instead of a build.
  --devices <Latest|All>      Optional iOS unit-test device selection.
  -h, --help                  Show this help text.

The remote repository path is ~/Code/<type>/<repo> when --type is present,
or ~/Code/<repo> when it is omitted. SSH authentication (including the key)
is taken from your normal SSH configuration.

To unlock the remote login Keychain for signing, set
XCODE_REMOTE_KEYCHAIN_PASSWORD in your local environment before running this
script. It is sent to the runner over SSH standard input, not as an argument,
and only for iOS builds.
EOF
}

fail() {
  printf 'FAILURE: %s\n' "$1" >&2
  exit 1
}

is_path_segment() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$1" != "." && "$1" != ".." ]]
}

[[ $# -gt 0 ]] || { usage >&2; exit 2; }
[[ "$1" != "-h" && "$1" != "--help" ]] || { usage; exit 0; }

host="$1"
shift
repo=""
account_type=""
branch=""
lane=""
short_code=""
features=""
new_apple=0
platform="ios"
build_type=""
build_package=""
bundle_id=""
dev_apis=""
unit_tests=0
devices=""

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
    --lane)
      [[ $# -ge 2 ]] || fail "--lane requires a value"
      lane="$2"
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
    --newApple)
      new_apple=1
      shift
      ;;
    --platform)
      [[ $# -ge 2 ]] || fail "--platform requires a value"
      platform="$2"
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
    --devices)
      [[ $# -ge 2 ]] || fail "--devices requires a value"
      devices="$2"
      shift 2
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
is_path_segment "$repo" || fail "--repo must be a single directory name"
[[ -z "$account_type" ]] || is_path_segment "$account_type" || fail "--type must be a single directory name"
[[ "${XCODE_REMOTE_KEYCHAIN_PASSWORD:-}" != *$'\n'* ]] || fail "XCODE_REMOTE_KEYCHAIN_PASSWORD must not contain a newline"

if [[ $unit_tests -eq 1 ]]; then
  case "$platform" in
    ios)
      [[ -z "$devices" || "$devices" == "Latest" || "$devices" == "All" ]] || fail "--devices must be Latest or All"
      remote_files=( "$ios_test_remote_runner" )
      required_settings=( RMB_BUILDS_HOST RMB_BUILDS_DIR RMB_FASTLANE_SELECTOR RMB_GDRIVE_EMAIL )
      ;;
    android)
      [[ -z "$devices" ]] || fail "--devices is only available for iOS unit tests"
      [[ -n "$short_code" ]] || fail "--shortCode is required for Android unit tests"
      remote_files=( "$android_common" "$android_test_remote_runner" )
      required_settings=( RMB_BUILDS_HOST RMB_BUILDS_DIR RMB_ANDROID_PROJECT_DIR )
      ;;
    *) fail "--platform must be ios or android" ;;
  esac
else
  [[ -n "$short_code" ]] || fail "--shortCode is required"
  case "$platform" in
    ios)
      [[ -n "$lane" ]] || fail "--lane is required"
      remote_files=( "$ios_remote_runner" )
      required_settings=( RMB_FASTLANE_SELECTOR RMB_GDRIVE_EMAIL RMB_IOS_IPA_DIR )
      ;;
    android)
      [[ "$build_type" == "Release" || "$build_type" == "Debug" || "$build_type" == "BrowserStack" || "$build_type" == "Play Store" ]] || fail "--buildType must be Release, Debug, BrowserStack, or Play Store"
      [[ "$build_package" == "APK" || "$build_package" == "Bundle" ]] || fail "--buildPackage must be APK or Bundle"
      if [[ "$build_type" == "Play Store" ]]; then
        [[ "$build_package" == "Bundle" ]] || fail "Play Store builds require --buildPackage Bundle"
        [[ "$bundle_id" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]] || fail "--bundleId must be a valid Android application ID"
      fi
      [[ -z "$dev_apis" || "$dev_apis" == "true" || "$dev_apis" == "false" ]] || fail "--devApis must be true or false"
      remote_files=( "$android_common" "$android_remote_runner" )
      required_settings=( RMB_BUILDS_HOST RMB_BUILDS_DIR RMB_ANDROID_PROJECT_DIR )
      ;;
    *) fail "--platform must be ios or android" ;;
  esac
fi
for remote_file in "${remote_files[@]}"; do
  [[ -f "$remote_file" ]] || fail "Could not find remote runner: $remote_file"
done

[[ -f "$config_file" ]] || fail "Could not find $config_file (copy config.example.sh to config.sh and fill it in)"
# shellcheck source=config.example.sh
source "$config_file" || fail "Could not load $config_file"
for config_name in "${required_settings[@]}"; do
  [[ -n "${!config_name:-}" ]] || fail "$config_name is not set in $config_file"
  [[ "${!config_name}" != *$'\n'* ]] || fail "$config_name must not contain a newline"
done
android_play_service_account_json="${RMB_ANDROID_PLAY_SERVICE_ACCOUNT_JSON:-}"
[[ "$android_play_service_account_json" != *$'\n'* ]] || fail "RMB_ANDROID_PLAY_SERVICE_ACCOUNT_JSON must not contain a newline"
if [[ $unit_tests -eq 0 && "$platform" == "android" && "$build_type" == "Play Store" ]]; then
  [[ -n "$android_play_service_account_json" ]] || fail "RMB_ANDROID_PLAY_SERVICE_ACCOUNT_JSON is required for Play Store builds"
fi
# Prepend the settings the remote runners need to the streamed script, so
# nothing machine-specific is stored in the runners themselves.
remote_preamble=""
for config_name in "${required_settings[@]}"; do
  printf -v config_line 'export %s=%q\n' "$config_name" "${!config_name}"
  remote_preamble+="$config_line"
done
if [[ -n "$android_play_service_account_json" ]]; then
  printf -v config_line 'export GOOGLE_PLAY_SERVICE_ACCOUNT_JSON=%q\n' "$android_play_service_account_json"
  remote_preamble+="$config_line"
fi

# The runner is sent through stdin, so it need not be preinstalled on the host.
# Bash normally reads a streamed script as it runs, so any child that reads
# stdin (ssh, Gradle, pod) would swallow the rest of the runner, and the run
# would then end with status 0 and no result. Sending it as one block makes
# Bash parse all of it first and gives every child an empty stdin. Do not use
# `exec </dev/null` inside a runner instead: it ends a streamed script at once.
stream_runner() {
  printf '{\n'
  for remote_file in "${remote_files[@]}"; do
    cat "$remote_file"
    printf '\n'
  done
  printf '} </dev/null\n'
}

remote_arguments=( --repo "$repo" )
[[ -z "$account_type" ]] || remote_arguments+=( --type "$account_type" )
remote_arguments+=( --branch "$branch" )
if [[ $unit_tests -eq 1 ]]; then
  if [[ "$platform" == "ios" ]]; then
    [[ -z "$devices" ]] || remote_arguments+=( --devices "$devices" )
  else
    remote_arguments+=( --shortCode "$short_code" )
  fi
elif [[ "$platform" == "ios" ]]; then
  remote_arguments+=( --shortCode "$short_code" )
  remote_arguments+=( --lane "$lane" )
  [[ -z "$features" ]] || remote_arguments+=( --features "$features" )
  [[ $new_apple -eq 0 ]] || remote_arguments+=( --newApple )
else
  remote_arguments+=( --shortCode "$short_code" )
  remote_arguments+=( --buildType "$build_type" --buildPackage "$build_package" )
  [[ -z "$bundle_id" ]] || remote_arguments+=( --bundleId "$bundle_id" )
  [[ -z "$dev_apis" ]] || remote_arguments+=( --devApis "$dev_apis" )
  [[ -z "$features" ]] || remote_arguments+=( --features "$features" )
fi
# Only the iOS build runner unlocks the Keychain and clears the password. Keep
# it off the remote host for every other run.
if [[ $unit_tests -eq 1 || "$platform" != "ios" ]]; then
  unset XCODE_REMOTE_KEYCHAIN_PASSWORD
fi
if [[ -n "${XCODE_REMOTE_KEYCHAIN_PASSWORD:-}" ]]; then
  # Feed the password before the remote script; it is never placed in the SSH
  # command or argument list. The small remote Bash wrapper consumes that line
  # and passes the remainder to the runner as its script source.
  remote_wrapper='IFS= read -r XCODE_REMOTE_KEYCHAIN_PASSWORD; export XCODE_REMOTE_KEYCHAIN_PASSWORD; exec bash -s -- "$@"'
  printf -v remote_command 'bash -c %q bash' "$remote_wrapper"
  for remote_argument in "${remote_arguments[@]}"; do
    printf -v escaped_argument '%q' "$remote_argument"
    remote_command+=" $escaped_argument"
  done
  { printf '%s\n' "$XCODE_REMOTE_KEYCHAIN_PASSWORD"; printf '%s' "$remote_preamble"; stream_runner; } | ssh "$host" "$remote_command"
else
  # ssh joins command arguments into text for the remote login shell. Quote
  # each argument before that handoff so branch names such as
  # "feature/APP-42-Q&A-Example" arrive intact.
  remote_command='bash -s --'
  for remote_argument in "${remote_arguments[@]}"; do
    printf -v escaped_argument '%q' "$remote_argument"
    remote_command+=" $escaped_argument"
  done
  { printf '%s' "$remote_preamble"; stream_runner; } | ssh "$host" "$remote_command"
fi
ssh_status=$?

# Status 3 means the result was delivered and only the reset failed. The runner
# has already said so, and a FAILURE line here would invite a repeat run.
if [[ $ssh_status -ne 0 && $ssh_status -ne 3 ]]; then
  printf 'FAILURE: Remote run failed (SSH or the remote runner exited with status %d).\n' "$ssh_status" >&2
fi

exit "$ssh_status"
