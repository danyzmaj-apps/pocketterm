import AppKit

// Before anything else, so a crash at launch is reported too (only with POCKETTERM_SENTRY_DSN set;
// App/ErrorReports.swift).
ErrorReports.start()

// The app's lifecycle is AppKit's: PocketTerm lives in the menu bar and owns its windows (App/Windows.swift).
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
