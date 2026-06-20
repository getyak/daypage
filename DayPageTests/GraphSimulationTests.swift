import XCTest
import CoreGraphics
@testable import DayPage

/// Tests for the off-actor force-directed layout — issue #27.
///
/// We exercise the pure `computeStep` function directly so the tests stay
/// deterministic and don't depend on TimelineView ticks. The properties
/// pinned here are the ones that would silently regress if a future
/// contributor went back to the dictionary-keyed mutation style:
///
///   • Two isolated nodes drift APART (repulsion only).
///   • Two edge-linked nodes that start far apart drift TOGETHER on average.
///   • Center gravity nudges a lone outlier toward the centre.
///   • Determinism: the same inputs produce the same outputs.
final class GraphSimulationTests: XCTestCase {

    private let size = CGSize(width: 400, height: 400)

    // MARK: - Repulsion

    func testComputeStep_twoIsolatedNodes_repelFromEachOther() {
        let p0 = [CGPoint(x: 195, y: 200), CGPoint(x: 205, y: 200)]
        let v0 = [CGPoint.zero, CGPoint.zero]
        let initialGap = abs(p0[1].x - p0[0].x)

        let (p1, _) = GraphViewModel.computeStep(
            positions: p0, velocities: v0, edges: [], size: size
        )

        // After one step the nodes should be moving apart (not necessarily
        // visibly displaced past the gravity pull-back, but their velocity
        // along the connecting axis points outward).
        let newGap = abs(p1[1].x - p1[0].x)
        XCTAssertGreaterThan(newGap, initialGap,
            "Two close isolated nodes must repel (gap went from \(initialGap) → \(newGap))")
    }

    // MARK: - Edge attraction

    func testComputeStep_edgeLinkedFarNodes_attractTowardEachOther() {
        // Two nodes 300pt apart, linked by one edge. Edge attraction must
        // dominate repulsion at this distance, pulling them closer.
        let p0 = [CGPoint(x: 50, y: 200), CGPoint(x: 350, y: 200)]
        let v0 = [CGPoint.zero, CGPoint.zero]
        let initialGap = abs(p0[1].x - p0[0].x)

        let (p1, _) = GraphViewModel.computeStep(
            positions: p0, velocities: v0, edges: [(0, 1)], size: size
        )

        let newGap = abs(p1[1].x - p1[0].x)
        XCTAssertLessThan(newGap, initialGap,
            "Edge-linked far nodes must attract (gap went from \(initialGap) → \(newGap))")
    }

    // MARK: - Center gravity

    func testComputeStep_loneOutlier_isPulledTowardCenter() {
        let p0 = [CGPoint(x: 50, y: 50)]
        let v0 = [CGPoint.zero]
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let initialDist = hypot(center.x - p0[0].x, center.y - p0[0].y)

        // Single node has no pairs to repel, so only gravity applies.
        let (p1, _) = GraphViewModel.computeStep(
            positions: p0, velocities: v0, edges: [], size: size
        )

        // Single-node guard short-circuits in the public entry point but
        // the pure function still runs. Confirm gravity nudges it inward.
        let newDist = hypot(center.x - p1[0].x, center.y - p1[0].y)
        XCTAssertLessThan(newDist, initialDist,
            "Lone outlier must drift toward centre (dist \(initialDist) → \(newDist))")
    }

    // MARK: - Determinism

    func testComputeStep_isDeterministic() {
        let p0 = (0..<10).map { i in CGPoint(x: Double(i) * 30, y: 200) }
        let v0 = [CGPoint](repeating: .zero, count: 10)
        let edges: [(Int, Int)] = [(0, 1), (1, 2), (3, 7)]

        let (a, b) = GraphViewModel.computeStep(positions: p0, velocities: v0, edges: edges, size: size)
        let (c, d) = GraphViewModel.computeStep(positions: p0, velocities: v0, edges: edges, size: size)

        XCTAssertEqual(a.map { "\($0.x),\($0.y)" }, c.map { "\($0.x),\($0.y)" })
        XCTAssertEqual(b.map { "\($0.x),\($0.y)" }, d.map { "\($0.x),\($0.y)" })
    }

    // MARK: - Stability under load

    func testComputeStep_largeGraph_completesWithoutNaN() {
        // The dictionary-key version could produce NaN positions when a
        // node was momentarily co-located with another (dist=0 → divide by
        // zero). The index-array rewrite still uses max(dist, 1) so the
        // guarantee holds — but pin it.
        var p0: [CGPoint] = []
        for _ in 0..<300 {
            p0.append(CGPoint(x: 200, y: 200))
        }
        let v0 = [CGPoint](repeating: .zero, count: p0.count)

        let (p1, v1) = GraphViewModel.computeStep(
            positions: p0, velocities: v0, edges: [], size: size
        )

        for pt in p1 {
            XCTAssertFalse(pt.x.isNaN || pt.y.isNaN,
                "300 co-located nodes must not produce NaN positions")
        }
        for vel in v1 {
            XCTAssertFalse(vel.x.isNaN || vel.y.isNaN)
        }
    }
}
