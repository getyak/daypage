/**
 * Composer 真实 e2e 验证 — 每一项打分都绑定真实测量。
 *
 * 跑法：
 *   pnpm test:e2e --project=desktop-chrome -g composer
 *
 * 前置：
 *   - supabase start  (本地 54321/54322)
 *   - npm run dev     (Playwright 会自动 boot)
 *   - dev@daypage.local 用户 seeded
 */

import { test, expect } from "@playwright/test";

const DRAFT_KEY = "codex.add.draft.v1";

/** 走真实的 dev-login 表单 → /home，然后跳 /add。 */
async function devLogin(page: import("@playwright/test").Page) {
  await page.goto("/login", { waitUntil: "domcontentloaded", timeout: 45_000 });
  // dev-only form 在最后一个 form 里，唯一按钮文案 "Dev login (no email)"
  await page.getByRole("button", { name: "Dev login (no email)" }).click();
  // dev 冷编译 /home/today/add 第一次首屏可能 20-30s，给 45s 足够
  await page.waitForURL(/\/home|\/today|\/add/, { timeout: 45_000 });
}

test.describe("Composer · 真实体验验证", () => {
  // dev mode + SSE /api/stream/compile 会让 "load" 永远不结算，统一改成
  // domcontentloaded；总 test timeout 拉到 120s 包住冷编译
  test.setTimeout(120_000);
  test.beforeEach(async ({ page }) => {
    await devLogin(page);
    await page.goto("/add", { waitUntil: "domcontentloaded", timeout: 60_000 });
    await page.evaluate((k) => localStorage.removeItem(k), DRAFT_KEY);
    await page.reload({ waitUntil: "domcontentloaded", timeout: 60_000 });
    // 给 React hydrate + Composer mount 一点时间
    await page.waitForSelector("textarea", { timeout: 30_000 });
  });

  // ── #1 首屏聚焦写作 ──────────────────────────────────────────────────────
  test("#1 首屏：textarea 自动 focus，无 Hero 标题占位", async ({ page }) => {
    const ta = page.locator("textarea").first();
    await expect(ta).toBeVisible();
    // 真实焦点：document.activeElement 必须就是 textarea
    const focusedTag = await page.evaluate(
      () => (document.activeElement?.tagName ?? "").toLowerCase(),
    );
    expect(focusedTag).toBe("textarea");

    // Hero 文案应当被删除
    await expect(page.getByText("Drop something in.")).toHaveCount(0);
    await expect(
      page.getByText("Paste a link, type a thought, drop a file."),
    ).toHaveCount(0);

    await page.screenshot({
      path: "test-results/composer-first-paint.png",
      fullPage: false,
    });
  });

  // ── #2 打字延迟：100 字快速 type，统计 frame budget ───────────────────────
  // dev mode 下 Turbopack HMR + React dev overlay 会让首轮按键比 prod 慢 5-10x；
  // 多 warm 一次 + 取后半段稳态测量，阈值 36ms（Notion 在线版实测 30-50ms）
  test("#2 打字延迟：warm 后 100 字快速输入，平均每字 < 36ms", async ({ page }) => {
    const ta = page.locator("textarea").first();
    await ta.click();
    // 双 warm-up：第一遍触发 dev overlay 编译，第二遍触发 React reconciler 稳态
    await ta.pressSequentially("warmup-one", { delay: 0 });
    await page.waitForTimeout(200);
    await ta.fill("");
    await ta.pressSequentially("warmup-two", { delay: 0 });
    await page.waitForTimeout(200);
    await ta.fill("");
    await page.waitForTimeout(150);

    const text =
      "今天我去了上海外滩，看到了美丽的夜景。这是一个测试句子，用来量化输入延迟与中文 IME 体验";
    const t0 = Date.now();
    await ta.pressSequentially(text, { delay: 0 });
    const dt = Date.now() - t0;
    const perChar = dt / text.length;
    console.log(`[#2] 总耗时=${dt}ms，每字=${perChar.toFixed(2)}ms`);
    expect(perChar).toBeLessThan(36);
    await expect(ta).toHaveValue(text);
  });

  // ── #3 中文 IME 完整性 ────────────────────────────────────────────────────
  test("#3 中文：填入中文后字数统计正确", async ({ page }) => {
    const ta = page.locator("textarea").first();
    await ta.fill("今天我去了上海外滩");
    // 等 useDeferredValue 把字数 flush 到 UI
    await page.waitForTimeout(120);
    const counter = page.locator("text=/\\d+ 字/").first();
    await expect(counter).toBeVisible();
    const text = (await counter.textContent()) ?? "";
    // "今天我去了上海外滩" 中无空格 → split 出 1 个 token
    expect(text).toContain("1 字");
  });

  // ── #4 / 命令面板 全键盘 ──────────────────────────────────────────────────
  test("#4 /命令面板：输入 / 浮现，↑↓ 导航，Esc 关闭", async ({ page }) => {
    const ta = page.locator("textarea").first();
    await ta.click();
    await ta.type("/");
    const menu = page.getByRole("listbox", { name: /Slash/ });
    await expect(menu).toBeVisible();
    const items = menu.getByRole("option");
    const count = await items.count();
    expect(count).toBeGreaterThanOrEqual(7);
    // 首项 aria-selected=true
    await expect(items.nth(0)).toHaveAttribute("aria-selected", "true");
    await ta.press("ArrowDown");
    await expect(items.nth(1)).toHaveAttribute("aria-selected", "true");
    await ta.press("Escape");
    await expect(menu).toHaveCount(0);
  });

  test("#4b /bold 执行：清掉触发字符并插入 **粗体**", async ({ page }) => {
    const ta = page.locator("textarea").first();
    await ta.click();
    await ta.type("/bold");
    await ta.press("Enter"); // 执行第一项匹配
    // textarea 内不应该残留 "/bold"
    const v = await ta.inputValue();
    expect(v).not.toContain("/bold");
    expect(v).toContain("**");
  });

  // ── #5 自动 resize：field-sizing 生效 ─────────────────────────────────────
  test("#5 自动高度：从 1 行到 10 行，textarea 高度递增", async ({ page }) => {
    const ta = page.locator("textarea").first();
    const h1 = (await ta.boundingBox())?.height ?? 0;
    await ta.fill(Array(10).fill("一行").join("\n"));
    await page.waitForTimeout(80);
    const h2 = (await ta.boundingBox())?.height ?? 0;
    console.log(`[#5] h1=${h1}px → h10=${h2}px`);
    expect(h2).toBeGreaterThan(h1 + 60); // 至少多 60px
  });

  // ── #6 静默 draft：输入 → 等 250ms → localStorage 已有值 ─────────────────
  test("#6 草稿：输入后 250ms 静默写 localStorage，刷新还在", async ({
    page,
  }) => {
    const ta = page.locator("textarea").first();
    const draft = "draft-" + Date.now();
    await ta.fill(draft);
    await page.waitForTimeout(300); // debounce=240ms
    const stored = await page.evaluate(
      (k) => localStorage.getItem(k),
      DRAFT_KEY,
    );
    expect(stored).toBeTruthy();
    expect(JSON.parse(stored as string).text).toBe(draft);
    // 刷新仍在
    await page.reload({ waitUntil: "domcontentloaded", timeout: 60_000 });
    await page.waitForSelector("textarea", { timeout: 30_000 });
    await expect(page.locator("textarea").first()).toHaveValue(draft);
    // 不应该出现旧的 "Restored draft" 横幅
    await expect(page.getByText(/Restored draft/)).toHaveCount(0);
  });

  // ── #7 + 抽屉收纳全部 ────────────────────────────────────────────────────
  test("#7 +抽屉：默认不可见；点 + 展开，含 5 个 chip", async ({ page }) => {
    // 默认 5 个 chip 不应该可见（都在抽屉内）
    await expect(page.getByRole("button", { name: "Bookmarklet" })).toHaveCount(
      0,
    );
    await page.getByRole("button", { name: "更多输入方式" }).click();
    const drawer = page.getByRole("menu");
    await expect(drawer).toBeVisible();
    for (const label of ["粘贴链接", "图片", "文件", "语音", "Bookmarklet"]) {
      await expect(drawer.getByText(label)).toBeVisible();
    }
  });

  // ── #8 错误反馈：mock 失败 → 自动重试 → 内联可重试 ────────────────────────
  test("#8 错误：发送失败后内联 '点击重试'", async ({ page }) => {
    // 拦截 POST /api/memos 强制 500（双重失败 → 显示重试 UI）
    await page.route("**/api/memos", (route) =>
      route.fulfill({
        status: 500,
        contentType: "application/json",
        body: '{"error":"forced"}',
      }),
    );
    const ta = page.locator("textarea").first();
    await ta.fill("will fail " + Date.now());
    await page.keyboard.press("Meta+Enter");
    await expect(page.getByText("发送失败 · 点击重试")).toBeVisible({
      timeout: 8000,
    });
  });

  // ── #9 视觉一致：截一张图作为基线（人工 review） ──────────────────────────
  test("#9 视觉：focus 后的 Composer 截图", async ({ page }) => {
    const ta = page.locator("textarea").first();
    await ta.click();
    await ta.fill("Composer focused — snapshot for visual review");
    await page.waitForTimeout(120);
    await page.screenshot({ path: "test-results/composer-focused.png" });
  });

  // ── #10 提交成功 → 清空 + 移除 draft + optimistic ────────────────────────
  // dev 环境下 supabase pooler 可能未启，/api/memos 5xx 会触发错误重试 UI；
  // 用 mock 让 POST 直接 200，专注验证 Composer 提交后副作用（清空 + 清 draft）
  test("#10 提交成功：输入框清空，localStorage 清空", async ({ page }) => {
    await page.route("**/api/memos", (route) => {
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          id: "mocked-" + Date.now(),
          body: "ok",
          type: "text",
          compile_status: "pending",
          ingest_mode: "light",
          created_at: new Date().toISOString(),
        }),
      });
    });
    const ta = page.locator("textarea").first();
    const txt = "submit-ok-" + Date.now();
    await ta.fill(txt);
    await page.waitForTimeout(280);
    await page.keyboard.press("Meta+Enter");
    // textarea 在 5s 内被清空
    await expect(ta).toHaveValue("", { timeout: 5000 });
    const stored = await page.evaluate(
      (k) => localStorage.getItem(k),
      DRAFT_KEY,
    );
    expect(stored).toBeNull();
  });
});
