import { readFileSync } from "node:fs";
import { defineConfig } from "drizzle-kit";

// drizzle-kit runs outside Next.js so it does NOT auto-load .env.local.
// Parse it ourselves (zero deps) so `npm run db:migrate` / `db:generate`
// work without requiring callers to `source .env.local` first.
function loadEnvLocal() {
  if (process.env.DATABASE_URL) return;
  try {
    const text = readFileSync(new URL("./.env.local", import.meta.url), "utf8");
    for (const line of text.split(/\r?\n/)) {
      const m = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)?\s*$/i);
      if (!m) continue;
      const key = m[1];
      if (process.env[key]) continue;
      let val = m[2] ?? "";
      if (
        (val.startsWith('"') && val.endsWith('"')) ||
        (val.startsWith("'") && val.endsWith("'"))
      ) {
        val = val.slice(1, -1);
      }
      process.env[key] = val;
    }
  } catch {
    // .env.local optional — fall back to existing process.env
  }
}

loadEnvLocal();

export default defineConfig({
  schema: "./src/lib/db/schema.ts",
  out: "./drizzle/migrations",
  dialect: "postgresql",
  dbCredentials: {
    url: process.env.DATABASE_URL!,
  },
});
