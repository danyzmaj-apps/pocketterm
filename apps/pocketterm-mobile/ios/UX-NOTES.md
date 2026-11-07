# iPhone app: UX changes from the Flutter app

The native app (SwiftUI, iOS 17+) keeps every feature, string and test id of the Flutter app at 0.1.7. Where an
iOS idiom fits better than Flutter's custom chrome, it uses the idiom. This file lists each such change, so the
e2e flows and the docs can follow them.

## Everywhere
- **System chrome.** iOS's own colours (light and dark), SF fonts, Dynamic Type, standard navigation bars, lists,
  forms, sheets with detents, menus and confirmation dialogs. On iOS 26 these come as Liquid Glass.
- **Themes** are System (the default: iOS's own blue tint, terminals black on white or light on near-black with
  xterm's 16 colours), Catppuccin (Latte / Mocha), Rosé Pine (Dawn / Rosé Pine) and Tokyo Night (Day / Night). Each
  has a light and a dark half, shown as the phone is and switched live with it; Gruvbox is gone (its people are on
  Catppuccin). A theme colours what is the terminal's: screens, code blocks and the accent tint. The picker shows
  each theme's light and dark halves side by side. System and Catppuccin keep the app's own icon; Rosé Pine and
  Tokyo Night switch it. The app no longer repaints its chrome in the theme, and the theme cross-fade is gone.
- **Terminal page.** The navigation bar, the keys bar and the composer take the screen's background and its light
  or dark, so the page reads as one terminal surface (also when the computer's own terminal colours show).
- **Launch.** The Flutter intro animation is gone. The storyboard launch screen shows the app icon on System's
  background (white or near-black), and while the app reads what it kept, the chosen theme's icon on its background.
- **Snackbars → toasts.** A floating capsule above the bottom edge, with an optional action (Undo, Settings), read
  out by VoiceOver as it comes.
- **Haptics** use iOS's notification, selection and impact feedback (done, picked, held, failed).

## Home
- **Computer picker.** It's the navigation title's menu (`ToolbarTitleMenu`), not a bottom sheet. A checkmark marks
  the computer shown.
- **Profile filter and project sort** are menus with checkmarked choices, not a sheet or a tap-to-toggle pill. The
  e2e flows open the menu (`profile-filter`, `project-sort`), then tap the choice (`profile-filter-<x>`,
  `project-sort-name`, `project-sort-activity`).
- **Project headings** are section headers with a small chevron that turns when folded. The long-press menu is a
  context menu, titled with the folder's short path.
- **Row state.** StateBorder (the coloured border, the working "snake" and the needs-you flash) is replaced by an SF
  Symbol in the state's colour. It pulses while the agent works and bounces once when it starts needing you; green
  marks done, red failed, grey paused. The row's own colour tints its background.
- **Row long-press** opens a context menu instead of a sheet. Its first line says where the window sits on the
  computer.
- **Swipe actions** are native: Rename (grey), Color (in the row's colour), then End session / Close window (red).
  Closing now asks first (a confirmation dialog), where Flutter closed at once from the swipe. iOS closes swipes
  itself, so the 5-second auto-close is gone.
- **New session** is a round prominent + beside the orchestrator bar, at the bottom.
- **The new session sheet** is a form with detents (70% and full). The profile choices are capsules and the project
  folders an inline picker.
- **Rename, Color and the windows-and-tabs overview** are sheets with detents and Cancel/Done.
- **Locked computer and empty states** use iOS's ContentUnavailableView.
- **Hints** about screen-only windows (`switch-tip`, `<command>-screens-only`) sit in the footer of the windows
  section.

## Conversation
- **Markdown.** The transcript uses iOS's own Markdown for inline text, with its own blocks for headings, lists,
  quotes, tables and code. Code blocks use the theme's terminal colours and have a Copy button.
- **Tool calls** are DisclosureGroup cards.
- **The composer** is a bottom inset bar with a growing text field. Attach is a menu: Paste image, Choose from Photos
  (PhotosPicker), Choose from Files.
- **Questions, approvals and plans** are inline cards with prominent buttons. A destructive step (clearing the queue,
  deleting a prompt with images or files) asks with a confirmation dialog.
- **The queue screen** is a full-screen list with native reordering (drag handles) and swipe-to-delete.

## Terminal screen
- **Screen colours.** When the computer sends no colours, the screen uses the theme's text and background, not
  xterm's black and grey.
- **The keys bar** uses system bordered buttons, 44 pt tall. VoiceOver reads full names (Escape, Up arrow,
  Control C) instead of the key caps.
- **Closing a window** asks in an action sheet instead of the in-page red panel. There is no `close-sent` spinner,
  because the dialog goes once tapped.
- **Unreadable and closed windows** use ContentUnavailableView.
- **The switch-to-conversation sheet** is native, opening at half height (medium and large detents).

## Orchestrator
- **The bar** is a capsule: Liquid Glass on iOS 26, a material before. VoiceOver reads "Orchestrator" with its
  status as the value.
- **The chat** is a full-screen navigation view: Close on the left, Stop and Open conversation as toolbar icons.

## Voice
- **The orb.** Flutter's corona (a particle star) becomes an orb of two tinted discs that swell with the microphone
  level, with an SF Symbol `waveform` (variable-colour effect) while listening. It's red while a hold has slid away
  to cancel, grey and still while starting or stopping, and doesn't swell with Reduce Motion.
- **Live words** fade in as one text instead of word by word, and scroll to the newest.
- **The voice sheet** is a full-screen navigation view with Close on the left and the language on the right. It's
  presented over full screen, so a hold's finger keeps reaching the microphone underneath.
- **Voice language** is a pushed settings page (a checkmark list), not a bottom sheet.

## Tips
- **Tip bubbles.** The coach's spotlight (a dimmed screen with a hole) becomes iOS popovers on the controls: the
  caption with Got it. One shows at a time, in tour order, each once, as before. Tapping beside a popover closes it
  and counts as seen, as tapping the dim did.
  - TipKit's `popoverTip` was tried and dropped: it didn't present on List rows and section headers, and its own
    datastore kept a second, conflicting record of seen tips.
  - A popover hides the page under it from VoiceOver and UI tests until it's dismissed. The Maestro flows dismiss
    tips first (`tips.yaml`, now up to 5 in a row).
- **The tour question** ("New here?") is a medium sheet that can't be swiped away.

## Setup, scanning, notifications, account
- **Setup and push consent** are centred pages on the grouped background, with cards and large buttons. The push
  consent buttons stay pinned at the bottom.
- **The scanner** uses VisionKit's DataScannerViewController for QR codes, falling back to AVFoundation.
  - It checks for a camera before asking for permission, so the Simulator and camera-less devices get the
    "no camera" text straight away, with no prompt.
  - It gives a success haptic on a good code and a warning haptic on a new problem.
- **The account sheet** is a Form in its own navigation stack. Theme and voice language are pushed pages. The theme
  page's footer says the app icon changes too.
- **The Notifications switch** moves as soon as it's flipped, while registering is still going on. Flutter moved it
  only once the choice was saved.
- **A link from outside the app** (ConfirmLink) is an inline card with an orange border.
- **No Supabase.** A phone signed in to a Supabase project is signed out at launch (Supabase isn't asked): its
  sign-in, computer keys and followed sessions go, and the setup says "Your computer's PocketTerm now runs its own
  server. Scan its new code." (`server-moved`) until a code signs it in again. Any other server is kept. A
  `kind=supabase` code is no PocketTerm code.
