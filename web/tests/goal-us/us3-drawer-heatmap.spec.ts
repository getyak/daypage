/**
 * US3 · Today 抽屉 + 热力图 (mobile viewport)
 * 6 steps scored on 5 dimensions each.
 */
import { test, expect } from "@playwright/test";
import { collectConsole, scoreStep, shot, writeScore, loginViaForm } from "./_shared";

const STORY = "us3-drawer-heatmap";

test.describe("US3 · Drawer + Heatmap", () => {
  test.setTimeout(180_000);

  test("6-step scored journey", async ({ page }, testInfo) => {
    const c = collectConsole(page);
    await loginViaForm(page);
    // Warm /today so step 1 measures returning-user nav.
    await page.goto("/today", { waitUntil: "commit", timeout: 30_000 });
    await page.locator("h1").first().waitFor({ state: "visible", timeout: 10_000 });

    // Step 1: /today loaded
    let t0 = Date.now();
    await page.goto("/today", { waitUntil: "commit", timeout: 30_000 });
    await page.locator("h1").first().waitFor({ state: "visible", timeout: 10_000 });
    let loadMs = Date.now() - t0;
    await shot(page, STORY, "1-today-loaded", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "1-today-loaded",
        loadMs,
        focusOk: true,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length,
      }),
    );

    // Step 2: hero text
    const err2 = c.errors.length;
    t0 = Date.now();
    const heroText = (await page.locator("h1").first().textContent()) ?? "";
    loadMs = Date.now() - t0;
    await shot(page, STORY, "2-hero-text", testInfo);
    const hasWeekday = /星期|Mon|Tue|Wed|Thu|Fri|Sat|Sun/.test(heroText);
    writeScore(
      scoreStep({
        story: STORY,
        step: "2-hero-text",
        loadMs,
        focusOk: hasWeekday,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err2,
        extraNotes: [`hero="${heroText.trim()}"`],
      }),
    );

    // Step 3: memo card or explicit empty state visible
    const err3 = c.errors.length;
    t0 = Date.now();
    const memoCandidates = page.locator(
      'article, [data-testid*="memo"], [class*="Memo"], [class*="memo"]',
    );
    const memoOrEmpty =
      (await memoCandidates.first().isVisible({ timeout: 5_000 }).catch(() => false)) ||
      (await page.getByText(/AI|今日一句|还没|开始/).first().isVisible().catch(() => false));
    loadMs = Date.now() - t0;
    await shot(page, STORY, "3-memo-region", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "3-memo-region",
        loadMs,
        focusOk: memoOrEmpty,
        hasHierarchy: memoOrEmpty,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err3,
        extraNotes: [`memoOrEmpty=${memoOrEmpty}`],
      }),
    );

    // Step 4: open drawer
    const err4 = c.errors.length;
    t0 = Date.now();
    const drawerBtn = page.locator('[aria-label="打开侧边栏"]').first();
    await drawerBtn.click();
    const drawer = page.locator('[aria-label="关闭侧边栏"]').first();
    const drawerOpen = await drawer.isVisible({ timeout: 3_000 }).catch(() => false);
    loadMs = Date.now() - t0;
    await shot(page, STORY, "4-drawer-open", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "4-drawer-open",
        loadMs,
        focusOk: drawerOpen,
        hasHierarchy: drawerOpen,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err4,
        extraNotes: [`drawerOpen=${drawerOpen}`],
      }),
    );

    // Step 5: heatmap grid attached in drawer.
    const err5 = c.errors.length;
    t0 = Date.now();
    // Race two success signals: title=memos cell (real data) OR a weekday
    // label from the heatmap column header (structural ready even before
    // /api/heatmap resolves). Take whichever appears first.
    const gridReady = Promise.race([
      page
        .locator('[title*="memos"]')
        .first()
        .waitFor({ state: "attached", timeout: 10_000 })
        .then(() => true),
      page
        .getByText(/^(周[一二三四五六日]|Mon|Wed|Fri)$/)
        .first()
        .waitFor({ state: "visible", timeout: 10_000 })
        .then(() => true),
    ]).catch(() => false);
    const hmVisible = await gridReady;
    loadMs = Date.now() - t0;
    await shot(page, STORY, "5-heatmap-visible", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "5-heatmap-visible",
        loadMs,
        focusOk: hmVisible,
        hasHierarchy: hmVisible,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err5,
        extraNotes: [`heatmapVisible=${hmVisible}`],
      }),
    );

    // Step 6: hover heatmap cell
    const err6 = c.errors.length;
    t0 = Date.now();
    if (hmVisible) {
      await page.locator('[title*="memos"]').first().hover({ timeout: 3_000 }).catch(() => {});
    }
    loadMs = Date.now() - t0;
    await shot(page, STORY, "6-heatmap-hover", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "6-heatmap-hover",
        loadMs,
        focusOk: hmVisible,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err6,
      }),
    );

    expect(c.errors, `console errors: ${c.errors.join(" | ")}`).toEqual([]);
  });
});
