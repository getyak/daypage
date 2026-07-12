import Testing
import DayPageServices
@testable import DayPage

@Suite("GraphViewModel filter cache")
@MainActor
struct GraphViewModelFilterCacheTests {

    private func makeVM(nodes: [GraphNode]) -> GraphViewModel {
        let vm = GraphViewModel()
        vm.nodes = nodes
        return vm
    }

    private func makeNode(id: String, name: String, type: String = "themes",
                          dates: Set<String> = []) -> GraphNode {
        var n = GraphNode(id: id, name: name, entityType: type,
                          position: .zero)
        n.dates = dates
        return n
    }

    // MARK: - membership stability across simulationStep

    @Test("filteredNodes membership is unchanged after a simulationStep call")
    func membershipStableAfterSimStep() {
        let vm = makeVM(nodes: [
            makeNode(id: "themes/a", name: "Alpha"),
            makeNode(id: "themes/b", name: "Beta"),
            makeNode(id: "people/c", name: "Carol"),
        ])
        let before = Set(vm.filteredNodes.map { $0.id })
        vm.simulationStep(size: CGSize(width: 400, height: 800))
        let after = Set(vm.filteredNodes.map { $0.id })
        #expect(before == after)
    }

    // MARK: - cache invalidation on searchQuery

    @Test("filteredNodes reflects new searchQuery after mutation")
    func cacheInvalidatedOnSearchQuery() {
        let vm = makeVM(nodes: [
            makeNode(id: "themes/alpha", name: "Alpha"),
            makeNode(id: "themes/beta",  name: "Beta"),
        ])
        // prime cache
        let allIDs = Set(vm.filteredNodes.map { $0.id })
        #expect(allIDs.count == 2)

        vm.searchQuery = "Alpha"
        let filtered = vm.filteredNodes
        #expect(filtered.count == 1)
        #expect(filtered[0].name == "Alpha")
    }

    @Test("clearing searchQuery restores all nodes")
    func cacheClearedOnQueryReset() {
        let vm = makeVM(nodes: [
            makeNode(id: "themes/alpha", name: "Alpha"),
            makeNode(id: "themes/beta",  name: "Beta"),
        ])
        vm.searchQuery = "Alpha"
        #expect(vm.filteredNodes.count == 1)
        vm.searchQuery = ""
        #expect(vm.filteredNodes.count == 2)
    }

    // MARK: - simulationStep does not change cached result identity

    @Test("filteredNodes returns same results on repeated access without mutation")
    func cacheReturnsSameResultWithoutMutation() {
        let vm = makeVM(nodes: [
            makeNode(id: "themes/a", name: "A"),
            makeNode(id: "places/b", name: "B"),
        ])
        let first  = vm.filteredNodes.map { $0.id }
        let second = vm.filteredNodes.map { $0.id }
        #expect(first == second)
    }
}

// MARK: - #828 focus state machine + weighted edges

@Suite("GraphViewModel focus & edge weight (#828)")
@MainActor
struct GraphFocusAndWeightTests {

    private func makeNode(id: String, name: String, type: String = "themes") -> GraphNode {
        GraphNode(id: id, name: name, entityType: type, position: .zero)
    }

    private func makeVM(nodes: [GraphNode], edges: [GraphEdge] = []) -> GraphViewModel {
        let vm = GraphViewModel()
        vm.nodes = nodes
        vm.edges = edges
        return vm
    }

    // MARK: buildWeightedEdges — day-based co-occurrence semantics

    @Test("a pair earns at most +1 weight per day, even when wikilinked twice in one file")
    func weightDedupesWithinOneDay() {
        let edges = GraphViewModel.buildWeightedEdges(idsPerDay: [
            ["themes/a", "places/b", "themes/a", "places/b"],   // day 1 — a↔b mentioned twice
            ["themes/a", "places/b"],                           // day 2
            ["places/b", "people/c"],                           // day 3
        ])
        let byID = Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0.weight) })
        #expect(byID["places/b↔themes/a"] == 2)
        #expect(byID["people/c↔places/b"] == 1)
        #expect(edges.count == 2)
    }

    @Test("duplicate wikilinks to the same entity never create a self-loop")
    func noSelfLoops() {
        let edges = GraphViewModel.buildWeightedEdges(idsPerDay: [
            ["themes/a", "themes/a"],
        ])
        #expect(edges.isEmpty)
    }

    @Test("edge output order is stable (sorted pair keys) across rebuilds")
    func stableEdgeOrder() {
        let days = [["themes/z", "themes/a"], ["themes/m", "themes/a"]]
        let first = GraphViewModel.buildWeightedEdges(idsPerDay: days).map { $0.id }
        let second = GraphViewModel.buildWeightedEdges(idsPerDay: days).map { $0.id }
        #expect(first == second)
        #expect(first == first.sorted())
    }

    // MARK: focus state machine

    @Test("setFocus exposes the focused node and its one-hop neighborhood")
    func focusNeighborhood() {
        let vm = makeVM(
            nodes: [makeNode(id: "themes/a", name: "A"),
                    makeNode(id: "places/b", name: "B"),
                    makeNode(id: "people/c", name: "C")],
            edges: [GraphEdge(id: "e1", sourceID: "themes/a", targetID: "places/b", weight: 1)]
        )
        vm.setFocus("themes/a")
        #expect(vm.focusedNode?.id == "themes/a")
        #expect(vm.focusedNeighborIDs == ["places/b"])
        vm.setFocus(nil)
        #expect(vm.focusedNode == nil)
        #expect(vm.focusedNeighborIDs.isEmpty)
    }

    @Test("exitFocusIfFilteredOut drops focus only when the node leaves the visible set")
    func focusFollowsFiltering() {
        let vm = makeVM(nodes: [makeNode(id: "themes/a", name: "A"),
                                makeNode(id: "places/b", name: "B")])
        vm.setFocus("themes/a")
        vm.exitFocusIfFilteredOut(visibleIDs: ["themes/a", "places/b"])
        #expect(vm.focusedNodeID == "themes/a")
        vm.exitFocusIfFilteredOut(visibleIDs: ["places/b"])
        #expect(vm.focusedNodeID == nil)
    }

    // MARK: three-way classification color source

    @Test("color(for:) yields three distinct hues plus a themes fallback")
    func colorTriad() {
        let people = GraphNode.color(for: "people")
        let places = GraphNode.color(for: "places")
        let themes = GraphNode.color(for: "themes")
        #expect(people != places)
        #expect(places != themes)
        #expect(people != themes)
        #expect(GraphNode.color(for: "unknown") == themes)
    }
}
