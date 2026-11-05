import Combine
import PocketTermKit
import SwiftUI

/// The queue screen's state: the computer's queue as shown here, what's being edited, what just went.
final class QueueScreenModel: ObservableObject {
  init(remote: TerminalRemote, session: String) {
    self.remote = remote
    self.session = session
    last = remote.session(session)?.queue ?? []
  }

  let remote: TerminalRemote
  let session: String
  let view = QueueView()

  /// One that just left the queue for the agent, shown as Sent for a moment.
  struct Sent: Identifiable {
    let id = UUID()
    let item: LiveQueued
  }

  @Published private(set) var sent: [Sent] = []
  @Published private(set) var pausing = false
  @Published private(set) var adding = false
  @Published var addText = ""

  /// The one being edited in place, and its text.
  @Published var editing: String?
  @Published var editText = ""

  /// Text saved here, by id, until the computer's queue has it.
  @Published private(set) var edited: [String: String] = [:]

  /// Long ones shown whole.
  @Published var open: Set<String> = []

  /// Deleted from here: they leave, but weren't sent.
  private var deleted: Set<String> = []

  /// Sent now from here.
  private var sentNow: Set<String> = []

  private var last: [LiveQueued]
  private var stopListening: (@MainActor () -> Void)?
  private var timers: [Task<Void, Never>] = []

  /// How long one that went shows as Sent.
  static let sentFor: TimeInterval = 1.5

  var summary: LiveSummary? { remote.session(session) }

  func start() {
    if stopListening == nil { stopListening = remote.addListener { [weak self] in self?.changed() } }
  }

  func stop() {
    stopListening?()
    stopListening = nil
    for t in timers { t.cancel() }
    timers = []
  }

  /// The computer's queue changed: the next one leaving it from the front went to the agent (so did one sent now
  /// from here); one deleted here just goes.
  private func changed() {
    let queue = summary?.queue ?? []
    let ids = Set(queue.map(\.id))
    for (i, q) in last.enumerated() where !ids.contains(q.id) && !deleted.contains(q.id) {
      if i == 0 || sentNow.contains(q.id) { showSent(q) }
    }
    deleted = deleted.filter(ids.contains)
    sentNow = sentNow.filter(ids.contains)
    var byId: [String: LiveQueued] = [:]
    for q in queue { byId[q.id] = q }
    let stillEdited = edited.filter { id, text in byId[id].map { $0.text != text } ?? false }
    if stillEdited.count != edited.count { edited = stillEdited }
    if let e = editing, !ids.contains(e) { editing = nil }
    last = queue
  }

  private func showSent(_ q: LiveQueued) {
    let s = Sent(item: q)
    sent.append(s)
    timers.append(
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(Self.sentFor))
        if Task.isCancelled { return }
        withAnimation(.easeOut(duration: 0.3)) { self?.sent.removeAll { $0.id == s.id } }
      })
  }

  private func say(_ text: String, action: String? = nil, handler: (() -> Void)? = nil) {
    Toaster.shared.show(text, action: action, handler: handler)
  }

  /// Takes [id] out of the list at once, back if [request] fails; whether it went.
  @discardableResult
  private func drop(_ id: String, _ request: () async throws -> Void) async -> Bool {
    view.gone.insert(id)
    objectWillChange.send()
    do {
      try await request()
      return true
    } catch {
      view.gone.remove(id)
      objectWillChange.send()
      say(errorText(error))
      return false
    }
  }

  private func move(_ id: String, _ to: Int) async {
    do {
      try await remote.moveQueued(session, id, to)
    } catch {
      view.forgetOrder()
      objectWillChange.send()
      say(errorText(error))
    }
  }

  /// The one shown at [from] dragged to [to] (its place once moved).
  func dragged(_ all: [LiveQueued], _ shown: [LiveQueued], _ from: Int, _ to: Int) {
    guard from != to else { return }
    Haptics.picked()
    let id = shown[from].id
    let at = view.drop(all, shown, from, to)
    objectWillChange.send()
    Task { await move(id, at) }
  }

  func canRequeue(_ q: LiveQueued) -> Bool { requeueable(q, in: summary) }

  /// Queues [text] again, at place [at]: a copy, or one deleted coming back.
  func requeue(_ text: String, at: Int) async {
    guard let s = summary, s.busy || s.ask != nil else {
      return say("The run has ended, so it can't wait in the queue. Send it from the chat.")
    }
    do {
      guard let id = try await remote.prompt(session, text, followUp: true) else {
        return say("The run had ended: it went to the agent.")
      }
      try await remote.moveQueued(session, id, at)
    } catch {
      say(errorText(error))
    }
  }

  /// Deletes [q] (asked first, when it couldn't come back); Undo queues it again in its place.
  func delete(_ q: LiveQueued, at: Int) async {
    let undo = canRequeue(q)
    deleted.insert(q.id)
    guard await drop(q.id, { try await remote.removeQueued(session, q.id) }) else {
      deleted.remove(q.id)
      return
    }
    if undo {
      let text = q.text
      say("Deleted", action: "Undo") { [weak self] in Task { await self?.requeue(text, at: at) } }
    }
  }

  func clear(_ shown: [LiveQueued]) async {
    deleted.formUnion(shown.map(\.id))
    // All at once, each back with why if the computer refuses it.
    let remote = remote
    let session = session
    let tasks = shown.map { q in Task { await drop(q.id) { try await remote.removeQueued(session, q.id) } } }
    for t in tasks { _ = await t.value }
  }

  func pause(_ paused: Bool) async {
    pausing = true
    do { try await remote.pauseQueue(session, paused: paused) } catch { say(errorText(error)) }
    pausing = false
  }

  func startEdit(_ q: LiveQueued) {
    editText = edited[q.id] ?? q.text
    editing = q.id
  }

  func save(_ q: LiveQueued) async {
    let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
    editing = nil
    if text == (edited[q.id] ?? q.text) { return }
    edited[q.id] = text
    do {
      try await remote.editQueued(session, q.id, text)
    } catch {
      edited[q.id] = nil
      say(errorText(error))
    }
  }

  func sendNow(_ q: LiveQueued) {
    sentNow.insert(q.id)
    Task { await drop(q.id) { try await remote.sendQueuedNow(session, q.id) } }
  }

  func toTop(_ all: [LiveQueued], _ q: LiveQueued) {
    view.put(all, q.id, 0)
    objectWillChange.send()
    Task { await move(q.id, 0) }
  }

  func toBottom(_ all: [LiveQueued], _ q: LiveQueued) {
    view.put(all, q.id, all.count - 1)
    objectWillChange.send()
    Task { await move(q.id, all.count - 1) }
  }

  func add() async {
    let text = addText.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return }
    if text.hasPrefix("/") { return say("Commands can\u{2019}t wait in the queue. Send them from the chat.") }
    adding = true
    do {
      let id = try await remote.prompt(session, text, followUp: true)
      addText = ""
      if id == nil { say("The run had ended: it went to the agent.") }
    } catch {
      say(errorText(error))
    }
    adding = false
  }
}

/// Every prompt waiting in [session]'s queue on the computer, whole: each can be edited in place, moved (dragged,
/// or to the top or bottom), sent now (an agent that steers), copied or deleted; the queue paused or cleared, and
/// a prompt added at its end. Follows the computer: one that goes to the agent shows as Sent for a moment.
/// Offline, it only shows. Presented over the whole screen.
struct QueueScreen: View {
  @FocusState private var addFocused: Bool
  init(remote: TerminalRemote, session: String) {
    self.remote = remote
    _model = StateObject(wrappedValue: QueueScreenModel(remote: remote, session: session))
  }

  @ObservedObject var remote: TerminalRemote
  @StateObject private var model: QueueScreenModel
  @Environment(\.dismiss) private var dismiss
  @State private var clearing: [LiveQueued]?
  @State private var askDelete: (q: LiveQueued, at: Int)?

  /// Lines a long prompt shows until it's opened.
  static let lines = 6

  var body: some View {
    let s = model.summary
    NavigationStack {
      content(s)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .principal) {
            Text(s.map(sessionTitle) ?? "Queue")
              .font(.headline)
              .lineLimit(1)
              .accessibilityIdentifier("queue-title")
          }
          ToolbarItem(placement: .cancellationAction) {
            Button {
              dismiss()
            } label: {
              Image(systemName: "xmark")
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("queue-close")
          }
        }
        .safeAreaInset(edge: .bottom) { addBar(s, online: remote.online && s != nil) }
    }
    .onAppear { model.start() }
    .onDisappear { model.stop() }
    .confirmationDialog(
      "Clear the queue?", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }),
      titleVisibility: .visible, presenting: clearing
    ) { shown in
      Button("Clear all", role: .destructive) { Task { await model.clear(shown) } }
      Button("Cancel", role: .cancel) {}
    } message: { shown in
      Text(shown.count == 1 ? "The prompt never goes to the agent." : "All \(shown.count) prompts are deleted; none of them go.")
    }
    .confirmationDialog(
      "Delete this prompt?", isPresented: Binding(get: { askDelete != nil }, set: { if !$0 { askDelete = nil } }),
      titleVisibility: .visible, presenting: askDelete
    ) { d in
      Button("Delete", role: .destructive) { Task { await model.delete(d.q, at: d.at) } }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("It never goes to the agent, and it can\u{2019}t be undone.")
    }
  }

  /// Deletes [q], asking first when it can't come back: its images and files went to the computer once.
  private func delete(_ q: LiveQueued, at: Int) {
    // A menu hands focus back to the field it took it from: the keyboard would come up over the Undo toast.
    addFocused = false
    if model.canRequeue(q) {
      Task { await model.delete(q, at: at) }
    } else {
      askDelete = (q, at)
    }
  }

  @ViewBuilder private func content(_ s: LiveSummary?) -> some View {
    let online = remote.online && s != nil
    let (all, shown) = model.view.items(s?.queue ?? [])
    let paused = s?.paused ?? false
    let steers = s?.agent.steers ?? false
    let (state, stateColor): (String, Color) =
      if s == nil { ("Ended", .secondary) } else if paused { ("Paused", .orange) } else if s!.busy {
        ("Working", .accentColor)
      } else if s!.ask != nil { ("Waiting for you", .orange) } else { ("Idle", .secondary) }
    let note: String? =
      if s == nil { "The session has ended." } else if !remote.online { "Offline: you can look, but not change it." }
      else if paused && !s!.busy { "Nothing goes until you resume." } else { nil }
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text("Queued · \(shown.count)")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("queue-count")
        HStack(spacing: 6) {
          Circle().fill(stateColor).frame(width: 7, height: 7)
          Text(state)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(stateColor)
            .accessibilityIdentifier("queue-state")
        }
        Spacer()
        if !shown.isEmpty {
          Button(role: .destructive) {
            clearing = shown
          } label: {
            Image(systemName: "trash")
          }
          .disabled(!online)
          .accessibilityLabel("Clear all")
          .accessibilityIdentifier("queue-clear")
        }
        if !shown.isEmpty || paused {
          Button(paused ? "Resume" : "Pause") { Task { await model.pause(!paused) } }
            .disabled(!online || model.pausing)
            .accessibilityIdentifier(paused ? "queue-screen-resume" : "queue-screen-pause")
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 8)
      if let note {
        HStack(spacing: 6) {
          if !remote.online { Image(systemName: "icloud.slash") }
          Text(note)
          Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
      }
      Divider()
      if shown.isEmpty && model.sent.isEmpty {
        ContentUnavailableView {
          Label("Nothing queued", systemImage: "tray")
        } description: {
          Text("Prompts you queue while the agent works wait here.")
        }
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier("queue-empty")
      } else {
        ScrollViewReader { proxy in
          List {
            ForEach(model.sent) { sent in
              HStack(spacing: 8) {
                Image(systemName: "checkmark").foregroundStyle(.green)
                Text("Sent").font(.caption.weight(.semibold)).foregroundStyle(.green)
                Text(sent.item.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
              }
              .transition(.opacity)
              .accessibilityElement(children: .contain)
              .accessibilityIdentifier("queue-sent-\(sent.item.id)")
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, q in
              row(q, i, all, online: online, steers: steers)
            }
            .onMove(
              perform: online && model.editing == nil
                ? { from, to in
                  guard let f = from.first else { return }
                  model.dragged(all, shown, f, movedPlace(from: f, destination: to))
                } : nil)
          }
          .listStyle(.plain)
          .scrollDismissesKeyboard(.immediately)
          .accessibilityIdentifier("queue-list")
          .animation(.snappy, value: shown.map(\.id))
          // The keyboard came up or grew: the one being edited stays in view, Save and Cancel too, not just the
          // line typed in.
          .onChange(of: model.editing) { reveal(proxy) }
          .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { _ in
            reveal(proxy)
          }
        }
      }
    }
  }

  private func reveal(_ proxy: ScrollViewProxy) {
    guard let id = model.editing else { return }
    withAnimation(.snappy) { proxy.scrollTo(id, anchor: .bottom) }
  }

  private func row(_ q: LiveQueued, _ index: Int, _ all: [LiveQueued], online: Bool, steers: Bool) -> some View {
    let editing = model.editing == q.id
    let extras = attachedExtras(images: q.images, files: q.files)
    let at = all.firstIndex { $0.id == q.id } ?? index
    return HStack(alignment: .top, spacing: 8) {
      Text("\(index + 1)")
        .font(.footnote.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 24, alignment: .leading)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 4) {
        if editing {
          QueueEditor(model: model, item: q)
        } else {
          QueueText(
            id: q.id, text: model.edited[q.id] ?? q.text, open: model.open.contains(q.id),
            toggle: {
              if model.open.contains(q.id) { model.open.remove(q.id) } else { model.open.insert(q.id) }
            })
        }
        if !extras.isEmpty { Text(extras.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
        if q.cut { Text("Too long to show whole here.").font(.caption).foregroundStyle(.tertiary) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if !editing {
        Menu {
          if !q.cut { Button("Edit", systemImage: "pencil") { model.startEdit(q) } }
          if steers { Button("Send now", systemImage: "paperplane") { model.sendNow(q) } }
          if at > 0 { Button("Move to top", systemImage: "arrow.up.to.line") { model.toTop(all, q) } }
          if at < all.count - 1 {
            Button("Move to bottom", systemImage: "arrow.down.to.line") { model.toBottom(all, q) }
          }
          if model.canRequeue(q) {
            Button("Duplicate", systemImage: "plus.square.on.square") {
              Task { await model.requeue(q.text, at: at + 1) }
            }
          }
          Button("Delete", systemImage: "trash", role: .destructive) { delete(q, at: at) }
        } label: {
          Image(systemName: "ellipsis.circle")
            .font(.body)
            .foregroundStyle(online ? .secondary : .tertiary)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
        }
        .disabled(!online)
        .accessibilityLabel("More")
        .accessibilityIdentifier("queue-menu-\(q.id)")
      }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .onTapGesture { if online && !editing && !q.cut { model.startEdit(q) } }
    .listRowBackground(editing ? Color(.secondarySystemBackground) : nil)
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      if online && !editing {
        Button(role: .destructive) { delete(q, at: at) } label: { Label("Delete", systemImage: "trash") }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("queue-item-\(q.id)")
  }

  /// A prompt to add at the end of the queue: only while the agent works, else it would go at once.
  private func addBar(_ s: LiveSummary?, online: Bool) -> some View {
    let open = online && s != nil && (s!.busy || s!.ask != nil)
    let ready = open && !model.adding && !model.addText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return HStack(alignment: .bottom, spacing: 6) {
      TextField(open ? "Add to the queue" : "Adds while the agent works", text: $model.addText, axis: .vertical)
        .lineLimit(1...5)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .disabled(!open || model.adding)
        .focused($addFocused)
        .accessibilityIdentifier("queue-add-field")
      Button {
        Task { await model.add() }
      } label: {
        Group {
          if model.adding { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title) }
        }
        .frame(width: 40, height: 40)
      }
      .disabled(!ready)
      .accessibilityLabel("Add")
      .accessibilityIdentifier("queue-add")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.bar)
  }
}

/// A queued prompt's text, folded to [QueueScreen.lines] lines with Show more when it's longer.
private struct QueueText: View {
  let id: String
  let text: String
  let open: Bool
  let toggle: () -> Void
  @State private var full: CGFloat = 0
  @State private var folded: CGFloat = 0

  var body: some View {
    if text.isEmpty {
      Text("(no text)").font(.body).italic().foregroundStyle(.secondary)
    } else {
      let long = full > folded + 1
      VStack(alignment: .leading, spacing: 4) {
        Text(text)
          .font(.body)
          .lineLimit(open ? nil : QueueScreen.lines)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background {
            // The text whole and folded, unseen, to tell whether it's long.
            ZStack {
              Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { full = $0 }
              Text(text).font(.body).lineLimit(QueueScreen.lines).fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { folded = $0 }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
          }
          .accessibilityIdentifier("queue-text-\(id)")
        if long {
          Button(open ? "Show less" : "Show more") { withAnimation(.snappy) { toggle() } }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderless)
            .accessibilityIdentifier("queue-more-\(id)")
        }
      }
    }
  }
}

/// A queued prompt opened into a field in place: Save or Cancel closes it again.
private struct QueueEditor: View {
  @ObservedObject var model: QueueScreenModel
  let item: LiveQueued
  @FocusState private var focused: Bool

  var body: some View {
    let canSave =
      !model.editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.images > 0 || !item.files.isEmpty
    VStack(alignment: .leading, spacing: 8) {
      TextField("Prompt", text: $model.editText, axis: .vertical)
        .lineLimit(2...12)
        .focused($focused)
        .padding(8)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("queue-edit-field")
      HStack {
        Spacer()
        Button("Cancel") { model.editing = nil }
          .buttonStyle(.borderless)
          .accessibilityIdentifier("queue-edit-cancel")
        Button("Save") { Task { await model.save(item) } }
          .buttonStyle(.borderedProminent)
          .disabled(!canSave)
          .accessibilityIdentifier("queue-edit-save")
      }
    }
    .onAppear { focused = true }
  }
}
