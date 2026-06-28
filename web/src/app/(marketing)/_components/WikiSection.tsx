"use client";

import { motion, useTransform, type MotionValue } from "framer-motion";
import { ActCopy } from "./ActCopy";
import { IPhoneFrame } from "./IPhoneFrame";
import { ScrollScene } from "./ScrollScene";

const COPY = [
  {
    title: "Every entity becomes a node.",
    body: "People you mention, places you walk through, ideas you keep circling — each one earns its own page the first time it appears, and grows quietly as you keep living.",
  },
  {
    title: "Days link to days.",
    body: "When two diary entries share a name, a coordinate, or a recurring thought, an edge appears between them. You didn't draw it — your week did.",
  },
  {
    title: "A second brain that grows on its own.",
    body: "Search a name and read every day that mentions it. Open Lisbon and see the rain, the pastéis, the friend who's moving. The wiki gets denser without any extra effort from you.",
  },
];

export function WikiSection() {
  return (
    <ScrollScene
      id="wiki"
      tone="warm"
      label="Act 3 · Wiki"
      copy={(progress) => <ActCopy items={COPY} progress={progress} />}
      stage={(progress) => (
        <IPhoneFrame width={320}>
          <WikiMockScreen progress={progress} />
        </IPhoneFrame>
      )}
    />
  );
}

const VIEW_W = 280;
const VIEW_H = 460;
const CENTER = { x: VIEW_W / 2, y: VIEW_H / 2 + 10 };

const NODES = [
  { id: "heden",  label: "Heden",      kind: "place",  x: 50,  y: 110, delay: 0.0 },
  { id: "tokyo",  label: "Tokyo",      kind: "place",  x: 220, y: 80,  delay: 0.04 },
  { id: "joao",   label: "João",       kind: "person", x: 35,  y: 290, delay: 0.08 },
  { id: "wiki",   label: "wiki idea",  kind: "idea",   x: 245, y: 220, delay: 0.02 },
  { id: "lisbon", label: "Lisbon",     kind: "place",  x: 200, y: 380, delay: 0.06 },
  { id: "rain",   label: "rain",       kind: "idea",   x: 70,  y: 410, delay: 0.10 },
] as const;

const KIND_COLOR: Record<(typeof NODES)[number]["kind"], string> = {
  place: "var(--heatmap-mid)",
  person: "var(--accent)",
  idea: "var(--recording-red)",
};

function WikiMockScreen({ progress }: { progress: MotionValue<number> }) {
  // Phase 1 (0.00–0.33): central daily card shrinks to a dot
  // Phase 2 (0.33–0.66): satellites spring out
  // Phase 3 (0.66–1.00): edges draw + slow rotate

  const centerScale = useTransform(progress, [0, 0.18, 0.34], [1, 1, 0.18]);
  const centerCardOpacity = useTransform(progress, [0, 0.18, 0.34], [1, 1, 0]);
  const centerDotOpacity = useTransform(progress, [0.28, 0.36, 1], [0, 1, 1]);

  const edgeProgress = useTransform(progress, [0.62, 0.95], [0, 1]);
  const rotate = useTransform(progress, [0.66, 1], [0, -4]);

  return (
    <div
      style={{
        position: "absolute",
        inset: 0,
        display: "flex",
        flexDirection: "column",
        padding: "56px 18px 18px",
        gap: 12,
        fontFamily: "var(--font-inter), system-ui",
      }}
    >
      <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
        <span style={{ fontSize: 11, color: "var(--fg-subtle-aa)", letterSpacing: 1 }}>
          WIKI
        </span>
        <span
          style={{
            fontFamily: "var(--font-fraunces), serif",
            fontSize: 20,
            fontWeight: 600,
            color: "var(--fg-primary)",
            letterSpacing: -0.5,
          }}
        >
          Connections
        </span>
      </div>

      <motion.div style={{ flex: 1, position: "relative", rotate }}>
        <motion.div
          style={{
            position: "absolute",
            left: "50%",
            top: "50%",
            transform: "translate(-50%, -50%)",
            scale: centerScale,
            opacity: centerCardOpacity,
            width: 180,
            padding: "10px 12px",
            borderRadius: 14,
            background: "var(--surface-white)",
            border: "1px solid var(--border-subtle)",
            boxShadow: "0 10px 24px -14px rgba(43,40,34,0.2)",
            textAlign: "center",
          }}
        >
          <span
            style={{
              fontFamily: "var(--font-fraunces), serif",
              fontSize: 13,
              fontWeight: 600,
              color: "var(--fg-primary)",
              letterSpacing: -0.2,
              lineHeight: 1.25,
            }}
          >
            A Saturday folded around the rain
          </span>
          <div
            style={{
              marginTop: 4,
              fontSize: 9,
              color: "var(--fg-subtle-aa)",
              letterSpacing: 0.5,
            }}
          >
            JUN 28
          </div>
        </motion.div>

        <motion.div
          aria-hidden
          style={{
            position: "absolute",
            left: "50%",
            top: "50%",
            transform: "translate(-50%, -50%)",
            width: 10,
            height: 10,
            borderRadius: 999,
            background: "var(--fg-primary)",
            boxShadow: "0 0 0 4px var(--accent-soft)",
            opacity: centerDotOpacity,
          }}
        />

        <svg
          viewBox={`0 0 ${VIEW_W} ${VIEW_H}`}
          width="100%"
          height="100%"
          preserveAspectRatio="xMidYMid meet"
          style={{ position: "absolute", inset: 0, pointerEvents: "none" }}
        >
          {NODES.map((n, i) => (
            <EdgeLine key={n.id} node={n} index={i} edgeProgress={edgeProgress} />
          ))}
        </svg>

        {NODES.map((n) => (
          <SatelliteNode key={n.id} node={n} progress={progress} />
        ))}
      </motion.div>
    </div>
  );
}

function EdgeLine({
  node,
  index,
  edgeProgress,
}: {
  node: (typeof NODES)[number];
  index: number;
  edgeProgress: MotionValue<number>;
}) {
  const start = index * 0.05;
  const pathLength = useTransform(edgeProgress, [start, 1], [0, 1]);
  const edgeOpacity = useTransform(edgeProgress, [start, start + 0.05], [0, 1]);
  return (
    <motion.line
      x1={CENTER.x}
      y1={CENTER.y}
      x2={node.x}
      y2={node.y}
      stroke="var(--accent-border)"
      strokeWidth={1}
      strokeLinecap="round"
      style={{ pathLength, opacity: edgeOpacity }}
    />
  );
}

function SatelliteNode({
  node,
  progress,
}: {
  node: (typeof NODES)[number];
  progress: MotionValue<number>;
}) {
  const start = 0.34 + node.delay;
  const end = start + 0.16;

  const opacity = useTransform(progress, [start, end], [0, 1]);
  const scale = useTransform(progress, [start, end], [0.4, 1]);

  const leftPct = (node.x / VIEW_W) * 100;
  const topPct = (node.y / VIEW_H) * 100;

  return (
    <motion.div
      style={{
        position: "absolute",
        left: `${leftPct}%`,
        top: `${topPct}%`,
        transform: "translate(-50%, -50%)",
        opacity,
        scale,
        display: "flex",
        alignItems: "center",
        gap: 5,
        padding: "4px 9px",
        borderRadius: 999,
        background: "var(--surface-white)",
        border: "1px solid var(--border-subtle)",
        boxShadow: "0 6px 14px -10px rgba(43,40,34,0.25)",
        willChange: "transform, opacity",
      }}
    >
      <span
        style={{
          width: 6,
          height: 6,
          borderRadius: 999,
          background: KIND_COLOR[node.kind],
        }}
      />
      <span
        style={{
          fontSize: 10,
          fontWeight: 500,
          color: "var(--fg-primary)",
          fontFamily: "var(--font-inter), system-ui",
          letterSpacing: 0.1,
        }}
      >
        {node.label}
      </span>
    </motion.div>
  );
}
