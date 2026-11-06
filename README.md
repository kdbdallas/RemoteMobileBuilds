# RemoteMobileBuilds

Scripts and a macOS Shortcut for building or testing a mobile app (iOS and Android) on a remote Mac. You pick the platform, branch, and options in a few dialogs. The work then runs over SSH on a build Mac, and you get a success or failure alert when it finishes.

The build machine needs no installed copy of these scripts. The local entry point streams the platform-specific runner to the remote host over SSH standard input and runs it there with `bash -s`.

## How it works

```
Shortcut (Run Shell Script)
  └─ XcodeRemoteBuild.sh <ssh-host> [options]        (local)
       └─ ssh <host> bash -s -- ... < runner          (remote)
            ├─ XcodeRemoteBuildRemote.sh   iOS Fastlane build
            ├─ IOSUnitTestRemote.sh        iOS unit tests
            └─ AndroidRemoteBuildRemote.sh Android Gradle build
```

Each remote runner:

1. Resolves the repository at `~/Code/<type>/<repo>`, or `~/Code/<repo>` when `--type` is omitted.
2. Resets and cleans the checkout (`git reset --hard`, `git clean -ffdx`), fetches the requested branch from `origin`, then checks it out.
3. Runs the build or tests.
4. Delivers the result: it uploads the build to BrowserStack, publishes it to Google Play, or copies it to the build folder.
5. Resets and cleans the checkout again. A trap does this whether the run succeeds or fails.

Each runner ends with a single `SUCCESS: ...` or `FAILURE: ...` line, which the Shortcut uses for its alert.

> **Warning:** Every run discards uncommitted changes and untracked or ignored files in the remote checkout. Use a checkout on the build Mac that is dedicated to these builds.

## Files

| File | Runs on | Purpose |
| --- | --- | --- |
| `XcodeRemoteBuild.sh` | Local Mac | Entry point. Validates arguments, picks the runner, and runs it on the SSH host. |
| `XcodeRemoteBuildRemote.sh` | Remote Mac | iOS build: `pod install`, Bundler, then a Fastlane lane. Can upload the IPA to BrowserStack. |
| `IOSUnitTestRemote.sh` | Remote Mac | iOS unit tests through `fastlane ios test`. Copies the HTML report back. |
| `AndroidRemoteBuildRemote.sh` | Remote Mac | Android build with the Gradle wrapper. Produces an APK or AAB. |
| `Shortcut/Type-RunShellScript.sh` | Local Mac | Script body for the Shortcut's **Run Shell Script** action. Collects options through dialogs and shows the result. |
| `config.example.sh` | Local Mac | Template for `config.sh`, which holds your machine-specific settings. See [Configuration](#configuration). |

## Usage

```bash
./XcodeRemoteBuild.sh <ssh-host> --repo <repository-name> --branch <branch> [options]
```

| Option | Applies to | Description |
| --- | --- | --- |
| `--type <name>` | All | Subdirectory under `~/Code` on the remote Mac, such as `work` or `personal`. |
| `--repo <name>` | All | Repository directory name. Required. |
| `--branch <branch>` | All | Branch to check out. Required. |
| `--platform <ios\|android>` | Builds | Defaults to `ios`. |
| `--shortCode <code>` | Builds | App short code. iOS passes it to Fastlane as `name:<code>`. Android uses it as the Gradle flavor. Required for builds. |
| `--lane <lane>` | iOS build | Fastlane lane to run. Required for iOS builds. |
| `--newApple` | iOS build | Use the "new" Fastlane environment. The default is "old". |
| `--features <text>` | Builds | iOS: extra Fastlane options, such as `featureFlags:BROWSERSTACK apiDev:true`. Android: space-separated Gradle properties without `-P`. |
| `--buildType <type>` | Android | `Release`, `Debug`, `BrowserStack`, or `Play Store`. |
| `--buildPackage <type>` | Android | `APK` or `Bundle` (AAB). |
| `--bundleId <id>` | Android Play Store | Android application ID to publish. Required with `--buildType 'Play Store'`; the package must be `Bundle`. |
| `--devApis <true\|false>` | Android BrowserStack | Sets `-PAPI_DEV_ENABLED`. |
| `--unitTests` | iOS tests | Run the Fastlane test lane instead of a build. |
| `--devices <Latest\|All>` | iOS tests | Optional device selection passed to the test lane. |

### Examples

iOS BrowserStack build:

```bash
./XcodeRemoteBuild.sh ios-build-mac --type work --repo ios-app \
  --branch feature/CM-123-Example --lane createAppForBrowserStack \
  --shortCode MyApp --features "apiDev:true"
```

iOS unit tests on the latest simulators:

```bash
./XcodeRemoteBuild.sh ios-build-mac --unitTests --type work --repo ios-app \
  --branch develop --devices Latest
```

Android release bundle:

```bash
./XcodeRemoteBuild.sh android-build-mac --platform android --type work \
  --repo android-app --branch develop \
  --buildType Release --buildPackage Bundle --shortCode MyFlavor
```

## Platform details

### iOS builds (`XcodeRemoteBuildRemote.sh`)

- Requires Xcode at `/Applications/Xcode.app`, plus CocoaPods and Bundler on the remote Mac.
- Adds Homebrew, rbenv, and asdf shim directories to `PATH` and forces a UTF-8 locale. A non-interactive SSH session doesn't get the user's shell profile.
- Loads Fastlane credentials and settings by calling the zsh function named in `RMB_FASTLANE_SELECTOR` from the remote `~/.zshrc`. The runner imports only the variables it needs and doesn't print them.
- Runs `bundle install` only when `bundle check` fails.
- Disables Fastlane's `terminal-notifier` desktop notification for the run. Its bundled binary is Intel-only and fails on Apple Silicon.
- For the `createAppForBrowserStack` lane, renames the IPA in `<repo>/$RMB_IOS_IPA_DIR/` to `<ticket>-<shortCode>.ipa` and uploads it to BrowserStack App Live.

### iOS unit tests (`IOSUnitTestRemote.sh`)

- Fetches the branch from `origin` and resets the local branch to match it.
- Sets `DEVELOPER_DIR` to the full Xcode installation so `simctl` is available.
- Runs `bundle exec fastlane ios test` with standard input redirected from `/dev/null`. This stops test tools from consuming the rest of the streamed script.
- Copies `fastlane/test_output/report.html` to a timestamped folder on the build-folder host, then checks that the copied file is the same size. If a run fails but still produces a report, the report is delivered anyway; the test failures are recorded in the report.

### Android builds (`AndroidRemoteBuildRemote.sh`)

- Builds the Gradle project in `<repo>/$RMB_ANDROID_PROJECT_DIR`.
- Preserves the ignored `local.properties` file across cleanup so machine-local
  settings such as `KEYSTORE_DIR` remain available for later builds.
- Selects Java 17 or 21. It tries `JAVA_HOME`, then `/usr/libexec/java_home`, then the JBR bundled with Android Studio, then Homebrew, jenv, and SDKMAN installs.
- Runs `assemble<shortCode><buildType>` for APKs or `bundle<shortCode><buildType>` for AABs. `BrowserStack` builds run `assemble<shortCode>Debug -Pbrowserstack=true`. Play Store builds run `bundle<shortCode>Release`.
- Picks the newest matching artifact under `app/build/outputs` and renames it to `<ticket>-<shortCode>.<apk|aab>`.
- Uploads `BrowserStack` builds to BrowserStack, publishes Play Store bundles with `tools/play_release.py`, and copies other builds to the build folder. The Shortcut alert includes the publisher result.
- Play Store builds require `tools/play_release.py` on the selected Android-app branch and a service-account key path configured through `RMB_ANDROID_PLAY_SERVICE_ACCOUNT_JSON`; the key itself remains on the Android build Mac.

### Artifact naming

When a branch name contains a Jira key such as `CM-1234`, the key is the ticket part of the file name. Otherwise, Android uses the branch name with `/` replaced by `-`, and iOS uses the last path segment of the branch.

## Configuration

Machine-specific settings, such as host names, folders, repository names and your email address, are kept in `config.sh`, not in the scripts. `config.sh` is listed in `.gitignore`, so it stays on your machine. To create it:

```bash
cp config.example.sh config.sh
```

Then edit the values:

| Setting | Used by | Description |
| --- | --- | --- |
| `RMB_BUILDS_HOST` | Remote runners | SSH host that receives finished builds and test reports. |
| `RMB_BUILDS_DIR` | Remote runners | Absolute folder on that host where builds and reports are saved. |
| `RMB_FASTLANE_SELECTOR` | iOS runners | zsh function in the build Mac's `~/.zshrc` that exports the Fastlane environment. It is called as `<function> --version <old\|new> --xcode /Applications/Xcode.app --gdriveemail <email>`. |
| `RMB_GDRIVE_EMAIL` | iOS runners | Google Drive account passed to that function. |
| `RMB_IOS_IPA_DIR` | iOS build runner | Folder inside the iOS repository where the BrowserStack lane writes its IPA. |
| `RMB_ANDROID_PROJECT_DIR` | Android runners | Folder inside the Android repository that contains the Gradle project. |
| `RMB_ANDROID_PLAY_SERVICE_ACCOUNT_JSON` | Android Play Store builds | Absolute path on the Android build Mac to the Play Developer API service-account JSON key. |
| `RMB_IOS_HOST`, `RMB_ANDROID_HOST` | Shortcut | SSH hosts that run iOS and Android jobs. |
| `RMB_REPO_TYPE` | Shortcut | Subdirectory under `~/Code` on the build Macs. Leave it empty if there is none. |
| `RMB_IOS_REPO`, `RMB_ANDROID_REPO` | Shortcut | Repository directory names on the build Macs. |
| `RMB_IOS_SHORTCODE_DEFAULT`, `RMB_ANDROID_SHORTCODE_DEFAULT` | Shortcut | Default short codes shown in the Shortcut's dialogs. |

`XcodeRemoteBuild.sh` loads `config.sh` from its own folder. It adds `export` lines for the required remote settings, plus the optional Play service-account key path when configured, to the start of the script it streams over SSH. The remote runners stop with a clear error if a required setting is missing.

## Setup

### Local Mac

1. Clone this repository and create `config.sh` as described in [Configuration](#configuration).
2. Configure key-based SSH access to the build hosts in `~/.ssh/config`.
3. Create a Shortcut with a single **Run Shell Script** action (shell: `bash`) and paste in the contents of `Shortcut/Type-RunShellScript.sh`. The script expects the repository at `~/Code/personal/RemoteMobileBuilds`. If you cloned it somewhere else, change `RMB_DIR` at the top of the script.

### Remote (build) Mac

- Checkouts of the repositories under `~/Code/<type>/`.
- iOS: Xcode, CocoaPods, Bundler, and the Fastlane selector function (`RMB_FASTLANE_SELECTOR`) in `~/.zshrc`.
- Android: a JDK 17 or 21, and an executable `gradlew` in `<repo>/$RMB_ANDROID_PROJECT_DIR/`.
- BrowserStack uploads: a file at `~/Code/BrowserStackAuth` containing `username:access_key`.
- Delivery to the build folder: SSH access from the build Mac to `RMB_BUILDS_HOST`. Android builds are copied to `RMB_BUILDS_DIR`. Test reports go to `RMB_BUILDS_DIR/<timestamp>/<branch>/report.html`.

### Code signing and the Keychain

iOS signing often needs the remote login Keychain unlocked. To unlock it, set `XCODE_REMOTE_KEYCHAIN_PASSWORD` in the local environment before running `XcodeRemoteBuild.sh`. The password is sent as the first line of the SSH standard input. It never appears in the SSH command line or in process arguments. The runner unsets it after the unlock, so Fastlane and other child processes never see it.

The Shortcut reads this password from the local login Keychain, so it is never stored in the script. Store it once in Terminal; `-w` at the end makes `security` prompt for the password:

```bash
security add-generic-password -a "$USER" -s XcodeRemoteBuildKeychain -w
```

To change it later, add `-U` to update the existing item. If the item is missing, iOS builds from the Shortcut stop with an alert. The first time the Shortcut reads the item, macOS may ask you to allow access; choose **Always Allow**.

## The Shortcut

When you run it, the Shortcut asks for:

1. The platform: iOS or Android.
2. Whether to run unit tests. For iOS, it then asks which devices to use.
3. For iOS builds: the Apple account (Old or New), the branch, the lane (`createAppForBrowserStack`, `updateAppForStore`, or `createLaunchImages`), the short code, and optional feature flags.
4. For Android builds: the branch, the build type, the package type, the Dev APIs setting (BrowserStack builds only), the short code, and optional Gradle feature flags. Play Store builds require Bundle, then ask for a Bundle ID defaulting to `com.goeshow.<shortCode>` and publish the completed release bundle to production.

On success, it shows the `SUCCESS:` and `REPORT:` lines; Play Store builds also show the publisher result. On failure, it shows a critical alert with the lane or build type, the branch, and the last 12 lines of output.
