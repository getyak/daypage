"use client";

import { useSyncExternalStore } from "react";

const subscribeStatic = () => () => {};
const browserReady = () => true;
const serverNotReady = () => false;
const serverReduced = () => true;
const reducedMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

function subscribeReducedMotion(onChange: () => void) {
  const query = window.matchMedia("(prefers-reduced-motion: reduce)");
  query.addEventListener("change", onChange);
  return () => query.removeEventListener("change", onChange);
}

/** Static browser capabilities with an identical SSR and hydration fallback. */
export function useBrowserSnapshot<Value>(read: () => Value, server: () => Value): Value {
  return useSyncExternalStore(subscribeStatic, read, server);
}

export function useBrowserReady(): boolean {
  return useBrowserSnapshot(browserReady, serverNotReady);
}

/** Prefer still content during SSR, then follow the live browser preference. */
export function usePrefersReducedMotion(): boolean {
  return useSyncExternalStore(subscribeReducedMotion, reducedMotion, serverReduced);
}

export const hasSpeechAPI = () => typeof window !== "undefined"
  && ("SpeechRecognition" in window || "webkitSpeechRecognition" in window);
export const noSpeechAPI = () => false;
