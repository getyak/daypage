import { defineConfig } from "@playwright/test";

const outputDir = process.env.DAYPAGE_MARKETING_OUTPUT_DIR;
if (!outputDir) {
  throw new Error("Set DAYPAGE_MARKETING_OUTPUT_DIR to a task-owned test artifact directory");
}

export default defineConfig({
  testDir: "./tests",
  testMatch: "marketing-hydration.spec.ts",
  outputDir,
  workers: 1,
  retries: 0,
  reporter: "list",
  use: {
    baseURL: "http://127.0.0.1:13000",
    browserName: "chromium",
    channel: "chrome",
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
  },
  projects: [
    { name: "desktop", use: { viewport: { width: 1440, height: 900 } } },
    { name: "mobile", use: { viewport: { width: 375, height: 812 }, isMobile: true } },
  ],
  webServer: {
    command: "node node_modules/next/dist/bin/next start --hostname 127.0.0.1 --port 13000",
    url: "http://127.0.0.1:13000",
    reuseExistingServer: false,
  },
});
