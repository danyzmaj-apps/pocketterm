# Android app: UX changes from the Flutter app

The native app (Jetpack Compose, Material 3) keeps every feature, string and test id of the Flutter
app (0.1.7). Where Android's own components do the job better than Flutter-era custom chrome, it
uses them. This file lists each deliberate change.

## Whole app
- **Colours.** Material 3, light or dark as the system is. The System theme (the default) uses the
  wallpaper's colours (dynamic color) on Android 12+ and Material's baseline before that; the other
  themes, Catppuccin (Latte / Mocha), Rosé Pine (Dawn / Rosé Pine) and Tokyo Night (Day / Night),
  build the scheme from their accent. Each theme has a light and a dark half, switched with the
  system, and colours the terminal screens, the terminal page's bars, code blocks and the splash.
  Gruvbox is gone (its people are on Catppuccin; the IconGruvbox launcher alias stays, showing the
  app's own icon, until the app moves such a phone to IconDefault). System and Catppuccin keep the
  app's own launcher icon; Rosé Pine and Tokyo Night switch it.
- **Session state.** Shown by the leading icon and its colour, with a little motion: a spinner ring
  while working, a hand when it needs you, an error icon, a pause icon, a check when done. This
  replaces the drawn state borders, the running "snake" and the needs-you pulse.
- **Launch.** No intro animation. The system splash shows the app icon on the theme's background
  until the saved sign-in is read, so setup never flashes.
- **Navigation.** Pages are Navigation Compose destinations with predictive back. Sheets are
  `ModalBottomSheet`s and confirmations are `AlertDialog`s. Messages are Material snackbars.
- **Tips.** First-use tips are Material rich tooltips with "Got it". The tour question is a dialog,
  as on Flutter's Android. A tip dismissed by tapping elsewhere counts as seen.
- **Fonts.** System fonts (Roboto) for the app and the system monospace for terminals and code.
  Both scale with the font size setting.
- **Logging.** Debug builds log the e2e timing lines to logcat under the tag `PocketTerm` (was `flutter`).

## Home list
- Projects are a flat Material list under sticky headers with a fold chevron. Tap a header to fold
  it; long-press it for its menu.
- Swiping a row left uncovers only End session / Close window, which asks first (CloseConfirm).
  Rename and Color moved from the swipe to the long-press row menu. The 5 s auto-close of an open
  swipe and the one-open-row rule went with the custom swipe.
- End session / Close window in the row menu asks first too. Flutter closed at once.
- Rename compares against the session's own title, so typing that title clears the custom name.
- The computer picker opens from the large top-bar title (with a dropdown arrow), which collapses
  on scroll.
- The demo banner is a Material card. The empty, locked and waiting states use Material type.
- The New session sheet opens fully expanded.

## Settings (was the account sheet)
- A full-screen Settings page with a large top bar. It adds a Computers section (the picker's rows)
  and the app version. "Leave this server" is a destructive list row.
- The theme sheet shows each theme's palette and says that the theme colours terminals and code and
  sets the app icon.

## Session
- The transcript is a reverse-layout list anchored by item keys. New messages still never move the
  reading position.
- Tool calls are expandable Material cards. The status cross-fades from a spinner to a check or a cross.
- User and outgoing bubbles use the primary container colour with a chat-bubble corner. A failed
  bubble gets an error outline.
- Code blocks use the terminal theme's colours in monospace, scroll sideways and have a Copy button.
- The ask card is an outlined card tinted with the needs-you colour.
- Follow uses notification bell icons instead of the iPhone-style lock clock.
- Send is a filled icon button with Material's Send icon. The attach menu and the queue's More menus
  are dropdown menus with icons.
- Long-press tooltips explain "Continue" and "Queue".
- Close window asks in a dialog instead of an inline banner.
- Toasts on the session and queue pages sit above the composer.

## Queue
- The queue opens as a full-screen page with a Close button.
- Rows reorder by long-press drag or by their drag handle. Other rows animate into place.
- Swipe to delete uses Material's SwipeToDismissBox.

## Terminal
- The page has a Material top bar. Wrap is a toggle icon button. Action labels show as long-press
  tooltips.
- Until the computer sends its terminal's colours, the screen uses the theme's colours. Flutter used
  plain grey on black.
- The keys bar and composer use the theme's terminal colours. TalkBack reads the keys as
  Esc, Tab, Up, Down, Enter and Control C, not as the glyphs.
- The switch banner is a tonal strip. Its button wraps under the text on narrow screens.
- The switch sheet is a bottom sheet. The busy warning uses the error colour.
- The link note slides in and out.

## Orchestrator
- The bar is a raised pill. The orchestrator is a full-screen page.
- While the microphone is held, the page gets a primary-coloured border and wash.
- The orchestrator mic shows no visual "Hold to talk" tooltip, because a long-press tooltip would
  fight the hold. TalkBack reads "Microphone".

## Voice
- The voice sheet is a full-screen dialog with a Close button. Back closes it; it no longer drags down.
- The particle "corona" is now a Material mic orb. Its rings grow with the loudness, it turns the
  error colour while a hold would cancel, and it dims while starting or stopping.
- The language switch is in the top bar (translate icon and the language's name).
- The session's title shows under the sheet title.
- Insert and Send always sit side by side.

## Setup, scanner and push
- Setup shows the launcher icon in the theme's colours instead of the animated logo. The steps are a
  card with numbered badges, and the scan button is full width.
- A link from another server asks in a card outlined in the needs-you colour.
- On the push question, the buttons stay in the bottom bar while the explanation scrolls.
- The scanner uses CameraX with ML Kit. A device without a camera gets the message without a
  permission prompt. Camera errors use CameraX's error names.
- PocketTerm no longer works with Supabase projects; the only server is the one built into a
  computer's PocketTerm, over Tailscale. A phone that was signed in through a Supabase project is
  signed out at launch and setup says, once: "Your computer's PocketTerm now runs its own server.
  Scan its new code." Setup links with `kind=supabase` are no longer accepted. Any other saved
  server stays.
