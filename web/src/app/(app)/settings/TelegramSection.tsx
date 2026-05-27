"use client";

import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { MessageCircle, Check, Unlink, ExternalLink } from "lucide-react";
import { Btn, Card, SectionLabel } from "@/components/ui";

interface IngestSource {
  id: string;
  name: string;
  source_type: string;
  config: Record<string, unknown>;
  enabled: boolean;
  created_at: string;
}

function useTelegramSource() {
  return useQuery<IngestSource | null>({
    queryKey: ["ingest-sources", "telegram"],
    queryFn: async () => {
      const res = await fetch("/api/ingest-sources");
      if (!res.ok) throw new Error("Failed to fetch ingest sources");
      const all = (await res.json()) as IngestSource[];
      return all.find((s) => s.source_type === "telegram") ?? null;
    },
  });
}

function useConnectTelegram() {
  const qc = useQueryClient();
  return useMutation<IngestSource, Error, { chatId: string }>({
    mutationFn: async ({ chatId }) => {
      const res = await fetch("/api/ingest-sources", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: "Telegram",
          source_type: "telegram",
          config: { chat_id: chatId },
          enabled: true,
        }),
      });
      if (!res.ok) {
        const err = (await res.json().catch(() => ({}))) as { error?: string };
        throw new Error(err.error ?? "Failed to connect Telegram");
      }
      return res.json() as Promise<IngestSource>;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ["ingest-sources"] }),
  });
}

function useDisconnectTelegram() {
  const qc = useQueryClient();
  return useMutation<void, Error, string>({
    mutationFn: async (id) => {
      const res = await fetch(`/api/ingest-sources/${id}`, { method: "DELETE" });
      if (!res.ok && res.status !== 204) throw new Error("Failed to disconnect");
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ["ingest-sources"] }),
  });
}

export function TelegramSection() {
  const { data: source, isLoading } = useTelegramSource();
  const connect = useConnectTelegram();
  const disconnect = useDisconnectTelegram();
  const [chatId, setChatId] = useState("");

  const botUsername = process.env.NEXT_PUBLIC_TELEGRAM_BOT_USERNAME ?? "DayPageBot";
  const botLink = `https://t.me/${botUsername}`;

  async function handleConnect() {
    const id = chatId.trim();
    if (!id) return;
    await connect.mutateAsync({ chatId: id });
    setChatId("");
  }

  async function handleDisconnect() {
    if (!source) return;
    if (typeof window !== "undefined") {
      const ok = window.confirm("Disconnect Telegram? New messages won't be ingested.");
      if (!ok) return;
    }
    await disconnect.mutateAsync(source.id);
  }

  return (
    <div className="mt-32 settings-section">
      <SectionLabel>
        <span className="settings-section-title">
          <MessageCircle size={14} strokeWidth={1.8} />
          Telegram
        </span>
      </SectionLabel>

      <Card>
        {isLoading ? (
          <div className="settings-row" style={{ color: "var(--fg-subtle)", fontSize: "0.8125rem" }}>
            Loading…
          </div>
        ) : source ? (
          <div className="settings-row">
            <div className="settings-row-text">
              <div className="settings-row-label" style={{ display: "flex", alignItems: "center", gap: 6 }}>
                <Check size={14} style={{ color: "var(--color-success, #22c55e)" }} />
                Connected
              </div>
              <div className="settings-row-desc">
                Chat ID: <code style={{ fontSize: "0.75rem" }}>{String((source.config as Record<string, unknown>).chat_id ?? "—")}</code>
                {" · "}Messages from this chat are saved as memos.
              </div>
            </div>
            <div className="settings-row-control">
              <Btn
                kind="ghost"
                size="sm"
                icon={<Unlink size={14} />}
                onClick={handleDisconnect}
                disabled={disconnect.isPending}
              >
                {disconnect.isPending ? "Disconnecting…" : "Disconnect"}
              </Btn>
            </div>
          </div>
        ) : (
          <>
            <div className="settings-row">
              <div className="settings-row-text">
                <div className="settings-row-label">Connect Telegram</div>
                <div className="settings-row-desc">
                  Send memos to DayPage directly from Telegram.{" "}
                  <a href={botLink} target="_blank" rel="noopener noreferrer" style={{ color: "var(--accent)" }}>
                    Open @{botUsername} <ExternalLink size={11} style={{ verticalAlign: "middle" }} />
                  </a>
                  , start a chat, send <code>/start</code>, then paste your Chat ID below.
                </div>
              </div>
            </div>
            <div className="divider" />
            <div className="settings-row" style={{ gap: 8 }}>
              <input
                type="text"
                placeholder="Telegram Chat ID (e.g. 123456789)"
                value={chatId}
                onChange={(e) => setChatId(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && handleConnect()}
                style={{
                  flex: 1,
                  padding: "0.4rem 0.75rem",
                  border: "1px solid var(--accent-border)",
                  borderRadius: "var(--radius-sm, 6px)",
                  background: "var(--surface-1)",
                  color: "var(--fg-primary)",
                  fontSize: "0.875rem",
                }}
              />
              <Btn
                kind="primary"
                size="sm"
                onClick={handleConnect}
                disabled={!chatId.trim() || connect.isPending}
              >
                {connect.isPending ? "Connecting…" : "Connect"}
              </Btn>
            </div>
            {connect.isError && (
              <div className="settings-row" style={{ color: "var(--color-error, #ef4444)", fontSize: "0.8125rem", paddingTop: 0 }}>
                {connect.error?.message}
              </div>
            )}
          </>
        )}
      </Card>
    </div>
  );
}
