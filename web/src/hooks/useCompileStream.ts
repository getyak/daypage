"use client";

import { useEffect, useRef, useState } from "react";

export interface CompileProgressEvent {
  type: "progress";
  memo_id: string;
  status: "pending" | "running" | "done" | "failed";
  step?: string;
  progress?: number;
  error?: string;
}

export type MemoProgress = {
  status: "pending" | "running" | "done" | "failed";
  step?: string;
  progress?: number;
  error?: string;
};

// Subscribes to /api/stream/compile and maintains a map of memo_id → progress state.
// The server closes the stream after MAX_IDLE_POLLS consecutive empty polls; on "idle"
// the client closes immediately so networkidle can settle quickly.
export function useCompileStream(): Map<string, MemoProgress> {
  const [progressMap, setProgressMap] = useState<Map<string, MemoProgress>>(
    new Map()
  );
  const esRef = useRef<EventSource | null>(null);

  useEffect(() => {
    const es = new EventSource("/api/stream/compile");
    esRef.current = es;

    es.onmessage = (event: MessageEvent<string>) => {
      try {
        const data = JSON.parse(event.data) as CompileProgressEvent | { type: "ping" | "error" | "idle" };

        // Server signals no in-flight work — close immediately so networkidle can settle
        if (data.type === "idle") {
          es.close();
          esRef.current = null;
          return;
        }

        if (data.type !== "progress") return;

        const { memo_id, status, step, progress, error } = data as CompileProgressEvent;
        setProgressMap((prev) => {
          const next = new Map(prev);
          next.set(memo_id, { status, step, progress, error });
          return next;
        });
      } catch {
        // ignore parse errors
      }
    };

    es.onerror = () => {
      // EventSource will auto-reconnect; nothing to do here
    };

    return () => {
      es.close();
      esRef.current = null;
    };
  }, []);

  return progressMap;
}
