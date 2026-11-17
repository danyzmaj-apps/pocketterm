# Desk (beta)

Desk is one window on the Mac for every project's terminals. PocketTerm runs them itself, headless in tmux, so there
are no terminal windows, tabs or splits to arrange, and nothing stops when you close Desk or quit PocketTerm. Open it
from the menu-bar panel (**Open Desk (Beta)**), the right-click menu, or **Desk → Open Desk** while a PocketTerm window
is open.

It needs tmux (`brew install tmux`). It's in beta: it works on the Mac only, and its layout and keys may still change.

## The window

- **Sidebar.** **Waiting for you** lists every terminal across all projects whose agent asks a question, wants an
  approval or a plan reviewed, finished while you looked elsewhere, or failed. Under **Projects** each project with
  its terminals; a dot says how each stands (orange waits for you, accent works, green finished, red failed, blue a
  program runs). Right-click a project to pin it, show it in Finder or close it (its terminals end); a terminal to
  rename or end it.
- **Terminals.** The project's terminals in one of three layouts: **Single** (the focused one), **Focus** (the
  focused one large, the others beside it) and **Grid**. The layout is kept per project. Each pane's header shows
  its state, the ports it serves (click to open) and its ⌘ number.
- **Project details** (⌥⌘I): git branch, distance from upstream, changed files, worktrees; commands to run in a new
  terminal (package.json's scripts, and your own: type one in **Add a command…**); listening ports.

Answer an agent right in its terminal: Desk shows the real terminal, so approvals and questions work as in any
terminal.

## Keys

Only ⌘ keys, so none is taken from the programs in a terminal. All are in the **File** and **Desk** menus.

| Keys | Does |
| --- | --- |
| ⌘K | Go to a project or terminal, start an agent or terminal, run a project's command: type a few letters, Return. Empty, its first row is the project you were on before (⌘K, Return goes back). |
| ⌘J | The next terminal waiting for you, in any project (again for the one after) |
| ⌘1 … ⌘9 | The project's terminal 1 … 9 (the sidebar's order) |
| ⌘⇧] / ⌘⇧[ | The next / previous terminal of the project |
| ⌘T | A new terminal in the project |
| ⌘⇧T | A new session of your coding agent (Settings → Coding agents) |
| ⌘⇧W | End the focused terminal (asks while a program runs in it) |
| ⌘⇧↩ | Zoom the focused terminal, and back |
| ⌘O | Open a project folder |
| ⌃⌘S / ⌥⌘I | Show or hide the sidebar / project details |
| ⌘W | Close Desk: its terminals keep running |

In a terminal, the mouse wheel scrolls back (tmux), and Shift-drag selects text for ⌘C.

## With the phone

Desk's terminals are tmux panes, so the phone lists them like any other: one window per project ("Desk · api ·
terminal 2"), with screens, keys and, for omp and Claude Code, the conversation. To have sessions you start on the
phone open in Desk, choose **Settings → Terminals → New sessions open in → PocketTerm Desk**.

## How it works

Each terminal is a tmux session on a server of PocketTerm's own (`tmux -L pocketterm`, no `~/.tmux.conf`, no status
line or prefix key), tagged with its project (`@pocketterm_project`). The window shows each one through SwiftTerm
running `tmux attach`, so it can close and open again without touching what runs. See
`packages/PocketTermKit/Sources/PocketTermTerminals/Desk.swift` and `apps/pocketterm-desktop/macos/PocketTerm/Desk/`.

To look at or clean up by hand: `tmux -L pocketterm ls`, `tmux -L pocketterm kill-server`.
