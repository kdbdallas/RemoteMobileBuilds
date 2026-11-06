#!/usr/bin/env bash
# Executed on the remote Mac by XcodeRemoteBuild.sh. It can also be copied
# there and run directly.

set -u

# SSH executes this script with a minimal non-interactive PATH on macOS. Add
# the standard package-manager and Ruby-version-manager locations before
# looking up CocoaPods, Bundler, or Fastlane helpers.
for tool_directory in /opt/homebrew/bin /usr/local/bin "$HOME/.rbenv/shims" "$HOME/.asdf/shims"; do
  [[ -d "$tool_directory" ]] && PATH="$tool_directory:$PATH"
done
export PATH

# SSH and rbenv/Fastlane can otherwise inherit an unsuitable text encoding
# while handling xcodebuild output. Fastlane requires a UTF-8 locale.
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export LC_CTYPE="en_US.UTF-8"

usage() {
  cat <<'EOF'
Usage: XcodeRemoteBuildRemote.sh --repo <repository-name> --branch <branch> --lane <lane> --shortCode <short-code> [options]

Options:
  --type <account-type>       Repository subdirectory under ~/Code.
  --repo <repository-name>    Name of the repository directory (required).
  --branch <branch>           Git branch to check out (required).
  --lane <lane>               Fastlane lane to run (required).
  --shortCode <short-code>    Passed to Fastlane as name:<short-code> (required).
  --features <features>       Optional Fastlane parameter, for example apiDev:true.
  --newApple                  Use the new Fastlane environment; defaults to old.
EOF
}

failure() {
  printf 'FAILURE: %s\n' "$1" >&2
  exit 1
}

# XcodeRemoteBuild.sh exports these from config.sh ahead of this script.
for config_name in RMB_FASTLANE_SELECTOR RMB_GDRIVE_EMAIL RMB_IOS_IPA_DIR; do
  [[ -n "${!config_name:-}" ]] || failure "$config_name is not set; run this through XcodeRemoteBuild.sh with config.sh filled in"
done

is_path_segment() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$1" != "." && "$1" != ".." ]]
}

unlock_login_keychain() {
  local keychain_password="${XCODE_REMOTE_KEYCHAIN_PASSWORD:-}"
  local login_keychain="$HOME/Library/Keychains/login.keychain-db"

  [[ -n "$keychain_password" ]] || return 0
  printf '=== Unlocking remote login Keychain ===\n'
  if ! security unlock-keychain -p "$keychain_password" "$login_keychain"; then
    unset XCODE_REMOTE_KEYCHAIN_PASSWORD
    printf 'Could not unlock the remote login Keychain.\n' >&2
    return 1
  fi
  # Do not expose the password to pod, Bundler, Fastlane, or child processes.
  unset XCODE_REMOTE_KEYCHAIN_PASSWORD
}

repo=""
account_type=""
branch=""
lane=""
short_code=""
features=""
new_apple=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)
      [[ $# -ge 2 ]] || failure "--type requires a value"
      account_type="$2"; shift 2 ;;
    --repo)
      [[ $# -ge 2 ]] || failure "--repo requires a value"
      repo="$2"; shift 2 ;;
    --branch)
      [[ $# -ge 2 ]] || failure "--branch requires a value"
      branch="$2"; shift 2 ;;
    --lane)
      [[ $# -ge 2 ]] || failure "--lane requires a value"
      lane="$2"; shift 2 ;;
    --shortCode)
      [[ $# -ge 2 ]] || failure "--shortCode requires a value"
      short_code="$2"; shift 2 ;;
    --features)
      [[ $# -ge 2 ]] || failure "--features requires a value"
      features="$2"; shift 2 ;;
    --newApple)
      new_apple=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      failure "Unknown argument: $1" ;;
  esac
done

[[ -n "$repo" ]] || failure "--repo is required"
[[ -n "$branch" ]] || failure "--branch is required"
[[ -n "$lane" ]] || failure "--lane is required"
[[ -n "$short_code" ]] || failure "--shortCode is required"
is_path_segment "$repo" || failure "--repo must be a single directory name"
[[ -z "$account_type" ]] || is_path_segment "$account_type" || failure "--type must be a single directory name"
[[ "$branch" != -* ]] || failure "--branch must not begin with a dash"

if [[ ! -d /Applications/Xcode.app || ! -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]]; then
  failure "Could not find Xcode"
fi
unlock_login_keychain || failure "Could not unlock the remote login Keychain"

repo_path="$HOME/Code"
[[ -z "$account_type" ]] || repo_path="$repo_path/$account_type"
repo_path="$repo_path/$repo"
[[ -d "$repo_path" ]] || failure "Could not find repository: $repo_path"

cd "$repo_path" || failure "Could not enter repository: $repo_path"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || failure "Repository is not a Git work tree: $repo_path"
git check-ref-format --branch "$branch" >/dev/null 2>&1 || failure "Invalid branch name: $branch"

# From this point onward, always restore the checkout and remove every
# generated, untracked, and ignored item before returning to the caller.
cleanup_done=0
cleanup_status=0
fastlane_log=""
fastlane_failure_summary=""
cleanup_repo() {
  [[ $cleanup_done -eq 0 ]] || return
  cleanup_done=1
  printf '\n=== Resetting remote repository ===\n'
  git reset --hard || cleanup_status=1
  git clean -ffdx || cleanup_status=1
  if [[ -n "$fastlane_failure_summary" ]]; then
    printf '\n=== Fastlane failure summary ===\n%s\n' "$fastlane_failure_summary"
  fi
  [[ -z "$fastlane_log" ]] || rm -f "$fastlane_log"
}
trap cleanup_repo EXIT
trap 'exit 130' HUP INT TERM

upload_browserstack_ipa() {
  local ipa_directory ipa_path renamed_ipa_path ipa_filename ticket access_key

  ipa_directory="$repo_path/$RMB_IOS_IPA_DIR"
  [[ -d "$ipa_directory" ]] || {
    printf 'Could not find IPA output directory: %s\n' "$ipa_directory" >&2
    return 1
  }

  shopt -s nullglob
  local ipa_files=( "$ipa_directory"/*.ipa )
  shopt -u nullglob
  if [[ ${#ipa_files[@]} -ne 1 ]]; then
    printf 'Expected one IPA in %s, found %d.\n' "$ipa_directory" "${#ipa_files[@]}" >&2
    return 1
  fi
  ipa_path="${ipa_files[0]}"

  ticket="${branch##*/}"
  if [[ "$branch" =~ (CM-[0-9]+) ]]; then
    ticket="${BASH_REMATCH[1]}"
  fi
  ipa_filename="$ticket-$short_code.ipa"
  renamed_ipa_path="$ipa_directory/$ipa_filename"
  if [[ "$ipa_path" != "$renamed_ipa_path" ]]; then
    mv -f "$ipa_path" "$renamed_ipa_path" || return 1
  fi

  [[ -f "$HOME/Code/BrowserStackAuth" ]] || {
    printf 'Could not find BrowserStack access-key file: %s\n' "$HOME/Code/BrowserStackAuth" >&2
    return 1
  }
  access_key="$(<"$HOME/Code/BrowserStackAuth")"
  [[ -n "$access_key" ]] || {
    printf 'BrowserStack access-key file is empty.\n' >&2
    return 1
  }
  printf '\n=== Uploading %s to BrowserStack ===\n' "$ipa_filename"
  curl --fail --show-error -u "$access_key" -X POST \
    "https://api-cloud.browserstack.com/app-live/upload" \
    -F "file=@$renamed_ipa_path"
}

select_fastlane_environment() {
  local version="$1" environment_file environment_setting

  command -v zsh >/dev/null 2>&1 || {
    printf 'Could not find zsh required for the Fastlane selector function.\n' >&2
    return 1
  }

  environment_file="$(mktemp -t xcode-remote-fastlane-env)" || return 1
  # The selector is a function in ~/.zshrc. Capture only the variables it
  # configures, then export them in this Bash process for the later Fastlane
  # invocation. Nothing from this file is printed to the build log.
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

main_status=0
main_failure=""

printf '=== Checking out branch: %s ===\n' "$branch"
printf '=== Preparing remote repository ===\n'
if ! git reset --hard; then
  main_status=1
  main_failure="Could not reset remote repository before checkout"
elif ! git clean -ffdx; then
  main_status=1
  main_failure="Could not clean remote repository before checkout"
# The leading + accepts rewritten history, so rebased or force-pushed branches
# still fetch. `checkout -B` then moves the local branch to the fetched commit;
# a plain checkout would keep building whatever the last fetch left behind.
elif ! git fetch origin "+refs/heads/$branch:refs/remotes/origin/$branch"; then
  main_status=1
  main_failure="Could not fetch branch from origin: $branch"
elif ! git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
  main_status=1
  main_failure="Could not find remote branch: origin/$branch"
elif ! git checkout -B "$branch" "origin/$branch"; then
  main_status=1
  main_failure="Could not check out branch: $branch"
elif ! git branch --set-upstream-to="origin/$branch" "$branch"; then
  main_status=1
  main_failure="Could not set upstream branch: origin/$branch"
elif ! command -v pod >/dev/null 2>&1; then
  main_status=1
  main_failure="Could not find CocoaPods (pod)"
else
  fastlane_version="old"
  [[ $new_apple -eq 0 ]] || fastlane_version="new"
  printf '\n=== Selecting Fastlane environment: %s ===\n' "$fastlane_version"
  if ! select_fastlane_environment "$fastlane_version"; then
    main_status=1
    main_failure="Could not select Fastlane environment: $fastlane_version"
  else
    printf '\n=== Running pod install ===\n'
    # Be explicit about the project directory. The Fastlane environment
    # selector runs in a subshell, but tools it configures can otherwise leave
    # CocoaPods resolving its Podfile from an unexpected directory.
    if ! pod install --project-directory="$repo_path"; then
      main_status=1
      main_failure="pod install failed"
    elif ! command -v bundle >/dev/null 2>&1; then
      main_status=1
      main_failure="Could not find Bundler (bundle)"
    elif ! bundle check >/dev/null 2>&1; then
      printf '\n=== Installing Bundler dependencies ===\n'
      if ! bundle install; then
        main_status=1
        main_failure="bundle install failed"
      fi
    fi

    if [[ $main_status -eq 0 ]]; then
      printf '\n=== Running Fastlane lane: %s ===\n' "$lane"
      # Fastlane's terminal-notifier gem bundles an Intel-only executable,
      # which fails after an otherwise successful build on Apple Silicon.
      # The Shortcut reports the final result, so safely make only that
      # nonessential desktop notification a no-op for remote builds.
      notification_shim="$(mktemp -t xcode-remote-fastlane-notification)" || {
        main_status=1
        main_failure="Could not create Fastlane notification shim"
      }
      if [[ $main_status -eq 0 ]]; then
        printf '%s\n' \
          'require "terminal-notifier"' \
          'module TerminalNotifier; def self.notify(*); true; end; end' \
          > "$notification_shim"
        fastlane_bin="$(bundle show fastlane)/bin/fastlane"
        fastlane_command=(
          bundle exec ruby
          -e 'load ENV.fetch("FASTLANE_NOTIFICATION_SHIM"); load ARGV.shift'
          "$fastlane_bin"
          "$lane"
          "name:$short_code"
        )
      fi
      # Accept one or more Fastlane options from the shortcut, for example:
      #   featureFlags:BROWSERSTACK apiDev:true
      # Splitting with `read` builds an argument array without evaluating the
      # user-provided text as shell code.
      if [[ $main_status -eq 0 && -n "$features" ]]; then
        read -r -a feature_arguments <<< "$features"
        fastlane_command+=( "${feature_arguments[@]}" )
      fi
      if [[ $main_status -eq 0 ]]; then
        fastlane_command+=( --verbose )
        fastlane_log="$(mktemp -t xcode-remote-fastlane-log)" || {
          main_status=1
          main_failure="Could not create Fastlane log"
        }
      fi
      if [[ $main_status -eq 0 ]]; then
        # Fastlane and its Xcode subprocesses must not consume the remainder
        # of this runner, which is streamed over SSH standard input.
        if ! env FASTLANE_NOTIFICATION_SHIM="$notification_shim" "${fastlane_command[@]}" >"$fastlane_log" 2>&1 </dev/null; then
          main_status=1
          main_failure="Fastlane lane failed: $lane"
          # Cleanup output otherwise hides the real reason from Shortcuts'
          # final 12-line alert. Keep the most useful Fastlane diagnostics.
          # Keep only concrete Xcode/build errors. Broad matches such as
          # "fastlane finished with errors" and Fastlane's release notes hide
          # the useful failure in Shortcuts' small alert.
          failed_fastlane_action="$(grep -E '💥' "$fastlane_log" | tail -n 1 || true)"
          # Fastlane often reports its actual provisioning or signing problem
          # as a [!] line; omit only its generic build-failure wrapper.
          fastlane_failure_summary="$(grep -E '\[!\]' "$fastlane_log" | grep -Evi 'error building (the )?application|fastlane finished with errors' | tail -n 6 || true)"
          [[ -n "$fastlane_failure_summary" ]] || fastlane_failure_summary="$(grep -Ei 'error:|fatal error:|xcodebuild: error:|command .* failed|code sign|provisioning profile|no profiles for|no signing certificate|unable to|undefined symbol|ld: |clang:|swiftc|\*\* (archive|build) failed \*\*' "$fastlane_log" | tail -n 8 || true)"
          if [[ -z "$fastlane_failure_summary" ]]; then
            # Some Xcode failures have no individually tagged error line.
            # In that case the final lines immediately before Fastlane's
            # failure marker are the best available context.
            fastlane_failure_summary="$(sed -n '1,/fastlane finished with errors/p' "$fastlane_log" | tail -n 10)"
          fi
          if [[ -n "$failed_fastlane_action" ]]; then
            fastlane_failure_summary="Fastlane failed action: $failed_fastlane_action
$fastlane_failure_summary"
          fi
        fi
        cat "$fastlane_log"
        rm -f "$fastlane_log"
        fastlane_log=""
        rm -f "$notification_shim"
      fi
      if [[ $main_status -eq 0 && "$lane" == "createAppForBrowserStack" ]]; then
        upload_browserstack_ipa || {
          main_status=1
          main_failure="Could not upload the IPA to BrowserStack"
        }
      fi
    fi
  fi
fi

cleanup_repo
trap - EXIT HUP INT TERM

if [[ $cleanup_status -ne 0 ]]; then
  failure "Could not fully reset repository after the Fastlane run"
fi
if [[ $main_status -ne 0 ]]; then
  failure "$main_failure"
fi

printf 'SUCCESS: Fastlane lane %s completed successfully.\n' "$lane"
