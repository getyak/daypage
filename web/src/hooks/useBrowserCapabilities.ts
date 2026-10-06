"use client";

import { useSyncExternalStore } from "react";

const noopSubscribe = () => () => {};
const serverUnsupported = () => false;
const serverReduced = () => true;
const motionQuery = "(prefers-reduced-motion: reduce)";

export function speechSupported() {
  return typeof window !== "undefined" &&
    ("SpeechRecognition" in window || "webkitSpeechRecognition" in window);
}

export function useSpeechSupported() {
  return useSyncExternalStore(noopSubscribe, speechSupported, serverUnsupported);
}

function reducedSnapshot() {
  return typeof window === "undefined" || window.matchMedia(motionQuery).matches;
}

function subscribeMotion(onChange: () => void) {
  const query = window.matchMedia(motionQuery);
  query.addEventListener("change", onChange);
  return () => query.removeEventListener("change", onChange);
}

export function useReducedMotionPreference() {
  return useSyncExternalStore(subscribeMotion, reducedSnapshot, serverReduced);
}

function shaderSnapshot() {
  return typeof navigator !== "undefined" && (navigator.hardwareConcurrency ?? 4) >= 4;
}

export function useShaderCapable() {
  return useSyncExternalStore(noopSubscribe, shaderSnapshot, serverUnsupported);
}
