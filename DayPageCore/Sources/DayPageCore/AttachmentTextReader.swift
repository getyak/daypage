import Foundation
import ImageIO
import PDFKit
import Vision

public enum AttachmentTextError: LocalizedError {
  case unsupported, unreadable, tooLarge, noTranscript, noText
  public var errorDescription: String? {
    switch self {
    case .unsupported: return "This attachment type cannot be read as text yet."
    case .unreadable: return "The selected attachment could not be read."
    case .tooLarge: return "Choose an attachment smaller than 25 MB."
    case .noTranscript: return "This recording has no saved transcript yet."
    case .noText: return "No readable text was found in this attachment."
    }
  }
}

/// File reads require a URL resolved by NotebookStore after a card-scope check.
/// The image-data entry point is also used by explicit local screenshot review.
public enum AttachmentTextReader {
  public static func readImage(data: Data) async throws -> String {
    try Task.checkCancellation()
    guard data.count <= 25 * 1_024 * 1_024 else { throw AttachmentTextError.tooLarge }
    let task = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      let result = try recognizeImage(data)
      try Task.checkCancellation()
      guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AttachmentTextError.noText }
      return bounded(result)
    }
    let text = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    try Task.checkCancellation()
    return text
  }

  public static func read(url: URL, kind: String, transcript: String? = nil) async throws -> String {
    try Task.checkCancellation()
    if kind == "audio" {
      guard let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AttachmentTextError.noTranscript
      }
      return bounded(transcript)
    }
    let task = Task.detached(priority: .utility) { () throws -> String in
      try Task.checkCancellation()
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: 25 * 1_024 * 1_024 + 1) ?? Data()
      guard data.count <= 25 * 1_024 * 1_024 else { throw AttachmentTextError.tooLarge }
      try Task.checkCancellation()
      let result: String
      if kind == "photo" {
        result = try recognizeImage(data)
      } else if url.pathExtension.lowercased() == "pdf" {
        guard let document = PDFDocument(data: data) else { throw AttachmentTextError.unreadable }
        var pages: [String] = []
        for index in 0..<min(document.pageCount, 20) {
          try Task.checkCancellation()
          if let text = document.page(at: index)?.string, !text.isEmpty {
            pages.append("[Page \(index + 1)]\n" + String(text.prefix(8_000)))
          }
        }
        guard !pages.isEmpty else { throw AttachmentTextError.noText }
        result = pages.joined(separator: "\n\n") + (document.pageCount > 20 ? "\n[truncated: first 20 pages]" : "")
      } else if ["txt", "md", "markdown", "csv", "json", "log"].contains(url.pathExtension.lowercased()) {
        guard let text = String(data: data, encoding: .utf8) else { throw AttachmentTextError.unreadable }
        result = text
      } else {
        throw AttachmentTextError.unsupported
      }
      try Task.checkCancellation()
      guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AttachmentTextError.noText }
      return bounded(result)
    }
    let text = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    try Task.checkCancellation()
    return text
  }

  private static func recognizeImage(_ data: Data) throws -> String {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 2_048,
      ] as CFDictionary) else { throw AttachmentTextError.unreadable }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
  }

  private static func bounded(_ text: String) -> String {
    text.count > 16_000 ? String(text.prefix(16_000)) + "\n[truncated]" : text
  }
}
