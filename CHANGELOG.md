# Changelog

User-visible changes to PocketTerm. Each release says whether servers need `apps/pocketterm-desktop/tool/setup-backend.sh` again (or an update from the setup wizard) and whether the push relay must be redeployed.

## Unreleased

No server update or relay redeploy needed.

- **Phone: links to the rest of PocketTerm.** The welcome screen links to the desktop app's downloads (step 1 needs it), and the account sheet links to the source on GitHub.

## 0.1.0

The first release. PocketTerm is the "Terminal from the phone" part of [Džep](https://github.com/danyzmaj-apps/dzep) 0.5.0 as a product of its own: Džep's ideas, todos, notes, reminders, Ask and widgets are not part of it.

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
- **Its own backend:** a fresh, minimal schema (sign-up rules, pairing and reviewer codes, the terminal channel and image bucket, push registrations, the computers list) and two functions, `pair` and `push`. It is not compatible with a Džep server: set up a new Supabase project for PocketTerm ([docs/SELF_HOSTING.md](docs/SELF_HOSTING.md)).
- **Side by side with Džep:** PocketTerm installs its omp extension as `pocketterm-live.ts` and its Claude Code plugin as `pocketterm@pocketterm`, and keeps its files in `~/.config/pocketterm`, so it never overwrites Džep's.
