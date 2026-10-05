import { test, expect } from "@playwright/test";

for (const reducedMotion of ["reduce", "no-preference"] as const) {
  test(`public landing pages hydrate with motion preference ${reducedMotion}`, async ({ page }, testInfo) => {
    await page.emulateMedia({ reducedMotion });
    const errors: string[] = [];
    page.on("pageerror", error => errors.push(error.message));
    page.on("console", message => {
      if (message.type() === "error") errors.push(message.text());
    });

    for (const route of ["/", "/zh"]) {
      await page.goto(route);
      await expect(page.locator("main h1")).toBeVisible();
      await expect(page.getByRole("link", { name: "DayPage home" })).toBeVisible();
      if (route === "/") {
        await expect(page.locator("#capture h3")).toHaveCount(3);
        if (reducedMotion === "reduce") {
          const panels = await page.locator("#capture h3").evaluateAll(headings => headings.map(heading => {
            const style = getComputedStyle(heading.parentElement!);
            return { opacity: style.opacity, position: style.position };
          }));
          expect(panels).toEqual(Array.from({ length: 3 }, () => ({ opacity: "1", position: "static" })));
          await expect(page.locator("canvas")).toHaveCount(0);
        }
      }
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      // Navigation has completed and visible client content is present.
      expect(errors).toEqual([]);
      await page.screenshot({ path: testInfo.outputPath(route === "/" ? "landing-en.png" : "landing-zh.png"), fullPage: true });
    }
  });
}
