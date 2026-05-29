"use client";

import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { Webhook, Check, Trash2 } from "lucide-react";
import { Btn, Card, SectionLabel } from "@/components/ui";

interface WebhookConfig {
  configured: boolean;
  id?: string;
  url?: string;
  has_secret?: boolean;
  enabled?: boolean;
}

const inputStyle: React.CSSProperties = {
  flex: 1,
  padding: "0.4rem 0.75rem",
  border: "1px solid var(--accent-border)",
  borderRadius: "var(--radius-sm, 6px)",
  background: "var(--surface-1)",
  color: "var(--fg-primary)",
  fontSize: "0.875rem",
};

function useWebhook() {
  return useQuery<WebhookConfig>({
    queryKey: ["webhook"],
    queryFn: async () => {
      const res = await fetch("/api/webhooks");
      if (!res.ok) throw new Error("Failed to fetch webhook config");
      return res.json() as Promise<WebhookConfig>;
    },
  });
}

function useSaveWebhook() {
  const qc = useQueryClient();
  return useMutation<
    WebhookConfig,
    Error,
    { url: string; secret?: string; enabled: boolean }
  >({
    mutationFn: async (input) => {
      const res = await fetch("/api/webhooks", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(input),
      });
      if (!res.ok) {
        const err = (await res.json().catch(() => ({}))) as { error?: string };
        throw new Error(err.error ?? "Failed to save webhook");
      }
      return res.json() as Promise<WebhookConfig>;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ["webhook"] }),
  });
}

function useDeleteWebhook() {
  const qc = useQueryClient();
  return useMutation<void, Error, void>({
    mutationFn: async () => {
      const res = await fetch("/api/webhooks", { method: "DELETE" });
      if (!res.ok && res.status !== 204) throw new Error("Failed to remove webhook");
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ["webhook"] }),
  });
}

export function WebhookSection() {
  const { data, isLoading } = useWebhook();
  const save = useSaveWebhook();
  const remove = useDeleteWebhook();

  const [url, setUrl] = useState("");
  const [secret, setSecret] = useState("");

  // Hydrate the URL field with the saved value when it loads (adjust-state-
  // during-render: cheaper than an effect and lint-clean). We track the last
  // server URL we synced so user edits aren't clobbered on re-render.
  const [syncedUrl, setSyncedUrl] = useState<string | null>(null);
  const serverUrl = data?.url ?? "";
  if (serverUrl && serverUrl !== syncedUrl) {
    setSyncedUrl(serverUrl);
    setUrl(serverUrl);
  }

  async function handleSave() {
    const u = url.trim();
    if (!u) return;
    await save.mutateAsync({
      url: u,
      // Only send the secret when the user typed one; blank keeps the existing.
      secret: secret.trim() ? secret.trim() : undefined,
      enabled: true,
    });
    setSecret("");
  }

  async function handleRemove() {
    if (typeof window !== "undefined") {
      const ok = window.confirm("Remove webhook? Page changes will no longer be pushed.");
      if (!ok) return;
    }
    await remove.mutateAsync();
    setUrl("");
    setSecret("");
  }

  const configured = data?.configured === true;

  return (
    <div className="mt-32 settings-section">
      <SectionLabel>
        <span className="settings-section-title">
          <Webhook size={14} strokeWidth={1.8} />
          Webhook
        </span>
      </SectionLabel>

      <Card>
        {isLoading ? (
          <div
            className="settings-row"
            style={{ color: "var(--fg-subtle)", fontSize: "0.8125rem" }}
          >
            Loading…
          </div>
        ) : (
          <>
            <div className="settings-row">
              <div className="settings-row-text">
                <div
                  className="settings-row-label"
                  style={{ display: "flex", alignItems: "center", gap: 6 }}
                >
                  {configured && (
                    <Check size={14} style={{ color: "var(--color-success, #22c55e)" }} />
                  )}
                  {configured ? "Active" : "Outbound webhook"}
                </div>
                <div className="settings-row-desc">
                  Push <code style={{ fontSize: "0.75rem" }}>page.changed</code> events
                  (create / update / promote-to-live) to your endpoint so external
                  agents can react. Payloads are signed with{" "}
                  <code style={{ fontSize: "0.75rem" }}>X-DayPage-Signature</code>{" "}
                  (HMAC-SHA256 of the body using your secret).
                  {configured && data?.has_secret === false && (
                    <span style={{ color: "var(--color-warning, #f59e0b)" }}>
                      {" "}No secret set — payloads are unsigned.
                    </span>
                  )}
                </div>
              </div>
            </div>

            <div className="divider" />

            <div className="settings-row" style={{ flexDirection: "column", gap: 8, alignItems: "stretch" }}>
              <input
                type="url"
                placeholder="https://your-agent.example.com/daypage-hook"
                value={url}
                onChange={(e) => setUrl(e.target.value)}
                style={inputStyle}
              />
              <input
                type="password"
                placeholder={
                  data?.has_secret
                    ? "Signing secret (leave blank to keep current)"
                    : "Signing secret (optional)"
                }
                value={secret}
                onChange={(e) => setSecret(e.target.value)}
                style={inputStyle}
              />
              <div style={{ display: "flex", gap: 8 }}>
                <Btn
                  kind="primary"
                  size="sm"
                  onClick={handleSave}
                  disabled={!url.trim() || save.isPending}
                >
                  {save.isPending ? "Saving…" : configured ? "Update" : "Save"}
                </Btn>
                {configured && (
                  <Btn
                    kind="ghost"
                    size="sm"
                    icon={<Trash2 size={14} />}
                    onClick={handleRemove}
                    disabled={remove.isPending}
                  >
                    {remove.isPending ? "Removing…" : "Remove"}
                  </Btn>
                )}
              </div>
            </div>

            {save.isError && (
              <div
                className="settings-row"
                style={{ color: "var(--color-error, #ef4444)", fontSize: "0.8125rem", paddingTop: 0 }}
              >
                {save.error?.message}
              </div>
            )}
          </>
        )}
      </Card>
    </div>
  );
}
