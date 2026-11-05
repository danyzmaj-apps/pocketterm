import Combine
import Foundation

/// A computer running PocketTerm on this server (GET /v1/desktops): it refreshes [seenAt] every minute while
/// its terminal bridge runs, and the phone talks to it on its own topic, its id.
public struct Desktop: Sendable, Hashable, Identifiable {
  public init(id: String, name: String, platform: String, seenAt: Date) {
    self.id = id
    self.name = name
    self.platform = platform
    self.seenAt = seenAt
  }

  /// Nil when a field is missing or `seen_at` isn't a date (Dart throws there).
  public init?(json j: JSONObject) {
    guard let id = j["id"]?.string, let name = j["name"]?.string, let platform = j["platform"]?.string,
      let seenAt = DartDate.tryParse(j["seen_at"]?.string)
    else { return nil }
    self.init(id: id, name: name, platform: platform, seenAt: seenAt)
  }

  /// 8 characters, a-z and 0-9.
  public let id: String
  public let name: String

  /// `macos` or `windows`.
  public let platform: String
  public let seenAt: Date

  public var windows: Bool { platform == "windows" }

  /// It has said so within two and a half of its one-minute beats.
  public var online: Bool { Date().timeIntervalSince(seenAt) < Self.onlineWithin }

  /// How recently a computer has to have said it's there to count as [online], in seconds.
  public static let onlineWithin: TimeInterval = 150

  public func toJson() -> JSONObject {
    [
      "id": .string(id), "name": .string(name), "platform": .string(platform),
      "seen_at": .string(DartDate.utcIso8601(seenAt)),
    ]
  }
}

/// Phone: the server's computers, newest seen first, and the one the Terminal tab shows ([selected]).
@MainActor
public final class Desktops: ObservableObject {
  /// [cached]: the list as last seen, [saved]: the computer last shown, both from before this launch (shown
  /// until the server says otherwise); [onChanged] keeps them for the next one.
  public init(
    _ server: Server, cached: [Desktop] = [], saved: String? = nil,
    onChanged: ((_ all: [Desktop], _ selected: String?) -> Void)? = nil
  ) {
    self.server = server
    all = cached
    selectedId = saved
    self.onChanged = onChanged
  }

  private let server: Server

  /// The list or the selection changed.
  public let onChanged: ((_ all: [Desktop], _ selected: String?) -> Void)?

  /// Computers seen this long ago or longer aren't listed, in seconds (30 days).
  public static let keepFor: TimeInterval = 30 * 24 * 3600

  @Published public private(set) var all: [Desktop]

  /// The server has answered since launch.
  @Published public private(set) var loaded = false

  @Published private var selectedId: String?

  public var selected: Desktop? { all.first { $0.id == selectedId } }

  /// Why the last [refresh] got no list (the server can't be reached, say); nil once one came.
  @Published public private(set) var error: String?

  /// Fetches the list; on failure the last one stays, and [error] says why. One that comes back after
  /// [dispose] (signed out meanwhile) is dropped: it would keep the old server's computers for the next
  /// sign-in.
  public func refresh() async {
    do {
      let rows = try await server.desktops()
      timing("computers listed")
      if !disposed { apply(rows) }
    } catch {
      timing("computers failed")
      debugLog("PocketTerm: computers: \(error)")
      let why = (error as? ServerException)?.message ?? "\(error)"
      if disposed || why == self.error { return }
      self.error = why
    }
  }

  private var disposed = false

  public func dispose() { disposed = true }

  /// The rows from the server, newest seen first.
  func apply(_ rows: [JSONObject]) {
    let now = Date()
    all = rows.compactMap(Desktop.init(json:)).filter { now.timeIntervalSince($0.seenAt) < Self.keepFor }
    loaded = true
    error = nil
    pick()
    onChanged?(all, selectedId)
  }

  /// The person shows [id]'s sessions.
  public func select(_ id: String) {
    if id == selectedId || !all.contains(where: { $0.id == id }) { return }
    selectedId = id
    onChanged?(all, selectedId)
  }

  /// The person just scanned [id]'s code: it's shown now if listed, else as soon as [apply] lists it,
  /// whichever computer was seen last.
  public func show(_ id: String) {
    if all.contains(where: { $0.id == id }) {
      wanted = nil
      select(id)
    } else {
      wanted = id
    }
  }

  private var wanted: String?

  /// The one asked for by [show] once listed; else the one shown stays while listed; else the newest seen
  /// (kept from then on, so it doesn't flip as computers take turns being newest); else none.
  private func pick() {
    if let w = wanted, all.contains(where: { $0.id == w }) {
      selectedId = w
      wanted = nil
    }
    if selected == nil { selectedId = all.first?.id }
  }
}
