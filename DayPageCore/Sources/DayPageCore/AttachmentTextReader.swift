import Foundation
import ImageIO
import PDFKit
import Vision
#if targetEnvironment(simulator) && os(iOS)
import CoreML
#endif

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
    try await readImageData(data: data, diagnostic: nil)
  }

  #if DEBUG
  /// Static synthetic-QA phases only. The caller owns the exact QA scope;
  /// no image, recognized text, file location or error payload is observed.
  public static func readImage(data: Data, diagnostic: @escaping @Sendable (String) -> Void,
    workerFacts: SyntheticOCRWorkerFacts? = nil) async throws -> String {
    try await readImageData(data: data, diagnostic: { phase in
      workerFacts?.record(phase)
      diagnostic(phase)
    })
  }
  #endif

  private static func readImageData(data: Data, diagnostic: (@Sendable (String) -> Void)?) async throws -> String {
    try Task.checkCancellation()
    guard data.count <= 25 * 1_024 * 1_024 else { throw AttachmentTextError.tooLarge }
    let task = Task.detached(priority: .utility) {
      diagnostic?("worker_entered")
      try Task.checkCancellation()
      let result = try recognizeImage(data, diagnostic: diagnostic)
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

  private static func recognizeImage(_ data: Data, diagnostic: (@Sendable (String) -> Void)? = nil) throws -> String {
    diagnostic?("decode_started")
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
    #if targetEnvironment(simulator) && os(iOS)
      if #available(iOS 17.0, *) {
        // Keep the accurate multilingual request on real supported devices.
        // Simulator stages can explicitly use their supported CPU device;
        // stages without one keep Vision's normal device selection.
        for (stage, devices) in try request.supportedComputeStageDevices {
          if let cpu = devices.first(where: { if case .cpu(_) = $0 { return true }; return false }) {
            request.setComputeDevice(cpu, for: stage)
          }
        }
      }
    #endif
    diagnostic?("vision_entered")
    do { try VNImageRequestHandler(cgImage: image).perform([request]) }
    catch { diagnostic?("vision_failed"); throw error }
    diagnostic?("vision_returned")
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
  }

  private static func bounded(_ text: String) -> String {
    text.count > 16_000 ? String(text.prefix(16_000)) + "\n[truncated]" : text
  }
}

#if DEBUG
/// One synthetic attempt only. Raw uptime never leaves this object; the lock
/// protects five first-observed worker stamps. No callbacks or UI work run locked.
public final class SyntheticOCRWorkerFacts: @unchecked Sendable {
  public struct Snapshot: Sendable {
    public let workerEnteredMS: Int?
    public let decodeStartedMS: Int?
    public let visionEnteredMS: Int?
    public let visionReturnedMS: Int?
    public let visionFailedMS: Int?
    public let sampledMS: Int?
    public let clamped: Bool
    public let clockValid: Bool
  }
  private let lock = NSLock()
  private let admitted = DispatchTime.now().uptimeNanoseconds
  private var stamps: [UInt64?] = Array(repeating: nil, count: 5)
  public init() {}

  fileprivate func record(_ phase: String) {
    let index: Int
    switch phase {
    case "worker_entered": index = 0
    case "decode_started": index = 1
    case "vision_entered": index = 2
    case "vision_returned": index = 3
    case "vision_failed": index = 4
    default: return
    }
    let observed = DispatchTime.now().uptimeNanoseconds
    lock.lock()
    if stamps[index] == nil { stamps[index] = observed }
    lock.unlock()
  }

  public func snapshot() -> Snapshot {
    lock.lock()
    let observed = stamps
    let sampled = DispatchTime.now().uptimeNanoseconds
    lock.unlock()
    var clamped = false, clockValid = true
    func elapsed(_ stamp: UInt64?) -> Int? {
      guard let stamp else { return nil }
      guard stamp >= admitted else { clockValid = false; return nil }
      let milliseconds = (stamp - admitted) / 1_000_000
      if milliseconds > 120_000 { clamped = true }
      return Int(min(milliseconds, 120_000))
    }
    let worker = elapsed(observed[0]), decode = elapsed(observed[1])
    let entered = elapsed(observed[2]), returned = elapsed(observed[3]), failed = elapsed(observed[4])
    let read = elapsed(sampled)
    return Snapshot(workerEnteredMS: worker, decodeStartedMS: decode, visionEnteredMS: entered,
      visionReturnedMS: returned, visionFailedMS: failed, sampledMS: read,
      clamped: clamped, clockValid: clockValid)
  }
}
#endif
