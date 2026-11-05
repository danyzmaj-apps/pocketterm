import PocketTermKit
import SwiftUI

/// A queued prompt being edited, for `.sheet(item:)`.
struct QueuedEdit: Identifiable {
  let item: LiveQueued
  var id: String { item.id }
}

/// The prompts waiting on the computer for the run to end, next first: each can be edited, moved (held and
/// dragged), sent now (an agent that steers) or deleted (swiped), and the whole queue paused. A move or a delete
/// shows at once, until the computer's queue says the same.
struct QueueStrip: View {
  let remote: TerminalRemote
  let session: String
  let summary: LiveSummary?
  let online: Bool

  /// Its agent takes a prompt mid-run: one can be sent now.
  let steers: Bool
  let openQueue: () -> Void

  @State private var folded = false
  @State private var pausing = false
  @State private var view = QueueView()
  @State private var editing: QueuedEdit?

  /// Bumped after [view] changes here, so the strip draws it.
  @State private var changes = 0

  /// About one row's height: the list shows three and a half, and scrolls for more.
  private static let row: CGFloat = 56

  private func toast(_ e: Error) { Toaster.shared.show(errorText(e)) }

  /// Moves the one shown at [from] to [to] (its place once moved).
  private func move(_ all: [LiveQueued], _ shown: [LiveQueued], _ from: Int, _ to: Int) {
    guard to != from else { return }
    Haptics.picked()
    let id = shown[from].id
    let at = view.drop(all, shown, from, to)
    changes += 1
    Task {
      do {
        try await remote.moveQueued(session, id, at)
      } catch {
        view.forgetOrder()
        changes += 1
        toast(error)
      }
    }
  }

  /// Takes [id] out of the list at once, back if [request] fails.
  private func drop(_ id: String, _ request: @escaping () async throws -> Void) {
    view.gone.insert(id)
    changes += 1
    Task {
      do {
        try await request()
      } catch {
        view.gone.remove(id)
        changes += 1
        toast(error)
      }
    }
  }

  private func pause(_ paused: Bool) async {
    pausing = true
    do { try await remote.pauseQueue(session, paused: paused) } catch { toast(error) }
    pausing = false
  }

  var body: some View {
    let _ = changes
    let (all, shown) = view.items(summary?.queue ?? [])
    let paused = summary?.paused ?? false
    if !shown.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 4) {
          Button {
            withAnimation(.snappy) { folded.toggle() }
          } label: {
            Image(systemName: "chevron.right")
              .rotationEffect(.degrees(folded ? 0 : 90))
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.secondary)
              .frame(width: 28, height: 32)
          }
          .accessibilityLabel(folded ? "Show the queue" : "Fold the queue")
          .accessibilityIdentifier("queue-fold")
          Button(action: openQueue) {
            HStack(spacing: 6) {
              Text("\(paused ? "Queue paused" : "Queued") · \(shown.count)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(paused ? Color.orange : Color.secondary)
                .lineLimit(1)
              Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityHint("Opens the whole queue")
          .accessibilityIdentifier("queue-open-header")
          Button(paused ? "Resume" : "Pause") { Task { await pause(!paused) } }
            .font(.footnote.weight(.semibold))
            .disabled(!online || pausing)
            .accessibilityIdentifier(paused ? "queue-resume" : "queue-pause")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue-strip")
        if paused && !(summary?.busy ?? false) {
          Text("Nothing goes until you resume.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 32)
            .padding(.bottom, 4)
        }
        if !folded {
          List {
            ForEach(shown, id: \.id) { q in
              row(q)
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                  if online {
                    Button(role: .destructive) {
                      drop(q.id) { try await remote.removeQueued(session, q.id) }
                    } label: {
                      Label("Delete", systemImage: "trash")
                    }
                  }
                }
            }
            .onMove(
              perform: online
                ? { from, to in
                  guard let f = from.first else { return }
                  move(all, shown, f, movedPlace(from: f, destination: to))
                } : nil)
          }
          .listStyle(.plain)
          .scrollContentBackground(.hidden)
          .environment(\.defaultMinListRowHeight, Self.row - 8)
          .frame(height: min(CGFloat(shown.count), 3.5) * Self.row)
          .transition(.opacity)
        }
      }
      .sheet(item: $editing) { e in
        EditQueuedSheet(item: e.item) { text in
          Task {
            do { try await remote.editQueued(session, e.item.id, text) } catch { toast(error) }
          }
        }
        .toasts()
      }
    }
  }

  private func row(_ q: LiveQueued) -> some View {
    let extras = attachedExtras(images: q.images, files: q.files)
    return HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        if q.text.isEmpty {
          Text("(no text)").font(.subheadline).italic().foregroundStyle(.secondary)
        } else {
          Text(q.text).font(.subheadline).lineLimit(2)
        }
        if !extras.isEmpty {
          Text(extras.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Menu {
        if !q.cut { Button("Edit", systemImage: "pencil") { editing = QueuedEdit(item: q) } }
        if steers {
          Button("Send now", systemImage: "paperplane") {
            drop(q.id) { try await remote.sendQueuedNow(session, q.id) }
          }
        }
        Button("Delete", systemImage: "trash", role: .destructive) {
          drop(q.id) { try await remote.removeQueued(session, q.id) }
        }
      } label: {
        Image(systemName: "ellipsis")
          .foregroundStyle(online ? .secondary : .tertiary)
          .frame(width: 36, height: 36)
          .contentShape(Rectangle())
      }
      .disabled(!online)
      .accessibilityLabel("More")
      .accessibilityIdentifier("queued-menu-\(q.id)")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("queued-\(q.id)")
  }
}

/// A queued prompt's text to change. Empty only when images or files go with it.
struct EditQueuedSheet: View {
  let item: LiveQueued
  let onSave: (String) -> Void
  @State private var text: String
  @FocusState private var focused: Bool
  @Environment(\.dismiss) private var dismiss

  init(item: LiveQueued, onSave: @escaping (String) -> Void) {
    self.item = item
    self.onSave = onSave
    _text = State(initialValue: item.text)
  }

  var body: some View {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let canSave = !trimmed.isEmpty || item.images > 0 || !item.files.isEmpty
    NavigationStack {
      Form {
        TextField("Prompt", text: $text, axis: .vertical)
          .lineLimit(3...10)
          .focused($focused)
          .accessibilityIdentifier("queued-edit-field")
      }
      .navigationTitle("Edit queued prompt")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.accessibilityIdentifier("queued-edit-cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            onSave(trimmed)
            dismiss()
          }
          .disabled(!canSave)
          .accessibilityIdentifier("queued-edit-save")
        }
      }
      .onAppear { focused = true }
    }
    .presentationDetents([.medium, .large])
  }
}
