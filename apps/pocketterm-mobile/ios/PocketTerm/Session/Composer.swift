import PhotosUI
import PocketTermKit
import SwiftUI
import UniformTypeIdentifiers

/// The bottom of the conversation: slash command suggestions, Continue, the queue, the busy bar (Queue, Stop),
/// what's attached, and the field with the attach menu, the microphone and Send.
struct Composer: View {
  @ObservedObject var model: SessionModel
  @ObservedObject var attachments: ChatAttachments
  let summary: LiveSummary?
  let online: Bool
  let openQueue: () -> Void

  @FocusState private var focused: Bool
  @State private var pickingPhotos = false
  @State private var photoItems: [PhotosPickerItem] = []
  @State private var importing = false

  var body: some View {
    let s = summary
    let busy = s?.busy ?? false
    let agent = model.agent(s)
    let text = model.text
    let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    // One at a time, in order: the next waits until the computer has the one sending. While images load, the
    // button stays a disabled Send.
    let loading = attachments.loading
    let canSend = online && !model.sending && !model.delivering && !loading && (!empty || !attachments.isEmpty)
    // Nothing to send: the button there is the microphone.
    let talk = !model.sending && !loading && empty && attachments.isEmpty
    let canAttach = online && attachments.room > 0 && !loading
    let slash = text.hasPrefix("/")
    let commanding = online && s != nil && slash
    let noWindow = commanding && !model.can(model.windowKey(s), .line)
    let matches = commanding && !noWindow ? matchCommands(s!.commands, text) : []

    VStack(alignment: .leading, spacing: 6) {
      if noWindow {
        Text(noCommandsText(agent))
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
          .accessibilityIdentifier("commands-need-window")
      } else if !matches.isEmpty {
        commands(matches)
      }
      if model.offerContinue && online && s != nil && !busy {
        Button {
          Task { await model.sendContinue() }
        } label: {
          Label("Continue", systemImage: "play.fill")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .accessibilityHint("Carry on with what it was doing")
        .accessibilityIdentifier("continue")
        .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
      QueueStrip(
        remote: model.remote, session: model.key, summary: s, online: online, steers: agent.steers,
        openQueue: openQueue)
      if busy && online {
        HStack {
          // An agent that can't steer queues every prompt while busy.
          if agent.steers {
            Toggle(isOn: $model.followUp) {
              Label("Queue", systemImage: "text.append")
            }
            .toggleStyle(.button)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .accessibilityHint("Off: the prompt steers \(agent.label) now")
            .accessibilityIdentifier("follow-up")
            .appTip(.queue)
          }
          Spacer()
          Button(role: .destructive) {
            Task { await model.stop() }
          } label: {
            Label("Stop", systemImage: "stop.circle")
          }
          .controlSize(.small)
          .disabled(model.stopping)
          .accessibilityIdentifier("stop")
        }
        .transition(.opacity)
      }
      AttachmentStrip(attachments: attachments)
      HStack(alignment: .bottom, spacing: 6) {
        attachMenu(enabled: canAttach)
        field(agent: agent, busy: busy, slash: slash, matches: matches)
        // A command's name isn't spoken; otherwise a smaller microphone beside Send adds to what's typed.
        if !talk && !model.sending && online && !slash {
          VoiceMic(enabled: online, existing: { model.text }, small: true, onResult: model.voiced)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
        if talk {
          VoiceMic(enabled: online, existing: { model.text }, onResult: model.voiced)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
        } else {
          Button {
            Task { await model.send(busy: busy) }
          } label: {
            Group {
              if model.sending {
                ProgressView()
              } else {
                Image(systemName: "arrow.up.circle.fill").font(.title)
              }
            }
            .frame(width: 40, height: 40)
          }
          .disabled(!canSend)
          .accessibilityLabel("Send")
          .accessibilityIdentifier("session-send")
          .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
      }
      .animation(.snappy(duration: 0.25), value: talk)
      .animation(.snappy(duration: 0.25), value: slash)
    }
    .animation(.snappy(duration: 0.25), value: busy)
    .animation(.snappy(duration: 0.25), value: model.offerContinue)
    .padding(.horizontal, 10)
    .padding(.top, 6)
    .padding(.bottom, 8)
    .onChange(of: model.focusRequest) { focused = true }
    // The agent asks: the card above takes the answer. With the keyboard still up it got squeezed to a strip, its
    // buttons scrolled out of sight under the composer.
    .onChange(of: summary?.ask?.id) { _, ask in if ask != nil { focused = false } }
  }

  /// Slash commands go to the agent's terminal window: the matches while the name is typed.
  private func commands(_ matches: [LiveCommand]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(matches, id: \.name) { c in
        Button {
          model.complete(c)
        } label: {
          (Text("/\(c.name)").fontWeight(.semibold).foregroundStyle(.primary)
            + Text(c.description.isEmpty ? "" : "  \(c.description)").foregroundStyle(.secondary))
            .font(.subheadline)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("command-\(c.name)")
      }
    }
  }

  private func attachMenu(enabled: Bool) -> some View {
    Menu {
      Button("Paste image", systemImage: "doc.on.clipboard") { Task { await model.pasteImage() } }
      Button("Choose from Photos", systemImage: "photo.on.rectangle") { pickingPhotos = true }
      Button("Choose from Files", systemImage: "folder") { importing = true }
    } label: {
      Image(systemName: "paperclip")
        .font(.title3)
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
    .disabled(!enabled)
    .accessibilityLabel("Attach images or files")
    .accessibilityIdentifier("session-attach")
    .photosPicker(
      isPresented: $pickingPhotos, selection: $photoItems, maxSelectionCount: max(attachments.room, 1),
      matching: .images, preferredItemEncoding: .compatible
    )
    .onChange(of: photoItems) { _, picked in
      guard !picked.isEmpty else { return }
      photoItems = []
      Task { await model.addPhotos(picked) }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
      switch result {
      case .success(let urls): Task { await model.addFiles(urls) }
      case .failure(let e): Toaster.shared.show(errorText(e))
      }
    }
  }

  private func field(agent: Agent, busy: Bool, slash: Bool, matches: [LiveCommand]) -> some View {
    let hint =
      busy ? (model.followUp || !agent.steers ? "Queue a prompt…" : "Steer \(agent.label)…") : "Prompt \(agent.label)…"
    return TextField(hint, text: $model.text, axis: .vertical)
      .lineLimit(1...6)
      .font(.body)
      .focused($focused)
      .disabled(!online)
      // A command's name isn't a word to correct or capitalize.
      .autocorrectionDisabled(slash)
      .textInputAutocapitalization(slash ? .never : .sentences)
      // A hardware keyboard's Tab takes the first suggestion.
      .onKeyPress(.tab) {
        guard let first = matches.first else { return .ignored }
        model.complete(first)
        return .handled
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
      .accessibilityIdentifier("session-input")
      .appTip(.slash)
  }
}

/// The composer's pending images and files, each with a ✕: a thumbnail per image, a chip with its name and size
/// per file, a spinner tile per one still loading, and what went wrong; nothing when empty.
struct AttachmentStrip: View {
  @ObservedObject var attachments: ChatAttachments
  var size: CGFloat = 56

  var body: some View {
    let items = attachments.items
    let loading = attachments.pending + (attachments.picking ? 1 : 0)
    if !items.isEmpty || loading > 0 || attachments.problem != nil {
      VStack(alignment: .leading, spacing: 6) {
        if !items.isEmpty || loading > 0 {
          ScrollView(.horizontal) {
            HStack(spacing: 8) {
              ForEach(Array(items.enumerated()), id: \.element.id) { i, a in
                removable(a, at: i)
              }
              ForEach(0..<loading, id: \.self) { i in
                ProgressView()
                  .frame(width: size, height: size)
                  .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                  .padding(.top, 6)
                  .accessibilityLabel("Loading image")
                  .accessibilityIdentifier("attachment-loading-\(i)")
              }
            }
            .padding(.horizontal, 4)
          }
          .scrollIndicators(.hidden)
          .accessibilityIdentifier("attachment-strip")
        }
        if let problem = attachments.problem {
          Text(problem).font(.caption).foregroundStyle(.red).padding(.horizontal, 4)
        }
      }
      .transition(.opacity)
    }
  }

  private func removable(_ a: ChatAttachment, at i: Int) -> some View {
    let label: String =
      switch a {
      case .image: "Remove image"
      case .file(let f): "Remove \(f.name)"
      }
    return Group {
      switch a {
      case .image(let image): ChatThumb(image: image, size: size)
      case .file(let f): ChatFileChip(file: f, height: size)
      }
    }
    .padding(.top, 6)
    .padding(.trailing, 6)
    .overlay(alignment: .topTrailing) {
      Button {
        attachments.removeAt(i)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, .gray)
          .font(.body)
          .frame(width: 32, height: 32, alignment: .topTrailing)
          .contentShape(Rectangle())
      }
      .offset(x: 4, y: -4)
      .accessibilityLabel(label)
      // By position: the strip scrolls, and only the shown ones are in the tree a test reads.
      .accessibilityIdentifier("attachment-remove-\(i)")
    }
  }
}
