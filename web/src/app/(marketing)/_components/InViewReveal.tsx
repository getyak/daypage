"use client";

import { motion, useReducedMotion, type Variants } from "framer-motion";
import { type ReactNode } from "react";

interface InViewRevealProps {
  children: ReactNode;
  /** Pixel offset before the element triggers (negative = earlier). */
  rootMargin?: string;
  delay?: number;
  /** Vertical translate distance for the hidden state, in px. */
  y?: number;
  className?: string;
  as?: "div" | "section" | "li" | "span";
}

const variants = (y: number): Variants => ({
  hidden: { opacity: 0, y },
  visible: {
    opacity: 1,
    y: 0,
    transition: { type: "spring", stiffness: 120, damping: 22, mass: 0.9 },
  },
});

export function InViewReveal({
  children,
  rootMargin = "-15% 0px",
  delay = 0,
  y = 24,
  className,
  as = "div",
}: InViewRevealProps) {
  const reduced = useReducedMotion();
  if (reduced) {
    const Tag = as;
    return <Tag className={className}>{children}</Tag>;
  }
  const MotionTag = motion[as];
  return (
    <MotionTag
      className={className}
      variants={variants(y)}
      initial="hidden"
      whileInView="visible"
      viewport={{ once: true, margin: rootMargin }}
      transition={{ delay }}
      style={{ willChange: "transform, opacity" }}
    >
      {children}
    </MotionTag>
  );
}
