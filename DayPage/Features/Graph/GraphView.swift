import SwiftUI

// MARK: - GraphView

struct GraphView: View {

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
                    }
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
                } else if viewModel.filteredNodes.isEmpty {
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

    private var isTransformed: Bool { scale != 1.0 || offset != .zero }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DSSpacing.md) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48, weight: .thin))
                .foregroundColor(DSColor.inkFaint)
            Text(viewModel.nodes.isEmpty ? "尚无知识图谱" : "无匹配节点")
                .font(DSType.h2)
                .foregroundColor(DSColor.inkMuted)
            Text(viewModel.nodes.isEmpty ? "编译日记后，实体节点将在此出现" : "调整搜索或筛选条件以查看节点")
                .bodySMStyle()
                .foregroundColor(DSColor.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DSSpacing.xl4)
        }
    }

    // MARK: - Graph Canvas

    private var graphCanvas: some View {
        GeometryReader { geo in
            let size = geo.size
            let filteredIDs = Set(viewModel.filteredNodes.map { $0.id })

            ZStack {
                Canvas { ctx, _ in
                    let nodePos = Dictionary(uniqueKeysWithValues: viewModel.nodes.map { ($0.id, $0.position) })

                    // Draw edges (filtered)
                    for edge in viewModel.filteredEdges {
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

                    // Draw all nodes (dim non-matching)
                    for node in viewModel.nodes {
                        let inFilter = filteredIDs.contains(node.id)
                        let x = node.position.x * scale + offset.width + size.width / 2
                        let y = node.position.y * scale + offset.height + size.height / 2
                        let r = nodeRadius * scale
                        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                        let alpha: CGFloat = inFilter ? 1.0 : 0.2
                        ctx.fill(Path(ellipseIn: rect), with: .color(node.color.opacity(alpha)))
                        ctx.stroke(Path(ellipseIn: rect), with: .color(node.color.opacity(0.6 * alpha)), lineWidth: 1.5 * scale)
                    }
                }
                .frame(width: size.width, height: size.height)
                .onAppear { simulationSize = size }
                .onChange(of: size) { simulationSize = $0 }

                // Node labels (filtered only)
                ForEach(viewModel.filteredNodes) { node in
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
                        .position(x: x, y: y + nodeRadius * scale + 10 * scale)
                }

                // Invisible tap targets for each filtered node
                ForEach(viewModel.filteredNodes) { node in
                    let x = node.position.x * scale + offset.width + size.width / 2
                    let y = node.position.y * scale + offset.height + size.height / 2
                    let r = max(nodeRadius * scale, 22)
                    Circle()
                        .fill(Color.clear)
                        .frame(width: r * 2, height: r * 2)
                        .contentShape(Circle())
                        .position(x: x, y: y)
                        .onTapGesture {
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
                }

                // Tap pulse ring — reads live position from the model so it tracks
                // the node even while the force-directed simulation is still running.
                if let id = tapPulseNodeID,
                   let pulseNode = viewModel.nodes.first(where: { $0.id == id }) {
                    let px = pulseNode.position.x * scale + offset.width + size.width / 2
                    let py = pulseNode.position.y * scale + offset.height + size.height / 2
                    let ringScale = 1.0 + tapPulseProgress   // 1.0 → 2.0
                    let diameter = nodeRadius * scale * 2 * ringScale
                    Circle()
                        .strokeBorder(pulseNode.color, lineWidth: 2)
                        .frame(width: diameter, height: diameter)
                        .opacity(Double(1 - tapPulseProgress))
                        .position(x: px, y: py)
                        .allowsHitTesting(false)
                }

                if isTransformed { recenterButton }
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

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            legendRow(color: DSColor.amberDeep, label: "地点")
            legendRow(color: DSColor.inkMuted, label: "人物")
            legendRow(color: DSColor.amberAccent, label: "主题")
        }
        .padding(DSSpacing.md)
        .liquidGlassCard(cornerRadius: DSRadius.md, tone: .hi)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(DSSpacing.lg)
    }

    private var recenterButton: some View {
        Button {
            Haptics.tapConfirm()
            withAnimation(Motion.spring) {
                scale = 1.0; lastScale = 1.0
                offset = .zero; lastOffset = .zero
            }
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

    private func legendRow(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(DSFonts.jetBrainsMono(size: 10))
                .foregroundColor(DSColor.inkPrimary)
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
