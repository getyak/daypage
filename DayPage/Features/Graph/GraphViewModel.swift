import Foundation
import SwiftUI

// MARK: - GraphNode

struct GraphNode: Identifiable {
    let id: String          // "places/joma-coffee"
    let name: String
    let entityType: String  // "places" | "people" | "themes"
    var position: CGPoint
    var velocity: CGPoint = .zero
    var dates: Set<String> = []   // YYYY-MM-DD dates this entity appears in
    var occurrenceCount: Int = 0  // parsed from entity page frontmatter

    var color: Color {
        switch entityType {
        case "people":  return DSColor.secondary
        case "places":  return DSColor.amberArchival
        default:        return DSColor.tertiary
        }
    }

    /// Visual radius scales with occurrence count: base 16pt, +2pt per 5 mentions, capped at 32pt.
    var displayRadius: CGFloat {
        let extra = CGFloat(min(occurrenceCount / 5, 8)) * 2
        return 16 + extra
    }

    /// Parses slug from the node id ("places/joma-coffee" → "joma-coffee")
    var entitySlug: String { id.components(separatedBy: "/").dropFirst().joined(separator: "/") }
}

// MARK: - GraphEdge

struct GraphEdge: Identifiable {
    let id: String
    let sourceID: String
    let targetID: String
}

// MARK: - GraphViewModel

@MainActor
final class GraphViewModel: ObservableObject {

    @Published var nodes: [GraphNode] = []
    @Published var edges: [GraphEdge] = []
    @Published var isLoading: Bool = false
    @Published var hasCompiledDailies: Bool = false

    // MARK: - Filter State
    // searchInput: TextField binding, changes per keystroke.
    // searchQuery: debounced output observed by filtering + canvas redraw.
    // 200ms debounce keeps O(n) filter + full canvas redraw off the keystroke path on big graphs.
    @Published var searchInput: String = "" { didSet { scheduleSearchDebounce() } }
    @Published var searchQuery: String = "" { didSet { _filteredNodes = nil } }
    @Published var filterStartDate: Date? = nil { didSet { _filteredNodes = nil } }
    @Published var filterEndDate: Date? = nil { didSet { _filteredNodes = nil } }

    private var _filteredNodes: [GraphNode]? = nil
    private var searchDebounceTask: Task<Void, Never>? = nil

    private func scheduleSearchDebounce() {
        searchDebounceTask?.cancel()
        // Empty input flushes immediately so the clear button feels instant.
        if searchInput.isEmpty {
            if !searchQuery.isEmpty { searchQuery = "" }
            return
        }
        let snapshot = searchInput
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if self.searchQuery != snapshot { self.searchQuery = snapshot }
            }
        }
    }

    /// Nodes after applying search and date filters. Result is cached and
    /// invalidated only when nodes, searchQuery, or date filters change.
    var filteredNodes: [GraphNode] {
        if let cached = _filteredNodes { return cached }
        let result = computeFilteredNodes()
        _filteredNodes = result
        return result
    }

    private func computeFilteredNodes() -> [GraphNode] {
        nodes.filter { node in
            let matchesSearch = searchQuery.isEmpty
                || node.name.localizedCaseInsensitiveContains(searchQuery)
            let matchesDate: Bool = {
                guard filterStartDate != nil || filterEndDate != nil else { return true }
                let fmt = dateFormatter
                if let start = filterStartDate {
                    let startStr = fmt.string(from: start)
                    if !node.dates.contains(where: { $0 >= startStr }) { return false }
                }
                if let end = filterEndDate {
                    let endStr = fmt.string(from: end)
                    if !node.dates.contains(where: { $0 <= endStr }) { return false }
                }
                return true
            }()
            return matchesSearch && matchesDate
        }
    }

    /// Live count of nodes matching the current search query.
    var searchMatchCount: Int { searchQuery.isEmpty ? 0 : filteredNodes.count }

    /// Edges where both endpoints are in filteredNodes.
    var filteredEdges: [GraphEdge] {
        let ids = Set(filteredNodes.map { $0.id })
        return edges.filter { ids.contains($0.sourceID) && ids.contains($0.targetID) }
    }

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Scan & Build Graph

    func load() {
        guard !isLoading else { return }
        isLoading = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.buildGraph()
            await MainActor.run { [weak self] in
                self?.nodes = result.nodes
                self?._filteredNodes = nil
                self?.edges = result.edges
                self?.hasCompiledDailies = result.hasCompiledDailies
                self?.isLoading = false
            }
        }
    }

    private struct BuildResult {
        let nodes: [GraphNode]
        let edges: [GraphEdge]
        let hasCompiledDailies: Bool
    }

    nonisolated private static func buildGraph() -> BuildResult {
        let fm = FileManager.default
        let vaultURL = VaultInitializer.vaultURL
        let wikiURL = vaultURL.appendingPathComponent("wiki", isDirectory: true)
        let dailyURL = wikiURL.appendingPathComponent("daily", isDirectory: true)

        var entityMap: [String: (name: String, type: String)] = [:]
        var entityDates: [String: Set<String>] = [:]
        var edgeSet: Set<String> = []
        var rawEdges: [GraphEdge] = []

        // Scan all Daily Page files for [[wiki/type/slug|Name]] wikilinks
        let dailyFiles: [URL]
        do { dailyFiles = try fm.contentsOfDirectory(at: dailyURL, includingPropertiesForKeys: nil) }
        catch { dailyFiles = [] }
        let hasCompiledDailies = dailyFiles.contains { $0.pathExtension == "md" }
        for fileURL in dailyFiles where fileURL.pathExtension == "md" {
            let content: String
            do { content = try String(contentsOf: fileURL, encoding: .utf8) }
            catch { continue }
            let dateStr = fileURL.deletingPathExtension().lastPathComponent
            let refs = extractWikilinks(from: content)

            // Build edges between entities mentioned on the same day
            let ids = refs.map { "\($0.type)/\($0.slug)" }
            for i in 0..<ids.count {
                entityDates[ids[i], default: []].insert(dateStr)
                for j in (i+1)..<ids.count {
                    let key = [ids[i], ids[j]].sorted().joined(separator: "↔")
                    if !edgeSet.contains(key) {
                        edgeSet.insert(key)
                        rawEdges.append(GraphEdge(id: key, sourceID: ids[i], targetID: ids[j]))
                    }
                }
                if entityMap[ids[i]] == nil {
                    entityMap[ids[i]] = (name: refs[i].name, type: refs[i].type)
                }
            }
        }

        // Also scan entity page directories for any entities not yet in map
        for entityType in ["places", "people", "themes"] {
            let typeURL = wikiURL.appendingPathComponent(entityType, isDirectory: true)
            let files: [URL]
            do { files = try fm.contentsOfDirectory(at: typeURL, includingPropertiesForKeys: nil) }
            catch { files = [] }
            for fileURL in files where fileURL.pathExtension == "md" {
                let slug = fileURL.deletingPathExtension().lastPathComponent
                let key = "\(entityType)/\(slug)"
                if entityMap[key] == nil {
                    let name: String
                    if let fileContent = (try? String(contentsOf: fileURL, encoding: .utf8)),
                       let parsed = parseName(from: fileContent) {
                        name = parsed
                    } else {
                        name = slug.replacingOccurrences(of: "-", with: " ").capitalized
                    }
                    entityMap[key] = (name: name, type: entityType)
                }
            }
        }

        // Parse occurrence counts from entity page frontmatter
        var occurrenceCounts: [String: Int] = [:]
        for entityType in ["places", "people", "themes"] {
            let typeURL = wikiURL.appendingPathComponent(entityType, isDirectory: true)
            let files: [URL]
            do { files = try fm.contentsOfDirectory(at: typeURL, includingPropertiesForKeys: nil) }
            catch { files = [] }
            for fileURL in files where fileURL.pathExtension == "md" {
                let slug = fileURL.deletingPathExtension().lastPathComponent
                let key = "\(entityType)/\(slug)"
                if let content = try? String(contentsOf: fileURL, encoding: .utf8),
                   let countStr = extractFrontmatterField("occurrence_count", from: content),
                   let count = Int(countStr) {
                    occurrenceCounts[key] = count
                }
            }
        }

        // Place nodes in a circle initially
        let count = entityMap.count
        let radius: Double = count > 1 ? 180 : 0
        var nodes: [GraphNode] = []
        var idx = 0
        for (id, info) in entityMap {
            let angle = count > 0 ? (Double(idx) / Double(count)) * 2 * .pi : 0
            let pos = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            var node = GraphNode(id: id, name: info.name, entityType: info.type, position: pos)
            node.dates = entityDates[id] ?? []
            // Use occurrence_count from entity page if available, otherwise fall back to date count
            node.occurrenceCount = occurrenceCounts[id] ?? node.dates.count
            nodes.append(node)
            idx += 1
        }

        return BuildResult(nodes: nodes, edges: rawEdges, hasCompiledDailies: hasCompiledDailies)
    }

    // MARK: - Wikilink Extraction

    private struct WikiRef {
        let type: String
        let slug: String
        let name: String
    }

    // Cached once at file scope — NSRegularExpression compilation is expensive
    // and the pattern is invariant. Previously rebuilt on every Daily Page scan,
    // which on a vault with hundreds of dailies meant hundreds of pattern compiles
    // per graph load.
    nonisolated private static let wikilinkRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\[\[wiki/(places|people|themes)/([^\]|]+)(?:\|([^\]]+))?\]\]"#
    )

    nonisolated private static func extractWikilinks(from content: String) -> [WikiRef] {
        // Matches [[wiki/places/slug|Name]] or [[wiki/places/slug]]
        var results: [WikiRef] = []
        guard let regex = wikilinkRegex else { return [] }
        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let type = nsContent.substring(with: match.range(at: 1))
            let slug = nsContent.substring(with: match.range(at: 2))
            let name: String
            if match.range(at: 3).location != NSNotFound {
                name = nsContent.substring(with: match.range(at: 3))
            } else {
                name = slug.replacingOccurrences(of: "-", with: " ").capitalized
            }
            results.append(WikiRef(type: type, slug: slug, name: name))
        }
        return results
    }

    nonisolated private static func extractFrontmatterField(_ field: String, from content: String) -> String? {
        var sawOpener = false
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if sawOpener { break }
                sawOpener = true
                continue
            }
            if trimmed.hasPrefix("\(field):") {
                let val = String(trimmed.dropFirst("\(field):".count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return val.isEmpty ? nil : val
            }
        }
        return nil
    }

    nonisolated private static func parseName(from content: String) -> String? {
        // Walks the frontmatter only — stops at the closing `---`. The previous
        // implementation tried to detect the closer with `!content.hasPrefix("---")`,
        // which is always false for well-formed frontmatter (file starts with `---`),
        // so the loop kept scanning the entire body. Track the frontmatter boundary
        // explicitly instead.
        var sawOpener = false
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if sawOpener { break }  // closing fence — name: must have appeared by now
                sawOpener = true
                continue
            }
            if trimmed.hasPrefix("name:") {
                let val = String(trimmed.dropFirst("name:".count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return val.isEmpty ? nil : val
            }
        }
        return nil
    }

    // MARK: - Force-Directed Layout Step

    /// True while a background tick is in flight. Used to coalesce concurrent
    /// requests — without it, two SwiftUI frame ticks could each launch a
    /// detached task and the slower one would overwrite the newer state.
    /// Issue #27.
    private var simulationInFlight = false

    /// Public entry point invoked from GraphView's TimelineView tick. With
    /// up to ~200 nodes the work happens inline on the main actor (cheap
    /// enough that hopping off-actor is more overhead than it saves). Past
    /// that threshold the O(n²) loop is moved off-actor and we apply the
    /// result back on the main actor in one `assign`.
    func simulationStep(size: CGSize) {
        guard nodes.count > 1 else { return }
        // Index-keyed arrays are 5-10× faster than the original Dictionary
        // because force lookups become O(1) pointer offsets. Snapshot the
        // mutable state into compact arrays before computing.
        let snapshotPositions = nodes.map { $0.position }
        let snapshotVelocities = nodes.map { $0.velocity }
        let nodeIndex: [String: Int] = Dictionary(
            uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) }
        )
        var edgeIndices: [(Int, Int)] = []
        edgeIndices.reserveCapacity(edges.count)
        for edge in edges {
            guard let si = nodeIndex[edge.sourceID],
                  let ti = nodeIndex[edge.targetID] else { continue }
            edgeIndices.append((si, ti))
        }

        if nodes.count <= 200 {
            // Inline path — main-actor overhead < detached-task overhead at
            // this size; the algorithm still completes in well under a frame.
            let (newPositions, newVelocities) = Self.computeStep(
                positions: snapshotPositions,
                velocities: snapshotVelocities,
                edges: edgeIndices,
                size: size
            )
            applyStep(positions: newPositions, velocities: newVelocities)
            return
        }

        // Large graph — offload the O(n²) repulsion loop. Drop overlapping
        // ticks so the simulation never piles up behind the main actor.
        if simulationInFlight { return }
        simulationInFlight = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let (p, v) = Self.computeStep(
                positions: snapshotPositions,
                velocities: snapshotVelocities,
                edges: edgeIndices,
                size: size
            )
            await MainActor.run {
                guard let self = self else { return }
                self.applyStep(positions: p, velocities: v)
                self.simulationInFlight = false
            }
        }
    }

    /// Pure layout tick — no actor isolation, no @Published reads. Takes
    /// the current positions/velocities + edges and returns the next
    /// positions/velocities. Same physics as the original — repulsion
    /// between all pairs, edge attraction, gravity to centre, damped
    /// Verlet integration. Extracted so the off-actor path is a single
    /// function call, not a tangle of captures.
    nonisolated static func computeStep(
        positions: [CGPoint],
        velocities: [CGPoint],
        edges: [(Int, Int)],
        size: CGSize
    ) -> ([CGPoint], [CGPoint]) {
        let n = positions.count
        let repulsion: Double = 6000
        let attraction: Double = 0.04
        let damping: Double = 0.85
        let dt: Double = 0.5
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        var forces = [CGPoint](repeating: .zero, count: n)

        // Repulsion between all node pairs (O(n²); the dominant cost).
        for i in 0..<n {
            let pi = positions[i]
            for j in (i + 1)..<n {
                let pj = positions[j]
                let dx = pj.x - pi.x
                let dy = pj.y - pi.y
                let dist = max(sqrt(dx * dx + dy * dy), 1)
                let force = repulsion / (dist * dist)
                let fx = (dx / dist) * force
                let fy = (dy / dist) * force
                forces[i].x -= fx; forces[i].y -= fy
                forces[j].x += fx; forces[j].y += fy
            }
        }

        // Attraction along edges (O(e); cheap once indices are pre-resolved).
        for (si, ti) in edges {
            let ps = positions[si]
            let pt = positions[ti]
            let dx = pt.x - ps.x
            let dy = pt.y - ps.y
            let dist = max(sqrt(dx * dx + dy * dy), 1)
            let force = attraction * dist
            let fx = (dx / dist) * force
            let fy = (dy / dist) * force
            forces[si].x += fx; forces[si].y += fy
            forces[ti].x -= fx; forces[ti].y -= fy
        }

        // Gravity toward center.
        for i in 0..<n {
            forces[i].x += (center.x - positions[i].x) * 0.005
            forces[i].y += (center.y - positions[i].y) * 0.005
        }

        // Damped Verlet integration.
        var newPositions = positions
        var newVelocities = velocities
        for i in 0..<n {
            var v = newVelocities[i]
            let f = forces[i]
            v.x = (v.x + f.x * dt) * damping
            v.y = (v.y + f.y * dt) * damping
            newVelocities[i] = v
            newPositions[i].x += v.x * dt
            newPositions[i].y += v.y * dt
        }
        return (newPositions, newVelocities)
    }

    /// MainActor writeback. Length-mismatches (node count changed during
    /// an off-actor tick — e.g. a reload swapped in a different graph)
    /// are detected and the tick is discarded.
    private func applyStep(positions: [CGPoint], velocities: [CGPoint]) {
        guard nodes.count == positions.count else { return }
        for i in 0..<nodes.count {
            nodes[i].position = positions[i]
            nodes[i].velocity = velocities[i]
        }
    }
}
