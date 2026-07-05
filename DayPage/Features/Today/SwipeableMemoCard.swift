import SwiftUI
import DayPageModels
import DayPageServices

// MARK: - SwipePhysics
//
// All numeric constants for the swipe-to-reveal interaction live here so the
// motion language is auditable in one place and easy to tune. Names are
// chosen to map to the four-stage gesture vocabulary:
//
//   peek      — finger moves but the action is not yet committable.
//   reveal    — the user has crossed the open threshold; icon + label sit on
//                a settled panel; releasing snaps the panel open.
//   overdrag  — drag continues past the panel with light damping; the drawer
//                keeps hugging the card edge on its way to the commit line.
//   commit    — past commitThreshold the outermost action expands to fill
//                the drawer; releasing executes it directly (Mail-style).
//
// Tuned against Apple Mail / Notes / Reminders for snappy attack and minimal
// overshoot, while keeping the panel surface visually quiet at small offsets.
//
// Internal (not fileprivate) so SwipeSnapLogic below and the
// SwipePolishContractTests suite can assert against the real tokens
// instead of re-hardcoding literals.
enum SwipePhysics {

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

    /// Damping applied to drag travel past the panel edge. Unlike the old
    /// 0.25 rubber wall, 0.85 keeps the card following the finger — the
    /// overdrag is now a doorway to the full-swipe commit, not a dead end.
    /// Mail tracks 1:1 here; a light 15% drag keeps some tactile weight.
    static let overdragDamping: CGFloat = 0.85

    /// Visual offset past which releasing the finger commits the OUTERMOST
    /// action directly (trailing → share, leading → pin), Mail-style.
    /// 236pt ≈ 65% of the 362pt card, requiring ~250pt of finger travel
    /// through the damped zone — a deliberate, uncancellable-feeling pull
    /// that is still comfortably reachable one-handed.
    static let commitThreshold: CGFloat = 236

    /// Corner radius of MemoCardView's `.solidCard(cornerRadius: 14)`
    /// surface. The drawer container clips to the same continuous shape so
    /// revealed action panels share the card's silhouette instead of
    /// poking square corners out of a rounded card.
    static let cardCornerRadius: CGFloat = 14

    /// Spring used for snap-open / snap-close. Delegated to the shared
    /// `Motion.panel` token (0.32s response, 0.85 damping) so drawer motion
    /// stays consistent with the recording panel, popovers, and other card
    /// surfaces. Previously duplicated inline as spring(0.28, 0.86) — the
    /// 40ms delta was audible against the rest of the app.
    static let snapSpring: Animation = Motion.panel

    /// Eased curve used in place of `snapSpring` when Reduce Motion is on.
    /// Reuses `Motion.dismiss` (0.22s easeOut) so all fallbacks share one curve.
    static let reducedSnap: Animation = Motion.dismiss

    /// Delay before the parent's action callback fires after `snapClose()`.
    /// Matches the resolved response of `snapSpring` (+ a small settle
    /// margin) so any presented sheet / dialog animates in only after the
    /// drawer is visually flush. Previously hardcoded 0.25s which was 30ms
    /// short of the panel response.
    static let actionCommitDelay: TimeInterval = 0.36
}

// MARK: - CardSwipeSide / SwipeSnapLogic

/// Which drawer a swipe reveals. Internal so the pure snap-resolution logic
/// (and its tests) can speak the same vocabulary as the view.
enum CardSwipeSide: Equatable {
    case leading, trailing
}

/// Pure release-decision for the swipe gesture, extracted from the view so
/// the whole state machine is unit-testable without touch synthesis.
///
/// Inputs are the values available at finger-lift; the output says where the
/// card should settle — including the Mail-style full-swipe commit that
/// executes the outermost action when the drag "冲高" past commitThreshold.
enum SwipeSnapLogic {

    enum Resolution: Equatable {
        case open(CardSwipeSide)
        case close
        /// Execute the OUTERMOST action of the given side immediately
        /// (trailing → share, leading → pin). Fired only from a full swipe.
        case commitOuter(CardSwipeSide)
    }

    /// - Parameters:
    ///   - revealed: the side that was settled open when the drag began.
    ///   - visualOffset: damped on-screen offset at release (currentOffset).
    ///   - dx: raw drag translation relative to the drag start.
    ///   - velocity: horizontal velocity in pt/s at release.
    static func resolve(
        revealed: CardSwipeSide?,
        visualOffset: CGFloat,
        dx: CGFloat,
        velocity: CGFloat
    ) -> Resolution {
        // Full-swipe commit wins over every other rule: once the card has
        // been pulled past the commit line the release means "do it now".
        // Deliberately translation-only — a flick's velocity alone must
        // never commit an action the finger didn't travel for.
        if visualOffset <= -SwipePhysics.commitThreshold { return .commitOuter(.trailing) }
        if visualOffset >= SwipePhysics.commitThreshold { return .commitOuter(.leading) }

        let openT = SwipePhysics.openThreshold
        let closeT = SwipePhysics.closeThreshold
        let vOpen = SwipePhysics.velocityOpen
        let vClose = SwipePhysics.velocityClose
        switch revealed {
        case nil:
            if      dx < -openT || velocity < -vOpen { return .open(.trailing) }
            else if dx >  openT || velocity >  vOpen { return .open(.leading)  }
            else                                     { return .close           }
        case .trailing:
            return (dx > closeT || velocity > vClose) ? .close : .open(.trailing)
        case .leading:
            return (dx < -closeT || velocity < -vClose) ? .close : .open(.leading)
        }
    }
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
//  - Past ±panelW the drag keeps following with light damping toward the
//    full-swipe commit line (see SwipePhysics.commitThreshold).
//  - Velocity-aware snap: a flick opens/closes even with small translation —
//    but only real finger travel (never velocity) can trigger a commit.
//  - Threshold-cross haptic ticks escalate during the drag: soft (armed) →
//    light (fully revealed) → rigid (commit armed), Apple Notes-style.
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

    // Touch-down press feedback (UITableViewCell-highlight semantics): the
    // card settles to 0.985× while the finger rests on it and springs back
    // on lift — or the instant the scroll / swipe / context-menu takes the
    // touch. Suppressed under Reduce Motion.
    @State private var isPressed: Bool = false

    // Tracks which threshold the live drag has already crossed so the
    // mid-drag haptic tick fires once per cross, not once per frame.
    @State private var armedSide: CardSwipeSide? = nil

    // R3 — fires a stronger "fully revealed" light-impact tick the first
    // time the user pulls the panel all the way open (≥ panelWidth) within
    // a single drag. Distinct from the early `armedSide` tick (which fires
    // at openThreshold to signal "release-to-arm"). Resets when the drag
    // ends or the drag direction flips.
    @State private var fullyRevealedSide: CardSwipeSide? = nil

    // Full-swipe commit arming: non-nil once the live drag has pulled the
    // card past SwipePhysics.commitThreshold. Drives the outermost button's
    // expand-to-fill choreography and the rigid "about to execute" haptic.
    @State private var commitArmedSide: CardSwipeSide? = nil

    // One drawer at a time: set after this card announces its own drag via
    // .memoCardDidBeginSwipe so peers can close, reset on lift/cancel.
    @State private var didNotifyPeers: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var revealedSide: CardSwipeSide? {
        if settledOffset < -1 { return .trailing }
        if settledOffset > 1  { return .leading }
        return nil
    }

    // Sign contract (relied on by revealProgress AND the per-side
    // revealWidth passed to each SwipeActionPanel): POSITIVE offset =
    // leading (right-swipe) reveal, NEGATIVE = trailing (left-swipe).
    private var currentOffset: CGFloat {
        let raw = settledOffset + dragDelta
        let w = SwipePhysics.panelWidth
        if raw > w  { return w  + (raw - w)  * SwipePhysics.overdragDamping }
        if raw < -w { return -w + (raw + w)  * SwipePhysics.overdragDamping }
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

    var body: some View {
        ZStack(alignment: .center) {
            // LAYER 1 (bottom): the card body — pure presentation. Navigation
            // and panel-close are driven by the tap recognizer inside
            // HorizontalPanGesture (onTap), not a SwiftUI NavigationLink,
            // because the pan host view hit-tests to self.
            MemoCardView(memo: memo, onDelete: onDelete)
                .contentShape(Rectangle())
                .scaleEffect(isPressed && !reduceMotion ? 0.985 : 1.0)
                .animation(reduceMotion ? nil : Motion.spring, value: isPressed)
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
                        onPressChanged: { pressed in
                            // A confirmed swipe owns the touch — never show
                            // the pressed dip while the drawer is moving.
                            isPressed = pressed && !isPanActive
                        },
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
                    progress: max(0, revealProgress),
                    revealWidth: max(SwipePhysics.panelWidth, currentOffset),
                    commitArmed: commitArmedSide == .leading
                )
                Spacer(minLength: 0)
                SwipeActionPanel(
                    actions: trailingActions,
                    edge: .trailing,
                    progress: max(0, -revealProgress),
                    revealWidth: max(SwipePhysics.panelWidth, -currentOffset),
                    commitArmed: commitArmedSide == .trailing
                )
            }
            .allowsHitTesting(revealedSide != nil && !isSelectionMode)
        }
        // Same continuous corner as MemoCardView's solidCard surface, so a
        // revealed drawer inherits the card's silhouette (the old .clipped()
        // let the panels poke square corners out of a 14pt-rounded card).
        .clipShape(RoundedRectangle(cornerRadius: SwipePhysics.cardCornerRadius, style: .continuous))
        // R3→2026-07-04: the long-press contextMenu moved UP to TimelineRow.
        // Two nested contextMenus (this one + TimelineRow's share/select
        // menu) meant the inner one shadowed the outer — TimelineRow now
        // owns the single merged menu (share / pin / select / delete) with
        // a card preview. VoiceOver users keep every action via the
        // accessibilityActions below.
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
            if newValue {
                // Also disarm any in-flight commit layout: entering selection
                // mode during the brief post-commit settle window must never
                // leave the expanded single-button drawer frozen on screen.
                commitArmedSide = nil
                if revealedSide != nil {
                    snapClose()
                }
            }
        }
        // Mail semantics: starting a swipe on any card closes every other
        // card's drawer, so at most one drawer is ever open on screen.
        .onReceive(NotificationCenter.default.publisher(for: .memoCardDidBeginSwipe)) { note in
            guard let other = note.object as? UUID, other != memo.id else { return }
            if revealedSide != nil { snapClose() }
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
            run: { runAction { onPin?() } },
            // R4 a11y — actor + object named for VoiceOver.
            a11yLabel: memo.pinnedAt != nil ? "取消置顶 memo" : "置顶 memo"
        ))
        items.append(SwipeAction(
            id: .more,
            label: NSLocalizedString("memo.swipe.more", comment: "Swipe action: more options"),
            systemImage: "ellipsis",
            tone: .neutral,
            run: { runAction(haptic: .soft) { onMore?() } },
            a11yLabel: "更多操作"
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
                run: { runAction(haptic: .confirm) { onShare?() } },
                a11yLabel: "分享 memo"
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
                run: { runAction(haptic: .warn) { onDelete?() } },
                // R4 — VoiceOver hint warns that delete is irreversible.
                a11yLabel: "删除 memo",
                a11yHint: "将永久移除该条记录"
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
        DispatchQueue.main.asyncAfter(deadline: .now() + SwipePhysics.actionCommitDelay, execute: action)
    }

    // MARK: - Pan callbacks
    //
    // The UIKit recognizer handles direction-lock and slop before these
    // fire; by the time onChanged runs, the touch is already confirmed
    // horizontal and we can apply translation 1:1.

    private func handlePanChanged(_ translation: CGFloat) {
        if !didNotifyPeers {
            didNotifyPeers = true
            NotificationCenter.default.post(name: .memoCardDidBeginSwipe, object: memo.id)
        }
        // The swipe owns the touch now — release the press dip so the card
        // doesn't ride the drawer at 0.985×.
        if isPressed { isPressed = false }
        dragDelta = translation
        updateThresholdHaptics()
    }

    private func handlePanEnded(_ translation: CGFloat, _ velocity: CGFloat) {
        // Resolve on the pre-release visual offset — dragDelta must still be
        // live here so the full-swipe commit sees how far the card really was.
        let visualOffset = currentOffset
        let resolution = SwipeSnapLogic.resolve(
            revealed: revealedSide,
            visualOffset: visualOffset,
            dx: translation,
            velocity: velocity
        )
        armedSide = nil
        fullyRevealedSide = nil
        didNotifyPeers = false

        switch resolution {
        case .open(let side):
            dragDelta = 0
            commitArmedSide = nil
            snapOpen(side)
        case .close:
            dragDelta = 0
            commitArmedSide = nil
            snapClose()
        case .commitOuter(let side):
            // Hand the live drag offset to settledOffset before zeroing the
            // delta — same composed value, so no visual jump — then run the
            // OUTERMOST action (trailing → share, leading → pin). run()
            // already carries the haptic + animated close + settle delay.
            settledOffset = visualOffset
            dragDelta = 0
            let outer = (side == .trailing ? trailingActions : leadingActions).first
            outer?.run()
            // Keep the expanded single-button layout through the close
            // animation so the drawer doesn't pop back to two columns
            // mid-flight; clear once the panel is visually flush.
            DispatchQueue.main.asyncAfter(deadline: .now() + SwipePhysics.actionCommitDelay) {
                commitArmedSide = nil
            }
        }
    }

    private func handlePanCancelled() {
        // Snap back to the prior resting state without touching settledOffset.
        dragDelta = 0
        armedSide = nil
        fullyRevealedSide = nil
        didNotifyPeers = false
        commitArmedSide = nil
    }

    /// Fires a soft tick the first time a drag crosses the open threshold
    /// in each direction. Subsequent frames inside the same band don't
    /// re-trigger. Mirrors the Apple Notes "armed" feedback that tells the
    /// user "release now and the action will fire."
    private func updateThresholdHaptics() {
        let offset = currentOffset
        let armingSide: CardSwipeSide?
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
        let fullSide: CardSwipeSide?
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

        // Full-swipe commit arming — the third and strongest tick. Crossing
        // commitThreshold expands the outermost button to fill the drawer
        // (release now = execute); sliding back under it collapses the
        // layout with a light disarm tick, exactly like Mail's arm/disarm.
        let commitSide: CardSwipeSide?
        if offset >= SwipePhysics.commitThreshold {
            commitSide = .leading
        } else if offset <= -SwipePhysics.commitThreshold {
            commitSide = .trailing
        } else {
            commitSide = nil
        }
        if commitSide != commitArmedSide {
            let animation: Animation? = reduceMotion ? nil : SwipePhysics.snapSpring
            withAnimation(animation) { commitArmedSide = commitSide }
            if commitSide != nil {
                Haptics.rigid(intensity: 0.8)
            } else {
                Haptics.light()
            }
        }
    }

    // MARK: - Snap Logic
    //
    // Release resolution lives in SwipeSnapLogic (pure, unit-tested);
    // these two just animate the card to the resolved resting position.

    private func snapOpen(_ side: CardSwipeSide) {
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

    // R4 — richer a11y. `label` is the visible swipe-button text (kept short
    // so it fits the 56pt button). Callers may supply an additional
    // VoiceOver-only label/hint that names the actor and the consequence.
    var a11yLabel: String? = nil
    var a11yHint: String? = nil
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
    /// Live drawer width. Tracks the (damped) finger past panelWidth so the
    /// panel's inner edge always hugs the card edge during an overdrag —
    /// with the old fixed width a full swipe opened a bare gap between them.
    var revealWidth: CGFloat = SwipePhysics.panelWidth
    /// Full-swipe commit armed: the outermost (primary) action expands to
    /// fill the whole drawer and the secondary column folds away, signalling
    /// "release to execute", mirroring Mail's full-swipe choreography.
    var commitArmed: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // R3 — interleave a 1pt hairline between adjacent action columns
            // so the share/delete (or pin/more) boundary reads as two distinct
            // tap targets rather than a single colored slab. `inkFaint` is the
            // same low-opacity ink token used by other DS rules and keeps the
            // divider readable in both schemes. Folded away while the commit
            // layout has a single full-width button.
            ForEach(Array(orderedActions.enumerated()), id: \.element.id) { index, action in
                if index > 0 && !commitArmed {
                    Rectangle()
                        .fill(DSColor.inkFaint)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .opacity(progress > 0.02 ? 1 : 0)
                        .allowsHitTesting(false)
                }
                if !commitArmed || action.id == outerActionID {
                    SwipeActionButton(
                        action: action,
                        progress: progress,
                        fillsWidth: commitArmed && action.id == outerActionID
                    )
                }
            }
        }
        .frame(width: max(SwipePhysics.panelWidth, revealWidth))
        .frame(maxHeight: .infinity)
        // Hide entirely when closed so VoiceOver doesn't announce hidden
        // targets and a stray tap on the laid-out panel can't fire.
        .opacity(progress > 0.02 ? 1 : 0)
        .allowsHitTesting(progress > 0.02)
        .accessibilityHidden(progress <= 0.02)
    }

    /// The primary action — callers pass their arrays primary-first, and the
    /// primary always sits at the drawer's outer (screen-edge) side.
    private var outerActionID: SwipeAction.Kind? { actions.first?.id }

    /// Leading panel grows from the left edge, so its primary action should be
    /// outermost (left). Trailing panel grows from the right edge, primary
    /// outermost (right). We keep the caller's array primary-first and only
    /// reverse for the trailing side so layout matches travel direction.
    private var orderedActions: [SwipeAction] {
        edge == .trailing ? actions.reversed() : actions
    }
}

// MARK: - SwipeActionButton

/// A single action column inside a panel. On iOS 26 the base is native
/// Liquid Glass (tinted with the action's semantic tone, deepening as the
/// reveal progresses — the warm ambient canvas refracts through it); on
/// iOS 16–25 it keeps the ultraThinMaterial + tone-tint recipe. Icon scales
/// up and label fades in past 0.30 of the reveal.
private struct SwipeActionButton: View {

    let action: SwipeAction
    let progress: CGFloat
    /// True while this button is the commit-armed primary: it stretches to
    /// fill the whole drawer instead of its fixed 76pt column.
    var fillsWidth: Bool = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let labelFadeStart: CGFloat = 0.30
    private let iconScaleMin: CGFloat = 0.6
    private let iconScaleMax: CGFloat = 1.0

    var body: some View {
        Button(action: action.run) {
            ZStack {
                background
                content
            }
            .frame(width: fillsWidth ? nil : SwipePhysics.actionWidth)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.a11yLabel ?? action.label)
        .accessibilityHint(action.a11yHint ?? "")
    }

    @ViewBuilder
    private var background: some View {
        // Neutral tones keep a higher tint floor so their pale surface stays
        // legible; accent / destructive start lower and deepen as revealed.
        let floor: CGFloat = (action.tone == .neutral ? 0.78 : 0.42)
        let tint = Double(floor + (1 - floor) * min(1, progress))
        if reduceTransparency {
            // Accessibility: opaque tone surface, no blur or refraction.
            baseColor.opacity(max(tint, 0.96))
        } else if #available(iOS 26.0, *) {
            // Native Liquid Glass tinted with the deepening semantic tone.
            // `.interactive()` adds the press-softening squish on touch.
            Color.clear.glassEffect(
                .regular.tint(baseColor.opacity(tint)).interactive(),
                in: .rect
            )
        } else {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                baseColor.opacity(tint)
            }
        }
    }

    private var content: some View {
        VStack(spacing: 6) {
            Image(systemName: action.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(foreground)
                .scaleEffect(iconScale)
                // Mail-style "release to execute" cue: the symbol bounces
                // the moment the full-swipe commit arms (and re-bounces if
                // the user slides back under the line and re-arms).
                .modifier(CommitArmBounce(armed: fillsWidth))

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

// MARK: - CommitArmBounce

/// One-shot symbol bounce when the full-swipe commit arms / re-arms.
/// iOS 17+ only (`symbolEffect`); inert on iOS 16 and under Reduce Motion.
private struct CommitArmBounce: ViewModifier {
    let armed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *), !reduceMotion {
            content.symbolEffect(.bounce, options: .speed(1.3), value: armed)
        } else {
            content
        }
    }
}

// MARK: - Notification.Name

extension Notification.Name {
    /// Posted (object: Memo.id as UUID) the moment a card's horizontal pan
    /// starts moving. Every other SwipeableMemoCard closes its drawer on
    /// receipt, so at most one drawer is open at a time (Mail semantics).
    static let memoCardDidBeginSwipe = Notification.Name("memoCardDidBeginSwipe")
}
