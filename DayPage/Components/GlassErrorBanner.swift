import SwiftUI

// MARK: - GlassErrorBannerItem

struct GlassErrorBannerItem: Identifiable, Equatable {
    let id: UUID
    let icon: Image
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let retryLabel: String?
    let retryAction: (() -> Void)?

    init(
        id: UUID = UUID(),
        icon: Image,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        retryLabel: String? = nil,
        retryAction: (() -> Void)? = nil
    ) {
        self.id = id
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.retryLabel = retryLabel
        self.retryAction = retryAction
    }

    static func == (lhs: GlassErrorBannerItem, rhs: GlassErrorBannerItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - GlassErrorBannerStack

/// Manages up to 2 simultaneous banners (LIFO). A 3rd push collapses extras into a +N chip.
@MainActor
final class GlassErrorBannerStack: ObservableObject {
    static let shared = GlassErrorBannerStack()

    @Published private(set) var items: [GlassErrorBannerItem] = []

    private var dismissTasks: [UUID: Task<Void, Never>] = [:]
    private let maxVisible = 2

    private init() {}

    func push(_ item: GlassErrorBannerItem) {
        items.append(item)
        scheduleDismiss(for: item)
    }

    func dismiss(id: UUID) {
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
        withAnimation(Motion.slide) {
            items.removeAll { $0.id == id }
        }
    }

    func dismissAll() {
        dismissTasks.values.forEach { $0.cancel() }
        dismissTasks = [:]
        withAnimation(Motion.slide) { items = [] }
    }

    // MARK: - Computed

    /// Banners shown as full cards (newest 2, LIFO).
    var visibleItems: [GlassErrorBannerItem] {
        Array(items.suffix(maxVisible))
    }

    /// Count of banners collapsed into the +N chip.
    var overflowCount: Int {
        max(0, items.count - maxVisible)
    }

    // MARK: - Private

    private func scheduleDismiss(for item: GlassErrorBannerItem) {
        let id = item.id
        dismissTasks[id] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            dismiss(id: id)
        }
    }

    func cancelDismiss(id: UUID) {
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
    }
}

// MARK: - GlassErrorBanner

struct GlassErrorBanner: View {
    let icon: Image
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var retryLabel: String? = nil
    var retryAction: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    @State private var appeared = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(DSColor.errorRed)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(DSType.bodySM)
                        .fontWeight(.semibold)
                        .foregroundColor(DSColor.inkPrimary)

                    if let subtitle {
                        Text(subtitle)
                            .font(DSType.bodySM)
                            .foregroundColor(DSColor.inkMuted)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(title)
                .accessibilityHint(subtitle != nil ? subtitle! : "")

                if let label = retryLabel, let action = retryAction {
                    Button {
                        action()
                        onDismiss?()
                    } label: {
                        Text(label)
                            .font(DSType.sectionLabel)
                            .textCase(.uppercase)
                            .tracking(1.2)
                            .foregroundColor(DSColor.errorRed)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .accessibilityLabel(label)
                }
            }

            Spacer(minLength: 0)

            Button {
                onDismiss?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DSColor.inkSubtle)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("error-banner-dismiss")
        }
        .accessibilityHint("Swipe up to dismiss")
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.height < -10 {
                        Haptics.soft()
                        onDismiss?()
                    }
                }
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DSColor.errorSoft)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .saturation(1.6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [DSColor.glassEdge, Color.clear],
                        startPoint: .top,
                        endPoint: .center
                    ),
                    lineWidth: 0.6
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DSColor.errorSoft.opacity(0.5), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color(hex: "2D1E0A").opacity(0.04), radius: 1, x: 0, y: 1)
        .shadow(color: Color(hex: "2D1E0A").opacity(0.10), radius: 16, x: 0, y: 6)
        .offset(y: appeared ? 0 : -80)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(Motion.slide) { appeared = true }
            Haptics.warn()
        }
    }
}

// MARK: - GlassErrorBannerOverflow (+ N chip)

private struct GlassErrorBannerOverflow: View {
    let count: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text("+\(count) more")
                .font(DSType.labelSM)
                .fontWeight(.medium)
                .foregroundColor(DSColor.errorRed)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .liquidGlassPill()
    }
}

// MARK: - GlassErrorBannerOverlayModifier

struct GlassErrorBannerOverlayModifier: ViewModifier {
    @ObservedObject private var stack = GlassErrorBannerStack.shared

    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content

            if !stack.items.isEmpty {
                // Full-screen tap-outside area sits between content and banners.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { stack.dismissAll() }
                    .zIndex(199)

                VStack(spacing: 8) {
                    if stack.overflowCount > 0 {
                        GlassErrorBannerOverflow(count: stack.overflowCount) {
                            stack.dismissAll()
                        }
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }

                    ForEach(stack.visibleItems) { item in
                        GlassErrorBanner(
                            icon: item.icon,
                            title: item.title,
                            subtitle: item.subtitle,
                            retryLabel: item.retryLabel,
                            retryAction: item.retryAction,
                            onDismiss: { stack.dismiss(id: item.id) }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .zIndex(200)
            }
        }
        .animation(Motion.slide, value: stack.items.map(\.id))
    }
}

extension View {
    func glassErrorBannerOverlay() -> some View {
        modifier(GlassErrorBannerOverlayModifier())
    }
}

// MARK: - Preview

#Preview("Single Banner") {
    ZStack {
        AmbientBackground()
        Color.clear
            .glassErrorBannerOverlay()
            .onAppear {
                GlassErrorBannerStack.shared.push(
                    GlassErrorBannerItem(
                        icon: Image(systemName: "wifi.slash"),
                        title: "error.network.title",
                        subtitle: "error.network.subtitle",
                        retryLabel: "Retry",
                        retryAction: { }
                    )
                )
            }
    }
}

#Preview("Two Banners") {
    ZStack {
        AmbientBackground()
        Color.clear
            .glassErrorBannerOverlay()
            .onAppear {
                GlassErrorBannerStack.shared.push(
                    GlassErrorBannerItem(
                        icon: Image(systemName: "exclamationmark.triangle"),
                        title: "error.sync.title",
                        subtitle: nil,
                        retryLabel: nil,
                        retryAction: nil
                    )
                )
                GlassErrorBannerStack.shared.push(
                    GlassErrorBannerItem(
                        icon: Image(systemName: "wifi.slash"),
                        title: "error.network.title",
                        subtitle: "error.network.subtitle",
                        retryLabel: "Retry",
                        retryAction: { }
                    )
                )
            }
    }
}

#Preview("Overflow +N Chip") {
    ZStack {
        AmbientBackground()
        Color.clear
            .glassErrorBannerOverlay()
            .onAppear {
                for i in 1...4 {
                    GlassErrorBannerStack.shared.push(
                        GlassErrorBannerItem(
                            icon: Image(systemName: "exclamationmark.circle"),
                            title: LocalizedStringKey("Error \(i)"),
                            subtitle: nil,
                            retryLabel: nil,
                            retryAction: nil
                        )
                    )
                }
            }
    }
}

#Preview("No Retry") {
    ZStack {
        AmbientBackground()
        Color.clear
            .glassErrorBannerOverlay()
            .onAppear {
                GlassErrorBannerStack.shared.push(
                    GlassErrorBannerItem(
                        icon: Image(systemName: "lock.fill"),
                        title: "error.auth.title",
                        subtitle: "error.auth.subtitle"
                    )
                )
            }
    }
}
