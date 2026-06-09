"use client";

import { useEffect, useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { Sparkles, Check, CloudOff } from "lucide-react";
import { Btn, Card, SectionLabel } from "@/components/ui";
import {
  EVOLUTION_SETTINGS_KEY,
  EVOLUTION_SCHEDULES,
  DEFAULT_EVOLUTION_CONFIG,
  type EvolutionConfig,
} from "@/lib/settings/evolution";

// US-022: settings UI for the autonomous evolution loop (US-021 block). Reads
// the `evolution` block from GET /api/settings and saves it back via PUT — only
// that one key is sent, so the route's merge-upsert leaves other settings intact.

// Default hour a fresh "daily" schedule fires on (local 09:00).
const DEFAULT_DAILY_HOUR = 9;

function useEvolutionConfig() {
  return useQuery<EvolutionConfig>({
    queryKey: ["settings", "evolution"],
    queryFn: async () => {
      const res = await fetch("/api/settings");
      if (!res.ok) throw new Error("Failed to load settings");
      const data = (await res.json()) as {
        settings?: Record<string, unknown>;
      };
      const raw = data.settings?.[EVOLUTION_SETTINGS_KEY];
      // The route normalizes on write; here we shallow-merge over defaults so a
      // missing/partial block still renders complete controls.
      return {
        ...DEFAULT_EVOLUTION_CONFIG,
        ...(raw && typeof raw === "object" ? (raw as Partial<EvolutionConfig>) : {}),
      };
    },
  });
}

function useSaveEvolutionConfig() {
  const qc = useQueryClient();
  return useMutation<EvolutionConfig, Error, EvolutionConfig>({
    mutationFn: async (config) => {
      const res = await fetch("/api/settings", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ [EVOLUTION_SETTINGS_KEY]: config }),
      });
      if (!res.ok) {
        const err = (await res.json().catch(() => ({}))) as { error?: string };
        throw new Error(err.error ?? "Failed to save");
      }
      const data = (await res.json()) as {
        settings?: Record<string, unknown>;
      };
      const saved = data.settings?.[EVOLUTION_SETTINGS_KEY];
      return {
        ...DEFAULT_EVOLUTION_CONFIG,
        ...(saved && typeof saved === "object" ? (saved as Partial<EvolutionConfig>) : config),
      };
    },
    onSuccess: (saved) => {
      qc.setQueryData(["settings", "evolution"], saved);
    },
  });
}

export function EvolutionSection() {
  const { data: remote, isLoading } = useEvolutionConfig();
  const save = useSaveEvolutionConfig();

  // Local draft so edits don't write on every keystroke; saved on "Save".
  const [draft, setDraft] = useState<EvolutionConfig>(DEFAULT_EVOLUTION_CONFIG);
  const [savedAt, setSavedAt] = useState<number | null>(null);

  // Sync draft from server whenever the remote value (re)loads.
  useEffect(() => {
    if (remote) setDraft(remote);
  }, [remote]);

  const dirty = remote ? JSON.stringify(draft) !== JSON.stringify(remote) : false;

  function patch(next: Partial<EvolutionConfig>) {
    setDraft((d) => ({ ...d, ...next }));
  }

  async function handleSave() {
    await save.mutateAsync(draft);
    setSavedAt(Date.now());
  }

  const inputStyle: React.CSSProperties = {
    padding: "0.4rem 0.6rem",
    border: "1px solid var(--accent-border)",
    borderRadius: "var(--radius-sm, 6px)",
    background: "var(--surface-1)",
    color: "var(--fg-primary)",
    fontSize: "0.875rem",
  };

  return (
    <div className="mt-32 settings-section">
      <SectionLabel
        right={<span className="settings-section-hint">When the system evolves & pushes.</span>}
      >
        <span className="settings-section-title">
          <Sparkles size={14} strokeWidth={1.8} />
          演化与推送
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
            {/* Enabled toggle */}
            <div className="settings-row">
              <div className="settings-row-text">
                <div className="settings-row-label">启用演化</div>
                <div className="settings-row-desc">
                  系统按设定节奏生成任务建议并推送到所选通道。
                </div>
              </div>
              <div className="settings-row-control">
                <button
                  type="button"
                  role="switch"
                  aria-checked={draft.enabled}
                  aria-label="启用演化"
                  className={`settings-toggle ${draft.enabled ? "is-on" : ""}`}
                  onClick={() => patch({ enabled: !draft.enabled })}
                >
                  <span className="settings-toggle-thumb" />
                </button>
              </div>
            </div>

            <div className="divider" />

            {/* Frequency */}
            <div className="settings-row">
              <div className="settings-row-text">
                <div className="settings-row-label">频率</div>
                <div className="settings-row-desc">
                  每小时跟随调度心跳；每日仅在所选时刻触发一次。
                </div>
              </div>
              <div
                className="settings-row-control"
                style={{ display: "flex", alignItems: "center", gap: 8 }}
              >
                <div className="settings-segmented" role="radiogroup">
                  {EVOLUTION_SCHEDULES.map((s) => (
                    <button
                      key={s}
                      type="button"
                      role="radio"
                      aria-checked={draft.schedule === s}
                      className={`settings-segmented-item ${draft.schedule === s ? "is-active" : ""}`}
                      onClick={() =>
                        patch(
                          // Switching to daily pins an explicit hour so the
                          // saved block carries a concrete "每日+时刻".
                          s === "daily"
                            ? { schedule: s, dailyHour: draft.dailyHour ?? DEFAULT_DAILY_HOUR }
                            : { schedule: s }
                        )
                      }
                    >
                      {s === "hourly" ? "每小时" : "每日"}
                    </button>
                  ))}
                </div>
                {draft.schedule === "daily" && (
                  <select
                    aria-label="每日时刻"
                    value={draft.dailyHour ?? DEFAULT_DAILY_HOUR}
                    onChange={(e) => patch({ dailyHour: Number(e.target.value) })}
                    style={inputStyle}
                  >
                    {Array.from({ length: 24 }, (_, h) => (
                      <option key={h} value={h}>
                        {String(h).padStart(2, "0")}:00
                      </option>
                    ))}
                  </select>
                )}
              </div>
            </div>

            <div className="divider" />

            {/* Channel */}
            <div className="settings-row">
              <div className="settings-row-text">
                <div className="settings-row-label">通道</div>
                <div className="settings-row-desc">建议推送到哪里。</div>
              </div>
              <div className="settings-row-control">
                <div className="settings-segmented" role="radiogroup">
                  <button
                    type="button"
                    role="radio"
                    aria-checked={draft.channel === "telegram"}
                    className="settings-segmented-item is-active"
                    onClick={() => patch({ channel: "telegram" })}
                  >
                    Telegram
                  </button>
                </div>
              </div>
            </div>

            <div className="divider" />

            {/* Per-tree budget */}
            <div className="settings-row">
              <div className="settings-row-text">
                <div className="settings-row-label">每树预算</div>
                <div className="settings-row-desc">
                  单次运行每棵任务树允许消耗的 token 上限。
                </div>
              </div>
              <div className="settings-row-control">
                <input
                  type="number"
                  min={1}
                  step={500}
                  aria-label="每树预算 (tokens)"
                  value={draft.perTreeBudgetTokens}
                  onChange={(e) =>
                    patch({
                      perTreeBudgetTokens: Math.max(1, Math.floor(Number(e.target.value) || 0)),
                    })
                  }
                  style={{ ...inputStyle, width: 110, textAlign: "right" }}
                />
              </div>
            </div>

            <div className="divider" />

            {/* Save row */}
            <div
              className="settings-row"
              style={{ alignItems: "center", gap: 10 }}
            >
              <div className="settings-row-text">
                {save.isError ? (
                  <div
                    className="settings-row-desc"
                    style={{ color: "var(--color-error, #ef4444)", display: "flex", alignItems: "center", gap: 4 }}
                  >
                    <CloudOff size={13} />
                    {save.error?.message}
                  </div>
                ) : savedAt && !dirty ? (
                  <div
                    className="settings-row-desc"
                    style={{ color: "var(--success, #22c55e)", display: "flex", alignItems: "center", gap: 4 }}
                  >
                    <Check size={13} />
                    已保存
                  </div>
                ) : (
                  <div className="settings-row-desc">
                    {dirty ? "有未保存的更改。" : "已是最新。"}
                  </div>
                )}
              </div>
              <div className="settings-row-control">
                <Btn
                  kind="primary"
                  size="sm"
                  onClick={handleSave}
                  disabled={!dirty || save.isPending}
                >
                  {save.isPending ? "保存中…" : "保存"}
                </Btn>
              </div>
            </div>
          </>
        )}
      </Card>
    </div>
  );
}
