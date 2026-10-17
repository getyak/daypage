import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";

// Only the external browser preference and router context are controlled.
// AnimatePresence and motion.div use the actual installed Motion renderer.
const preference = vi.hoisted(() => ({ reduced: null as boolean | null }));
vi.mock("next/navigation", () => ({ usePathname: () => "/memos" }));
vi.mock("framer-motion", async (importOriginal) => ({
  ...(await importOriginal<typeof import("framer-motion")>()),
  useReducedMotion: () => preference.reduced,
}));

import { PageTransition } from "../PageTransition";

function firstRender(reduced: boolean | null): string {
  preference.reduced = reduced;
  return renderToStaticMarkup(
    createElement(
      PageTransition,
      null,
      createElement("section", { "aria-label": "Reader" }, "Reader content"),
    ),
  );
}

describe("PageTransition hydration boundary", () => {
  it.each([false, true])(
    "keeps the server markup when the browser reduced-motion preference is %s",
    (reduced) => {
      // Motion reports null during SSR. The browser may already know true on
      // its first render; that must not remove an enclosing layout element.
      const server = firstRender(null);
      const browser = firstRender(reduced);
      expect(server).toContain("Reader content");
      expect(browser).toBe(server);
    },
  );
});
