"use client";

import { useCallback, useRef, useState } from "react";
import Link from "next/link";
import { Bot, Plus, Trash2, Pencil, X, Send, FileText } from "lucide-react";
import { Btn, Card, SectionLabel } from "@/components/ui";
import { AGENT_MODELS, DEFAULT_AGENT_MODEL } from "@/lib/ai/agent-models";

export interface AgentDTO {
  id: string;
  name: string;
  persona_prompt: string;
  model: string;
  domain_id: string | null;
  top_k: number;
}

export interface DomainDTO {
  id: string;
  slug: string;
  label: string;
}

interface Citation {
  n: number;
  page_id: string;
  slug: string;
  title: string;
  type: string;
  excerpt: string;
}

interface ChatMsg {
  id: string;
  role: "user" | "assistant";
  content: string;
  citations?: Citation[];
  streaming?: boolean;
}

const inputStyle: React.CSSProperties = {
  width: "100%",
  padding: "0.5rem 0.75rem",
  border: "1px solid var(--accent-border)",
  borderRadius: "var(--radius-sm, 6px)",
  background: "var(--surface-1)",
  color: "var(--fg-primary)",
  fontSize: "0.875rem",
};

const labelStyle: React.CSSProperties = {
  display: "block",
  fontSize: "0.75rem",
  fontWeight: 600,
  color: "var(--fg-muted)",
  marginBottom: 4,
};

interface FormState {
  id: string | null;
  name: string;
  persona_prompt: string;
  model: string;
  domain_id: string;
  top_k: number;
}

const EMPTY_FORM: FormState = {
  id: null,
  name: "",
  persona_prompt: "",
  model: DEFAULT_AGENT_MODEL,
  domain_id: "",
  top_k: 8,
};

export function AgentsClient({
  initialAgents,
  domains,
}: {
  initialAgents: AgentDTO[];
  domains: DomainDTO[];
}) {
  const [agents, setAgents] = useState<AgentDTO[]>(initialAgents);
  const [form, setForm] = useState<FormState | null>(null);
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);
  const [activeAgent, setActiveAgent] = useState<AgentDTO | null>(
    initialAgents[0] ?? null
  );

  const domainLabel = useCallback(
    (id: string | null) => domains.find((d) => d.id === id)?.label ?? null,
    [domains]
  );

  function openCreate() {
    setFormError(null);
    setForm({ ...EMPTY_FORM });
  }

  function openEdit(a: AgentDTO) {
    setFormError(null);
    setForm({
      id: a.id,
      name: a.name,
      persona_prompt: a.persona_prompt,
      model: a.model,
      domain_id: a.domain_id ?? "",
      top_k: a.top_k,
    });
  }

  async function saveForm() {
    if (!form) return;
    if (!form.name.trim() || !form.persona_prompt.trim()) {
      setFormError("Name and persona prompt are required.");
      return;
    }
    setSaving(true);
    setFormError(null);
    try {
      const payload = {
        name: form.name.trim(),
        persona_prompt: form.persona_prompt.trim(),
        model: form.model,
        domain_id: form.domain_id || null,
        top_k: form.top_k,
      };
      const res = await fetch(
        form.id ? `/api/agents/${form.id}` : "/api/agents",
        {
          method: form.id ? "PATCH" : "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload),
        }
      );
      if (!res.ok) {
        const e = (await res.json().catch(() => ({}))) as { error?: string };
        throw new Error(e.error ?? "Failed to save agent");
      }
      const saved = (await res.json()) as AgentDTO;
      setAgents((prev) => {
        const exists = prev.some((a) => a.id === saved.id);
        return exists
          ? prev.map((a) => (a.id === saved.id ? saved : a))
          : [saved, ...prev];
      });
      setActiveAgent(saved);
      setForm(null);
    } catch (err) {
      setFormError(err instanceof Error ? err.message : "Failed to save agent");
    } finally {
      setSaving(false);
    }
  }

  async function deleteAgent(id: string) {
    if (typeof window !== "undefined") {
      const ok = window.confirm("Delete this agent? Its conversations are kept.");
      if (!ok) return;
    }
    const res = await fetch(`/api/agents/${id}`, { method: "DELETE" });
    if (res.ok || res.status === 204) {
      setAgents((prev) => {
        const next = prev.filter((a) => a.id !== id);
        setActiveAgent((cur) => (cur?.id === id ? next[0] ?? null : cur));
        return next;
      });
    }
  }

  return (
    <div className="page" style={{ maxWidth: 920 }}>
      <SectionLabel
        right={
          <Btn kind="primary" size="sm" icon={<Plus size={14} />} onClick={openCreate}>
            New agent
          </Btn>
        }
      >
        <span className="settings-section-title">
          <Bot size={14} strokeWidth={1.8} />
          Agents
        </span>
      </SectionLabel>

      <p className="ds-caption" style={{ color: "var(--fg-muted)", margin: "8px 0 16px" }}>
        Define an assistant grounded in your wiki — give it a persona, pick a
        model, and optionally pin it to one knowledge area. It answers only from
        what you&apos;ve captured and cites the source.
      </p>

      {/* Create / edit form */}
      {form && (
        <Card>
          <div style={{ display: "flex", flexDirection: "column", gap: 14, padding: 4 }}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
              <strong style={{ fontSize: "0.9375rem" }}>
                {form.id ? "Edit agent" : "New agent"}
              </strong>
              <Btn kind="ghost" size="sm" icon={<X size={14} />} onClick={() => setForm(null)}>
                Cancel
              </Btn>
            </div>

            <div>
              <label style={labelStyle} htmlFor="agent-name">Name</label>
              <input
                id="agent-name"
                type="text"
                placeholder="e.g. Writing coach"
                value={form.name}
                onChange={(e) => setForm({ ...form, name: e.target.value })}
                style={inputStyle}
              />
            </div>

            <div>
              <label style={labelStyle} htmlFor="agent-persona">Persona prompt</label>
              <textarea
                id="agent-persona"
                placeholder="You are a candid writing coach. Push me to clarify my arguments using my own notes…"
                value={form.persona_prompt}
                onChange={(e) => setForm({ ...form, persona_prompt: e.target.value })}
                rows={4}
                style={{ ...inputStyle, resize: "vertical", fontFamily: "inherit" }}
              />
            </div>

            <div style={{ display: "flex", gap: 12, flexWrap: "wrap" }}>
              <div style={{ flex: "1 1 200px" }}>
                <label style={labelStyle} htmlFor="agent-model">Model</label>
                <select
                  id="agent-model"
                  value={form.model}
                  onChange={(e) => setForm({ ...form, model: e.target.value })}
                  style={inputStyle}
                >
                  {AGENT_MODELS.map((m) => (
                    <option key={m.id} value={m.id}>
                      {m.label} — {m.hint}
                    </option>
                  ))}
                </select>
              </div>

              <div style={{ flex: "1 1 200px" }}>
                <label style={labelStyle} htmlFor="agent-domain">Retrieval scope</label>
                <select
                  id="agent-domain"
                  value={form.domain_id}
                  onChange={(e) => setForm({ ...form, domain_id: e.target.value })}
                  style={inputStyle}
                >
                  <option value="">All domains</option>
                  {domains.map((d) => (
                    <option key={d.id} value={d.id}>{d.label}</option>
                  ))}
                </select>
              </div>

              <div style={{ flex: "0 0 120px" }}>
                <label style={labelStyle} htmlFor="agent-topk">Recall (top-k)</label>
                <input
                  id="agent-topk"
                  type="number"
                  min={1}
                  max={20}
                  value={form.top_k}
                  onChange={(e) =>
                    setForm({ ...form, top_k: Math.max(1, Math.min(20, Number(e.target.value) || 8)) })
                  }
                  style={inputStyle}
                />
              </div>
            </div>

            {formError && (
              <div style={{ color: "var(--color-error, #ef4444)", fontSize: "0.8125rem" }}>
                {formError}
              </div>
            )}

            <div>
              <Btn kind="primary" size="sm" loading={saving} onClick={saveForm}>
                {form.id ? "Save changes" : "Create agent"}
              </Btn>
            </div>
          </div>
        </Card>
      )}

      {/* Agent list */}
      <div style={{ display: "flex", flexDirection: "column", gap: 10, marginTop: 16 }}>
        {agents.length === 0 && !form ? (
          <Card>
            <div style={{ padding: "24px", textAlign: "center", color: "var(--fg-muted)" }}>
              No agents yet. Create one to chat with your wiki in a custom voice.
            </div>
          </Card>
        ) : (
          agents.map((a) => (
            <Card key={a.id} className={activeAgent?.id === a.id ? "is-active" : ""}>
              <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
                <button
                  type="button"
                  onClick={() => setActiveAgent(a)}
                  style={{
                    flex: 1,
                    textAlign: "left",
                    background: "none",
                    border: "none",
                    cursor: "pointer",
                    padding: 0,
                    minWidth: 0,
                  }}
                >
                  <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                    <Bot size={15} strokeWidth={1.8} />
                    <strong style={{ fontSize: "0.9375rem" }}>{a.name}</strong>
                    <span className="ds-mono-11" style={{ color: "var(--fg-subtle)" }}>
                      {a.model}
                    </span>
                    {domainLabel(a.domain_id) && (
                      <span
                        className="ds-mono-11"
                        style={{
                          color: "var(--fg-subtle)",
                          border: "1px solid var(--accent-border)",
                          borderRadius: 4,
                          padding: "0 6px",
                        }}
                      >
                        {domainLabel(a.domain_id)}
                      </span>
                    )}
                  </div>
                  <div
                    style={{
                      fontSize: "0.8125rem",
                      color: "var(--fg-muted)",
                      marginTop: 4,
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                      whiteSpace: "nowrap",
                    }}
                  >
                    {a.persona_prompt}
                  </div>
                </button>
                <Btn kind="ghost" size="sm" icon={<Pencil size={14} />} onClick={() => openEdit(a)} aria-label="Edit" />
                <Btn kind="ghost" size="sm" icon={<Trash2 size={14} />} onClick={() => deleteAgent(a.id)} aria-label="Delete" />
              </div>
            </Card>
          ))
        )}
      </div>

      {/* Chat panel for the active agent */}
      {activeAgent && (
        <div style={{ marginTop: 24 }}>
          <AgentChat key={activeAgent.id} agent={activeAgent} />
        </div>
      )}
    </div>
  );
}

// ─── Inline RAG-grounded chat with the selected agent ─────────────────────────

function AgentChat({ agent }: { agent: AgentDTO }) {
  const [messages, setMessages] = useState<ChatMsg[]>([]);
  const [input, setInput] = useState("");
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const threadRef = useRef<string | null>(null);

  async function send() {
    const text = input.trim();
    if (!text || sending) return;
    setInput("");
    setError(null);
    setSending(true);

    const userMsg: ChatMsg = { id: `u-${Date.now()}`, role: "user", content: text };
    const assistantId = `a-${Date.now()}`;
    setMessages((prev) => [
      ...prev,
      userMsg,
      { id: assistantId, role: "assistant", content: "", streaming: true },
    ]);

    try {
      const res = await fetch(`/api/agents/${agent.id}/chat`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          content: text,
          thread_id: threadRef.current ?? undefined,
        }),
      });
      if (!res.ok || !res.body) {
        const e = (await res.json().catch(() => ({}))) as { error?: string };
        throw new Error(e.error ?? `Request failed (${res.status})`);
      }

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const parts = buffer.split("\n\n");
        buffer = parts.pop() ?? "";
        for (const part of parts) {
          const line = part.trim();
          if (!line.startsWith("data:")) continue;
          const json = line.slice(5).trim();
          if (!json) continue;
          let evt: Record<string, unknown>;
          try {
            evt = JSON.parse(json);
          } catch {
            continue;
          }
          if (evt.type === "thread" && typeof evt.thread_id === "string") {
            threadRef.current = evt.thread_id;
          } else if (evt.type === "token" && typeof evt.content === "string") {
            const chunk = evt.content;
            setMessages((prev) =>
              prev.map((m) =>
                m.id === assistantId ? { ...m, content: m.content + chunk } : m
              )
            );
          } else if (evt.type === "done") {
            if (typeof evt.thread_id === "string") threadRef.current = evt.thread_id;
            const citations = Array.isArray(evt.citations)
              ? (evt.citations as Citation[])
              : [];
            setMessages((prev) =>
              prev.map((m) =>
                m.id === assistantId ? { ...m, streaming: false, citations } : m
              )
            );
          } else if (evt.type === "error") {
            throw new Error(String(evt.message ?? "Stream error"));
          }
        }
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Chat failed");
      setMessages((prev) =>
        prev.map((m) =>
          m.streaming ? { ...m, streaming: false } : m
        )
      );
    } finally {
      setSending(false);
      setMessages((prev) =>
        prev.map((m) => (m.streaming ? { ...m, streaming: false } : m))
      );
    }
  }

  return (
    <Card>
      <div style={{ padding: 4 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 12 }}>
          <Bot size={15} strokeWidth={1.8} />
          <strong style={{ fontSize: "0.9375rem" }}>Chat with {agent.name}</strong>
        </div>

        <div
          className="agent-chat-log"
          style={{
            display: "flex",
            flexDirection: "column",
            gap: 12,
            maxHeight: 360,
            overflowY: "auto",
            marginBottom: 12,
          }}
        >
          {messages.length === 0 ? (
            <div className="ds-caption" style={{ color: "var(--fg-muted)" }}>
              Ask {agent.name} something. Answers are grounded in your wiki and
              cite the pages they use.
            </div>
          ) : (
            messages.map((m) => (
              <div key={m.id} style={{ display: "flex", flexDirection: "column", gap: 4 }}>
                <span className="ds-mono-11" style={{ color: "var(--fg-subtle)" }}>
                  {m.role === "user" ? "You" : agent.name}
                </span>
                <div
                  style={{
                    fontSize: "0.875rem",
                    color: "var(--fg-primary)",
                    whiteSpace: "pre-wrap",
                  }}
                >
                  {m.content}
                  {m.streaming && <span aria-hidden> ▍</span>}
                </div>
                {m.citations && m.citations.length > 0 && (
                  <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginTop: 2 }}>
                    {m.citations.map((c) => (
                      <Link
                        key={c.n}
                        href={`/wiki/${encodeURIComponent(c.slug)}`}
                        className="ds-mono-11"
                        style={{
                          display: "inline-flex",
                          alignItems: "center",
                          gap: 4,
                          color: "var(--fg-muted)",
                          textDecoration: "none",
                          border: "1px solid var(--accent-border)",
                          borderRadius: 4,
                          padding: "1px 6px",
                        }}
                      >
                        <FileText size={11} />
                        {`{${c.n}} ${c.title}`}
                      </Link>
                    ))}
                  </div>
                )}
              </div>
            ))
          )}
        </div>

        {error && (
          <div style={{ color: "var(--color-error, #ef4444)", fontSize: "0.8125rem", marginBottom: 8 }}>
            {error}
          </div>
        )}

        <div style={{ display: "flex", gap: 8 }}>
          <input
            type="text"
            placeholder={`Message ${agent.name}…`}
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                void send();
              }
            }}
            disabled={sending}
            style={inputStyle}
          />
          <Btn
            kind="primary"
            size="sm"
            icon={<Send size={14} />}
            loading={sending}
            onClick={() => void send()}
            disabled={!input.trim()}
          >
            Send
          </Btn>
        </div>
      </div>
    </Card>
  );
}
