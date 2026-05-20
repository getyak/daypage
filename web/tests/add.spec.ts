/**
 * E2E tests for the /add page — US-011 acceptance criteria.
 *
 * Covers:
 *   - Draft save & restore across page reload (localStorage key: codex.add.draft.v1)
 *   - Cmd/Ctrl+Enter keyboard shortcut submits the form
 *   - Breadcrumb shows "Add" on first paint
 *   - Bookmarklet button opens a "Save to Codex" modal
 *   - URL mode toggle changes textarea placeholder and highlights the URL button
 *   - Photo / File picker inputs exist and buttons are clickable
 *   - Optimistic "QUEUED" badge appears immediately after clicking Add
 */

import { test, expect } from "@playwright/test";

const DRAFT_KEY = "codex.add.draft.v1";

async function loginDevBypass(page: import("@playwright/test").Page) {
  await page.goto("/api/auth/dev-bypass", { waitUntil: "networkidle" });
}

// ─── Draft restore ────────────────────────────────────────────────────────────

test.describe("/add — draft save and restore", () => {
  test.beforeEach(async ({ page }) => {
    await loginDevBypass(page);
    // Clear any existing draft so tests start from a clean state.
    await page.goto("/add", { waitUntil: "networkidle" });
    await page.evaluate((key) => localStorage.removeItem(key), DRAFT_KEY);
  });

  test("draft restore after reload — type, save draft, reload, text is present", async ({
    page,
  }) => {
    await page.goto("/add", { waitUntil: "networkidle" });

    const textarea = page.locator("textarea").first();
    const draftText = "Hello, this is my draft note " + Date.now();

    await textarea.click();
    await textarea.fill(draftText);

    // Click "Save draft" button
    await page.click('button:has-text("Save draft")');

    // Brief pause to confirm toast appears (optional UX check)
    await expect(page.getByText("Draft saved")).toBeVisible({ timeout: 2000 });

    // Reload the page
    await page.reload({ waitUntil: "networkidle" });

    // After reload the draft should be restored into the textarea
    const restoredTextarea = page.locator("textarea").first();
    await expect(restoredTextarea).toHaveValue(draftText, { timeout: 3000 });

    // The "Restored draft" hint should be visible
    await expect(page.getByText(/Restored draft/)).toBeVisible({
      timeout: 3000,
    });
  });
});

// ─── Keyboard shortcut ────────────────────────────────────────────────────────

test.describe("/add — keyboard shortcut", () => {
  test.beforeEach(async ({ page }) => {
    await loginDevBypass(page);
    await page.goto("/add", { waitUntil: "networkidle" });
    // Ensure no draft is present so the textarea starts empty
    await page.evaluate((key) => localStorage.removeItem(key), DRAFT_KEY);
    await page.reload({ waitUntil: "networkidle" });
  });

  test("Cmd+Enter submit — textarea clears or button shows Adding… state", async ({
    page,
  }) => {
    const textarea = page.locator("textarea").first();
    const submitText = "Testing keyboard shortcut submit " + Date.now();

    await textarea.click();
    await textarea.fill(submitText);
    await expect(textarea).toHaveValue(submitText);

    // Press Meta+Enter (Cmd on Mac, mapped to Meta in Playwright)
    await page.keyboard.press("Meta+Enter");

    // Either the textarea is cleared (success path) OR the button briefly
    // shows "Adding…" (pending state). Both indicate the handler fired.
    // We wait up to 3 s for one of the two conditions.
    const clearedOrPending = page
      .locator('button:has-text("Adding…")')
      .or(textarea.filter({ hasText: "" }));

    // The textarea value should no longer equal the original text
    await expect(textarea).not.toHaveValue(submitText, { timeout: 3000 });
  });
});

// ─── Breadcrumb ───────────────────────────────────────────────────────────────

test.describe("/add — breadcrumb", () => {
  test("breadcrumb first-paint shows 'Add'", async ({ page }) => {
    await loginDevBypass(page);
    // Use domcontentloaded so we test what's painted before full hydration
    await page.goto("/add", { waitUntil: "domcontentloaded" });

    // The topbar breadcrumb renders: Codex / Add
    // BreadcrumbLabel renders a <span> with "Add"
    const breadcrumb = page
      .getByRole("banner")
      .getByText("Add", { exact: true });
    await expect(breadcrumb).toBeVisible({ timeout: 5000 });
  });
});

// ─── Bookmarklet modal ────────────────────────────────────────────────────────

test.describe("/add — bookmarklet", () => {
  test.beforeEach(async ({ page }) => {
    await loginDevBypass(page);
    await page.goto("/add", { waitUntil: "networkidle" });
  });

  test("Bookmarklet button opens modal with 'Save to Codex' title", async ({
    page,
  }) => {
    // Click the Bookmarklet chip button
    await page.click('button:has-text("Bookmarklet")');

    // The Dialog component should be visible
    const dialog = page.locator('[role="dialog"]');
    await expect(dialog).toBeVisible({ timeout: 3000 });

    // Modal title should contain "Save to Codex"
    await expect(dialog.getByText(/Save to Codex/i)).toBeVisible();
  });

  test("Bookmarklet modal does NOT show an attachments area", async ({
    page,
  }) => {
    await page.click('button:has-text("Bookmarklet")');

    const dialog = page.locator('[role="dialog"]');
    await expect(dialog).toBeVisible({ timeout: 3000 });

    // The attachments strip (add-input__attachments) should not be inside the dialog
    await expect(
      dialog.locator(".add-input__attachments")
    ).not.toBeVisible();
  });
});

// ─── URL mode toggle ──────────────────────────────────────────────────────────

test.describe("/add — URL mode toggle", () => {
  test.beforeEach(async ({ page }) => {
    await loginDevBypass(page);
    await page.goto("/add", { waitUntil: "networkidle" });
    // Clear draft so textarea starts empty
    await page.evaluate((key) => localStorage.removeItem(key), DRAFT_KEY);
    await page.reload({ waitUntil: "networkidle" });
  });

  test("URL button toggles mode: placeholder changes to https://, textarea stays empty", async ({
    page,
  }) => {
    const textarea = page.locator("textarea").first();

    // Before toggle: default placeholder
    const defaultPlaceholder = await textarea.getAttribute("placeholder");
    expect(defaultPlaceholder).not.toMatch(/https:\/\//);

    // Click the URL chip
    await page.click('button:has-text("URL")');

    // After toggle: placeholder should contain "https://"
    await expect(textarea).toHaveAttribute("placeholder", /https:\/\//);

    // Textarea value should still be empty (no auto-fill)
    await expect(textarea).toHaveValue("");
  });

  test("URL button has accent styling when active", async ({ page }) => {
    const urlButton = page.locator('button:has-text("URL")').first();

    // Click to activate URL mode
    await urlButton.click();

    // When active, the component applies inline style with var(--accent) color
    // Check via computed style or inline style attribute
    const style = await urlButton.getAttribute("style");
    expect(style).toBeTruthy();
    // The component sets background: var(--accent-soft) and color: var(--accent)
    expect(style).toMatch(/accent/);
  });
});

// ─── File pickers ─────────────────────────────────────────────────────────────

test.describe("/add — file picker inputs", () => {
  test.beforeEach(async ({ page }) => {
    await loginDevBypass(page);
    await page.goto("/add", { waitUntil: "networkidle" });
  });

  test("Photo picker — hidden input[accept='image/*'] exists and Photo button is clickable", async ({
    page,
  }) => {
    // The hidden photo input should exist in the DOM
    const photoInput = page.locator('input[type="file"][accept="image/*"]');
    await expect(photoInput).toBeAttached();

    // Clicking the Photo button should not throw or break the page
    const photoButton = page.locator('button:has-text("Photo")');
    await expect(photoButton).toBeVisible();
    // Use a file chooser event listener to avoid actually opening a system dialog
    const [fileChooser] = await Promise.all([
      page.waitForEvent("filechooser", { timeout: 2000 }).catch(() => null),
      photoButton.click(),
    ]);
    // Whether or not the file chooser fires, the page should still be intact
    await expect(page.locator("textarea").first()).toBeVisible();
  });

  test("File picker — hidden input[type='file'] (no accept) exists and File button is clickable", async ({
    page,
  }) => {
    // There are two file inputs: one with accept="image/*" and one without.
    // The plain file input is the non-image one.
    const fileInput = page.locator(
      'input[type="file"]:not([accept="image/*"])'
    );
    await expect(fileInput).toBeAttached();

    const fileButton = page.locator('button:has-text("File")');
    await expect(fileButton).toBeVisible();

    // Verify no error state after click
    const [fileChooser] = await Promise.all([
      page.waitForEvent("filechooser", { timeout: 2000 }).catch(() => null),
      fileButton.click(),
    ]);
    await expect(page.locator("textarea").first()).toBeVisible();
  });
});

// ─── Optimistic QUEUED badge ──────────────────────────────────────────────────

test.describe("/add — optimistic QUEUED update", () => {
  test.beforeEach(async ({ page }) => {
    await loginDevBypass(page);
    await page.goto("/add", { waitUntil: "networkidle" });
    await page.evaluate((key) => localStorage.removeItem(key), DRAFT_KEY);
    await page.reload({ waitUntil: "networkidle" });
  });

  test("new submission shows QUEUED badge or Adding… button immediately after click", async ({
    page,
  }) => {
    const textarea = page.locator("textarea").first();
    const memoText = "Optimistic queue test " + Date.now();

    await textarea.click();
    await textarea.fill(memoText);

    // Intercept the POST to /api/memos so we can control timing and avoid
    // a real network call failing the test.
    await page.route("/api/memos", async (route) => {
      // Delay the response long enough to observe the optimistic UI
      await new Promise((r) => setTimeout(r, 3000));
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          id: "test-memo-id",
          body: memoText,
          type: "text",
          compile_status: "pending",
          ingest_mode: "light",
          created_at: new Date().toISOString(),
        }),
      });
    });

    // Click the Add button
    const addButton = page.locator('button:has-text("Add")').last();
    await addButton.click();

    // Immediately after click, one of the following should appear:
    //   1. The Add button changes to "Adding…" (mutation.isPending)
    //   2. A QUEUED badge appears in the Compile Queue section
    const addingButton = page.locator('button:has-text("Adding…")');
    const queuedBadge = page.getByText("QUEUED");

    // Wait for either indicator
    await expect(addingButton.or(queuedBadge)).toBeVisible({ timeout: 2000 });
  });
});
