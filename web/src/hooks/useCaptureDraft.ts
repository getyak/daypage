"use client";

import { useSyncExternalStore } from "react";

export const CAPTURE_DRAFT_KEY = "codex.add.draft.v1";

function readSnapshot(): string | null {
  try {
    return localStorage.getItem(CAPTURE_DRAFT_KEY);
  } catch {
    return null;
  }
}

function subscribe(onChange: () => void) {
  const listener = (event: StorageEvent) => {
    if (event.key === CAPTURE_DRAFT_KEY || event.key === null) onChange();
  };
  window.addEventListener("storage", listener);
  return () => window.removeEventListener("storage", listener);
}

const serverSnapshot = () => undefined;

export function draftText(snapshot: string | null | undefined): string {
  if (!snapshot) return "";
  try {
    const parsed: unknown = JSON.parse(snapshot);
    if (parsed && typeof parsed === "object" && "text" in parsed && typeof parsed.text === "string") {
      return parsed.text;
    }
  } catch {
    // Corrupt/blocked storage must not prevent capture.
  }
  return "";
}

export function useCaptureDraft() {
  return useSyncExternalStore<string | null | undefined>(subscribe, readSnapshot, serverSnapshot);
}
