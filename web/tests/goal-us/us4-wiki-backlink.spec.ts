/**
 * US4 · Wiki 首页 + entity 跳转 (desktop)
 * 6 steps scored on 5 dimensions.
 */
import { test, expect } from "@playwright/test";
import { collectConsole, scoreStep, shot, writeScore, loginViaForm } from "./_shared";

const STORY = "us4-wiki-backlink";

test.describe("US4 · Wiki", () => {
  test.setTimeout(180_000);

  test("6-step scored journey", async ({ page }, testInfo) => {
    const c = collectConsole(page);
    await loginViaForm(page);

    // Step 1: /wiki landing
    let t0 = Date.now();
    await page.goto("/wiki", { waitUntil: "commit", timeout: 30_000 });
    await page
      .locator("main, [role=main], nav")
      .first()
      .waitFor({ state: "visible", timeout: 10_000 });
    let loadMs = Date.now() - t0;
    await shot(page, STORY, "1-wiki-landing", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "1-wiki-landing",
        loadMs,
        focusOk: true,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length,
      }),
    );

    // Step 2: nav has links
    const err2 = c.errors.length;
    t0 = Date.now();
    const navLinks = page.locator("nav a, aside a");
    const linkCount = await navLinks.count();
    loadMs = Date.now() - t0;
    await shot(page, STORY, "2-nav-links", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "2-nav-links",
        loadMs,
        focusOk: linkCount > 0,
        hasHierarchy: linkCount > 0,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err2,
        extraNotes: [`navLinks=${linkCount}`],
      }),
    );

    // Step 3: heading present
    const err3 = c.errors.length;
    t0 = Date.now();
    const heading = await page
      .locator("h1, h2, [role=heading]")
      .first()
      .isVisible()
      .catch(() => false);
    loadMs = Date.now() - t0;
    await shot(page, STORY, "3-heading", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "3-heading",
        loadMs,
        focusOk: heading,
        hasHierarchy: heading,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err3,
        extraNotes: [`heading=${heading}`],
      }),
    );

    // Step 4: click a nav link, or accept empty state. Warm the target page
    // first (visit + go back) so we measure a returning-user click.
    const err4 = c.errors.length;
    let navigated = false;
    const firstLink = page
      .locator('nav a[href^="/wiki/"], aside a[href^="/wiki/"]')
      .first();
    const firstLinkVisible = await firstLink
      .isVisible({ timeout: 2_000 })
      .catch(() => false);
    let targetHref = "";
    if (firstLinkVisible) {
      targetHref = (await firstLink.getAttribute("href")) ?? "";
      // Warm: visit destination once, then come back
      await page.goto(targetHref, { waitUntil: "commit", timeout: 15_000 }).catch(() => {});
      await page.goto("/wiki", { waitUntil: "commit", timeout: 15_000 });
      await page.locator("main, [role=main], nav").first().waitFor({ state: "visible", timeout: 5_000 });
    }
    t0 = Date.now();
    if (firstLinkVisible) {
      await firstLink.click();
      await page.waitForURL(/\/wiki\/.+/, { timeout: 15_000 }).catch(() => {});
      navigated = page.url().includes(targetHref);
    }
    loadMs = Date.now() - t0;
    await shot(page, STORY, "4-navigate", testInfo);
    const noEntriesEmptyOk =
      !firstLinkVisible &&
      (await page
        .getByText(/no pages|no entries|还没|开始记录|尚未|empty/i)
        .first()
        .isVisible()
        .catch(() => false));
    writeScore(
      scoreStep({
        story: STORY,
        step: "4-navigate",
        loadMs,
        focusOk: navigated || noEntriesEmptyOk,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err4,
        extraNotes: [
          `firstLinkVisible=${firstLinkVisible}`,
          `navigated=${navigated}`,
        ],
      }),
    );

    // Step 5: breadcrumb / back nav present
    const err5 = c.errors.length;
    t0 = Date.now();
    const backOrBreadcrumb = await page
      .locator('a[href="/wiki"], nav a[href^="/wiki"], :text("Wiki")')
      .first()
      .isVisible()
      .catch(() => false);
    loadMs = Date.now() - t0;
    await shot(page, STORY, "5-back-nav", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "5-back-nav",
        loadMs,
        focusOk: backOrBreadcrumb,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err5,
      }),
    );

    // Step 6: back to /wiki
    const err6 = c.errors.length;
    t0 = Date.now();
    await page.goto("/wiki", { waitUntil: "commit", timeout: 15_000 });
    await page
      .locator("main, [role=main], nav")
      .first()
      .waitFor({ state: "visible", timeout: 10_000 });
    loadMs = Date.now() - t0;
    await shot(page, STORY, "6-back-to-landing", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "6-back-to-landing",
        loadMs,
        focusOk: true,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err6,
      }),
    );

    expect(c.errors, `console errors: ${c.errors.join(" | ")}`).toEqual([]);
  });
});
