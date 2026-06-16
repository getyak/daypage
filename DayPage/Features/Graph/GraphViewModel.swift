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
    @Published var searchQuery: String = "" { didSet { _filteredNodes = nil } }
    @Published var filterStartDate: Date? = nil { didSet { _filteredNodes = nil } }
    @Published var filterEndDate: Date? = nil { didSet { _filteredNodes = nil } }

    private var _filteredNodes: [GraphNode]? = nil

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

    func simulationStep(size: CGSize) {
        guard nodes.count > 1 else { return }

        let repulsion: Double = 6000
        let attraction: Double = 0.04
        let damping: Double = 0.85
        let dt: Double = 0.5
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        var forces: [String: CGPoint] = [:]
        for node in nodes { forces[node.id] = .zero }

        // Repulsion between all node pairs
        for i in 0..<nodes.count {
            for j in (i+1)..<nodes.count {
                let dx = nodes[j].position.x - nodes[i].position.x
                let dy = nodes[j].position.y - nodes[i].position.y
                let dist = max(sqrt(dx*dx + dy*dy), 1)
                let force = repulsion / (dist * dist)
                let fx = (dx / dist) * force
                let fy = (dy / dist) * force
                forces[nodes[i].id]!.x -= fx
                forces[nodes[i].id]!.y -= fy
                forces[nodes[j].id]!.x += fx
                forces[nodes[j].id]!.y += fy
            }
        }

        // Attraction along edges
        let nodeIndex = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        for edge in edges {
            guard let si = nodeIndex[edge.sourceID], let ti = nodeIndex[edge.targetID] else { continue }
            let dx = nodes[ti].position.x - nodes[si].position.x
            let dy = nodes[ti].position.y - nodes[si].position.y
            let dist = max(sqrt(dx*dx + dy*dy), 1)
            let force = attraction * dist
            let fx = (dx / dist) * force
            let fy = (dy / dist) * force
            forces[nodes[si].id]!.x += fx
            forces[nodes[si].id]!.y += fy
            forces[nodes[ti].id]!.x -= fx
            forces[nodes[ti].id]!.y -= fy
        }

        // Gravity toward center
        for node in nodes {
            let dx = center.x - node.position.x
            let dy = center.y - node.position.y
            forces[node.id]!.x += dx * 0.005
            forces[node.id]!.y += dy * 0.005
        }

        // Integrate
        for i in 0..<nodes.count {
            var v = nodes[i].velocity
            let f = forces[nodes[i].id]!
            v.x = (v.x + f.x * dt) * damping
            v.y = (v.y + f.y * dt) * damping
            nodes[i].velocity = v
            nodes[i].position.x += v.x * dt
            nodes[i].position.y += v.y * dt
        }
    }
}
