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
  gestures: Record<string, number>;
  // `dark` intentionally not consumed on iOS — SwiftUI adapts via Color
  // literals against the environment's colorScheme rather than swapping
  // CSS variables. If iOS ever needs an explicit dark-token entry, add
  // a `DarkColors` enum here.
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
  out.push(``);
  out.push(`enum DSTokens {`);
  out.push(`    static let version = "${t.version}"`);
  out.push(``);

  // Colors
  out.push(`    enum Colors {`);
  for (const [k, v] of Object.entries(t.colors)) {
    const [r, g, b] = hexToRGB(v);
    out.push(`        /// ${v}`);
    out.push(`        static let ${camel(k)} = Color(red: ${fmt(r)}, green: ${fmt(g)}, blue: ${fmt(b)})`);
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

  // Gestures
  out.push(`    enum Gestures {`);
  for (const [k, v] of Object.entries(t.gestures)) {
    out.push(`        static let ${camel(k)}: CGFloat = ${fmt(v)}`);
  }
  out.push(`    }`);
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
