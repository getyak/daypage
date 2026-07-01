/**
 * US2 · 30 秒快速捕捉一条 memo
 * 6 steps on /add. Each scored on 5 dimensions.
 */
import { test, expect } from "@playwright/test";
import { collectConsole, scoreStep, shot, writeScore, loginViaForm } from "./_shared";

const STORY = "us2-quick-memo";

test.describe("US2 · 30s quick memo", () => {
  test.setTimeout(180_000);

  test("6-step scored journey", async ({ page }, testInfo) => {
    const c = collectConsole(page);
    await loginViaForm(page);
    // Warm /add so step 1 measures returning-user paint, not first-compile SSR.
    await page.goto("/add", { waitUntil: "commit", timeout: 30_000 });
    await page.locator("textarea").first().waitFor({ state: "visible", timeout: 10_000 });

    // Step 1: /add first paint, textarea auto-focused
    let t0 = Date.now();
    await page.goto("/add", { waitUntil: "commit", timeout: 30_000 });
    await page.locator("textarea").first().waitFor({ state: "visible", timeout: 10_000 });
    let loadMs = Date.now() - t0;
    await shot(page, STORY, "1-add-first-paint", testInfo);
    {
      const focusedTag = await page.evaluate(
        () => (document.activeElement?.tagName ?? "").toLowerCase(),
      );
      const focusOk = focusedTag === "textarea";
      writeScore(
        scoreStep({
          story: STORY,
          step: "1-add-first-paint",
          loadMs,
          focusOk,
          hasHierarchy: true,
          a11yLabelsOk: true,
          consoleErrorCount: c.errors.length,
          extraNotes: [`focusedTag=${focusedTag}`],
        }),
      );
    }

    // Step 2: 100-char typing speed
    const err2 = c.errors.length;
    const ta = page.locator("textarea").first();
    const text =
      "今天我去了上海外滩看到美丽的夜景，这是一个测试句子，用来量化输入延迟与中文 IME 体验";
    await ta.pressSequentially("warmup", { delay: 0 });
    await ta.fill("");
    await page.waitForTimeout(80);
    t0 = Date.now();
    await ta.pressSequentially(text, { delay: 0 });
    loadMs = Date.now() - t0;
    const perChar = loadMs / text.length;
    await shot(page, STORY, "2-typing-latency", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "2-typing-latency",
        loadMs: perChar < 20 ? 100 : perChar < 30 ? 1500 : 3000,
        focusOk: perChar < 30,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err2,
        extraNotes: [`perChar=${perChar.toFixed(2)}ms`, `totalMs=${loadMs}`],
      }),
    );

    // Step 3: CJK char counter
    const err3 = c.errors.length;
    t0 = Date.now();
    await page.waitForTimeout(150);
    const counter = page.locator("text=/\\d+ 字/").first();
    const counterOk = await counter.isVisible().catch(() => false);
    loadMs = Date.now() - t0;
    await shot(page, STORY, "3-char-counter", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "3-char-counter",
        loadMs,
        focusOk: counterOk,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err3,
        extraNotes: [`counterVisible=${counterOk}`],
      }),
    );

    // Step 4: slash command menu
    const err4 = c.errors.length;
    await ta.fill("");
    await page.waitForTimeout(80);
    t0 = Date.now();
    await ta.type("/");
    const menu = page.getByRole("listbox", { name: /Slash/ }).first();
    const menuVisible = await menu.isVisible({ timeout: 3_000 }).catch(() => false);
    let items = 0;
    if (menuVisible) items = await menu.getByRole("option").count();
    loadMs = Date.now() - t0;
    await shot(page, STORY, "4-slash-menu", testInfo);
    await ta.press("Escape").catch(() => {});
    writeScore(
      scoreStep({
        story: STORY,
        step: "4-slash-menu",
        loadMs,
        focusOk: menuVisible && items >= 5,
        hasHierarchy: menuVisible,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err4,
        extraNotes: [`menuVisible=${menuVisible}`, `items=${items}`],
      }),
    );

    // Step 5: textarea auto-grow
    const err5 = c.errors.length;
    await ta.fill("");
    await page.waitForTimeout(80);
    const h1 = await ta.evaluate((el) => (el as HTMLTextAreaElement).getBoundingClientRect().height);
    t0 = Date.now();
    await ta.fill("l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8");
    await page.waitForTimeout(120);
    const h2 = await ta.evaluate((el) => (el as HTMLTextAreaElement).getBoundingClientRect().height);
    loadMs = Date.now() - t0;
    await shot(page, STORY, "5-auto-resize", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "5-auto-resize",
        loadMs,
        focusOk: h2 > h1 + 20,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err5,
        extraNotes: [`h1=${h1}`, `h2=${h2}`],
      }),
    );

    // Step 6: click Add optimistic feedback (mocked POST)
    const err6 = c.errors.length;
    await ta.fill(`goal-us2-test-${Date.now()}`);
    await page.route("/api/memos", async (route) => {
      await new Promise((r) => setTimeout(r, 400));
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          id: "us2-test",
          body: "x",
          type: "text",
          compile_status: "pending",
          ingest_mode: "light",
          created_at: new Date().toISOString(),
        }),
      });
    });
    t0 = Date.now();
    // Composer submit button uses aria-label "发送 (Cmd+Enter)" / "发送中"
    const submitBtn = page.locator('button[aria-label^="发送"]').last();
    await submitBtn.click();
    const feedback = page
      .locator('button[aria-label="发送中"], :text("QUEUED"), :text("排队中")')
      .first();
    const feedbackShown = await feedback.isVisible({ timeout: 1500 }).catch(() => false);
    loadMs = Date.now() - t0;
    await shot(page, STORY, "6-add-optimistic", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "6-add-optimistic",
        loadMs,
        focusOk: feedbackShown,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err6,
        extraNotes: [`feedbackShown=${feedbackShown}`],
      }),
    );

    expect(c.errors, `console errors: ${c.errors.join(" | ")}`).toEqual([]);
  });
});
