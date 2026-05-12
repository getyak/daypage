/**
 * Visual baseline tests for DayPage Web (V5 Codex).
 * Captures screenshots at desktop (1440px), tablet (768px), and mobile (375px) viewports.
 * Routes covered: /login, /home, /add, /inbox, /wiki, /chat, /domain (empty slug → branded 404)
 *
 * On first run these tests CREATE the baseline snapshots.
 * On subsequent runs they DIFF against the baseline — failures indicate visual regressions.
 *
 * Usage:
 *   pnpm exec playwright test e2e/visual-baseline.spec.ts --update-snapshots   # seed baselines
 *   pnpm exec playwright test e2e/visual-baseline.spec.ts                      # diff run
 */

import { test, expect } from "@playwright/test";

// dev-bypass cookie name expected by the app's auth middleware
const DEV_BYPASS_COOKIE = "dev-auth-bypass";

async function loginDevBypass(page: import("@playwright/test").Page) {
  // Hit the dev-bypass endpoint which sets a session cookie
  await page.goto("/api/auth/dev-bypass", { waitUntil: "networkidle" });
}

// ─── Login page (unauthenticated) ─────────────────────────────────────────────

test.describe("login", () => {
  test("login page renders", async ({ page }) => {
    await page.goto("/login", { waitUntil: "networkidle" });
    await expect(page).toHaveScreenshot("login.png", { fullPage: true });
  });
});

// ─── Authenticated routes ──────────────────────────────────────────────────────

test.describe("authenticated routes", () => {
  test.beforeEach(async ({ page }) => {
    await loginDevBypass(page);
  });

  test("/home renders", async ({ page }) => {
    await page.goto("/home", { waitUntil: "networkidle" });
    await expect(page).toHaveScreenshot("home.png", { fullPage: true });
  });

  test("/add renders", async ({ page }) => {
    await page.goto("/add", { waitUntil: "networkidle" });
    await expect(page).toHaveScreenshot("add.png", { fullPage: true });
  });

  test("/inbox renders", async ({ page }) => {
    await page.goto("/inbox", { waitUntil: "networkidle" });
    await expect(page).toHaveScreenshot("inbox.png", { fullPage: true });
  });

  test("/wiki renders", async ({ page }) => {
    await page.goto("/wiki", { waitUntil: "networkidle" });
    await expect(page).toHaveScreenshot("wiki.png", { fullPage: true });
  });

  test("/chat renders", async ({ page }) => {
    await page.goto("/chat", { waitUntil: "networkidle" });
    await expect(page).toHaveScreenshot("chat.png", { fullPage: true });
  });

  test("/domain/unknown renders branded empty state", async ({ page }) => {
    await page.goto("/domain/unknown-slug-for-baseline", {
      waitUntil: "networkidle",
    });
    await expect(page).toHaveScreenshot("domain-404.png", { fullPage: true });
  });
});

// ─── Mobile layout — no horizontal scroll ─────────────────────────────────────

test.describe("mobile layout", () => {
  test.use({ viewport: { width: 375, height: 812 } });

  test.beforeEach(async ({ page }) => {
    await loginDevBypass(page);
  });

  test("/home has no horizontal scroll at 375px", async ({ page }) => {
    await page.goto("/home", { waitUntil: "networkidle" });
    const hasScroll = await page.evaluate(
      () => document.documentElement.scrollWidth > document.documentElement.clientWidth
    );
    expect(hasScroll, "horizontal scroll detected at 375px").toBe(false);
    await expect(page).toHaveScreenshot("home-mobile.png", { fullPage: true });
  });

  test("/add has no horizontal scroll at 375px", async ({ page }) => {
    await page.goto("/add", { waitUntil: "networkidle" });
    const hasScroll = await page.evaluate(
      () => document.documentElement.scrollWidth > document.documentElement.clientWidth
    );
    expect(hasScroll, "horizontal scroll detected at 375px").toBe(false);
    await expect(page).toHaveScreenshot("add-mobile.png", { fullPage: true });
  });
});
