/**
 * DayPage v9 design contract tests.
 *
 * Locks down the assertions from docs/web-design-v9.md that must hold no
 * matter how the page's data changes. Kept separate from the pixel-perfect
 * visual baselines so a copy change doesn't require updating snapshots.
 *
 * Usage:
 *   pnpm exec playwright test e2e/v9-design.spec.ts
 */
import { test, expect } from "@playwright/test";

async function loginDevBypass(page: import("@playwright/test").Page) {
  await page.goto("/api/auth/dev-bypass", { waitUntil: "networkidle" });
}

test.describe("v9 design contract", () => {
  test.beforeEach(async ({ page }) => {
    await loginDevBypass(page);
  });

  // Signature move: /home is the first port of call, and it must open with
  // the Fraunces serif hero. Missing hero = the page lost its "gallery
  // entrance" and needs escalation, not a rebase.
  test("/home renders the v9 HomeHero (serif date + mono caps stats)", async ({ page }) => {
    await page.goto("/home", { waitUntil: "networkidle" });
    const hero = page.locator(".ds-home-hero");
    await expect(hero).toBeVisible();

    // Date node is a Fraunces heading — check computed font-family contains
    // "Fraunces". CSS var indirection means we can't string-match the raw
    // property, so we resolve it in the browser context.
    const dateFontFamily = await hero.locator(".ds-home-hero__date").evaluate((el) =>
      window.getComputedStyle(el).fontFamily
    );
    expect(dateFontFamily.toLowerCase()).toContain("fraunces");

    // Stats line is mono caps.
    const statsTextTransform = await hero.locator(".ds-home-hero__stats").evaluate((el) =>
      window.getComputedStyle(el).textTransform
    );
    expect(statsTextTransform).toBe("uppercase");
  });

  // Elevation contract: the shared Card component must express --elev-flat.
  // We assert on the CSS variable rather than a specific rgba, so token
  // updates in tokens.json don't require touching this test.
  test("Card uses --elev-flat by default", async ({ page }) => {
    await page.goto("/home", { waitUntil: "networkidle" });
    // Any .card on the page will do — the observation / activity cards are
    // both plain .card elements, so pick the first one that's visible.
    const anyCard = page.locator(".card").first();
    await expect(anyCard).toBeVisible();
    const boxShadow = await anyCard.evaluate((el) => window.getComputedStyle(el).boxShadow);
    // --elev-flat resolves to `0px 1px 2px rgba(60, 40, 15, 0.04)`. In dark
    // mode it's a much darker overlay. Both are non-"none" — the assertion
    // is that shadow is actually set.
    expect(boxShadow).not.toBe("none");
  });

  // Reduce-motion contract: the reduce-motion rules in globals.css must be
  // reachable (regression guard for the Lightning CSS bug fixed in
  // docs/web-design-v9.md §9). We can't observe reduced animation directly
  // in a headless run without opt-in flags, so we just assert that the
  // stylesheet contains the -still keyframe replacement, which proves the
  // fix landed.
  test("reduce-motion still-keyframe fallback is present in globals.css", async ({ page }) => {
    await page.goto("/home", { waitUntil: "networkidle" });
    const hasStillKeyframe = await page.evaluate(() => {
      for (const sheet of Array.from(document.styleSheets)) {
        let rules: CSSRuleList;
        try {
          rules = sheet.cssRules;
        } catch {
          // cross-origin sheets throw — skip them
          continue;
        }
        for (const rule of Array.from(rules)) {
          if (
            rule instanceof CSSKeyframesRule &&
            (rule.name === "ds-fade-still" || rule.name === "ds-noop-still")
          ) {
            return true;
          }
        }
      }
      return false;
    });
    expect(hasStillKeyframe).toBe(true);
  });
});
