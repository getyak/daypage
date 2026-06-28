import SwiftUI
import UIKit

// MARK: - Banner Kind

enum BannerKind {
    case progress
    case success
    case error
    case info
}

// MARK: - AppBannerModel

struct AppBannerModel: Identifiable {
    let id = UUID()
    var kind: BannerKind
    var title: String
    var subtitle: String?
    var primaryAction: BannerAction?
    var secondaryAction: BannerAction?
    var autoDismiss: Bool

    init(
        kind: BannerKind,
        title: String,
        subtitle: String? = nil,
        primaryAction: BannerAction? = nil,
        secondaryAction: BannerAction? = nil,
        autoDismiss: Bool = true
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.autoDismiss = autoDismiss
    }
}

struct BannerAction {
    let label: String
    let handler: () -> Void
}

// MARK: - BannerCenter

@MainActor
final class BannerCenter: ObservableObject {
    static let shared = BannerCenter()
    @Published var currentBanner: AppBannerModel?

    private var autoDismissTask: Task<Void, Never>?
    // F5 fix: previously every show() overwrote the current banner, so when
    // background compile + voice transcribe + iCloud conflict all failed at
    // once the user only saw the last error. Errors now queue and display
    // one after another; success/info/progress still overrides immediately.
    private var queue: [AppBannerModel] = []
    private let maxQueueSize = 3

    private init() {}

    func show(_ model: AppBannerModel) {
        // If an error is currently visible and a NEW error comes in, queue it
        // instead of clobbering. Non-error banners still display immediately so
        // a "Saved ✓" toast can interrupt a stale error.
        if case .error = currentBanner?.kind, case .error = model.kind {
            if queue.count < maxQueueSize {
                queue.append(model)
            }
            return
        }
        present(model)
    }

    func dismiss() {
        autoDismissTask?.cancel()
        withAnimation(Motion.respectReduceMotion(Motion.bannerSlide)) {
            currentBanner = nil
        }
        drainNextIfAny()
    }

    // MARK: - Private

    private func present(_ model: AppBannerModel) {
        autoDismissTask?.cancel()
        withAnimation(Motion.respectReduceMotion(Motion.bannerSlide)) {
            currentBanner = model
        }
        if model.autoDismiss {
            // Banners with primary/secondary actions linger longer so users can
            // read and tap them; pure info/success/error toasts fade after 5s.
            let hasAction = model.primaryAction != nil || model.secondaryAction != nil
            let delayNanos: UInt64 = hasAction ? 8_000_000_000 : 5_000_000_000
            autoDismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: delayNanos)
                if !Task.isCancelled {
                    withAnimation(Motion.respectReduceMotion(Motion.bannerSlide)) {
                        self.currentBanner = nil
                    }
                    self.drainNextIfAny()
                }
            }
        }
    }

    private func drainNextIfAny() {
        guard !queue.isEmpty else { return }
        // Give the dismiss animation a beat so the next banner doesn't pop
        // before the prior is visually gone.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !self.queue.isEmpty else { return }
            let next = self.queue.removeFirst()
            self.present(next)
        }
    }
}

// MARK: - AppBanner View

struct AppBanner: View {
    let model: AppBannerModel
    @ObservedObject private var bannerCenter = BannerCenter.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            leadingIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(foregroundColor)
                if let subtitle = model.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(foregroundColor.opacity(0.8))
                }
                if model.primaryAction != nil || model.secondaryAction != nil {
                    HStack(spacing: 16) {
                        if let action = model.primaryAction {
                            Button(action.label, action: action.handler)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(accentColor)
                        }
                        if let action = model.secondaryAction {
                            Button(action.label, action: action.handler)
                                .font(.system(size: 13))
                                .foregroundColor(foregroundColor.opacity(0.7))
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isStaticText)
            Spacer()
            Button {
                bannerCenter.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(foregroundColor.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("banner-dismiss-button")
        }
        .padding(DSSpacing.cardGap)
        .background(backgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: DSSpacing.radiusCard)
                .stroke(borderColor, lineWidth: 1)
        )
        .cornerRadius(DSSpacing.radiusCard)
        .padding(.horizontal, DSSpacing.cardGap)
        .onAppear {
            switch model.kind {
            case .error:            Haptics.warn()
            case .success:          Haptics.success()
            case .info, .progress:  Haptics.soft()
            }
            let announcement = [model.title, model.subtitle].compactMap { $0 }.joined(separator: ". ")
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch model.kind {
        case .progress:
            ProgressView()
                .tint(accentColor)
                .frame(width: 20, height: 20)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(accentColor)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(accentColor)
        case .info:
            Image(systemName: "info.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(accentColor)
        }
    }

    private var accessibilityLabel: String {
        [model.title, model.subtitle].compactMap { $0 }.joined(separator: ". ")
    }

    private var backgroundColor: Color {
        switch model.kind {
        case .progress: return DSColor.warningSoft
        case .success: return DSColor.successSoft
        case .error:   return DSColor.errorSoft
        case .info:    return DSColor.surfaceSunken
        }
    }

    private var foregroundColor: Color {
        DSColor.onBackgroundPrimary
    }

    private var accentColor: Color {
        switch model.kind {
        case .progress: return DSColor.warningAmber
        case .success:  return DSColor.successGreen
        case .error:    return DSColor.errorRed
        case .info:     return DSColor.onBackgroundMuted
        }
    }

    private var borderColor: Color {
        switch model.kind {
        case .progress: return DSColor.accentBorder
        case .success:  return DSColor.successSoft
        case .error:    return DSColor.errorSoft
        case .info:     return DSColor.borderDefault
        }
    }
}

// MARK: - BannerOverlay

struct BannerOverlayModifier: ViewModifier {
    @ObservedObject private var bannerCenter = BannerCenter.shared

    func body(content: Content) -> some View {
        // ZStack keeps the banner floating above content without shifting layout.
        ZStack(alignment: .top) {
            content
            if let banner = bannerCenter.currentBanner {
                AppBanner(model: banner)
                    .padding(.top, 8)
                    // Asymmetric: slide-down + fade-in on entry; pure fade-up
                    // on exit so dismissal feels gentle rather than yanked.
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity.combined(with: .offset(y: -8))
                    ))
                    .zIndex(100)
            }
        }
        .dsAnimation(Motion.bannerSlide, value: bannerCenter.currentBanner?.id)
    }
}

extension View {
    func bannerOverlay() -> some View {
        modifier(BannerOverlayModifier())
    }
}
