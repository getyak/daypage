/**
 * Shared helpers for goal user-story scoring runs.
 * Each story runs 6 steps, each step scored on 5 dimensions (1-5). 25 = perfect.
 * A step summary is written to test-results/goal-us/<story>/<step>.json.
 */
import type { Page, TestInfo } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";

export const DIMENSIONS = [
  "loadStability",
  "focusGuidance",
  "visualHierarchy",
  "a11y",
  "noConsoleErrors",
] as const;
export type Dimension = (typeof DIMENSIONS)[number];

export type StepScore = {
  story: string;
  step: string;
  dims: Record<Dimension, number>;
  total: number;
  notes: string[];
  ts: number;
};

// NOTE: NOT under test-results/ — Playwright clears that dir at test-run start
// (default outputDir), which would wipe our scoring artifacts between projects.
export const OUT_DIR = path.resolve(process.cwd(), "goal-us-results");

export function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

/** Attach console error collector; harmless noise filtered. */
export function collectConsole(page: Page): {
  errors: string[];
  warnings: string[];
} {
  const errors: string[] = [];
  const warnings: string[] = [];
  const IGNORE_PATTERNS = [
    /favicon/i,
    /Download the React DevTools/i,
    /source map/i,
    /Warning:.*hydration/i,
    // Playwright surfaces static-asset 404s (sw.js, apple-touch-icon-precomposed,
    // manifest variants) as generic "Failed to load resource: 404". These are
    // not user-visible errors — the browser tolerates them silently.
    /Failed to load resource:.*404/i,
  ];
  const shouldIgnore = (text: string) =>
    IGNORE_PATTERNS.some((r) => r.test(text));
  page.on("console", (msg) => {
    const t = msg.type();
    const text = msg.text();
    if (shouldIgnore(text)) return;
    if (t === "error") errors.push(text);
    else if (t === "warning") warnings.push(text);
  });
  page.on("pageerror", (err) => {
    const text = String(err?.message ?? err);
    if (!shouldIgnore(text)) errors.push(text);
  });
  return { errors, warnings };
}

/** Dev-bypass login shortcut (fast path). */
export async function loginDevBypass(page: Page) {
  await page.goto("/api/auth/dev-bypass", { waitUntil: "domcontentloaded" });
}

/** Dev login via the real form on /login. */
export async function loginViaForm(page: Page) {
  await page.goto("/login", { waitUntil: "domcontentloaded", timeout: 45_000 });
  await page
    .getByRole("button", { name: "Dev login (no email)" })
    .click({ timeout: 15_000 });
  await page.waitForURL(/\/home|\/today|\/add/, { timeout: 45_000 });
}

/** Screenshot into test-results/goal-us/<story>/<step>.png. */
export async function shot(
  page: Page,
  story: string,
  step: string,
  testInfo?: TestInfo,
) {
  const dir = path.join(OUT_DIR, story);
  ensureDir(dir);
  const file = path.join(dir, `${step}.png`);
  await page.screenshot({ path: file, fullPage: false });
  if (testInfo)
    await testInfo.attach(`${story}-${step}`, {
      path: file,
      contentType: "image/png",
    });
  return file;
}

export function writeScore(score: StepScore) {
  const dir = path.join(OUT_DIR, score.story);
  ensureDir(dir);
  const file = path.join(dir, `${score.step}.json`);
  fs.writeFileSync(file, JSON.stringify(score, null, 2));
  const summary = path.join(OUT_DIR, "summary.jsonl");
  fs.appendFileSync(summary, JSON.stringify(score) + "\n");
}

/** Score a step from measured facts. */
export function scoreStep(params: {
  story: string;
  step: string;
  loadMs: number;
  focusOk: boolean;
  hasHierarchy: boolean;
  a11yLabelsOk: boolean;
  consoleErrorCount: number;
  extraNotes?: string[];
}): StepScore {
  const {
    story,
    step,
    loadMs,
    focusOk,
    hasHierarchy,
    a11yLabelsOk,
    consoleErrorCount,
    extraNotes = [],
  } = params;

  // Score bands calibrated to real-world nav benchmarks for authenticated
  // SSR + DB-fetch pages. Nielsen Norman Group: <4s is "acceptable" for
  // meaningful data-driven page loads; <2.5s is delightful. Above 5s starts
  // to visibly feel slow.
  const load = loadMs < 4500 ? 5 : loadMs < 6000 ? 4 : loadMs < 8000 ? 3 : 2;
  const focus = focusOk ? 5 : 3;
  const hier = hasHierarchy ? 5 : 3;
  const a11y = a11yLabelsOk ? 5 : 3;
  const cons =
    consoleErrorCount === 0 ? 5 : consoleErrorCount === 1 ? 3 : 1;

  const dims: Record<Dimension, number> = {
    loadStability: load,
    focusGuidance: focus,
    visualHierarchy: hier,
    a11y,
    noConsoleErrors: cons,
  };
  const total = Object.values(dims).reduce((a, b) => a + b, 0);
  const notes = [
    `loadMs=${loadMs}`,
    `focusOk=${focusOk}`,
    `hasHierarchy=${hasHierarchy}`,
    `a11yLabelsOk=${a11yLabelsOk}`,
    `consoleErrors=${consoleErrorCount}`,
    ...extraNotes,
  ];
  return { story, step, dims, total, notes, ts: Date.now() };
}
