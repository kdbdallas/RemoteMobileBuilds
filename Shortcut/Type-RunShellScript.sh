# Folder containing this repository. Change this if you cloned it elsewhere.
RMB_DIR="$HOME/Code/personal/RemoteMobileBuilds"
if ! source "$RMB_DIR/config.sh"; then
  osascript - "$RMB_DIR/config.sh" <<'APPLESCRIPT'
on run argv
  display alert "Failure" message ("Could not load " & item 1 of argv & ". Copy config.example.sh to config.sh and fill it in.") as critical
end run
APPLESCRIPT
  exit 1
fi
buildScript="$RMB_DIR/XcodeRemoteBuild.sh"
typeArguments=()
[[ -n "${RMB_REPO_TYPE:-}" ]] && typeArguments=(--type "$RMB_REPO_TYPE")

platform=$(osascript -e 'choose from list {"iOS", "Android"} with prompt "Build Platform" default items {"iOS"}') || exit 0
[[ "$platform" == "false" ]] && exit 0

features=""
unitTests=$(osascript -e 'button returned of (display dialog "Running Unit Tests" buttons {"Yes", "No"} default button "No")') || exit 0
if [[ "$unitTests" == "Yes" ]]; then
  lane="Unit Tests"
  if [[ "$platform" == "iOS" ]]; then
    devices=$(osascript -e 'choose from list {"Not Specified", "Latest", "All"} with prompt "Devices to Run" default items {"Not Specified"}') || exit 0
    [[ "$devices" == "false" ]] && exit 0
    [[ "$devices" == "Not Specified" ]] && devices=""
    branch=$(osascript -e 'text returned of (display dialog "Branch" default answer "" buttons {"Cancel", "Continue"} default button "Continue")') || exit 0
    [[ "$branch" == "Cancel" ]] && exit 0
    buildCommand=(
      "$buildScript"
      "$RMB_IOS_HOST"
      --unitTests
      "${typeArguments[@]}"
      --repo "$RMB_IOS_REPO"
      --branch "$branch"
    )
    [[ -n "$devices" ]] && buildCommand+=(--devices "$devices")
  else
    shortCode=$(osascript - "${RMB_ANDROID_SHORTCODE_DEFAULT:-}" <<'APPLESCRIPT'
on run argv
  text returned of (display dialog "Client Short Code" default answer (item 1 of argv) buttons {"Cancel", "Continue"} default button "Continue")
end run
APPLESCRIPT
) || exit 0
    [[ "$shortCode" == "Cancel" ]] && exit 0
    branch=$(osascript -e 'text returned of (display dialog "Branch" default answer "" buttons {"Cancel", "Continue"} default button "Continue")') || exit 0
    [[ "$branch" == "Cancel" ]] && exit 0
    buildCommand=(
      "$buildScript"
      "$RMB_ANDROID_HOST"
      --unitTests
      --platform android
      "${typeArguments[@]}"
      --repo "$RMB_ANDROID_REPO"
      --branch "$branch"
      --shortCode "$shortCode"
    )
  fi
else
features=""
if [[ "$platform" == "iOS" ]]; then
  appleAccount=$(osascript -e 'button returned of (display dialog "Apple Account" buttons {"Old", "New"} default button "Old")') || exit 0
  branch=$(osascript -e 'text returned of (display dialog "Branch" default answer "" buttons {"Cancel", "Continue"} default button "Continue")') || exit 0
[[ "$branch" == "Cancel" ]] && exit 0
  lane=$(osascript -e 'choose from list {"createAppForBrowserStack", "updateAppForStore", "createLaunchImages"} with prompt "Lane" default items {"createAppForBrowserStack"}') || exit 0
  [[ "$lane" == "false" ]] && exit 0
  shortCode=$(osascript - "${RMB_IOS_SHORTCODE_DEFAULT:-}" <<'APPLESCRIPT'
on run argv
  text returned of (display dialog "ShortCode" default answer (item 1 of argv) buttons {"Cancel", "Continue"} default button "Continue")
end run
APPLESCRIPT
) || exit 0
  [[ "$shortCode" == "Cancel" ]] && exit 0
  features=$(osascript -e 'text returned of (display dialog "Feature Flags (optional; e.g. featureFlags:BROWSERSTACK apiDev:true)" default answer "" buttons {"Cancel", "Continue"} default button "Continue")') || exit 0
  [[ "$features" == "Cancel" ]] && exit 0

  XCODE_REMOTE_KEYCHAIN_PASSWORD=$(security find-generic-password -a "$USER" -s XcodeRemoteBuildKeychain -w 2>/dev/null) || {
    osascript -e 'display alert "Failure" message "Could not read the remote Keychain password from the local Keychain (service: XcodeRemoteBuildKeychain)." as critical'
    exit 1
  }
  export XCODE_REMOTE_KEYCHAIN_PASSWORD
  buildCommand=(
    "$buildScript"
    "$RMB_IOS_HOST"
    "${typeArguments[@]}"
    --repo "$RMB_IOS_REPO"
    --branch "$branch"
    --lane "$lane"
    --shortCode "$shortCode"
  )
  [[ "$appleAccount" == "New" ]] && buildCommand+=(--newApple)
else
  branch=$(osascript -e 'text returned of (display dialog "Branch" default answer "" buttons {"Cancel", "Continue"} default button "Continue")') || exit 0
[[ "$branch" == "Cancel" ]] && exit 0
  buildType=$(osascript -e 'choose from list {"Release", "Debug", "BrowserStack"} with prompt "Build Type" default items {"Release"}') || exit 0
  [[ "$buildType" == "false" ]] && exit 0
  buildPackage=$(osascript -e 'choose from list {"APK", "Bundle"} with prompt "Build Package" default items {"APK"}') || exit 0
  [[ "$buildPackage" == "false" ]] && exit 0
  devApis=""
  if [[ "$buildType" == "BrowserStack" ]]; then
    devApis=$(osascript -e 'button returned of (display dialog "Dev APIs Enabled" buttons {"true", "false"} default button "false")') || exit 0
  fi
  shortCode=$(osascript - "${RMB_ANDROID_SHORTCODE_DEFAULT:-}" <<'APPLESCRIPT'
on run argv
  text returned of (display dialog "ShortCode" default answer (item 1 of argv) buttons {"Cancel", "Continue"} default button "Continue")
end run
APPLESCRIPT
) || exit 0
  [[ "$shortCode" == "Cancel" ]] && exit 0
  features=$(osascript -e 'text returned of (display dialog "Other Feature Flags (optional; space-separated, without -P)" default answer "" buttons {"Cancel", "Continue"} default button "Continue")') || exit 0
  [[ "$features" == "Cancel" ]] && exit 0

  buildCommand=(
    "$buildScript"
    "$RMB_ANDROID_HOST"
    --platform android
    "${typeArguments[@]}"
    --repo "$RMB_ANDROID_REPO"
    --branch "$branch"
    --buildType "$buildType"
    --buildPackage "$buildPackage"
    --shortCode "$shortCode"
  )
  [[ "$buildType" == "BrowserStack" ]] && buildCommand+=(--devApis "$devApis")
fi
fi
[[ -n "$features" ]] && buildCommand+=(--features "$features")

output=$("${buildCommand[@]}" 2>&1)
exitStatus=$?

if (( exitStatus == 0 )); then
  if [[ "$unitTests" == "Yes" ]]; then
    successMessage=$(printf 'SUCCESS: Tests Ran\nReport saved to the timestamped Builds folder.')
  else
    successMessage=$(printf '%s\n' "$output" | grep -E '^(SUCCESS:|REPORT:)' | tail -n 2)
    [[ -n "$successMessage" ]] || successMessage=$(printf '%s\n' "$output" | tail -n 12)
  fi
  osascript - "$successMessage" <<'APPLESCRIPT'
on run argv
  display alert "Success" message (item 1 of argv)
end run
APPLESCRIPT
  printf '%s\n' "$output"
  exit 0
fi

label="$platform"
if [[ "$unitTests" == "Yes" ]]; then
  label="Lane: Unit Tests"
elif [[ "$platform" == "iOS" ]]; then
  label="Lane: $lane"
else
  label="Build Type: $buildType"
fi
debug=$(printf '%s\nBranch: %s\n\nLast 12 lines of output:\n%s\n' "$label" "$branch" "$(printf '%s\n' "$output" | tail -n 12)")
osascript - "$debug" <<'APPLESCRIPT'
on run argv
  display alert "Failure" message (item 1 of argv) as critical
end run
APPLESCRIPT
printf '%s\n' "$debug"
exit "$exitStatus"
