# Changelog

What each PocketTerm release brings.

## 1.0.0

The first release of PocketTerm as it is now: native apps on every platform, and your own PocketTerm server running on one of your computers, reached over Tailscale.

- **Native apps.** SwiftUI on the Mac and the iPhone, Jetpack Compose on Android, WinUI 3 on Windows. They follow your system's light or dark mode.
  - **Mac:** a menu-bar panel with how this computer stands, the **Terminal from phone** switch and what needs attention; Settings is a standard Mac Settings window.
  - **Windows:** Mica, Fluent icons, Settings in a side pane, a tray icon.
  - **iPhone:** native lists, swipe actions, menus, TipKit tips, Live Activities.
  - **Android:** Material 3 with your wallpaper's colors on Android 12 and later, ongoing notifications for the sessions you follow.
- **Setup over Tailscale.** The desktop app runs the server itself, and Tailscale gives it a private HTTPS address that only your own devices reach. Setup is the Tailscale checklist and **Start**. Another computer of yours joins with **Join another computer's PocketTerm…**, using the link from **Settings → Account → Add a computer…**.
- **Themes that follow light and dark.** **System** (the default), **Catppuccin** (Latte and Mocha), **Rosé Pine** (Dawn and Rosé Pine) and **Tokyo Night** (Day and Night). They color terminal screens, code and the accent, and the app icon follows the theme.
- **Conversations, screens and keys.**
  - Every coding session (omp, Claude Code) reads as a conversation you can prompt, steer, queue and stop, with images and files, approvals, questions and plans.
  - Every other terminal window (kitty, tmux, WezTerm, iTerm2, Ghostty) is a live screen you can type in.
  - omp profiles are listed and kept, and a new session opens as a tab in its project's window.
- **The push relay** needs no update.

### Coming from 0.1.x

Earlier test builds (0.1.0–0.1.7) were Flutter apps that could also use a Supabase project or a server on a VPS. They are no longer published. Updating from them keeps your sign-in, your computers' keys and your preferences, except:

- A computer that was on Supabase or on your own server is signed out once and opens the Tailscale setup. A phone that was on Supabase is signed out and asks you to scan its computer's new code. See [Moving from Supabase or your own server](docs/SELF_HOSTING.md#moving-from-supabase-or-your-own-server).
- The themes Catppuccin Mocha and Gruvbox Material become Catppuccin, and Rosé Pine Dawn becomes Rosé Pine.
