"use client";

import { motion, useTransform, type MotionValue } from "framer-motion";

export interface ActCopyItem {
  title: string;
  body: string;
}

interface ActCopyProps {
  items: ActCopyItem[];
  progress: MotionValue<number>;
  tone?: "warm" | "dark";
}

/**
 * Left-column copy stack used by the three-act ScrollScene sections.
 * Each panel owns 1/N of progress and softly crossfades at the seams.
 */
export function ActCopy({ items, progress, tone = "warm" }: ActCopyProps) {
  const titleColor =
    tone === "dark"
      ? "text-[color:var(--bg-warm)]"
      : "text-[color:var(--fg-primary)]";
  const bodyColor =
    tone === "dark"
      ? "text-[color:var(--bg-warm)]/65"
      : "text-[color:var(--fg-muted)]";
  const dotColor =
    tone === "dark"
      ? "bg-[color:var(--bg-warm)]"
      : "bg-[color:var(--accent)]";

  return (
    <div className="relative h-[340px]">
      {items.map((item, i) => (
        <CopyPanel
          key={item.title}
          item={item}
          index={i}
          total={items.length}
          progress={progress}
          titleColor={titleColor}
          bodyColor={bodyColor}
        />
      ))}

      <div className="absolute -left-6 top-2 hidden h-full flex-col gap-3 lg:flex">
        {items.map((_, i) => (
          <ProgressDot
            key={i}
            index={i}
            total={items.length}
            progress={progress}
            dotColor={dotColor}
          />
        ))}
      </div>
    </div>
  );
}

function CopyPanel({
  item,
  index,
  total,
  progress,
  titleColor,
  bodyColor,
}: {
  item: ActCopyItem;
  index: number;
  total: number;
  progress: MotionValue<number>;
  titleColor: string;
  bodyColor: string;
}) {
  const start = index / total;
  const end = (index + 1) / total;
  const opacity = useTransform(
    progress,
    [start - 0.06, start + 0.04, end - 0.04, end + 0.06],
    [0, 1, 1, 0],
  );
  const y = useTransform(
    progress,
    [start - 0.06, start + 0.04, end - 0.04, end + 0.06],
    [16, 0, 0, -16],
  );
  return (
    <motion.div
      style={{ opacity, y, willChange: "transform, opacity" }}
      className="absolute inset-0"
    >
      <h3
        className={`font-serif text-[clamp(30px,4.2vw,48px)] leading-[1.05] tracking-[-0.02em] ${titleColor}`}
      >
        {item.title}
      </h3>
      <p className={`mt-6 max-w-[460px] text-[17px] leading-[1.6] ${bodyColor}`}>
        {item.body}
      </p>
    </motion.div>
  );
}

function ProgressDot({
  index,
  total,
  progress,
  dotColor,
}: {
  index: number;
  total: number;
  progress: MotionValue<number>;
  dotColor: string;
}) {
  const start = index / total;
  const end = (index + 1) / total;
  const active = useTransform(progress, [start, end], [0, 1]);
  const scale = useTransform(active, [0, 1], [1, 1.6]);
  const opacity = useTransform(active, [0, 1], [0.3, 1]);
  return (
    <motion.span
      style={{ scale, opacity }}
      className={`block h-1.5 w-1.5 rounded-full ${dotColor}`}
    />
  );
}
