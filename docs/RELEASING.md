# Releasing

PocketTerm is a personal project. Maintainer notes for shipping its four builds: the Mac app (notarized DMG on GitHub Releases, updated through Sparkle), the Windows app (unsigned installer on the same GitHub release), the iPhone app (TestFlight only) and the Android app (Google Play internal testing only). The phone apps are not published on the App Store or Google Play. Plus the push relay the phones depend on.

Every app's version is the `version:` line of its own `pubspec.yaml` (`apps/pocketterm-desktop/pubspec.yaml`, `apps/pocketterm-mobile/pubspec.yaml`), as `<name>+<build>`. The build number must grow with every upload to any store; keep both apps on the same version name. The Mac and Windows apps are one Flutter app, so they always share a version. Baker numbers phone builds itself ([below](#each-release-1)), so TestFlight and Play build numbers don't match the pubspec's.

Keys and certificates never go in the repo: keep them in the maintainer's keys folder (mode 600), passwords in the Keychain.

## Push relay (once, and after relay changes)

Every user's server sends phone notifications through one relay the publisher runs, `functions/relay` on the publisher's own Supabase project. It holds the only credentials that can reach PocketTerm's installs: the APNs key for iPhones and the Firebase service account for Android.

1. **APNs key.** At [developer.apple.com → Keys](https://developer.apple.com/account/resources/authkeys/add), create a key with Apple Push Notifications service (Sandbox & Production, team scoped), or reuse an existing key of the team: APNs keys work for every app of the team. The `.p8` downloads once; keep its `AuthKey_<KEYID>.p8` name.
2. **Firebase service account.** In the Firebase project that holds the Android app (package `com.danyzmaj.pocketterm`), Project settings → Service accounts → **Generate new private key**. The same project's `google-services.json` goes into Android release builds (below).
3. **Deploy** (in `apps/pocketterm-desktop`; needs the Supabase CLI, logged in, and `jq`):
   ```sh
   tool/deploy-relay.sh <relay-project-ref> <keys>/AuthKey_<KEYID>.p8 <TEAM> [bundle-id] [--fcm <keys>/pocketterm-fcm-service-account.json]
   ```
   The bundle id (the APNs topic) defaults to `com.danyzmaj.pocketterm`. It stores the APNs key as relay secrets (`APNS_KEY`, `APNS_KEY_ID` from the file name, `APNS_TEAM_ID`, `APNS_TOPIC`), with `--fcm` the service account as `FCM_SERVICE_ACCOUNT`, and deploys `relay` with `--no-verify-jwt`. The secrets reach the CLI through a mode-600 env file, never the command line. Without `--fcm` the FCM secret stays as it is; unset, the relay answers Android pushes with 501.

`functions/push` on every server sends to `PUSH_RELAY_URL`, by default `https://iemvfkcpmgdkupwnnewg.supabase.co/functions/v1/relay`; change that default in `supabase/functions/push/index.ts` if the relay moves. Servers pick up a new default only when their `push` function is redeployed (`tool/setup-backend.sh`), so say so in the changelog.

## Mac

Each release is a notarized DMG on GitHub Releases, plus an `appcast.xml` that installed copies check through Sparkle (`SUFeedURL` in `apps/pocketterm-desktop/macos/Runner/Info.plist`: `https://github.com/danyzmaj-apps/pocketterm/releases/latest/download/appcast.xml`). `tool/release.sh` does all of it.

### One-time setup (maintainer's Mac)

1. **Developer ID Application certificate** for the team in `config/PocketTerm.xcconfig` (`POCKETTERM_TEAM`, or `config/Local.xcconfig` if it sets one): Xcode → Settings → Accounts → your team → Manage Certificates → **+** → Developer ID Application.
2. **Notarization credentials** as a keychain profile. `release.sh` uses the profile named by `NOTARY_PROFILE`, default `dzep-notary`: it's a team credential, so the one the team already has works. To make one, create an app-specific password at [account.apple.com](https://account.apple.com), then:
   ```sh
   xcrun notarytool store-credentials <profile> --apple-id <you@example.com> --team-id <TEAM>
   ```
3. **Sparkle signing key**, stored in the login keychain under the account `pocketterm`. In `apps/pocketterm-desktop`, after `pod install` in `macos/`:
   ```sh
   macos/Pods/Sparkle/bin/generate_keys --account pocketterm      # makes it once, prints the public half
   macos/Pods/Sparkle/bin/generate_keys --account pocketterm -p   # prints the public half again
   ```
   The public half is `SUPublicEDKey` in `macos/Runner/Info.plist`. **Back up the private half**: without it, installed copies won't accept new updates.
   ```sh
   macos/Pods/Sparkle/bin/generate_keys --account pocketterm -x <keys>/pocketterm-sparkle-private-key && chmod 600 <keys>/pocketterm-sparkle-private-key
   ```
4. `gh auth login`, with push access to the repo; and fvm.

**A fork shipping its own Mac app** makes its own Sparkle key the same way, puts its public half in `SUPublicEDKey` and its own feed in `SUFeedURL` (`https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`), and runs `release.sh` with `REPO=<owner>/<repo>`. Otherwise its copies would look for updates from upstream and refuse them. Its team and bundle id come from `config/Local.xcconfig` ([BUILDING.md](BUILDING.md#your-signing-identity)), its push relay from `PUSH_RELAY_URL` ([SELF_HOSTING.md](SELF_HOSTING.md#your-own-app-id-and-relay)).

### Each release

1. Bump `version:` in `apps/pocketterm-desktop/pubspec.yaml` (for example `0.2.0+2`), and set the same version name in `apps/pocketterm-desktop/integrations/claude/plugins/pocketterm/.claude-plugin/plugin.json`: Claude Code updates a plugin only to a new version, so installed copies would keep their old hooks (`release.sh` refuses a mismatch).
2. Turn `## Unreleased` in `CHANGELOG.md` into a `## 0.2.0` section; `release.sh` refuses to run without a `## <version>` heading and uses that section as the release notes. Say whether servers need `apps/pocketterm-desktop/tool/setup-backend.sh` again (new migrations or function changes) and whether the relay must be redeployed.
3. Point the download links in `README.md` (**Getting started**) at the new version's DMG and installer.
4. Commit and push to `main`, then (in `apps/pocketterm-desktop`):
   ```sh
   tool/release.sh
   ```

The script checks the prerequisites above (a clean tree, no `v<version>` tag yet, HEAD on `origin/main`, the certificate, the notary profile, the Sparkle key), builds and archives the app, and exports it with Developer ID signing. It notarizes and staples the app, builds the DMG, signs it with the team's Developer ID certificate, and notarizes and staples that too. Then it writes the appcast (keeping older entries from the previous release's `appcast.xml`) and creates the GitHub release `v<version>` with `PocketTerm-<version>.dmg` and `appcast.xml`; the release creates the tag on GitHub at HEAD, so a failed upload leaves no tag behind and a rerun just works.

`release.sh` doesn't look at CI: a red run on the release commit doesn't stop it, so check CI yourself first.

`tool/release.sh --dry-run` runs the same build with development signing, without notarizing or publishing, and leaves `build/release/PocketTerm-<version>.dmg` (in `apps/pocketterm-desktop`).

## Windows

Nothing to do by hand: publishing the GitHub release (which `release.sh` does) starts [.github/workflows/release-windows.yml](../.github/workflows/release-windows.yml). On `windows-latest` it checks out the release's tag, installs the Flutter version from `.fvmrc`, runs `flutter build windows --release` in `apps/pocketterm-desktop`, checks that the pubspec version matches the tag (`v<version>`), builds the installer with Inno Setup (`windows/installer.iss`) and uploads `PocketTerm-<version>-setup.exe` to the same release.

- If the job fails, fix it and run the workflow again by hand (Actions → Release (Windows) → **Run workflow**, with the tag, for example `v0.2.0`); it replaces an earlier upload.
- The installer and the app are not code-signed, so SmartScreen warns on first run. Windows copies don't update themselves: at start and once a day, the app asks GitHub for the latest release and, when it's newer than itself, shows a download link in Settings and **Update available…** in the tray menu, both opening the release page. That check reads `https://api.github.com/repos/danyzmaj-apps/pocketterm/releases/latest`, so a release only counts once it's published (not a draft or prerelease).

To build the installer locally, see [BUILDING.md](BUILDING.md#windows).

## Phones: TestFlight and Play internal testing

Both phone builds are built and uploaded by **Baker** (`baker.danyzmaj.com`, or its `baker_…` MCP tools), which runs the build on this Mac with the keys in the maintainer's keys folder. Nothing is submitted for App Store or Play review.

### One-time setup

iPhone:

1. An **App Store Connect** app record for bundle id `com.danyzmaj.pocketterm` (team `5SSZ6TYMF5`). The bundle ids `com.danyzmaj.pocketterm`, `…PocketTermLive`, `…PocketTermPush` and the App Group `group.com.danyzmaj.pocketterm` are already registered (automatic signing did it on the first release build).
2. TestFlight → **Internal testing**: the group `Internal`, with the testers (members of the team), set to get every build automatically. Internal builds need no Beta App Review.

Android:

1. A **Google Play Console** app with package `com.danyzmaj.pocketterm`, with the **Internal testing** track and its testers' list. Internal testing needs no review. Play only accepts API uploads once one build was uploaded by hand: build `fvm flutter build appbundle --release` once and upload `build/app/outputs/bundle/release/app-release.aab` to Internal testing in the console.
2. **Play App Signing** (the default): Google holds the app signing key; uploads are signed with the upload key `pocketterm-upload.jks` (alias `upload`) in the maintainer's keys folder, its password in the Keychain item `pocketterm-upload`. `apps/pocketterm-mobile/android/key.properties` (git-ignored, from `key.properties.example`) points at it. If it is lost, request an upload key reset in Play Console.
3. `apps/pocketterm-mobile/android/app/google-services.json` (git-ignored) from the Firebase project `pocketterm-cf6de8`, whose service account the relay holds. A release build stops without it (it would have no push).
4. A Play service account (`shipyard-play-uploader@holdup-signup.iam.gserviceaccount.com`), its JSON in the keys folder, set as the project's Play JSON in Baker. Invite it in Play Console → **Users and permissions** with release access to the app; until then uploads fail with a permission error.

Baker: add `apps/pocketterm-mobile` as a project, set its App Store Connect key preset and Play JSON, and use a workflow with the Play track `internal`.

### Each release

Set the version name in `apps/pocketterm-mobile/pubspec.yaml`, then ship from Baker to TestFlight and Google Play (**Ship both**). Baker's workflow uses the git commit count as the build number (`autoBuildNumber`), so it grows with every commit and the `+<build>` in the pubspec is ignored; ship from a new commit each time. For a build by hand: `fvm flutter build ipa --release --build-number <n>` (check `codesign -dv build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app` shows `TeamIdentifier=5SSZ6TYMF5`) and `fvm flutter build appbundle --release --build-number <n>`, with `<n>` above the last uploaded build.

TestFlight builds use APNs production; the relay handles both production and sandbox tokens.

### Reviewer codes

Not needed for internal testing. **Settings → Reviewer access** in the desktop app (press ⌥ Option to show it) makes codes that sign a phone into a separate demo account on your server; they're only for a build someone outside your account has to try (TestFlight external testing goes through Beta App Review, which needs a way in).
