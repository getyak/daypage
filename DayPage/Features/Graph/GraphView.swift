import SwiftUI
import UIKit
import DayPageServices
import DayPageStorage

// MARK: - GraphView

struct GraphView: View {

    @EnvironmentObject private var nav: AppNavigationModel
    @StateObject private var viewModel = GraphViewModel()

    // Zoom & pan state
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero

    // Simulation tick — CADisplayLink-backed, synced to screen refresh and
    // pinned to 30fps; honors Low Power Mode. See GraphDisplayLinkController.
    @StateObject private var displayLink = GraphDisplayLinkController()
    @State private var simulationSize: CGSize = .zero
    @State private var simulationSteps: Int = 0

    // Navigation state
    @State private var selectedNode: GraphNode? = nil
    @State private var showEntityPage: Bool = false

    // Tap pulse state — ID-based so the ring tracks the live simulation position
    @State private var tapPulseNodeID: String? = nil
    @State private var tapPulseProgress: CGFloat = 0   // 0 → 1 drives both scale and opacity
    @State private var tapPulseGeneration: Int = 0     // cancels stale clear tasks on rapid taps

    // Filter state
    @State private var showFilters: Bool = false

// Search auto-center state
    @State private var lastCenteredMatchID: String? = nil
    @State private var searchMatchIndex: Int = 0

    // Auto-fit state — fires once when simulation settles; re-arms on node-set change
    @State private var didAutoFit: Bool = false

    // Accessibility-layer position snapshot (model space, node.id → position).
    // Captured when the simulation starts (initial layout) and settles/stops,
    // so the VoiceOver element ForEach never re-lays-out per simulation frame.
    @State private var a11yPositions: [String: CGPoint] = [:]

    // Zero-match haptic guard — fires warn() exactly once per zero-crossing
    @State private var lastZeroQuery: String? = nil

    // Wrap-around flash state for the match-count pill
    @State private var matchPillFlash: Bool = false

    // Zero-match glass toast — fades out after 3s; cancelled when query changes.
    @State private var showZeroMatchToast: Bool = false
    @State private var zeroMatchToastQuery: String = ""
    @State private var zeroMatchToastGen: Int = 0

    // Network-size milestone tracking — fires soft haptic + VoiceOver every 10 nodes
    @State private var lastNetworkMilestone: Int = 0

    // Legend type-visibility filter — persisted across tab switches and relaunches
    @AppStorage(AppSettings.Keys.graphHiddenTypes) private var hiddenTypesRaw: String = ""

    private var hiddenTypes: Set<String> {
        get {
            let parts = hiddenTypesRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            return Set(parts)
        }
        // nonmutating: only writes to the @AppStorage-backed `hiddenTypesRaw`,
        // never mutates `self`, so it can be assigned from escaping SwiftUI closures.
        nonmutating set {
            hiddenTypesRaw = newValue.sorted().joined(separator: ",")
        }
    }

    // Empty state animation + ClearFiltersPressStyle (do not remove this @Environment:
    // both `emptyState` and `clearFiltersButton` read `reduceMotion`; deleting it
    // breaks the build — see incident around PR #466).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private let maxSimSteps = 200

    @State private var currentTime: Date = Date()
    private let headerTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Header bar — Liquid Glass strip on the warm canvas
            VStack(spacing: 0) {
                // Persistent top row — sidebar entry + serif page title. Kept
                // OUTSIDE the node-count gate below: the empty state used to
                // hide the entire header, leaving no visible way back to the
                // sidebar (edge-swipe was the only exit).
                HStack(spacing: 12) {
                    Button {
                        Haptics.soft()
                        nav.openSidebar()
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(DSType.bodySM)
                            .foregroundColor(DSColor.inkMuted)
                            .frame(width: 36, height: 36)
                            .glassSurface(in: Circle())
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("a11y.nav.open", comment: "Sidebar open button"))
                    .accessibilityHint(NSLocalizedString("a11y.nav.open.hint", comment: "Opens the sidebar navigation drawer"))
                    .accessibilityIdentifier("graph-sidebar-menu-button")

                    Text(NSLocalizedString("sidebar.nav.graph", comment: "Graph page title"))
                        .font(DSFonts.serif(size: 20, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundColor(DSColor.inkPrimary)

                    Spacer()
                }
                .padding(.horizontal, DSSpacing.lg)
                .padding(.top, DSSpacing.sm)
                .padding(.bottom, 2)

                if !viewModel.nodes.isEmpty {
                HStack(spacing: DSSpacing.sm) {
                    // Search field — glass-tinted capsule
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundColor(DSColor.inkMuted)
                        TextField(NSLocalizedString("graph.search.placeholder", comment: "Graph search field placeholder"), text: $viewModel.searchInput)
                            .font(DSFonts.jetBrainsMono(size: 12))
                            .foregroundColor(DSColor.inkPrimary)
                            .submitLabel(.search)
                            .onSubmit {
                                let matches = searchMatches
                                guard !matches.isEmpty else {
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                    return
                                }
                                if matches.count > 1 {
                                    searchMatchIndex = (searchMatchIndex + 1) % matches.count
                                    let node = matches[searchMatchIndex]
                                    centerOn(node, in: simulationSize)
                                    pulseNode(node)
                                    announceSearchMatch(node, index: searchMatchIndex, total: matches.count)
                                    Haptics.soft()
                                } else {
                                    centerOn(matches[0], in: simulationSize)
                                    pulseNode(matches[0])
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                }
                            }
                        if !viewModel.searchInput.isEmpty {
                            Button {
                                Haptics.soft()
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                                    viewModel.searchInput = ""
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(DSColor.inkMuted)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(NSLocalizedString("graph.search.clear.a11y", comment: "VoiceOver label for the Clear search button in the graph"))
                            .transition(.opacity)
                        }
                    }
                    .animation(Motion.fade, value: viewModel.searchInput.isEmpty)
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.vertical, 7)
                    // #771: search field → glass engine (.control). Engine owns rim.
                    .dpGlass(.control, in: RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))

                    // Filter toggle — amber when active
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut) { showFilters.toggle() }
                    } label: {
                        Image(systemName: showFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .font(.system(size: 20))
                            .foregroundColor(hasActiveFilter ? DSColor.amberAccent : DSColor.inkMuted)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(showFilters ? "Hide filters" : "Show filters")
                }
                .padding(.horizontal, DSSpacing.lg)
                .padding(.vertical, DSSpacing.sm)

                if !viewModel.nodes.isEmpty && !hasActiveFilter {
                    networkSizePill
                        .padding(.horizontal, DSSpacing.lg)
                        .padding(.bottom, DSSpacing.sm)
                        .transition(.opacity)
                }

                if !viewModel.searchQuery.isEmpty {
                    HStack(spacing: DSSpacing.xs) {
                        let matches = searchMatches
                        let count = matches.count
                        let isZero = count == 0

                        if isZero {
                            HStack(spacing: 5) {
                                Image(systemName: "magnifyingglass.slash")
                                    .font(.system(size: 11))
                                    .foregroundColor(DSColor.inkMuted)
                                Text(NSLocalizedString("graph.search.zero_match", comment: "Graph search zero-match pill"))
                                    .font(DSFonts.jetBrainsMono(size: 11))
                                    .foregroundColor(DSColor.inkMuted)
                            }
                            .padding(.horizontal, DSSpacing.md)
                            .padding(.vertical, 5)
                            // #771: zero-match hint → glass engine (.toast),
                            // keeping the amber emphasis rim on top.
                            .dpGlass(.toast, in: Capsule())
                            .overlay(Capsule().strokeBorder(DSColor.amberAccent.opacity(0.5), lineWidth: 0.5))
                            .accessibilityLabel(NSLocalizedString("graph.search.zero_match", comment: ""))
                        } else {
                            let pillText = count > 1
                                ? String(format: NSLocalizedString("graph.search.match_count.other", comment: "Graph search match count pill, multiple"), searchMatchIndex + 1, count)
                                : String(format: NSLocalizedString("graph.search.match_count.one", comment: "Graph search match count pill, single"), count)
                            Text(pillText)
                                .font(DSFonts.jetBrainsMono(size: 11))
                                .foregroundColor(DSColor.inkMuted)
                                .padding(.horizontal, DSSpacing.md)
                                .padding(.vertical, 5)
                                // #771: match-count badge → glass engine (.pill),
                                // keeping the amber flash overlays on top.
                                .dpGlass(.pill, in: Capsule())
                                .overlay(
                                    Capsule()
                                        .strokeBorder(DSColor.amberAccent, lineWidth: 1.5)
                                        .opacity(matchPillFlash ? 1 : 0)
                                        .animation(Motion.fade, value: matchPillFlash)
                                )
                                .overlay(
                                    Capsule()
                                        .fill(DSColor.amberAccent.opacity(0.15))
                                        .opacity(matchPillFlash ? 1 : 0)
                                        .animation(Motion.fade, value: matchPillFlash)
                                )
                                .accessibilityLabel(String(format: NSLocalizedString("graph.search.match_count.a11y", comment: "Graph search match count accessibility label"), count))
                            if count > 1 {
                                Button {
                                    advanceMatch(by: -1, matches: matches, in: simulationSize)
                                } label: {
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(DSColor.inkMuted)
                                        .frame(width: 28, height: 28)
                                        // #771: match nav button → glass engine (.control).
                                        .dpGlass(.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel(NSLocalizedString("graph.a11y.prev_match", comment: "Graph previous match button"))
                                Button {
                                    advanceMatch(by: +1, matches: matches, in: simulationSize)
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(DSColor.inkMuted)
                                        .frame(width: 28, height: 28)
                                        // #771: match nav button → glass engine (.control).
                                        .dpGlass(.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel(NSLocalizedString("graph.a11y.next_match", comment: "Graph next match button"))
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.bottom, DSSpacing.sm)
                    .transition(.opacity)
                    .animation(Motion.fade, value: viewModel.searchMatchCount)
                    .onChange(of: viewModel.searchMatchCount) { count in
                        let query = viewModel.searchQuery
                        guard !query.isEmpty else {
                            lastZeroQuery = nil
                            dismissZeroMatchToast()
                            return
                        }
                        if count == 0 && lastZeroQuery != query {
                            lastZeroQuery = query
                            Haptics.warn()
                            presentZeroMatchToast(for: query)
                            if UIAccessibility.isVoiceOverRunning {
                                let msg = NSLocalizedString("graph.search.zero_match", comment: "Graph search zero-match VoiceOver announcement")
                                UIAccessibility.post(notification: .announcement, argument: msg)
                            }
                        } else if count > 0 {
                            lastZeroQuery = nil
                            dismissZeroMatchToast()
                            if UIAccessibility.isVoiceOverRunning {
                                let msg = String(format: NSLocalizedString("graph.search.match_count.voiceover", comment: "Graph search match count VoiceOver announcement"), count)
                                UIAccessibility.post(notification: .announcement, argument: msg)
                            }
                        }
                    }
                    .onChange(of: viewModel.searchQuery) { _ in
                        // New query → cancel any pending toast so the next zero-hit
                        // can re-trigger from a clean state, and stale toasts don't
                        // linger over an in-flight new query.
                        dismissZeroMatchToast()
                    }
                }

                if showFilters {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: DSSpacing.sm) {
                            Text(NSLocalizedString("graph.filter.start", comment: "Graph date filter start label"))
                                .font(DSFonts.jetBrainsMono(size: 11))
                                .foregroundColor(DSColor.inkMuted)
                                .frame(width: 30)
                            DatePicker(
                                "",
                                selection: Binding(
                                    get: { viewModel.filterStartDate ?? Date() },
                                    set: { viewModel.filterStartDate = $0 }
                                ),
                                displayedComponents: .date
                            )
                            .labelsHidden()
                            .datePickerStyle(.compact)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if viewModel.filterStartDate != nil {
                                Button(NSLocalizedString("graph.filter.clear", comment: "Graph date filter clear button")) { viewModel.filterStartDate = nil }
                                    .font(DSFonts.inter(size: 11))
                                    .foregroundColor(DSColor.amberAccent)
                                    .frame(minHeight: 44)
                            }
                        }
                        HStack(spacing: DSSpacing.sm) {
                            Text(NSLocalizedString("graph.filter.end", comment: "Graph date filter end label"))
                                .font(DSFonts.jetBrainsMono(size: 11))
                                .foregroundColor(DSColor.inkMuted)
                                .frame(width: 30)
                            DatePicker(
                                "",
                                selection: Binding(
                                    get: { viewModel.filterEndDate ?? Date() },
                                    set: { viewModel.filterEndDate = $0 }
                                ),
                                displayedComponents: .date
                            )
                            .labelsHidden()
                            .datePickerStyle(.compact)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if viewModel.filterEndDate != nil {
                                Button(NSLocalizedString("graph.filter.clear", comment: "Graph date filter clear button")) { viewModel.filterEndDate = nil }
                                    .font(DSFonts.inter(size: 11))
                                    .foregroundColor(DSColor.amberAccent)
                                    .frame(minHeight: 44)
                            }
                        }
                    }
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.vertical, DSSpacing.md)
                    // #771: filter drop-down panel → glass engine (.panel).
                    // Full-width Rectangle so the bottom hairline divider below
                    // remains the visual seam (no rounded corners here).
                    .dpGlass(.panel, in: Rectangle())
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                } // end if !viewModel.nodes.isEmpty

                Rectangle()
                    .fill(DSColor.glassRim)
                    .frame(height: 0.5)
            }
            .background(DSColor.bgWarm)

            // MARK: Graph area — warm canvas
            ZStack {
                DSColor.bgWarm.ignoresSafeArea()

                if viewModel.isLoading {
                    GraphSkeleton()
                        .padding(40)
                } else if visibleNodes.isEmpty {
                    emptyState
                } else {
                    graphCanvas
                    legend
                        // The focus preview bar floats at the same bottom band;
                        // fade the legend out while focused so the two glass
                        // cards never stack (#828). Hit-testing off while
                        // hidden so ghost taps can't toggle type filters.
                        .opacity(viewModel.focusedNodeID != nil ? 0 : 1)
                        .allowsHitTesting(viewModel.focusedNodeID == nil)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showZeroMatchToast {
                zeroMatchToast
                    .padding(.bottom, 96)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(reduceMotion ? nil : Motion.spring, value: viewModel.focusedNodeID)
        .navigationBarHidden(true)
        .onReceive(headerTimer) { date in
            currentTime = date
        }
        .onAppear {
            viewModel.load()
        }
        .onChange(of: viewModel.nodes.count) { count in
            didAutoFit = false
            if !viewModel.nodes.isEmpty {
                startSimulation()
                if simulationSteps >= maxSimSteps { attemptAutoFit() }
            }
            let milestone = count / 10
            guard count > 0, milestone > lastNetworkMilestone else { return }
            lastNetworkMilestone = milestone
            Haptics.soft()
            if UIAccessibility.isVoiceOverRunning {
                let msg = String(
                    format: NSLocalizedString("graph.network.milestone.announcement", comment: "VoiceOver: network crossed a 10-node milestone"),
                    count, viewModel.edges.count
                )
                UIAccessibility.post(notification: .announcement, argument: msg)
            }
        }
        .onDisappear {
            stopSimulation()
        }
        // #828 — if a search/date/type filter removes the focused node from the
        // visible set, drop focus so the preview bar can't dangle over a hidden
        // node. Membership can change without a count change, so recompute the
        // visible id set each time any filter input changes.
        .onChange(of: viewModel.searchQuery) { _ in exitFocusIfNeeded() }
        .onChange(of: viewModel.filterStartDate) { _ in exitFocusIfNeeded() }
        .onChange(of: viewModel.filterEndDate) { _ in exitFocusIfNeeded() }
        .onChange(of: hiddenTypesRaw) { _ in exitFocusIfNeeded() }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                if !viewModel.nodes.isEmpty && simulationSteps < maxSimSteps {
                    startSimulation(reset: false)
                }
            case .inactive, .background:
                stopSimulation()
            @unknown default:
                break
            }
        }
        .sheet(isPresented: $showEntityPage) {
            if let node = selectedNode {
                EntityPageView(entityType: node.entityType, entitySlug: node.entitySlug)
            }
        }
    }

    private var hasActiveFilter: Bool {
        viewModel.filterStartDate != nil || viewModel.filterEndDate != nil || !viewModel.searchQuery.isEmpty
    }

    private var visibleNodes: [GraphNode] {
        hiddenTypes.isEmpty
            ? viewModel.filteredNodes
            : viewModel.filteredNodes.filter { !hiddenTypes.contains($0.entityType) }
    }

    private var isTransformed: Bool { scale != 1.0 || offset != .zero }

    // MARK: - Gesture Physics

    /// Zoom clamp bounds. Motion is allowed slightly past these while pinching
    /// (rubber-band), then springs back inside on release.
    private static let minScale: CGFloat = 0.3
    private static let maxScale: CGFloat = 5.0

    /// Interactive spring the canvas rides after a pan fling — carries the
    /// gesture's release velocity into a natural deceleration.
    private static let panMomentum: Animation = .interactiveSpring(response: 0.5,
                                                                    dampingFraction: 0.82,
                                                                    blendDuration: 0.25)
    /// Elastic settle used to snap zoom overshoot back inside the clamp.
    private static let zoomSettle: Animation = .spring(response: 0.35, dampingFraction: 0.72)

    /// Applies rising resistance once `raw` passes the zoom clamp so the pinch
    /// keeps responding at the limits instead of dead-stopping. Within bounds it
    /// returns `raw` unchanged; beyond, overshoot is compressed logarithmically.
    private static func rubberBandedScale(_ raw: CGFloat) -> CGFloat {
        if raw < minScale {
            let over = minScale - raw
            return minScale - over / (1 + over * 3.0)
        } else if raw > maxScale {
            let over = raw - maxScale
            return maxScale + over / (1 + over * 0.6)
        }
        return raw
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.nodes.isEmpty {
            if viewModel.hasCompiledDailies {
                EmptyStateView.graphNotConnected {
                    Task { @MainActor in
                        try? await CompilationService.shared.compile(trigger: "manual") { _, _ in }
                        viewModel.load()
                    }
                }
            } else {
                EmptyStateView.graphEmpty(ctaAction: {
                    nav.navigate(to: .today)
                }, subtitleOverride: graphEmptySubtitle(currentTime))
            }
        } else {
            EmptyStateView.graphNoMatches {
                Haptics.tapConfirm()
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    viewModel.searchInput = ""
                    viewModel.filterStartDate = nil
                    viewModel.filterEndDate = nil
                    hiddenTypes = Set()
                }
            }
        }
    }

    private func graphEmptySubtitle(_ date: Date) -> String {
        let key: String
        switch TimeOfDay.from(date) {
        case .morning:   key = "empty.graph.subtitle.morning"
        case .afternoon: key = "empty.graph.subtitle.afternoon"
        case .evening:   key = "empty.graph.subtitle.evening"
        case .lateNight: key = "empty.graph.subtitle.night"
        }
        return NSLocalizedString(key, comment: "")
    }

    private var clearFiltersButton: some View {
        Button {
            Haptics.tapConfirm()
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                viewModel.searchInput = ""
                viewModel.filterStartDate = nil
                viewModel.filterEndDate = nil
                hiddenTypes = Set()
            }
        } label: {
            Text(NSLocalizedString("graph.filter.clear_all", comment: "Graph clear all filters button"))
                .font(DSType.sectionLabel)
                .textCase(.uppercase)
                .tracking(1.5)
                .foregroundColor(Color.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(DSColor.amberDeep)
                .clipShape(Capsule())
        }
        .buttonStyle(ClearFiltersPressStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(L10n.Empty.graphClearFilters)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Network Size Pill

    private var networkSizePill: some View {
        let nodeCount = viewModel.nodes.count
        let edgeCount = viewModel.edges.count
        return HStack(spacing: 0) {
            Text(NSLocalizedString("graph.pill.nodes.prefix", comment: "Graph network pill — before node count"))
                .font(DSType.mono10)
                .foregroundColor(DSColor.inkMuted)
                .textCase(.uppercase)
                .tracking(0.5)
            Text("\(nodeCount)")
                .font(DSType.mono10)
                .foregroundColor(DSColor.inkMuted)
                .textCase(.uppercase)
                .tracking(0.5)
                .modifier(NumericTextContentTransition(value: Double(nodeCount), reduceMotion: reduceMotion))
                .animation(reduceMotion ? nil : Motion.spring, value: nodeCount)
            Text(NSLocalizedString("graph.pill.nodes.suffix", comment: "Graph network pill — between node and edge count"))
                .font(DSType.mono10)
                .foregroundColor(DSColor.inkMuted)
                .textCase(.uppercase)
                .tracking(0.5)
            Text("\(edgeCount)")
                .font(DSType.mono10)
                .foregroundColor(DSColor.inkMuted)
                .textCase(.uppercase)
                .tracking(0.5)
                .modifier(NumericTextContentTransition(value: Double(edgeCount), reduceMotion: reduceMotion))
                .animation(reduceMotion ? nil : Motion.spring, value: edgeCount)
            Text(NSLocalizedString("graph.pill.edges.suffix", comment: "Graph network pill — after edge count"))
                .font(DSType.mono10)
                .foregroundColor(DSColor.inkMuted)
                .textCase(.uppercase)
                .tracking(0.5)
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, 5)
        // #771: network-size stat badge → glass engine (.pill). Engine owns rim.
        .dpGlass(.pill, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            format: NSLocalizedString("graph.pill.accessibility", comment: "VoiceOver: network size combined label"),
            nodeCount, edgeCount
        ))
    }

    // MARK: - Accessibility Helpers

    private func announceSearchMatch(_ node: GraphNode, index: Int, total: Int) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let message: String
        if total == 1 {
            message = String(format: NSLocalizedString("graph.search.match.announcement.single", comment: "VoiceOver: single search match"), node.name)
        } else {
            message = String(format: NSLocalizedString("graph.search.match.announcement", comment: "VoiceOver: search match position"), node.name, index + 1, total)
        }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func localizedEntityTypeName(_ entityType: String) -> String {
        switch entityType {
        case "places":  return NSLocalizedString("graph.node_type.places", comment: "Graph node type: places")
        case "people":  return NSLocalizedString("graph.node_type.people", comment: "Graph node type: people")
        default:        return NSLocalizedString("graph.node_type.themes", comment: "Graph node type: themes")
        }
    }

    /// VoiceOver value for a node: its type name, plus a focus-state suffix
    /// (已聚焦 / 邻居) when the graph is in focus mode (#828).
    private func nodeA11yValue(_ node: GraphNode) -> String {
        let type = localizedEntityTypeName(node.entityType)
        guard let focus = viewModel.focusedNodeID else { return type }
        if node.id == focus {
            return type + "，" + NSLocalizedString("graph.focus.state.focused", comment: "VoiceOver value suffix: this node is focused")
        }
        if viewModel.focusedNeighborIDs.contains(node.id) {
            return type + "，" + NSLocalizedString("graph.focus.state.neighbor", comment: "VoiceOver value suffix: this node is a neighbor of the focused node")
        }
        return type
    }

    private func openNode(_ node: GraphNode) {
        Haptics.tapConfirm()
        selectedNode = node
        tapPulseNodeID = node.id
        tapPulseProgress = 0
        tapPulseGeneration += 1
        let gen = tapPulseGeneration
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
            tapPulseProgress = 1
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if tapPulseGeneration == gen { tapPulseNodeID = nil }
        }
        showEntityPage = true
    }

    /// #828 — enters or switches focus to `node`. Highlights its one-hop
    /// neighborhood, dims the rest, and (via the body) floats the preview bar.
    /// A soft haptic + pulse ring confirms the target. Does NOT open the entity
    /// page — that happens when the user taps the preview bar.
    private func enterFocus(_ node: GraphNode) {
        let switching = viewModel.focusedNodeID != nil && viewModel.focusedNodeID != node.id
        Haptics.soft()
        withAnimation(reduceMotion ? nil : Motion.spring) {
            viewModel.setFocus(node.id)
        }
        pulseNode(node)
        if UIAccessibility.isVoiceOverRunning {
            let neighborCount = viewModel.focusedNeighborIDs.count
            // Distinct phrasing for switching between focused nodes vs first
            // entry, so sequential VO exploration hears the state change.
            let key = switching ? "graph.focus.switched.a11y" : "graph.focus.entered.a11y"
            let msg = String(
                format: NSLocalizedString(key, comment: "VoiceOver: focus entered/switched to a node, N neighbors"),
                node.name, Int64(neighborCount)
            )
            UIAccessibility.post(notification: .announcement, argument: msg)
        }
    }

    /// #828 — drops focus if a filter has hidden the focused node. `visibleNodes`
    /// already folds in search, date, and legend-type filters.
    private func exitFocusIfNeeded() {
        guard viewModel.focusedNodeID != nil else { return }
        let ids = Set(visibleNodes.map { $0.id })
        viewModel.exitFocusIfFilteredOut(visibleIDs: ids)
    }

    /// #828 — exits focus, restoring full-graph visibility.
    private func exitFocus() {
        Haptics.soft()
        withAnimation(reduceMotion ? nil : Motion.spring) {
            viewModel.setFocus(nil)
        }
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(
                notification: .announcement,
                argument: NSLocalizedString("graph.focus.exited.a11y", comment: "VoiceOver: exited focus mode")
            )
        }
    }

    private func focusNode(_ node: GraphNode, in size: CGSize) {
        let targetScale: CGFloat = max(0.3, min(5.0, 2.2))
        let newOffset = CGSize(
            width:  (size.width  / 2 - node.position.x) * targetScale,
            height: (size.height / 2 - node.position.y) * targetScale
        )
        Haptics.tapConfirm()
        tapPulseNodeID = node.id
        tapPulseProgress = 0
        tapPulseGeneration += 1
        let gen = tapPulseGeneration
        withAnimation(reduceMotion ? nil : Motion.spring) {
            scale = targetScale; lastScale = targetScale
            offset = newOffset; lastOffset = newOffset
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
            tapPulseProgress = 1
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if tapPulseGeneration == gen { tapPulseNodeID = nil }
        }
    }

    // MARK: - Focus Helpers (#828)

    /// The set of node IDs that stay fully lit in the current focus state:
    /// the focused node plus its one-hop neighbors. Empty when not focused
    /// (meaning "everything is lit" — callers treat empty as no dimming).
    private var focusActiveIDs: Set<String> {
        guard let focus = viewModel.focusedNodeID else { return [] }
        var ids = viewModel.focusedNeighborIDs
        ids.insert(focus)
        return ids
    }

    /// Opacity multiplier for a node/label/edge under the current focus state.
    /// 1.0 when nothing is focused or the element is in the active set; a deep
    /// dim (0.15) otherwise so the focused neighborhood pops.
    private func focusOpacity(active: Bool) -> CGFloat {
        guard viewModel.focusedNodeID != nil else { return 1.0 }
        return active ? 1.0 : 0.15
    }

    // MARK: - Label Rendering (#828 tiered + collision-avoided)

    /// Draws node labels with priority ordering, zoom-gated tier limits, and a
    /// greedy rectangle-overlap skip so dense clusters no longer smear into an
    /// unreadable blur. Priority: focused node + neighbors first (always
    /// drawn), then search matches, then by occurrence count descending. At
    /// zoom < 0.6 only the top 8 draw, 0.6–1.2 the top 20, > 1.2 all — the
    /// focused neighborhood is exempt from the cap so it stays labelled.
    private func drawLabels(
        ctx: GraphicsContext,
        visible: [GraphNode],
        size: CGSize,
        activeIDs: Set<String>,
        isFocused: Bool
    ) {
        let query = viewModel.searchQuery
        let fontSize = max(8, 10 * scale)

        // Priority sort. Lower sortKey = higher priority (drawn first, wins
        // collisions). Focused neighborhood = 0, search match = 1, rest = 2;
        // within a tier, higher occurrence count wins.
        func priority(_ node: GraphNode) -> Int {
            if isFocused && activeIDs.contains(node.id) { return 0 }
            if !query.isEmpty && node.name.localizedCaseInsensitiveContains(query) { return 1 }
            return 2
        }
        let ordered = visible.sorted { a, b in
            let pa = priority(a), pb = priority(b)
            if pa != pb { return pa < pb }
            return a.occurrenceCount > b.occurrenceCount
        }

        // Zoom-gated cap on how many non-forced labels may draw.
        let cap: Int
        if scale < 0.6 { cap = 8 }
        else if scale <= 1.2 { cap = 20 }
        else { cap = Int.max }

        var drawnRects: [CGRect] = []
        var drawnCount = 0
        for node in ordered {
            let forced = isFocused && activeIDs.contains(node.id)
            if !forced && drawnCount >= cap { continue }

            let x = node.position.x * scale + offset.width + size.width / 2
            let y = node.position.y * scale + offset.height + size.height / 2
            let labelY = y + node.displayRadius * scale + 10 * scale

            // Approximate label rect. JetBrains Mono ASCII advance ≈ 0.6 ×
            // fontSize, but CJK glyphs (PingFang fallback) are full-width
            // ≈ 1.0 × fontSize — a flat 0.6 factor under-measures Chinese
            // names by ~40% and lets them overlap despite the greedy check.
            let estWidth = node.name.reduce(CGFloat(0)) { acc, ch in
                acc + fontSize * (ch.isASCII ? 0.6 : 1.0)
            }
            let estHeight = fontSize * 1.3
            let rect = CGRect(x: x - estWidth / 2, y: labelY - estHeight / 2, width: estWidth, height: estHeight)

            // Greedy collision skip — but never drop a forced (focused) label.
            if !forced && drawnRects.contains(where: { $0.intersects(rect) }) { continue }
            drawnRects.append(rect)
            if !forced { drawnCount += 1 }

            let isSearchMatch = !query.isEmpty && node.name.localizedCaseInsensitiveContains(query)
            // Focus dim applies to labels too so out-of-focus names recede.
            let focusAlpha = focusOpacity(active: !isFocused || activeIDs.contains(node.id))
            let label = Text(node.name)
                .font(.custom("JetBrainsMono-Regular", fixedSize: fontSize))
                .fontWeight(isSearchMatch ? .bold : .regular)
                .foregroundColor((isSearchMatch ? DSColor.amberDeep : DSColor.inkPrimary).opacity(focusAlpha))
            ctx.draw(label, at: CGPoint(x: x, y: labelY), anchor: .center)
        }
    }

    // MARK: - Hit Testing

    /// Finds the nearest visible node whose screen-space hit radius contains
    /// the tap location. Mirrors the deleted invisible tap-target circles:
    /// screen position = model position * scale + offset + size/2, hit radius
    /// = max(displayRadius * scale, 22) — same 44pt minimum touch target.
    private func hitTestNode(at location: CGPoint, in size: CGSize) -> GraphNode? {
        var best: GraphNode? = nil
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for node in visibleNodes {
            let x = node.position.x * scale + offset.width + size.width / 2
            let y = node.position.y * scale + offset.height + size.height / 2
            let r = max(node.displayRadius * scale, 22)
            let dx = location.x - x
            let dy = location.y - y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance <= r && distance < bestDistance {
                bestDistance = distance
                best = node
            }
        }
        return best
    }

    // MARK: - Graph Canvas

    private var graphCanvas: some View {
        GeometryReader { geo in
            let size = geo.size
            let visible = visibleNodes
            let filteredIDs = Set(visible.map { $0.id })

            ZStack {
                Canvas { ctx, _ in
                    let nodePos = Dictionary(uniqueKeysWithValues: viewModel.nodes.map { ($0.id, $0.position) })
                    let activeIDs = focusActiveIDs
                    let isFocused = viewModel.focusedNodeID != nil

                    // Draw edges (visible nodes only). Line width + opacity now
                    // encode co-occurrence weight in three tiers (#828); base
                    // colors come from the ink token so they adapt to scheme.
                    // Edge color derives from the shared edge ink; alpha carries
                    // both the weight tier and the focus dim.
                    let visibleEdges = viewModel.filteredEdges.filter {
                        filteredIDs.contains($0.sourceID) && filteredIDs.contains($0.targetID)
                    }
                    for edge in visibleEdges {
                        guard let src = nodePos[edge.sourceID], let dst = nodePos[edge.targetID] else { continue }
                        let sx = src.x * scale + offset.width + size.width / 2
                        let sy = src.y * scale + offset.height + size.height / 2
                        let ex = dst.x * scale + offset.width + size.width / 2
                        let ey = dst.y * scale + offset.height + size.height / 2
                        var path = Path()
                        path.move(to: CGPoint(x: sx, y: sy))
                        path.addLine(to: CGPoint(x: ex, y: ey))
                        // 3-tier weight encoding: width + opacity + ink step.
                        // inkFaint alone reads as nearly invisible on the warm
                        // canvas (the pre-#828 flat-edge problem), so heavier
                        // ties also climb the ink ladder for real contrast.
                        let lineWidth: CGFloat
                        let baseAlpha: CGFloat
                        let edgeInk: Color
                        switch edge.weight {
                        case ...1:   lineWidth = 0.8; baseAlpha = 0.35; edgeInk = DSColor.inkFaint
                        case 2...3:  lineWidth = 1.6; baseAlpha = 0.50; edgeInk = DSColor.inkSubtle
                        default:     lineWidth = 2.6; baseAlpha = 0.65; edgeInk = DSColor.inkMuted
                        }
                        // In focus mode an edge stays lit only if BOTH its
                        // endpoints are in the active neighborhood (i.e. it's an
                        // edge of the focused node); otherwise it dims.
                        let edgeActive = !isFocused
                            || (activeIDs.contains(edge.sourceID) && activeIDs.contains(edge.targetID))
                        let alpha = baseAlpha * focusOpacity(active: edgeActive)
                        ctx.stroke(path, with: .color(edgeInk.opacity(alpha)), lineWidth: lineWidth)
                    }

                    // Draw all nodes (dim non-matching); radius scales with occurrence count
                    for node in viewModel.nodes {
                        let inFilter = filteredIDs.contains(node.id)
                        let x = node.position.x * scale + offset.width + size.width / 2
                        let y = node.position.y * scale + offset.height + size.height / 2
                        let r = node.displayRadius * scale
                        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                        // Two independent dims stack: search/date filter (0.2)
                        // and focus mode (0.15). Take the lower so a node that's
                        // both out-of-filter and out-of-focus doesn't double-dim
                        // below either floor.
                        let filterAlpha: CGFloat = inFilter ? 1.0 : 0.2
                        let focusAlpha = focusOpacity(active: !isFocused || activeIDs.contains(node.id))
                        let alpha = min(filterAlpha, focusAlpha)
                        ctx.fill(Path(ellipseIn: rect), with: .color(node.color.opacity(alpha)))
                        ctx.stroke(Path(ellipseIn: rect), with: .color(node.color.opacity(0.6 * alpha)), lineWidth: 1.5 * scale)
                    }

                    // Node labels — tiered by priority + greedy collision skip
                    // (#828). Drawn in-Canvas so the label layer no longer
                    // re-lays-out dozens of SwiftUI Text views every simulation
                    // frame (Axiom perf audit). VoiceOver names come from the
                    // accessibility layer below. See drawLabels(...) for the
                    // priority ordering and rectangle-overlap rejection.
                    drawLabels(
                        ctx: ctx,
                        visible: visible,
                        size: size,
                        activeIDs: activeIDs,
                        isFocused: isFocused
                    )
                }
                .frame(width: size.width, height: size.height)
                // Tap/zoom/pan gestures live on the Canvas DRAWING LAYER, not
                // the containing ZStack. A container-level SpatialTapGesture
                // (count:2).exclusively(single) steals taps from sibling child
                // buttons — verified on-simulator: preview-bar and zoom-capsule
                // taps were delivered to the canvas single-tap handler instead
                // of the buttons (#828 FINDING). On the Canvas itself the
                // buttons layered above win hit-testing as normal.
                .gesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { value in
                            if let node = hitTestNode(at: value.location, in: size) {
                                focusNode(node, in: size)
                            } else {
                                Haptics.soft()
                                fitToContent(in: size)
                            }
                        }
                        .exclusively(
                            before: SpatialTapGesture()
                                .onEnded { value in
                                    // #828 two-stage exploration: single tap on a
                                    // node enters/switches focus; empty space
                                    // exits. Entity page opens from the preview bar.
                                    if let node = hitTestNode(at: value.location, in: size) {
                                        enterFocus(node)
                                    } else if viewModel.focusedNodeID != nil {
                                        exitFocus()
                                    }
                                }
                        )
                )
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                // Rubber-band past the [0.3, 5.0] clamp: motion
                                // continues beyond the bound with rising resistance
                                // instead of dead-stopping, then springs back on
                                // release. Feels alive at the zoom limits.
                                let raw = lastScale * value
                                let newScale = Self.rubberBandedScale(raw)
                                let ratio = newScale / scale
                                offset.width *= ratio
                                offset.height *= ratio
                                scale = newScale
                            }
                            .onEnded { _ in
                                // Snap any overshoot back inside the clamp with an
                                // elastic settle (honors Reduce Motion). Offset is
                                // scaled by the same ratio so the pivot stays put.
                                let clamped = max(0.3, min(5.0, scale))
                                let ratio = clamped / max(scale, 0.0001)
                                let target = CGSize(width: offset.width * ratio,
                                                    height: offset.height * ratio)
                                if clamped != scale {
                                    withAnimation(Motion.respectReduceMotion(Self.zoomSettle)) {
                                        scale = clamped
                                        offset = target
                                    }
                                }
                                lastScale = clamped
                                lastOffset = target
                            },
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { value in
                                // Momentum: project the fling using the gesture's
                                // velocity-derived predicted end translation, then
                                // ride an interactive spring to that target so the
                                // canvas decelerates naturally instead of freezing
                                // on the release frame. Reduce Motion → hard freeze.
                                let projected = CGSize(
                                    width: lastOffset.width + value.predictedEndTranslation.width,
                                    height: lastOffset.height + value.predictedEndTranslation.height
                                )
                                if reduceMotion {
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                } else {
                                    withAnimation(Self.panMomentum) { offset = projected }
                                }
                                lastOffset = projected
                            }
                    )
                )
                .accessibilityHidden(true)
                .onAppear { simulationSize = size }
                .onChange(of: size) { simulationSize = $0 }
                .onChange(of: viewModel.searchQuery) { query in
                    searchMatchIndex = 0
                    matchPillFlash = false
                    guard !query.isEmpty else {
                        lastCenteredMatchID = nil
                        return
                    }
                    guard let match = bestSearchMatch, match.id != lastCenteredMatchID else { return }
                    lastCenteredMatchID = match.id
                    Haptics.soft()
                    if simulationSteps >= maxSimSteps {
                        centerOn(match, in: size)
                        pulseNode(match)
                    } else {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            centerOn(match, in: size)
                            pulseNode(match)
                        }
                    }
                }

                // Accessibility layer — VoiceOver-only elements for each filtered
                // node. The visual labels are drawn inside the Canvas above and
                // touch is handled by the SpatialTapGesture hit-test on the
                // container, so these circles carry accessibility ONLY (hit
                // testing disabled). Positions come from a snapshot frozen when
                // the force simulation settles/stops — never from the live
                // per-frame simulation positions — so this ForEach does not
                // re-layout the SwiftUI view graph on every simulation tick.
                // While the simulation is still running, VoiceOver targets may
                // lag the drawn nodes by up to one settle cycle; by design.
                ForEach(visible) { node in
                    let pos = a11yPositions[node.id] ?? node.position
                    let x = pos.x * scale + offset.width + size.width / 2
                    let y = pos.y * scale + offset.height + size.height / 2
                    let r = max(node.displayRadius * scale, 22)
                    Circle()
                        .fill(Color.clear)
                        .frame(width: r * 2, height: r * 2)
                        .position(x: x, y: y)
                        .allowsHitTesting(false)
                        .accessibilityElement()
                        // R4 — VoiceOver gets entity name + recurrence count
                        // so users can scan the graph by frequency without
                        // seeing the visual node-size cue.
                        .accessibilityLabel(String(
                            format: NSLocalizedString(
                                "graph.node.a11y.full",
                                value: "实体：%@，出现 %lld 次",
                                comment: "VoiceOver label: entity name + occurrence count"
                            ),
                            node.name, Int64(node.occurrenceCount)
                        ))
                        .accessibilityValue(nodeA11yValue(node))
                        // #828 — VoiceOver activation now mirrors touch: it
                        // enters focus (highlighting the neighborhood) rather
                        // than jumping to the entity page. The entity page is
                        // reached from the focus preview bar's own element.
                        .accessibilityHint(NSLocalizedString("graph.a11y.focus_entity", comment: "Graph node accessibility hint: activate to focus"))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { enterFocus(node) }
                }

                // Tap pulse ring — reads live position from the model so it tracks
                // the node even while the force-directed simulation is still running.
                if let id = tapPulseNodeID,
                   let pulseNode = viewModel.nodes.first(where: { $0.id == id }) {
                    let px = pulseNode.position.x * scale + offset.width + size.width / 2
                    let py = pulseNode.position.y * scale + offset.height + size.height / 2
                    let ringScale = 1.0 + tapPulseProgress   // 1.0 → 2.0
                    let diameter = pulseNode.displayRadius * scale * 2 * ringScale
                    Circle()
                        .strokeBorder(pulseNode.color, lineWidth: 2)
                        .frame(width: diameter, height: diameter)
                        .opacity(Double(1 - tapPulseProgress))
                        .position(x: px, y: py)
                        .allowsHitTesting(false)
                }

                // #828 — single consolidated control capsule (fit / + / −).
                // The former separate recenter button + zoom-% pill + zoom
                // stepper (three glass cards padded into alignment by hand) are
                // now one vertical capsule with hairline dividers.
                zoomControls

                // #828 focus preview bar. Two hard-won constraints (verified
                // on-simulator via tap bisection, see PR #-for-828):
                //  1. It must NOT be wrapped in `if … + .transition(.move…)` —
                //     the transition wrapper left the button permanently
                //     non-hit-testable (taps fell through to the canvas and
                //     exited focus). It stays mounted and animates via
                //     opacity + offset instead.
                //  2. Its glass must be the interactive .control role — a
                //     non-interactive .panel pane on the iOS 26 native
                //     glassEffect path swallows child-button touches.
                focusPreviewBar
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 28)
                    .opacity(viewModel.focusedNodeID != nil ? 1 : 0)
                    .offset(y: viewModel.focusedNodeID != nil || reduceMotion ? 0 : 24)
                    .allowsHitTesting(viewModel.focusedNodeID != nil)
            }
            // Gestures are attached to the Canvas drawing layer above (see
            // comment there) so the zoom capsule and focus preview bar keep
            // normal button hit-testing. Only the VoiceOver container action
            // stays at ZStack level — the Canvas itself is accessibilityHidden.
            .accessibilityAction(named: Text(NSLocalizedString("Reset view", comment: "VoiceOver: graph canvas reset-view action"))) {
                Haptics.soft()
                fitToContent(in: size)
            }
        }
    }

    // MARK: - Legend

    // Legend renders from GraphNode.color(for:) so node hues and legend swatches
    // can never drift (#828 收敛为一处). Order: people / places / themes.
    private static let legendTypeOrder: [String] = ["people", "places", "themes"]

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.legendTypeOrder, id: \.self) { type in
                let count = viewModel.filteredNodes.filter { $0.entityType == type }.count
                let isHidden = hiddenTypes.contains(type)
                let label = localizedEntityTypeName(type)
                legendRow(type: type, color: GraphNode.color(for: type), label: label, count: count, isHidden: isHidden)
            }
        }
        .padding(DSSpacing.md)
        // .control (interactive glass), NOT .panel: on the iOS 26 native
        // glassEffect path a non-interactive pane composites its children
        // into the glass layer and the type-toggle rows stop receiving
        // touches entirely (#828 FINDING, same as zoom capsule/preview bar).
        .dpGlass(.control, in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous), tint: GlassTone.hi.fill)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(DSSpacing.lg)
    }

    // #828 — single vertical control capsule replacing the three separate
    // glass cards (recenter / zoom-% pill / zoom stepper). One glass background,
    // hairline dividers between the three actions: fit (center-to-content, the
    // former recenter) / + (zoom in) / − (zoom out). Each action keeps its
    // original accessibility label.
    private var zoomControls: some View {
        VStack(spacing: 0) {
            // Fit — center-and-scale to show all content (former recenter).
            Button {
                Haptics.tapConfirm()
                fitToScreen(in: simulationSize)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(DSColor.inkPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .opacity(visibleNodes.count < 2 ? 0.4 : 1.0)
            }
            .disabled(visibleNodes.count < 2)
            .accessibilityLabel(NSLocalizedString("graph.a11y.fit", comment: "Graph fit-to-screen button"))
            .accessibilityAddTraits(.isButton)

            // Fixed-width hairline: an unconstrained Rectangle is greedy and
            // stretches the whole VStack (and its glass card) to full screen
            // width, burying the graph under a giant panel (FINDING-002).
            Rectangle()
                .fill(DSColor.glassRim)
                .frame(width: 24, height: 0.5)

            Button {
                zoom(by: 1.3)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(DSColor.inkPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .opacity(scale >= 5.0 ? 0.4 : 1.0)
            }
            .accessibilityLabel(NSLocalizedString("graph.a11y.zoom_in", comment: "Graph zoom in button"))
            .accessibilityHint(scale >= 5.0 ? NSLocalizedString("graph.a11y.zoom_max", comment: "Graph zoom in limit hint") : "")
            .accessibilityAddTraits(.isButton)

            Rectangle()
                .fill(DSColor.glassRim)
                .frame(width: 24, height: 0.5)

            Button {
                zoom(by: 1 / 1.3)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(DSColor.inkPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .opacity(scale <= 0.3 ? 0.4 : 1.0)
            }
            .accessibilityLabel(NSLocalizedString("graph.a11y.zoom_out", comment: "Graph zoom out button"))
            .accessibilityHint(scale <= 0.3 ? NSLocalizedString("graph.a11y.zoom_min", comment: "Graph zoom out limit hint") : "")
            .accessibilityAddTraits(.isButton)
        }
        // .control (interactive glass) — see legend comment: a .panel pane on
        // iOS 26 swallows child-button touches (#828 FINDING).
        .dpGlass(.control, in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous), tint: GlassTone.hi.fill)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(DSSpacing.lg)
    }

    // Springs scale+offset to show all visible nodes — used by double-tap-to-reset
    // and the fit-to-screen button. Caller is responsible for any haptic feedback.
    private func fitToContent(in size: CGSize) {
        let nodes = visibleNodes
        guard nodes.count >= 2 else {
            if let node = nodes.first {
                let targetScale: CGFloat = 1.5
                let newOffset = CGSize(
                    width:  -node.position.x * targetScale,
                    height: -node.position.y * targetScale
                )
                withAnimation(reduceMotion ? nil : Motion.spring) {
                    scale = targetScale; lastScale = targetScale
                    offset = newOffset; lastOffset = newOffset
                }
            } else {
                withAnimation(reduceMotion ? nil : Motion.spring) {
                    scale = 1.0; lastScale = 1.0
                    offset = .zero; lastOffset = .zero
                }
            }
            return
        }

        let inset: CGFloat = 40
        var minX = nodes[0].position.x - nodes[0].displayRadius
        var maxX = nodes[0].position.x + nodes[0].displayRadius
        var minY = nodes[0].position.y - nodes[0].displayRadius
        var maxY = nodes[0].position.y + nodes[0].displayRadius
        for node in nodes.dropFirst() {
            minX = min(minX, node.position.x - node.displayRadius)
            maxX = max(maxX, node.position.x + node.displayRadius)
            minY = min(minY, node.position.y - node.displayRadius)
            maxY = max(maxY, node.position.y + node.displayRadius)
        }
        let contentWidth  = maxX - minX
        let contentHeight = maxY - minY
        guard contentWidth > 0, contentHeight > 0 else { return }

        let availableWidth  = size.width  - inset * 2
        let availableHeight = size.height - inset * 2
        let targetScale = max(0.3, min(5.0, min(availableWidth / contentWidth, availableHeight / contentHeight)))
        let midX = (minX + maxX) / 2
        let midY = (minY + maxY) / 2
        let newOffset = CGSize(width: -midX * targetScale, height: -midY * targetScale)

        withAnimation(reduceMotion ? nil : Motion.spring) {
            scale = targetScale; lastScale = targetScale
            offset = newOffset; lastOffset = newOffset
        }
    }

    private func fitToScreen(in size: CGSize) {
        let nodes = visibleNodes
        guard nodes.count >= 2 else {
            // Single node fallback: center on it at scale 1.5
            if let node = nodes.first {
                let targetScale: CGFloat = 1.5
                let newOffset = CGSize(
                    width:  -node.position.x * targetScale,
                    height: -node.position.y * targetScale
                )
                withAnimation(reduceMotion ? nil : Motion.spring) {
                    scale = targetScale; lastScale = targetScale
                    offset = newOffset; lastOffset = newOffset
                }
                Haptics.tapConfirm()
            }
            return
        }

        let inset: CGFloat = 40
        var minX = nodes[0].position.x - nodes[0].displayRadius
        var maxX = nodes[0].position.x + nodes[0].displayRadius
        var minY = nodes[0].position.y - nodes[0].displayRadius
        var maxY = nodes[0].position.y + nodes[0].displayRadius
        for node in nodes.dropFirst() {
            minX = min(minX, node.position.x - node.displayRadius)
            maxX = max(maxX, node.position.x + node.displayRadius)
            minY = min(minY, node.position.y - node.displayRadius)
            maxY = max(maxY, node.position.y + node.displayRadius)
        }

        let contentWidth  = maxX - minX
        let contentHeight = maxY - minY
        guard contentWidth > 0, contentHeight > 0 else { return }

        let availableWidth  = size.width  - inset * 2
        let availableHeight = size.height - inset * 2
        let targetScale = max(0.3, min(5.0, min(availableWidth / contentWidth, availableHeight / contentHeight)))

        let midX = (minX + maxX) / 2
        let midY = (minY + maxY) / 2
        let newOffset = CGSize(
            width:  -midX * targetScale,
            height: -midY * targetScale
        )

        withAnimation(reduceMotion ? nil : Motion.spring) {
            scale = targetScale; lastScale = targetScale
            offset = newOffset; lastOffset = newOffset
        }
        Haptics.tapConfirm()
    }

    private func zoom(by factor: CGFloat) {
        let target = max(0.3, min(5.0, scale * factor))
        guard abs(target - scale) >= 0.0001 else {
            Haptics.warn()
            return
        }
        let ratio = target / scale
        let newOffset = CGSize(width: offset.width * ratio, height: offset.height * ratio)
        if !reduceMotion {
            withAnimation(Motion.spring) {
                scale = target; lastScale = target
                offset = newOffset; lastOffset = newOffset
            }
        } else {
            scale = target; lastScale = target
            offset = newOffset; lastOffset = newOffset
        }
        Haptics.soft()
    }

    private func legendRow(type: String, color: Color, label: String, count: Int, isHidden: Bool) -> some View {
        Button {
            Haptics.soft()
            withAnimation(Motion.spring) {
                var updated = hiddenTypes
                if isHidden {
                    updated.remove(type)
                } else {
                    updated.insert(type)
                }
                hiddenTypes = updated
            }
        } label: {
            HStack(spacing: 6) {
                if isHidden {
                    Circle()
                        .strokeBorder(color, lineWidth: 1.5)
                        .frame(width: 10, height: 10)
                } else {
                    Circle()
                        .fill(color)
                        .frame(width: 10, height: 10)
                }
                Text("\(label) \(count)")
                    .font(DSFonts.jetBrainsMono(size: 10))
                    .foregroundColor(DSColor.inkPrimary)
                    .strikethrough(isHidden, color: DSColor.inkMuted)
            }
            .opacity(isHidden ? 0.35 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(format: NSLocalizedString("graph.legend.node_count", comment: "Graph legend row accessibility label"), label, count))
        .accessibilityValue(isHidden ? NSLocalizedString("graph.legend.value.hidden", comment: "Graph legend hidden state") : NSLocalizedString("graph.legend.value.shown", comment: "Graph legend shown state"))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Focus Preview Bar (#828)

    /// Bottom liquid-glass card shown while a node is focused. Surfaces the
    /// entity name (serif), its type + occurrence count + most-recent date
    /// (mono), and a chevron. Tapping it opens the existing EntityPage sheet —
    /// the two-stage exploration path: tap node → focus, tap bar → entity page.
    @ViewBuilder
    private var focusPreviewBar: some View {
        if let node = viewModel.focusedNode {
            Button {
                Haptics.tapConfirm()
                openNode(node)
            } label: {
                HStack(spacing: DSSpacing.md) {
                    // Category swatch — same hue as the node.
                    Circle()
                        .fill(node.color)
                        .frame(width: 12, height: 12)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(node.name)
                            .font(DSFonts.serif(size: 17, weight: .semibold))
                            .foregroundColor(DSColor.inkPrimary)
                            .lineLimit(1)
                        Text(focusPreviewSubtitle(for: node))
                            .font(DSFonts.jetBrainsMono(size: 11))
                            .foregroundColor(DSColor.inkMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: DSSpacing.sm)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DSColor.inkMuted)
                }
                .padding(.horizontal, DSSpacing.lg)
                .padding(.vertical, DSSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                // .control (interactive glass) — see legend comment: a .panel
                // pane on iOS 26 swallows the bar-button's touches (#828 FINDING).
                .dpGlass(.control, in: RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous), tint: GlassTone.hi.fill)
                // The glassEffect background is composited out of the label,
                // collapsing the Button's tappable area to bare text glyphs —
                // verified on-simulator (a plain background restored taps).
                // contentShape re-establishes the full card as the hit area,
                // the same guard every zoom-capsule button carries.
                .contentShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DSSpacing.lg)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(focusPreviewA11yLabel(for: node))
            .accessibilityHint(NSLocalizedString("graph.focus.preview.hint", comment: "VoiceOver hint: double-tap opens entity page"))
            .accessibilityAddTraits(.isButton)
        }
    }

    /// Mono subtitle line: "类型 · 出现 N 次 · 最近 YYYY-MM-DD" (date omitted if unknown).
    private func focusPreviewSubtitle(for node: GraphNode) -> String {
        let typeName = localizedEntityTypeName(node.entityType)
        let occ = String(
            format: NSLocalizedString("graph.focus.preview.occurrences", comment: "Focus preview: occurrence count fragment"),
            Int64(node.occurrenceCount)
        )
        if let latest = node.dates.max() {
            let recent = String(
                format: NSLocalizedString("graph.focus.preview.recent", comment: "Focus preview: most-recent date fragment"),
                latest
            )
            return "\(typeName) · \(occ) · \(recent)"
        }
        return "\(typeName) · \(occ)"
    }

    private func focusPreviewA11yLabel(for node: GraphNode) -> String {
        let base = String(
            format: NSLocalizedString("graph.focus.preview.a11y", comment: "VoiceOver: focus preview bar — name, type, count"),
            node.name, localizedEntityTypeName(node.entityType), Int64(node.occurrenceCount)
        )
        if let latest = node.dates.max() {
            return base + " · " + String(
                format: NSLocalizedString("graph.focus.preview.recent", comment: "Focus preview: most-recent date fragment"),
                latest
            )
        }
        return base
    }

    // MARK: - Zero-Match Toast

    private var zeroMatchToast: some View {
        // Chinese-by-default string (consistent with other in-product copy like
        // "暂无关联记录" in EntityPageView). Quoted query is the user's literal
        // input so they see exactly what didn't match.
        let msg = "没有匹配 '\(zeroMatchToastQuery)'"
        return Text(msg)
            .font(DSFonts.jetBrainsMono(size: 12))
            .foregroundColor(DSColor.inkPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            // #771: zero-match toast → glass engine (.toast). Engine owns rim.
            .dpGlass(.toast, in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            .accessibilityLabel(msg)
    }

    private func presentZeroMatchToast(for query: String) {
        zeroMatchToastQuery = query
        zeroMatchToastGen += 1
        let gen = zeroMatchToastGen
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            showZeroMatchToast = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // A newer toast (or a dismissZeroMatchToast call) bumped the
            // generation — drop this stale fade-out so it doesn't snuff a
            // freshly-presented toast.
            guard gen == zeroMatchToastGen else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                showZeroMatchToast = false
            }
        }
    }

    private func dismissZeroMatchToast() {
        guard showZeroMatchToast else {
            // Still bump the generation so any pending fade-out task drops
            // the next-toast schedule, even if no toast is on screen yet.
            zeroMatchToastGen += 1
            return
        }
        zeroMatchToastGen += 1
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            showZeroMatchToast = false
        }
    }

    // MARK: - Search Match Navigation

    private func advanceMatch(by delta: Int, matches: [GraphNode], in size: CGSize) {
        guard !matches.isEmpty else { return }
        let oldIndex = searchMatchIndex
        let newIndex = (oldIndex + delta + matches.count) % matches.count
        let wrapped = delta > 0 ? newIndex < oldIndex : newIndex > oldIndex
        searchMatchIndex = newIndex
        let node = matches[newIndex]
        centerOn(node, in: size)
        pulseNode(node)
        announceSearchMatch(node, index: newIndex, total: matches.count)
        if wrapped {
            Haptics.rigid(intensity: 0.7)
            if !reduceMotion {
                matchPillFlash = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    matchPillFlash = false
                }
            }
        } else {
            Haptics.soft()
        }
    }

    // MARK: - Search Auto-Center

    private var searchMatches: [GraphNode] {
        guard !viewModel.searchQuery.isEmpty else { return [] }
        let q = viewModel.searchQuery
        let candidates = visibleNodes.filter { $0.name.localizedCaseInsensitiveContains(q) }
        let exact   = candidates.filter { $0.name.localizedCaseInsensitiveCompare(q) == .orderedSame }
        let prefix  = candidates.filter { $0.name.lowercased().hasPrefix(q.lowercased()) && $0.name.localizedCaseInsensitiveCompare(q) != .orderedSame }
        let rest    = candidates.filter { !$0.name.lowercased().hasPrefix(q.lowercased()) }
        return (exact + prefix + rest.sorted { $0.name.count < $1.name.count })
    }

    private func pulseNode(_ node: GraphNode) {
        tapPulseNodeID = node.id
        tapPulseProgress = 0
        tapPulseGeneration += 1
        let gen = tapPulseGeneration
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
            tapPulseProgress = 1
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if tapPulseGeneration == gen { tapPulseNodeID = nil }
        }
    }

    private var bestSearchMatch: GraphNode? {
        guard !viewModel.searchQuery.isEmpty else { return nil }
        let q = viewModel.searchQuery
        let candidates = viewModel.filteredNodes.filter {
            $0.name.localizedCaseInsensitiveContains(q)
        }
        if let exact = candidates.first(where: { $0.name.localizedCaseInsensitiveCompare(q) == .orderedSame }) {
            return exact
        }
        if let prefix = candidates.first(where: { $0.name.localizedCaseInsensitiveContains(q) && $0.name.lowercased().hasPrefix(q.lowercased()) }) {
            return prefix
        }
        return candidates.min(by: { $0.name.count < $1.name.count })
    }

    private func centerOn(_ node: GraphNode, in size: CGSize) {
        let newOffset = CGSize(
            width: -node.position.x * scale,
            height: -node.position.y * scale
        )
        withAnimation(reduceMotion ? nil : Motion.spring) {
            offset = newOffset
            lastOffset = newOffset
        }
    }

    // MARK: - Simulation

    private func attemptAutoFit() {
        guard !didAutoFit, !isTransformed, visibleNodes.count >= 2 else { return }
        didAutoFit = true
        fitToScreen(in: simulationSize)
    }

    /// Freezes current node positions for the VoiceOver accessibility layer.
    /// Called when the simulation starts (initial layout) and when it stops
    /// (settled, view disappeared, or app backgrounded). While the simulation
    /// runs, accessibility targets intentionally stay at the last snapshot.
    private func snapshotAccessibilityPositions() {
        a11yPositions = Dictionary(
            uniqueKeysWithValues: viewModel.nodes.map { ($0.id, $0.position) }
        )
    }

    private func startSimulation(reset: Bool = true) {
        if reset {
            simulationSteps = 0
            snapshotAccessibilityPositions()
        }
        // CADisplayLink ticks on the main thread @ 30fps; controller is
        // idempotent (start() is a no-op when already running), so we just
        // reinstall the closure to capture the latest state and (re)start it.
        displayLink.onTick = {
            guard self.simulationSteps < self.maxSimSteps else {
                self.stopSimulation()
                return
            }
            self.viewModel.simulationStep(size: self.simulationSize)
            self.simulationSteps += 1
            if self.simulationSteps == self.maxSimSteps {
                self.attemptAutoFit()
            }
        }
        displayLink.start()
    }

    private func stopSimulation() {
        displayLink.stop()
        // Simulation halted — re-sync the accessibility layer to the final
        // (settled) node positions.
        snapshotAccessibilityPositions()
    }
}

// MARK: - NumericTextContentTransition

private struct NumericTextContentTransition: ViewModifier {
    let value: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .contentTransition(reduceMotion ? .identity : .numericText(value: value))
        } else {
            content
                .contentTransition(.identity)
        }
    }
}

// MARK: - ClearFiltersPressStyle

private struct ClearFiltersPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect((!reduceMotion && configuration.isPressed) ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}
