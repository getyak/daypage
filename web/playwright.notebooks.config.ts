import { defineConfig } from "@playwright/test";
import path from "node:path";

const artifact = process.env.GET443_NOTEBOOKS_ARTIFACT_DIR;
const origin = "http://127.0.0.1:13143";
if (process.env.GET443_NOTEBOOKS_RUN !== "1" || !artifact || !path.isAbsolute(artifact)) {
  throw new Error("Explicit GET443_NOTEBOOKS_RUN=1 and an absolute task-owned GET443_NOTEBOOKS_ARTIFACT_DIR are required");
}
if (process.env.NEXT_PUBLIC_SUPABASE_URL !== origin + "/__get443_supabase" ||
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY !== "synthetic-get443-public-key-not-a-credential" ||
    process.env.DAYPAGE_PRIVATE_PREVIEW !== "1" || process.env.NEXT_TELEMETRY_DISABLED !== "1") {
  throw new Error("Build and run a dedicated actual Next bundle with the documented synthetic loopback public configuration");
}

export default defineConfig({
  testDir: "./tests",
  testMatch: "file-exchange-notebooks.spec.ts",
  outputDir: path.join(artifact, "playwright-results"),
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 240_000,
  expect: { timeout: 15_000 },
  reporter: [["list"], ["json", { outputFile: path.join(artifact, "playwright-results.json") }]],
  use: {
    baseURL: origin,
    browserName: "chromium",
    channel: "chrome",
    // No HAR, trace, video, auth storageState or credentials are serialized.
    trace: "off",
    video: "off",
    screenshot: "off",
  },
  projects: [
    { name: "desktop", use: { viewport: { width: 1440, height: 900 } } },
    { name: "narrow", dependencies: ["desktop"], use: { viewport: { width: 375, height: 812 } } },
  ],
  webServer: {
    command: "node scripts/file-exchange-notebooks-fixture.mjs --serve",
    url: origin + "/__get443_control/ready",
    reuseExistingServer: false,
    timeout: 90_000,
    gracefulShutdown: { signal: "SIGTERM", timeout: 15_000 },
  },
});
