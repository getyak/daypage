"use client";

import { useCallback, useMemo, useState, useSyncExternalStore } from "react";
import {
  User as UserIcon,
  Palette,
  Sparkles,
  Bell,
  Database,
  Info,
  Check,
  Download,
  Trash2,
  ExternalLink,
} from "lucide-react";
import { Btn, Card, Chip, Icon, SectionLabel } from "@/components/ui";

// ── Types ─────────────────────────────────────────────────────────────
type Theme = "system" | "light" | "dark";
type Density = "comfortable" | "compact";
type Lang = "en" | "zh";
type AIModel = "qwen3.5-plus" | "qwen-max" | "qwen-turbo";

interface Preferences {
  theme: Theme;
  density: Density;
  language: Lang;
  weekStart: "sunday" | "monday";
  ai: {
    model: AIModel;
    temperature: number; // 0..1, step 0.1
    autoCompile: boolean;
  };
  notifications: {
    dailyDigest: boolean;
    compileDone: boolean;
    inboxAlerts: boolean;
  };
}

const STORAGE_KEY = "codex.settings.v1";

const DEFAULT_PREFS: Preferences = {
  theme: "system",
  density: "comfortable",
  language: "en",
  weekStart: "monday",
  ai: {
    model: "qwen3.5-plus",
    temperature: 0.6,
    autoCompile: true,
  },
  notifications: {
    dailyDigest: true,
    compileDone: true,
    inboxAlerts: false,
  },
};

// ── Props ─────────────────────────────────────────────────────────────
export interface SettingsClientProps {
  user: {
    name: string | null;
    email: string | null;
    plan: string;
  };
  signOutAction: () => Promise<void>;
}

// ── Storage subscription (useSyncExternalStore avoids setState-in-effect) ──
const storageSubscribers = new Set<() => void>();
// `undefined` = never read; `null` = read, no entry; string = serialized prefs.
let cachedSnapshot: string | null | undefined = undefined;

function subscribeStorage(onChange: () => void) {
  storageSubscribers.add(onChange);
  const handler = (e: StorageEvent) => {
    if (e.key === STORAGE_KEY) {
      cachedSnapshot = e.newValue;
      onChange();
    }
  };
  window.addEventListener("storage", handler);
  return () => {
    storageSubscribers.delete(onChange);
    window.removeEventListener("storage", handler);
  };
}

function readStorageSnapshot(): string | null {
  if (cachedSnapshot !== undefined) return cachedSnapshot;
  try {
    cachedSnapshot = window.localStorage.getItem(STORAGE_KEY);
  } catch {
    cachedSnapshot = null;
  }
  return cachedSnapshot;
}

function writeStorageSnapshot(value: Preferences): void {
  const next = JSON.stringify(value);
  cachedSnapshot = next;
  try {
    window.localStorage.setItem(STORAGE_KEY, next);
  } catch {
    // ignore quota errors
  }
  for (const cb of storageSubscribers) cb();
}

function parseSnapshot(raw: string | null): Preferences {
  if (!raw) return DEFAULT_PREFS;
  try {
    const parsed = JSON.parse(raw) as Partial<Preferences>;
    return {
      ...DEFAULT_PREFS,
      ...parsed,
      ai: { ...DEFAULT_PREFS.ai, ...(parsed.ai ?? {}) },
      notifications: {
        ...DEFAULT_PREFS.notifications,
        ...(parsed.notifications ?? {}),
      },
    };
  } catch {
    return DEFAULT_PREFS;
  }
}

// ── Page ──────────────────────────────────────────────────────────────
export function SettingsClient({ user, signOutAction }: SettingsClientProps) {
  // Server renders DEFAULT_PREFS; client hydrates from localStorage.
  // useSyncExternalStore returns `undefined` on the server (via the SSR snapshot)
  // and the actual localStorage value after hydration.
  const snapshot = useSyncExternalStore<string | null | undefined>(
    subscribeStorage,
    readStorageSnapshot,
    () => undefined,
  );
  const hydrated = snapshot !== undefined;
  const prefs = useMemo<Preferences>(
    () => parseSnapshot(snapshot ?? null),
    [snapshot],
  );
  const [savedAt, setSavedAt] = useState<number | null>(null);

  const persist = useCallback((next: Preferences) => {
    writeStorageSnapshot(next);
    setSavedAt(Date.now());
  }, []);

  const update = useCallback(
    <K extends keyof Preferences>(key: K, value: Preferences[K]) => {
      persist({ ...prefs, [key]: value });
    },
    [prefs, persist],
  );

  const updateAI = useCallback(
    <K extends keyof Preferences["ai"]>(key: K, value: Preferences["ai"][K]) => {
      persist({ ...prefs, ai: { ...prefs.ai, [key]: value } });
    },
    [prefs, persist],
  );

  const updateNotif = useCallback(
    <K extends keyof Preferences["notifications"]>(
      key: K,
      value: Preferences["notifications"][K],
    ) => {
      persist({ ...prefs, notifications: { ...prefs.notifications, [key]: value } });
    },
    [prefs, persist],
  );

  const initials = useMemo(() => {
    const base = user.name ?? user.email ?? "U";
    return (
      base
        .split(/[\s@.]+/)
        .filter(Boolean)
        .slice(0, 2)
        .map((s) => s[0]?.toUpperCase() ?? "")
        .join("") || "U"
    );
  }, [user]);

  const handleExport = useCallback(() => {
    try {
      const blob = new Blob([JSON.stringify(prefs, null, 2)], { type: "application/json" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `daypage-settings-${new Date().toISOString().slice(0, 10)}.json`;
      a.click();
      URL.revokeObjectURL(url);
    } catch {
      // ignore
    }
  }, [prefs]);

  const handleReset = useCallback(() => {
    if (typeof window !== "undefined") {
      const ok = window.confirm(
        "Reset all preferences to defaults? This only clears local settings, not your data.",
      );
      if (!ok) return;
    }
    persist(DEFAULT_PREFS);
  }, [persist]);

  return (
    <div className="page settings-page">
      {/* Hero */}
      <header className="settings-hero">
        <div>
          <div
            className="ds-section-label"
            style={{
              color: "var(--accent)",
              marginBottom: 14,
              display: "inline-flex",
              alignItems: "center",
              gap: 6,
            }}
          >
            <Icon as={Sparkles} size={12} />
            Preferences
          </div>
          <h1 className="hero-headline" style={{ fontSize: 36 }}>
            Settings
            <br />
            <span className="accent">tune DayPage to your rhythm.</span>
          </h1>
          <p className="hero-sub">
            Changes are saved instantly on this device. Account-wide sync is on the roadmap.
          </p>
        </div>

        <Card className="settings-saved-card">
          <div className="settings-saved-row">
            <span className="settings-saved-dot" aria-hidden />
            <div>
              <div className="settings-saved-label">Local preferences</div>
              <div className="settings-saved-meta">
                {savedAt
                  ? `Saved ${formatRelative(savedAt)}`
                  : hydrated
                    ? "Up to date"
                    : "Loading…"}
              </div>
            </div>
          </div>
          <div className="settings-saved-actions">
            <Btn kind="soft" size="sm" onClick={handleExport} icon={<Download size={14} />}>
              Export JSON
            </Btn>
            <Btn kind="ghost" size="sm" onClick={handleReset}>
              Reset
            </Btn>
          </div>
        </Card>
      </header>

      {/* Profile */}
      <Section icon={UserIcon} title="Profile" hint="Your account on DayPage.">
        <Card>
          <div className="settings-profile">
            <div className="settings-avatar" aria-hidden>
              {initials}
            </div>
            <div className="settings-profile-meta">
              <div className="settings-profile-name">
                {user.name ?? user.email?.split("@")[0] ?? "Account"}
              </div>
              <div className="settings-profile-email">{user.email ?? "—"}</div>
              <div className="settings-profile-chips">
                <Chip tone="accent">{user.plan}</Chip>
                <Chip tone="ghost">github auth</Chip>
              </div>
            </div>
            <form action={signOutAction} className="settings-profile-cta">
              <Btn kind="secondary" size="sm" type="submit">
                Sign out
              </Btn>
            </form>
          </div>
        </Card>
      </Section>

      {/* Appearance */}
      <Section icon={Palette} title="Appearance" hint="How DayPage looks on this device.">
        <Card>
          <Row
            label="Theme"
            description="System matches your OS preference."
            control={
              <Segmented
                value={prefs.theme}
                onChange={(v) => update("theme", v as Theme)}
                options={[
                  { value: "system", label: "System" },
                  { value: "light", label: "Light" },
                  { value: "dark", label: "Dark", disabled: true, hint: "soon" },
                ]}
              />
            }
          />
          <Divider />
          <Row
            label="Density"
            description="Compact tightens row paddings across lists."
            control={
              <Segmented
                value={prefs.density}
                onChange={(v) => update("density", v as Density)}
                options={[
                  { value: "comfortable", label: "Comfortable" },
                  { value: "compact", label: "Compact" },
                ]}
              />
            }
          />
          <Divider />
          <Row
            label="Language"
            description="Interface language. Restart is not required."
            control={
              <Segmented
                value={prefs.language}
                onChange={(v) => update("language", v as Lang)}
                options={[
                  { value: "en", label: "English" },
                  { value: "zh", label: "中文" },
                ]}
              />
            }
          />
          <Divider />
          <Row
            label="Week starts on"
            control={
              <Segmented
                value={prefs.weekStart}
                onChange={(v) => update("weekStart", v as Preferences["weekStart"])}
                options={[
                  { value: "monday", label: "Mon" },
                  { value: "sunday", label: "Sun" },
                ]}
              />
            }
          />
        </Card>
      </Section>

      {/* AI */}
      <Section
        icon={Sparkles}
        title="AI compilation"
        hint="Model and behaviour for nightly compilation."
      >
        <Card>
          <Row
            label="Model"
            description="DashScope-compatible. Larger models cost more tokens."
            control={
              <Segmented
                value={prefs.ai.model}
                onChange={(v) => updateAI("model", v as AIModel)}
                options={[
                  { value: "qwen-turbo", label: "Turbo" },
                  { value: "qwen3.5-plus", label: "Plus" },
                  { value: "qwen-max", label: "Max" },
                ]}
              />
            }
          />
          <Divider />
          <Row
            label="Temperature"
            description={`Creativity. ${prefs.ai.temperature.toFixed(1)} — lower is more literal.`}
            control={
              <div className="settings-slider">
                <input
                  type="range"
                  min={0}
                  max={1}
                  step={0.1}
                  value={prefs.ai.temperature}
                  onChange={(e) => updateAI("temperature", Number(e.target.value))}
                />
                <span className="settings-slider-value">{prefs.ai.temperature.toFixed(1)}</span>
              </div>
            }
          />
          <Divider />
          <Row
            label="Auto-compile at 02:00"
            description="Nightly background job. Skips if no new entries."
            control={
              <Toggle
                checked={prefs.ai.autoCompile}
                onChange={(v) => updateAI("autoCompile", v)}
                ariaLabel="Auto-compile at 02:00"
              />
            }
          />
        </Card>
      </Section>

      {/* Notifications */}
      <Section icon={Bell} title="Notifications" hint="What pings you, and what stays quiet.">
        <Card>
          <Row
            label="Daily digest"
            description="A 7am summary of what landed overnight."
            control={
              <Toggle
                checked={prefs.notifications.dailyDigest}
                onChange={(v) => updateNotif("dailyDigest", v)}
                ariaLabel="Daily digest"
              />
            }
          />
          <Divider />
          <Row
            label="Compile finished"
            description="Local notification when nightly compile completes."
            control={
              <Toggle
                checked={prefs.notifications.compileDone}
                onChange={(v) => updateNotif("compileDone", v)}
                ariaLabel="Compile finished notification"
              />
            }
          />
          <Divider />
          <Row
            label="Inbox alerts"
            description="Ping when the system finds a contradiction or orphan."
            control={
              <Toggle
                checked={prefs.notifications.inboxAlerts}
                onChange={(v) => updateNotif("inboxAlerts", v)}
                ariaLabel="Inbox alerts"
              />
            }
          />
        </Card>
      </Section>

      {/* Data */}
      <Section icon={Database} title="Data" hint="Your stuff. Always exportable.">
        <Card>
          <Row
            label="Export settings"
            description="Download the preferences blob for this device."
            control={
              <Btn kind="soft" size="sm" onClick={handleExport} icon={<Download size={14} />}>
                Export JSON
              </Btn>
            }
          />
          <Divider />
          <Row
            label="Reset preferences"
            description="Restores defaults. Does not touch your pages or memos."
            control={
              <Btn kind="ghost" size="sm" onClick={handleReset} icon={<Trash2 size={14} />}>
                Reset
              </Btn>
            }
          />
          <Divider />
          <Row
            label="Delete account"
            description="Permanent. Removes every memo, page and link."
            control={
              <Btn kind="ghost" size="sm" disabled title="contact support">
                Contact support
              </Btn>
            }
          />
        </Card>
      </Section>

      {/* About */}
      <Section icon={Info} title="About">
        <Card>
          <Row
            label="DayPage"
            description="v0.4 · private build · built on Next.js"
            control={
              <Chip tone="default">
                <Check size={12} style={{ marginRight: 4 }} />
                up to date
              </Chip>
            }
          />
          <Divider />
          <Row
            label="Source"
            description="Open source on GitHub."
            control={
              <a
                href="https://github.com/getyak/daypage"
                target="_blank"
                rel="noreferrer"
                className="btn btn--ghost btn--sm"
              >
                Repository
                <span className="btn__icon btn__icon--right">
                  <ExternalLink size={14} />
                </span>
              </a>
            }
          />
        </Card>
      </Section>
    </div>
  );
}

// ── Primitives ────────────────────────────────────────────────────────
function Section({
  icon: IconCmp,
  title,
  hint,
  children,
}: {
  icon: React.ComponentType<{ size?: number; strokeWidth?: number }>;
  title: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <div className="mt-32 settings-section">
      <SectionLabel
        right={hint ? <span className="settings-section-hint">{hint}</span> : undefined}
      >
        <span className="settings-section-title">
          <IconCmp size={14} strokeWidth={1.8} />
          {title}
        </span>
      </SectionLabel>
      {children}
    </div>
  );
}

function Row({
  label,
  description,
  control,
}: {
  label: string;
  description?: string;
  control: React.ReactNode;
}) {
  return (
    <div className="settings-row">
      <div className="settings-row-text">
        <div className="settings-row-label">{label}</div>
        {description ? <div className="settings-row-desc">{description}</div> : null}
      </div>
      <div className="settings-row-control">{control}</div>
    </div>
  );
}

function Divider() {
  return <div className="divider" />;
}

interface SegmentedOption {
  value: string;
  label: string;
  disabled?: boolean;
  hint?: string;
}

function Segmented({
  value,
  onChange,
  options,
}: {
  value: string;
  onChange: (next: string) => void;
  options: SegmentedOption[];
}) {
  return (
    <div className="settings-segmented" role="radiogroup">
      {options.map((opt) => {
        const isActive = opt.value === value;
        return (
          <button
            key={opt.value}
            type="button"
            role="radio"
            aria-checked={isActive}
            disabled={opt.disabled}
            title={opt.hint}
            className={[
              "settings-segmented-item",
              isActive ? "is-active" : "",
              opt.disabled ? "is-disabled" : "",
            ]
              .filter(Boolean)
              .join(" ")}
            onClick={() => !opt.disabled && onChange(opt.value)}
          >
            {opt.label}
          </button>
        );
      })}
    </div>
  );
}

function Toggle({
  checked,
  onChange,
  ariaLabel,
}: {
  checked: boolean;
  onChange: (next: boolean) => void;
  ariaLabel: string;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={ariaLabel}
      className={`settings-toggle ${checked ? "is-on" : ""}`}
      onClick={() => onChange(!checked)}
    >
      <span className="settings-toggle-thumb" />
    </button>
  );
}

// ── Utils ─────────────────────────────────────────────────────────────
function formatRelative(ts: number): string {
  const diff = Date.now() - ts;
  if (diff < 1500) return "just now";
  const s = Math.floor(diff / 1000);
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  return new Date(ts).toLocaleString();
}
