import DayPageCore
import SwiftUI
import UIKit

struct NoteSharePreview: View {
  @EnvironmentObject private var notebook: NotebookModel
  @Environment(\.dismiss) private var dismiss
  let entry: NotebookEntry
  @State private var style: NoteShareStyle = .paper
  @State private var format: NoteShareFormat
  @State private var showsDate = true
  @State private var preparing = false
  @State private var sheet: PreparedNoteShare?
  @State private var error: String?
  @State private var imageExceedsBudget = false

  init(entry: NotebookEntry) {
    self.entry = entry
    _format = State(initialValue: NoteSharePolicy.imageAvailability(for: entry.memo.body) == .available
      ? .image : (entry.memo.attachments.isEmpty ? .text : .original))
  }

  private var date: String? {
    showsDate ? entry.memo.created.formatted(date: .abbreviated, time: .shortened) : nil
  }
  private var completeText: String {
    NoteSharePolicy.completeText(body: entry.memo.body, date: date)
  }
  private var imageAvailability: NoteSharePolicy.ImageAvailability {
    imageExceedsBudget ? .tooLong : NoteSharePolicy.imageAvailability(for: entry.memo.body)
  }
  private var canExport: Bool {
    switch format {
    case .image: return imageAvailability == .available
    case .text: return !entry.memo.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .original: return !entry.memo.body.isEmpty || !entry.memo.attachments.isEmpty
    }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          formatOptions
          if format == .image { styleOptions }
          Toggle("Show date", isOn: $showsDate)
            .font(.subheadline).accessibilityIdentifier("share-show-date")
          preview
          attachmentExplanation
          if let error {
            VStack(alignment: .leading, spacing: 8) {
              Text(error).font(.subheadline).foregroundStyle(.red)
                .accessibilityIdentifier("share-export-error")
              if canExport {
                Button("Try again", action: export).frame(minHeight: 44)
                  .accessibilityIdentifier("share-export-retry")
              }
            }
          }
        }
        .padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
      }
      .notebookSurface().tint(NotebookTheme.accent)
      .navigationTitle("Share note").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }.disabled(preparing)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(action: export) {
            if preparing { ProgressView() } else { Text("Share") }
          }
          .disabled(preparing || !canExport).accessibilityLabel("Share")
          .accessibilityIdentifier("share-export")
        }
      }
      .disabled(preparing)
      .accessibilityIdentifier("note-share-preview")
      .sheet(item: $sheet) { prepared in NoteShareSheet(items: prepared.items) }
      .onChange(of: format) { _ in error = nil }
      .onChange(of: style) { _ in error = nil; imageExceedsBudget = false }
      .onChange(of: showsDate) { _ in error = nil; imageExceedsBudget = false }
    }
    .interactiveDismissDisabled(preparing)
  }

  private var formatOptions: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Format").font(.caption).foregroundStyle(NotebookTheme.muted)
      HStack(spacing: 8) {
        ForEach(NoteShareFormat.allCases) { option in
          choice(option.title, selected: format == option) { format = option }
            .accessibilityIdentifier("share-format-" + option.rawValue)
        }
      }
    }
  }

  private var styleOptions: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Style").font(.caption).foregroundStyle(NotebookTheme.muted)
      HStack(spacing: 8) {
        ForEach(NoteShareStyle.allCases) { option in
          choice(option.title, selected: style == option) { style = option }
            .accessibilityIdentifier("share-style-" + option.rawValue)
        }
      }
    }
  }

  private func choice(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(.subheadline).multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 44).padding(.horizontal, 4)
        .foregroundStyle(selected ? NotebookTheme.readingAccent : NotebookTheme.ink)
        .background(selected ? NotebookTheme.accentSoft : NotebookTheme.card,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
          selected ? NotebookTheme.accent : NotebookTheme.line, lineWidth: 1))
    }
    .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
  }

  @ViewBuilder private var preview: some View {
    switch format {
    case .image:
      if imageAvailability == .available {
        NoteShareCanvas(bodyText: entry.memo.body, date: date, style: style)
          .dynamicTypeSize(.medium).frame(maxWidth: 360)
          .frame(maxWidth: .infinity).accessibilityIdentifier("share-card-preview")
      } else {
        VStack(alignment: .leading, spacing: 12) {
          Label("Image unavailable", systemImage: "doc.text")
            .font(.subheadline.weight(.medium))
          Text(imageAvailability == .emptyBody
               ? LocalizedStringKey("This note has no text for an image. Choose Original to share its attachments.")
               : LocalizedStringKey("This note is too long for one image. Choose Text or Original to share every word."))
            .font(.subheadline).lineSpacing(4)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(NotebookTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("share-image-unavailable")
      }
    case .text, .original:
      VStack(alignment: .leading, spacing: 16) {
        if let date, !entry.memo.body.isEmpty {
          Text(date).font(.caption).foregroundStyle(NotebookTheme.muted)
            .accessibilityIdentifier("share-preview-date")
        }
        if !entry.memo.body.isEmpty {
          Text(entry.memo.body).font(NotebookTheme.reading(17, text: entry.memo.body))
            .lineSpacing(6).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("share-complete-text")
        } else {
          Text("This note contains attachments only.")
            .font(.subheadline).foregroundStyle(NotebookTheme.muted)
        }
        if format == .original, !entry.memo.attachments.isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(entry.memo.attachments.enumerated()), id: \.offset) { _, attachment in
              Label(URL(fileURLWithPath: attachment.file).lastPathComponent, systemImage: "paperclip")
                .font(.caption).textSelection(.enabled)
            }
          }.accessibilityIdentifier("share-original-attachments")
        }
      }
      .padding(20).frame(maxWidth: .infinity, alignment: .leading)
      .background(NotebookTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }
  }

  private var attachmentExplanation: some View {
    VStack(alignment: .leading, spacing: 8) {
      if format == .original {
        if entry.memo.attachments.isEmpty {
          Text("No attachments. Shares the complete original text.")
        } else {
          Text("Shares the complete original text and every attachment listed above. Original files keep their existing contents and metadata.")
        }
      } else if format == .image {
        Text("Shares the styled text as one image. Attachments are not included.")
      } else {
        Text("Shares the complete text. Attachments are not included.")
      }
      Text("Location, device details and other note metadata are not added. Only the date you choose is included.")
    }
    .font(.caption).foregroundStyle(NotebookTheme.muted).lineSpacing(4)
    .accessibilityElement(children: .combine).accessibilityIdentifier("share-attachment-semantics")
  }

  @MainActor private func export() {
    guard !preparing, canExport else { return }
    preparing = true
    error = nil
    Task { @MainActor in
      defer { preparing = false }
      do {
        var items: [Any] = []
        switch format {
        case .image:
          let image = try renderImage()
          #if DEBUG
          if NotebookModel.isQA, ProcessInfo.processInfo.arguments.contains("-qaExportShareImage") {
            // Synthetic QA output, in the isolated Debug application's own sandbox.
            try image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("qa-shared-note.png"), options: .atomic)
          }
          #endif
          items = [image]
        case .text:
          items = [completeText]
        case .original:
          if !entry.memo.body.isEmpty { items.append(completeText) }
          for attachment in entry.memo.attachments {
            let url = try await notebook.store.assetURL(attachment.file, for: entry)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
            guard values.isRegularFile == true, values.isReadable == true else {
              throw CocoaError(.fileReadUnknown)
            }
            items.append(url)
          }
        }
        sheet = PreparedNoteShare(items: items)
      } catch NoteImageError.tooLarge {
        imageExceedsBudget = true
      } catch {
        self.error = NSLocalizedString("Couldn't prepare this share. Your note is unchanged. Try again or choose another format.", comment: "Share preparation failure")
      }
    }
  }

  @MainActor private func renderImage() throws -> UIImage {
    let renderer = ImageRenderer(content:
      NoteShareCanvas(bodyText: entry.memo.body, date: date, style: style)
        .dynamicTypeSize(.medium).frame(width: 360).fixedSize(horizontal: false, vertical: true))
    renderer.proposedSize = ProposedViewSize(width: 360, height: nil)
    let scale: CGFloat = 2
    var result: UIImage?
    var exceedsBudget = false
    // ImageRenderer measures first; no bitmap is allocated until its complete height is known.
    renderer.render(rasterizationScale: scale) { size, draw in
      guard NoteSharePolicy.canRenderImage(width: Double(size.width), height: Double(size.height),
                                           scale: Double(scale)) else {
        exceedsBudget = true
        return
      }
      guard let context = CGContext(data: nil, width: Int(ceil(size.width * scale)),
                                    height: Int(ceil(size.height * scale)), bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return }
      context.scaleBy(x: scale, y: scale)
      draw(context)
      guard let image = context.makeImage() else { return }
      result = UIImage(cgImage: image, scale: scale, orientation: .up)
    }
    if exceedsBudget { throw NoteImageError.tooLarge }
    guard let result else { throw NoteImageError.renderFailed }
    return result
  }
}

private enum NoteImageError: Error { case tooLarge, renderFailed }

private struct PreparedNoteShare: Identifiable {
  let id = UUID()
  let items: [Any]
}

private enum NoteShareFormat: String, CaseIterable, Identifiable {
  case image, text, original
  var id: String { rawValue }
  var title: LocalizedStringKey {
    switch self {
    case .image: return "Image"
    case .text: return "Text"
    case .original: return "Original"
    }
  }
}

private enum NoteShareStyle: String, CaseIterable, Identifiable {
  case paper, ink, minimal
  var id: String { rawValue }
  var title: LocalizedStringKey {
    switch self {
    case .paper: return "Paper"
    case .ink: return "Ink"
    case .minimal: return "Minimal"
    }
  }
  var background: Color {
    switch self {
    case .paper: return Color(red: 0.98, green: 0.97, blue: 0.95)
    case .ink: return Color(red: 0.14, green: 0.11, blue: 0.08)
    case .minimal: return .white
    }
  }
  var foreground: Color {
    self == .ink ? Color(red: 0.96, green: 0.92, blue: 0.85) : Color(red: 0.14, green: 0.11, blue: 0.08)
  }
}

private struct NoteShareCanvas: View {
  let bodyText: String
  let date: String?
  let style: NoteShareStyle

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      if style != .minimal {
        Rectangle().fill(style.foreground.opacity(0.5)).frame(width: 26, height: 2)
      }
      if let date {
        Text(date).font(.system(size: 11, design: .monospaced))
          .foregroundStyle(style.foreground.opacity(0.7))
          .accessibilityIdentifier("share-preview-date")
      }
      Text(bodyText).font(NotebookTheme.reading(18, text: bodyText)).lineSpacing(7)
        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(style.foreground)
    .padding(style == .minimal ? 24 : 28)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(style.background)
  }
}
