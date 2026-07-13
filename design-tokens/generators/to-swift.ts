#!/usr/bin/env node
// Generates DayPage/App/DSTokens.swift from tokens.json.
// Run: node --experimental-strip-types design-tokens/generators/to-swift.ts

import { readFileSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

type Tokens = {
  version: string;
  colors: Record<string, string>;
  fonts: Record<string, string>;
  fontSize: Record<string, number>;
  radii: Record<string, number>;
  shadows: Record<string, string>;
  elevation: Record<string, string>;
  spacing: Record<string, number>;
  motion: Record<string, string | number>;
  // Optional: the `gestures` group was removed once its tokens went unused
  // (the real swipe constants live in SwipePhysics). Kept optional so an
  // absent group emits no `enum Gestures` rather than crashing the generator.
  gestures?: Record<string, number>;
  // Dark-mode variants. Colors with a `dark.colors` counterpart are emitted
  // as adaptive UIColor dynamic providers so DSTokens.Colors no longer sinks
  // in dark mode; colors without one stay static. `dark.elevation` is
  // emitted alongside the light references for use-site mapping.
  dark?: {
    colors?: Record<string, string>;
    elevation?: Record<string, string>;
  };
};

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..", "..");
const TOKENS_PATH = join(ROOT, "design-tokens", "tokens.json");
const SWIFT_PATH = join(ROOT, "DayPage", "App", "DSTokens.swift");

// kebab-case → camelCase identifier.
function camel(name: string): string {
  return name.replace(/-([a-z0-9])/gi, (_, c: string) => c.toUpperCase());
}

// "#RRGGBB" → (r, g, b) doubles in [0,1].
function hexToRGB(hex: string): [number, number, number] {
  const h = hex.replace("#", "");
  const r = parseInt(h.slice(0, 2), 16) / 255;
  const g = parseInt(h.slice(2, 4), 16) / 255;
  const b = parseInt(h.slice(4, 6), 16) / 255;
  return [r, g, b];
}

function fmt(n: number): string {
  return Number.isInteger(n) ? n.toFixed(1) : String(n);
}

function buildSwift(t: Tokens): string {
  const out: string[] = [];
  out.push(`// DSTokens.swift — DayPage v${t.version} design tokens.`);
  out.push(`// DO NOT EDIT by hand. Edit design-tokens/tokens.json and run \`make tokens-build\`.`);
  out.push(`//`);
  out.push(`// Source of truth: design-tokens/tokens.json`);
  out.push(``);
  out.push(`import SwiftUI`);
  out.push(`import UIKit`);
  out.push(``);
  out.push(`enum DSTokens {`);
  out.push(`    static let version = "${t.version}"`);
  out.push(``);

  // Colors — tokens with a dark.colors counterpart become adaptive dynamic
  // providers; the rest stay static (single value valid in both schemes).
  const darkColors = t.dark?.colors ?? {};
  out.push(`    enum Colors {`);
  for (const [k, v] of Object.entries(t.colors)) {
    const [r, g, b] = hexToRGB(v);
    const dark = darkColors[k];
    if (dark) {
      const [dr, dg, db] = hexToRGB(dark);
      out.push(`        /// light ${v} / dark ${dark}`);
      out.push(`        static let ${camel(k)} = Color(UIColor { traits in`);
      out.push(`            traits.userInterfaceStyle == .dark`);
      out.push(`                ? UIColor(red: ${fmt(dr)}, green: ${fmt(dg)}, blue: ${fmt(db)}, alpha: 1.0)`);
      out.push(`                : UIColor(red: ${fmt(r)}, green: ${fmt(g)}, blue: ${fmt(b)}, alpha: 1.0)`);
      out.push(`        })`);
    } else {
      out.push(`        /// ${v}`);
      out.push(`        static let ${camel(k)} = Color(red: ${fmt(r)}, green: ${fmt(g)}, blue: ${fmt(b)})`);
    }
  }
  out.push(`    }`);
  out.push(``);

  // Fonts (postscript-style family names)
  out.push(`    enum Fonts {`);
  for (const [k, v] of Object.entries(t.fonts)) {
    out.push(`        static let ${camel(k)} = "${v}"`);
  }
  out.push(`    }`);
  out.push(``);

  // Font sizes
  out.push(`    enum FontSize {`);
  for (const [k, v] of Object.entries(t.fontSize)) {
    out.push(`        static let ${camel(k)}: CGFloat = ${fmt(v)}`);
  }
  out.push(`    }`);
  out.push(``);

  // Radii
  out.push(`    enum Radii {`);
  for (const [k, v] of Object.entries(t.radii)) {
    out.push(`        static let ${camel(k)}: CGFloat = ${fmt(v)}`);
  }
  out.push(`    }`);
  out.push(``);

  // Shadows — kept as raw CSS strings for reference; Swift shadow consumers
  // should map to (color, radius, x, y) at the use site.
  out.push(`    enum Shadows {`);
  for (const [k, v] of Object.entries(t.shadows)) {
    out.push(`        /// CSS reference: ${v}`);
    out.push(`        static let ${camel(k)} = ${JSON.stringify(v)}`);
  }
  out.push(`    }`);
  out.push(``);

  // Elevation — v9 three-tier semantic shadow scale (flat / raise / float).
  // Same string-reference convention as Shadows; SwiftUI callers translate
  // at the use site.
  out.push(`    enum Elevation {`);
  for (const [k, v] of Object.entries(t.elevation)) {
    out.push(`        /// CSS reference: ${v}`);
    out.push(`        static let ${camel(k)} = ${JSON.stringify(v)}`);
  }
  const darkElevation = t.dark?.elevation ?? {};
  if (Object.keys(darkElevation).length > 0) {
    out.push(``);
    out.push(`        // Dark-scheme shadow references — black-based, higher opacity`);
    out.push(`        // (warm-ink shadows disappear on dark canvases).`);
    for (const [k, v] of Object.entries(darkElevation)) {
      out.push(`        /// CSS reference (dark): ${v}`);
      out.push(`        static let ${camel(k)}Dark = ${JSON.stringify(v)}`);
    }
  }
  out.push(`    }`);
  out.push(``);

  // Spacing
  out.push(`    enum Spacing {`);
  for (const [k, v] of Object.entries(t.spacing)) {
    out.push(`        static let ${camel(k)}: CGFloat = ${fmt(v)}`);
  }
  out.push(`    }`);
  out.push(``);

  // Motion — durations in seconds (TimeInterval), curves as strings.
  out.push(`    enum Motion {`);
  for (const [k, v] of Object.entries(t.motion)) {
    if (typeof v === "number") {
      out.push(`        /// ${v}ms`);
      out.push(`        static let ${camel(k)}: TimeInterval = ${(v / 1000).toFixed(3)}`);
    } else {
      out.push(`        static let ${camel(k)} = ${JSON.stringify(v)}`);
    }
  }
  out.push(`    }`);
  out.push(``);

  // Gestures (optional — omitted entirely when the group is absent)
  if (t.gestures && Object.keys(t.gestures).length > 0) {
    out.push(`    enum Gestures {`);
    for (const [k, v] of Object.entries(t.gestures)) {
      out.push(`        static let ${camel(k)}: CGFloat = ${fmt(v)}`);
    }
    out.push(`    }`);
  }
  out.push(`}`);
  out.push(``);

  return out.join("\n");
}

function main() {
  const tokens: Tokens = JSON.parse(readFileSync(TOKENS_PATH, "utf8"));
  const swift = buildSwift(tokens);

  let current = "";
  try {
    current = readFileSync(SWIFT_PATH, "utf8");
  } catch {
    // file doesn't exist yet
  }

  if (current !== swift) {
    writeFileSync(SWIFT_PATH, swift);
    console.log(`[tokens] wrote ${SWIFT_PATH}`);
  } else {
    console.log(`[tokens] ${SWIFT_PATH} already up to date`);
  }
}

main();
