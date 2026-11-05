import AppKit

// The app's lifecycle is AppKit's: PocketTerm lives in the menu bar and owns its windows (App/Windows.swift).
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
