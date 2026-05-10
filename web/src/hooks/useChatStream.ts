"use client";

import { useState, useCallback, useRef } from "react";

export interface ChatReference {
  n: number;
  page_id: string;
  slug: string;
  title: string;
  type: string;
  score?: number;
  excerpt: string;
}

export interface ChatCitation {
  n: number;
  page_id: string;
  slug: string;
  title: string;
  type: string;
  excerpt: string;
}

export interface StreamingMessage {
  id: string | null;
  role: "assistant";
  content: string;
  citations: ChatCitation[];
  references: ChatReference[];
  isStreaming: boolean;
  error: string | null;
}

export interface UseChatStreamResult {
  streamingMsg: StreamingMessage | null;
  send: (threadId: string, content: string) => Promise<void>;
  isSending: boolean;
  error: string | null;
  clearError: () => void;
}

export function useChatStream(onDone?: (msg: StreamingMessage) => void): UseChatStreamResult {
  const [streamingMsg, setStreamingMsg] = useState<StreamingMessage | null>(null);
  const [isSending, setIsSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const send = useCallback(
    async (threadId: string, content: string) => {
      // Cancel any in-flight request
      abortRef.current?.abort();
      const controller = new AbortController();
      abortRef.current = controller;

      setIsSending(true);
      setError(null);
      setStreamingMsg({
        id: null,
        role: "assistant",
        content: "",
        citations: [],
        references: [],
        isStreaming: true,
        error: null,
      });

      try {
        const res = await fetch(`/api/chat/threads/${threadId}/messages`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ content }),
          signal: controller.signal,
        });

        if (!res.ok) {
          const body = await res.text().catch(() => "");
          let msg = `Error ${res.status}`;
          try {
            const j = JSON.parse(body) as { error?: string };
            if (j.error) msg = j.error;
          } catch { /* ignore */ }
          throw new Error(msg);
        }

        if (!res.body) throw new Error("No response body");

        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";
        let finalMsg: StreamingMessage | null = null;

        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split("\n");
          buffer = lines.pop() ?? "";

          for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed.startsWith("data: ")) continue;
            let parsed: Record<string, unknown>;
            try {
              parsed = JSON.parse(trimmed.slice(6)) as Record<string, unknown>;
            } catch {
              continue;
            }

            if (parsed.type === "token") {
              const chunk = parsed.content as string;
              setStreamingMsg((prev) =>
                prev ? { ...prev, content: prev.content + chunk } : null
              );
            } else if (parsed.type === "done") {
              const citations = (parsed.citations as ChatCitation[]) ?? [];
              const references = (parsed.references as ChatReference[]) ?? [];
              const messageId = (parsed.message_id as string) ?? null;
              setStreamingMsg((prev) => {
                if (!prev) return null;
                const finished: StreamingMessage = {
                  ...prev,
                  id: messageId,
                  citations,
                  references,
                  isStreaming: false,
                };
                finalMsg = finished;
                return finished;
              });
            } else if (parsed.type === "error") {
              const errMsg = (parsed.message as string) ?? "Unknown error";
              setStreamingMsg((prev) =>
                prev ? { ...prev, isStreaming: false, error: errMsg } : null
              );
              setError(errMsg);
            }
          }
        }

        if (finalMsg) onDone?.(finalMsg);
      } catch (err: unknown) {
        if (err instanceof Error && err.name === "AbortError") return;
        const msg = err instanceof Error ? err.message : "An error occurred";
        setError(msg);
        setStreamingMsg((prev) =>
          prev ? { ...prev, isStreaming: false, error: msg } : null
        );
      } finally {
        setIsSending(false);
      }
    },
    [onDone]
  );

  const clearError = useCallback(() => setError(null), []);

  return { streamingMsg, send, isSending, error, clearError };
}
