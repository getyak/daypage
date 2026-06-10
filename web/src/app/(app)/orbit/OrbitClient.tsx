"use client";

import { useEffect, useRef, useState, useCallback } from "react";
import * as d3Force from "d3-force";
import * as d3Drag from "d3-drag";
import * as d3Zoom from "d3-zoom";
import * as d3Selection from "d3-selection";

// ─── Types ────────────────────────────────────────────────────────────────────

export type TreeSummary = {
  id: string;
  title: string;
  status: string;
};

type TreeNodeDTO = {
  id: string;
  tree_id: string;
  parent_id: string | null;
  kind: "goal" | "branch" | "leaf";
  status: string;
  title: string;
  heat: number;
  evidence_memo_ids: string[];
  page_id: string | null;
  created_at: string;
  updated_at: string;
};

type TreeDetailDTO = {
  tree: { id: string; title: string; status: string };
  nodes: TreeNodeDTO[];
  diff: {
    since: string;
    added_node_ids: string[];
    changed_node_ids: string[];
  };
};

// d3-force simulation types
type SimNode = d3Force.SimulationNodeDatum & TreeNodeDTO;
type SimLink = d3Force.SimulationLinkDatum<SimNode> & { id: string };

// ─── Constants ────────────────────────────────────────────────────────────────

const NODE_MIN_RADIUS = 6;
const NODE_MAX_RADIUS = 18;
const SELECTED_RING = 4;

// Heat → colour: cool grey (cold/0) → warm accent (hot/1). Heat is unbounded
// in the schema but in practice 0–1; clamp for the gradient.
function heatColor(heat: number): string {
  const t = Math.max(0, Math.min(1, heat));
  if (t < 0.5) return "var(--fg-subtle)";
  if (t < 0.75) return "var(--accent)";
  return "var(--warning)";
}

// Heat → radius: hotter nodes render larger so attention follows heat.
function heatRadius(heat: number): number {
  const t = Math.max(0, Math.min(1, heat));
  return NODE_MIN_RADIUS + t * (NODE_MAX_RADIUS - NODE_MIN_RADIUS);
}

// ─── Node detail aside (evidence memo count + status) ──────────────────────────

function NodeDetailAside({
  node,
  isNew,
  isChanged,
  onClose,
}: {
  node: TreeNodeDTO;
  isNew: boolean;
  isChanged: boolean;
  onClose: () => void;
}) {
  return (
    <div
      style={{
        position: "absolute",
        top: "1rem",
        right: "1rem",
        width: "280px",
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
        <div
          style={{ display: "flex", flexDirection: "column", gap: "0.25rem" }}
        >
          <span
            style={{
              fontSize: "0.6875rem",
              fontWeight: 600,
              color: heatColor(node.heat),
              textTransform: "uppercase",
              letterSpacing: "0.06em",
            }}
          >
            {node.kind}
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
          flexWrap: "wrap",
          gap: "0.5rem 0.75rem",
          fontSize: "0.8125rem",
          color: "var(--fg-muted)",
        }}
      >
        <span>{node.evidence_memo_ids.length} evidence memos</span>
        <span>heat {node.heat.toFixed(2)}</span>
        <span
          style={{
            color: "var(--accent)",
            fontWeight: 600,
            fontSize: "0.6875rem",
            textTransform: "uppercase",
          }}
        >
          {node.status}
        </span>
        {isNew && (
          <span
            style={{
              color: "var(--success)",
              fontWeight: 600,
              fontSize: "0.6875rem",
              textTransform: "uppercase",
            }}
          >
            new this week
          </span>
        )}
        {!isNew && isChanged && (
          <span
            style={{
              color: "var(--warning)",
              fontWeight: 600,
              fontSize: "0.6875rem",
              textTransform: "uppercase",
            }}
          >
            changed this week
          </span>
        )}
      </div>
    </div>
  );
}

// ─── Graph canvas for a single tree ────────────────────────────────────────────

function TreeGraph({ treeId }: { treeId: string }) {
  const wrapRef = useRef<HTMLDivElement>(null);
  const svgRef = useRef<SVGSVGElement>(null);
  const [detail, setDetail] = useState<TreeDetailDTO | null>(null);
  const [loading, setLoading] = useState(true);
  const [selectedNode, setSelectedNode] = useState<TreeNodeDTO | null>(null);
  // Measured canvas size. The simulation's center force depends on this, so we
  // must have a *real* size before laying out — reading svg.clientHeight inside
  // the layout effect races with flexbox and can yield a collapsed height,
  // which pins every node to the top of the canvas. A ResizeObserver feeds the
  // true size (and keeps it current on resize / sidebar collapse).
  const [dims, setDims] = useState<{ w: number; h: number } | null>(null);

  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const ro = new ResizeObserver((entries) => {
      const box = entries[0]?.contentRect;
      if (!box) return;
      // Ignore degenerate (pre-layout) sizes so we never center on a 0-height.
      if (box.width < 1 || box.height < 1) return;
      setDims((prev) =>
        prev && prev.w === Math.round(box.width) && prev.h === Math.round(box.height)
          ? prev
          : { w: Math.round(box.width), h: Math.round(box.height) }
      );
    });
    ro.observe(el);
    return () => ro.disconnect();
    // Re-run once the graph DOM (with wrapRef) actually mounts: while loading or
    // empty, a different element tree renders and wrapRef.current is null.
  }, [loading, detail]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoading(true);
    setSelectedNode(null);
    let cancelled = false;
    fetch(`/api/trees/${treeId}`)
      .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
      .then((d: TreeDetailDTO) => {
        if (cancelled) return;
        setDetail(d);
        setLoading(false);
      })
      .catch(() => {
        if (cancelled) return;
        setDetail(null);
        setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [treeId]);

  const handleNodeClick = useCallback((node: TreeNodeDTO) => {
    setSelectedNode((cur) => (cur?.id === node.id ? null : node));
  }, []);

  // Build + run the simulation. parent_id → child edges form the branch graph.
  useEffect(() => {
    if (!detail || !svgRef.current || !dims) return;
    if (detail.nodes.length === 0) return;

    const svg = d3Selection.select(svgRef.current);
    svg.selectAll("*").remove();

    // Use the ResizeObserver-measured size, not svg.clientHeight (which races
    // with layout). Falls back defensively but dims is guaranteed non-null here.
    const width = dims.w || 800;
    const height = dims.h || 560;
    const addedSet = new Set(detail.diff.added_node_ids);
    const changedSet = new Set(detail.diff.changed_node_ids);

    const g = svg.append("g");

    const zoom = d3Zoom
      .zoom<SVGSVGElement, unknown>()
      .scaleExtent([0.2, 4])
      .on("zoom", (event: d3Zoom.D3ZoomEvent<SVGSVGElement, unknown>) => {
        g.attr("transform", event.transform.toString());
      });
    svg.call(zoom);

    const simNodes: SimNode[] = detail.nodes.map((n) => ({ ...n }));
    const nodeById = new Map(simNodes.map((n) => [n.id, n]));

    const simLinks: SimLink[] = simNodes
      .filter((n) => n.parent_id && nodeById.has(n.parent_id))
      .map((n) => ({
        id: `${n.parent_id}->${n.id}`,
        source: nodeById.get(n.parent_id!)!,
        target: nodeById.get(n.id)!,
      }));

    const simulation = d3Force
      .forceSimulation<SimNode>(simNodes)
      .force(
        "link",
        d3Force
          .forceLink<SimNode, SimLink>(simLinks)
          .id((d) => d.id)
          .distance(90)
          .strength(0.5)
      )
      .force("charge", d3Force.forceManyBody().strength(-240))
      .force("center", d3Force.forceCenter(width / 2, height / 2))
      .force(
        "collision",
        d3Force.forceCollide<SimNode>((d) => heatRadius(d.heat) + 8)
      );

    // Edges
    const edgeGroup = g.append("g").attr("class", "edges");
    const edgeSel = edgeGroup
      .selectAll<SVGLineElement, SimLink>("line")
      .data(simLinks)
      .join("line")
      .attr("stroke", "var(--accent-border)")
      .attr("stroke-width", 1.5)
      .attr("stroke-opacity", 0.6);

    // Nodes
    const nodeGroup = g.append("g").attr("class", "nodes");
    const nodeSel = nodeGroup
      .selectAll<SVGGElement, SimNode>("g")
      .data(simNodes)
      .join("g")
      .style("cursor", "pointer");

    nodeSel
      .append("circle")
      .attr("r", (d) => heatRadius(d.heat))
      .attr("fill", (d) => heatColor(d.heat))
      // Diff ring: green = new this week, amber = changed this week.
      .attr("stroke", (d) =>
        addedSet.has(d.id)
          ? "var(--success)"
          : changedSet.has(d.id)
            ? "var(--warning)"
            : "var(--surface-white)"
      )
      .attr("stroke-width", (d) =>
        addedSet.has(d.id) || changedSet.has(d.id) ? 3 : 2
      );

    nodeSel
      .append("text")
      .attr("dy", (d) => heatRadius(d.heat) + 12)
      .attr("text-anchor", "middle")
      .attr("font-size", "9px")
      .attr("fill", "var(--fg-muted)")
      .attr("pointer-events", "none")
      .text((d) => (d.title.length > 20 ? d.title.slice(0, 18) + "…" : d.title));

    nodeSel.on("click", (_event, d) => handleNodeClick(d));

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

    simulation.on("tick", () => {
      edgeSel
        .attr("x1", (d) => (d.source as SimNode).x ?? 0)
        .attr("y1", (d) => (d.source as SimNode).y ?? 0)
        .attr("x2", (d) => (d.target as SimNode).x ?? 0)
        .attr("y2", (d) => (d.target as SimNode).y ?? 0);

      nodeSel.attr("transform", (d) => `translate(${d.x ?? 0},${d.y ?? 0})`);
    });

    return () => {
      simulation.stop();
    };
  }, [detail, handleNodeClick, dims]);

  // Highlight the selected node with an extra ring.
  useEffect(() => {
    if (!svgRef.current || !detail) return;
    const svg = d3Selection.select(svgRef.current);
    svg
      .selectAll<SVGGElement, SimNode>(".nodes g circle")
      .attr("opacity", (d) =>
        !selectedNode || d.id === selectedNode.id ? 1 : 0.35
      )
      .attr("stroke-width", (d) => {
        if (selectedNode && d.id === selectedNode.id) return SELECTED_RING;
        const inDiff =
          detail.diff.added_node_ids.includes(d.id) ||
          detail.diff.changed_node_ids.includes(d.id);
        return inDiff ? 3 : 2;
      });
  }, [selectedNode, detail]);

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
        Loading orbit…
      </div>
    );
  }

  if (!detail || detail.nodes.length === 0) {
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
          🪐
        </div>
        <p
          className="ds-body-md"
          style={{ color: "var(--fg-muted)", maxWidth: "320px", margin: 0 }}
        >
          This tree has no nodes yet — it grows as memos compile into goals.
        </p>
      </div>
    );
  }

  const selNew = selectedNode
    ? detail.diff.added_node_ids.includes(selectedNode.id)
    : false;
  const selChanged = selectedNode
    ? detail.diff.changed_node_ids.includes(selectedNode.id)
    : false;

  return (
    <div
      ref={wrapRef}
      style={{ flex: 1, position: "relative", overflow: "hidden", minHeight: 0 }}
    >
      <svg
        ref={svgRef}
        style={{ width: "100%", height: "100%", display: "block" }}
      />

      {selectedNode && (
        <NodeDetailAside
          node={selectedNode}
          isNew={selNew}
          isChanged={selChanged}
          onClose={() => setSelectedNode(null)}
        />
      )}

      {/* This-week diff summary + heat legend */}
      <div
        style={{
          position: "absolute",
          bottom: "1rem",
          left: "1rem",
          display: "flex",
          flexDirection: "column",
          gap: "0.375rem",
          background: "var(--surface-white)",
          border: "1px solid var(--accent-border)",
          borderRadius: "var(--radius-sm)",
          padding: "0.5rem 0.75rem",
          opacity: 0.9,
          fontSize: "0.6875rem",
          color: "var(--fg-muted)",
        }}
      >
        <span>
          This week:{" "}
          <strong style={{ color: "var(--success)" }}>
            +{detail.diff.added_node_ids.length}
          </strong>{" "}
          new ·{" "}
          <strong style={{ color: "var(--warning)" }}>
            {detail.diff.changed_node_ids.length}
          </strong>{" "}
          changed
        </span>
        <span style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
          <LegendDot color="var(--fg-subtle)" /> cold
          <LegendDot color="var(--accent)" /> warm
          <LegendDot color="var(--warning)" /> hot
        </span>
      </div>
    </div>
  );
}

function LegendDot({ color }: { color: string }) {
  return (
    <span
      style={{
        width: "8px",
        height: "8px",
        borderRadius: "50%",
        background: color,
        display: "inline-block",
        flexShrink: 0,
      }}
    />
  );
}

// ─── Orbit page shell: tree picker + graph ─────────────────────────────────────

export function OrbitClient({ trees }: { trees: TreeSummary[] }) {
  const [activeTreeId, setActiveTreeId] = useState<string | null>(
    trees[0]?.id ?? null
  );

  if (trees.length === 0) {
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
        <div style={{ fontSize: "2rem" }}>🪐</div>
        <h2
          style={{
            margin: 0,
            fontSize: "1.125rem",
            color: "var(--fg-primary)",
          }}
        >
          No task trees yet
        </h2>
        <p
          className="ds-body-md"
          style={{ color: "var(--fg-muted)", maxWidth: "360px", margin: 0 }}
        >
          Task trees grow as the system compiles your memos into goals. Once one
          exists, it will appear here as a living graph.
        </p>
      </div>
    );
  }

  return (
    <div
      style={{ flex: 1, display: "flex", flexDirection: "column", minHeight: 0 }}
    >
      <header
        style={{
          display: "flex",
          alignItems: "center",
          gap: "0.75rem",
          padding: "1rem 1.25rem",
          borderBottom: "1px solid var(--accent-border)",
          flexWrap: "wrap",
        }}
      >
        <h1
          style={{
            margin: 0,
            fontSize: "1.0625rem",
            fontWeight: 600,
            color: "var(--fg-primary)",
          }}
        >
          Orbit
        </h1>
        <div style={{ display: "flex", gap: "0.375rem", flexWrap: "wrap" }}>
          {trees.map((t) => {
            const active = t.id === activeTreeId;
            return (
              <button
                key={t.id}
                onClick={() => setActiveTreeId(t.id)}
                style={{
                  padding: "0.3125rem 0.75rem",
                  borderRadius: "var(--radius-sm)",
                  border: "1px solid var(--accent-border)",
                  background: active ? "var(--accent-soft)" : "transparent",
                  color: active ? "var(--accent)" : "var(--fg-muted)",
                  fontSize: "0.8125rem",
                  fontWeight: active ? 600 : 500,
                  cursor: "pointer",
                }}
              >
                {t.title}
              </button>
            );
          })}
        </div>
      </header>

      {activeTreeId && <TreeGraph key={activeTreeId} treeId={activeTreeId} />}
    </div>
  );
}
