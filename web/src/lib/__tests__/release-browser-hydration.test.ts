import { afterEach, describe, expect, it, vi } from "vitest";
import { createElement } from "react";
import { renderToString } from "react-dom/server";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { draftText } from "@/hooks/useCaptureDraft";
import { speechSupported } from "@/hooks/useBrowserCapabilities";
import { Composer } from "@/app/(app)/add/Composer";
import { CaptureHero } from "@/app/(app)/add/CaptureHero";
import { HomeHero } from "@/app/(app)/home/HomeHero";
import { AISummaryCard } from "@/app/(app)/today/AISummaryCard";
import { ShaderBackground } from "@/app/(marketing)/_components/ShaderBackground";
import { SplitText } from "@/app/(marketing)/_components/SplitText";
import { ProblemSection } from "@/app/(marketing)/_components/ProblemSection";
import { InViewReveal } from "@/app/(marketing)/_components/InViewReveal";
import { ScrollScene } from "@/app/(marketing)/_components/ScrollScene";
import { animationControls } from "framer-motion";
import { runSessionEntrance } from "@/hooks/useSessionEntrance";

afterEach(() => vi.unstubAllGlobals());

describe("capture draft compatibility", () => {
  it("restores the existing text format, including an explicitly empty draft", () => {
    expect(draftText(JSON.stringify({ text: "隔离测试草稿", mode: "text", attachmentRef: null }))).toBe("隔离测试草稿");
    expect(draftText('{"text":""}')).toBe("");
  });
  it("accepts unavailable or corrupt storage without crashing capture", () => {
    for (const value of [undefined, null, "", "{", "null", "42", '{"text":false}', '{"text":{}}']) {
      expect(draftText(value)).toBe("");
    }
  });
});

describe("Framer controller lifetime", () => {
  it("allows layout teardown before passive cleanup and StrictMode replay", async () => {
    const controls = animationControls();
    const storage = new Map<string, string>();
    const getStorage = () => ({ getItem: (key: string) => storage.get(key) ?? null, setItem: (key: string, value: string) => { storage.set(key, value); } });
    const state = { claimed: false, finished: false };
    const unmountFirst = controls.mount();
    const cleanupFirst = runSessionEntrance(controls, state, "hero", false, getStorage);
    unmountFirst();
    expect(() => cleanupFirst?.()).not.toThrow();
    const unmountReplay = controls.mount();
    const cleanupReplay = runSessionEntrance(controls, state, "hero", false, getStorage);
    await Promise.resolve();
    expect(state.finished).toBe(true);
    expect(storage.get("hero")).toBe("1");
    unmountReplay();
    expect(() => cleanupReplay?.()).not.toThrow();
  });
  it("stops a cancelled entrance without completing it, and settles when motion is reduced", async () => {
    const controls = animationControls();
    const unmount = controls.mount();
    const storage = { getItem: vi.fn(() => null), setItem: vi.fn() };
    const state = { claimed: false, finished: false };
    const cleanup = runSessionEntrance(controls, state, "hero", false, () => storage);
    cleanup?.();
    await Promise.resolve();
    expect(state.finished).toBe(false);
    runSessionEntrance(controls, state, "hero", true, () => storage);
    expect(state.finished).toBe(true);
    expect(storage.setItem).toHaveBeenCalledTimes(1);
    unmount();
  });
});

describe("browser capability boundaries", () => {
  it("keeps the initial problem heading as readable static text", () => {
    const html = renderToString(createElement(ProblemSection));
    expect(html).toContain(">You forget. The day forgets you back.</h2>");
  });
  it("keeps revealed content visible during server rendering", () => {
    const html = renderToString(createElement(InViewReveal, null, "Visible server content"));
    expect(html).toContain("Visible server content");
    expect(html).not.toMatch(/opacity:0|will-change|translateY/);
  });
  it("uses the static scroll-scene layout before browser preferences are known", () => {
    const html = renderToString(createElement(ScrollScene, {
      id: "release-scene", acts: 1,
      copy: () => createElement("p", null, "Readable copy"),
      stage: () => createElement("p", null, "Static stage"),
    }));
    expect(html).toContain('id="release-scene"');
    expect(html).toContain("Readable copy");
    expect(html).toContain("Static stage");
    expect(html).not.toMatch(/sticky|100svh/);
  });
  it.each(["Your day, captured raw.", "今天 👨‍👩‍👦 的一天"])("keeps the initial split title static before browser preferences are known: %s", (text) => {
    const matchMedia = vi.fn(() => ({ matches: false }));
    vi.stubGlobal("window", { matchMedia });
    const html = renderToString(createElement(SplitText, { text, split: "char", as: "h1", className: "release-title" }));
    expect(html).toBe(`<h1 class="release-title">${text}</h1>`);
    expect(matchMedia).not.toHaveBeenCalled();
  });
  it("detects standard and vendor speech support without starting recognition", () => {
    const constructor = vi.fn();
    vi.stubGlobal("window", {});
    expect(speechSupported()).toBe(false);
    vi.stubGlobal("window", { SpeechRecognition: constructor });
    expect(speechSupported()).toBe(true);
    vi.stubGlobal("window", { webkitSpeechRecognition: constructor });
    expect(speechSupported()).toBe(true);
    expect(constructor).not.toHaveBeenCalled();
  });
  it("keeps SSR capture blank and speech disabled even when browser storage exists", () => {
    const read = vi.fn(() => '{"text":"synthetic-private-draft"}');
    vi.stubGlobal("localStorage", { getItem: read });
    vi.stubGlobal("window", { SpeechRecognition: vi.fn() });
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    const html = renderToString(createElement(QueryClientProvider, { client }, createElement(Composer)));
    expect(html).not.toContain("synthetic-private-draft");
    expect(read).not.toHaveBeenCalled();
    expect(html).toContain("textarea");
    client.clear();
  });
  it("renders visible static hero content without reading or claiming session storage", () => {
    const storage = { getItem: vi.fn(), setItem: vi.fn() };
    vi.stubGlobal("sessionStorage", storage);
    const home = renderToString(createElement(HomeHero, { date: "2026 · Oct 06", weekday: "TUE", sourceCount: 2, pageCount: 3, thisWeekCount: 4 }));
    const capture = renderToString(createElement(CaptureHero, { queueCount: 2, doneCount: 3 }));
    expect(home).toContain("2026 · Oct 06");
    expect(capture).toContain("IN QUEUE");
    expect(home + capture).not.toMatch(/opacity:0|translateY\(12px\)/);
    expect(storage.getItem).not.toHaveBeenCalled();
    expect(storage.setItem).not.toHaveBeenCalled();
  });
  it("renders a static GPU fallback and summary loading state without animation during SSR", () => {
    const shader = renderToString(createElement(ShaderBackground));
    expect(shader).toContain("radial-gradient");
    expect(shader).not.toContain("<canvas");
    const summary = renderToString(createElement(AISummaryCard));
    expect(summary).toContain('aria-busy="true"');
    expect(summary).not.toContain("ai-caret-blink");
  });
});
