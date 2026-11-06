# RemoteMobileBuilds

Scripts and a macOS Shortcut for building or testing a mobile app (iOS and Android) on a remote Mac. You pick the platform, branch, and options in a few dialogs. The work then runs over SSH on a build Mac, and you get a success or failure alert when it finishes.

The build machine needs no installed copy of these scripts. The local entry point streams the platform-specific runner to the remote host over SSH standard input and runs it there with `bash -s`. The runner is sent as a single block with its standard input redirected from `/dev/null`, so a command that reads standard input can't consume the rest of the script.

## How it works

```
Shortcut (Run Shell Script)
  └─ XcodeRemoteBuild.sh <ssh-host> [options]        (local)
       └─ ssh <host> bash -s -- ... < runner          (remote)
            ├─ XcodeRemoteBuildRemote.sh   iOS Fastlane build
            ├─ IOSUnitTestRemote.sh        iOS unit tests
            ├─ AndroidRemoteBuildRemote.sh Android Gradle build
            └─ AndroidUnitTestRemote.sh    Android unit tests
```

Each remote runner:

1. Resolves the repository at `~/Code/<type>/<repo>`, or `~/Code/<repo>` when `--type` is omitted.
2. Resets and cleans the checkout (`git reset --hard`, `git clean -ffdx`), then fetches the requested branch from `origin` and moves the local branch to the fetched commit, so rebased or force-pushed branches build correctly.
3. Runs the build or tests.
4. Delivers the result: it uploads the build to BrowserStack, publishes it to Google Play, copies it to the build folder, or copies the test report there. The runner has no delivery step for iOS lanes other than `createAppForBrowserStack`.
5. Resets and cleans the checkout again. A trap does this whether the run succeeds or fails.

Each runner reports its result on a `SUCCESS: ...` or `FAILURE: ...` line and through its exit status, which decides the Shortcut's alert. Test runners also print a `REPORT:` line with the report's location, and Play Store builds print a `PLAY_STORE_RESULT:` line with the publisher's response.

> **Warning:** Every run discards uncommitted changes and untracked or ignored files in the remote checkout. Use a checkout on the build Mac that is dedicated to these builds.

## Files

| File | Runs on | Purpose |
| --- | --- | --- |
| `XcodeRemoteBuild.sh` | Local Mac | Entry point. Validates arguments, picks the runner, and runs it on the SSH host. |
| `XcodeRemoteBuildRemote.sh` | Remote Mac | iOS build: `pod install`, Bundler, then a Fastlane lane. Can upload the IPA to BrowserStack. |
| `IOSUnitTestRemote.sh` | Remote Mac | iOS unit tests through `fastlane ios test`. Copies the HTML reports to the build folder. |
| `AndroidRemoteBuildRemote.sh` | Remote Mac | Android build with the Gradle wrapper. Produces an APK or AAB. |
| `AndroidUnitTestRemote.sh` | Remote Mac | Android unit tests with the Gradle wrapper. Copies the HTML reports to the build folder. |
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
| `--platform <ios\|android>` | All | Defaults to `ios`. |
| `--shortCode <code>` | Builds, Android tests | App short code. iOS passes it to Fastlane as `name:<code>`. Android uses it as the Gradle flavor. Required for builds and Android unit tests. |
| `--lane <lane>` | iOS build | Fastlane lane to run. Required for iOS builds. |
| `--newApple` | iOS build | Use the "new" Fastlane environment. The default is "old". |
| `--features <text>` | Builds | iOS: extra Fastlane options, such as `featureFlags:BROWSERSTACK apiDev:true`. Android: space-separated Gradle properties without `-P`. |
| `--buildType <type>` | Android build | `Release`, `Debug`, `BrowserStack`, or `Play Store`. Required for Android builds. |
| `--buildPackage <type>` | Android build | `APK` or `Bundle` (AAB). Required for Android builds. |
| `--bundleId <id>` | Android Play Store | Android application ID to publish. Required with `--buildType 'Play Store'`; the package must be `Bundle`. |
| `--devApis <true\|false>` | Android BrowserStack | Sets `-PAPI_DEV_ENABLED`. Defaults to `false`. |
| `--unitTests` | Tests | Run the selected platform's unit tests instead of a build. |
| `--devices <Latest\|All>` | iOS tests | Optional device selection passed to the test lane. |
| `-h`, `--help` | All | Show the help text. |

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

Android unit tests:

```bash
./XcodeRemoteBuild.sh android-build-mac --unitTests --platform android --type work \
  --repo android-app --branch develop --shortCode MyFlavor
```

## Platform details

### iOS builds (`XcodeRemoteBuildRemote.sh`)

- Requires Xcode at `/Applications/Xcode.app`, plus CocoaPods and Bundler on the remote Mac.
- Adds Homebrew, rbenv, and asdf shim directories to `PATH` and forces a UTF-8 locale. A non-interactive SSH session doesn't get the user's shell profile.
- Loads Fastlane credentials and settings by calling the zsh function named in `RMB_FASTLANE_SELECTOR` from the remote `~/.zshrc`. The runner imports only the variables it needs and doesn't print them.
- Runs `bundle install` only when `bundle check` fails.
- Disables Fastlane's `terminal-notifier` desktop notification for the run. Its bundled binary is Intel-only and fails on Apple Silicon.
- For the `createAppForBrowserStack` lane, renames the IPA in `<repo>/$RMB_IOS_IPA_DIR/` to `<ticket>-<shortCode>.ipa` and uploads it to BrowserStack App Live. The folder must contain exactly one IPA.
- When Fastlane fails, prints a short summary after cleanup so the cause appears in the Shortcut's 12-line alert. The summary names the failed Fastlane action, followed by the most specific `[!]` or Xcode error lines.

### iOS unit tests (`IOSUnitTestRemote.sh`)

- Fetches the branch from `origin` and resets the local branch to match it.
- Always selects the "old" Fastlane environment. `--newApple` has no effect on test runs.
- Sets `DEVELOPER_DIR` to the full Xcode installation so `simctl` is available.
- Runs `bundle exec fastlane ios test` with standard input redirected from `/dev/null`. This stops test tools from consuming the rest of the streamed script.
- Copies the whole `fastlane/test_output` folder to `RMB_BUILDS_DIR/iOS/<timestamp>/<branch>/`, which keeps the links from `report.html` to each device's report working. It then checks that the number of HTML files matches and that `report.html` isn't empty.
- If tests fail but a report exists, the report is delivered and the run still ends with `SUCCESS: Tests Ran`. The test failures are recorded in the report. If the run stops before the normal copy step, the cleanup trap tries to copy the report first.
- If there's no report, the run fails and prints a short failure summary after cleanup.

### Android builds (`AndroidRemoteBuildRemote.sh`)

- Builds the Gradle project in `<repo>/$RMB_ANDROID_PROJECT_DIR`.
- Preserves the ignored `local.properties` file across both cleans so machine-local
  settings such as `KEYSTORE_DIR` remain available for this build and later runs.
  If the restore fails, the run prints where the backup copy is.
- Selects Java 17 or 21. It tries `JAVA_HOME`, then `/usr/libexec/java_home`, then the JBR bundled with Android Studio, then Homebrew, jenv, and SDKMAN installs.
- Finds the Android SDK through `ANDROID_HOME`, then `ANDROID_SDK_ROOT`, then `~/Library/Android/sdk`.
- Runs `assemble<shortCode><buildType>` for APKs or `bundle<shortCode><buildType>` for AABs. `BrowserStack` builds run `assemble<shortCode>Debug -Pbrowserstack=true` and always produce an APK, whatever `--buildPackage` says. Play Store builds run `bundle<shortCode>Release`.
- When Gradle fails, prints its `What went wrong` block after cleanup so the cause appears in the Shortcut's 12-line alert.
- Fails if the checkout can't be reset or `local.properties` can't be restored after the build. The build has already been delivered by then, and the `FAILURE:` line says so.
- Picks the newest artifact under `app/build/outputs` whose path contains the short code, and renames it to `<ticket>-<shortCode>.<apk|aab>`.
- Uploads `BrowserStack` builds to BrowserStack, publishes Play Store bundles to the production track with `tools/play_release.py`, and copies other builds to the build folder. The Shortcut alert includes the publisher result.
- Play Store builds require `tools/play_release.py` on the selected Android-app branch and a service-account key path configured through `RMB_ANDROID_PLAY_SERVICE_ACCOUNT_JSON`; the key itself remains on the Android build Mac.

### Android unit tests (`AndroidUnitTestRemote.sh`)

- Runs `./gradlew test<shortCode>DebugUnitTest` in `<repo>/$RMB_ANDROID_PROJECT_DIR`.
- Finds Java and the Android SDK the same way as Android builds, except that it doesn't look for jenv or SDKMAN installs.
- Copies `app/build/reports/tests/test<shortCode>DebugUnitTest` to `RMB_BUILDS_DIR/Android/<timestamp>/<branch>/`. It then checks that the number of HTML files matches and that `index.html` isn't empty.
- If tests fail but a report exists, the report is delivered and the run still ends with `SUCCESS: Tests Ran`. The test failures are recorded in the report.
- If there's no report, the run fails and prints a short failure summary after cleanup.
- Preserves `local.properties` across both cleans, the same way as Android builds.

### Artifact naming

When a branch name contains a `CM-` Jira key such as `CM-1234`, the key is the ticket part of the file name. Otherwise, iOS and Android both use the last path segment of the branch, so `feature/login` becomes `login`.

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

`XcodeRemoteBuild.sh` loads `config.sh` from its own folder. Each run requires only the settings its runner uses, so an Android-only setup can leave the iOS settings empty:

| Run | Required settings |
| --- | --- |
| iOS build | `RMB_FASTLANE_SELECTOR`, `RMB_GDRIVE_EMAIL`, `RMB_IOS_IPA_DIR` |
| iOS unit tests | `RMB_BUILDS_HOST`, `RMB_BUILDS_DIR`, `RMB_FASTLANE_SELECTOR`, `RMB_GDRIVE_EMAIL` |
| Android build or unit tests | `RMB_BUILDS_HOST`, `RMB_BUILDS_DIR`, `RMB_ANDROID_PROJECT_DIR` |

It adds `export` lines for those settings to the start of the script it streams over SSH, and exports the Play service-account key path as `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` when configured. Play Store builds stop with an error if that path is empty. The remote runners also check the settings they need when run directly.

## Setup

### Local Mac

1. Clone this repository and create `config.sh` as described in [Configuration](#configuration).
2. Configure key-based SSH access to the build hosts in `~/.ssh/config`.
3. Create a Shortcut with a single **Run Shell Script** action (shell: `bash`) and paste in the contents of `Shortcut/Type-RunShellScript.sh`. The script expects the repository at `~/Code/personal/RemoteMobileBuilds`. If you cloned it somewhere else, change `RMB_DIR` at the top of the script.

### Remote (build) Mac

- Checkouts of the repositories under `~/Code/<type>/`.
- iOS: Xcode, CocoaPods, Bundler, and the Fastlane selector function (`RMB_FASTLANE_SELECTOR`) in `~/.zshrc`.
- Android: a JDK 17 or 21, the Android SDK, and an executable `gradlew` in `<repo>/$RMB_ANDROID_PROJECT_DIR/`.
- Play Store builds: `python3`, plus the service-account key at the path in `RMB_ANDROID_PLAY_SERVICE_ACCOUNT_JSON`.
- BrowserStack uploads: a file at `~/Code/BrowserStackAuth` containing `username:access_key`.
- Delivery to the build folder: SSH access from the build Mac to `RMB_BUILDS_HOST`. Android builds are copied to `RMB_BUILDS_DIR`, which must already exist. iOS test reports go to `RMB_BUILDS_DIR/iOS/<timestamp>/<branch>/` (open `report.html`), and Android test reports go to `RMB_BUILDS_DIR/Android/<timestamp>/<branch>/` (open `index.html`).

### Code signing and the Keychain

iOS signing often needs the remote login Keychain unlocked. To unlock it, set `XCODE_REMOTE_KEYCHAIN_PASSWORD` in the local environment before running `XcodeRemoteBuild.sh`. The password is sent as the first line of the SSH standard input. It never appears in the SSH command line or in process arguments. The runner unsets it after the unlock, so Fastlane and other child processes never see it. Only iOS builds use the password. `XcodeRemoteBuild.sh` doesn't send it for test runs or Android builds, even if it's set.

The Shortcut reads this password from the local login Keychain, so it is never stored in the script. Store it once in Terminal; `-w` at the end makes `security` prompt for the password:

```bash
security add-generic-password -a "$USER" -s XcodeRemoteBuildKeychain -w
```

To change it later, add `-U` to update the existing item. If the item is missing, iOS builds from the Shortcut stop with an alert. The first time the Shortcut reads the item, macOS may ask you to allow access; choose **Always Allow**.

## The Shortcut

When you run it, the Shortcut asks for:

1. The platform: iOS or Android.
2. Whether to run unit tests. iOS tests then ask for the devices and the branch. Android tests ask for the short code and the branch.
3. For iOS builds: the Apple account (Old or New), the branch, the lane (`createAppForBrowserStack`, `updateAppForStore`, or `createLaunchImages`), the short code, the Dev APIs setting (`createAppForBrowserStack` only), and optional feature flags. Choosing `true` for Dev APIs adds `apiDev:true` to the feature flags.
4. For Android builds: the branch, the build type, the package type, the Dev APIs setting (BrowserStack builds only), the short code, and optional Gradle feature flags. Play Store builds require Bundle, then ask for a Bundle ID defaulting to `com.goeshow.<shortCode>` and publish the completed release bundle to production.

On success, it shows the runner's `SUCCESS:` line; Play Store builds also show the publisher result. Unit-test runs show a fixed message that points to the timestamped Builds folder. That alert means the tests finished and the report was delivered, not that they passed, so check the report. The exact location is on the `REPORT:` line in the script's output. On failure, it shows a critical alert with the lane or build type, the branch, and the last 12 lines of output.
