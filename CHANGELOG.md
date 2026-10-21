# Changelog

User-visible changes to PocketTerm. Each release says whether servers need `apps/pocketterm-desktop/tool/setup-backend.sh` again (or an update from the setup wizard) and whether the push relay must be redeployed.

## Unreleased

No server update or relay redeploy needed.

- **Settings: Reviewer access is hidden.** It's only for publishing the phone apps (App Store / Play review codes), so it appears once you press ⌥ Option (Alt on Windows) in Settings, until the window is shown again.
- **Get this computer ready.** After the first sign-in on a computer (through the wizard or by connecting an existing server), the window is a checklist instead of Settings: PocketTerm installs itself into every coding agent it finds (omp, Claude Code) and lists agent sessions that started before it, with how to restart them (`omp -c`, `claude -c`); then the terminals with their one-click fixes, project folders found in your home folder (one click each), and the QR code for your phone. Each step checks itself off and can be skipped. Computers already set up with an earlier version see it once too, the next time the window opens: most of them never had the agent integration installed.
- **Setup wizard: server only.** Its last step no longer shows the terminals or WezTerm's install; the checklist after sign-in does, and the last step says so.
- **Settings: a status card at the top.** **All set**, or each thing that needs attention with the button that fixes it: PocketTerm missing or out of date in a coding agent (also one installed after setup), agent sessions to restart, a terminal to set up or allow, no phone signed in yet, no project folders. **Open setup checklist** brings the checklist back. Rows that need you are marked in amber.
- **Phone: windows that show only as screens say why.** For an omp or Claude Code window that doesn't report as a conversation, the phone now says what the computer found: PocketTerm isn't installed in that agent there, it's out of date, Claude Code has mods turned off, or the session started before PocketTerm was installed (restart it with `omp -c` or `claude -c`). With a computer on an earlier version, the old general note stays.

## 0.1.2

No server update or relay redeploy needed.

- **Setup wizard: clearer about the keys it asks for.** Step 1 explains why Supabase's token has to cover the whole organization (creating a project needs it), what PocketTerm does with it, that it's never saved, and how to wall it off in an organization of its own; the last step reminds you to delete it. Step 3 warns, in amber, to untick GitHub's "Allow wildcard matching", and **Set up my server** stays off until you confirm you did.

## 0.1.1

Servers need `apps/pocketterm-desktop/tool/setup-backend.sh` again (or an update from the setup wizard): a new migration stamps each computer's last-seen time with the server's clock, and `push` changed. The relay doesn't need redeploying.

- **New icon.** A phone showing a terminal prompt, leaning out of the pocket, instead of the note.
- **Phone: links to the rest of PocketTerm.** The welcome screen links to the desktop app's downloads (step 1 needs it), and the account sheet links to the source on GitHub.
- **Phone: with no computer on the account,** the screen explains why (a review demo account, or a computer with Terminal from phone off) and hides the + button.
- **Phone:** "Fold all others" keeps projects you folded on your other computers folded.
- **Phone:** ending one followed session's Live Activity no longer stops updates for the phone's other followed sessions.
- **Computers show as Online by the server's clock,** so a computer whose clock is off no longer reads as "Seen N min ago" while it's online.
- **Setup wizard:** a terminal's "turn it on" note goes away once the permission is given.
- **Windows:** the terminal mirror and WezTerm titles keep non-ASCII characters (box drawing, ✓, ⏺) instead of garbling them, and Settings finds the Claude plugin under a user folder with non-ASCII letters.
- **Windows:** Claude Code installed with npm (`claude.cmd`) is found and runs; a native `claude.exe` is preferred.
- **Windows:** a WezTerm window that answered slowly once comes back within a minute, instead of disappearing from the phone until PocketTerm restarts.
- **Windows:** a stalled WezTerm download stops with an error after 30 seconds so you can try again.
- **Windows:** Claude sessions reach the phone when `HOME` points somewhere other than your user folder.

## 0.1.0

The first release: your computer's omp and Claude Code sessions on your phone, through a Supabase server you own.

- **Desktop app for macOS and Windows.** A setup wizard that creates your own Supabase server (or connects one you have), sign-in with GitHub, and Settings. Otherwise it runs in the background: in the menu bar on the Mac, in the tray on Windows. Closing the window keeps it running.
- **Phone app for iPhone and Android.** Pair it by scanning a code from the desktop app. The Terminal tab lists your computer's omp and Claude Code sessions by project and its other terminal windows. A session opens as a conversation: streamed Markdown answers, tool-call cards, prompts with images, steer, queue and stop, questions, approvals, plan reviews and slash commands. Other windows are live screens you can type into. **New session** starts your agent or a shell in one of your projects.
- **Phone: a steadier Terminal list.** Projects stay put: sorted by name, or by recent activity (re-ranked only when you pull to refresh), chosen above the list. Sessions keep their order within a project instead of jumping when one needs you or starts working. A project's heading is just its name: tap it to fold the project to one line that still says what needs you; long-press it for a new session there, fold, fold all others or unfold all.
- **Windows: WezTerm without the search.** The setup wizard's last step and **Settings → Terminals** have an **Install** button: PocketTerm downloads WezTerm's own installer from WezTerm's GitHub release, checks it against WezTerm's published checksum, and opens it for you to click through. Prefer a terminal? The wizard shows the `winget` line to copy. PocketTerm notices WezTerm as soon as it's installed, either way.
- **Mac: your terminals in the setup wizard.** The wizard's last step lists the terminals found on your Mac with their one-click fixes (kitty's **Set up**, **Allow…** for Automation) and recommends tmux with a `brew install tmux` line to copy when it's missing. It catches up on its own once you've given a permission.
- **Several computers per account.** Each desktop registers itself; the phone lists them with their platform and whether they're online, and you pick one. Pushes and Live Activities say which computer a session is on, so a tap opens it there.
- **Pushes and Live Activities** when a run finishes or the agent needs you, through the publisher's relay, encrypted for your phone.
- **Terminals:** kitty, tmux, WezTerm, iTerm2, Terminal and Ghostty on the Mac; WezTerm on Windows.
- **Windows:** an unsigned per-user installer (`PocketTerm-0.1.0-setup.exe`) on GitHub Releases. Settings shows a link when a newer version is out.
- **Mac:** a notarized DMG that updates itself (Sparkle).
- **Its own backend:** a fresh, minimal schema (sign-up rules, pairing and reviewer codes, the terminal channel and image bucket, push registrations, the computers list) and two functions, `pair` and `push`. Set up a new Supabase project for PocketTerm ([docs/SELF_HOSTING.md](docs/SELF_HOSTING.md)).
