"use client";

import { motion, useReducedMotion, type Variants } from "framer-motion";
import { createElement, type ReactNode } from "react";

type Split = "word" | "char";

interface SplitTextProps {
  text: string;
  split?: Split;
  className?: string;
  stagger?: number;
  delay?: number;
  as?: "h1" | "h2" | "p" | "span";
  /** Wrap individual tokens with a custom render fn (e.g. to italicize one word). */
  renderToken?: (token: string, index: number) => ReactNode;
}

const containerVariants = (delay: number, stagger: number): Variants => ({
  hidden: {},
  visible: {
    transition: {
      delayChildren: delay,
      staggerChildren: stagger,
    },
  },
});

// Spring on y/opacity (overshoot is fine), tween on filter so CSS blur never
// receives a negative value during overshoot.
const tokenVariants: Variants = {
  hidden: { opacity: 0, y: "0.5em", filter: "blur(8px)" },
  visible: {
    opacity: 1,
    y: 0,
    filter: "blur(0px)",
    transition: {
      y: { type: "spring", stiffness: 140, damping: 20, mass: 0.9 },
      opacity: { duration: 0.5, ease: [0.16, 1, 0.3, 1] },
      filter: { duration: 0.55, ease: [0.16, 1, 0.3, 1] },
    },
  },
};

export function SplitText({
  text,
  split = "word",
  className,
  stagger = 0.045,
  delay = 0,
  as = "span",
  renderToken,
}: SplitTextProps) {
  const reduced = useReducedMotion();

  // Tokens are split by whitespace for "word", or by Unicode segmenter for "char"
  // so multi-codepoint glyphs (emoji, CJK) stay intact.
  const tokens =
    split === "word"
      ? text.split(/(\s+)/)
      : Array.from(
          new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(
            text,
          ),
          (s) => s.segment,
        );

  const MotionTag = motion[as] as typeof motion.span;

  if (reduced) {
    return createElement(as, { className }, text);
  }

  return (
    <MotionTag
      className={className}
      variants={containerVariants(delay, stagger)}
      initial="hidden"
      animate="visible"
      aria-label={text}
    >
      {tokens.map((token, i) => {
        // Preserve whitespace exactly: render it raw, not as a motion token.
        if (/^\s+$/.test(token)) {
          return <span key={`ws-${i}`}>{token}</span>;
        }
        const content = renderToken ? renderToken(token, i) : token;
        return (
          <motion.span
            key={`${token}-${i}`}
            variants={tokenVariants}
            style={{ display: "inline-block", willChange: "transform, opacity" }}
            aria-hidden
          >
            {content}
          </motion.span>
        );
      })}
    </MotionTag>
  );
}
