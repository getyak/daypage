"use client";

import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { Key, Trash2, Plus, Copy, Check } from "lucide-react";
import { Btn, Card, SectionLabel } from "@/components/ui";
import { Dialog } from "../_components/Dialog";

// ── Types ──────────────────────────────────────────────────────────────────────

interface ApiKeyRecord {
  id: string;
  name: string;
  key_prefix: string;
  scopes: string[];
  last_used_at: string | null;
  created_at: string;
  expires_at: string | null;
}

interface CreatedKey extends ApiKeyRecord {
  key: string;
}

const ALL_SCOPES = ["read", "write", "admin"];

// ── Hooks ──────────────────────────────────────────────────────────────────────

function useKeys() {
  return useQuery<ApiKeyRecord[]>({
    queryKey: ["api-keys"],
    queryFn: async () => {
      const res = await fetch("/api/keys");
      if (!res.ok) throw new Error("Failed to fetch keys");
      return res.json() as Promise<ApiKeyRecord[]>;
    },
  });
}

function useCreateKey() {
  const qc = useQueryClient();
  return useMutation<CreatedKey, Error, { name: string; scopes: string[] }>({
    mutationFn: async (body) => {
      const res = await fetch("/api/keys", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      if (!res.ok) {
        const err = (await res.json().catch(() => ({}))) as { error?: string };
        throw new Error(err.error ?? "Failed to create key");
      }
      return res.json() as Promise<CreatedKey>;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ["api-keys"] }),
  });
}

function useDeleteKey() {
  const qc = useQueryClient();
  return useMutation<void, Error, string>({
    mutationFn: async (id) => {
      const res = await fetch(`/api/keys/${id}`, { method: "DELETE" });
      if (!res.ok && res.status !== 204) throw new Error("Failed to delete key");
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ["api-keys"] }),
  });
}

// ── Component ──────────────────────────────────────────────────────────────────

export function ApiKeysSection() {
  const { data: keys = [], isLoading } = useKeys();
  const createKey = useCreateKey();
  const deleteKey = useDeleteKey();

  const [createOpen, setCreateOpen] = useState(false);
  const [newKeyName, setNewKeyName] = useState("");
  const [newKeyScopes, setNewKeyScopes] = useState<string[]>(["read"]);
  const [createdKey, setCreatedKey] = useState<CreatedKey | null>(null);
  const [copied, setCopied] = useState(false);
  const [deleteConfirm, setDeleteConfirm] = useState<string | null>(null);

  function openCreate() {
    setNewKeyName("");
    setNewKeyScopes(["read"]);
    setCreateOpen(true);
  }

  async function handleCreate() {
    if (!newKeyName.trim()) return;
    const result = await createKey.mutateAsync({
      name: newKeyName.trim(),
      scopes: newKeyScopes,
    });
    setCreateOpen(false);
    setCreatedKey(result);
  }

  async function handleCopy() {
    if (!createdKey) return;
    await navigator.clipboard.writeText(createdKey.key).catch(() => undefined);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  function toggleScope(scope: string) {
    setNewKeyScopes((prev) =>
      prev.includes(scope) ? prev.filter((s) => s !== scope) : [...prev, scope]
    );
  }

  return (
    <div className="mt-32 settings-section">
      <SectionLabel
        right={
          <Btn
            kind="soft"
            size="sm"
            onClick={openCreate}
            icon={<Plus size={14} />}
          >
            Create API Key
          </Btn>
        }
      >
        <span className="settings-section-title">
          <Key size={14} strokeWidth={1.8} />
          API Keys
        </span>
      </SectionLabel>

      <Card>
        {isLoading ? (
          <div className="settings-row" style={{ color: "var(--fg-subtle)", fontSize: "0.8125rem" }}>
            Loading…
          </div>
        ) : keys.length === 0 ? (
          <div className="settings-row" style={{ color: "var(--fg-subtle)", fontSize: "0.8125rem" }}>
            No API keys yet. Create one to access DayPage programmatically.
          </div>
        ) : (
          keys.map((k, i) => (
            <div key={k.id}>
              {i > 0 && <div className="divider" />}
              <div className="settings-row">
                <div className="settings-row-text">
                  <div className="settings-row-label" style={{ display: "flex", alignItems: "center", gap: 6 }}>
                    <code style={{ fontSize: "0.75rem", background: "var(--surface-2)", padding: "1px 5px", borderRadius: 4 }}>
                      {k.key_prefix}…
                    </code>
                    {k.name}
                  </div>
                  <div className="settings-row-desc">
                    Scopes: {(k.scopes ?? []).join(", ")} ·{" "}
                    {k.last_used_at
                      ? `Last used ${new Date(k.last_used_at).toLocaleDateString()}`
                      : "Never used"}{" "}
                    · Created {new Date(k.created_at).toLocaleDateString()}
                  </div>
                </div>
                <div className="settings-row-control">
                  <Btn
                    kind="ghost"
                    size="sm"
                    icon={<Trash2 size={14} />}
                    onClick={() => setDeleteConfirm(k.id)}
                    disabled={deleteKey.isPending}
                  >
                    Delete
                  </Btn>
                </div>
              </div>
            </div>
          ))
        )}
      </Card>

      {/* Create key dialog */}
      <Dialog open={createOpen} onClose={() => setCreateOpen(false)} title="Create API Key">
        <div style={{ display: "flex", flexDirection: "column", gap: "1rem", marginTop: "0.5rem" }}>
          <div>
            <label
              htmlFor="key-name"
              style={{ display: "block", fontSize: "0.8125rem", fontWeight: 500, marginBottom: 6 }}
            >
              Name
            </label>
            <input
              id="key-name"
              type="text"
              placeholder="e.g. iOS sync"
              value={newKeyName}
              onChange={(e) => setNewKeyName(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && handleCreate()}
              style={{
                width: "100%",
                padding: "0.5rem 0.75rem",
                border: "1px solid var(--accent-border)",
                borderRadius: "var(--radius-sm, 6px)",
                background: "var(--surface-1)",
                color: "var(--fg-primary)",
                fontSize: "0.875rem",
                boxSizing: "border-box",
              }}
            />
          </div>
          <div>
            <div style={{ fontSize: "0.8125rem", fontWeight: 500, marginBottom: 6 }}>Scopes</div>
            <div style={{ display: "flex", gap: 8 }}>
              {ALL_SCOPES.map((scope) => (
                <label
                  key={scope}
                  style={{ display: "flex", alignItems: "center", gap: 4, fontSize: "0.8125rem", cursor: "pointer" }}
                >
                  <input
                    type="checkbox"
                    checked={newKeyScopes.includes(scope)}
                    onChange={() => toggleScope(scope)}
                  />
                  {scope}
                </label>
              ))}
            </div>
          </div>
          {createKey.isError && (
            <div style={{ color: "var(--color-error, #ef4444)", fontSize: "0.8125rem" }}>
              {createKey.error?.message}
            </div>
          )}
          <div style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}>
            <Btn kind="ghost" size="sm" onClick={() => setCreateOpen(false)}>
              Cancel
            </Btn>
            <Btn
              kind="primary"
              size="sm"
              onClick={handleCreate}
              disabled={!newKeyName.trim() || createKey.isPending}
            >
              {createKey.isPending ? "Creating…" : "Create"}
            </Btn>
          </div>
        </div>
      </Dialog>

      {/* Reveal key one-time dialog */}
      <Dialog
        open={!!createdKey}
        onClose={() => setCreatedKey(null)}
        title="API Key Created"
      >
        <div style={{ display: "flex", flexDirection: "column", gap: "1rem", marginTop: "0.5rem" }}>
          <p style={{ fontSize: "0.8125rem", color: "var(--fg-subtle)", margin: 0 }}>
            Copy your key now — it will not be shown again.
          </p>
          <div
            style={{
              background: "var(--surface-2)",
              borderRadius: "var(--radius-sm, 6px)",
              padding: "0.75rem",
              fontFamily: "monospace",
              fontSize: "0.8125rem",
              wordBreak: "break-all",
              color: "var(--fg-primary)",
              border: "1px solid var(--accent-border)",
            }}
          >
            {createdKey?.key}
          </div>
          <div style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}>
            <Btn
              kind="primary"
              size="sm"
              icon={copied ? <Check size={14} /> : <Copy size={14} />}
              onClick={handleCopy}
            >
              {copied ? "Copied!" : "Copy & Close"}
            </Btn>
          </div>
        </div>
      </Dialog>

      {/* Delete confirmation dialog */}
      <Dialog
        open={!!deleteConfirm}
        onClose={() => setDeleteConfirm(null)}
        title="Delete API Key"
      >
        <div style={{ display: "flex", flexDirection: "column", gap: "1rem", marginTop: "0.5rem" }}>
          <p style={{ fontSize: "0.8125rem", color: "var(--fg-subtle)", margin: 0 }}>
            This key will stop working immediately. This action cannot be undone.
          </p>
          <div style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}>
            <Btn kind="ghost" size="sm" onClick={() => setDeleteConfirm(null)}>
              Cancel
            </Btn>
            <Btn
              kind="secondary"
              size="sm"
              icon={<Trash2 size={14} />}
              disabled={deleteKey.isPending}
              onClick={async () => {
                if (deleteConfirm) {
                  await deleteKey.mutateAsync(deleteConfirm);
                  setDeleteConfirm(null);
                }
              }}
            >
              {deleteKey.isPending ? "Deleting…" : "Delete"}
            </Btn>
          </div>
        </div>
      </Dialog>
    </div>
  );
}
