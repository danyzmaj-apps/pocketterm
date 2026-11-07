# Releasing

PocketTerm is a personal project. Maintainer notes for shipping its four builds: the Mac app (notarized DMG on GitHub Releases, updated through Sparkle), the Windows app (unsigned installer on the same GitHub release), the iPhone app (TestFlight) and the Android app (Google Play open testing). The phone apps are not published on the App Store or in Google Play's production track. Plus the push relay the phones depend on.

Versions: the Mac app's is `MARKETING_VERSION` (the version name) and `CURRENT_PROJECT_VERSION` (the build number) in `apps/pocketterm-desktop/macos/project.yml`; the Windows app takes the release tag's (`-p:Version=<version>`, the csproj's `<Version>` being only the default for local builds); the iPhone app's is `MARKETING_VERSION` in `apps/pocketterm-mobile/ios/project.yml`, the Android app's `versionName` in `apps/pocketterm-mobile/android/app/build.gradle.kts`. Keep every app on the same version name. Baker numbers phone builds itself ([below](#each-release-1)) and passes the version name and number to the build scripts, so TestFlight and Play build numbers don't match the files' defaults.

Keys and certificates never go in the repo: keep them in the maintainer's keys folder (mode 600), passwords in the Keychain.

## Release order

Release in this order:

1. **Bump the version** in `apps/pocketterm-desktop/macos/project.yml` and the phone apps' defaults (above) (details in [Mac → Each release](#each-release)). Commit and push to `main`.
2. **Push the tag.** `tool/release.sh` creates the GitHub release `v<version>`, and with it the tag. The server ships inside the desktop apps, so there is no server release of its own.
3. **Desktop and phone builds** go out after that: the Windows installer (built from the same release) and the phone builds from Baker.

## Before a release: end to end

CI runs the unit tests ([CONTRIBUTING.md](../CONTRIBUTING.md#pull-requests)). Before a release, run end to end only what covers the release's changes and the features around them (pick them as [TESTING.md](TESTING.md#what-to-run-for-a-change) says, from the release's `CHANGELOG.md` section and `git log v<previous>..HEAD`), with `--from-head`, which runs what's committed, in a worktree of HEAD. They run on the maintainer's Mac, on a quiet Mac (they open throwaway terminal windows).

The full matrix below (every terminal, both servers, both phone platforms) is for releases with big cross-cutting changes (the protocol, encryption, session routing, the server) or when a targeted run turns up something it can't explain:

```sh
# at the repo root
tool/e2e/run.sh --from-head --terminal all                                   # local server, iPhone Simulator
tool/e2e/run.sh --from-head --terminal all --platform android --avd <avd>    # the same on an Android emulator
tool/e2e/run.sh --from-head --terminal all --server builtin                  # needs `tailscale serve status` empty
```

- **`--server builtin`** refuses to start while Tailscale serves anything, so quit the installed PocketTerm first; the run removes what it left in Tailscale's Serve settings.
- **An Android emulator** must have internet (Firebase gives no push token without it); the phone run waits up to a minute and says so.

The installed app, as from Finder (the terminal needs Accessibility and Screen Recording):

```sh
tool/smoke/run.sh prepare
tool/smoke/scenario.sh wizard getready settings menubar quit
tool/smoke/run.sh clean
```

## Push relay (once, and after relay changes)

Every user's server sends phone notifications through one relay the publisher runs, `apps/pocketterm-relay` on the publisher's machine at `https://push.danyzmaj.com`. It holds the only credentials that can reach PocketTerm's installs: the APNs key for iPhones and the Firebase service account for Android.

1. **APNs key.** At [developer.apple.com → Keys](https://developer.apple.com/account/resources/authkeys/add), create a key with Apple Push Notifications service (Sandbox & Production, team scoped), or reuse an existing key of the team: APNs keys work for every app of the team. The `.p8` downloads once; keep its `AuthKey_<KEYID>.p8` name.
2. **Firebase service account.** In the Firebase project that holds the Android app (package `com.danyzmaj.pocketterm`), Project settings → Service accounts → **Generate new private key**. The same project's `google-services.json` goes into Android release builds (below).
3. **Secrets on the server**, in `/etc/danyzmaj/pocketterm-relay/`: the relay's X25519 private key (`openssl genpkey -algorithm X25519`, kept as `<keys>/pocketterm-relay-x25519.key`), the `.p8`, the service account and `app.env` with `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`. File names and the copy command: [apps/pocketterm-relay/README.md](../apps/pocketterm-relay/README.md#deploy).
4. **Deploy:** a push to `main` that touches `apps/pocketterm-relay/**` starts Baker's *Relay* workflow (project `pocketterm-android`): it runs the relay's tests (`deno check main.ts && deno task test`), then deploys it on the server itself as compose project `pocketterm-relay`. Baker → *Relay* → *Deploy* redeploys.

Every PocketTerm server sends to `PUSH_RELAY_URL` (default `https://push.danyzmaj.com/v1/push`), sealed to `PUSH_RELAY_KEY` (default the relay's public key); both defaults are in `packages/pocketterm_server/lib/src/relay.dart`. Servers pick up a new default only when they update, so a new relay key or URL goes in the changelog, and the old one keeps working until they have.

## Mac

Each release is a notarized DMG of the native Mac app (`apps/pocketterm-desktop/macos`) on GitHub Releases, plus an `appcast.xml` that installed copies check through Sparkle (`SUFeedURL` in `apps/pocketterm-desktop/macos/PocketTerm/Info.plist`: `https://github.com/danyzmaj-apps/pocketterm/releases/latest/download/appcast.xml`). `tool/release.sh` does all of it. The app is universal (Apple silicon and Intel), and so is the built-in server it bundles: `tool/server-sidecar.sh` needs `DART_X64` pointing at an Intel Dart SDK's `dart` (it runs under Rosetta) to build the Intel half, and `release.sh` refuses a real release without it.

### One-time setup (maintainer's Mac)

1. **Developer ID Application certificate** for the team in `config/PocketTerm.xcconfig` (`POCKETTERM_TEAM`, or `config/Local.xcconfig` if it sets one): Xcode → Settings → Accounts → your team → Manage Certificates → **+** → Developer ID Application.
2. **Notarization credentials** as a keychain profile. `release.sh` uses the profile named by `NOTARY_PROFILE`, default `pocketterm-notary`. To make one, create an app-specific password at [account.apple.com](https://account.apple.com), then:
   ```sh
   xcrun notarytool store-credentials pocketterm-notary --apple-id <you@example.com> --team-id <TEAM>
   ```
3. **Sparkle signing key**, stored in the login keychain under the account `pocketterm`. Sparkle comes as a Swift package; its tools are in the package's artifacts once Xcode has resolved it (any build of the app, e.g. `release.sh --dry-run`, which leaves them in `build/release/dd/SourcePackages/artifacts/sparkle/Sparkle/bin`). In `apps/pocketterm-desktop`:
   ```sh
   SPARKLE=build/release/dd/SourcePackages/artifacts/sparkle/Sparkle/bin
   $SPARKLE/generate_keys --account pocketterm      # makes it once, prints the public half
   $SPARKLE/generate_keys --account pocketterm -p   # prints the public half again
   ```
   The public half is `SUPublicEDKey` in `macos/PocketTerm/Info.plist`. **Back up the private half**: without it, installed copies won't accept new updates.
   ```sh
   $SPARKLE/generate_keys --account pocketterm -x <keys>/pocketterm-sparkle-private-key && chmod 600 <keys>/pocketterm-sparkle-private-key
   ```
4. `gh auth login`, with push access to the repo; xcodegen (`brew install xcodegen`); fvm (the built-in server is Dart); an Intel Dart SDK for `DART_X64` (above), of the same Dart version as `fvm dart --version`, unzipped user-locally; it runs under Rosetta (`softwareupdate --install-rosetta` if `arch -x86_64 /usr/bin/true` fails):
   ```sh
   mkdir -p ~/.local/share/dart-x64 && cd ~/.local/share/dart-x64
   curl -fsSLO https://storage.googleapis.com/dart-archive/channels/stable/release/<dart-version>/sdk/dartsdk-macos-x64-release.zip
   unzip -q dartsdk-macos-x64-release.zip && rm dartsdk-macos-x64-release.zip
   arch -x86_64 dart-sdk/bin/dart --version   # … on "macos_x64"
   ```

**A fork shipping its own Mac app** makes its own Sparkle key the same way, puts its public half in `SUPublicEDKey` and its own feed in `SUFeedURL` (`https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`), and runs `release.sh` with `REPO=<owner>/<repo>`. Otherwise its copies would look for updates from upstream and refuse them. Its team and bundle id come from `config/Local.xcconfig` ([BUILDING.md](BUILDING.md#your-signing-identity)), its push relay from `PUSH_RELAY_URL` ([SELF_HOSTING.md](SELF_HOSTING.md#your-own-app-id-and-relay)).

### Each release

1. Bump `MARKETING_VERSION` (the version) and `CURRENT_PROJECT_VERSION` (the build number, always higher than the last release's: Sparkle compares it) in `apps/pocketterm-desktop/macos/project.yml` and set the same version name in `apps/pocketterm-desktop/integrations/claude/plugins/pocketterm/.claude-plugin/plugin.json`: Claude Code updates a plugin only to a new version, so installed copies would keep their old hooks (`release.sh` refuses a mismatch).
2. Add a `## <version>` section at the top of `CHANGELOG.md` with the user-visible changes; `release.sh` refuses to run without it and uses that section as the release notes. Say whether the relay must be redeployed.
3. Point the download links in `README.md` (**Getting started**) at the new version's DMG and installer.
4. Commit and push to `main`, then (in `apps/pocketterm-desktop`):
   ```sh
   DART_X64=~/.local/share/dart-x64/dart-sdk/bin/dart tool/release.sh
   ```

The script checks the prerequisites above (a clean tree, no `v<version>` tag yet, HEAD on `origin/main`, the certificate, the notary profile, the Sparkle key, `DART_X64`), builds the universal server, archives the app with it (`Contents/Helpers/pocketterm-server`, signed with the hardened runtime and `macos/scripts/server.entitlements`) and exports it with Developer ID signing, then checks the export: both architectures, the team, and the server signed with the Developer ID, the hardened runtime and its entitlement. It notarizes and staples the app, builds the DMG, signs it with the team's Developer ID certificate, and notarizes and staples that too. Then it writes the appcast (keeping older entries from the previous release's `appcast.xml`) and creates the GitHub release `v<version>` with `PocketTerm-<version>.dmg` and `appcast.xml`; the release creates the tag on GitHub at HEAD, so a failed upload leaves no tag behind and a rerun just works.

`release.sh` doesn't look at CI: a red run on the release commit doesn't stop it, so check CI yourself first.

`tool/release.sh --dry-run` runs the same build, Developer ID signed and with a signed appcast entry, but prints the notarytool/stapler commands instead of running them and publishes nothing (without `DART_X64` it bundles an arm64-only server and says so). It leaves `build/release/PocketTerm-<version>.dmg` and `build/release/appcast/appcast.xml` (in `apps/pocketterm-desktop`); `spctl -a -vv` on its app says "Unnotarized Developer ID". The Sparkle key is read from `SPARKLE_KEY_FILE` (default `/Users/danyzmaj/Dev/keys/pocketterm-sparkle-private-key`, the backup above) when that file exists, else from the keychain, which may ask for access.

## Windows

Nothing to do by hand: publishing the GitHub release (which `release.sh` does) starts [.github/workflows/release-windows.yml](../.github/workflows/release-windows.yml). On `windows-latest` it checks out the release's tag (`v<version>`, or a prerelease of it), installs Dart (`dart-lang/setup-dart`) and compiles the built-in server with `tool/server-sidecar.ps1`, publishes the native app self-contained (`dotnet publish … -p:Version=<version> -p:PocketTermRelease=true`), builds the installer with Inno Setup (`windows/installer.iss`) and uploads `PocketTerm-<version>-setup.exe` to the same release. Every pull request already builds, tests, installs and smoke-runs the same installer (`.github/workflows/ci.yml`, job `dotnet-windows`).

- If the job fails, fix it and run the workflow again by hand (Actions → Release (Windows) → **Run workflow**, with the tag `v<version>`); it replaces an earlier upload.
- The installer and the app are not code-signed, so SmartScreen warns on first run. Windows copies don't update themselves: at start and once a day, the app asks GitHub for the latest release and, when it's newer than itself, shows a download link in Settings and **Update available…** in the tray menu, both opening the release page. That check reads `https://api.github.com/repos/danyzmaj-apps/pocketterm/releases/latest`, so a release only counts once it's published (not a draft or prerelease).

To build the installer locally, see [BUILDING.md](BUILDING.md#windows).

## Phones: TestFlight and Play open testing

Both phone builds are built and uploaded by **Baker** (`baker.danyzmaj.com`, or its `baker_…` MCP tools), which runs the build on this Mac with the keys in the maintainer's keys folder. Each build goes to external testers: on iPhone the TestFlight group **External testers** (public link `https://testflight.apple.com/join/UAHRArPQ`; each new build waits for Beta App Review, usually under a day), on Android the Play **open testing** track (API track `beta`; each release goes through Play's review). The TestFlight group **Internal** gets every build at once, without review.

### One-time setup

iPhone:

1. An **App Store Connect** app record for bundle id `com.danyzmaj.pocketterm` (team `5SSZ6TYMF5`). The bundle ids `com.danyzmaj.pocketterm`, `…PocketTermLive`, `…PocketTermPush` and the App Group `group.com.danyzmaj.pocketterm` are already registered (automatic signing did it on the first release build).
2. TestFlight → **Internal testing**: the group `Internal`, with the testers (members of the team), set to get every build automatically. Internal builds need no Beta App Review.

Android:

1. A **Google Play Console** app with package `com.danyzmaj.pocketterm`, with the **Internal testing** track and its testers' list. Internal testing needs no review. Play only accepts API uploads once one build was uploaded by hand: run `apps/pocketterm-mobile/tool/build-aab.sh` once and upload `apps/pocketterm-mobile/android/app/build/outputs/bundle/release/app-release.aab` to Internal testing in the console.
2. **Play App Signing** (the default): Google holds the app signing key; uploads are signed with the upload key `pocketterm-upload.jks` (alias `upload`) in the maintainer's keys folder, its password in the Keychain item `pocketterm-upload`. `apps/pocketterm-mobile/android/key.properties` (git-ignored, from `key.properties.example`) points at it. If it is lost, request an upload key reset in Play Console.
3. `apps/pocketterm-mobile/android/app/google-services.json` (git-ignored) from the Firebase project `pocketterm-cf6de8`, whose service account the relay holds. A release build stops without it (it would have no push).
4. A Play service account (`shipyard-play-uploader@holdup-signup.iam.gserviceaccount.com`), its JSON in the keys folder, set as the project's Play JSON in Baker. Invite it in Play Console → **Users and permissions** with release access to the app; until then uploads fail with a permission error.

Baker builds a native app from its own folder, so the phones are two Baker projects on this repo, each with a workflow **Default** (ref `main`, no triggers: nothing ships on its own):

- `pocketterm-android`, folder `apps/pocketterm-mobile/android`: the Play JSON, carry-over files `key.properties` and `app/google-services.json`, Play track `beta` (open testing) plus `internal`, status `completed`. It also holds the repo's checks (CI) and the *Relay* workflow.
- `pocketterm-ios`, folder `apps/pocketterm-mobile/ios`: the App Store Connect key preset `danyzmaj` and the TestFlight group `External testers`.

### Each release

Set the version name (`MARKETING_VERSION` in `ios/project.yml`, `versionName` in `android/app/build.gradle.kts`), then ship each phone from Baker: *Ship* on `pocketterm-ios` (TestFlight) and on `pocketterm-android` (Google Play). The workflows leave the version name empty, so the builds take it from those files (a `v<version>` tag or `release/<version>` branch overrides it). The build number comes from each project's build counter (`autoBuildNumber`), which only goes up; keep both counters above the highest build TestFlight and Play have. For a build by hand, from anywhere: `apps/pocketterm-mobile/tool/build-ipa.sh --build-name <version> --build-number <n>` (check `codesign -dv` on the app in the archive shows `TeamIdentifier=5SSZ6TYMF5`) and `apps/pocketterm-mobile/tool/build-aab.sh --build-name <version> --build-number <n>`, with `<n>` above the last uploaded build.

### Phone builds (Baker)

Baker runs each project's build command in its folder, appends `--build-name=<version> --build-number=<n>`, and uploads the newest `.aab` under the Gradle modules' `build/outputs/bundle/` or the newest `.ipa` under `build/`. Build commands:

- Android (`pocketterm-android`, in `apps/pocketterm-mobile/android`): `../tool/build-aab.sh` (Gradle `:app:bundleRelease`, signed with `android/key.properties`; writes `android/app/build/outputs/bundle/release/app-release.aab`). Without `android/local.properties`, as in Baker's worktree, it uses the SDK in `ANDROID_HOME` or `~/Library/Android/sdk`.
- iPhone (`pocketterm-ios`, in `apps/pocketterm-mobile/ios`): `../tool/build-ipa.sh` (xcodegen, archive and App Store Connect export with the team from `config/PocketTerm.xcconfig`; writes `ios/build/ipa/PocketTerm.ipa`, no upload)

Check commands (from the repo root):

```sh
cd packages/PocketTermKit && swift test
cd apps/pocketterm-mobile/ios && xcodegen generate && xcodebuild -scheme PocketTerm -destination 'generic/platform=iOS Simulator' build
cd apps/pocketterm-mobile/android && ./gradlew :core:test :app:testDebugUnitTest :app:lintDebug
cd apps/pocketterm-desktop/macos && xcodegen generate && xcodebuild -scheme PocketTerm build test
~/.dotnet/dotnet test apps/pocketterm-desktop/windows/PocketTerm.Libraries.slnf
```

TestFlight builds use APNs production; the relay handles both production and sandbox tokens.
