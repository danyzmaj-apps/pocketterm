import Foundation
import PocketTermKit

// "Try the demo": the real app on a made-up computer, answered right here on
// the phone. Two projects with coding sessions (one finished, one waiting for
// an approval, one at work), their conversations and plain terminal windows.
// Nothing goes over the network. The docs' screenshots draw the same data.

let demoHome = "/Users/demo"
let demoGarden = "\(demoHome)/Dev/garden-api"
let demoSite = "\(demoHome)/Dev/pocketterm-site"

/// The pretend computer's name.
let demoDesktopName = "MacBook Pro"

/// A window that shows only its screen (omp at work in it, not reporting).
let demoScreenOnly = "kitty-1/7"

/// What every op the demo can't pretend says.
let demoNoComputer =
  "This is the demo, so there's no computer to do that. Scan your computer's code to use PocketTerm for real."

private func millis(_ d: Date) -> JSON { .int(Int((d.timeIntervalSince1970 * 1000).rounded(.down))) }

/// The sessions, as the computer sends them in its state; [overrides] by session key.
func demoSessions(_ now: Date, _ overrides: [String: JSONObject]) -> [JSONObject] {
  func ago(_ minutes: Double) -> JSON { millis(now.addingTimeInterval(-minutes * 60)) }
  let base: [JSONObject] = [
    [
      "key": "kitty-1/3", "id": "s1", "agent": "omp", "window": "kitty-1/3",
      "title": "Add a soil moisture endpoint", "cwd": .string(demoGarden), "model": "Sonnet 4.5",
      "ctx": 23, "cost": 1.86, "at": ago(4), "epoch": "e1", "seq": 7,
    ],
    [
      "key": "wezterm-2", "id": "s2", "agent": "claude", "window": "wezterm-2",
      "title": "Fix the pricing table on small screens", "cwd": .string(demoSite), "model": "Opus 4.5",
      "ctx": 61, "cost": 12.4,
      "ask": ["kind": "approval", "id": "a1", "tool": "Bash", "summary": "npm run build"],
      "at": ago(1), "epoch": "e1", "seq": 4,
    ],
    [
      "key": "tmux-%4", "id": "s3", "agent": "omp", "window": "tmux-%4",
      "title": "Rate-limit the plant search", "cwd": .string(demoGarden), "model": "GPT-5.5",
      "busy": true, "ctx": 84, "cost": 43.34, "at": ago(0), "epoch": "e1", "seq": 5,
    ],
  ]
  return base.map { s in s.merging(overrides[s["key"]?.string ?? ""] ?? [:]) { _, new in new } }
}

/// The computer's state: three coding sessions (finished, needing you,
/// working), a window showing only its screen and three plain terminal
/// windows, in two projects, sitting in three app windows (kitty, WezTerm, Ghostty with tmux).
func demoState(now: Date = Date(), overrides: [String: JSONObject] = [:]) -> JSONObject {
  let windows: [JSON] = [
    [
      "key": "kitty-1/3", "title": "omp", "cwd": .string(demoGarden), "program": "omp", "app": "kitty",
      "osWindow": "kitty-1/os1", "tabId": "kitty-1/t1",
    ],
    [
      "key": "wezterm-2", "title": "claude", "cwd": .string(demoSite), "program": "claude", "app": "wezterm",
      "osWindow": "wezterm-os1", "tabId": "wezterm-t1",
    ],
    [
      "key": "tmux-%4", "title": "omp", "cwd": .string(demoGarden), "program": "omp", "app": "tmux",
      "via": "Ghostty", "osWindow": "ghostty-os1", "tabId": "ghostty-t1",
    ],
    [
      "key": "kitty-1/1", "title": "zsh", "cwd": .string(demoGarden), "program": "zsh", "app": "kitty",
      "focused": true, "osWindow": "kitty-1/os1", "tabId": "kitty-1/t2",
    ],
    [
      "key": "tmux-%2", "title": "nvim README.md", "cwd": .string(demoSite), "program": "nvim", "app": "tmux",
      "via": "Ghostty", "osWindow": "ghostty-os1", "tabId": "ghostty-t2",
    ],
    [
      "key": .string(demoScreenOnly), "title": "omp", "cwd": .string(demoGarden), "program": "omp",
      "app": "kitty", "osWindow": "kitty-1/os1", "tabId": "kitty-1/t3",
    ],
  ]
  return [
    "windows": .array(windows),
    "sessions": .array(demoSessions(now, overrides).map(JSON.object)),
    "projects": .strings([demoGarden, demoSite]),
    "home": .string(demoHome),
    "agent": "omp",
    "agents": ["omp": "installed", "claude": "installed"],
    "opensIn": "kitty",
    "placement": "projectWindow",
  ]
}

private func item(
  _ order: Int, _ kind: ItemKind, text: String = "", tool: String = "", title: String = "", output: String = ""
) -> LiveItem {
  LiveItem(
    id: "it\(order)", kind: kind, text: text, tool: tool, title: title, output: output, status: .ok, order: order,
    seq: order)
}

/// Each session's conversation, oldest first.
func demoTranscripts() -> [String: [LiveItem]] {
  [
    "kitty-1/3": [
      item(
        1, .user,
        text: "Add GET /plants/:id/moisture: the last 24 hours of soil readings, newest first. "
          + "Reuse the sensor repo, and add tests."),
      item(2, .assistant, text: "Let me look at how the readings are stored first."),
      item(3, .tool, tool: "read", title: "src/sensors/repo.ts"),
      item(4, .tool, tool: "read", title: "src/routes/plants.ts"),
      item(5, .tool, tool: "edit", title: "src/routes/plants.ts"),
      item(
        6, .tool, tool: "bash", title: "npm test -- moisture",
        output: " PASS  test/moisture.test.ts\n"
          + "  ✓ last 24 h, newest first (18 ms)\n"
          + "  ✓ 404 for an unknown plant (4 ms)\n"
          + "\n"
          + "Tests:  2 passed, 2 total"),
      item(
        7, .assistant,
        text: "Done. `GET /plants/:id/moisture` now returns the last 24 h of readings:\n\n"
          + "- `SensorRepo.readingsSince()` runs the query, on the `(plant_id, taken_at)` index\n"
          + "- an unknown plant gets a **404**\n"
          + "- `test/moisture.test.ts` covers both\n\n"
          + "Want a `?hours=` parameter as well?"),
    ],
    "wezterm-2": [
      item(
        1, .user,
        text:
          "The pricing table overflows on phones. Stack the plans under 640 px and keep the Pro column highlighted."),
      item(2, .tool, tool: "Read", title: "src/components/Pricing.tsx"),
      item(3, .tool, tool: "Edit", title: "src/components/Pricing.tsx"),
      item(
        4, .assistant,
        text: "The plans now stack below 640 px, Pro first and still highlighted. I want to build the site to check it."),
    ],
    "tmux-%4": [
      item(
        1, .user,
        text: "Rate-limit GET /plants/search to 30 requests a minute per API key, with a Retry-After header."),
      item(2, .tool, tool: "read", title: "src/middleware/auth.ts"),
      item(3, .tool, tool: "write", title: "src/middleware/rateLimit.ts"),
      item(4, .tool, tool: "edit", title: "src/routes/search.ts"),
      item(5, .assistant, text: "The limiter is in place. Running the integration tests now."),
    ],
  ]
}

/// What each terminal window shows.
func demoScreen(_ window: String) -> [String] {
  switch window {
  case demoScreenOnly:
    [
      " Import the 2026 seed list from suppliers.csv",
      "",
      " I will read the CSV, match each row to a catalog entry and",
      " add the new varieties with their sowing months.",
      "",
      " ╭──────────────────────────────────────────────╮",
      " │ $ python scripts/import_seeds.py suppliers.csv │",
      " ├─── Output ───────────────────────────────────┤",
      " │ 412 rows read                                │",
      " │ 388 matched, 24 new                          │",
      " ╰──────────────────────────────────────────────╯",
      "",
      " ⠼ 41s > Opus > garden-api",
      "╰─",
    ]
  case "tmux-%2":
    [
      "# PocketTerm site",
      "",
      "The marketing site, built with Astro.",
      "",
      "## Develop",
      "",
      "    npm install",
      "    npm run dev",
      "~",
      "~",
      "\"README.md\" 9L, 112B",
    ]
  default:
    [
      "demo@MacBook-Pro garden-api % git status",
      "On branch main",
      "Your branch is up to date with 'origin/main'.",
      "",
      "nothing to commit, working tree clean",
      "demo@MacBook-Pro garden-api % ",
    ]
  }
}

/// The demo's computer: its list (one computer) and its remote, answering
/// the app's messages itself. [dispose] when the demo ends.
final class DemoComputer {
  static let desktopId = "demo0000"

  let desktops: Desktops
  let remote: TerminalRemote

  private let cache: URL
  private var timer: Task<Void, Never>?
  private var running = true
  private var transcripts = demoTranscripts()
  private var overrides: [String: JSONObject] = [
    // Prompts waiting for the run at work to end, to look at, change and move in the queue.
    "tmux-%4": [
      "queue": [
        ["id": "dq1", "t": "Add a test for the 429 answer and its Retry-After header."],
        [
          "id": "dq2",
          "t": .string(
            "Then make the limit configurable per API key, 60 requests a minute by default. Read it from "
              + "config/limits.yaml, fall back to the default when a key has no entry, and log once at startup "
              + "which keys have a limit of their own. Keep the middleware small: the lookup goes in a function of "
              + "its own, so it can be tested without a server running."),
        ],
        ["id": "dq3", "t": "This trace is from production: is it the same bug?", "im": 1],
        ["id": "dq4", "t": "Update the limits section of the docs.", "f": ["limits.md"]],
      ]
    ]
  ]
  private var queued = 4

  /// Never asked anything: the list and the remote are fed here.
  private static let nowhere = PocketTermServerClient(Backend(url: "http://localhost:1"), tokens: MemoryDeviceTokens())

  init(cacheDir: URL) {
    cache = cacheDir
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    desktops = Desktops(
      Self.nowhere,
      cached: [Desktop(id: Self.desktopId, name: demoDesktopName, platform: "macos", seenAt: Date())],
      saved: Self.desktopId)
    // The remote's send hook needs self, which isn't there yet: route through a box.
    let box = WeakBox()
    remote = TerminalRemote(
      Self.nowhere, supportDir: cacheDir, desktopId: Self.desktopId,
      key: ChannelKey(Data(repeating: 7, count: ChannelKey.length))!,
      // Answered later, as Dart's scheduleMicrotask: never inside the remote's own call.
      send: { event, payload in Task { @MainActor in box.demo?.receive(event, payload) } },
      // Images go nowhere either.
      upload: { _, _ in },
      from: "demo-phone")
    box.demo = self
    sendState()
    // As a computer does: its state keeps coming, so it reads as online.
    timer = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled, let self else { return }
        self.sendState()
      }
    }
  }

  private final class WeakBox { weak var demo: DemoComputer? }

  private func sendState() { remote.handle("state", demoState(overrides: overrides)) }

  private func sendItems(_ session: String) {
    guard let items = transcripts[session] else { return }
    remote.handle(
      "items",
      [
        "to": .string(remote.from), "session": .string(session), "epoch": "e1", "seq": .int(items.count),
        "reset": true, "last": true, "older": false, "items": .array(items.map { .object($0.toJson()) }),
      ])
  }

  private func receive(_ event: String, _ p: JSONObject) {
    guard running else { return }
    switch event {
    case "hello":
      sendState()
    case "sync" where p["session"]?.string != nil:
      sendItems(p["session"]!.string!)
    case "sync" where p["window"]?.string != nil:
      let window = p["window"]!.string!
      remote.handle("screen", ["window": .string(window), "v": 1, "lines": .strings(demoScreen(window))])
    case "run":
      var answer = run(p)
      answer["id"] = p["id"] ?? .null
      remote.handle("ran", answer)
    default:
      break
    }
  }

  /// A conversation goes on: [items] added to [session], its summary [summary].
  private func add(_ session: String, _ items: [(ItemKind, String)], _ summary: JSONObject) {
    var list = transcripts[session] ?? []
    for (kind, text) in items { list.append(item(list.count + 1, kind, text: text)) }
    transcripts[session] = list
    var o = overrides[session] ?? [:]
    o.merge(summary) { _, new in new }
    o["seq"] = .int(list.count)
    o["at"] = millis(Date())
    overrides[session] = o
    sendState()
    sendItems(session)
  }

  /// What the computer answers to a `run`: nothing is done, the conversation just goes on as if.
  private func run(_ p: JSONObject) -> JSONObject {
    let session = p["session"]?.string
    let op = p["op"]?.string
    if op == "prompt", let session, p["deliver"]?.string == "followUp", busy(session) {
      queued += 1
      let id = "dq\(queued)"
      setQueue(session, queue(session) + [["id": .string(id), "t": .string(p["text"]?.string ?? "")]])
      return ["queued": .string(id)]
    }
    if op == "queue", let session { return changeQueue(session, p) }
    if op == "prompt", let session {
      add(
        session,
        [
          (.user, p["text"]?.string ?? ""),
          (
            .assistant,
            "This is the demo: there's no computer behind it, so nothing ran. Scan your computer's code to send "
              + "prompts for real."
          ),
        ], ["busy": false])
      return [:]
    }
    if op == "answer", let session {
      let approved = p["approve"]?.bool == true
      add(
        session,
        [
          (
            .assistant,
            approved
              ? "Built in 6.2 s. The pricing table stacks on small screens and the Pro plan stays highlighted."
              : "Okay, I won't build it. The change is in src/components/Pricing.tsx when you want to check it."
          )
        ], ["ask": .null, "busy": false])
      return [:]
    }
    if op == "probe" { return ["busy": .bool(p["window"]?.string == demoScreenOnly)] }
    if op == "older" { return [:] }
    return ["error": .string(demoNoComputer)]
  }

  private func busy(_ session: String) -> Bool {
    demoSessions(Date(), overrides).contains { $0["key"]?.string == session && $0["busy"]?.bool == true }
  }

  private func queue(_ session: String) -> [JSONObject] {
    (overrides[session]?["queue"]?.array ?? []).compactMap(\.object)
  }

  private func setQueue(_ session: String, _ queue: [JSONObject], paused: Bool? = nil) {
    var o = overrides[session] ?? [:]
    let wasPaused = o["paused"]?.bool == true
    o["queue"] = .array(queue.map(JSON.object))
    o["paused"] = .bool(!queue.isEmpty && (paused ?? wasPaused))
    overrides[session] = o
    sendState()
  }

  /// The phone's change to [session]'s queue, as the computer makes it (LiveHub in apps/pocketterm-desktop).
  private func changeQueue(_ session: String, _ p: JSONObject) -> JSONObject {
    var queue = queue(session)
    let at = queue.firstIndex { $0["id"] != nil && $0["id"] == p["item"] }
    let what = p["do"]?.string
    guard let at else {
      if what == "pause" || what == "resume" {
        setQueue(session, queue, paused: what == "pause")
        return [:]
      }
      return ["error": "That prompt has gone to the agent already."]
    }
    switch what {
    case "edit":
      queue[at]["t"] = .string(p["text"]?.string ?? "")
    case "remove":
      queue.remove(at: at)
    case "move":
      let q = queue.remove(at: at)
      let to = p["to"]?.number.map { Int($0) } ?? 0
      queue.insert(q, at: min(max(to, 0), queue.count))
    case "send":
      let q = queue.remove(at: at)
      setQueue(session, queue)
      add(session, [(.user, q["t"]?.string ?? "")], [:])
      return [:]
    case "pause", "resume":
      setQueue(session, queue, paused: what == "pause")
      return [:]
    default:
      break
    }
    setQueue(session, queue)
    return [:]
  }

  func dispose() {
    timer?.cancel()
    timer = nil
    running = false
    remote.dispose()
    desktops.dispose()
    do {
      try FileManager.default.removeItem(at: cache)
    } catch {
      print("PocketTerm: demo cache: \(error)")
    }
  }
}
