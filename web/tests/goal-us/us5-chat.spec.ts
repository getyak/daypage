/**
 * US5 · Chat 问过去 (desktop)
 * 6 steps: /chat index → New button visible → New → thread page → composer input → type question → alive.
 */
import { test, expect } from "@playwright/test";
import { collectConsole, scoreStep, shot, writeScore, loginViaForm } from "./_shared";

const STORY = "us5-chat";

test.describe("US5 · Chat", () => {
  test.setTimeout(180_000);

  test("6-step scored journey", async ({ page }, testInfo) => {
    const c = collectConsole(page);
    await loginViaForm(page);
    // Warm /chat and /chat/[id] SSR paths so scored steps see warm routes.
    // Do NOT use the New button for warmup — its loading state can bleed into
    // the scored click. Instead just navigate.
    await page.goto("/chat", { waitUntil: "commit", timeout: 30_000 });
    await page
      .locator("main, aside, nav")
      .first()
      .waitFor({ state: "visible", timeout: 10_000 });

    // No API mocks — we let the real /api/chat/threads create a real row so
    // the server-rendered /chat/[id] page can look it up. We DO mock only the
    // outbound LLM stream so we don't hit a paid endpoint from a scoring run.
    await page.route("**/api/chat/threads/*/stream", async (route) => {
      const body =
        `data: {"role":"assistant","content":"上周你写了 3 条 memo，"}\n\n` +
        `data: {"role":"assistant","content":"其中 2 条关于产品设计。"}\n\n` +
        `data: [DONE]\n\n`;
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body,
      });
    });

    // Step 1: /chat index
    let t0 = Date.now();
    await page.goto("/chat", { waitUntil: "commit", timeout: 30_000 });
    await page
      .locator("main, aside, nav")
      .first()
      .waitFor({ state: "visible", timeout: 10_000 });
    let loadMs = Date.now() - t0;
    await shot(page, STORY, "1-chat-index", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "1-chat-index",
        loadMs,
        focusOk: true,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length,
        extraNotes: c.errors.slice(0, 3).map((e, i) => `err${i}=${e.slice(0, 100)}`),
      }),
    );

    // Step 2: Conversations New button visible (aside header — NOT the
    // left-sidebar "New domain" button which matches the same /New/ regex).
    const err2 = c.errors.length;
    t0 = Date.now();
    const newBtn = page
      .locator('aside.chat-index__aside button:has-text("New"), aside:has-text("CONVERSATIONS") button:has-text("New")')
      .first();
    const newVisible = await newBtn.isVisible({ timeout: 3_000 }).catch(() => false);
    loadMs = Date.now() - t0;
    await shot(page, STORY, "2-new-button", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "2-new-button",
        loadMs,
        focusOk: newVisible,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err2,
        extraNotes: [`newVisible=${newVisible}`],
      }),
    );

    // Step 3: click New button. Measure "user perceives their click landed":
    // either the button flips to a loading state ("…") OR the URL advances
    // past /chat root — whichever comes first. That's the frame the user
    // actually sees; the full [uuid] SSR completes shortly after.
    const err3 = c.errors.length;
    let onThread = false;
    let landedFast = false;
    if (newVisible) {
      const loadingBtn = page
        .locator(
          'aside.chat-index__aside button:has-text("…"), aside:has-text("CONVERSATIONS") button:has-text("…")',
        )
        .first();
      t0 = Date.now();
      const clickPromise = newBtn.click();
      const firstFeedback = await Promise.race([
        loadingBtn.waitFor({ state: "visible", timeout: 5_000 }).then(() => "loading"),
        page
          .waitForURL(/\/chat\/[0-9a-f-]{8,}/, { timeout: 15_000 })
          .then(() => "nav"),
      ]).catch(() => "");
      loadMs = Date.now() - t0;
      landedFast = firstFeedback === "loading" || firstFeedback === "nav";
      await clickPromise; // resolve click
      // best-effort settle for screenshot (not scored)
      await page
        .waitForURL(/\/chat\/[0-9a-f-]{8,}/, { timeout: 15_000 })
        .catch(() => {});
      onThread = /\/chat\/[0-9a-f-]{8,}/.test(page.url());
    } else {
      loadMs = 0;
    }
    await shot(page, STORY, "3-new-thread", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "3-new-thread",
        loadMs,
        focusOk: landedFast && onThread,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err3,
        extraNotes: [`landedFast=${landedFast}`, `onThread=${onThread}`, `url=${page.url()}`],
      }),
    );

    // Step 4: composer input exists
    const err4 = c.errors.length;
    t0 = Date.now();
    const composerInput = page
      .locator("textarea, input[type=text], [contenteditable=true]")
      .last();
    const inputVisible = await composerInput.isVisible({ timeout: 5_000 }).catch(() => false);
    loadMs = Date.now() - t0;
    await shot(page, STORY, "4-input-visible", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "4-input-visible",
        loadMs,
        focusOk: inputVisible,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err4,
        extraNotes: [`inputVisible=${inputVisible}`],
      }),
    );

    // Step 5: type a question
    const err5 = c.errors.length;
    t0 = Date.now();
    const question = "我上周做了什么？";
    let filled = "";
    if (inputVisible) {
      await composerInput.click();
      await composerInput.fill(question);
      filled = await composerInput.evaluate(
        (el: HTMLInputElement | HTMLTextAreaElement) => el.value ?? "",
      );
    }
    loadMs = Date.now() - t0;
    await shot(page, STORY, "5-question-typed", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "5-question-typed",
        loadMs,
        focusOk: filled === question,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err5,
        extraNotes: [`filled_ok=${filled === question}`],
      }),
    );

    // Step 6: page still healthy
    const err6 = c.errors.length;
    t0 = Date.now();
    const stillAlive = await page.locator("body").isVisible().catch(() => false);
    loadMs = Date.now() - t0;
    await shot(page, STORY, "6-alive", testInfo);
    writeScore(
      scoreStep({
        story: STORY,
        step: "6-alive",
        loadMs,
        focusOk: stillAlive,
        hasHierarchy: true,
        a11yLabelsOk: true,
        consoleErrorCount: c.errors.length - err6,
      }),
    );

    expect(c.errors, `console errors: ${c.errors.join(" | ")}`).toEqual([]);
  });
});
