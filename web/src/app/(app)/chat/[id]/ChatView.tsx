"use client";

import { useState, useRef, useEffect, useCallback } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import type { Citation } from "./page";

interface Message {
  id: string;
  role: "user" | "assistant";
  content: string;
  citations: Citation[] | null;
  created_at: string;
  suggested_followups?: string[];
  idk?: boolean;
  streaming?: boolean;
}

interface Reference {
  n: number;
  page_id: string;
  slug: string;
  title: string;
  type: string;
  score: number;
  excerpt: string;
}

interface ThreadSummary {
  id: string;
  title: string;
  updated_at: string;
}

interface ChatViewProps {
  threadId: string;
  threadTitle: string;
  initialMessages: Message[];
  threads: ThreadSummary[];
}

export function ChatView({ threadId, threadTitle, initialMessages, threads }: ChatViewProps) {
  const router = useRouter();
  const [messages, setMessages] = useState<Message[]>(initialMessages);
  const [input, setInput] = useState("");
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [activeRef, setActiveRef] = useState<number | null>(null);
  const [currentRefs, setCurrentRefs] = useState<Reference[]>([]);
  const bottomRef = useRef<HTMLDivElement>(null);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  const sendMessage = useCallback(
    async (text: string) => {
      if (!text.trim() || sending) return;
      setError(null);
      setSending(true);
      setActiveRef(null);

      const userMsg: Message = {
        id: crypto.randomUUID(),
        role: "user",
        content: text,
        citations: null,
        created_at: new Date().toISOString(),
      };

      const assistantPlaceholder: Message = {
        id: crypto.randomUUID(),
        role: "assistant",
        content: "",
        citations: null,
        created_at: new Date().toISOString(),
        streaming: true,
      };

      setMessages((prev) => [...prev, userMsg, assistantPlaceholder]);
      setInput("");

      try {
        const res = await fetch(`/api/chat/threads/${threadId}/messages`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ content: text }),
        });

        if (res.status === 429) {
          setError("Daily token limit reached. Try again tomorrow.");
          setMessages((prev) => prev.filter((m) => m.id !== assistantPlaceholder.id));
          setSending(false);
          return;
        }

        if (!res.ok || !res.body) {
          setError("Failed to send message. Please try again.");
          setMessages((prev) => prev.filter((m) => m.id !== assistantPlaceholder.id));
          setSending(false);
          return;
        }

        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";

        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          buffer += decoder.decode(value, { stream: true });
          const parts = buffer.split("\n\n");
          buffer = parts.pop() ?? "";

          for (const part of parts) {
            const line = part.trim();
            if (!line.startsWith("data: ")) continue;
            let evt: Record<string, unknown>;
            try {
              evt = JSON.parse(line.slice(6)) as Record<string, unknown>;
            } catch {
              continue;
            }

            if (evt.type === "token" && typeof evt.content === "string") {
              setMessages((prev) =>
                prev.map((m) =>
                  m.id === assistantPlaceholder.id
                    ? { ...m, content: m.content + evt.content }
                    : m
                )
              );
            } else if (evt.type === "done") {
              const refs = Array.isArray(evt.references) ? (evt.references as Reference[]) : [];
              const citations = Array.isArray(evt.citations) ? (evt.citations as Citation[]) : null;
              const suggested = Array.isArray(evt.suggested_followups)
                ? (evt.suggested_followups as string[])
                : [];
              const idk = Boolean(evt.idk);
              const messageId = typeof evt.message_id === "string" ? evt.message_id : crypto.randomUUID();

              setCurrentRefs(refs);
              setMessages((prev) =>
                prev.map((m) =>
                  m.id === assistantPlaceholder.id
                    ? {
                        ...m,
                        id: messageId,
                        streaming: false,
                        citations,
                        suggested_followups: suggested,
                        idk,
                      }
                    : m
                )
              );
              router.refresh();
            } else if (evt.type === "error") {
              setError(typeof evt.message === "string" ? evt.message : "An error occurred.");
            }
          }
        }
      } catch {
        setError("Connection error. Please try again.");
        setMessages((prev) => prev.filter((m) => m.id !== assistantPlaceholder.id));
      } finally {
        setSending(false);
      }
    },
    [threadId, sending, router]
  );

  function handleKeyDown(e: React.KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      void sendMessage(input);
    }
  }

  async function handleNewThread() {
    const res = await fetch("/api/chat/threads", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    if (res.ok) {
      const thread = (await res.json()) as { id: string };
      router.push(`/chat/${thread.id}`);
      router.refresh();
    }
  }

  return (
    <div style={{ display: "flex", height: "calc(100vh - 52px)" }}>
      {/* Thread list sidebar */}
      <aside
        style={{
          width: "280px",
          flexShrink: 0,
          borderRight: "1px solid var(--accent-border)",
          background: "var(--surface-white)",
          display: "flex",
          flexDirection: "column",
        }}
      >
        <div
          style={{
            padding: "1rem",
            borderBottom: "1px solid var(--accent-border)",
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
          }}
        >
          <p className="ds-section-label">Conversations</p>
          <button
            type="button"
            className="btn btn--soft btn--sm"
            onClick={handleNewThread}
          >
            New
          </button>
        </div>
        <ul style={{ listStyle: "none", margin: 0, padding: "0.5rem", flex: 1, overflowY: "auto" }}>
          {threads.map((t) => (
            <li key={t.id}>
              <Link
                href={`/chat/${t.id}`}
                style={{
                  display: "block",
                  padding: "0.625rem 0.75rem",
                  borderRadius: "var(--radius-sm)",
                  textDecoration: "none",
                  color: "var(--fg-primary)",
                  background: t.id === threadId ? "var(--accent-soft)" : undefined,
                  transition: "background 100ms ease-out",
                }}
                className={t.id !== threadId ? "sidebar-nav-item" : undefined}
              >
                <p
                  style={{
                    fontSize: "0.875rem",
                    fontWeight: t.id === threadId ? 600 : 500,
                    margin: 0,
                    overflow: "hidden",
                    textOverflow: "ellipsis",
                    whiteSpace: "nowrap",
                    color: t.id === threadId ? "var(--accent)" : "var(--fg-primary)",
                  }}
                >
                  {t.title}
                </p>
                <p className="ds-mono-11" style={{ margin: "0.125rem 0 0" }}>
                  {formatRelative(t.updated_at)}
                </p>
              </Link>
            </li>
          ))}
        </ul>
      </aside>

      {/* Main chat area */}
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
        {/* Thread header */}
        <div
          style={{
            padding: "0.75rem 1.5rem",
            borderBottom: "1px solid var(--accent-border)",
            background: "var(--surface-white)",
            flexShrink: 0,
          }}
        >
          <p style={{ fontWeight: 600, fontSize: "0.9375rem", margin: 0, color: "var(--fg-primary)" }}>
            {threadTitle}
          </p>
        </div>

        {/* Messages + References */}
        <div style={{ flex: 1, display: "flex", overflow: "hidden" }}>
          {/* Messages */}
          <div
            style={{
              flex: 1,
              overflowY: "auto",
              padding: "1.5rem",
              display: "flex",
              flexDirection: "column",
              gap: "1.25rem",
            }}
          >
            {messages.length === 0 && (
              <div
                style={{
                  textAlign: "center",
                  marginTop: "4rem",
                  color: "var(--fg-muted)",
                }}
              >
                <p className="ds-body-md">Ask anything from your wiki</p>
              </div>
            )}

            {messages.map((msg) => (
              <MessageBubble
                key={msg.id}
                msg={msg}
                onCiteClick={(n) => setActiveRef(activeRef === n ? null : n)}
                activeRef={activeRef}
                onFollowupClick={(q) => {
                  setInput(q);
                  textareaRef.current?.focus();
                  void sendMessage(q);
                }}
              />
            ))}

            {error && (
              <div
                style={{
                  background: "var(--error-soft)",
                  color: "var(--error)",
                  borderRadius: "var(--radius-sm)",
                  padding: "0.75rem 1rem",
                  fontSize: "0.875rem",
                }}
              >
                {error}
              </div>
            )}

            <div ref={bottomRef} />
          </div>

          {/* References sidebar */}
          {currentRefs.length > 0 && (
            <aside
              style={{
                width: "280px",
                flexShrink: 0,
                borderLeft: "1px solid var(--accent-border)",
                background: "var(--surface-white)",
                overflowY: "auto",
                padding: "1rem",
                display: "flex",
                flexDirection: "column",
                gap: "0.75rem",
              }}
            >
              <p className="ds-section-label">References</p>
              {currentRefs.map((ref) => (
                <a
                  key={ref.n}
                  href={`/wiki/${ref.slug}`}
                  target="_blank"
                  rel="noreferrer"
                  style={{
                    display: "block",
                    textDecoration: "none",
                    borderRadius: "var(--radius-sm)",
                    border: `1px solid ${activeRef === ref.n ? "var(--accent)" : "var(--accent-border)"}`,
                    background: activeRef === ref.n ? "var(--accent-soft)" : "var(--surface-white)",
                    padding: "0.625rem 0.75rem",
                    transition: "border-color 100ms ease-out, background 100ms ease-out",
                  }}
                >
                  <div
                    style={{
                      display: "flex",
                      alignItems: "center",
                      gap: "0.375rem",
                      marginBottom: "0.25rem",
                    }}
                  >
                    <span
                      style={{
                        background: "var(--accent)",
                        color: "#fff",
                        fontFamily: "var(--font-jetbrains-mono)",
                        fontSize: "0.625rem",
                        fontWeight: 700,
                        padding: "0.125rem 0.375rem",
                        borderRadius: "999px",
                        lineHeight: 1.4,
                      }}
                    >
                      {ref.n}
                    </span>
                    <span
                      style={{
                        fontSize: "0.6875rem",
                        fontWeight: 500,
                        textTransform: "uppercase",
                        letterSpacing: "0.06em",
                        color: "var(--fg-subtle)",
                      }}
                    >
                      {ref.type}
                    </span>
                  </div>
                  <p
                    style={{
                      fontSize: "0.8125rem",
                      fontWeight: 600,
                      color: "var(--fg-primary)",
                      margin: "0 0 0.25rem",
                    }}
                  >
                    {ref.title}
                  </p>
                  {ref.excerpt && (
                    <p
                      style={{
                        fontSize: "0.75rem",
                        color: "var(--fg-muted)",
                        margin: 0,
                        lineHeight: 1.5,
                        display: "-webkit-box",
                        WebkitLineClamp: 3,
                        WebkitBoxOrient: "vertical",
                        overflow: "hidden",
                      }}
                    >
                      {ref.excerpt}
                    </p>
                  )}
                </a>
              ))}
            </aside>
          )}
        </div>

        {/* Composer */}
        <div
          style={{
            borderTop: "1px solid var(--accent-border)",
            background: "var(--surface-white)",
            padding: "1rem 1.5rem",
            flexShrink: 0,
          }}
        >
          <div
            style={{
              display: "flex",
              gap: "0.625rem",
              alignItems: "flex-end",
            }}
          >
            <textarea
              ref={textareaRef}
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={handleKeyDown}
              placeholder="Ask a question… (Enter to send, Shift+Enter for newline)"
              rows={3}
              disabled={sending}
              style={{
                flex: 1,
                resize: "none",
                border: "1px solid var(--accent-border)",
                borderRadius: "var(--radius-sm)",
                padding: "0.625rem 0.75rem",
                fontFamily: "var(--font-inter)",
                fontSize: "0.9375rem",
                lineHeight: 1.5,
                background: "var(--bg-warm)",
                color: "var(--fg-primary)",
                outline: "none",
              }}
            />
            <button
              type="button"
              className="btn btn--primary btn--md"
              onClick={() => void sendMessage(input)}
              disabled={sending || !input.trim()}
              style={{ flexShrink: 0 }}
            >
              {sending ? "…" : "Send"}
            </button>
          </div>
          <p className="ds-mono-11" style={{ marginTop: "0.375rem" }}>
            Answers are grounded in your wiki. Citations appear as {"{N}"} tokens.
          </p>
        </div>
      </div>
    </div>
  );
}

function MessageBubble({
  msg,
  onCiteClick,
  activeRef,
  onFollowupClick,
}: {
  msg: Message;
  onCiteClick: (n: number) => void;
  activeRef: number | null;
  onFollowupClick: (q: string) => void;
}) {
  const isUser = msg.role === "user";

  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: isUser ? "flex-end" : "flex-start",
        gap: "0.375rem",
      }}
    >
      {!isUser && (
        <span
          style={{
            fontSize: "0.6875rem",
            fontWeight: 600,
            textTransform: "uppercase",
            letterSpacing: "0.06em",
            color: "var(--fg-subtle)",
          }}
        >
          Assistant
        </span>
      )}

      <div
        style={{
          maxWidth: "75%",
          padding: "0.75rem 1rem",
          borderRadius: "var(--radius-md)",
          background: isUser ? "var(--accent)" : "var(--surface-white)",
          color: isUser ? "#fff" : "var(--fg-primary)",
          border: isUser ? "none" : "1px solid var(--accent-border)",
          fontSize: "0.9375rem",
          lineHeight: 1.65,
          whiteSpace: "pre-wrap",
          wordBreak: "break-word",
        }}
      >
        {renderContent(msg.content, onCiteClick, activeRef)}
        {msg.streaming && (
          <span
            style={{
              display: "inline-block",
              width: "0.5rem",
              height: "1em",
              background: "var(--fg-muted)",
              borderRadius: "1px",
              marginLeft: "2px",
              verticalAlign: "text-bottom",
              animation: "blink 1s step-end infinite",
            }}
          />
        )}
      </div>

      {/* Suggested follow-ups */}
      {!isUser && !msg.streaming && msg.suggested_followups && msg.suggested_followups.length > 0 && (
        <div style={{ display: "flex", flexWrap: "wrap", gap: "0.375rem", maxWidth: "75%" }}>
          {msg.suggested_followups.map((q, i) => (
            <button
              key={i}
              type="button"
              className="chip chip--ghost chip--interactive"
              onClick={() => onFollowupClick(q)}
              style={{ fontSize: "0.8125rem", textAlign: "left", cursor: "pointer" }}
            >
              {q}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

function renderContent(
  content: string,
  onCiteClick: (n: number) => void,
  activeRef: number | null
): React.ReactNode {
  const parts = content.split(/(\{(\d+)\})/g);
  const result: React.ReactNode[] = [];
  let i = 0;

  while (i < parts.length) {
    const part = parts[i];
    if (part === undefined) { i++; continue; }

    const citeMatch = part.match(/^\{(\d+)\}$/);
    if (citeMatch) {
      const n = parseInt(citeMatch[1], 10);
      result.push(
        <button
          key={i}
          type="button"
          className="cite"
          onClick={() => onCiteClick(n)}
          style={{
            display: "inline-flex",
            alignItems: "center",
            justifyContent: "center",
            width: "1.125rem",
            height: "1.125rem",
            borderRadius: "50%",
            background: activeRef === n ? "var(--accent)" : "var(--accent-soft)",
            color: activeRef === n ? "#fff" : "var(--accent)",
            fontSize: "0.5625rem",
            fontWeight: 700,
            border: "none",
            cursor: "pointer",
            verticalAlign: "super",
            lineHeight: 1,
            padding: 0,
            marginLeft: "1px",
            transition: "background 100ms ease-out, color 100ms ease-out",
          }}
        >
          {n}
        </button>
      );
    } else if (part) {
      result.push(<span key={i}>{part}</span>);
    }
    i++;
  }

  return result;
}

function formatRelative(dateStr: string): string {
  const date = new Date(dateStr);
  const now = Date.now();
  const diff = now - date.getTime();
  const mins = Math.floor(diff / 60_000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 7) return `${days}d ago`;
  return date.toLocaleDateString();
}
