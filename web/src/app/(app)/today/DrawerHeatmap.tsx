"use client";

import { useEffect, useState } from "react";

interface HeatmapCell {
  date: string;
  count: number;
}

interface HeatmapData {
  weeks: number;
  from: string;
  to: string;
  cells: HeatmapCell[];
  streak: number;
}

function cellColor(count: number, isFuture: boolean) {
  if (isFuture) return "transparent";
  if (count === 0) return "var(--heatmap-empty)";
  if (count <= 2) return "var(--heatmap-low)";
  if (count <= 5) return "var(--heatmap-mid)";
  return "var(--heatmap-high)";
}

const WEEK_DAYS = ["Mon", "", "Wed", "", "Fri", "", ""];
const COLS = 16;
const ROWS = 7;

function buildGrid(cells: HeatmapCell[], today: Date) {
  // Build a map from date string → count
  const map = new Map<string, number>();
  for (const c of cells) map.set(c.date, c.count);

  // The grid ends on the most recent Sunday (or today if it is Sunday)
  // We build COLS weeks × 7 days, ending at today's week
  const endDate = new Date(today);
  // Advance to end of this week (Saturday = day 6)
  const dayOfWeek = endDate.getDay(); // 0=Sun
  // We want each column = Mon–Sun. Shift: Mon=0..Sun=6
  const shiftedDay = (dayOfWeek + 6) % 7; // 0=Mon..6=Sun
  const daysToEndOfWeek = 6 - shiftedDay;
  endDate.setDate(endDate.getDate() + daysToEndOfWeek);

  const grid: Array<{ date: string; count: number; isFuture: boolean }[]> = [];

  for (let col = COLS - 1; col >= 0; col--) {
    const column: { date: string; count: number; isFuture: boolean }[] = [];
    for (let row = 0; row < ROWS; row++) {
      const d = new Date(endDate);
      d.setDate(endDate.getDate() - col * 7 - (6 - row));
      const iso = d.toISOString().slice(0, 10);
      column.push({
        date: iso,
        count: map.get(iso) ?? 0,
        isFuture: d > today,
      });
    }
    grid.push(column);
  }

  return grid;
}

function getMonthLabels(grid: Array<{ date: string }[]>) {
  const labels: { label: string; colIndex: number }[] = [];
  let lastMonth = "";
  for (let col = 0; col < grid.length; col++) {
    const firstDay = grid[col][0].date;
    const month = new Date(firstDay + "T00:00:00")
      .toLocaleString("en-US", { month: "short" })
      .toUpperCase();
    if (month !== lastMonth) {
      labels.push({ label: month, colIndex: col });
      lastMonth = month;
    }
  }
  return labels.slice(0, 5);
}

const LEGEND_BOXES = [
  { bg: "var(--heatmap-empty)", border: "none" },
  { bg: "var(--heatmap-low)", border: "none" },
  { bg: "var(--heatmap-mid)", border: "none" },
  { bg: "var(--heatmap-high)", border: "none" },
];

export function DrawerHeatmap() {
  const [data, setData] = useState<HeatmapData | null>(null);
  const [tooltip, setTooltip] = useState<{ text: string; x: number; y: number } | null>(null);

  useEffect(() => {
    fetch("/api/stats/heatmap?weeks=16")
      .then((r) => r.json())
      .then((d: HeatmapData) => setData(d))
      .catch(() => {});
  }, []);

  const today = new Date();

  if (!data) {
    // Skeleton
    return (
      <div
        style={{
          borderRadius: 14,
          border: "0.5px solid var(--border-default)",
          boxShadow: "var(--shadow-card)",
          padding: 14,
          background: "var(--surface-white)",
        }}
      >
        <div
          className="shimmer"
          style={{ height: 96, borderRadius: 8 }}
          aria-label="加载中"
        />
      </div>
    );
  }

  const grid = buildGrid(data.cells, today);
  const monthLabels = getMonthLabels(grid);
  const totalEntries = data.cells.reduce((sum, c) => sum + c.count, 0);

  const CELL = 10;
  const GAP = 3;

  return (
    <div
      style={{
        borderRadius: 14,
        border: "0.5px solid var(--border-default)",
        boxShadow: "var(--shadow-card)",
        padding: 14,
        background: "var(--surface-white)",
        position: "relative",
      }}
    >
      {/* Header row: "LAST N WEEKS" + entry count — frames the grid as the
          drawer's hero element. */}
      <div
        style={{
          display: "flex",
          alignItems: "baseline",
          justifyContent: "space-between",
          marginBottom: 12,
        }}
      >
        <span
          style={{
            fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
            fontSize: 9,
            letterSpacing: 1.4,
            textTransform: "uppercase",
            color: "var(--fg-muted)",
          }}
        >
          LAST {data.weeks} WEEKS
        </span>
        <span
          style={{
            display: "inline-flex",
            alignItems: "baseline",
            gap: 5,
          }}
        >
          <span
            style={{
              fontFamily: "var(--font-fraunces), Georgia, serif",
              fontSize: 26,
              fontWeight: 600,
              letterSpacing: "-0.5px",
              lineHeight: 1,
              color: "var(--fg-primary)",
            }}
          >
            {totalEntries}
          </span>
          <span
            style={{
              fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
              fontSize: 8,
              letterSpacing: 1.2,
              textTransform: "uppercase",
              color: "var(--fg-muted)",
            }}
          >
            ENTRIES
          </span>
        </span>
      </div>

      {/* Month labels row */}
      <div
        style={{
          display: "grid",
          gridTemplateColumns: `repeat(${COLS}, ${CELL}px)`,
          gap: GAP,
          marginBottom: 4,
          paddingLeft: 22,
        }}
      >
        {grid.map((_, colIdx) => {
          const labelEntry = monthLabels.find((m) => m.colIndex === colIdx);
          return (
            <div
              key={colIdx}
              style={{
                fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
                fontSize: 9,
                letterSpacing: "0.4px",
                textTransform: "uppercase",
                color: "var(--fg-subtle)",
                whiteSpace: "nowrap",
                overflow: "visible",
                lineHeight: 1,
              }}
            >
              {labelEntry ? labelEntry.label : ""}
            </div>
          );
        })}
      </div>

      {/* Main grid: day labels + cells */}
      <div style={{ display: "flex", gap: 4 }}>
        {/* Day-of-week labels */}
        <div
          style={{
            display: "grid",
            gridTemplateRows: `repeat(${ROWS}, ${CELL}px)`,
            gap: GAP,
            alignItems: "center",
            width: 18,
            flexShrink: 0,
          }}
        >
          {WEEK_DAYS.map((label, i) => (
            <div
              key={i}
              style={{
                fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
                fontSize: 8,
                letterSpacing: "0.4px",
                textTransform: "uppercase",
                color: "var(--fg-subtle)",
                lineHeight: 1,
                textAlign: "right",
              }}
            >
              {label}
            </div>
          ))}
        </div>

        {/* Cell grid */}
        <div
          style={{
            display: "grid",
            gridTemplateColumns: `repeat(${COLS}, ${CELL}px)`,
            gridTemplateRows: `repeat(${ROWS}, ${CELL}px)`,
            gap: GAP,
          }}
        >
          {grid.flatMap((col, colIdx) =>
            col.map((cell, rowIdx) => (
              <div
                key={`${colIdx}-${rowIdx}`}
                style={{
                  width: CELL,
                  height: CELL,
                  borderRadius: 2,
                  background: cellColor(cell.count, cell.isFuture),
                  border: cell.isFuture
                    ? "0.5px dashed var(--border-default)"
                    : "none",
                  cursor: cell.isFuture ? "default" : "pointer",
                  transition: "opacity 120ms ease-out",
                }}
                title={cell.isFuture ? undefined : `${cell.date} · ${cell.count} memos`}
                onMouseEnter={(e) => {
                  if (cell.isFuture) return;
                  const rect = (e.target as HTMLElement).getBoundingClientRect();
                  setTooltip({
                    text: `${cell.date} · ${cell.count} memos`,
                    x: rect.left,
                    y: rect.top - 28,
                  });
                }}
                onMouseLeave={() => setTooltip(null)}
                onClick={() => {
                  if (!cell.isFuture) {
                    setTooltip(
                      tooltip?.text === `${cell.date} · ${cell.count} memos`
                        ? null
                        : {
                            text: `${cell.date} · ${cell.count} memos`,
                            x: 0,
                            y: 0,
                          }
                    );
                  }
                }}
              />
            ))
          )}
        </div>
      </div>

      {/* Legend row */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          marginTop: 8,
          paddingLeft: 22,
        }}
      >
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 4,
            fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
            fontSize: 8,
            letterSpacing: "0.4px",
            textTransform: "uppercase",
            color: "var(--fg-subtle)",
          }}
        >
          <span>LESS</span>
          {LEGEND_BOXES.map((b, i) => (
            <div
              key={i}
              style={{
                width: 10,
                height: 10,
                borderRadius: 2,
                background: b.bg,
                border: b.border,
              }}
            />
          ))}
          <span>MORE</span>
        </div>

        {/* Streak pill */}
        <div
          style={{
            display: "inline-flex",
            alignItems: "center",
            gap: 4,
            padding: "2px 8px",
            borderRadius: 999,
            background: "var(--accent-soft)",
            border: "0.5px solid var(--accent-border)",
            fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
            fontSize: 9,
            letterSpacing: "0.5px",
            textTransform: "uppercase",
            color: "var(--accent)",
            fontWeight: 700,
          }}
        >
          🔥 {data.streak} DAYS
        </div>
      </div>

      {/* Tooltip */}
      {tooltip && (
        <div
          style={{
            position: "fixed",
            left: tooltip.x,
            top: tooltip.y,
            background: "var(--fg-primary)",
            color: "var(--surface-white)",
            fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
            fontSize: 10,
            letterSpacing: "0.3px",
            padding: "4px 8px",
            borderRadius: 6,
            pointerEvents: "none",
            zIndex: 200,
            whiteSpace: "nowrap",
          }}
        >
          {tooltip.text}
        </div>
      )}
    </div>
  );
}
