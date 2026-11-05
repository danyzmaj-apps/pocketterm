import PocketTermKit
import SwiftUI
import UIKit

// The transcript's items as the phone draws them: the person's prompts, the agent's answers (Markdown), its tool
// calls and its own notices.

/// One item of a transcript.
struct TranscriptItemView: View, Equatable {
  let item: LiveItem
  let open: Bool
  let toggle: () -> Void

  static func == (a: Self, b: Self) -> Bool { a.item == b.item && a.open == b.open }

  var body: some View {
    switch item.kind {
    case .user: UserBubble(text: item.text, images: item.images)
    case .assistant: AssistantText(text: item.text)
    case .tool: ToolCard(item: item, open: open, toggle: toggle)
    case .notice: NoticeLine(text: item.text, open: open, toggle: toggle)
    }
  }
}

/// The person's bubble on the right, at most about four fifths of the width.
private struct Bubble<Content: View>: View {
  var dimmed = false
  var failed = false
  @ViewBuilder let content: Content

  var body: some View {
    content
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay {
        if failed { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.red.opacity(0.6)) }
      }
      .opacity(dimmed ? 0.6 : 1)
      // At most about four fifths of the row: the rest stays clear on the left.
      .padding(.leading, 56)
      .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

/// The person's prompt in a transcript, with how many images came with it.
struct UserBubble: View {
  let text: String
  let images: Int

  var body: some View {
    Bubble {
      VStack(alignment: .trailing, spacing: 4) {
        if !text.isEmpty {
          Text(text).font(.body).textSelection(.enabled)
        }
        if images > 0 {
          Text(attachedExtras(images: images)[0]).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// A prompt sent from the page, shown as the person's own until its item comes back: dimmed, with a spinner,
/// while it goes. One that didn't go says why, and a tap sends it again.
struct OutgoingBubble: View {
  let o: Outgoing
  let retry: () -> Void

  var body: some View {
    let problem = o.sending ? nil : o.problem
    VStack(alignment: .trailing, spacing: 4) {
      Bubble(dimmed: o.sending || o.waiting, failed: problem != nil) {
        VStack(alignment: .trailing, spacing: 6) {
          if !o.attachments.isEmpty { AttachmentThumbs(items: o.attachments, size: 48) }
          if !o.text.isEmpty { Text(o.text).font(.body) }
        }
      }
      .animation(.easeOut(duration: 0.2), value: o.sending)
      if o.sending {
        HStack(spacing: 6) {
          ProgressView().controlSize(.mini)
          Text("Sending…")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("outgoing-sending")
      } else if o.waiting {
        Text("Queued: goes when the run ends")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("outgoing-queued")
      } else if let problem {
        VStack(alignment: .trailing, spacing: 2) {
          Text(problem).lineLimit(3).multilineTextAlignment(.trailing).foregroundStyle(.secondary)
          Text("Not sent. Tap to retry").foregroundStyle(.red)
        }
        .font(.caption)
        .accessibilityIdentifier("outgoing-failed")
      }
    }
    .padding(.trailing, 4)
    .frame(maxWidth: .infinity, alignment: .trailing)
    .contentShape(Rectangle())
    .onTapGesture { if problem != nil { retry() } }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(problem != nil ? .isButton : [])
    .accessibilityIdentifier("outgoing")
  }
}

/// An assistant's answer: Markdown, its line breaks kept as the agent's terminal shows them; links open outside
/// the app.
struct AssistantText: View, Equatable {
  let text: String

  var body: some View {
    let blocks = markdownBlocks(text)
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in MarkdownBlockView(block: b) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MarkdownBlockView: View {
  let block: MdBlock

  var body: some View {
    switch block {
    case .paragraph(let s):
      Text(inlineMarkdown(s)).font(.body).textSelection(.enabled)
    case .heading(let level, let s):
      Text(inlineMarkdown(s))
        .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        .textSelection(.enabled)
    case .code(let language, let s):
      CodeBlock(language: language, code: s)
    case .list(let items):
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.marker).foregroundStyle(.secondary).monospacedDigit()
            Text(inlineMarkdown(item.text)).textSelection(.enabled)
          }
          .padding(.leading, CGFloat(item.depth) * 16)
        }
      }
      .font(.body)
    case .quote(let s):
      Text(inlineMarkdown(s))
        .font(.body)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .padding(.leading, 10)
        .overlay(alignment: .leading) { Capsule().fill(Color(.separator)).frame(width: 3) }
    case .table(let header, let rows):
      TableBlock(header: header, rows: rows)
    case .rule:
      Divider()
    }
  }
}

/// A fenced code block in the terminal's colours and font: it scrolls sideways rather than wrap, and copies.
private struct CodeBlock: View {
  let language: String
  let code: String
  @EnvironmentObject private var look: Appearance

  var body: some View {
    let theme = look.theme
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(language).font(.caption2.monospaced()).foregroundStyle(theme.dim.color)
        Spacer()
        Button {
          UIPasteboard.general.string = code
          Haptics.picked()
          Toaster.shared.show("Copied")
        } label: {
          Image(systemName: "doc.on.doc").font(.caption)
        }
        .tint(theme.dim.color)
        .accessibilityLabel("Copy code")
        .accessibilityIdentifier("code-copy")
      }
      .padding(.horizontal, 10)
      .padding(.top, 6)
      ScrollView(.horizontal) {
        Text(code)
          .font(.mono(.footnote))
          .foregroundStyle(theme.text.color)
          .fixedSize(horizontal: true, vertical: false)
          .textSelection(.enabled)
          .padding(.horizontal, 10)
          .padding(.bottom, 10)
          .padding(.top, 4)
      }
      .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
    .background(theme.win.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color.opacity(0.6)))
  }
}

/// A Markdown table, its cells inline Markdown; wide ones scroll sideways.
private struct TableBlock: View {
  let header: [String]
  let rows: [[String]]

  var body: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
        GridRow {
          ForEach(Array(header.enumerated()), id: \.offset) { _, c in Text(inlineMarkdown(c)).bold() }
        }
        Divider()
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { _, c in Text(inlineMarkdown(c)) }
          }
        }
      }
      .font(.subheadline)
      .textSelection(.enabled)
      .padding(10)
    }
    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

/// The agent's own lines in the transcript ("Interrupted", a finished background job). A short one sits
/// centered; a long one is left-aligned and folded to three lines until tapped.
struct NoticeLine: View {
  let text: String
  let open: Bool
  let toggle: () -> Void

  var body: some View {
    if text.count <= 80 && !text.contains("\n") {
      Text(text)
        .font(.caption)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    } else {
      Text(text)
        .font(.caption)
        .foregroundStyle(.tertiary)
        .lineLimit(open ? nil : 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 10)
        .overlay(alignment: .leading) { Capsule().fill(Color(.separator)).frame(width: 2) }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { toggle() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(open ? "Folds it" : "Shows it whole")
    }
  }
}

/// A tool the agent ran: its name and what it did, how it went, and its output once opened.
struct ToolCard: View {
  let item: LiveItem
  let open: Bool
  let toggle: () -> Void

  var body: some View {
    let i = item
    let what = i.title.isEmpty ? i.args : i.title
    DisclosureGroup(
      isExpanded: Binding(get: { open }, set: { if $0 != open { toggle() } })
    ) {
      VStack(alignment: .leading, spacing: 8) {
        Divider()
        if !i.title.isEmpty && !i.args.isEmpty {
          Text(i.args).font(.mono(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
        }
        ScrollView(.horizontal) {
          Text(i.output.isEmpty ? (i.status == .running ? "…" : "No output.") : i.output)
            .font(.mono(.caption))
            .fixedSize(horizontal: true, vertical: false)
            .textSelection(.enabled)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
      }
      .padding(.top, 6)
    } label: {
      HStack(spacing: 8) {
        ToolStatusMark(status: i.status)
        Text(i.tool).font(.mono(.caption).weight(.semibold)).foregroundStyle(.primary)
        Text(what).font(.mono(.caption)).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .tint(.secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(i.status == .error ? Color.red.opacity(0.5) : Color(.separator).opacity(0.5))
    }
    .animation(.snappy, value: open)
  }
}

/// A spinner while the tool runs, becoming a green check or a red cross as it finishes.
private struct ToolStatusMark: View {
  let status: ToolStatus

  var body: some View {
    Group {
      switch status {
      case .running:
        ProgressView().controlSize(.mini)
          .accessibilityLabel("Running")
      case .ok:
        Image(systemName: "checkmark").foregroundStyle(.green)
          .accessibilityLabel("Done")
      case .error:
        Image(systemName: "xmark").foregroundStyle(.red)
          .accessibilityLabel("Failed")
      }
    }
    .font(.caption.weight(.bold))
    .frame(width: 16)
    .transition(.scale.combined(with: .opacity))
    .animation(.snappy, value: status)
  }
}

// MARK: - Attachments

/// Thumbnails decoded once, small, per image: the page draws often (every change on the computer).
private final class ThumbCache {
  static let shared = ThumbCache()
  private let cache = NSCache<NSData, UIImage>()

  func thumb(_ bytes: Data, side: CGFloat) async -> UIImage? {
    let key = bytes as NSData
    if let hit = cache.object(forKey: key) { return hit }
    let px = side * UIScreen.main.scale * 2
    let made = await Task.detached(priority: .userInitiated) { () -> UIImage? in
      UIImage(data: bytes)?.preparingThumbnail(of: CGSize(width: px, height: px))
    }.value
    if let made { cache.setObject(made, forKey: key) }
    return made
  }
}

/// An image attachment's square thumbnail.
struct ChatThumb: View {
  let image: ChatImage
  let size: CGFloat
  @State private var thumb: UIImage?

  var body: some View {
    ZStack {
      Color(.secondarySystemFill)
      if let thumb { Image(uiImage: thumb).resizable().scaledToFill() }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .task(id: ObjectIdentifier(image)) { thumb = await ThumbCache.shared.thumb(image.bytes, side: size) }
    .accessibilityLabel("Image")
  }
}

/// A file attachment: an icon, its name and its size.
struct ChatFileChip: View {
  let file: ChatFile
  let height: CGFloat

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "doc").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(file.name).font(.footnote).lineLimit(1).truncationMode(.middle)
        Text(formatBytes(file.bytes.count)).font(.caption2).foregroundStyle(.secondary)
      }
    }
    .padding(.leading, 10)
    .padding(.trailing, 14)
    .frame(maxWidth: 200, minHeight: height, maxHeight: height, alignment: .leading)
    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

/// Images and files as they went with a message.
struct AttachmentThumbs: View {
  let items: [ChatAttachment]
  var size: CGFloat = 56

  var body: some View {
    SessionFlowLayout(spacing: 6, alignment: .trailing) {
      ForEach(items) { a in
        switch a {
        case .image(let i): ChatThumb(image: i, size: size)
        case .file(let f): ChatFileChip(file: f, height: size)
        }
      }
    }
  }
}

/// Lays its views out in rows, wrapping onto the next as the width runs out.
struct SessionFlowLayout: Layout {
  var spacing: CGFloat = 6
  var alignment: HorizontalAlignment = .leading

  private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
    var rows: [[(index: Int, size: CGSize)]] = [[]]
    var x: CGFloat = 0
    for (i, v) in subviews.enumerated() {
      let s = v.sizeThatFits(ProposedViewSize(width: width, height: nil))
      if x > 0 && x + s.width > width {
        rows.append([])
        x = 0
      }
      rows[rows.count - 1].append((i, s))
      x += s.width + spacing
    }
    return rows
  }

  private func rowWidth(_ r: [(index: Int, size: CGSize)]) -> CGFloat {
    let widths: CGFloat = r.reduce(0) { $0 + $1.size.width }
    return widths + spacing * CGFloat(max(r.count - 1, 0))
  }

  private func rowHeight(_ r: [(index: Int, size: CGSize)]) -> CGFloat {
    r.map { $0.size.height }.max() ?? 0
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    let rs = rows(subviews, width: width)
    let heights: CGFloat = rs.reduce(0) { $0 + rowHeight($1) }
    let height = heights + spacing * CGFloat(max(rs.count - 1, 0))
    let widest: CGFloat = rs.map { rowWidth($0) }.max() ?? 0
    return CGSize(width: proposal.width ?? widest, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for r in rows(subviews, width: bounds.width) {
      let rowWidth = rowWidth(r)
      var x =
        alignment == .trailing ? bounds.maxX - rowWidth : alignment == .center ? bounds.midX - rowWidth / 2 : bounds.minX
      let h = rowHeight(r)
      for (i, s) in r {
        subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
        x += s.width + spacing
      }
      y += h + spacing
    }
  }
}
