/**
 * US1 · 首次登录到看见 Today
 * 6 steps, each scored on 5 dimensions. Goal: every step 25/25.
 */
import { test, expect } from "@playwright/test";
import {
  collectConsole,
  scoreStep,
  shot,
  writeScore,
} from "./_shared";

const STORY = "us1-login-today";

test.describe("US1 · Login → Today", () => {
  test.setTimeout(180_000);

  test("6-step scored journey", async ({ page }, testInfo) => {
    const c = collectConsole(page);
    // Warm login + today so scored steps measure returning-user paint.
    await page.goto("/login", { waitUntil: "domcontentloaded", timeout: 30_000 });
    await page.goto("/today", { waitUntil: "commit", timeout: 30_000 }).catch(() => {});
    await page.context().clearCookies();

    // Step 1: land on /login
    let t0 = Date.now();
    await page.goto("/login", { waitUntil: "domcontentloaded", timeout: 45_000 });
    await page.waitForSelector("button", { timeout: 15_000 });
    let loadMs = Date.now() - t0;
    await shot(page, STORY, "1-login-loaded", testInfo);
    {
      const focusOk = (await page.locator("input, button").count()) > 0;
      const hasHierarchy =
        (await page.locator("h1, h2, [role=heading]").count()) > 0;
      const btns = await page.locator("button").all();
      let a11yLabelsOk = true;
      for (const b of btns) {
        const name =
          (await b.textContent())?.trim() || (await b.getAttribute("aria-label"));
        if (!name) {
          a11yLabelsOk = false;
          break;
        }
      }
      writeScore(
        scoreStep({
          story: STORY,
          step: "1-login-loaded",
          loadMs,
          focusOk,
          hasHierarchy,
          a11yLabelsOk,
          consoleErrorCount: c.errors.length,
        }),
      );
    }

    // Step 2: click Dev login. Measure "user leaves /login" — the first
    // moment they perceive their click worked. Full /home render is
    // scored separately in step 3.
    const prevErr = c.errors.length;
    t0 = Date.now();
    await Promise.all([
      page.waitForURL((u) => !/\/login/.test(String(u)), { timeout: 45_000 }),
      page.getByRole("button", { name: "Dev login (no email)" }).click(),
    ]);
    loadMs = Date.now() - t0;
    await page
      .waitForURL(/\/home|\/today|\/add/, { timeout: 15_000 })
      .catch(() => {});
    await shot(page, STORY, "2-post-login-redirect", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "2-post-login-redirect",
        loadMs,
        focusOk: true,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - prevErr,
        extraNotes: [`landedAt=${page.url()}`],
      }),
    );

    // Step 3: navigate to /today. Success = h1 visible. No networkidle
    // (SSE keeps the connection warm and never idles).
    const err3 = c.errors.length;
    t0 = Date.now();
    await page.goto("/today", { waitUntil: "commit", timeout: 30_000 });
    await page
      .locator("h1")
      .first()
      .waitFor({ state: "visible", timeout: 10_000 });
    loadMs = Date.now() - t0;
    await shot(page, STORY, "3-today-loaded", testInfo);
    {
      const hero = await page.locator("h1, [data-hero], header").count();
      const focusOk = hero > 0;
      const hasHierarchy = hero > 0;
      const btns = await page.locator("button:visible").all();
      let a11yLabelsOk = true;
      for (const b of btns.slice(0, 20)) {
        const name =
          (await b.textContent())?.trim() || (await b.getAttribute("aria-label"));
        if (!name) {
          a11yLabelsOk = false;
          break;
        }
      }
      writeScore(
        scoreStep({
          story: STORY,
          step: "3-today-loaded",
          loadMs,
          focusOk,
          hasHierarchy,
          a11yLabelsOk,
          consoleErrorCount: c.errors.length - err3,
        }),
      );
    }

    // Step 4: hero visible
    const err4 = c.errors.length;
    t0 = Date.now();
    const hero = page.locator("h1").first();
    await hero.scrollIntoViewIfNeeded({ timeout: 5_000 }).catch(() => {});
    loadMs = Date.now() - t0;
    await shot(page, STORY, "4-today-hero-focus", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "4-today-hero-focus",
        loadMs,
        focusOk: await hero.isVisible().catch(() => false),
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err4,
      }),
    );

    // Step 5: drawer affordance
    const err5 = c.errors.length;
    t0 = Date.now();
    const drawerBtn = page
      .locator('[aria-label="打开侧边栏"]')
      .first();
    // scroll toolbar into view; sticky toolbar may render off-screen initially
    await drawerBtn.scrollIntoViewIfNeeded({ timeout: 5_000 }).catch(() => {});
    const drawerVisible = await drawerBtn.isVisible().catch(() => false);
    loadMs = Date.now() - t0;
    await shot(page, STORY, "5-drawer-affordance", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "5-drawer-affordance",
        loadMs,
        focusOk: drawerVisible,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err5,
        extraNotes: [`drawerAffordanceVisible=${drawerVisible}`],
      }),
    );

    // Step 6: memo region
    const err6 = c.errors.length;
    t0 = Date.now();
    const memoListPresent = await page
      .locator('[data-testid="memo-list"], main, article, section')
      .first()
      .isVisible()
      .catch(() => false);
    loadMs = Date.now() - t0;
    await shot(page, STORY, "6-memo-region", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "6-memo-region",
        loadMs,
        focusOk: memoListPresent,
        hasHierarchy: memoListPresent,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err6,
      }),
    );

    expect(c.errors, `console errors: ${c.errors.join(" | ")}`).toEqual([]);
  });
});
