# Releasing

PocketTerm is a personal project. Maintainer notes for shipping its four builds: the Mac app (notarized DMG on GitHub Releases, updated through Sparkle), the Windows app (unsigned installer on the same GitHub release), the iPhone app (TestFlight) and the Android app (Google Play open testing). The phone apps are not published on the App Store or in Google Play's production track. Plus the push relay the phones depend on.

Every app's version is the `version:` line of its own `pubspec.yaml` (`apps/pocketterm-desktop/pubspec.yaml`, `apps/pocketterm-mobile/pubspec.yaml`), as `<name>+<build>`. The build number must grow with every upload to any store; keep both apps on the same version name. The Mac and Windows apps are one Flutter app, so they always share a version. Baker numbers phone builds itself ([below](#each-release-1)), so TestFlight and Play build numbers don't match the pubspec's.

Keys and certificates never go in the repo: keep them in the maintainer's keys folder (mode 600), passwords in the Keychain.

## Release order

The wizard's VPS commands fetch `docker-compose.yml` from the tag `v<version>` and run the image `ghcr.io/danyzmaj-apps/pocketterm-server:<version>`. Neither exists until the release is out, so a desktop build of a new version can't set up a VPS before both are published. Release in this order:

1. **Bump the version** in `apps/pocketterm-desktop/pubspec.yaml`, `apps/pocketterm-mobile/pubspec.yaml` and the `POCKETTERM_VERSION` default in `apps/pocketterm-server/docker-compose.yml` (details in [Mac → Each release](#each-release)). Commit and push to `main`.
2. **Push the tag.** `tool/release.sh` creates the GitHub release `v<version>`, and with it the tag.
3. **The server image publishes.** The tag starts [.github/workflows/server-image.yml](../.github/workflows/server-image.yml) (on `push` of tags `v*`), which pushes `:<version>`, `:<major>.<minor>` and `:latest` to ghcr. Wait for it to go green before telling anyone about the release.
4. **Desktop and phone builds** go out after that: the Windows installer (built from the same release) and the phone builds from Baker.

**Once, after the first image is published:** packages on ghcr start private, and a VPS can't pull a private image without signing in. On GitHub, open the organization's **Packages** → `pocketterm-server` → **Package settings** → **Danger Zone** → **Change visibility** → **Public**. Check it from a machine that isn't signed in to ghcr: `docker pull ghcr.io/danyzmaj-apps/pocketterm-server:<version>`.

PocketTerm on Supabase needs no release step of its own: its migrations and function (`apps/pocketterm-desktop/supabase/`) ship inside the desktop app, and the app's setup deploys them.

## Before a release: end to end

CI runs the unit tests ([CONTRIBUTING.md](../CONTRIBUTING.md#pull-requests)). Before a release, run end to end only what covers the release's changes and the features around them (pick them as [TESTING.md](TESTING.md#what-to-run-for-a-change) says, from the release's `CHANGELOG.md` section and `git log v<previous>..HEAD`), with `--from-head`, which runs what's committed, in a worktree of HEAD. They run on the maintainer's Mac, on a quiet Mac (they open throwaway terminal windows).

The full matrix below (every terminal, every server, both phone platforms) is for releases with big cross-cutting changes (the protocol, encryption, session routing, the server) or when a targeted run turns up something it can't explain:

```sh
# at the repo root
tool/e2e/run.sh --from-head --terminal all                                   # local server, iPhone Simulator
tool/e2e/run.sh --from-head --terminal all --platform android --avd <avd>    # the same on an Android emulator
tool/e2e/run.sh --from-head --terminal all --server supabase                 # PocketTerm on a local Supabase
tool/e2e/run.sh --from-head --terminal kitty --server supabase-cloud --supabase-token-file <keys>/<supabase token>
tool/e2e/run.sh --from-head --terminal all --server https://pocketterm-test.danyzmaj.com \
  --setup-link-file <keys>/pocketterm-test-setup-link.txt \
  --server-stop-cmd 'ssh -o BatchMode=yes server docker stop pocketterm-test-app-1' \
  --server-start-cmd 'ssh -o BatchMode=yes server docker start pocketterm-test-app-1'
tool/e2e/run.sh --from-head --terminal all --server builtin                  # needs `tailscale serve status` empty
```

- **`--server supabase-cloud`** walks the desktop's own Supabase setup on supabase.com with a personal access token from the file: it makes a project named `PocketTerm e2e <terminal> <stamp>` in the token's first organization and deletes it after each terminal's run, whatever happened. The free plan allows 2 active projects: one slot must be free (pause another project for the run and restore it after). It has no server restart phase (a hosted project can't be taken off the network).
- **`--server builtin`** refuses to start while Tailscale serves anything, so quit the installed PocketTerm first; the run removes what it left in Tailscale's Serve settings.
- **An Android emulator** must have internet (Firebase gives no push token without it); the phone run waits up to a minute and says so.

The installed app, as from Finder (the terminal needs Accessibility and Screen Recording):

```sh
tool/smoke/run.sh prepare
tool/smoke/scenario.sh wizard getready settings menubar quit
tool/smoke/run.sh clean
```

### The test server

`https://pocketterm-test.danyzmaj.com` is a PocketTerm server on the publisher's server for the end-to-end runs ([apps/pocketterm-server/deploy/compose.yaml](../apps/pocketterm-server/deploy/compose.yaml), compose project `pocketterm-test`). Redeploy it after server changes: in [Baker](https://baker.danyzmaj.com), project `pocketterm-mobile` → workflow *Test server* → *Deploy*, on the branch to deploy (manual only, no trigger). Baker sends that commit to danyzmaj-server, which builds the image there and starts it with a healthcheck-gated deploy.

After `docker compose … build --pull`, a plain `up -d --wait` can keep the old container running although a new image was built, so the server silently runs old code (the deploy runs `up --wait` too, so it may have the same gap). After redeploying, check the image; if it's the old one, recreate the container on the server, from the deployed checkout's folder:

```sh
docker compose -p pocketterm-test -f apps/pocketterm-server/deploy/compose.yaml up -d --force-recreate --wait --wait-timeout 180
docker inspect pocketterm-test-app-1 --format '{{.Image}}'   # must be the image just built
```

`/v1/health` shows only the version name, not the build, so it can't tell an old container from a new one: check the image ID.

## Push relay (once, and after relay changes)

Every user's server sends phone notifications through one relay the publisher runs, `apps/pocketterm-relay` on the publisher's own server at `https://push.danyzmaj.com`. It holds the only credentials that can reach PocketTerm's installs: the APNs key for iPhones and the Firebase service account for Android.

1. **APNs key.** At [developer.apple.com → Keys](https://developer.apple.com/account/resources/authkeys/add), create a key with Apple Push Notifications service (Sandbox & Production, team scoped), or reuse an existing key of the team: APNs keys work for every app of the team. The `.p8` downloads once; keep its `AuthKey_<KEYID>.p8` name.
2. **Firebase service account.** In the Firebase project that holds the Android app (package `com.danyzmaj.pocketterm`), Project settings → Service accounts → **Generate new private key**. The same project's `google-services.json` goes into Android release builds (below).
3. **Secrets on the server**, in `/etc/danyzmaj/pocketterm-relay/`: the relay's X25519 private key (`openssl genpkey -algorithm X25519`, kept as `<keys>/pocketterm-relay-x25519.key`), the `.p8`, the service account and `app.env` with `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`. File names and the copy command: [apps/pocketterm-relay/README.md](../apps/pocketterm-relay/README.md#deploy).
4. **Deploy:** a push to `main` that touches `apps/pocketterm-relay/**` starts Baker's *Relay* workflow (project `pocketterm-mobile`): once the commit's checks pass (the `relay` check runs the relay's tests), Baker deploys it on the server itself as compose project `pocketterm-relay`. Baker → *Relay* → *Deploy* redeploys.

Every PocketTerm server sends to `PUSH_RELAY_URL` (default `https://push.danyzmaj.com/v1/push`), sealed to `PUSH_RELAY_KEY` (default the relay's public key); both defaults are in `packages/pocketterm_server/lib/src/relay.dart`. Servers pick up a new default only when they update, so a new relay key or URL goes in the changelog, and the old one keeps working until they have.

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

1. Bump `version:` in `apps/pocketterm-desktop/pubspec.yaml` (`<version>+<build>`), and set the same version name in `apps/pocketterm-desktop/integrations/claude/plugins/pocketterm/.claude-plugin/plugin.json`: Claude Code updates a plugin only to a new version, so installed copies would keep their old hooks (`release.sh` refuses a mismatch). Set the same version as the `POCKETTERM_VERSION` default in `apps/pocketterm-server/docker-compose.yml`: the VPS setup fetches that file from the release tag and runs the image it names (`release.sh` refuses a mismatch here too). Set it as `VERSION` in `apps/pocketterm-desktop/supabase/functions/pocketterm/index.ts` too, what a Supabase project reports in `GET /v1/health` (`release.sh` doesn't check this one).
2. Add a `## <version>` section at the top of `CHANGELOG.md` with the user-visible changes; `release.sh` refuses to run without it and uses that section as the release notes. Say whether servers must be updated (VPS: `docker compose pull`; Supabase: **Update that project**) and whether the relay must be redeployed.
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

1. A **Google Play Console** app with package `com.danyzmaj.pocketterm`, with the **Internal testing** track and its testers' list. Internal testing needs no review. Play only accepts API uploads once one build was uploaded by hand: build `fvm flutter build appbundle --release` once and upload `build/app/outputs/bundle/release/app-release.aab` to Internal testing in the console.
2. **Play App Signing** (the default): Google holds the app signing key; uploads are signed with the upload key `pocketterm-upload.jks` (alias `upload`) in the maintainer's keys folder, its password in the Keychain item `pocketterm-upload`. `apps/pocketterm-mobile/android/key.properties` (git-ignored, from `key.properties.example`) points at it. If it is lost, request an upload key reset in Play Console.
3. `apps/pocketterm-mobile/android/app/google-services.json` (git-ignored) from the Firebase project `pocketterm-cf6de8`, whose service account the relay holds. A release build stops without it (it would have no push).
4. A Play service account (`shipyard-play-uploader@holdup-signup.iam.gserviceaccount.com`), its JSON in the keys folder, set as the project's Play JSON in Baker. Invite it in Play Console → **Users and permissions** with release access to the app; until then uploads fail with a permission error.

Baker: add `apps/pocketterm-mobile` as a project, set its App Store Connect key preset and Play JSON, and use a workflow with the Play track `beta` (open testing), status `completed`, and the TestFlight group `External testers`.

### Each release

Set the version name in `apps/pocketterm-mobile/pubspec.yaml`, then ship from Baker to TestFlight and Google Play (**Ship both**). Baker's workflow uses the git commit count as the build number (`autoBuildNumber`), so it grows with every commit and the `+<build>` in the pubspec is ignored; ship from a new commit each time. For a build by hand: `fvm flutter build ipa --release --build-number <n>` (check `codesign -dv build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app` shows `TeamIdentifier=5SSZ6TYMF5`) and `fvm flutter build appbundle --release --build-number <n>`, with `<n>` above the last uploaded build.

TestFlight builds use APNs production; the relay handles both production and sandbox tokens.
