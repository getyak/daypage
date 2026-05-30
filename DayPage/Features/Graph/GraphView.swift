import SwiftUI
import UIKit

// MARK: - GraphView

struct GraphView: View {

    @EnvironmentObject private var nav: AppNavigationModel
    @StateObject private var viewModel = GraphViewModel()

    // Zoom & pan state
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero

    // Simulation timer
    @State private var simulationTimer: Timer? = nil
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

    // Zero-match haptic guard — fires warn() exactly once per zero-crossing
    @State private var lastZeroQuery: String? = nil

    // Legend type-visibility filter
    @State private var hiddenTypes: Set<String> = []

    // Empty state animation + ClearFiltersPressStyle (do not remove this @Environment:
    // both `emptyState` and `clearFiltersButton` read `reduceMotion`; deleting it
    // breaks the build — see incident around PR #466).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let nodeRadius: CGFloat = 16
    private let maxSimSteps = 200

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Header bar — Liquid Glass strip on the warm canvas
            VStack(spacing: 0) {
                HStack(spacing: DSSpacing.sm) {
                    // Search field — glass-tinted capsule
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundColor(DSColor.inkMuted)
                        TextField("搜索节点...", text: $viewModel.searchQuery)
                            .font(DSFonts.jetBrainsMono(size: 12))
                            .foregroundColor(DSColor.inkPrimary)
                        if !viewModel.searchQuery.isEmpty {
                            Button {
                                Haptics.soft()
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    viewModel.searchQuery = ""
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(DSColor.inkSubtle)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Clear search")
                            .transition(.opacity)
                        }
                    }
                    .animation(Motion.fade, value: viewModel.searchQuery.isEmpty)
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.vertical, 7)
                    .background(DSColor.glassLo)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                            .strokeBorder(DSColor.glassRim, lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))

                    // Filter toggle — amber when active
                    Button {
                        withAnimation(.easeInOut) { showFilters.toggle() }
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
                                Text(NSLocalizedString("无匹配节点", comment: "Graph search zero-match pill"))
                                    .font(DSFonts.jetBrainsMono(size: 11))
                                    .foregroundColor(DSColor.inkMuted)
                            }
                            .padding(.horizontal, DSSpacing.md)
                            .padding(.vertical, 5)
                            .background(DSColor.glassLo)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(DSColor.amberAccent.opacity(0.5), lineWidth: 0.5))
                            .accessibilityLabel(NSLocalizedString("无匹配节点", comment: ""))
                        } else {
                            let pillText = count > 1
                                ? "\(searchMatchIndex + 1)/\(count) 个匹配"
                                : "\(count) 个匹配"
                            Text(pillText)
                                .font(DSFonts.jetBrainsMono(size: 11))
                                .foregroundColor(DSColor.inkMuted)
                                .padding(.horizontal, DSSpacing.md)
                                .padding(.vertical, 5)
                                .background(DSColor.glassLo)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(DSColor.glassRim, lineWidth: 0.5))
                                .accessibilityLabel("\(count) 个匹配结果")
                            if count > 1 {
                                Button {
                                    Haptics.soft()
                                    searchMatchIndex = (searchMatchIndex - 1 + matches.count) % matches.count
                                    let node = matches[searchMatchIndex]
                                    centerOn(node, in: simulationSize)
                                    pulseNode(node)
                                } label: {
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(DSColor.inkMuted)
                                        .frame(width: 28, height: 28)
                                        .background(DSColor.glassLo)
                                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DSColor.glassRim, lineWidth: 0.5))
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("上一个匹配")
                                Button {
                                    Haptics.soft()
                                    searchMatchIndex = (searchMatchIndex + 1) % matches.count
                                    let node = matches[searchMatchIndex]
                                    centerOn(node, in: simulationSize)
                                    pulseNode(node)
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(DSColor.inkMuted)
                                        .frame(width: 28, height: 28)
                                        .background(DSColor.glassLo)
                                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DSColor.glassRim, lineWidth: 0.5))
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("下一个匹配")
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
                            return
                        }
                        if count == 0 && lastZeroQuery != query {
                            lastZeroQuery = query
                            Haptics.warn()
                            if UIAccessibility.isVoiceOverRunning {
                                let msg = NSLocalizedString("无匹配节点", comment: "Graph search zero-match pill")
                                UIAccessibility.post(notification: .announcement, argument: msg)
                            }
                        } else if count > 0 {
                            lastZeroQuery = nil
                            if UIAccessibility.isVoiceOverRunning {
                                let msg = "\(count) 个匹配"
                                UIAccessibility.post(notification: .announcement, argument: msg)
                            }
                        }
                    }
                }

                if showFilters {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: DSSpacing.sm) {
                            Text("开始")
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
                                Button("清除") { viewModel.filterStartDate = nil }
                                    .font(DSFonts.inter(size: 11))
                                    .foregroundColor(DSColor.amberAccent)
                                    .frame(minHeight: 44)
                            }
                        }
                        HStack(spacing: DSSpacing.sm) {
                            Text("结束")
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
                                Button("清除") { viewModel.filterEndDate = nil }
                                    .font(DSFonts.inter(size: 11))
                                    .foregroundColor(DSColor.amberAccent)
                                    .frame(minHeight: 44)
                            }
                        }
                    }
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.vertical, DSSpacing.md)
                    .background(DSColor.glassLo)
                    .background(.ultraThinMaterial)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Rectangle()
                    .fill(DSColor.glassRim)
                    .frame(height: 0.5)
            }
            .background(DSColor.bgWarm)

            // MARK: Graph area — warm canvas
            ZStack {
                DSColor.bgWarm.ignoresSafeArea()

                if viewModel.isLoading {
                    ProgressView()
                        .tint(DSColor.onSurfaceVariant)
                } else if visibleNodes.isEmpty {
                    emptyState
                } else {
                    graphCanvas
                    legend
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.load()
        }
        .onChange(of: viewModel.nodes.count) { _ in
            if !viewModel.nodes.isEmpty { startSimulation() }
        }
        .onDisappear {
            stopSimulation()
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

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.nodes.isEmpty {
            EmptyStateView.graphEmpty {
                nav.navigate(to: .today)
            }
        } else {
            EmptyStateView.graphNoMatches {
                Haptics.tapConfirm()
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewModel.searchQuery = ""
                    viewModel.filterStartDate = nil
                    viewModel.filterEndDate = nil
                    hiddenTypes = []
                }
            }
        }
    }

    private var clearFiltersButton: some View {
        Button {
            Haptics.tapConfirm()
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.searchQuery = ""
                viewModel.filterStartDate = nil
                viewModel.filterEndDate = nil
            }
        } label: {
            Text("清除筛选")
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
        .accessibilityLabel("清除筛选")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Accessibility Helpers

    private func localizedEntityTypeName(_ entityType: String) -> String {
        switch entityType {
        case "places":  return "地点"
        case "people":  return "人物"
        default:        return "主题"
        }
    }

    private func openNode(_ node: GraphNode) {
        Haptics.tapConfirm()
        selectedNode = node
        tapPulseNodeID = node.id
        tapPulseProgress = 0
        tapPulseGeneration += 1
        let gen = tapPulseGeneration
        withAnimation(.easeOut(duration: 0.35)) {
            tapPulseProgress = 1
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if tapPulseGeneration == gen { tapPulseNodeID = nil }
        }
        showEntityPage = true
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
        withAnimation(.easeOut(duration: 0.35)) {
            tapPulseProgress = 1
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if tapPulseGeneration == gen { tapPulseNodeID = nil }
        }
    }

    // MARK: - Graph Canvas

    private var graphCanvas: some View {
        GeometryReader { geo in
            let size = geo.size
            let filteredIDs = Set(visibleNodes.map { $0.id })

            ZStack {
                Canvas { ctx, _ in
                    let nodePos = Dictionary(uniqueKeysWithValues: viewModel.nodes.map { ($0.id, $0.position) })

                    // Draw edges (visible nodes only)
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
                        ctx.stroke(path, with: .color(DSColor.inkFaint.opacity(0.7)), lineWidth: 1)
                    }

                    // Draw all nodes (dim non-matching); radius scales with occurrence count
                    for node in viewModel.nodes {
                        let inFilter = filteredIDs.contains(node.id)
                        let x = node.position.x * scale + offset.width + size.width / 2
                        let y = node.position.y * scale + offset.height + size.height / 2
                        let r = node.displayRadius * scale
                        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                        let alpha: CGFloat = inFilter ? 1.0 : 0.2
                        ctx.fill(Path(ellipseIn: rect), with: .color(node.color.opacity(alpha)))
                        ctx.stroke(Path(ellipseIn: rect), with: .color(node.color.opacity(0.6 * alpha)), lineWidth: 1.5 * scale)
                    }
                }
                .frame(width: size.width, height: size.height)
                .accessibilityHidden(true)
                .onAppear { simulationSize = size }
                .onChange(of: size) { simulationSize = $0 }
                .onChange(of: viewModel.searchQuery) { query in
                    searchMatchIndex = 0
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

                // Node labels (filtered only) — hidden from VoiceOver; the tap target below announces the name
                ForEach(visibleNodes) { node in
                    let x = node.position.x * scale + offset.width + size.width / 2
                    let y = node.position.y * scale + offset.height + size.height / 2
                    let isSearchMatch = !viewModel.searchQuery.isEmpty
                        && node.name.localizedCaseInsensitiveContains(viewModel.searchQuery)
                    Text(node.name)
                        .font(.custom("JetBrainsMono-Regular", fixedSize: max(8, 10 * scale)))
                        .foregroundColor(isSearchMatch ? DSColor.amberDeep : DSColor.inkPrimary)
                        .fontWeight(isSearchMatch ? .bold : .regular)
                        .lineLimit(1)
                        .fixedSize()
                        .position(x: x, y: y + node.displayRadius * scale + 10 * scale)
                        .accessibilityHidden(true)
                }

                // Invisible tap targets for each filtered node
                ForEach(visibleNodes) { node in
                    let x = node.position.x * scale + offset.width + size.width / 2
                    let y = node.position.y * scale + offset.height + size.height / 2
                    let r = max(node.displayRadius * scale, 22)
                    Circle()
                        .fill(Color.clear)
                        .frame(width: r * 2, height: r * 2)
                        .contentShape(Circle())
                        .position(x: x, y: y)
                        .onTapGesture(count: 2) { focusNode(node, in: size) }
                        .onTapGesture { openNode(node) }
                        .accessibilityElement()
                        .accessibilityLabel(node.name)
                        .accessibilityValue(localizedEntityTypeName(node.entityType))
                        .accessibilityHint("打开实体页面")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { openNode(node) }
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

                if isTransformed { recenterButton }
                if scale != 1.0 { zoomIndicator }
            }
            .onTapGesture(count: 2) {
                guard isTransformed else { return }
                Haptics.tapConfirm()
                resetTransform()
            }
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in scale = max(0.3, min(5.0, lastScale * value)) }
                        .onEnded { _ in lastScale = scale },
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in lastOffset = offset }
                )
            )
        }
    }

    // MARK: - Legend

    private static let legendTypes: [(type: String, color: Color, label: String)] = [
        ("places", DSColor.amberDeep,   "地点"),
        ("people", DSColor.inkMuted,    "人物"),
        ("themes", DSColor.amberAccent, "主题"),
    ]

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.legendTypes, id: \.type) { entry in
                let count = viewModel.filteredNodes.filter { $0.entityType == entry.type }.count
                let isHidden = hiddenTypes.contains(entry.type)
                legendRow(type: entry.type, color: entry.color, label: entry.label, count: count, isHidden: isHidden)
            }
        }
        .padding(DSSpacing.md)
        .liquidGlassCard(cornerRadius: DSRadius.md, tone: .hi)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(DSSpacing.lg)
    }

    private func resetTransform() {
        withAnimation(Motion.spring) {
            scale = 1.0; lastScale = 1.0
            offset = .zero; lastOffset = .zero
        }
    }

    private var recenterButton: some View {
        Button {
            Haptics.tapConfirm()
            resetTransform()
        } label: {
            Image(systemName: "scope")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(DSColor.inkPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .liquidGlassCard(cornerRadius: DSRadius.md, tone: .hi)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(DSSpacing.lg)
        .accessibilityLabel("Recenter graph")
        .transition(.opacity.combined(with: .scale))
        .animation(Motion.spring, value: isTransformed)
    }

    private var zoomIndicator: some View {
        Text("\(Int(scale * 100))%")
            .font(DSFonts.jetBrainsMono(size: 10))
            .foregroundColor(DSColor.inkPrimary)
            .padding(.horizontal, DSSpacing.sm)
            .padding(.vertical, 6)
            .liquidGlassCard(cornerRadius: DSRadius.md, tone: .hi)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(DSSpacing.lg)
            .padding(.bottom, 56)
            .accessibilityLabel("Zoom level")
            .accessibilityValue("\(Int(scale * 100)) percent")
            .transition(.opacity.combined(with: .scale))
            .animation(reduceMotion ? .default.speed(0) : Motion.spring, value: scale)
    }

    private func legendRow(type: String, color: Color, label: String, count: Int, isHidden: Bool) -> some View {
        Button {
            Haptics.soft()
            withAnimation(Motion.spring) {
                if isHidden {
                    hiddenTypes.remove(type)
                } else {
                    hiddenTypes.insert(type)
                }
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
        .accessibilityLabel("\(label), \(count)个节点")
        .accessibilityValue(isHidden ? "已隐藏" : "已显示")
        .accessibilityAddTraits(.isButton)
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
        withAnimation(.easeOut(duration: 0.35)) {
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

    // MARK: - Helpers

    private func typeLabel(_ entityType: String) -> String {
        switch entityType {
        case "places":  return "地点"
        case "people":  return "人物"
        case "themes":  return "主题"
        default:        return entityType
        }
    }

    // MARK: - Simulation

    private func startSimulation() {
        simulationSteps = 0
        simulationTimer?.invalidate()
        simulationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in
                guard self.simulationSteps < self.maxSimSteps else {
                    self.stopSimulation()
                    return
                }
                self.viewModel.simulationStep(size: self.simulationSize)
                self.simulationSteps += 1
            }
        }
    }

    private func stopSimulation() {
        simulationTimer?.invalidate()
        simulationTimer = nil
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
