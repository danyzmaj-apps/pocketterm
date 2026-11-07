# PocketTerm for macOS and Windows

The desktop app: the first-run setup (**On this computer**: the server built into the app, published to the owner's tailnet by Tailscale, or **Join another computer's PocketTerm…** with a setup link), sign-in, the setup checklist (**Get this computer ready**) and Settings (Phone, Coding agents, Terminals and Account); otherwise it runs in the background (menu bar on the Mac, tray on Windows) with the local terminal API and the bridge that lets a phone reach omp, Claude Code and this computer's terminals (macOS: kitty, tmux, WezTerm, iTerm2, Ghostty; Windows: WezTerm).

Two native apps share this folder's assets:

| Path | What |
| --- | --- |
| `macos/` | The Mac app (Swift 6, SwiftUI on AppKit, macOS 13+): the menu-bar item and its panel, the setup window, the Settings window, Sparkle updates; its services are [`packages/PocketTermKit`](../../packages/PocketTermKit/)'s `PocketTermDesktop` and `PocketTermTerminals`. The Xcode project comes from `project.yml` (xcodegen). [UX-NOTES.md](macos/UX-NOTES.md) |
| `windows/` | The Windows app (C# 12, .NET 8, WinUI 3): `PocketTerm.sln`, the installer `installer.iss`, the smoke run `tool/smoke.ps1` ([README](windows/README.md), [UX-NOTES.md](windows/UX-NOTES.md)) |
| `integrations/omp/` | omp extension `pocketterm-live.ts`: sessions for the phone |
| `integrations/claude/` | Claude Code marketplace with PocketTerm's `pocketterm` plugin: sessions for the phone (`plugins/pocketterm/hooks/`); `claude plugin test integrations/claude/plugins/pocketterm` runs its tests |
| `assets/` | The theme icons the apps switch to (`icon/`) and the tray icon (`tray.ico`) |
| `tool/release.sh` | Build, notarize and publish a Mac release |
| `tool/make_icon.swift` | Draw the app icons: the app's own (Catppuccin Mocha's) and each other theme's, for every app |

Both apps bundle the PocketTerm server (`packages/pocketterm_server`, compiled by `tool/server-sidecar.sh` / `.ps1` at the repo root) for **On this computer**.

```sh
(cd macos && xcodegen generate && open PocketTerm.xcodeproj)     # on a Mac; then run the PocketTerm scheme
dotnet run --project windows/PocketTerm.App -p:Platform=x64      # on a Windows PC
```

Building, signing and the installer: [docs/BUILDING.md](../../docs/BUILDING.md).
