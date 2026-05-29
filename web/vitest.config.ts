import { defineConfig } from "vitest/config";
import path from "path";

export default defineConfig({
  test: {
    environment: "node",
    globals: false,
  },
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
      // `server-only` is a Next.js build-time guard with no runtime export;
      // stub it so server modules can be unit-tested under vitest.
      "server-only": path.resolve(__dirname, "./tests/server-only-stub.ts"),
    },
  },
});
