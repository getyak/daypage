"use client";

import { useState, useRef, useCallback, useEffect } from "react";
import { MessageSquare, X, Send, Loader } from "lucide-react";

interface AskAboutPageProps {
  pageSlug: string;
  pageTitle: string;
  pageBodyMd: string | null;
}

interface Message {
  role: "user" | "assistant";
  content: string;
  streaming?: boolean;
}

export function AskAboutPage({ pageSlug, pageTitle, pageBodyMd }: AskAboutPageProps) {
  const [open, setOpen] = useState(false);
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const bottomRef = useRef<HTMLDivElement>(null);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  // Auto-resize textarea
  useEffect(() => {
    const ta = textareaRef.current;
    if (!ta) return;
    ta.style.height = "auto";
    ta.style.height = `${Math.min(ta.scrollHeight, 160)}px`;
  }, [input]);

  const handleAsk = useCallback(async () => {
    const q = input.trim();
    if (!q || loading) return;

    setInput("");
    setError(null);
    setMessages((prev) => [...prev, { role: "user", content: q }]);
    setLoading(true);

    try {
      // Create or reuse a thread then send the message with page context prepended
      const createRes = await fetch("/api/chat/threads", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ title: `Ask: ${pageTitle}` }),
      });

      if (!createRes.ok) {
        throw new Error("Failed to create thread");
      }

      const { id: threadId } = (await createRes.json()) as { id: string };

      // Build context-enriched question
      const contextPrefix = pageBodyMd
        ? `[Context: wiki page "${pageTitle}"]\n\n${pageBodyMd.slice(0, 1200)}\n\n---\n\n`
        : `[Context: wiki page "${pageTitle}"]\n\n`;

      const fullQuestion = contextPrefix + q;

      // Stream the response
      const msgRes = await fetch(`/api/chat/threads/${threadId}/messages`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ content: fullQuestion }),
      });

      if (!msgRes.ok) {
        throw new Error("Failed to send message");
      }

      const reader = msgRes.body?.getReader();
      if (!reader) throw new Error("No response stream");

      const decoder = new TextDecoder();
      let assistantContent = "";

      setMessages((prev) => [
        ...prev,
        { role: "assistant", content: "", streaming: true },
      ]);

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        const chunk = decoder.decode(value, { stream: true });
        const lines = chunk.split("\n");

        for (const line of lines) {
          if (!line.startsWith("data: ")) continue;
          try {
            const evt = JSON.parse(line.slice(6)) as { type: string; content?: string };
            if (evt.type === "token" && evt.content) {
              assistantContent += evt.content;
              setMessages((prev) => {
                const next = [...prev];
                const last = next[next.length - 1];
                if (last?.role === "assistant") {
                  next[next.length - 1] = { ...last, content: assistantContent, streaming: true };
                }
                return next;
              });
            } else if (evt.type === "done") {
              setMessages((prev) => {
                const next = [...prev];
                const last = next[next.length - 1];
                if (last?.role === "assistant") {
                  next[next.length - 1] = { ...last, content: assistantContent, streaming: false };
                }
                return next;
              });
            }
          } catch {
            // ignore parse errors
          }
        }
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Something went wrong");
      setMessages((prev) => prev.filter((m) => !m.streaming));
    } finally {
      setLoading(false);
    }
  }, [input, loading, pageBodyMd, pageTitle]);

  if (!open) {
    return (
      <button
        className="btn btn--soft btn--sm"
        onClick={() => setOpen(true)}
        style={{ display: "flex", alignItems: "center", gap: "0.375rem" }}
      >
        <MessageSquare size={13} />
        Ask
      </button>
    );
  }

  return (
    <div
      style={{
        position: "fixed",
        bottom: "1.5rem",
        right: "1.5rem",
        width: "min(420px, calc(100vw - 3rem))",
        maxHeight: "520px",
        background: "var(--surface-white)",
        border: "1px solid var(--accent-border)",
        borderRadius: "var(--radius-md)",
        boxShadow: "0 8px 32px rgba(0,0,0,0.12)",
        display: "flex",
        flexDirection: "column",
        zIndex: 200,
        overflow: "hidden",
      }}
    >
      {/* Header */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: "0.5rem",
          padding: "0.75rem 1rem",
          borderBottom: "1px solid var(--accent-border)",
          flexShrink: 0,
        }}
      >
        <MessageSquare size={14} style={{ color: "var(--accent)" }} />
        <span
          style={{
            flex: 1,
            fontSize: "0.875rem",
            fontWeight: 600,
            color: "var(--fg-primary)",
            overflow: "hidden",
            textOverflow: "ellipsis",
            whiteSpace: "nowrap",
          }}
        >
          Ask about &ldquo;{pageTitle}&rdquo;
        </span>
        <button
          type="button"
          className="btn btn--ghost btn--sm"
          onClick={() => setOpen(false)}
          aria-label="Close"
          style={{ padding: "0.25rem", minWidth: 0 }}
        >
          <X size={14} />
        </button>
      </div>

      {/* Messages */}
      <div
        style={{
          flex: 1,
          overflowY: "auto",
          padding: "0.75rem 1rem",
          display: "flex",
          flexDirection: "column",
          gap: "0.75rem",
        }}
      >
        {messages.length === 0 && (
          <p
            style={{
              fontSize: "0.8125rem",
              color: "var(--fg-subtle)",
              textAlign: "center",
              margin: "1rem 0",
            }}
          >
            Ask anything about this page.
          </p>
        )}
        {messages.map((msg, i) => (
          <div
            key={i}
            style={{
              alignSelf: msg.role === "user" ? "flex-end" : "flex-start",
              maxWidth: "85%",
              padding: "0.5rem 0.75rem",
              borderRadius: msg.role === "user" ? "12px 12px 4px 12px" : "12px 12px 12px 4px",
              background: msg.role === "user" ? "var(--accent-soft)" : "var(--surface-sunken)",
              fontSize: "0.8125rem",
              lineHeight: 1.5,
              color: "var(--fg-primary)",
              whiteSpace: "pre-wrap",
              wordBreak: "break-word",
            }}
          >
            {msg.content}
            {msg.streaming && (
              <span
                style={{
                  display: "inline-block",
                  width: "0.4em",
                  height: "0.9em",
                  background: "var(--accent)",
                  marginLeft: "0.15em",
                  verticalAlign: "text-bottom",
                  animation: "blink 0.7s step-end infinite",
                }}
              />
            )}
          </div>
        ))}
        {error && (
          <p style={{ fontSize: "0.8125rem", color: "var(--error)", textAlign: "center" }}>
            {error}
          </p>
        )}
        <div ref={bottomRef} />
      </div>

      {/* Input */}
      <div
        style={{
          padding: "0.625rem 0.75rem",
          borderTop: "1px solid var(--accent-border)",
          display: "flex",
          gap: "0.5rem",
          alignItems: "flex-end",
          flexShrink: 0,
        }}
      >
        <textarea
          ref={textareaRef}
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Ask a question…"
          rows={1}
          style={{
            flex: 1,
            resize: "none",
            border: "1px solid var(--accent-border)",
            borderRadius: "var(--radius-sm)",
            padding: "0.4375rem 0.625rem",
            fontSize: "0.875rem",
            background: "var(--bg-warm)",
            color: "var(--fg-primary)",
            fontFamily: "inherit",
            outline: "none",
            minHeight: "2rem",
            maxHeight: "160px",
            overflowY: "auto",
          }}
          onKeyDown={(e) => {
            if ((e.metaKey || e.ctrlKey) && e.key === "Enter" && !loading) {
              e.preventDefault();
              handleAsk();
            }
          }}
        />
        <button
          type="button"
          className="btn btn--primary btn--sm"
          disabled={!input.trim() || loading}
          onClick={handleAsk}
          aria-label="Send"
          style={{ flexShrink: 0, height: "2rem" }}
        >
          {loading ? <Loader size={13} style={{ animation: "spin 1s linear infinite" }} /> : <Send size={13} />}
        </button>
      </div>

    </div>
  );
}
