#!/usr/bin/env bash
# Executed on the Android build Mac by XcodeRemoteBuild.sh for unit-test runs.

set -u

usage() {
  cat <<'EOF'
Usage: AndroidUnitTestRemote.sh --repo <repository-name> --branch <branch> --shortCode <short-code> [--type <account-type>]
EOF
}

failure() {
  printf 'FAILURE: %s\n' "$1" >&2
  exit 1
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

  if [[ -n "${JAVA_HOME:-}" ]] && use_supported_java "$JAVA_HOME"; then
    return 0
  fi
  registered_java_home="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
  [[ -n "$registered_java_home" ]] && use_supported_java "$registered_java_home" && return 0
  registered_java_home="$(/usr/libexec/java_home -v 21 2>/dev/null || true)"
  [[ -n "$registered_java_home" ]] && use_supported_java "$registered_java_home" && return 0

  for candidate in \
    '/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
    /opt/homebrew/opt/openjdk@21 \
    /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
    /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home; do
    use_supported_java "$candidate" && return 0
  done
  return 1
}

configure_android_sdk() {
  local candidate

  # local.properties may not exist on the build Mac, so Gradle must be able to
  # get its SDK location from the remote machine's environment.
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

repo_path="$HOME/Code"
[[ -z "$account_type" ]] || repo_path="$repo_path/$account_type"
repo_path="$repo_path/$repo"
project_path="$repo_path/$RMB_ANDROID_PROJECT_DIR"
report_directory="$project_path/app/build/reports/tests/test${short_code}DebugUnitTest"
[[ -d "$repo_path" ]] || failure "Could not find repository: $repo_path"
[[ -d "$project_path" ]] || failure "Could not find Android project: $project_path"

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

cd "$repo_path" || failure "Could not enter repository: $repo_path"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || failure "Repository is not a Git work tree: $repo_path"
git check-ref-format --branch "$branch" >/dev/null 2>&1 || failure "Invalid branch name: $branch"

# local.properties is deliberately ignored and holds machine-local paths such
# as KEYSTORE_DIR. Preserve it outside the checkout so the required cleans do
# not lose configuration for this run or later builds.
local_properties_path="$project_path/local.properties"
local_properties_backup=""
if [[ -f "$local_properties_path" ]]; then
  local_properties_backup="$(mktemp -t remote-mobile-local-properties)" || failure "Could not back up local.properties"
  cp "$local_properties_path" "$local_properties_backup" || failure "Could not back up local.properties"
fi
restore_local_properties() {
  [[ -z "$local_properties_backup" ]] || cp "$local_properties_backup" "$local_properties_path"
}

cleanup_done=0
cleanup_status=0
test_log=""
test_failure_summary=""
cleanup_repo() {
  [[ $cleanup_done -eq 0 ]] || return
  cleanup_done=1
  printf '\n=== Resetting remote repository ===\n'
  git reset --hard || cleanup_status=1
  git clean -ffdx || cleanup_status=1
  if [[ -n "$local_properties_backup" ]]; then
    if restore_local_properties; then
      rm -f "$local_properties_backup"
    else
      cleanup_status=1
      printf 'Could not restore local.properties; a copy remains at %s\n' "$local_properties_backup" >&2
    fi
  fi
  if [[ -n "$test_failure_summary" ]]; then
    printf '\n=== Android unit-test failure summary ===\n%s\n' "$test_failure_summary"
  fi
  [[ -z "$test_log" ]] || rm -f "$test_log"
}
trap cleanup_repo EXIT
trap 'exit 130' HUP INT TERM

printf '=== Preparing remote repository ===\n'
git reset --hard || failure "Could not reset remote repository before checkout"
git clean -ffdx || failure "Could not clean remote repository before checkout"
printf '=== Checking out branch: %s ===\n' "$branch"
git fetch origin "+refs/heads/$branch:refs/remotes/origin/$branch" || failure "Could not fetch branch from origin: $branch"
git show-ref --verify --quiet "refs/remotes/origin/$branch" || failure "Could not find remote branch: origin/$branch"
git checkout -B "$branch" "origin/$branch" || failure "Could not check out branch: $branch"
git branch --set-upstream-to="origin/$branch" "$branch" || failure "Could not set upstream branch: origin/$branch"

cd "$project_path" || failure "Could not enter Android project: $project_path"
restore_local_properties || failure "Could not restore local.properties"
[[ -x ./gradlew ]] || failure "Could not find executable Gradle wrapper: $project_path/gradlew"
configure_java || failure "Could not find a Java runtime on the remote Mac"
printf '=== Using Java: %s ===\n' "$JAVA_HOME"
configure_android_sdk || failure "Could not find the Android SDK on the remote Mac"
printf '=== Using Android SDK: %s ===\n' "$ANDROID_HOME"

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
[[ $cleanup_status -eq 0 ]] || failure "Could not fully reset repository after the unit-test run"
printf 'SUCCESS: Tests Ran\n'
