#!/usr/bin/env bash
# Executed on the Android build Mac by XcodeRemoteBuild.sh for unit-test runs.

# XcodeRemoteBuild.sh streams AndroidCommon.sh ahead of this script.
if ! declare -F prepare_android_checkout >/dev/null; then
  printf 'FAILURE: Run this through XcodeRemoteBuild.sh, which supplies AndroidCommon.sh\n' >&2
  exit 1
fi

usage() {
  cat <<'EOF'
Usage: AndroidUnitTestRemote.sh --repo <repository-name> --branch <branch> --shortCode <short-code> [--type <account-type>]
EOF
}

repo=""
account_type=""
branch=""
short_code=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) [[ $# -ge 2 ]] || failure "--type requires a value"; account_type="$2"; shift 2 ;;
    --repo) [[ $# -ge 2 ]] || failure "--repo requires a value"; repo="$2"; shift 2 ;;
    --branch) [[ $# -ge 2 ]] || failure "--branch requires a value"; branch="$2"; shift 2 ;;
    --shortCode) [[ $# -ge 2 ]] || failure "--shortCode requires a value"; short_code="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) failure "Unknown argument: $1" ;;
  esac
done

[[ -n "$repo" ]] || failure "--repo is required"
[[ -n "$branch" ]] || failure "--branch is required"
[[ -n "$short_code" ]] || failure "--shortCode is required"
[[ "$short_code" =~ ^[A-Za-z0-9_-]+$ ]] || failure "--shortCode may only contain letters, numbers, underscores, and hyphens"
is_path_segment "$repo" || failure "--repo must be a single directory name"
[[ -z "$account_type" ]] || is_path_segment "$account_type" || failure "--type must be a single directory name"
[[ "$branch" != -* ]] || failure "--branch must not begin with a dash"

copy_report_directory() {
  local source_directory="$1" report_timestamp report_destination source_html_count remote_html_count remote_report_host

  report_timestamp="$(date '+%Y-%m-%d_%H-%M-%S')"
  report_destination="$RMB_BUILDS_DIR/Android/$report_timestamp/$branch"
  [[ -s "$source_directory/index.html" ]] || return 1
  source_html_count="$(find "$source_directory" -type f -name '*.html' -print | wc -l | tr -d '[:space:]')"
  [[ "$source_html_count" =~ ^[1-9][0-9]*$ ]] || return 1
  ssh "$RMB_BUILDS_HOST" "mkdir -p $(printf '%q' "$report_destination")" || return 1
  scp -r "$source_directory"/. "$RMB_BUILDS_HOST:$report_destination/" || return 1
  remote_html_count="$(ssh "$RMB_BUILDS_HOST" "find $(printf '%q' "$report_destination") -type f -name '*.html' -print | wc -l" 2>/dev/null | tr -d '[:space:]')"
  [[ "$remote_html_count" == "$source_html_count" ]] || return 1
  ssh "$RMB_BUILDS_HOST" "test -s $(printf '%q' "$report_destination/index.html")" || return 1
  remote_report_host="$(ssh "$RMB_BUILDS_HOST" 'hostname' 2>/dev/null | tr -d '\n')" || return 1
  printf 'REPORT: %s:%s (%s HTML reports)\n' "$remote_report_host" "$report_destination" "$source_html_count"
}

test_log=""
test_failure_summary=""
after_cleanup() {
  if [[ -n "$test_failure_summary" ]]; then
    printf '\n=== Android unit-test failure summary ===\n%s\n' "$test_failure_summary"
  fi
  [[ -z "$test_log" ]] || rm -f "$test_log"
}

open_android_repository
report_directory="$project_path/app/build/reports/tests/test${short_code}DebugUnitTest"
prepare_android_checkout

printf '\n=== Running Android unit tests ===\nCommand: ./gradlew test%sDebugUnitTest\n' "$short_code"
test_log="$(mktemp -t android-unit-tests)" || failure "Could not create Android unit-test log"
test_exit_status=0
./gradlew "test${short_code}DebugUnitTest" >"$test_log" 2>&1 || test_exit_status=$?
cat "$test_log"

if [[ ! -s "$report_directory/index.html" ]]; then
  if (( test_exit_status != 0 )); then
    # Put Gradle's actual failure near the end of Shortcuts' 12-line alert;
    # otherwise repository cleanup hides it behind generated-file messages.
    test_failure_summary="$(sed -n '/^[[:space:]]*\* What went wrong:/,/^[[:space:]]*\* Try:/p' "$test_log" | tail -n 8)"
    [[ -n "$test_failure_summary" ]] || test_failure_summary="$(tail -n 8 "$test_log")"
    failure "Gradle unit tests failed and did not produce an HTML report"
  fi
  failure "Could not find Android test report: $report_directory/index.html"
fi
rm -f "$test_log"
test_log=""
if (( test_exit_status != 0 )); then
  printf '=== Tests completed with failures; copying the HTML report ===\n'
fi
printf '\n=== Saving test report to the build folder ===\n'
copy_report_directory "$report_directory" || failure "Could not copy and verify test reports on $RMB_BUILDS_HOST"

cleanup_repo
trap - EXIT HUP INT TERM
[[ $cleanup_status -eq 0 ]] || delivered_but_not_reset "Report saved"
printf 'SUCCESS: Tests Ran\n'
