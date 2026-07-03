// Slim Playwright config for the /e2e directory (design contract tests).
// The default playwright.config.ts is scoped to /tests and stays that way;
// this file lets us run the e2e contract suite (v9-design.spec.ts,
// add-v9.spec.ts, visual-baseline.spec.ts) without cross-configuring the
// main test harness.
import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: false,
  retries: 0,
  workers: 1,
  reporter: [["line"]],
  use: {
    baseURL: process.env.BASE_URL ?? "http://localhost:3000",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [
    {
      name: "desktop-chrome",
      use: { ...devices["Desktop Chrome"], viewport: { width: 1440, height: 900 } },
    },
  ],
});
