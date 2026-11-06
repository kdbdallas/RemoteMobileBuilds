# shellcheck shell=bash
# Shared by the Android runners. AndroidRemoteBuild.sh streams this file ahead of
# AndroidRemoteBuildRemote.sh or AndroidUnitTestRemote.sh, so it runs first.

set -u

failure() {
  printf 'FAILURE: %s\n' "$1" >&2
  exit 1
}

# Exit status 3 means the result was delivered but the checkout was not reset.
# AndroidRemoteBuild.sh and the Shortcut report it separately from a failure, so
# that nobody repeats a run that already published or uploaded a build.
delivered_but_not_reset() {
  printf 'WARNING: %s, but the remote repository could not be fully reset. It does not need to run again.\n' "$1" >&2
  exit 3
}

# AndroidRemoteBuild.sh exports these from config.sh ahead of this script.
for config_name in RMB_BUILDS_HOST RMB_BUILDS_DIR RMB_ANDROID_PROJECT_DIR; do
  [[ -n "${!config_name:-}" ]] || failure "$config_name is not set; run this through AndroidRemoteBuild.sh with config.sh filled in"
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

# Runners that have their own work to do during cleanup override this.
after_cleanup() { :; }

# From the moment this returns, the checkout goes back to a clean state however
# the run ends. Expects repo, account_type, and branch to be set, and sets
# repo_path and project_path.
open_android_repository() {
  repo_path="$HOME/Code"
  [[ -z "$account_type" ]] || repo_path="$repo_path/$account_type"
  repo_path="$repo_path/$repo"
  # The project is checked after checkout, not here: it belongs to the requested
  # branch, and whatever an earlier run left behind must not block this one.
  project_path="$repo_path/$RMB_ANDROID_PROJECT_DIR"
  [[ -d "$repo_path" ]] || failure "Could not find repository: $repo_path"

  cd "$repo_path" || failure "Could not enter repository: $repo_path"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || failure "Repository is not a Git work tree: $repo_path"
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || failure "Invalid branch name: $branch"

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

  cleanup_done=0
  cleanup_status=0
  trap cleanup_repo EXIT
  trap 'exit 130' HUP INT TERM
}

restore_local_properties() {
  [[ ! -f "$local_properties_backup" ]] || cp "$local_properties_backup" "$local_properties_path"
}

# Returns the checkout to a clean state on both successful and failed runs. This
# mirrors the iOS remote runners and removes Gradle outputs as well as any other
# generated, ignored files.
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
  after_cleanup
}

# Leaves the requested branch checked out, the working directory in the Android
# project, and Java and the Android SDK ready for Gradle.
prepare_android_checkout() {
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
}
