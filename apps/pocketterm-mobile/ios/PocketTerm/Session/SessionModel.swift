import Combine
import Foundation
import PhotosUI
import PocketTermKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One coding session's page, apart from its drawing: the composer's text (kept as a draft) and attachments, the
/// prompts on their way, and what the page asks of the computer.
final class SessionModel: ObservableObject {
  init(home: HomeModel, remote: TerminalRemote, key: String, starting: Bool, after: AfterSwitch) {
    self.home = home
    self.remote = remote
    self.key = key
    self.starting = starting
    offerContinue = after == .offer
    autoContinue = after == .send
    attachmentsChanged = attachments.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
  }

  let home: HomeModel
  let remote: TerminalRemote
  let key: String

  /// Just launched: its agent may not have reported yet.
  let starting: Bool

  let attachments = ChatAttachments()
  private var attachmentsChanged: AnyCancellable?

  /// What's in the composer.
  @Published var text = "" {
    didSet { if text != oldValue { draftChanged() } }
  }

  /// Prompts sent from here that haven't come back in the transcript yet, oldest first.
  @Published private(set) var outgoing: [Outgoing] = []

  /// A slash command is on its way.
  @Published private(set) var sending = false
  @Published private(set) var stopping = false
  @Published private(set) var loadingOlder = false

  /// Queue, not steer, while the agent works.
  @Published var followUp = false

  /// A Continue chip above the composer prompts it to carry on (it was restarted mid-run), until it went.
  @Published private(set) var offerContinue: Bool

  /// `continue` goes as soon as the session can take a prompt, once; the chip shows only if that fails.
  private var autoContinue: Bool

  /// Tool and notice items showing whole.
  @Published var expanded: Set<String> = []

  /// Just launched, and its agent hasn't reported for [sessionStartWait].
  @Published private(set) var late = false

  /// Bumped to put the cursor in the field; to scroll to the newest.
  @Published private(set) var focusRequest = 0
  @Published private(set) var bottomRequest = 0

  /// The session has been in the computer's state since the page opened.
  private(set) var seen = false

  /// One of [outgoing] is on its way to the computer.
  var delivering: Bool { outgoing.contains { $0.sending } }

  private var unwatch: (@MainActor () -> Void)?
  private var stopListening: (@MainActor () -> Void)?
  private var visible = false
  private var lateTimer: Task<Void, Never>?

  // MARK: Lifecycle

  /// The page shows (again): the computer hears it's watched, the draft comes back.
  func appear() {
    visible = true
    if unwatch == nil { unwatch = remote.watchSession(key) }
    if stopListening == nil { stopListening = remote.addListener { [weak self] in self?.remoteChanged() } }
    if !draftLoaded {
      draftLoaded = true
      let draft = home.app.drafts.load(draftKey)
      // Typed before it came: what's in the field wins.
      if !draft.isEmpty && text.isEmpty {
        savedDraft = draft
        text = draft
      }
    }
    if starting && lateTimer == nil {
      lateTimer = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(sessionStartWait))
        if !Task.isCancelled { self?.late = true }
      }
    }
    remoteChanged()
  }

  /// The page went from the screen: covered by another (its screen) it stays watched; gone, it stops.
  func disappear() {
    visible = false
    saveDraft()
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, !self.visible, !self.onPath else { return }
      self.unwatch?()
      self.unwatch = nil
      self.stopListening?()
      self.stopListening = nil
      self.lateTimer?.cancel()
    }
  }

  /// Whether the page is among those open over the list.
  private var onPath: Bool {
    home.path.contains { if case .session(let k, _, _) = $0 { k == key } else { false } }
  }

  /// Whether the page is the one in front.
  private var onTop: Bool {
    if visible, case .session(let k, _, _)? = home.path.last { return k == key }
    return false
  }

  private func remoteChanged() {
    if remote.session(key) != nil { seen = true }
    let left = stillOutgoing(outgoing, view: remote.view(key), summary: remote.session(key))
    if left.count != outgoing.count { outgoing = left }
    continueWhenReady()
  }

  // MARK: Drafts

  // The unsent text is kept per session (Drafts); attachments aren't.
  private var draftKey: String { routedKey(remote.desktopId, key) }
  private var draftLoaded = false
  private var savedDraft = ""
  private var draftSoon: Task<Void, Never>?

  private func draftChanged() {
    draftSoon?.cancel()
    draftSoon = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      if !Task.isCancelled { self?.saveDraft() }
    }
  }

  func saveDraft() {
    draftSoon?.cancel()
    guard draftLoaded, text != savedDraft else { return }
    savedDraft = text
    home.app.drafts.save(draftKey, text)
  }

  // MARK: What the session is

  /// The terminal window the agent runs in, if it runs in one (a launched one before it reports: the session's key
  /// is its window's).
  func windowKey(_ s: LiveSummary?) -> String? { s?.window ?? (remote.window(key) != nil ? key : nil) }

  /// Whether there's a [window] and its terminal can do [cap]; one not in the list yet (just launched) can do
  /// everything.
  func can(_ window: String?, _ cap: TermCap) -> Bool {
    guard let window else { return false }
    return remote.window(window)?.can(cap) ?? true
  }

  /// The session's agent: as it reports, else its window's program, else the one the computer starts (a
  /// just-launched session).
  func agent(_ s: LiveSummary?) -> Agent { s?.agent ?? remote.window(key)?.agent ?? remote.agent }

  // MARK: Sending

  private func toast(_ message: String) { Toaster.shared.show(message) }

  func send(busy: Bool) async {
    let typed = text
    let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    if (trimmed.isEmpty && attachments.isEmpty) || attachments.loading || sending || delivering { return }
    let attached = attachments.items
    let s = remote.session(key)
    // A slash command is typed into the agent's window, where its editor reads it; sent as a prompt, the agent
    // would take it for chat.
    let command = trimmed.hasPrefix("/")
    if command && !attached.isEmpty { return toast("Slash commands can't take images or files.") }
    if command && !can(windowKey(s), .line) { return toast(noCommandsText(agent(s))) }
    let queue = busy && (followUp || !agent(s).steers)
    Haptics.done()
    if !command { return await prompt(trimmed, attached, followUp: queue) }
    sending = true
    do {
      let before = remote.session(key)?.id
      try await remote.prompt(key, trimmed, followUp: queue)
      if let window = remote.session(key)?.window { Task { await menuOrScreen(window, before) } }
      // Only what went: the field stays editable while it goes, and what was typed meanwhile is the next prompt.
      let now = text
      text = now.hasPrefix(typed) ? String(String(now.dropFirst(typed.count)).drop { $0.isWhitespace }) : now
      bottomRequest += 1
    } catch {
      toast(errorText(error))
    }
    sending = false
  }

  /// What was said goes after what's typed; Send then sends it all as Send would now (steering, queued or not,
  /// with the attachments), and what can't go yet stays in the field. Insert leaves it there to go on typing.
  func voiced(_ r: VoiceResult) {
    text = appendSpoken(text, r.text)
    if r.send {
      Task { await send(busy: remote.session(key)?.busy ?? false) }
    } else {
      focusRequest += 1
    }
  }

  /// Sends [text] and [attached] as the person's message, which shows at once at the bottom of the transcript
  /// while the field and the attachments are free for the next one.
  private func prompt(_ text: String, _ attached: [ChatAttachment], followUp: Bool) async {
    // A prompt of their own replaces the `continue` a restart would send, and says what comes next instead of
    // Continue.
    autoContinue = false
    offerContinue = false
    let o = Outgoing(text, attached, followUp: followUp, transcript: remote.view(key))
    self.text = ""
    attachments.removeSent(attached)
    bottomRequest += 1
    outgoing.append(o)
    await deliver(o)
  }

  /// A failed prompt, sent again as it was.
  func retry(_ o: Outgoing) {
    guard !o.sending, o.problem != nil else { return }
    Task { await deliver(o) }
  }

  /// Sends [o] (again): a failure stays on its bubble, with why.
  private func deliver(_ o: Outgoing) async {
    o.sending = true
    o.problem = nil
    objectWillChange.send()
    do {
      o.queued = try await remote.prompt(
        key, o.text,
        images: o.attachments.compactMap { $0.image?.bytes },
        files: o.attachments.compactMap { a in a.file.map { PromptFile(name: $0.name, mime: $0.mime, bytes: $0.bytes) } },
        followUp: o.followUp)
      // Followed from here on (Lock Screen), as working.
      prompted()
    } catch {
      o.problem = errorText(error)
    }
    o.sending = false
    objectWillChange.send()
    remoteChanged()
  }

  /// A prompt went: the session is followed from here on, as working, if the phone can show one more.
  private func prompted() {
    guard let s = remote.session(key), let activities = remote.activities else { return }
    let key = key
    Task { try? await activities.prompted(key, title: sessionTitle(s)) }
  }

  /// Prompts `continue`: the run a restart from the phone stopped carries on. Once; again only if it didn't go.
  func sendContinue() async {
    offerContinue = false
    do {
      try await remote.prompt(key, "continue")
      prompted()
      bottomRequest += 1
    } catch {
      offerContinue = true
      toast(errorText(error))
    }
  }

  /// Prompts `continue` once the session is there, at rest, and the phone is online.
  private func continueWhenReady() {
    guard autoContinue, let s = remote.session(key), remote.online, !s.busy, !sending else { return }
    autoContinue = false
    Task { await sendContinue() }
  }

  /// A command's picker (/resume, /model, /tree …) shows here as a menu once the computer has read it off the
  /// agent's screen; when none comes (a command without one, or one the computer can't read), its screen opens
  /// instead. A command that renewed the session (/new, /clear) shows its result here, so nothing opens: [before]
  /// is the session's id when it was sent.
  private func menuOrScreen(_ window: String, _ before: String?) async {
    func renewed() -> Bool { before != nil && (remote.session(key)?.id ?? before) != before }
    for _ in 0..<12 {
      try? await Task.sleep(for: .milliseconds(250))
      if !onTop || remote.session(key)?.ask?.isMenu == true || renewed() { return }
    }
    if renewed() { return }
    if onTop && can(window, .read) { home.openWindow(window) }
  }

  /// Puts `/name ` in the field, the cursor after it.
  func complete(_ c: LiveCommand) { text = "/\(c.name) " }

  func stop() async {
    stopping = true
    do { try await remote.abort(key) } catch { toast(errorText(error)) }
    stopping = false
  }

  func older() async {
    loadingOlder = true
    do { try await remote.older(key) } catch { toast(errorText(error)) }
    loadingOlder = false
  }

  func toggleFollow(_ activities: LiveActivities, _ s: LiveSummary) async {
    if activities.following(key) { return await activities.stop(key) }
    var problem: String?
    do {
      if !(try await activities.follow(key, title: sessionTitle(s))) {
        problem = "Live Activities are off for PocketTerm: turn them on in Settings \u{2192} PocketTerm."
      }
    } catch is TooManyActivities {
      problem =
        "Your iPhone shows only a few Live Activities at once. Stop following another session, or end one on the "
        + "Lock Screen, then try again."
    } catch {
      problem = errorText(error)
    }
    if let problem { toast(problem) }
  }

  func toggle(_ item: String) {
    if expanded.contains(item) { expanded.remove(item) } else { expanded.insert(item) }
  }

  // MARK: Attachments

  /// The clipboard's images, as they are.
  private func clipboardImages() -> [Data] {
    var raws: [Data] = []
    for item in UIPasteboard.general.items {
      for (type, value) in item {
        guard UTType(type)?.conforms(to: .image) == true else { continue }
        if let d = value as? Data {
          raws.append(d)
        } else if let image = value as? UIImage, let d = image.pngData() {
          raws.append(d)
        } else {
          continue
        }
        break
      }
    }
    return raws
  }

  func pasteImage() async {
    if !(await attachments.paste(clipboardImages())) { toast("There is no image on the clipboard.") }
  }

  /// Photos the picker handed back, read while a placeholder shows.
  func addPhotos(_ picked: [PhotosPickerItem]) async {
    do {
      try await attachments.pick { _ in
        var raws: [Data] = []
        for p in picked {
          if let d = try await p.loadTransferable(type: Data.self) { raws.append(d) }
        }
        return raws
      }
    } catch {
      toast(errorText(error))
    }
  }

  func addFiles(_ urls: [URL]) async {
    do {
      try await attachments.addFiles(urls.map { PickedURLFile($0) })
    } catch {
      toast(errorText(error))
    }
  }
}
