# RemoteMobileBuilds local configuration.
#
# Copy this file to config.sh in the same folder and fill in your values:
#   cp config.example.sh config.sh
# config.sh is ignored by Git, so these values stay on your machine.

# --- Sent to the remote runners by XcodeRemoteBuild.sh ---

# SSH host that receives finished builds and test reports. The build Mac must
# be able to reach it with key-based SSH.
RMB_BUILDS_HOST="builds-host"
# Absolute folder on RMB_BUILDS_HOST where builds and reports are saved.
RMB_BUILDS_DIR="/Users/you/Builds"
# zsh function in the build Mac's ~/.zshrc that exports the Fastlane
# environment. It is called as:
#   <function> --version <old|new> --xcode /Applications/Xcode.app --gdriveemail <email>
RMB_FASTLANE_SELECTOR="use-fastlane-env"
# Google Drive account passed to the Fastlane selector function.
RMB_GDRIVE_EMAIL="you@example.com"

# --- Used by the Shortcut (Shortcut/Type-RunShellScript.sh) ---

# SSH hosts that run iOS and Android jobs.
RMB_IOS_HOST="ios-build-mac"
RMB_ANDROID_HOST="android-build-mac"
# Repository subdirectory under ~/Code on the build Macs (may be empty).
RMB_REPO_TYPE="work"
# Repository directory names on the build Macs.
RMB_IOS_REPO="ios-app"
RMB_ANDROID_REPO="android-app"
# Default short codes offered in the Shortcut's dialogs.
RMB_IOS_SHORTCODE_DEFAULT="MyApp"
RMB_ANDROID_SHORTCODE_DEFAULT="CONTAINER"
