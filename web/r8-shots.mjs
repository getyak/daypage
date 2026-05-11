import { chromium } from "playwright";
import fs from "node:fs";
const OUT = "/tmp/daypage-r8"; fs.mkdirSync(OUT, { recursive: true });
const browser = await chromium.launch({ headless: true });
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

await page.goto("http://localhost:3000/login", { waitUntil: "domcontentloaded" });
await page.locator('button:has-text("Dev login")').click();
await page.waitForURL(/\/home/, { timeout: 30000 });
await page.waitForTimeout(2000);

await page.screenshot({ path: `${OUT}/home-full.png`, fullPage: true });
await page.screenshot({ path: `${OUT}/home-hero.png`, clip: { x: 248, y: 0, width: 1192, height: 600 } });
await page.screenshot({ path: `${OUT}/home-mid.png`, clip: { x: 248, y: 350, width: 1192, height: 600 } });

await page.goto("http://localhost:3000/wiki", { waitUntil: "domcontentloaded" });
await page.waitForTimeout(2000);
await page.screenshot({ path: `${OUT}/wiki-list.png`, fullPage: true });

await page.goto("http://localhost:3000/inbox", { waitUntil: "domcontentloaded" });
await page.waitForTimeout(2000);
await page.screenshot({ path: `${OUT}/inbox-full.png`, fullPage: true });

await page.goto("http://localhost:3000/chat", { waitUntil: "domcontentloaded" });
await page.waitForTimeout(2000);
await page.screenshot({ path: `${OUT}/chat-empty.png`, fullPage: true });

await browser.close();
console.log("done");
