import SwiftUI
import DayPageModels
import DayPageServices
import DayPageStorage

// MARK: - MemoDetailTagModel

/// Original exact account-tag labels for one memo (#884). Read-only over the
/// derived projection cache; refreshed on projection changes. `unavailable`
/// is distinct from "no tags" — a missing/failed cache never claims zero.
@MainActor
final class MemoDetailTagModel: ObservableObject {
    enum Availability: Equatable {
        case loading
        case unavailable
        case ready
    }

    @Published private(set) var availability: Availability = .loading
    /// ORIGINAL label text in exact catalogue order (byte-exact, no trim,
    /// no normalization, no invented parents).
    @Published private(set) var labels: [String] = []

    func reload(memoID: UUID) {
        // Single optional binding: `try?` already yields an optional.
        var bound: SyncRealmIdentity?
        do {
            bound = try SyncAccountStateStore.boundRealm()
        } catch {
            bound = nil
        }
        guard let realm = bound else {
            availability = .unavailable
            labels = []
            return
        }
        do {
            let snapshot = try AccountTagProjectionStore.read(
                realm: realm,
                vaultRoot: VaultInitializer.vaultURL
            )
            labels = snapshot.links.filter { $0.memoID == memoID }.map { $0.label.text }
            availability = .ready
        } catch {
            labels = []
            availability = .unavailable
        }
    }
}

// Absolute capture time is displayed in the selected zone. Raw file ownership
// remains the validated route key supplied separately by MemoDetailHost.
enum MemoDetailDatePresentation {
    static func createdFull(_ date: Date, timeZone: TimeZone) -> String {
        string(date, pattern: "yyyy-MM-dd HH:mm:ss", timeZone: timeZone)
    }

    static func kicker(_ date: Date, timeZone: TimeZone) -> String {
        string(date, pattern: "yyyy-MM-dd  HH:mm", timeZone: timeZone).uppercased()
    }

    private static func string(_ date: Date, pattern: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

struct MemoDetailMetadataSection: View {
    let memo: Memo
    let photoMetadataByFile: [String: PhotoMetadata]
    var owningFileKey: String? = nil
    @ObservedObject private var appSettings = AppSettings.shared
    @StateObject private var tagModel = MemoDetailTagModel()

    private struct BodyStats {
        let wordCount: Int
        let characterCount: Int
        let readingMinutes: Int
    }

    private var createdFull: String {
        MemoDetailDatePresentation.createdFull(memo.created, timeZone: appSettings.preferredTimeZone)
    }

    private var bodyStats: BodyStats {
        var cjkCount = 0
        var latinWords = 0
        var inLatinRun = false
        for scalar in memo.body.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) ||
                (0x3400...0x4DBF).contains(scalar.value) ||
                (0x3040...0x30FF).contains(scalar.value) {
                cjkCount += 1
                inLatinRun = false
            } else if scalar.properties.isWhitespace {
                inLatinRun = false
            } else {
                if !inLatinRun { latinWords += 1 }
                inLatinRun = true
            }
        }
        let minutes = Double(cjkCount) / 300 + Double(latinWords) / 220
        return BodyStats(
            wordCount: TextCount.words(memo.body),
            characterCount: memo.body.count,
            readingMinutes: MemoPresentationSafety.roundedInt(minutes) ?? 0
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            memoDetailSectionLabel(NSLocalizedString("memo.detail.section.metadata", comment: ""))
                .padding(.bottom, DSSpacing.xs)

            row(NSLocalizedString("memo.detail.meta.created", comment: ""), createdFull)
            row(NSLocalizedString("memo.detail.meta.file", comment: ""), "vault/raw/\(owningFileKey ?? DateFormatters.isoDate.string(from: memo.created)).md")
            row(NSLocalizedString("memo.detail.meta.kind", comment: ""), memo.type.rawValue.capitalized)

            tagRows

            if !memo.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if bodyStats.wordCount != bodyStats.characterCount {
                    row(NSLocalizedString("memo.detail.meta.words", comment: ""), "\(bodyStats.wordCount)")
                }
                row(NSLocalizedString("memo.detail.meta.characters", comment: ""), "\(bodyStats.characterCount)")
                row(NSLocalizedString("memo.detail.meta.reading", comment: ""), readingTime)
            }

            kindSpecificRows
        }
        .onAppear { tagModel.reload(memoID: memo.id) }
        .onChange(of: memo.id) { newValue in
            tagModel.reload(memoID: newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountTagProjectionDidUpdate)) { _ in
            // Projection refreshes update the original label list live.
            tagModel.reload(memoID: memo.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .rawStorageDidWrite)) { _ in
            tagModel.reload(memoID: memo.id)
        }
    }

    private var readingTime: String {
        bodyStats.readingMinutes < 1
            ? NSLocalizedString("memo.detail.meta.reading.less_than_1", comment: "")
            : String(format: NSLocalizedString("memo.detail.meta.reading.min", comment: ""), bodyStats.readingMinutes)
    }

    /// Original exact labels of this memo (#884). Unavailable metadata is
    /// visually distinct from a memo that genuinely has no tags.
    @ViewBuilder
    private var tagRows: some View {
        switch tagModel.availability {
        case .loading:
            EmptyView()
        case .unavailable:
            row(
                NSLocalizedString("memo.detail.meta.tags", comment: ""),
                NSLocalizedString("memo.detail.meta.tags.unavailable", comment: "")
            )
        case .ready:
            if tagModel.labels.isEmpty {
                row(
                    NSLocalizedString("memo.detail.meta.tags", comment: ""),
                    NSLocalizedString("memo.detail.meta.tags.none", comment: "")
                )
            } else {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text(NSLocalizedString("memo.detail.meta.tags", comment: "").uppercased())
                        .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                        .tracking(0.6)
                        .foregroundColor(DSColor.inkMuted)
                    FlowTagChips(labels: tagModel.labels)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var kindSpecificRows: some View {
        if let audio = memo.attachments.first(where: { $0.kind == "audio" }) {
            if let duration = audio.presentationDuration {
                row(NSLocalizedString("memo.detail.meta.duration", comment: ""), duration.mmss)
            }
            row(
                NSLocalizedString("memo.detail.meta.transcription", comment: ""),
                audio.transcript?.isEmpty == false
                    ? NSLocalizedString("memo.detail.meta.transcription.provider", comment: "")
                    : NSLocalizedString("memo.detail.meta.transcription.pending", comment: "")
            )
        }

        if let photo = memo.attachments.first(where: { $0.kind == "photo" }),
           let metadata = photoMetadataByFile[photo.file] {
            ForEach(metadata.rows) { metadataRow in
                row(metadataRow.label, metadataRow.value)
            }
        }

        if let location = memo.location {
            if let coordinate = location.presentationCoordinate {
                row(NSLocalizedString("memo.detail.meta.coordinates", comment: ""), String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude))
            }
            if let name = location.name, !name.isEmpty {
                row(NSLocalizedString("memo.detail.meta.place", comment: ""), name)
            }
        }

        if let weather = memo.weather, !weather.isEmpty {
            row(NSLocalizedString("memo.detail.meta.weather", comment: ""), weather)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.sm) {
            Text(label.uppercased())
                .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                .tracking(0.6)
                .foregroundColor(DSColor.inkMuted)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                .tracking(0.4)
                .foregroundColor(DSColor.inkMuted)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - FlowTagChips

/// Exact original label chips with stable non-String identity. Two
/// canonically-equivalent `String` spellings stay visually and structurally
/// distinct because the identity is the label's UTF-8 bytes.
struct FlowTagChips: View {
    let labels: [String]

    var body: some View {
        FlexibleTagLayout(spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, text in
                Text(text)
                    .font(DSFonts.inter(size: 12, relativeTo: .footnote))
                    .foregroundColor(DSColor.inkMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(DSColor.glassLo, in: Capsule())
                    .textSelection(.enabled)
            }
        }
    }
}

/// Minimal wrapping layout for tag chips (iOS 16 compatible).
///
/// Every chip is measured AND placed with a width bounded by the remaining
/// row width, so a legal long label (up to 1024 UTF-8 bytes) wraps inside the
/// container instead of overflowing it. Both passes use the SAME bounded
/// proposal, the label text keeps its exact bytes (no truncation, no
/// normalization) and stays fully selectable.
struct FlexibleTagLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0
        for subview in subviews {
            let natural = subview.sizeThatFits(.unspecified)
            var gap = rowWidth > 0 ? spacing : 0
            if maxWidth != .infinity, rowWidth > 0, rowWidth + gap + natural.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
                gap = 0
            }
            let available = maxWidth == .infinity
                ? CGFloat.infinity
                : max(0, maxWidth - rowWidth - gap)
            let boundedWidth = maxWidth == .infinity
                ? natural.width
                : min(natural.width, available)
            // SAME bounded proposal as placement: a long label wraps instead
            // of overflowing, and its full text remains the source value.
            let measured = subview.sizeThatFits(
                ProposedViewSize(width: boundedWidth, height: nil)
            )
            rowWidth += gap + measured.width
            rowHeight = max(rowHeight, measured.height)
            widestRow = max(widestRow, rowWidth)
        }
        totalHeight += rowHeight
        return CGSize(
            width: maxWidth == .infinity ? widestRow : maxWidth,
            height: totalHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let natural = subview.sizeThatFits(.unspecified)
            var gap = x > bounds.minX ? spacing : 0
            if x > bounds.minX, x + gap + natural.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
                gap = 0
            }
            let boundedWidth = min(natural.width, max(0, bounds.maxX - x - gap))
            let measured = subview.sizeThatFits(
                ProposedViewSize(width: boundedWidth, height: nil)
            )
            subview.place(
                at: CGPoint(x: x + gap, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: boundedWidth, height: nil)
            )
            x += gap + measured.width
            rowHeight = max(rowHeight, measured.height)
        }
    }
}
