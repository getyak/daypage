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

    // Filter state
    @State private var showFilters: Bool = false

    private let nodeRadius: CGFloat = 16
    private let maxSimSteps = 200

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Header bar
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    // Search field
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundColor(DSColor.onSurfaceVariant)
                        TextField("搜索节点...", text: $viewModel.searchQuery)
                            .font(.custom("JetBrainsMono-Regular", fixedSize: 12))
                            .foregroundColor(DSColor.onSurface)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(DSColor.surfaceContainerLow)

                    // Filter toggle
                    Button {
                        withAnimation(.easeInOut) { showFilters.toggle() }
                    } label: {
                        Image(systemName: showFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .font(.system(size: 20))
                            .foregroundColor(hasActiveFilter ? DSColor.primary : DSColor.onSurfaceVariant)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                // Date range filter panel
                if showFilters {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("开始")
                                .font(.custom("JetBrainsMono-Regular", fixedSize: 11))
                                .foregroundColor(DSColor.onSurfaceVariant)
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
                                    .font(.custom("Inter-Regular", size: 11))
                                    .foregroundColor(DSColor.onSurfaceVariant)
                            }
                        }
                        HStack(spacing: 8) {
                            Text("结束")
                                .font(.custom("JetBrainsMono-Regular", fixedSize: 11))
                                .foregroundColor(DSColor.onSurfaceVariant)
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
                                    .font(.custom("Inter-Regular", size: 11))
                                    .foregroundColor(DSColor.onSurfaceVariant)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .background(DSColor.surfaceContainerLow)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider().background(DSColor.outline)
            }
            .background(DSColor.surfaceContainerLow)

            // MARK: Graph area
            ZStack {
                DSColor.background.ignoresSafeArea()

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

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48, weight: .thin))
                .foregroundColor(DSColor.outlineVariant)
            Text(viewModel.nodes.isEmpty ? "尚无知识图谱" : "无匹配节点")
                .displayLGStyle()
                .foregroundColor(DSColor.outlineVariant)
            Text(viewModel.nodes.isEmpty ? "编译日记后，实体节点将在此出现" : "调整搜索或筛选条件以查看节点")
                .bodySMStyle()
                .foregroundColor(DSColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
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
                        ctx.stroke(path, with: .color(DSColor.outlineVariant.opacity(0.5)), lineWidth: 1)
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
                        .foregroundColor(isSearchMatch ? DSColor.primary : DSColor.onSurface)
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
                            selectedNode = node
                            showEntityPage = true
                        }
                }
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
            legendRow(color: DSColor.amberArchival, label: "地点")
            legendRow(color: DSColor.secondary, label: "人物")
            legendRow(color: DSColor.tertiary, label: "主题")
        }
        .padding(10)
        .background(DSColor.surfaceContainer.opacity(0.9))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(16)
    }

    private func legendRow(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.custom("JetBrainsMono-Regular", fixedSize: 10))
                .foregroundColor(DSColor.onSurface)
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
