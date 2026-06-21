import SwiftUI

// MARK: - SwipePhysics
//
// All numeric constants for the swipe-to-reveal interaction live here so the
// motion language is auditable in one place and easy to tune. Names are
// chosen to map to the four-stage gesture vocabulary:
//
//   peek      — finger moves but the action is not yet committable.
//   reveal    — the user has crossed the open threshold; icon + label sit on
//                a settled panel; releasing snaps the panel open.
//   rubber    — drag continues past the panel; resistance grows with distance.
//
// Tuned against Apple Mail / Notes / Reminders for snappy attack and minimal
// overshoot, while keeping the panel surface visually quiet at small offsets.
private enum SwipePhysics {

    /// Width of one action button inside a side panel.
    static let actionWidth: CGFloat = 76

    /// Total reveal width on each side. Each side now exposes TWO actions
    /// (left: share + delete, right: pin + more), so the panel is two action
    /// columns wide. A half-swipe still opens; a full swipe rests here.
    static let panelWidth: CGFloat = actionWidth * 2  // 152

    /// Translation past which a release snaps open (vs. snap back closed).
    /// Apple Notes uses ~40pt; we follow the same ratio to panelWidth so a
    /// confident half-swipe always opens but a hesitant brush snaps back.
    static let openThreshold: CGFloat = 40

    /// Translation while open past which a release snaps closed. Lower than
    /// openThreshold because the user has already paid the gesture cost of
    /// opening — closing should feel lighter.
    static let closeThreshold: CGFloat = 24

    /// Velocity (pt/s) past which a flick alone opens the panel, regardless
    /// of translation. UIKit reports real velocity so we use the same
    /// numeric scale as iOS Mail (~600 pt/s).
    static let velocityOpen: CGFloat = 600

    /// Velocity past which a flick alone closes the panel.
    static let velocityClose: CGFloat = 500

    /// Resistance coefficient applied to drag past the panel edge. 0.25 is
    /// firmer than the previous 0.35 so the limit reads as a real wall while
    /// still allowing a tactile overdrag.
    static let rubberBand: CGFloat = 0.25

    /// Spring used for snap-open / snap-close. Same response as iOS Mail
    /// (~0.28s) with damping that lets the panel settle in one cycle.
    static let snapSpring: Animation = .spring(response: 0.28, dampingFraction: 0.86)

    /// Eased curve used in place of `snapSpring` when Reduce Motion is on.
    /// No bounce, slightly shorter so the user can still feel the commit.
    static let reducedSnap: Animation = .easeOut(duration: 0.22)
}

// MARK: - SwipeableMemoCard
//
// iOS-native swipe-to-reveal wrapper around MemoCardView, built on a UIKit
// UIPanGestureRecognizer (see HorizontalPanGesture.swift) so the parent
// ScrollView keeps full ownership of vertical drags. Mirrors iOS Mail,
// Reminders, and Things 3 swipe-to-reveal behavior, with iOS-26-flavored
// visual choreography: the action surface deepens in tone as the drag
// progresses, the icon scales up, and the label only resolves once the
// open threshold is crossed.
//
//  - Left swipe → trailing SHARE action (accent amber) — the prominent,
//    content-first action surfaced by the museum-aesthetic redesign.
//  - Right swipe → leading MORE action (sunken neutral) — opens the fuller
//    set (pin / delete / …) so secondary chrome stays hidden by default.
//
// Gesture model:
//  - settledOffset is the resting position; dragDelta rides on top 1:1.
//  - Rubber-band resistance beyond ±panelW gives tactile limit feedback.
//  - Velocity-aware snap: a flick opens/closes even with small translation.
//  - Threshold-cross haptic tick fires during the drag (not just at button
//    tap), matching the Apple Notes "you've armed an action" feel.
//
// Why no SwiftUI DragGesture: SwiftUI's DragGesture + simultaneousGesture
// activates on the very first touch event and cannot relinquish gesture
// ownership back to UIScrollView. That broke vertical timeline scrolling
// whenever a finger landed on a card. The UIKit recognizer's
// gestureRecognizerShouldBegin gate is the only correct way to express
// "stay pending until direction is confirmed."
struct SwipeableMemoCard: View {

    let memo: Memo
    var onDelete: (() -> Void)? = nil
    var onPin: (() -> Void)? = nil
    /// Left-swipe SHARE action (museum-aesthetic primary).
    var onShare: (() -> Void)? = nil
    /// Right-swipe MORE action — parent presents the fuller action set.
    var onMore: (() -> Void)? = nil
    /// Tap on the card body → open the memo detail. Because the swipe
    /// recognizer's host view hit-tests to self (so it can see touches), the
    /// tap can no longer rely on a SwiftUI NavigationLink underneath; the
    /// parent drives navigation programmatically when this fires. In
    /// selection mode the parent re-routes this to toggle membership instead.
    var onOpen: (() -> Void)? = nil
    var onRetranscribe: ((Memo, Memo.Attachment) -> Void)? = nil
    /// Issue #309 W2: in multi-select mode, both the NavigationLink tap
    /// and the swipe gesture must be inert — the only valid interaction is
    /// the tap-to-toggle handled by the parent TimelineRow. Both panels
    /// are also auto-closed when entering this mode.
    var isSelectionMode: Bool = false

    // Settled resting offset: -panelW = trailing open, 0 = closed, +panelW = leading open
    @State private var settledOffset: CGFloat = 0

    // Live horizontal translation from the active UIKit pan. Distinct from
    // settledOffset so we can apply rubber-band on the sum without losing
    // either piece of state mid-drag.
    @State private var dragDelta: CGFloat = 0

    // True while UIPanGestureRecognizer is in began/changed. Used to disable
    // the NavigationLink so the tap that fires on lift after a real swipe
    // never routes to the detail page.
    @State private var isPanActive: Bool = false

    // Tracks which threshold the live drag has already crossed so the
    // mid-drag haptic tick fires once per cross, not once per frame.
    @State private var armedSide: Side? = nil

    // R3 — fires a stronger "fully revealed" light-impact tick the first
    // time the user pulls the panel all the way open (≥ panelWidth) within
    // a single drag. Distinct from the early `armedSide` tick (which fires
    // at openThreshold to signal "release-to-arm"). Resets when the drag
    // ends or the drag direction flips.
    @State private var fullyRevealedSide: Side? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    fileprivate enum Side { case leading, trailing }

    private var revealedSide: Side? {
        if settledOffset < -1 { return .trailing }
        if settledOffset > 1  { return .leading }
        return nil
    }

    private var currentOffset: CGFloat {
        let raw = settledOffset + dragDelta
        let w = SwipePhysics.panelWidth
        if raw > w  { return w  + (raw - w)  * SwipePhysics.rubberBand }
        if raw < -w { return -w + (raw + w)  * SwipePhysics.rubberBand }
        return raw
    }

    /// Normalized reveal progress used by the panel choreography. Positive
    /// when the leading (right-swipe → pin) panel is being revealed and
    /// negative for the trailing (left-swipe → delete) panel. Lightly
    /// over-clamped at ±1.4 so a small rubber-band overdrag still nudges
    /// scale/opacity without blowing them out.
    private var revealProgress: CGFloat {
        let p = currentOffset / SwipePhysics.panelWidth
        return max(-1.4, min(1.4, p))
    }

    private var accessibilityMemoLabel: String {
        let prefix = memo.body.prefix(50)
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Memo" : "Memo: \(trimmed)"
    }

    private var snapAnimation: Animation {
        reduceMotion ? SwipePhysics.reducedSnap : SwipePhysics.snapSpring
    }

    /// Long-press fallback menu — SHARE / PIN(or UNPIN) / DELETE. Mirrors
    /// the swipe-revealed actions so users who haven't found the gesture
    /// (or are using VoiceOver) can still reach every option. Disabled in
    /// selection mode by attaching only when not selecting.
    @ViewBuilder private func contextMenuItems() -> some View {
        if !isSelectionMode {
            Button {
                Haptics.tapConfirm()
                onShare?()
            } label: {
                Label(
                    NSLocalizedString("memo.swipe.share", comment: "Swipe/contextMenu: share memo"),
                    systemImage: "square.and.arrow.up"
                )
            }

            Button {
                Haptics.tapConfirm()
                onPin?()
            } label: {
                let label = memo.pinnedAt != nil
                    ? NSLocalizedString("memo.swipe.unpin", comment: "Swipe/contextMenu: unpin memo")
                    : NSLocalizedString("memo.swipe.pin",   comment: "Swipe/contextMenu: pin memo")
                Label(label, systemImage: memo.pinnedAt != nil ? "pin.slash" : "pin")
            }

            // role:.destructive paints the menu row red in iOS 15+; the
            // warning notification haptic before the delete callback
            // mirrors the swipe-revealed DELETE behaviour.
            Button(role: .destructive) {
                Haptics.warningNotification()
                onDelete?()
            } label: {
                Label(
                    NSLocalizedString("memo.swipe.delete", comment: "Swipe/contextMenu: delete memo"),
                    systemImage: "trash"
                )
            }
        }
    }

    var body: some View {
        ZStack(alignment: .center) {
            // LAYER 1 (bottom): the card body — pure presentation. Navigation
            // and panel-close are driven by the tap recognizer inside
            // HorizontalPanGesture (onTap), not a SwiftUI NavigationLink,
            // because the pan host view hit-tests to self.
            MemoCardView(memo: memo, onDelete: onDelete)
                .contentShape(Rectangle())
                .offset(x: isSelectionMode ? 0 : currentOffset)
                // UIKit pan + tap as an OVERLAY (not background): the
                // recognizers' host must sit in the hit-test walk for touches
                // on the card, so it has to be ABOVE the card. A confirmed
                // horizontal pan drives swipe-to-reveal; a plain tap fires
                // onTap (open detail, or — when a panel is open — close it).
                // Vertical drags never satisfy the direction-lock, so the
                // parent ScrollView keeps ownership and the timeline scrolls.
                .overlay(
                    HorizontalPanGesture(
                        isActive: $isPanActive,
                        onChanged: handlePanChanged,
                        onEnded: handlePanEnded,
                        onCancelled: handlePanCancelled,
                        onTap: handleCardTap,
                        isEnabled: !isSelectionMode
                    )
                )

            // LAYER 2 (top): the action drawers. They MUST sit ABOVE the card
            // so their SwiftUI Buttons reliably receive taps. The old design
            // placed them behind the card, where the card's offset frame and
            // its gesture overlay intercepted the buttons' taps — so a
            // revealed Share / Delete / Pin / More never fired. Each panel is
            // pinned to its screen edge and its content stays hidden (opacity
            // 0, hit-testing off) until `progress` rises, so at rest the
            // drawers never steal taps from the card. Hit-testing for the
            // whole layer is additionally gated on an actually-open panel.
            HStack(spacing: 0) {
                SwipeActionPanel(
                    actions: leadingActions,
                    edge: .leading,
                    progress: max(0, revealProgress)
                )
                Spacer(minLength: 0)
                SwipeActionPanel(
                    actions: trailingActions,
                    edge: .trailing,
                    progress: max(0, -revealProgress)
                )
            }
            .allowsHitTesting(revealedSide != nil && !isSelectionMode)
        }
        .clipped()
        // R3 — long-press contextMenu fallback. The swipe drawer is the
        // primary discovery path, but users who don't yet know the gesture
        // (or who are using accessibility tools) can still reach every
        // action via long-press. Disabled in selection mode so a long
        // press there doesn't fight the toggle.
        .contextMenu(menuItems: contextMenuItems)
        .accessibilityLabel(accessibilityMemoLabel)
        .accessibilityAction(named: "Share") { onShare?() }
        .accessibilityAction(named: "More") { onMore?() }
        .accessibilityAction(named: "Delete") { onDelete?() }
        .accessibilityAction(named: memo.pinnedAt != nil ? "Unpin" : "Pin") { onPin?() }
        // Entering selection mode mid-swipe (panel revealed) would leave a
        // dangling open panel that the user can't close — selection-mode
        // gestures don't reach the close overlay. Force-close on transition
        // so the card is visually flush when selection chrome appears.
        .onChange(of: isSelectionMode) { newValue in
            if newValue, revealedSide != nil {
                snapClose()
            }
        }
    }

    // MARK: - Swipe action definitions
    //
    // Each side exposes two actions. Left-swipe (trailing) surfaces the
    // content-first SHARE plus DELETE; right-swipe (leading) surfaces PIN plus
    // MORE. Building them as data lets SwipeActionPanel lay out N buttons
    // generically and keeps the choreography in one place.

    /// Right-swipe panel — pin (toggle) + more.
    private var leadingActions: [SwipeAction] {
        var items: [SwipeAction] = []
        items.append(SwipeAction(
            id: .pin,
            label: memo.pinnedAt != nil
                ? NSLocalizedString("memo.swipe.unpin", comment: "Swipe action: unpin memo")
                : NSLocalizedString("memo.swipe.pin",   comment: "Swipe action: pin memo"),
            systemImage: memo.pinnedAt != nil ? "pin.slash" : "pin",
            tone: .neutral,
            run: { runAction { onPin?() } }
        ))
        items.append(SwipeAction(
            id: .more,
            label: NSLocalizedString("memo.swipe.more", comment: "Swipe action: more options"),
            systemImage: "ellipsis",
            tone: .neutral,
            run: { runAction(haptic: .soft) { onMore?() } }
        ))
        return items
    }

    /// Left-swipe panel — share (primary) + delete (destructive).
    private var trailingActions: [SwipeAction] {
        [
            SwipeAction(
                id: .share,
                label: NSLocalizedString("memo.swipe.share", comment: "Swipe action: share memo"),
                systemImage: "square.and.arrow.up",
                tone: .accent,
                run: { runAction(haptic: .confirm) { onShare?() } }
            ),
            SwipeAction(
                id: .delete,
                label: NSLocalizedString("memo.swipe.delete", comment: "Swipe action: delete memo"),
                systemImage: "trash",
                tone: .destructive,
                // R3 — destructive actions get the system warning notification
                // pulse (not the lighter confirm tick) so the user feels an
                // unmistakable "irreversible action ahead" cue before the
                // close animation runs and the parent's actual delete fires.
                run: { runAction(haptic: .warn) { onDelete?() } }
            ),
        ]
    }

    // MARK: - Action handlers

    /// A plain tap on the card body. Priority: (1) if a side panel is open,
    /// the tap just closes it — never navigates; (2) otherwise route to the
    /// parent (open detail, or toggle selection in selection mode).
    private func handleCardTap() {
        if revealedSide != nil {
            snapClose()
            return
        }
        onOpen?()
    }

    /// Shared run-then-close choreography: fire a haptic, snap the panel
    /// closed, then run the action after the close settles so the detail
    /// sheet / dialog doesn't animate over a still-open drawer.
    private enum ActionHaptic { case soft, confirm, warn }
    private func runAction(haptic: ActionHaptic = .soft, _ action: @escaping () -> Void) {
        switch haptic {
        case .soft:    Haptics.soft()
        case .confirm: Haptics.tapConfirm()
        // R3 — UINotificationFeedbackGenerator(.warning) for destructive
        // commits (delete / discard). Distinct from the lighter `.confirm`
        // tick used for benign saves like share / pin.
        case .warn:    Haptics.warningNotification()
        }
        snapClose()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: action)
    }

    // MARK: - Pan callbacks
    //
    // The UIKit recognizer handles direction-lock and slop before these
    // fire; by the time onChanged runs, the touch is already confirmed
    // horizontal and we can apply translation 1:1.

    private func handlePanChanged(_ translation: CGFloat) {
        dragDelta = translation
        updateThresholdHaptics()
    }

    private func handlePanEnded(_ translation: CGFloat, _ velocity: CGFloat) {
        dragDelta = 0
        decideSnap(dx: translation, velocity: velocity)
        armedSide = nil
        fullyRevealedSide = nil
    }

    private func handlePanCancelled() {
        // Snap back to the prior resting state without touching settledOffset.
        dragDelta = 0
        armedSide = nil
        fullyRevealedSide = nil
    }

    /// Fires a soft tick the first time a drag crosses the open threshold
    /// in each direction. Subsequent frames inside the same band don't
    /// re-trigger. Mirrors the Apple Notes "armed" feedback that tells the
    /// user "release now and the action will fire."
    private func updateThresholdHaptics() {
        let offset = currentOffset
        let armingSide: Side?
        if offset > SwipePhysics.openThreshold {
            armingSide = .leading
        } else if offset < -SwipePhysics.openThreshold {
            armingSide = .trailing
        } else {
            armingSide = nil
        }
        if armingSide != armedSide {
            armedSide = armingSide
            if armingSide != nil { Haptics.soft() }
        }

        // R3 — second tick at the *full* panelWidth so the user feels a
        // confirmable "drawer fully out" cue distinct from the early
        // armed-at-threshold tick. UIImpactFeedbackGenerator(.light) via
        // Haptics.light() keeps the impact crisp without being shouty.
        let fullSide: Side?
        if offset >= SwipePhysics.panelWidth {
            fullSide = .leading
        } else if offset <= -SwipePhysics.panelWidth {
            fullSide = .trailing
        } else {
            fullSide = nil
        }
        if fullSide != fullyRevealedSide {
            fullyRevealedSide = fullSide
            if fullSide != nil { Haptics.light() }
        }
    }

    // MARK: - Snap Logic
    //
    // dx is always relative to the drag start position (not screen zero).
    // When trailing panel is open (settledOffset = -panelW), a rightward drag
    // produces dx > 0, which correctly triggers snapClose via the first branch.
    // No coordinate transform needed — this is the fix for the "can't close" bug.

    private func decideSnap(dx: CGFloat, velocity: CGFloat) {
        let openT = SwipePhysics.openThreshold
        let closeT = SwipePhysics.closeThreshold
        let vOpen = SwipePhysics.velocityOpen
        let vClose = SwipePhysics.velocityClose
        switch revealedSide {
        case nil:
            if      dx < -openT || velocity < -vOpen  { snapOpen(.trailing) }
            else if dx >  openT || velocity >  vOpen  { snapOpen(.leading)  }
            else                                       { snapClose()         }
        case .trailing:
            (dx > closeT || velocity > vClose) ? snapClose() : snapOpen(.trailing)
        case .leading:
            (dx < -closeT || velocity < -vClose) ? snapClose() : snapOpen(.leading)
        }
    }

    private func snapOpen(_ side: Side) {
        let target: CGFloat = side == .trailing ? -SwipePhysics.panelWidth : SwipePhysics.panelWidth
        withAnimation(snapAnimation) { settledOffset = target }
        HapticFeedback.light()
    }

    func snapClose() {
        withAnimation(snapAnimation) { settledOffset = 0 }
    }
}

// MARK: - SwipeAction

/// One revealable action inside a swipe drawer. `id` only drives the a11y
/// label and SF-symbol fallback; `run` carries the close-then-fire behavior.
struct SwipeAction: Identifiable {
    enum Kind { case share, delete, pin, more }
    enum Tone { case accent, destructive, neutral }

    let id: Kind
    let label: String
    let systemImage: String
    let tone: Tone
    let run: () -> Void
}

// MARK: - SwipeActionPanel
//
// Visual surface for one side of the swipe drawer. Lays out N action buttons
// side by side, each `SwipePhysics.actionWidth` wide, clipped to the card's
// outer corner radius by the ZStack's `.clipped()` so the drawer reads as a
// nested glass surface waking up rather than abutting bright rectangles.
//
// Choreography (driven by `progress`, 0…1+):
//   0.00 – 0.30   Icon at 0.6× scale, label hidden, soft tone.
//   0.30 – 1.00   Icon grows to 1.0×, label fades in, tone deepens.
//
// Each button is a full-height tap target so a revealed action is easy to
// hit. Buttons are ordered outer-edge-first so the most prominent action
// (share / pin) sits nearest the screen edge the finger travels toward.
private struct SwipeActionPanel: View {

    enum Edge { case leading, trailing }

    let actions: [SwipeAction]
    let edge: Edge
    let progress: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            // R3 — interleave a 1pt hairline between adjacent action columns
            // so the share/delete (or pin/more) boundary reads as two distinct
            // tap targets rather than a single colored slab. `inkFaint` is the
            // same low-opacity ink token used by other DS rules and keeps the
            // divider readable in both schemes.
            ForEach(Array(orderedActions.enumerated()), id: \.element.id) { index, action in
                if index > 0 {
                    Rectangle()
                        .fill(DSColor.inkFaint)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .opacity(progress > 0.02 ? 1 : 0)
                        .allowsHitTesting(false)
                }
                SwipeActionButton(action: action, progress: progress)
            }
        }
        .frame(width: SwipePhysics.panelWidth)
        .frame(maxHeight: .infinity)
        // Hide entirely when closed so VoiceOver doesn't announce hidden
        // targets and a stray tap on the laid-out panel can't fire.
        .opacity(progress > 0.02 ? 1 : 0)
        .allowsHitTesting(progress > 0.02)
        .accessibilityHidden(progress <= 0.02)
    }

    /// Leading panel grows from the left edge, so its primary action should be
    /// outermost (left). Trailing panel grows from the right edge, primary
    /// outermost (right). We keep the caller's array primary-first and only
    /// reverse for the trailing side so layout matches travel direction.
    private var orderedActions: [SwipeAction] {
        edge == .trailing ? actions.reversed() : actions
    }
}

// MARK: - SwipeActionButton

/// A single action column inside a panel. Frosted glass base + tone tint that
/// deepens with reveal progress; icon scales up and label fades in past 0.30.
private struct SwipeActionButton: View {

    let action: SwipeAction
    let progress: CGFloat

    private let labelFadeStart: CGFloat = 0.30
    private let iconScaleMin: CGFloat = 0.6
    private let iconScaleMax: CGFloat = 1.0

    var body: some View {
        Button(action: action.run) {
            ZStack {
                background
                content
            }
            .frame(width: SwipePhysics.actionWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.label)
    }

    private var background: some View {
        // Neutral tones keep a higher tint floor so their pale surface stays
        // legible; accent / destructive start lower and deepen as revealed.
        let floor: CGFloat = (action.tone == .neutral ? 0.78 : 0.42)
        let tint = Double(floor + (1 - floor) * min(1, progress))
        return ZStack {
            Rectangle().fill(.ultraThinMaterial)
            baseColor.opacity(tint)
        }
    }

    private var content: some View {
        VStack(spacing: 6) {
            Image(systemName: action.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(foreground)
                .scaleEffect(iconScale)

            Text(action.label)
                .font(.custom("Inter-Medium", size: 10.5))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundColor(foreground)
                .opacity(labelOpacity)
        }
        .padding(.horizontal, 4)
    }

    private var baseColor: Color {
        switch action.tone {
        // R3 — SHARE switches from the darker `accentAmber` (#5D3000) to
        // the brighter primary `amberAccent` (#A8541B) so the action
        // surface reads as warm-amber-active rather than near-black. This
        // is the warm-cream "primary action" amber the rest of the v4
        // language uses for active state.
        case .accent:      return DSColor.amberAccent
        // R3 — DELETE uses the existing semantic `errorRed` (#A23A2E) —
        // already the spec'd destructive token, no new color needed.
        case .destructive: return DSColor.errorRed
        case .neutral:     return DSColor.surfaceSunken
        }
    }

    private var foreground: Color {
        switch action.tone {
        // R3 — both saturated tones use `onRecording` (near-white in both
        // schemes, the same token the recording overlay uses on its dark
        // amber substrate) instead of raw `Color.white`. Keeps amber +
        // red surfaces token-driven and dark-mode-correct.
        case .accent, .destructive: return DSColor.onRecording
        case .neutral:              return DSColor.inkPrimary
        }
    }

    private var iconScale: CGFloat {
        let clamped = max(0, min(1, progress))
        return iconScaleMin + (iconScaleMax - iconScaleMin) * clamped
    }

    private var labelOpacity: Double {
        let clamped = max(0, min(1, (progress - labelFadeStart) / (1 - labelFadeStart)))
        return Double(clamped)
    }
}
