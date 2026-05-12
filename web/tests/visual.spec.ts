/**
 * Visual regression baseline tests for DayPage Web (V5 Codex).
 *
 * Routes covered: /login, /home, /add, /inbox, /wiki, /chat,
 *                 /domain/unknown (branded empty state)
 * Viewports: desktop (1440px) + mobile (375px) per project config.
 *
 * First run  → creates baseline snapshots under tests/__screenshots__/
 * Subsequent → diffs against baseline; >0.1% pixel diff = regression
 *
 * Seed baselines:
 *   pnpm exec playwright test tests/visual.spec.ts --update-snapshots
 * Diff run:
 *   pnpm exec playwright test tests/visual.spec.ts
 */

import { test, expect } from "@playwright/test";

async function loginDevBypass(page: import("@playwright/test").Page) {
  await page.goto("/api/auth/dev-bypass", { waitUntil: "networkidle" });
}

// ─── /login (unauthenticated) ──────────────────────────────────────────────────

test.describe("login", () => {
  test("renders login page", async ({ page }) => {
    await page.goto("/login", { waitUntil: "networkidle" });
    await expect(page).toHaveScreenshot("login.png", { fullPage: true });
  });
});

// ─── Authenticated routes ──────────────────────────────────────────────────────

test.describe("authenticated", () => {
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

// ─── Mobile layout ─────────────────────────────────────────────────────────────

test.describe("mobile layout", () => {
  test.use({ viewport: { width: 375, height: 812 } });

  test.beforeEach(async ({ page }) => {
    await loginDevBypass(page);
  });

  test("/home has no horizontal scroll at 375px", async ({ page }) => {
    await page.goto("/home", { waitUntil: "networkidle" });
    const hasScroll = await page.evaluate(
      () =>
        document.documentElement.scrollWidth >
        document.documentElement.clientWidth
    );
    expect(hasScroll, "horizontal scroll at 375px").toBe(false);
    await expect(page).toHaveScreenshot("home-mobile.png", { fullPage: true });
  });

  test("/add has no horizontal scroll at 375px", async ({ page }) => {
    await page.goto("/add", { waitUntil: "networkidle" });
    const hasScroll = await page.evaluate(
      () =>
        document.documentElement.scrollWidth >
        document.documentElement.clientWidth
    );
    expect(hasScroll, "horizontal scroll at 375px").toBe(false);
    await expect(page).toHaveScreenshot("add-mobile.png", { fullPage: true });
  });
});
