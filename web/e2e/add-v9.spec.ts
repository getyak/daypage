/**
 * DayPage v9 design contract tests — /add page.
 *
 * Locks down the six load-bearing pieces we shipped in the /add refactor
 * (see docs/web-design-v9.md and this PR's commit body):
 *   1. CaptureHero exists on /add with a Fraunces serif date + uppercase
 *      mono-caps stats line.
 *   2. Composer container reads with the v9 elevation tokens (--elev-flat
 *      baseline, --elev-raise + accent ring on focus).
 *   3. Composer placeholder is `此刻在想什么？` and hint copy references
 *      "记下此刻，余下交给夜里" when focused-empty.
 *   4. Primary CTA is the amber pill "收下" (not the old 28×28 send square).
 *   5. Pipeline banner appears at most once on the page — every per-row
 *      "编译服务未连接" leak from v8 is gone.
 *   6. Ingest-mode pill uses the shared .chip--success / .chip--accent
 *      tokens (i.e. LIGHT/FULL semantic pills), not hand-rolled colour.
 *
 * Usage:
 *   BASE_URL=http://localhost:3000 pnpm exec playwright test \
 *     e2e/add-v9.spec.ts --project=desktop-chrome
 */
import { test, expect, type Page } from "@playwright/test";

// The project auth flow is the real /login form — dev seed user
// `dev@daypage.local` gets a session cookie via `Dev login (no email)`.
async function loginDev(page: Page) {
  await page.goto("/login", { waitUntil: "domcontentloaded" });
  await page.getByRole("button", { name: "Dev login (no email)" }).click();
  await page.waitForURL(/\/(home|today|add)/, { timeout: 15_000 }).catch(() => {
    /* some flows land back on /login when session already exists — ignore */
  });
}

test.describe("v9 design contract — /add", () => {
  // Cold Turbopack routes on dev can take up to ~90s to compile /add on the
  // first request (the app is 30+ routes and lazy-compiles). Give each test
  // a generous 3-min budget rather than false-fail on first paint.
  test.setTimeout(180_000);

  test.beforeEach(async ({ page }) => {
    await loginDev(page);
    await page.goto("/add", { waitUntil: "domcontentloaded" });
    // wait for hydrated composer — its testid renders client-side
    await page.getByTestId("add-composer").waitFor({ state: "visible", timeout: 60_000 });
    // Composer auto-focuses on mount when there's no localStorage draft
    // (see Composer.tsx `queueMicrotask(() => taRef.current?.focus())`). To
    // give every test a clean starting state, blur out to a neutral point
    // and wait for the 180ms shadow transition to settle.
    await page.mouse.click(2, 2);
    await page.waitForTimeout(240);
  });

  // Contract #1 — CaptureHero (Fraunces + mono caps) is visible at the top
  test("CaptureHero renders with Fraunces serif date + mono caps stats", async ({ page }) => {
    const hero = page.getByTestId("capture-hero");
    await expect(hero).toBeVisible();

    // date uses Fraunces
    const dateFontFamily = await hero.locator(".ds-home-hero__date").evaluate(
      (el) => window.getComputedStyle(el).fontFamily,
    );
    expect(dateFontFamily.toLowerCase()).toContain("fraunces");

    // stats line is mono-caps
    const stats = hero.locator(".ds-home-hero__stats");
    const statsTextTransform = await stats.evaluate(
      (el) => window.getComputedStyle(el).textTransform,
    );
    expect(statsTextTransform).toBe("uppercase");

    // ritual phrase is present verbatim
    await expect(stats).toContainText("RAW · CAPTURE MOMENT");
  });

  // Contract #2 — Composer elevation tokens (flat baseline, raise on focus)
  test("Composer boxShadow flips between flat baseline and lifted focus", async ({ page }) => {
    const composer = page.getByTestId("add-composer");
    await expect(composer).toBeVisible();

    // The Composer auto-focuses on mount (Round 5 UX: "open page = already
    // writing"). So we start in the focused state, blur out to sample the
    // baseline, then focus back and sample the lifted state. This proves the
    // two shadow tokens are wired up and different.
    const textarea = composer.locator("textarea").first();

    // Blur by clicking the body outside the composer (top-left corner is a
    // safe empty area — the sidebar rail sits there but its own click
    // handlers won't refocus the composer).
    await page.mouse.click(2, 2);
    await page.waitForTimeout(280);
    await expect(composer).toHaveAttribute("data-focused", "false");
    const baselineShadow = await composer.evaluate(
      (el) => window.getComputedStyle(el).boxShadow,
    );
    expect(baselineShadow).not.toBe("none");
    const baselineBorder = await composer.evaluate(
      (el) => window.getComputedStyle(el).borderTopColor,
    );

    // Focus and re-sample.
    await textarea.focus();
    await page.waitForTimeout(280);
    await expect(composer).toHaveAttribute("data-focused", "true");
    const focusedShadow = await composer.evaluate(
      (el) => window.getComputedStyle(el).boxShadow,
    );
    const focusedBorder = await composer.evaluate(
      (el) => window.getComputedStyle(el).borderTopColor,
    );

    // Contract: BOTH boxShadow and border-color must change between the two
    // states. Exact strings differ per browser / theme, so inequality is the
    // stable assertion.
    expect(focusedShadow).not.toBe(baselineShadow);
    expect(focusedBorder).not.toBe(baselineBorder);
  });

  // Contract #3 — placeholder + hint copy
  test("Composer placeholder is Chinese; focused-empty hint shows ritual phrase", async ({ page }) => {
    const textarea = page.getByTestId("add-composer").locator("textarea").first();
    await expect(textarea).toHaveAttribute("placeholder", "此刻在想什么？");

    await textarea.focus();
    const hint = page.getByTestId("composer-hint");
    await expect(hint).toBeVisible();
    await expect(hint).toContainText("记下此刻，余下交给夜里");
  });

  // Contract #4 — Send CTA is the "收下" pill (not the old 28×28 icon)
  test("Send CTA is the amber '收下' pill with a rounded shape", async ({ page }) => {
    const send = page.getByTestId("composer-send");
    await expect(send).toBeVisible();
    await expect(send).toContainText("收下");

    const box = await send.boundingBox();
    expect(box).not.toBeNull();
    // v9 pill is 36px tall and >= 60px wide (icon + "收下" glyphs)
    expect(box!.height).toBeGreaterThanOrEqual(32);
    expect(box!.width).toBeGreaterThanOrEqual(60);

    const radius = await send.evaluate(
      (el) => window.getComputedStyle(el).borderRadius,
    );
    // 999px pill — parses to a very large pixel value in most browsers
    expect(parseInt(radius, 10)).toBeGreaterThanOrEqual(16);
  });

  // Contract #5 — no per-row "编译服务未连接" leak
  test("pipeline warning appears at most once (single banner, not per row)", async ({ page }) => {
    const leakCount = await page
      .getByText("编译服务未连接", { exact: false })
      .count();
    // Either the banner shows once (pipeline down) or not at all (pipeline
    // up). Anything ≥ 2 means the old per-MemoRow debug string leaked back.
    expect(leakCount).toBeLessThanOrEqual(1);

    // And ABSOLUTELY no ops debug hint in any body copy on the page:
    const debugLeak = await page.getByText("pnpm run dev:inngest", { exact: false }).count();
    expect(debugLeak).toBe(0);
  });

  // Contract #6 — ingest-mode pill uses the semantic tokens
  test("ingest-mode pill uses chip--success or chip--accent", async ({ page }) => {
    // We only assert IF there's at least one recently-compiled row on this
    // page. Fresh envs have none — we skip in that case rather than fail.
    const pills = page.locator(".ds-add-mode-pill");
    const count = await pills.count();
    test.skip(count === 0, "no memos yet — nothing to pill");

    for (let i = 0; i < count; i++) {
      const cls = (await pills.nth(i).getAttribute("class")) ?? "";
      const isSemantic =
        cls.includes("chip--success") || cls.includes("chip--accent");
      expect(isSemantic, `pill #${i} classes = ${cls}`).toBe(true);
    }
  });
});
