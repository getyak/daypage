"use client";

import { useEffect, useRef, useState, useCallback } from "react";
import * as d3Force from "d3-force";
import * as d3Drag from "d3-drag";
import * as d3Zoom from "d3-zoom";
import * as d3Selection from "d3-selection";

// ─── Types ────────────────────────────────────────────────────────────────────

type PageNode = {
  id: string;
  slug: string;
  type: "concept" | "source" | "entity" | "synthesis" | "daily";
  title: string;
  status: "draft" | "live" | "archived";
  source_count: number;
  backlink_count: number;
};

type PageLink = {
  id: string;
  from_page_id: string;
  to_page_id: string;
  weight: number;
  rationale: string | null;
};

type GraphData = {
  nodes: PageNode[];
  links: PageLink[];
};

// d3-force simulation node type
type SimNode = d3Force.SimulationNodeDatum & PageNode;
type SimLink = d3Force.SimulationLinkDatum<SimNode> & {
  id: string;
  weight: number;
  rationale: string | null;
};

// ─── Constants ────────────────────────────────────────────────────────────────

const NODE_COLORS: Record<PageNode["type"], string> = {
  concept: "var(--accent)",
  synthesis: "var(--success)",
  entity: "var(--accent-hover)",
  source: "var(--fg-muted)",
  daily: "var(--warning)",
};

const NODE_RADIUS = 8;
const SELECTED_RADIUS = 12;

// ─── Aside detail card ────────────────────────────────────────────────────────

function NodeDetailAside({
  node,
  onClose,
}: {
  node: PageNode;
  onClose: () => void;
}) {
  return (
    <div
      style={{
        position: "absolute",
        top: "1rem",
        right: "1rem",
        width: "260px",
        background: "var(--surface-white)",
        border: "1px solid var(--accent-border)",
        borderRadius: "var(--radius-md)",
        padding: "1rem",
        boxShadow: "0 4px 16px rgba(0,0,0,0.08)",
        zIndex: 10,
        display: "flex",
        flexDirection: "column",
        gap: "0.75rem",
      }}
    >
      <div
        style={{
          display: "flex",
          alignItems: "flex-start",
          justifyContent: "space-between",
          gap: "0.5rem",
        }}
      >
        <div style={{ display: "flex", flexDirection: "column", gap: "0.25rem" }}>
          <span
            style={{
              fontSize: "0.6875rem",
              fontWeight: 600,
              color: NODE_COLORS[node.type],
              textTransform: "uppercase",
              letterSpacing: "0.06em",
            }}
          >
            {node.type}
          </span>
          <h3
            style={{
              margin: 0,
              fontSize: "0.9375rem",
              fontWeight: 600,
              color: "var(--fg-primary)",
              lineHeight: 1.3,
            }}
          >
            {node.title}
          </h3>
        </div>
        <button
          onClick={onClose}
          style={{
            background: "transparent",
            border: "none",
            cursor: "pointer",
            color: "var(--fg-subtle)",
            fontSize: "1rem",
            flexShrink: 0,
            lineHeight: 1,
            padding: "0.125rem",
          }}
          aria-label="Close"
        >
          ×
        </button>
      </div>

      <div
        style={{
          display: "flex",
          gap: "0.75rem",
          fontSize: "0.8125rem",
          color: "var(--fg-muted)",
        }}
      >
        <span>{node.source_count} sources</span>
        <span>{node.backlink_count} backlinks</span>
        {node.status === "draft" && (
          <span
            style={{
              color: "var(--warning)",
              fontWeight: 600,
              fontSize: "0.6875rem",
              textTransform: "uppercase",
            }}
          >
            draft
          </span>
        )}
      </div>

      <a
        href={`/wiki/${node.slug}`}
        style={{
          display: "inline-flex",
          alignItems: "center",
          justifyContent: "center",
          padding: "0.4375rem 0.875rem",
          borderRadius: "var(--radius-sm)",
          background: "var(--accent-soft)",
          color: "var(--accent)",
          fontSize: "0.8125rem",
          fontWeight: 500,
          textDecoration: "none",
          border: "none",
          cursor: "pointer",
          transition: "background 100ms ease-out",
        }}
      >
        Open page →
      </a>
    </div>
  );
}

// ─── Main WikiGraph component ─────────────────────────────────────────────────

export function WikiGraph() {
  const svgRef = useRef<SVGSVGElement>(null);
  const [data, setData] = useState<GraphData | null>(null);
  const [loading, setLoading] = useState(true);
  const [selectedNode, setSelectedNode] = useState<PageNode | null>(null);
  const [neighborIds, setNeighborIds] = useState<Set<string>>(new Set());

  // Fetch graph data
  useEffect(() => {
    setLoading(true);
    fetch("/api/page_links")
      .then((r) => r.json())
      .then((d: GraphData) => {
        setData(d);
        setLoading(false);
      })
      .catch(() => setLoading(false));
  }, []);

  const handleNodeClick = useCallback(
    (node: PageNode, links: PageLink[]) => {
      if (selectedNode?.id === node.id) {
        setSelectedNode(null);
        setNeighborIds(new Set());
        return;
      }
      setSelectedNode(node);
      const neighbors = new Set<string>();
      for (const link of links) {
        if (link.from_page_id === node.id) neighbors.add(link.to_page_id);
        if (link.to_page_id === node.id) neighbors.add(link.from_page_id);
      }
      setNeighborIds(neighbors);
    },
    [selectedNode]
  );

  // Build and run d3 simulation
  useEffect(() => {
    if (!data || !svgRef.current) return;
    if (data.nodes.length === 0) return;

    const svg = d3Selection.select(svgRef.current);
    svg.selectAll("*").remove();

    const width = svgRef.current.clientWidth || 800;
    const height = svgRef.current.clientHeight || 560;

    // Root group for zoom/pan
    const g = svg.append("g");

    // Zoom behaviour
    const zoom = d3Zoom
      .zoom<SVGSVGElement, unknown>()
      .scaleExtent([0.2, 4])
      .on("zoom", (event: d3Zoom.D3ZoomEvent<SVGSVGElement, unknown>) => {
        g.attr("transform", event.transform.toString());
      });
    svg.call(zoom);

    // Arrow marker
    svg
      .append("defs")
      .append("marker")
      .attr("id", "arrow")
      .attr("viewBox", "0 -4 8 8")
      .attr("refX", NODE_RADIUS + 10)
      .attr("refY", 0)
      .attr("markerWidth", 6)
      .attr("markerHeight", 6)
      .attr("orient", "auto")
      .append("path")
      .attr("d", "M0,-4L8,0L0,4")
      .attr("fill", "var(--fg-subtle)");

    // Prepare simulation nodes/links
    const simNodes: SimNode[] = data.nodes.map((n) => ({ ...n }));
    const nodeById = new Map(simNodes.map((n) => [n.id, n]));

    const simLinks: SimLink[] = data.links
      .filter((l) => nodeById.has(l.from_page_id) && nodeById.has(l.to_page_id))
      .map((l) => ({
        ...l,
        source: nodeById.get(l.from_page_id)!,
        target: nodeById.get(l.to_page_id)!,
      }));

    // Simulation
    const simulation = d3Force
      .forceSimulation<SimNode>(simNodes)
      .force(
        "link",
        d3Force
          .forceLink<SimNode, SimLink>(simLinks)
          .id((d) => d.id)
          .distance(80)
          .strength(0.4)
      )
      .force("charge", d3Force.forceManyBody().strength(-200))
      .force("center", d3Force.forceCenter(width / 2, height / 2))
      .force("collision", d3Force.forceCollide(NODE_RADIUS + 6));

    // Draw edges
    const edgeGroup = g.append("g").attr("class", "edges");
    const edgeSel = edgeGroup
      .selectAll<SVGLineElement, SimLink>("line")
      .data(simLinks)
      .join("line")
      .attr("stroke", "var(--accent-border)")
      .attr("stroke-width", (d) => Math.sqrt(d.weight) * 1.5)
      .attr("stroke-opacity", 0.6)
      .attr("marker-end", "url(#arrow)");

    // Draw nodes
    const nodeGroup = g.append("g").attr("class", "nodes");
    const nodeSel = nodeGroup
      .selectAll<SVGGElement, SimNode>("g")
      .data(simNodes)
      .join("g")
      .style("cursor", "pointer");

    nodeSel
      .append("circle")
      .attr("r", NODE_RADIUS)
      .attr("fill", (d) => NODE_COLORS[d.type])
      .attr("stroke", "var(--surface-white)")
      .attr("stroke-width", 2);

    nodeSel
      .append("text")
      .attr("dy", NODE_RADIUS + 12)
      .attr("text-anchor", "middle")
      .attr("font-size", "9px")
      .attr("fill", "var(--fg-muted)")
      .attr("pointer-events", "none")
      .text((d) => (d.title.length > 20 ? d.title.slice(0, 18) + "…" : d.title));

    // Click handler (references current links data via closure)
    nodeSel.on("click", (_event, d) => {
      handleNodeClick(d, data.links);
    });

    // Drag behaviour
    const drag = d3Drag
      .drag<SVGGElement, SimNode>()
      .on("start", (event, d) => {
        if (!event.active) simulation.alphaTarget(0.3).restart();
        d.fx = d.x;
        d.fy = d.y;
      })
      .on("drag", (event, d) => {
        d.fx = event.x;
        d.fy = event.y;
      })
      .on("end", (event, d) => {
        if (!event.active) simulation.alphaTarget(0);
        d.fx = null;
        d.fy = null;
      });

    nodeSel.call(drag);

    // Tick update
    simulation.on("tick", () => {
      edgeSel
        .attr("x1", (d) => (d.source as SimNode).x ?? 0)
        .attr("y1", (d) => (d.source as SimNode).y ?? 0)
        .attr("x2", (d) => (d.target as SimNode).x ?? 0)
        .attr("y2", (d) => (d.target as SimNode).y ?? 0);

      nodeSel.attr(
        "transform",
        (d) => `translate(${d.x ?? 0},${d.y ?? 0})`
      );
    });

    return () => {
      simulation.stop();
    };
  }, [data, handleNodeClick]);

  // Apply highlight styles when selection changes
  useEffect(() => {
    if (!svgRef.current || !data) return;
    const svg = d3Selection.select(svgRef.current);

    if (!selectedNode) {
      // Reset all
      svg
        .selectAll<SVGGElement, SimNode>(".nodes g circle")
        .attr("r", NODE_RADIUS)
        .attr("opacity", 1);
      svg
        .selectAll<SVGLineElement, SimLink>(".edges line")
        .attr("stroke-opacity", 0.6);
      return;
    }

    svg
      .selectAll<SVGGElement, SimNode>(".nodes g circle")
      .attr("r", (d) =>
        d.id === selectedNode.id ? SELECTED_RADIUS : NODE_RADIUS
      )
      .attr("opacity", (d) =>
        d.id === selectedNode.id || neighborIds.has(d.id) ? 1 : 0.2
      );

    svg
      .selectAll<SVGLineElement, SimLink>(".edges line")
      .attr("stroke-opacity", (d) => {
        const src = (d.source as SimNode).id;
        const tgt = (d.target as SimNode).id;
        return src === selectedNode.id || tgt === selectedNode.id ? 0.9 : 0.1;
      });
  }, [selectedNode, neighborIds, data]);

  if (loading) {
    return (
      <div
        style={{
          flex: 1,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          color: "var(--fg-muted)",
          fontSize: "0.875rem",
        }}
      >
        Loading graph…
      </div>
    );
  }

  if (!data || data.nodes.length === 0) {
    return (
      <div
        style={{
          flex: 1,
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          gap: "0.75rem",
          padding: "3rem 2rem",
          textAlign: "center",
        }}
      >
        <div
          style={{
            width: "48px",
            height: "48px",
            borderRadius: "var(--radius-md)",
            background: "var(--surface-sunken)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontSize: "1.5rem",
          }}
        >
          🕸️
        </div>
        <p
          className="ds-body-md"
          style={{ color: "var(--fg-muted)", maxWidth: "320px", margin: 0 }}
        >
          Add and compile some content to start growing your graph
        </p>
      </div>
    );
  }

  return (
    <div style={{ flex: 1, position: "relative", overflow: "hidden" }}>
      <svg
        ref={svgRef}
        style={{ width: "100%", height: "100%", display: "block" }}
      />

      {selectedNode && (
        <NodeDetailAside
          node={selectedNode}
          onClose={() => {
            setSelectedNode(null);
            setNeighborIds(new Set());
          }}
        />
      )}

      {/* Legend */}
      <div
        style={{
          position: "absolute",
          bottom: "1rem",
          left: "1rem",
          display: "flex",
          flexWrap: "wrap",
          gap: "0.5rem",
          background: "var(--surface-white)",
          border: "1px solid var(--accent-border)",
          borderRadius: "var(--radius-sm)",
          padding: "0.5rem 0.75rem",
          opacity: 0.85,
        }}
      >
        {(
          Object.entries(NODE_COLORS) as [PageNode["type"], string][]
        ).map(([type, color]) => (
          <div
            key={type}
            style={{
              display: "flex",
              alignItems: "center",
              gap: "0.3125rem",
              fontSize: "0.6875rem",
              color: "var(--fg-muted)",
            }}
          >
            <span
              style={{
                width: "8px",
                height: "8px",
                borderRadius: "50%",
                background: color,
                flexShrink: 0,
              }}
            />
            {type}
          </div>
        ))}
      </div>
    </div>
  );
}
