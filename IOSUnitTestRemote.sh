#!/usr/bin/env bash
# Executed on the iOS remote Mac by XcodeRemoteBuild.sh for unit-test runs.

set -u

for tool_directory in /opt/homebrew/bin /usr/local/bin "$HOME/.rbenv/shims" "$HOME/.asdf/shims"; do
  [[ -d "$tool_directory" ]] && PATH="$tool_directory:$PATH"
done
export PATH
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export LC_CTYPE="en_US.UTF-8"

# Fastlane's test lane invokes xcrun/simctl. SSH otherwise inherits the
# Command Line Tools developer directory, which does not include simctl.
[[ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]] || {
  printf 'FAILURE: Could not find Xcode.\n' >&2
  exit 1
}
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

usage() {
  cat <<'EOF'
Usage: IOSUnitTestRemote.sh --repo <repository-name> --branch <branch> [--type <account-type>] [--devices <Latest|All>]
EOF
}

failure() {
  printf 'FAILURE: %s\n' "$1" >&2
  exit 1
}

# XcodeRemoteBuild.sh exports these from config.sh ahead of this script.
for config_name in RMB_BUILDS_HOST RMB_BUILDS_DIR RMB_FASTLANE_SELECTOR RMB_GDRIVE_EMAIL; do
  [[ -n "${!config_name:-}" ]] || failure "$config_name is not set; run this through XcodeRemoteBuild.sh with config.sh filled in"
done

is_path_segment() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$1" != "." && "$1" != ".." ]]
}

select_fastlane_environment() {
  local version="$1" environment_file environment_setting

  command -v zsh >/dev/null 2>&1 || {
    printf 'Could not find zsh required for the Fastlane selector function.\n' >&2
    return 1
  }

  environment_file="$(mktemp -t xcode-remote-fastlane-env)" || return 1
  # The selector is a function in ~/.zshrc. Capture the build environment it
  # configures, then export it into this non-interactive Bash process.
  if ! zsh -ic '"$2" --version "$1" --xcode /Applications/Xcode.app --gdriveemail "$3" || exit $?; printf "%s\n" "FASTLANE_USER=$FASTLANE_USER" "FASTLANE_PASSWORD=$FASTLANE_PASSWORD" "FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD=$FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD" "MATCH_PASSWORD=$MATCH_PASSWORD" "FASTLANE_GDRIVE_PATH=$FASTLANE_GDRIVE_PATH" "FASTLANE_CERTIFICATE_GIT_URL=$FASTLANE_CERTIFICATE_GIT_URL" "MAC_USER=$MAC_USER" "XCODE_PATH=$XCODE_PATH" "GDriveEmail=$GDriveEmail"' zsh "$version" "$RMB_FASTLANE_SELECTOR" "$RMB_GDRIVE_EMAIL" > "$environment_file"; then
    rm -f "$environment_file"
    return 1
  fi
  while IFS= read -r environment_setting; do
    case "$environment_setting" in
      FASTLANE_USER=*|FASTLANE_PASSWORD=*|FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD=*|MATCH_PASSWORD=*|FASTLANE_GDRIVE_PATH=*|FASTLANE_CERTIFICATE_GIT_URL=*|MAC_USER=*|XCODE_PATH=*|GDriveEmail=*)
        export "$environment_setting"
        ;;
    esac
  done < "$environment_file"
  rm -f "$environment_file"
}

repo=""
account_type=""
branch=""
devices=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) [[ $# -ge 2 ]] || failure "--type requires a value"; account_type="$2"; shift 2 ;;
    --repo) [[ $# -ge 2 ]] || failure "--repo requires a value"; repo="$2"; shift 2 ;;
    --branch) [[ $# -ge 2 ]] || failure "--branch requires a value"; branch="$2"; shift 2 ;;
    --devices) [[ $# -ge 2 ]] || failure "--devices requires a value"; devices="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) failure "Unknown argument: $1" ;;
  esac
done

[[ -n "$repo" ]] || failure "--repo is required"
[[ -n "$branch" ]] || failure "--branch is required"
[[ -z "$devices" || "$devices" == "Latest" || "$devices" == "All" ]] || failure "--devices must be Latest or All"
is_path_segment "$repo" || failure "--repo must be a single directory name"
[[ -z "$account_type" ]] || is_path_segment "$account_type" || failure "--type must be a single directory name"
[[ "$branch" != -* ]] || failure "--branch must not begin with a dash"

repo_path="$HOME/Code"
[[ -z "$account_type" ]] || repo_path="$repo_path/$account_type"
repo_path="$repo_path/$repo"
report_directory="$repo_path/fastlane/test_output"
[[ -d "$repo_path" ]] || failure "Could not find repository: $repo_path"

report_transferred=0
report_recovered_during_cleanup=0
copy_report_directory() {
  local source_directory="$1" report_timestamp report_destination source_html_count remote_html_count remote_report_host

  report_timestamp="$(date '+%Y-%m-%d_%H-%M-%S')"
  report_destination="$RMB_BUILDS_DIR/iOS/$report_timestamp/$branch"
  # report.html is an index when several devices are tested. Copy the whole
  # directory so its relative links to each device's report keep working.
  [[ -s "$source_directory/report.html" ]] || return 1
  source_html_count="$(find "$source_directory" -type f -name '*.html' -print | wc -l | tr -d '[:space:]')"
  [[ "$source_html_count" =~ ^[1-9][0-9]*$ ]] || return 1
  ssh "$RMB_BUILDS_HOST" "mkdir -p $(printf '%q' "$report_destination")" || return 1
  scp -r "$source_directory"/. "$RMB_BUILDS_HOST:$report_destination/" || return 1
  remote_html_count="$(ssh "$RMB_BUILDS_HOST" "find $(printf '%q' "$report_destination") -type f -name '*.html' -print | wc -l" 2>/dev/null | tr -d '[:space:]')"
  [[ "$remote_html_count" == "$source_html_count" ]] || return 1
  ssh "$RMB_BUILDS_HOST" "test -s $(printf '%q' "$report_destination/report.html")" || return 1
  remote_report_host="$(ssh "$RMB_BUILDS_HOST" 'hostname' 2>/dev/null | tr -d '\n')" || return 1
  report_transferred=1
  printf 'REPORT: %s:%s (%s HTML reports)\n' "$remote_report_host" "$report_destination" "$source_html_count"
}

cd "$repo_path" || failure "Could not enter repository: $repo_path"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || failure "Repository is not a Git work tree: $repo_path"
git check-ref-format --branch "$branch" >/dev/null 2>&1 || failure "Invalid branch name: $branch"

cleanup_done=0
cleanup_status=0
test_failure_summary=""
cleanup_repo() {
  [[ $cleanup_done -eq 0 ]] || return
  cleanup_done=1
  printf '\n=== Resetting remote repository ===\n'
  # Fallback for test tools that finish the test process but interrupt the
  # streamed runner before its normal transfer step. Copy before git clean
  # removes the generated report inside the repository.
  if [[ $report_transferred -eq 0 ]]; then
    if [[ -f "$report_directory/report.html" ]]; then
      printf '=== Recovering test report before cleanup ===\n'
      if copy_report_directory "$report_directory"; then
        report_recovered_during_cleanup=1
      else
        cleanup_status=1
      fi
    fi
  fi
  git reset --hard || cleanup_status=1
  git clean -ffdx || cleanup_status=1
  if [[ -n "$test_failure_summary" ]]; then
    printf '\n=== Unit-test failure summary ===\n%s\n' "$test_failure_summary"
  fi
  # If a child consumed the streamed runner after producing a report, finish
  # successfully here. The report has been copied and verified, and test
  # assertion failures belong in that report rather than blocking delivery.
  if [[ $report_recovered_during_cleanup -eq 1 && $cleanup_status -eq 0 ]]; then
    printf 'SUCCESS: Tests Ran\n'
    exit 0
  fi
}
trap cleanup_repo EXIT
trap 'exit 130' HUP INT TERM

printf '=== Preparing remote repository ===\n'
if ! git reset --hard; then
  failure "Could not reset remote repository before checkout"
elif ! git clean -ffdx; then
  failure "Could not clean remote repository before checkout"
fi

printf '=== Checking out branch: %s ===\n' "$branch"
if ! git fetch origin "+refs/heads/$branch:refs/remotes/origin/$branch"; then
  failure "Could not fetch branch from origin: $branch"
elif ! git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
  failure "Could not find remote branch: origin/$branch"
elif ! git checkout -B "$branch" "origin/$branch"; then
  failure "Could not check out branch: $branch"
elif ! git branch --set-upstream-to="origin/$branch" "$branch"; then
  failure "Could not set upstream branch: origin/$branch"
fi

command -v bundle >/dev/null 2>&1 || failure "Could not find Bundler (bundle)"
printf '\n=== Selecting Fastlane environment: old ===\n'
select_fastlane_environment old || failure "Could not select Fastlane environment: old"
# Reapply this after the selector: its interactive shell profile may alter
# Xcode-related variables. Validate before spending time on the test suite.
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"
simctl_path="$(/usr/bin/xcrun --find simctl 2>/dev/null)" || failure "Could not find simctl in the selected Xcode developer directory"
printf '=== Using simulator tool: %s ===\n' "$simctl_path"
command -v pod >/dev/null 2>&1 || failure "Could not find CocoaPods (pod)"
printf '\n=== Running pod install ===\n'
pod install --project-directory="$repo_path" || failure "pod install failed"
printf '\n=== Running iOS unit tests ===\n'
test_log="$(mktemp -t ios-unit-tests)" || failure "Could not create unit-test log"
test_exit_status=0
fastlane_test_command=( bundle exec fastlane ios test )
[[ -z "$devices" ]] || fastlane_test_command+=( "devices:$devices" )
# This runner is streamed to the remote shell over SSH standard input. Some
# Fastlane/Xcode test processes read stdin; without this redirect they can
# consume the remainder of this script, skipping report transfer and success
# output once tests finish.
if FASTLANE_SKIP_UPDATE_CHECK=1 "${fastlane_test_command[@]}" >"$test_log" 2>&1 </dev/null; then
  :
else
  test_exit_status=$?
fi
cat "$test_log"

# The test lane writes its index and per-device HTML reports within the
# checked-out repository.
if [[ ! -f "$report_directory/report.html" ]]; then
  if (( test_exit_status != 0 )); then
    # The Fastlane update notice is normally at the very end of its output.
    # Reprint only diagnostic lines after cleanup so Shortcuts' 12-line failure
    # alert includes the reason no usable test report was produced.
    test_failure_summary="$(grep -Ei '❌|xctassert|test case .* failed|test suite .* failed|\*\* test failed \*\*|\[!\]|error:|error |failure' "$test_log" | grep -Ev '^[[:space:]]*\* \[|✔' | tail -n 8 || true)"
    [[ -n "$test_failure_summary" ]] || test_failure_summary="$(tail -n 8 "$test_log")"
  fi
  rm -f "$test_log"
  failure "Could not find test report: $report_directory/report.html"
fi
rm -f "$test_log"
if (( test_exit_status != 0 )); then
  printf '=== Tests completed with failures; copying the HTML report ===\n'
fi
printf '\n=== Saving test report to the build folder ===\n'
copy_report_directory "$report_directory" || failure "Could not copy and verify test reports on $RMB_BUILDS_HOST"

cleanup_repo
trap - EXIT HUP INT TERM
[[ $cleanup_status -eq 0 ]] || failure "Could not fully reset repository after the unit-test run"

printf 'SUCCESS: Tests Ran\n'
