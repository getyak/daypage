import Foundation
import ImageIO
import UniformTypeIdentifiers
import DayPageModels

#if canImport(Vision) && !os(watchOS)
import Vision
#endif

public protocol ScreenshotEvidenceExtracting: Sendable {
    func extract(from imageData: Data) async throws -> ScreenshotEvidence
}

public struct VisionScreenshotEvidenceExtractor: ScreenshotEvidenceExtracting {
    public init() {}

    public func extract(from imageData: Data) async throws -> ScreenshotEvidence {
        #if canImport(Vision) && !os(watchOS)
        return try await Task.detached(priority: .userInitiated) {
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.automaticallyDetectsLanguage = true

            let barcodeRequest = VNDetectBarcodesRequest()
            let handler = VNImageRequestHandler(data: imageData, options: [:])
            try handler.perform([textRequest, barcodeRequest])

            let text = (textRequest.results ?? []).compactMap { observation -> ScreenshotTextObservation? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                return ScreenshotTextObservation(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    boundingBox: ScreenshotNormalizedRect(
                        x: box.origin.x,
                        y: box.origin.y,
                        width: box.size.width,
                        height: box.size.height
                    )
                )
            }

            let barcodes = (barcodeRequest.results ?? []).map { observation in
                let box = observation.boundingBox
                return ScreenshotBarcodeObservation(
                    symbology: observation.symbology.rawValue,
                    payload: observation.payloadStringValue,
                    boundingBox: ScreenshotNormalizedRect(
                        x: box.origin.x,
                        y: box.origin.y,
                        width: box.size.width,
                        height: box.size.height
                    )
                )
            }

            let joinedText = text.map(\.text).joined(separator: "\n")
            return ScreenshotEvidence(
                textObservations: text,
                barcodeObservations: barcodes,
                riskIndicators: Self.riskIndicators(in: joinedText)
            )
        }.value
        #else
        return ScreenshotEvidence()
        #endif
    }

    static func riskIndicators(in text: String) -> [ScreenshotRiskIndicator] {
        let lower = text.lowercased()
        var indicators: Set<ScreenshotRiskIndicator> = []

        let otpTerms = ["验证码", "一次性密码", "verification code", "one-time code", "otp"]
        if otpTerms.contains(where: lower.contains) { indicators.insert(.oneTimeCode) }

        let credentialTerms = ["密码", "passcode", "password", "api key", "secret key", "助记词"]
        if credentialTerms.contains(where: lower.contains) { indicators.insert(.credential) }

        let financialTerms = ["银行卡", "信用卡", "账户余额", "bank account", "credit card", "balance"]
        if financialTerms.contains(where: lower.contains) { indicators.insert(.financial) }

        let healthTerms = ["病历", "诊断", "处方", "medical record", "diagnosis", "prescription"]
        if healthTerms.contains(where: lower.contains) { indicators.insert(.health) }

        let identityTerms = ["身份证", "护照", "social security", "passport", "identity card"]
        if identityTerms.contains(where: lower.contains) { indicators.insert(.identity) }

        return ScreenshotRiskIndicator.allCases.filter(indicators.contains)
    }
}

public enum ScreenshotAnalysisImageError: Error {
    case invalidSource
    case thumbnailFailed
    case encodeFailed
}

/// Creates a metadata-free, bounded JPEG for cloud understanding. The original
/// lossless screenshot remains untouched in the Vault.
public enum ScreenshotAnalysisImage {
    public static func makeJPEG(
        from data: Data,
        maximumPixelDimension: Int = 1_600,
        compressionQuality: Double = 0.82
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ScreenshotAnalysisImageError.invalidSource
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ScreenshotAnalysisImageError.thumbnailFailed
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotAnalysisImageError.encodeFailed
        }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotAnalysisImageError.encodeFailed
        }
        return output as Data
    }
}
