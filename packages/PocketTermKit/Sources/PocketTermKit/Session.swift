import Combine
import Foundation

/// The connected server ([Backend]) and signing in to it (the server's setup link on a computer, a
/// computer's code on a phone): what the desktop and the phone apps share. Signed in is holding a device
/// token ([Server.account]), kept in [deviceTokens]. Subclasses (each app's) override the hooks; the app
/// hands every URL it's opened with to [openedLink].
@MainActor
open class Session: ObservableObject {
  /// [device]: this machine's name; [deviceTokens]: where its sign-in is kept; [backendStore]: where its
  /// server is kept.
  public init(device: String, deviceTokens: DeviceTokens, backendStore: BackendStore) {
    self.device = device
    self.deviceTokens = deviceTokens
    self.backendStore = backendStore
  }

  /// What this device is to the server: a computer, unless a phone says so. A computer signs in with the
  /// server's setup token, a phone only with a computer's pairing code.
  open var role: DeviceRole { .desktop }

  /// This device's platform, as the server takes it: `macos`, `windows`, `linux`, `ios` or `android`.
  open var platform: String {
    #if os(iOS)
      "ios"
    #elseif os(macOS)
      "macos"
    #else
      "linux"
    #endif
  }

  /// Where this device keeps its sign-in: the Keychain on a computer, the phone's own secure storage.
  public let deviceTokens: DeviceTokens

  /// Where this device keeps its server.
  public let backendStore: BackendStore

  /// The server this device connects through; nil until one is set up (the setup screen shows then).
  @Published public private(set) var backend: Backend?

  /// Only while [backend] is set.
  public private(set) var server: Server?

  /// This machine's name: its label on the server and of its push registration.
  public let device: String

  /// This device, signed in; nil while signed out.
  @Published public private(set) var user: Account?
  private var ended: Task<Void, Never>?

  /// Why the last sign-in or connect didn't happen, for the signed-out pages; nil once one did, and after
  /// signing out.
  @Published public var authError: String?

  /// What a link says to this device while it's signed in, once: one it can't use as is (a code for another
  /// server, a computer's key that wasn't scanned, a code that didn't work). The page in front shows it;
  /// [authError] stays the signed-out pages'.
  public var notices: AsyncStream<String> { noticesBroadcast.stream() }
  private let noticesBroadcast = Broadcaster<String>()

  private func notice(_ message: String) {
    noticesBroadcast.send(message)
    onNotice(message)
  }

  /// A notice went out ([notices]): the computer brings its window up.
  open func onNotice(_ message: String) {}

  /// The key this device holds for [desktopId], if any (a phone's, from a scanned code).
  open func computerKey(_ desktopId: String) -> ChannelKey? { nil }

  /// The link whose sign-in failed only because the Keychain couldn't keep it ([keychainProblem]): [retry]
  /// tries it again.
  @Published public private(set) var retryLink: URL?

  /// What a sign-in says when the Keychain (locked, or missing) didn't let PocketTerm keep it.
  public static let keychainProblem =
    "PocketTerm can\u{2019}t use your keychain (it may be locked or missing). Unlock it in Keychain Access, then "
    + "try again."

  /// Signs in again with [retryLink].
  public func retry() async {
    if let link = retryLink { await connectLink(link) }
  }

  /// Why the last sign-in is gone, once it is (signed out here, the server ended it); nil after a sign-in.
  /// The phone shows it on its scan screen.
  @Published public private(set) var signedOutReason: String?

  /// Set by [signOut] and [eraseServer] just before the sign-in goes.
  private var leaving: String?

  /// The server kept from before this launch, until [connect] is done with it.
  private var saved: Backend?

  /// Launch: opens the server this device was set up with, if any. The app hands every link it's opened
  /// with (`pocketterm://setup?url=…[&code=…|&setup=…]`) to [openedLink], from now on.
  open func start() async {
    saved = Backend.load(from: backendStore)
    if let saved { await connect(saved) }
  }

  /// A setup link opened from outside the app (a web page, a message, the camera app). One that would
  /// connect this signed-out device to a server other than its own ([saved] until [connect] is done) waits
  /// for the person ([linkToConfirm]): anyone can send a link, and this device's sessions would then go
  /// through that server. Any other link goes to [onOtherLink].
  public func openedLink(_ uri: URL) { openedLink(uri, saved: saved ?? Backend.load(from: backendStore)) }

  func openedLink(_ uri: URL, saved: Backend?) {
    guard let backend = Backend.fromLink(uri) else { return onOtherLink(uri) }
    if user == nil && backend != (self.backend ?? saved) {
      linkToConfirm = uri
      onLinkToConfirm()
      return
    }
    Task { await connectLink(uri) }
  }

  /// A setup link to another server, waiting for [answerLink].
  @Published public private(set) var linkToConfirm: URL?

  /// The person's answer to [linkToConfirm]: [connect] goes on with it.
  public func answerLink(connect: Bool) async {
    let uri = linkToConfirm
    linkToConfirm = nil
    if connect, let uri { await connectLink(uri) }
  }

  /// A link now waits in [linkToConfirm]: the computer brings its window up.
  open func onLinkToConfirm() {}

  /// A link opened from outside the app that isn't a setup link (the phone: a followed session's).
  open func onOtherLink(_ uri: URL) {}

  /// A setup link: connects to its server and signs in with what it carries (a computer: the server's setup
  /// token; a phone: a computer's pairing code). A computer key in it ([Backend.computerKey]) goes to
  /// [addComputerKey] only when the link was [scanned] with the in-app scanner, also when already signed in
  /// (a phone scanning one more computer): anyone can send a link from outside the app, and a key it
  /// planted would let them read that computer's sessions. A key that would replace another one held for
  /// that computer counts only once the code's pairing code works ([codeWorks]): only a computer signed in
  /// to this server makes one. Problems land in [authError], or in [notices] while signed in.
  open func connectLink(_ uri: URL, scanned: Bool = false) async {
    guard let backend = Backend.fromLink(uri) else { return }
    let phone = role == .phone
    let secret = phone ? Backend.pairingCode(uri) : Backend.setupToken(uri)
    let computer = scanned ? Backend.computerKey(uri) : nil
    if user != nil {
      if backend != self.backend {
        // A phone keeps one server: a computer on another needs it to leave this one first.
        notice(
          phone
            ? "That code is for a computer on \(backend.host), and this phone is on \(userName). To switch, leave "
              + "this server (Account → Leave this server), then scan the code again."
            : "Sign out before switching to \(backend.host).")
        onPairing(scanned: scanned, failure: .otherServer)
      } else if let computer {
        let held = computerKey(computer.desktop)
        let problem = held == nil || held == computer.key ? nil : await codeWorks(backend, secret)
        if let problem {
          notice(problem)
          onPairing(scanned: scanned, failure: problem == Self.codeUsed ? .codeUsed : .keyRejected)
          return
        }
        await addComputerKey(computer)
        onPairing(scanned: scanned, failure: nil, another: true)
      } else if phone && Backend.computerKey(uri) != nil {
        notice("To connect to a computer, scan its code with PocketTerm's scanner.")
        onPairing(scanned: scanned, failure: .notScanned)
      }
      objectWillChange.send()
      return
    }
    guard let secret else {
      authError =
        phone
        ? "That link has no sign-in code. On your computer, open PocketTerm: Settings → Phone → Add a phone…"
        : "That link has no setup token. On your server, run `pocketterm-server setup-link` and open the link "
          + "it prints."
      onPairing(scanned: scanned, failure: .noCode)
      return
    }
    if backend != self.backend {
      if let problem = await backend.check() {
        authError = problem
        onPairing(scanned: scanned, failure: .serverCheck)
        return
      }
      await connect(backend)
    }
    authError = nil
    retryLink = nil
    do {
      let s = server!
      let account =
        phone
        ? try await s.redeemCode(secret, label: device, platform: platform)
        : try await s.redeemSetup(secret, label: device, platform: platform)
      // Before the sign-in lands, so the computer shows unlocked at once.
      if let computer { await addComputerKey(computer) }
      setUser(account)
      onPairing(scanned: scanned, failure: nil)
    } catch let e as ServerException {
      authError =
        switch e.code {
        case "invalid_code" where phone: Self.codeUsed
        case "invalid_code":
          "That setup link doesn't work: the server has a newer one. Run `pocketterm-server setup-link` on the "
            + "server and open the link it prints."
        default: e.message
        }
      onPairing(scanned: scanned, failure: e.code == "invalid_code" ? .codeUsed : .serverError)
    } catch is SecureStoreError {
      authError = Self.keychainProblem
      retryLink = uri
      onPairing(scanned: scanned, failure: .storage)
    } catch {
      authError = "Sign-in failed: \(error)"
      onPairing(scanned: scanned, failure: .connection)
    }
  }

  /// How a setup link went ([connectLink]): signed in, or with [another] one more computer's key added ([failure]
  /// nil), else why not. [scanned]: read by the in-app scanner. The phone counts it in its usage statistics
  /// (`pairing_completed` / `pairing_failed`); never the link, its host or its code.
  open func onPairing(scanned: Bool, failure: PairingFailure?, another: Bool = false) {}

  static let codeUsed =
    "That code doesn't work: it was used, or it's more than 10 minutes old. Make a new one on your computer "
    + "(Settings → Phone → Add a phone…)."

  /// Whether pairing [code] works on [backend]: it's redeemed by a sign-in of its own that leaves at once.
  /// Nil when it did, else why not.
  private func codeWorks(_ backend: Backend, _ code: String?) async -> String? {
    guard let code else { return Self.codeUsed }
    let probe = makeServer(backend, tokens: MemoryDeviceTokens())
    defer { probe.close() }
    do {
      _ = try await probe.redeemCode(code, label: device, platform: platform)
      try await probe.leave()
      return nil
    } catch let e as ServerException {
      return e.code == "invalid_code" ? Self.codeUsed : e.message
    } catch {
      return "\(error)"
    }
  }

  /// A client for [backend] keeping its sign-in in [tokens].
  open func makeServer(_ backend: Backend, tokens: DeviceTokens) -> Server { Servers.make(backend, tokens: tokens) }

  /// A computer's key from a scanned setup link: the phone keeps it, over any it held for that computer.
  open func addComputerKey(_ computer: ComputerKey) async {}

  /// This computer and its key, for the setup link a phone scans; nil where there's none (a phone).
  open func pairingComputer() async -> ComputerKey? { nil }

  /// A setup link that signs a phone in (POST /v1/pair) and carries this computer's key ([pairingComputer]):
  /// the code works once, for 10 minutes; the key until reset. Only while signed in. Fails with a
  /// [PairingException] that says why.
  open func pairingLink() async throws -> URL {
    guard let server, let backend else { throw PairingException("Not signed in.") }
    let code: String
    do {
      code = try await server.createPairingCode()
    } catch let e as ServerException {
      throw PairingException(e.message)
    }
    return backend.linkWithCode(code, computer: await pairingComputer())
  }

  /// Opens [backend] (and remembers it): the one saved at launch, the setup screen's, or a setup link's,
  /// with the sign-in this device kept for it. With [signInAtOnce] that's signed in before the server says
  /// it still holds; otherwise once it did (or didn't answer). A refusal signs out, with the reason.
  /// Switching needs the user signed out.
  public func connect(_ backend: Backend) async {
    precondition(user == nil, "Sign out before switching servers.")
    closeServer()
    let s = makeServer(backend, tokens: deviceTokens)
    server = s
    backend.save(to: backendStore)
    saved = nil
    self.backend = backend
    authError = nil
    await s.load()
    let stream = s.ended
    ended = Task { @MainActor [weak self] in
      for await _ in stream {
        guard let self else { return }
        self.leaving = self.leaving ?? self.endedReason
        self.setUser(nil)
      }
    }
    if signInAtOnce {
      Task { await s.recheck() }
    } else {
      await s.recheck()
    }
    // Signed out or switched meanwhile: this server's answer no longer counts.
    guard server === s else { return }
    setUser(s.account)
    timing("signed in")
  }

  /// A launch shows the sign-in kept here at once and asks the server about it meanwhile: a phone, which
  /// then shows what it had without waiting on the network. A computer asks first: one running the server
  /// signs in to it anew when it refused the kept one.
  open var signInAtOnce: Bool { false }

  /// Why the sign-in is gone when the server stopped taking it (this device was removed, the server erased),
  /// worded for the person.
  open var endedReason: String {
    role == .phone
      ? "Your sign-in ended on the server. Scan a new code from PocketTerm on your computer."
      : "Your sign-in ended on the server. Open your server's setup link to sign in again."
  }

  /// Signs out and forgets the server: the setup screen shows again.
  open func disconnect() async {
    if user != nil { await signOut() }
    closeServer()
    Backend.clear(in: backendStore)
    saved = nil
    backend = nil
    authError = nil
  }

  private func closeServer() {
    guard let s = server else { return }
    ended?.cancel()
    ended = nil
    s.close()
    server = nil
  }

  /// Runs once a user is signed in (sign-in, or launch while signed in).
  open func onSignedIn(_ user: Account) async {}

  /// Runs before signing out, while the token still works on the server.
  open func onSigningOut() async throws {}

  /// Runs once the sign-in is gone, however that happened (signed out here, the server ended it).
  open func onSignedOut() async {}

  /// [connect]'s restore and the server's answers both report the sign-in: only a change of device runs
  /// [onSignedIn] or [onSignedOut].
  private func setUser(_ user: Account?) {
    if user != nil {
      if signedOutReason != nil { signedOutReason = nil }
      leaving = nil
      if linkToConfirm != nil { linkToConfirm = nil }
    } else if self.user != nil || leaving != nil {
      signedOutReason = leaving ?? endedReason
      leaving = nil
    }
    if user?.device.id == self.user?.device.id {
      if let user, user != self.user { self.user = user }
      return
    }
    self.user = user
    if let user {
      Task { await onSignedIn(user) }
    } else {
      Task { await onSignedOut() }
    }
  }

  /// Signs out: this device leaves the server (its token stops working there, DELETE /v1/devices/me) and
  /// forgets it here, also when [onSigningOut] or the server fails (offline).
  open func signOut() async {
    leaving = leaving ?? "You signed out."
    do {
      try await onSigningOut()
    } catch {
      debugLog("PocketTerm: sign-out cleanup failed: \(error)")
    }
    do {
      try await server?.leave()
    } catch {
      debugLog("PocketTerm: the server missed the sign-out: \(error)")
    }
    forgetError()
    setUser(nil)
  }

  /// A sign-in that went before leaves no problem behind for the next one.
  private func forgetError() {
    authError = nil
    retryLink = nil
  }

  /// This computer runs the server it's connected to (the one built into the app): only then may it erase
  /// it ([eraseServer]).
  open var hostsServer: Bool { false }

  /// Erases everything on the server ([hostsServer] only): every computer and phone is signed out, the images
  /// and push registrations go.
  open func eraseServer() async throws {
    precondition(hostsServer, "Only the computer running the server erases it.")
    do {
      try await onSigningOut()
    } catch {
      debugLog("PocketTerm: sign-out cleanup failed: \(error)")
    }
    try await server!.erase()
    leaving = "This server's data was erased."
    forgetError()
    setUser(nil)
  }

  /// What this device's sign-in is called on screen: its server.
  public var userName: String { backend?.host ?? "you" }

  deinit {
    ended?.cancel()
    noticesBroadcast.finish()
  }
}

/// Why a pairing code couldn't be made, worded for the person.
public struct PairingException: Error, Sendable, CustomStringConvertible, LocalizedError {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var description: String { message }
  public var errorDescription: String? { message }
}
