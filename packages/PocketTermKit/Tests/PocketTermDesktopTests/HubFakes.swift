#if os(macOS)
import Foundation
import PocketTermKit
import PocketTermTerminals
import XCTest

@testable import PocketTermDesktop

/// An extension's side of its connection to the hub: what it sends goes in as frames, what the hub sends comes out
/// through `request`. `close` (the hub closing it, or the extension going) ends the frames.
@MainActor
final class HubFakeExt: LiveLink {
  private let input: AsyncStream<String>.Continuation
  private var received: [JSONObject] = []
  private var waiter: CheckedContinuation<JSONObject, Never>?
  private var waitTimer: MainTimer?
  private(set) var closed = false

  init(_ hub: LiveHub) {
    let (frames, input) = AsyncStream.makeStream(of: String.self)
    self.input = input
    Task { await hub.accept(frames, self) }
  }

  // The hub's side.
  func send(_ frame: String) {
    guard let m = JSON.tryParse(frame)?.object else { return XCTFail("not a JSON object: \(frame)") }
    if let w = waiter {
      waiter = nil
      waitTimer?.cancel()
      w.resume(returning: m)
    } else {
      received.append(m)
    }
  }

  func close() async { end() }

  // The extension's side.
  func end() {
    closed = true
    input.finish()
  }

  func ext(_ m: JSONObject) { input.yield(m.encoded()) }

  func raw(_ frame: String) { input.yield(frame) }

  /// The next frame from the hub; an empty one (and a failure) when none comes within 5 s.
  func request(file: StaticString = #filePath, line: UInt = #line) async -> JSONObject {
    if !received.isEmpty { return received.removeFirst() }
    return await withCheckedContinuation { c in
      waiter = c
      waitTimer = MainTimer(5) { [weak self] in
        guard let self, let w = self.waiter else { return }
        self.waiter = nil
        XCTFail("no frame from the hub", file: file, line: line)
        w.resume(returning: [:])
      }
    }
  }

  var pending: Int { received.count }

  func hello(
    window: String? = "kitty-1/7", id: String = "s1", items: [JSON] = [], commands: [JSON] = []
  ) {
    ext([
      "t": "hello", "v": 1,
      "session": ["id": .string(id), "title": "Fix bug", "cwd": "/Users/me/Dev/pocketterm", "model": "m"],
      "window": window.map(JSON.string) ?? .null, "pid": 42, "busy": false, "items": .array(items), "older": false,
      "commands": .array(commands),
    ])
  }
}

/// Waits until `check` holds (the hub reads frames asynchronously).
@MainActor
func hubUntil(
  _ check: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line
) async {
  for _ in 0..<400 where !check() { try? await Task.sleep(nanoseconds: 5_000_000) }
  XCTAssertTrue(check(), "never came true", file: file, line: line)
}

/// The hub's events as they come.
@MainActor
final class HubEventLog {
  private(set) var events: [LiveEvent] = []
  private var task: Task<Void, Never>?

  init(_ hub: LiveHub) {
    let stream = hub.events
    task = Task { [weak self] in
      for await e in stream { self?.events.append(e) }
    }
  }

  var finished: [String] {
    events.compactMap { if case .finished(_, let summary) = $0 { summary } else { nil } }
  }

  var asked: [LiveAsk] { events.compactMap { if case .asked(_, let ask) = $0 { ask } else { nil } } }

  deinit { task?.cancel() }
}

/// A folder of its own in the temp folder, gone at `remove`.
func hubTempDir(_ prefix: String) -> String {
  var template = Array("\(NSTemporaryDirectory())\(prefix)XXXXXX".utf8CString)
  return String(cString: mkdtemp(&template)!)
}

/// Ghostty listing these windows (as they are when asked).
final class HubListedGhostty: Ghostty, @unchecked Sendable {
  private let lock = NSLock()
  private var windowsNow: [TermWindow]
  init(_ listed: [TermWindow]) {
    windowsNow = listed
    super.init(appPath: "/nonexistent-pocketterm/Ghostty.app")
  }
  var listed: [TermWindow] {
    get { lock.withLock { windowsNow } }
    set { lock.withLock { windowsNow = newValue } }
  }
  override func windows(_ procs: Procs) async throws -> [TermWindow] { listed }
}

/// kitty as the bridge drives it: what it's told goes to `log`; its screen is `screens` in turn.
final class BridgeFakeKitty: Kitty, @unchecked Sendable {
  private let lock = NSLock()
  private var logged: [String] = []
  private var shown: [String] = [""]

  init() { super.init(home: "/nonexistent-pocketterm", socketDir: "/nonexistent-pocketterm", restoreFront: false) }

  var log: [String] {
    get { lock.withLock { logged } }
    set { lock.withLock { logged = newValue } }
  }
  var screens: [String] {
    get { lock.withLock { shown } }
    set { lock.withLock { shown = newValue } }
  }
  func add(_ line: String) { lock.withLock { logged.append(line) } }

  override func pressKeys(_ key: String, _ names: [String]) async throws { add("keys \(names.joined(separator: " "))") }
  override func type(_ key: String, _ text: String) async throws { add("type \(text)") }
  override func plainScreen(_ key: String) async throws -> String {
    lock.withLock { shown.count > 1 ? shown.removeFirst() : shown[0] }
  }
}

/// Ghostty with one window whose title is `titles` in turn (none: no window).
final class BridgeFakeGhostty: Ghostty, @unchecked Sendable {
  private let lock = NSLock()
  private var queue: [String] = []
  init() { super.init(appPath: "/nonexistent-pocketterm/Ghostty.app") }
  var titles: [String] {
    get { lock.withLock { queue } }
    set { lock.withLock { queue = newValue } }
  }
  override func windows(_ procs: Procs) async throws -> [TermWindow] {
    let title: String? = lock.withLock { queue.isEmpty ? nil : (queue.count > 1 ? queue.removeFirst() : queue[0]) }
    guard let title else { return [] }
    return [
      TermWindow(
        key: "ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074", title: title, tab: "", cwd: "/p/chat", program: "",
        app: "ghostty", caps: caps)
    ]
  }
}
#endif
