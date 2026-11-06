#!/usr/bin/env bash
# Run a Fastlane job or iOS unit tests on a repository on a configured SSH host.
# Android runs use AndroidRemoteBuild.sh.
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
source "$script_dir/LocalCommon.sh" || { printf 'FAILURE: Could not load %s\n' "$script_dir/LocalCommon.sh" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: XcodeRemoteBuild.sh <ssh-host> --repo <repository-name> [options]

Options:
  --type <account-type>       Repository subdirectory under ~/Code (for example, personal).
  --repo <repository-name>    Name of the repository directory (required).
  --branch <branch>           Git branch to check out on the remote host (required).
  --lane <lane>               Fastlane lane to run (required for builds).
  --shortCode <short-code>    Value passed to Fastlane as name:<short-code> (required for builds).
  --features <features>       Optional Fastlane parameter, for example apiDev:true.
  --newApple                  Use the new Fastlane environment; defaults to old.
  --unitTests                 Run the iOS unit-test runner instead of a build.
  --devices <Latest|All>      Optional unit-test device selection.
  -h, --help                  Show this help text.

The remote repository path is ~/Code/<type>/<repo> when --type is present,
or ~/Code/<repo> when it is omitted. SSH authentication (including the key)
is taken from your normal SSH configuration.

To unlock the remote login Keychain for signing, set
XCODE_REMOTE_KEYCHAIN_PASSWORD in your local environment before running this
script. It is sent to the runner over SSH standard input, not as an argument,
and only for builds.

For Android builds and tests, use AndroidRemoteBuild.sh.
USAGE
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
    --platform)
      # The Shortcut is a pasted copy, so an old one can still send this.
      fail "--platform was removed: Android runs now use AndroidRemoteBuild.sh. If the Shortcut sent this, paste in the current Shortcut/Type-RunShellScript.sh"
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
  [[ -z "$devices" || "$devices" == "Latest" || "$devices" == "All" ]] || fail "--devices must be Latest or All"
  remote_files=( "$script_dir/IOSUnitTestRemote.sh" )
  required_settings=( RMB_BUILDS_HOST RMB_BUILDS_DIR RMB_FASTLANE_SELECTOR RMB_GDRIVE_EMAIL )
else
  [[ -n "$short_code" ]] || fail "--shortCode is required"
  [[ -n "$lane" ]] || fail "--lane is required"
  remote_files=( "$script_dir/XcodeRemoteBuildRemote.sh" )
  required_settings=( RMB_FASTLANE_SELECTOR RMB_GDRIVE_EMAIL RMB_IOS_IPA_DIR )
fi
require_remote_files
load_config "${required_settings[@]}"

remote_arguments=( --repo "$repo" )
[[ -z "$account_type" ]] || remote_arguments+=( --type "$account_type" )
remote_arguments+=( --branch "$branch" )
if [[ $unit_tests -eq 1 ]]; then
  [[ -z "$devices" ]] || remote_arguments+=( --devices "$devices" )
else
  remote_arguments+=( --shortCode "$short_code" )
  remote_arguments+=( --lane "$lane" )
  [[ -z "$features" ]] || remote_arguments+=( --features "$features" )
  [[ $new_apple -eq 0 ]] || remote_arguments+=( --newApple )
fi
quote_remote_arguments "${remote_arguments[@]}"

# Only the build runner unlocks the Keychain and clears the password. Keep it
# off the remote host for test runs.
[[ $unit_tests -eq 0 ]] || unset XCODE_REMOTE_KEYCHAIN_PASSWORD
if [[ -n "${XCODE_REMOTE_KEYCHAIN_PASSWORD:-}" ]]; then
  # Feed the password before the remote script; it is never placed in the SSH
  # command or argument list. The small remote Bash wrapper consumes that line
  # and passes the remainder to the runner as its script source.
  remote_wrapper='IFS= read -r XCODE_REMOTE_KEYCHAIN_PASSWORD; export XCODE_REMOTE_KEYCHAIN_PASSWORD; exec bash -s -- "$@"'
  printf -v remote_command 'bash -c %q bash' "$remote_wrapper"
  { printf '%s\n' "$XCODE_REMOTE_KEYCHAIN_PASSWORD"; printf '%s' "$remote_preamble"; stream_runner; } | ssh "$host" "$remote_command$quoted_remote_arguments"
else
  { printf '%s' "$remote_preamble"; stream_runner; } | ssh "$host" "bash -s --$quoted_remote_arguments"
fi
finish_remote_run "$?"
