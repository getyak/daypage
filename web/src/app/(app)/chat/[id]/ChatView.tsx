"use client";

import { useState, useRef, useEffect, useCallback } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { Btn } from "@/components/ui";
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

  const lastAssistant = [...messages].reverse().find(
    (m) => m.role === "assistant" && !m.streaming
  );

  return (
    <div className="chat">
      <div className="chat__main">
        <div className="chat__header">
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 12 }}>
            <div>
              <div className="chat__title">{threadTitle}</div>
              <div className="chat__meta">
                {messages.length} messages · drawing from {currentRefs.length} pages
              </div>
            </div>
            <Btn kind="ghost" size="sm" onClick={() => void handleNewThread()}>
              New conversation
            </Btn>
          </div>
        </div>

        <div className="chat__thread">
          {messages.length === 0 && (
            <div style={{ padding: "32px 0", textAlign: "center", color: "var(--fg-muted)" }}>
              <p className="ds-body-md">Ask anything from your wiki</p>
            </div>
          )}
          {messages.map((msg) => (
            <div key={msg.id} className={`msg msg--${msg.role}`}>
              <div className="msg__role">{msg.role === "user" ? "You" : "Codex"}</div>
              <div className="msg__body">
                <p>
                  {renderContent(
                    msg.content,
                    (n) => setActiveRef(activeRef === n ? null : n),
                    activeRef
                  )}
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
                </p>
              </div>
            </div>
          ))}
          {error && (
            <div
              style={{
                background: "var(--error-soft)",
                color: "var(--error)",
                borderRadius: "var(--radius-sm)",
                padding: "0.75rem 1rem",
                fontSize: "0.875rem",
                margin: "8px 0",
              }}
            >
              {error}
            </div>
          )}
          <div ref={bottomRef} />
        </div>

        {lastAssistant?.suggested_followups?.length ? (
          <div className="chat__followups">
            {lastAssistant.suggested_followups.map((q: string, i: number) => (
              <button
                key={i}
                type="button"
                className="chip chip--ghost chip--interactive"
                onClick={() => {
                  setInput(q);
                  textareaRef.current?.focus();
                  void sendMessage(q);
                }}
              >
                ✦ {q}
              </button>
            ))}
          </div>
        ) : null}

        <div className="chat__input-wrap">
          <textarea
            ref={textareaRef}
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={handleKeyDown}
            rows={1}
            placeholder="Ask the wiki anything…"
            disabled={sending}
          />
          <Btn kind="ghost" size="sm" aria-label="Attach" disabled title="coming soon">
            📎
          </Btn>
          <Btn
            kind="primary"
            size="sm"
            onClick={() => void sendMessage(input)}
            disabled={sending || !input.trim()}
          >
            {sending ? "…" : "Ask"}
          </Btn>
        </div>
        <div className="chat__disclaimer">Answers come from your wiki only.</div>
      </div>

      <aside className="cites">
        <p className="ds-section-label" style={{ marginBottom: 12 }}>
          References
        </p>
        {currentRefs.length === 0 ? (
          <p className="ds-mono-11" style={{ color: "var(--fg-subtle)" }}>
            None yet. Ask a question to surface sources.
          </p>
        ) : (
          <div>
            {currentRefs.map((c) => (
              <Link
                key={c.n}
                href={`/wiki/${c.slug}`}
                className={"cite-card" + (activeRef === c.n ? " is-active" : "")}
                style={{ display: "block", textDecoration: "none" }}
                onMouseEnter={() => setActiveRef(c.n)}
              >
                <div className="cite-card__num">
                  [{c.n}] {c.type}
                </div>
                <div className="cite-card__title">{c.title}</div>
                {c.excerpt && <div className="cite-card__excerpt">{c.excerpt}</div>}
              </Link>
            ))}
          </div>
        )}
        {threads.length > 1 && (
          <div style={{ marginTop: 24, paddingTop: 16, borderTop: "1px solid var(--accent-border)" }}>
            <p className="ds-section-label" style={{ marginBottom: 8 }}>
              Other conversations
            </p>
            <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
              {threads
                .filter((t) => t.id !== threadId)
                .slice(0, 5)
                .map((t) => (
                  <Link
                    key={t.id}
                    href={`/chat/${t.id}`}
                    style={{
                      fontSize: 12,
                      color: "var(--fg-muted)",
                      textDecoration: "none",
                      padding: "4px 0",
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                      whiteSpace: "nowrap",
                    }}
                  >
                    {t.title}
                  </Link>
                ))}
            </div>
          </div>
        )}
      </aside>
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
          className={"cite" + (activeRef === n ? " is-active" : "")}
          onClick={() => onCiteClick(n)}
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

