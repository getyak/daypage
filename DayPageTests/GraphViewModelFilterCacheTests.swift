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
