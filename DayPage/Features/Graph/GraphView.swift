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

    private let nodeRadius: CGFloat = 16
    private let maxSimSteps = 200

    var body: some View {
        ZStack {
            DSColor.background.ignoresSafeArea()

            if viewModel.isLoading {
                ProgressView()
                    .tint(DSColor.onSurfaceVariant)
            } else if viewModel.nodes.isEmpty {
                emptyState
            } else {
                graphCanvas
                legend
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.load()
        }
        .onChange(of: viewModel.nodes.count) { _ in
            if !viewModel.nodes.isEmpty {
                startSimulation()
            }
        }
        .onDisappear {
            stopSimulation()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48, weight: .thin))
                .foregroundColor(DSColor.outlineVariant)
            Text("尚无知识图谱")
                .displayLGStyle()
                .foregroundColor(DSColor.outlineVariant)
            Text("编译日记后，实体节点将在此出现")
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
            ZStack {
                Canvas { ctx, _ in
                    // Draw edges
                    let nodePos = Dictionary(uniqueKeysWithValues: viewModel.nodes.map { ($0.id, $0.position) })
                    for edge in viewModel.edges {
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

                    // Draw nodes
                    for node in viewModel.nodes {
                        let x = node.position.x * scale + offset.width + size.width / 2
                        let y = node.position.y * scale + offset.height + size.height / 2
                        let r = nodeRadius * scale
                        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                        ctx.fill(Path(ellipseIn: rect), with: .color(node.color))
                        ctx.stroke(Path(ellipseIn: rect), with: .color(node.color.opacity(0.6)), lineWidth: 1.5 * scale)
                    }
                }
                .frame(width: size.width, height: size.height)
                .onAppear { simulationSize = size }
                .onChange(of: size) { simulationSize = $0 }

                // Node labels overlay
                ForEach(viewModel.nodes) { node in
                    let x = node.position.x * scale + offset.width + size.width / 2
                    let y = node.position.y * scale + offset.height + size.height / 2
                    Text(node.name)
                        .font(.custom("JetBrainsMono-Regular", fixedSize: max(8, 10 * scale)))
                        .foregroundColor(DSColor.onSurface)
                        .lineLimit(1)
                        .fixedSize()
                        .position(x: x, y: y + nodeRadius * scale + 10 * scale)
                }
            }
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(0.3, min(5.0, lastScale * value))
                        }
                        .onEnded { _ in
                            lastScale = scale
                        },
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
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
