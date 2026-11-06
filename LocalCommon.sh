# shellcheck shell=bash
# Shared by the local entry points, XcodeRemoteBuild.sh and AndroidRemoteBuild.sh.
# Each one sets script_dir before sourcing this file, and sets remote_files to
# the files to stream, in order.

fail() {
  printf 'FAILURE: %s\n' "$1" >&2
  exit 1
}

is_path_segment() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$1" != "." && "$1" != ".." ]]
}

require_remote_files() {
  local remote_file
  for remote_file in "${remote_files[@]}"; do
    [[ -f "$remote_file" ]] || fail "Could not find remote runner: $remote_file"
  done
}

# Loads config.sh, checks the named settings, and adds an export line for each
# one to remote_preamble. The preamble goes ahead of the streamed script, so
# nothing machine-specific is stored in the runners themselves.
load_config() {
  local config_file="$script_dir/config.sh" config_name
  [[ -f "$config_file" ]] || fail "Could not find $config_file (copy config.example.sh to config.sh and fill it in)"
  # shellcheck source=config.example.sh
  source "$config_file" || fail "Could not load $config_file"
  remote_preamble=""
  for config_name in "$@"; do
    [[ -n "${!config_name:-}" ]] || fail "$config_name is not set in $config_file"
    [[ "${!config_name}" != *$'\n'* ]] || fail "$config_name must not contain a newline"
    add_to_preamble "$config_name" "${!config_name}"
  done
}

add_to_preamble() {
  local config_line
  printf -v config_line 'export %s=%q\n' "$1" "$2"
  remote_preamble+="$config_line"
}

# The runner is sent through stdin, so it need not be preinstalled on the host.
# Bash normally reads a streamed script as it runs, so any child that reads
# stdin (ssh, Gradle, pod) would swallow the rest of the runner, and the run
# would then end with status 0 and no result. Sending it as one block makes
# Bash parse all of it first and gives every child an empty stdin. Do not use
# `exec </dev/null` inside a runner instead: it ends a streamed script at once.
stream_runner() {
  local remote_file
  printf '{\n'
  for remote_file in "${remote_files[@]}"; do
    cat "$remote_file"
    printf '\n'
  done
  printf '} </dev/null\n'
}

# ssh joins command arguments into text for the remote login shell. Quote each
# argument before that handoff so branch names such as
# "feature/APP-42-Q&A-Example" arrive intact.
quote_remote_arguments() {
  local remote_argument escaped_argument
  quoted_remote_arguments=""
  for remote_argument in "$@"; do
    printf -v escaped_argument '%q' "$remote_argument"
    quoted_remote_arguments+=" $escaped_argument"
  done
}

# Status 3 means the result was delivered and only the reset failed. The runner
# has already said so, and a FAILURE line here would invite a repeat run.
finish_remote_run() {
  local ssh_status="$1"
  if [[ $ssh_status -ne 0 && $ssh_status -ne 3 ]]; then
    printf 'FAILURE: Remote run failed (SSH or the remote runner exited with status %d).\n' "$ssh_status" >&2
  fi
  exit "$ssh_status"
}
