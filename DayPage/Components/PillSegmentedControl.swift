import SwiftUI
import DayPageServices

// MARK: - PillSegmentedControl
//
// Museum-aesthetic segmented control (Claude Design bundle — app.jsx Segmented).
// A pill track on a sunken surface; the selected segment lifts onto a white
// pill with accent text + a whisper of shadow.
//
//   ┌─────────────────────────────┐
//   │ [ 今日 ]   成稿     档案     │   ← selected = white pill, accent text
//   └─────────────────────────────┘
//
// Generic over a Hashable id so callers bind it to their own tab enum.

struct PillSegmentedControl<ID: Hashable>: View {
    struct Segment: Identifiable {
        let id: ID
        let label: String
    }

    let segments: [Segment]
    @Binding var selection: ID
    var onSelect: ((ID) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pillNamespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments) { segment in
                segmentButton(segment)
            }
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(DSColor.surfaceSunken)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(DSColor.borderSubtle, lineWidth: 0.5)
                )
        )
        .accessibilityElement(children: .contain)
    }

    private func segmentButton(_ segment: Segment) -> some View {
        let isSelected = segment.id == selection
        return Button {
            guard !isSelected else { return }
            Haptics.soft()
            withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)) {
                selection = segment.id
            }
            onSelect?(segment.id)
        } label: {
            Text(segment.label)
                .font(.custom("Inter-Medium", size: 13))
                .fontWeight(isSelected ? .semibold : .medium)
                .foregroundColor(isSelected ? DSColor.accentAmber : DSColor.inkMuted)
                .lineLimit(1)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(DSColor.surfaceWhite)
                            .shadow(color: Color.black.opacity(0.06), radius: 1, x: 0, y: 1)
                            .matchedGeometryEffect(id: "pill", in: pillNamespace)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityLabel(segment.label)
    }
}
