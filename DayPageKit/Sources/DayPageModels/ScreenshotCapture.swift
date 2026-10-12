import Foundation

// MARK: - Capture lifecycle

public enum ScreenshotCaptureSource: String, Codable, CaseIterable, Sendable {
    case actionButtonShortcut
    case shareExtension
    case appImport
}

public enum ScreenshotCapturePhase: String, Codable, CaseIterable, Sendable {
    case stored
    case ingestPending
    case ingested
    case extracting
    case localOnly
    case queued
    case needsConsent
    case understanding
    case ready
    case pendingNetwork
    case failed
}

public struct ScreenshotNormalizedRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ScreenshotTextObservation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var confidence: Float
    public var boundingBox: ScreenshotNormalizedRect

    public init(
        id: UUID = UUID(),
        text: String,
        confidence: Float,
        boundingBox: ScreenshotNormalizedRect
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

public struct ScreenshotBarcodeObservation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var symbology: String
    public var payload: String?
    public var boundingBox: ScreenshotNormalizedRect

    public init(
        id: UUID = UUID(),
        symbology: String,
        payload: String?,
        boundingBox: ScreenshotNormalizedRect
    ) {
        self.id = id
        self.symbology = symbology
        self.payload = payload
        self.boundingBox = boundingBox
    }
}

public enum ScreenshotRiskIndicator: String, Codable, CaseIterable, Sendable {
    case oneTimeCode
    case credential
    case financial
    case health
    case identity
}

public struct ScreenshotEvidence: Codable, Equatable, Sendable {
    public var textObservations: [ScreenshotTextObservation]
    public var barcodeObservations: [ScreenshotBarcodeObservation]
    public var riskIndicators: [ScreenshotRiskIndicator]

    public init(
        textObservations: [ScreenshotTextObservation] = [],
        barcodeObservations: [ScreenshotBarcodeObservation] = [],
        riskIndicators: [ScreenshotRiskIndicator] = []
    ) {
        self.textObservations = textObservations
        self.barcodeObservations = barcodeObservations
        self.riskIndicators = riskIndicators
    }

    public var recognizedText: String {
        textObservations.map(\.text).joined(separator: "\n")
    }
}

// MARK: - Typed interpretation

public enum ScreenshotContentKind: String, Codable, CaseIterable, Sendable {
    case article
    case conversation
    case event
    case place
    case product
    case document
    case code
    case other
}

public struct ScreenshotEntitySuggestion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var type: String
    public var confidence: Double
    public var evidenceReferences: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        type: String,
        confidence: Double,
        evidenceReferences: [String] = []
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.confidence = confidence
        self.evidenceReferences = evidenceReferences
    }
}

public struct ScreenshotActionSuggestion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var type: String
    public var label: String
    public var draftFields: [String: String]
    public var confidence: Double
    public var evidenceReferences: [String]
    public var requiresConfirmation: Bool

    public init(
        id: UUID = UUID(),
        type: String,
        label: String,
        draftFields: [String: String] = [:],
        confidence: Double,
        evidenceReferences: [String] = [],
        requiresConfirmation: Bool = true
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.draftFields = draftFields
        self.confidence = confidence
        self.evidenceReferences = evidenceReferences
        self.requiresConfirmation = requiresConfirmation
    }
}

public struct ScreenshotProviderInfo: Codable, Equatable, Sendable {
    public var kind: String
    public var model: String
    public var promptVersion: String

    public init(kind: String, model: String, promptVersion: String) {
        self.kind = kind
        self.model = model
        self.promptVersion = promptVersion
    }
}

public struct ScreenshotUnderstandingResult: Codable, Equatable, Sendable {
    public var suggestedTitle: String
    public var kind: ScreenshotContentKind
    public var summary: String
    public var visualDescription: String
    public var entities: [ScreenshotEntitySuggestion]
    public var suggestedActions: [ScreenshotActionSuggestion]
    public var warnings: [String]
    public var provider: ScreenshotProviderInfo

    public init(
        suggestedTitle: String,
        kind: ScreenshotContentKind,
        summary: String,
        visualDescription: String,
        entities: [ScreenshotEntitySuggestion] = [],
        suggestedActions: [ScreenshotActionSuggestion] = [],
        warnings: [String] = [],
        provider: ScreenshotProviderInfo
    ) {
        self.suggestedTitle = suggestedTitle
        self.kind = kind
        self.summary = summary
        self.visualDescription = visualDescription
        self.entities = entities
        self.suggestedActions = suggestedActions
        self.warnings = warnings
        self.provider = provider
    }
}

// MARK: - Durable manifest

public struct ScreenshotCaptureManifest: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var memoID: UUID
    /// Canonical owning raw day key (`YYYY-MM-DD`) of the raw file this
    /// capture's memo lives in, captured at ingest. Later reconciliation,
    /// delete and undo use THIS key so a preferred-time-zone change can never
    /// retarget the operation to a neighbouring day file.
    public var memoDayString: String
    public var createdAt: Date
    public var updatedAt: Date
    public var source: ScreenshotCaptureSource
    public var phase: ScreenshotCapturePhase
    public var originalPath: String
    public var analysisDerivativePath: String?
    public var contentType: String
    public var sha256: String
    public var originalByteCount: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var cloudConsentAtCapture: Bool
    public var evidence: ScreenshotEvidence?
    public var understanding: ScreenshotUnderstandingResult?
    /// A bounded, non-content error code suitable for UI and diagnostics.
    public var failureReason: String?

    /// Legacy sidecar compatibility (issue #876 originals shipped without
    /// `memoDayString`). Only THIS field falls back when absent: the day is
    /// resolved later by exact memoID in the captured Vault, never guessed
    /// from createdAt. All other fields keep strict decode semantics.
    private enum CodingKeys: String, CodingKey {
        case id, memoID, memoDayString, createdAt, updatedAt, source, phase
        case originalPath, analysisDerivativePath, contentType, sha256
        case originalByteCount, pixelWidth, pixelHeight, cloudConsentAtCapture
        case evidence, understanding, failureReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        memoID = try container.decode(UUID.self, forKey: .memoID)
        // Missing day key ⇒ empty marker; ScreenshotCaptureStore resolves the
        // canonical raw owning day by exact memoID (fail-safe on ambiguity).
        memoDayString = try container.decodeIfPresent(String.self, forKey: .memoDayString) ?? ""
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        source = try container.decode(ScreenshotCaptureSource.self, forKey: .source)
        phase = try container.decode(ScreenshotCapturePhase.self, forKey: .phase)
        originalPath = try container.decode(String.self, forKey: .originalPath)
        analysisDerivativePath = try container.decodeIfPresent(String.self, forKey: .analysisDerivativePath)
        contentType = try container.decode(String.self, forKey: .contentType)
        sha256 = try container.decode(String.self, forKey: .sha256)
        originalByteCount = try container.decode(Int.self, forKey: .originalByteCount)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        cloudConsentAtCapture = try container.decode(Bool.self, forKey: .cloudConsentAtCapture)
        evidence = try container.decodeIfPresent(ScreenshotEvidence.self, forKey: .evidence)
        understanding = try container.decodeIfPresent(ScreenshotUnderstandingResult.self, forKey: .understanding)
        failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
    }

    public init(
        id: UUID,
        memoID: UUID,
        memoDayString: String,
        createdAt: Date,
        updatedAt: Date,
        source: ScreenshotCaptureSource,
        phase: ScreenshotCapturePhase,
        originalPath: String,
        analysisDerivativePath: String? = nil,
        contentType: String,
        sha256: String,
        originalByteCount: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        cloudConsentAtCapture: Bool,
        evidence: ScreenshotEvidence? = nil,
        understanding: ScreenshotUnderstandingResult? = nil,
        failureReason: String? = nil
    ) {
        self.id = id
        self.memoID = memoID
        self.memoDayString = memoDayString
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
        self.phase = phase
        self.originalPath = originalPath
        self.analysisDerivativePath = analysisDerivativePath
        self.contentType = contentType
        self.sha256 = sha256
        self.originalByteCount = originalByteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.cloudConsentAtCapture = cloudConsentAtCapture
        self.evidence = evidence
        self.understanding = understanding
        self.failureReason = failureReason
    }
}

public struct ScreenshotCaptureOutcome: Equatable, Sendable {
    public var manifest: ScreenshotCaptureManifest
    public var isDuplicate: Bool

    public init(manifest: ScreenshotCaptureManifest, isDuplicate: Bool) {
        self.manifest = manifest
        self.isDuplicate = isDuplicate
    }
}
