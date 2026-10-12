import SwiftUI
import DayPageModels

struct ScreenshotCaptureReviewView: View {
    let manifest: ScreenshotCaptureManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.on.rectangle")
                    .foregroundStyle(DSColor.accentOnBg)
                Text("截图收件箱")
                    .font(DSType.titleSM)
                    .foregroundStyle(DSColor.inkPrimary)
                Spacer()
                statusBadge
            }

            if let result = manifest.understanding {
                Text(result.suggestedTitle)
                    .font(DSType.serifBody16)
                    .foregroundStyle(DSColor.inkPrimary)
                Text(result.summary)
                    .font(DSType.bodySM)
                    .foregroundStyle(DSColor.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if !result.suggestedActions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(result.suggestedActions.prefix(2)) { action in
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                Text(action.label).lineLimit(1)
                                Spacer()
                                Text("需确认")
                                    .font(.caption2)
                                    .foregroundStyle(DSColor.inkMuted)
                            }
                            .font(DSType.labelSM)
                            .foregroundStyle(DSColor.inkPrimary)
                        }
                    }
                    .padding(9)
                    .background(DSColor.amberSoft.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityLabel("AI 建议，仅为草稿，需要确认")
                }
            } else if let evidence = manifest.evidence, !evidence.recognizedText.isEmpty {
                Text(evidence.recognizedText)
                    .font(DSType.bodySM)
                    .foregroundStyle(DSColor.inkMuted)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("本机识别文字：\(evidence.recognizedText)")
            } else {
                phaseMessage
            }

            if manifest.evidence?.riskIndicators.isEmpty == false {
                // Heuristic result: describe detected sensitive content staying
                // local — never promise perfect sensitive-content detection.
                Label("本机启发式识别到可能的敏感信息，该截图保留在本机、未上传", systemImage: "hand.raised.fill")
                    .font(DSType.labelSM)
                    .foregroundStyle(DSColor.statusWarning)
                    .accessibilityIdentifier("screenshot-sensitive-local-only")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screenshot-review-\(manifest.id.uuidString)")
    }

    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 4) {
            if isWorking { ProgressView().controlSize(.mini) }
            Image(systemName: statusIcon)
            Text(statusTitle)
        }
        .font(DSFonts.jetBrainsMono(size: 9, weight: .medium, relativeTo: .caption2))
        .foregroundStyle(statusColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.1))
        .clipShape(Capsule())
        .accessibilityLabel(statusTitle)
    }

    private var isWorking: Bool {
        [.extracting, .queued, .understanding].contains(manifest.phase)
    }

    private var statusTitle: String {
        switch manifest.phase {
        case .stored, .ingestPending, .ingested: return "已保全原图"
        case .extracting: return "本机识别"
        case .localOnly: return "仅本机"
        case .queued: return "等待 AI"
        case .needsConsent: return "需要配置"
        case .understanding: return "AI 分析中"
        case .ready: return "AI 生成"
        case .pendingNetwork: return "等待网络"
        case .failed: return "处理失败"
        }
    }

    private var statusIcon: String {
        switch manifest.phase {
        case .ready: return "sparkles"
        case .failed: return "exclamationmark.triangle.fill"
        case .pendingNetwork: return "wifi.slash"
        case .localOnly: return "iphone"
        case .needsConsent: return "key"
        default: return "checkmark.shield"
        }
    }

    private var statusColor: Color {
        switch manifest.phase {
        case .failed: return DSColor.statusError
        case .pendingNetwork, .needsConsent: return DSColor.statusWarning
        case .ready: return DSColor.accentOnBg
        default: return DSColor.inkMuted
        }
    }

    @ViewBuilder
    private var phaseMessage: some View {
        switch manifest.phase {
        case .failed:
            Text("原图仍在 Vault 中，可以安全重试。")
                .foregroundStyle(DSColor.statusError)
        case .pendingNetwork:
            Text("网络恢复后会继续，原图不会丢失。")
        case .needsConsent:
            Text("配置 OpenAI Key 并开启截图云端理解后可重试。")
        default:
            Text("已保存原图，正在准备可检索的本机证据。")
        }
    }
}

struct ScreenshotCaptureActionBar: View {
    let manifest: ScreenshotCaptureManifest
    let onRetry: () -> Void
    let onKeepLocal: () -> Void
    let onExplain: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onExplain) {
                Label("为什么保存它？", systemImage: "text.cursor")
            }
            .accessibilityIdentifier("screenshot-explain-\(manifest.id.uuidString)")

            Spacer(minLength: 4)

            if [.failed, .pendingNetwork, .needsConsent].contains(manifest.phase) {
                Button(action: onRetry) {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("screenshot-retry-\(manifest.id.uuidString)")
            }

            if [.queued, .understanding, .pendingNetwork, .needsConsent].contains(manifest.phase) {
                Button(action: onKeepLocal) {
                    Label("仅本机", systemImage: "iphone")
                }
                .accessibilityIdentifier("screenshot-local-only-\(manifest.id.uuidString)")
            }
        }
        .font(DSType.labelSM)
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .foregroundStyle(DSColor.accentOnBg)
        .padding(.horizontal, 14)
        .frame(height: 42)
    }
}

struct ScreenshotMeaningSheet: View {
    let initialText: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(initialText: String, onSave: @escaping (String) -> Void) {
        self.initialText = initialText
        self.onSave = onSave
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI 能看见截图里有什么，但不知道你为什么留下它。补一句真实意图，会让未来搜索更有用。")
                    .font(DSType.bodySM)
                    .foregroundStyle(DSColor.inkMuted)
                TextEditor(text: $text)
                    .font(DSType.serifBody16)
                    .padding(10)
                    .scrollContentBackground(.hidden)
                    .background(DSColor.surfaceWhite)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("screenshot-meaning-editor")
                Spacer()
            }
            .padding(20)
            .background(DSColor.bgWarm.ignoresSafeArea())
            .navigationTitle("为什么保存它？")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(text)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview("Screenshot ready") {
    ScreenshotCaptureReviewView(manifest: ScreenshotCaptureManifest(
        id: UUID(),
        memoID: UUID(),
        memoDayString: "2026-10-12",
        createdAt: Date(),
        updatedAt: Date(),
        source: .actionButtonShortcut,
        phase: .ready,
        originalPath: "raw/assets/screenshots/example.png",
        contentType: "public.png",
        sha256: "preview",
        originalByteCount: 100,
        pixelWidth: 1179,
        pixelHeight: 2556,
        cloudConsentAtCapture: true,
        understanding: ScreenshotUnderstandingResult(
            suggestedTitle: "周六西湖计划",
            kind: .place,
            summary: "截图包含周六下午去西湖的路线与集合时间。",
            visualDescription: "地图与行程信息",
            suggestedActions: [
                .init(type: "reminder", label: "周六 14:00 提醒出发", confidence: 0.9),
            ],
            provider: .init(kind: "openai", model: "gpt-5.4-mini", promptVersion: "screenshot-v1")
        )
    ))
    .padding()
    .background(DSColor.bgWarm)
}
