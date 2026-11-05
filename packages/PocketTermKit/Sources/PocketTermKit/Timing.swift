import Foundation

/// Debug builds: logs [what] with the time in ms, so a launch's steps can be timed from the device log
/// (`PocketTerm timing <ms> <what>`). Release builds log nothing there either.
public func timing(_ what: String) {
  #if DEBUG
    debugLog("PocketTerm timing \(millisecondsSinceEpoch(Date())) \(what)")
  #endif
}

/// Dart's `debugPrint`: the app's own log lines, in debug builds only. NSLog, as Flutter's print on Apple went to
/// the system log: a Simulator's `log stream` (the e2e run's timing report) reads them, not only Xcode's console.
public func debugLog(_ message: @autoclosure () -> String) {
  #if DEBUG
    NSLog("%@", message())
  #endif
}
