/**
 * DayPage v9 design contract tests — /add page.
 *
 * Locks down the six load-bearing pieces we shipped in the /add refactor
 * (see docs/web-design-v9.md and this PR's commit body):
 *   1. Capture starts with writing/voice, with no queue/compiled dashboard.
 *   2. Capture stays flat on focus, with a visible writing focus indicator
 *      and navigation available on demand (GET-285).
 *   3. The empty editor has a clear placeholder without a repeated footer prompt.
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

// Use an explicitly supplied account in the configured acceptance realm.
// Credentials stay in the local test process and never enter screenshots/logs.
async function loginDev(page: Page) {
  const email = process.env.DAYPAGE_E2E_EMAIL;
  const password = process.env.DAYPAGE_E2E_PASSWORD;
  test.skip(!email || !password, "DAYPAGE_E2E_EMAIL and DAYPAGE_E2E_PASSWORD are required");
  await page.goto("/login?callbackUrl=%2Fadd", { waitUntil: "domcontentloaded" });
  const form = page.locator(".login-password-form");
  await form.locator('input[name="email"]').fill(email!);
  await form.locator('input[name="password"]').fill(password!);
  await form.locator('button[type="submit"]').click();
  await page.waitForURL(/\/add(?:\?|$)/, { timeout: 30_000 });
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

  test("capture leads with a large editor and visible voice; organization is explicit", async ({ page }) => {
    const hero = page.getByTestId("capture-hero");
    await expect(hero.getByRole("heading", { name: "先留下此刻。" })).toBeVisible();
    await expect(hero).toContainText("写下来，或说一段");
    await expect(hero).not.toContainText(/IN QUEUE|COMPILED|CAPTURE MOMENT/);
    const composer = page.getByTestId("add-composer");
    await expect(composer.getByTestId("capture-voice")).toBeVisible();
    await expect(composer.getByRole("button", { name: "粗体", exact: true })).toHaveCount(0);
    const height = await composer.locator("textarea").evaluate((el) => el.getBoundingClientRect().height);
    expect(height).toBeGreaterThanOrEqual(180);
    const organized = page.locator("details.capture-organized");
    await expect(organized.locator("div").first()).toBeHidden();
    await organized.locator("summary").click();
    await expect(organized.locator("div").first()).toBeVisible();
  });

  // GET-285: focus belongs to writing rather than lifting a card.
  test("capture stays flat and navigation yields to the writing surface", async ({ page }) => {
    const composer = page.getByTestId("add-composer");
    await expect(composer).toBeVisible();

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
    expect(baselineShadow).toBe("none");
    await expect(page.locator(".app-shell > .sb")).toBeHidden();
    await expect(page.getByRole("button", { name: "Open navigation menu" })).toBeVisible();
    const editorShare = await textarea.evaluate((el) => el.getBoundingClientRect().height / window.innerHeight);
    expect(editorShare).toBeGreaterThanOrEqual(0.5);

    // Focus and re-sample.
    await textarea.focus();
    await page.waitForTimeout(280);
    await expect(composer).toHaveAttribute("data-focused", "true");
    const focusedShadow = await composer.evaluate(
      (el) => window.getComputedStyle(el).boxShadow,
    );
    expect(focusedShadow).toBe("none");
    const focus = await textarea.evaluate((el) => ({
      outline: parseFloat(getComputedStyle(el).outlineWidth),
      fontSize: parseFloat(getComputedStyle(el).fontSize),
    }));
    expect(focus.outline).toBeGreaterThanOrEqual(1);
    expect(focus.fontSize).toBeGreaterThanOrEqual(16);
  });

  // Contract #3 — placeholder + hint copy
  test("Composer uses a clear placeholder without a repeated empty prompt", async ({ page }) => {
    const textarea = page.getByTestId("add-composer").locator("textarea").first();
    await expect(textarea).toHaveAttribute("placeholder", "此刻在想什么？");

    await textarea.focus();
    const hint = page.getByTestId("composer-hint");
    await expect(hint).toHaveCount(0);
  });

  test("navigation and New domain keep separate keyboard focus boundaries", async ({ page }) => {
    const menuTrigger = page.getByRole("button", { name: "Open navigation menu", exact: true });
    await menuTrigger.click();
    const menu = page.getByRole("dialog", { name: "Navigation menu", exact: true });
    const newDomain = menu.getByRole("button", { name: "New domain", exact: true });
    await newDomain.click();
    const dialog = page.getByRole("dialog", { name: "New Domain", exact: true });
    const name = dialog.getByLabel("Domain name", { exact: true });
    await expect(name).toBeFocused();
    await expect(page.locator(".app-shell")).toHaveAttribute("inert", "");
    await name.press("Shift+Tab");
    const close = dialog.getByRole("button", { name: "Close", exact: true });
    await expect(close).toBeFocused();
    await close.press("Shift+Tab");
    await expect(dialog.getByRole("button", { name: "Cancel", exact: true })).toBeFocused();
    await dialog.press("Escape");
    await expect(dialog).toHaveCount(0);
    await expect(newDomain).toBeFocused();
    await expect(menu).toBeVisible();
    await newDomain.press("Escape");
    await expect(menu).toBeHidden();
    await expect(menuTrigger).toBeFocused();
  });

  test("a failed save keeps the draft available after reload", async ({ page }) => {
    const draft = "GET-285 synthetic save recovery";
    await page.route("**/api/memos", (route) => route.fulfill({
      status: 503,
      contentType: "application/json",
      body: JSON.stringify({ error: "Synthetic save failure" }),
    }));
    const editor = page.getByTestId("add-composer").locator("textarea").first();
    await editor.fill(draft);
    await page.getByTestId("composer-send").click();
    await expect(page.getByRole("button", { name: "发送失败 · 点击重试", exact: true })).toBeVisible();
    await expect(editor).toHaveValue(draft);
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(editor).toHaveValue(draft);
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
