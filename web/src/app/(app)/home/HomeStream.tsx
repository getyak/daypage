"use client";

// HomeStream — the unified home experience, mirroring the iOS Today→DailyPage
// pipeline on the web. Three movements, top to bottom:
//   1. An elegant inline composer + a "compile today" affordance.
//   2. Today's raw memos as flomo-style cards (live compile status per card).
//   3. Yesterday-and-earlier as compiled daily wiki cards.
//
// All data flows through endpoints that already exist and are shared with the
// iOS client: POST /api/memos (capture), POST /api/compile (manual trigger),
// GET /api/today/memos (today's stream), GET /api/compile/status (pipeline
// reachability). The midnight cron (inngest daily-page, 00:30 UTC) compiles the
// previous day automatically; the button here is the on-demand companion.

import { useCallback, useEffect, useRef, useState } from "react";
import Link from "next/link";
import {
  Check,
  Sparkles,
  Loader2,
  ArrowUpRight,
  Clock,
  FileText,
  AlertCircle,
} from "lucide-react";
import { MemoCard, type MemoCardData } from "../today/MemoCard";

// ─── Types ───────────────────────────────────────────────────────────────────

export type DailyPageCard = {
  slug: string; // e.g. "daily/2026-06-23"
  date: string; // YYYY-MM-DD
  title: string;
  excerpt: string;
  source_count: number;
  last_compiled_at: string | null;
};

interface HomeStreamProps {
  initialToday: MemoCardData[];
  dailyPages: DailyPageCard[];
}

const SPIN: React.CSSProperties = { animation: "spin 1s linear infinite" };

// ─── Date helpers ────────────────────────────────────────────────────────────

type TodayStrings = { weekday: string; long: string; iso: string };

function computeToday(): TodayStrings {
  const now = new Date();
  return {
    weekday: now.toLocaleDateString("zh-CN", { weekday: "long" }),
    long: now.toLocaleDateString("zh-CN", { year: "numeric", month: "long", day: "numeric" }),
    iso: `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(
      now.getDate()
    ).padStart(2, "0")}`,
  };
}

// A clock that re-derives the date strings once a minute, so a tab left open
// across midnight rolls over to the new day rather than freezing on mount.
// When the iso day flips, `onCross` fires once — callers use it to refetch
// "today's" memos (so cards left over from 23:59 don't claim to be today's).
function useTodayStrings(onCross?: (prevIso: string, nextIso: string) => void): TodayStrings {
  const [today, setToday] = useState<TodayStrings>(computeToday);
  const crossRef = useRef(onCross);
  useEffect(() => { crossRef.current = onCross; }, [onCross]);

  useEffect(() => {
    const t = setInterval(() => {
      setToday((prev) => {
        const next = computeToday();
        if (next.iso === prev.iso) return prev;
        try { crossRef.current?.(prev.iso, next.iso); } catch { /* ignore */ }
        return next;
      });
    }, 60_000);
    return () => clearInterval(t);
  }, []);
  return today;
}

// Pull the first complete sentence from an excerpt — preferring 。 / ！/ ？
// (Chinese punctuation) then falling back to . / ! / ? (Latin), then to the
// first newline. We never truncate mid-word; if no boundary is found within
// 64 chars, we let the excerpt speak for itself (the CSS will clamp).
function firstSentence(excerpt: string): string {
  const trimmed = excerpt.replace(/\s+/g, " ").trim();
  if (!trimmed) return "";
  const match = trimmed.match(/^[^。！？.!?\n]{2,64}[。！？.!?]/);
  return match ? match[0].trim() : trimmed;
}

// Friendly relative label for a daily wiki card: 昨天 / 前天 / N 天前 / N 周前.
// We deliberately avoid returning a month-day string here — the ISO date already
// sits in the corner stamp, and rendering "6月2日" right next to "2026-06-02"
// reads as a duplicate (and is what produced the "2026-06-026月2日" run-together
// glitch in earlier screenshots).
function relativeDayLabel(dateStr: string): string {
  const [y, m, d] = dateStr.split("-").map(Number);
  if (!y || !m || !d) return dateStr;
  const that = new Date(y, m - 1, d);
  const now = new Date();
  const today0 = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const diffDays = Math.round((today0.getTime() - that.getTime()) / 86_400_000);
  if (diffDays <= 0) return "今天";
  if (diffDays === 1) return "昨天";
  if (diffDays === 2) return "前天";
  if (diffDays < 7) return `${diffDays} 天前`;
  if (diffDays < 30) return `${Math.floor(diffDays / 7)} 周前`;
  if (diffDays < 365) return `${Math.floor(diffDays / 30)} 个月前`;
  return `${Math.floor(diffDays / 365)} 年前`;
}

// ─── Component ───────────────────────────────────────────────────────────────

export function HomeStream({ initialToday, dailyPages }: HomeStreamProps) {
  const [memos, setMemos] = useState<MemoCardData[]>(initialToday);
  const [serviceConnected, setServiceConnected] = useState(true);

  // Midnight-crossing toast — fires once when the iso day flips while the tab
  // is open. The reload below will pull the new day's (likely empty) memo set,
  // and this toast turns the moment into a product beat rather than a glitch.
  const [midnightToast, setMidnightToast] = useState<string | null>(null);
  const midnightToastTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const reloadMemosRef = useRef<() => Promise<void>>(async () => {});
  const onCrossMidnight = useCallback(() => {
    void reloadMemosRef.current();
    setMidnightToast("刚跨过了 00 点，昨天正在编织…");
    if (midnightToastTimer.current) clearTimeout(midnightToastTimer.current);
    midnightToastTimer.current = setTimeout(() => setMidnightToast(null), 6000);
  }, []);
  const { weekday, long, iso } = useTodayStrings(onCrossMidnight);

  // Composer state
  const [draft, setDraft] = useState("");
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saveOk, setSaveOk] = useState(false);
  const taRef = useRef<HTMLTextAreaElement>(null);

  // Compile-today state
  const [compiling, setCompiling] = useState(false);
  const [compileNote, setCompileNote] = useState<string | null>(null);

  // A single screen-reader announcement channel for save/compile outcomes.
  // aria-live only fires on *content change*, so identical consecutive messages
  // (e.g. two saves in a row) wouldn't re-announce — announce() appends an
  // invisible, ever-changing zero-width-space run to force the DOM to differ.
  const [liveMessage, setLiveMessage] = useState("");
  const liveSeq = useRef(0);
  const announce = useCallback((msg: string) => {
    liveSeq.current += 1;
    setLiveMessage(msg + "​".repeat(liveSeq.current % 2 ? 1 : 2));
  }, []);

  // Timers we must clear on unmount to avoid setState-after-unmount.
  const compileNoteTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const saveOkTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(
    () => () => {
      if (compileNoteTimer.current) clearTimeout(compileNoteTimer.current);
      if (saveOkTimer.current) clearTimeout(saveOkTimer.current);
      if (midnightToastTimer.current) clearTimeout(midnightToastTimer.current);
    },
    []
  );

  const scheduleCompileNoteClear = useCallback(() => {
    if (compileNoteTimer.current) clearTimeout(compileNoteTimer.current);
    compileNoteTimer.current = setTimeout(() => setCompileNote(null), 4500);
  }, []);

  const reloadMemos = useCallback(async () => {
    try {
      const r = await fetch("/api/today/memos");
      if (!r.ok) return;
      const d: { memos: MemoCardData[] } = await r.json();
      if (Array.isArray(d.memos)) setMemos(d.memos);
    } catch {
      /* keep last good */
    }
  }, []);
  // Expose the latest reloadMemos to onCrossMidnight without re-arming the
  // clock interval (the clock effect runs once on mount).
  useEffect(() => { reloadMemosRef.current = reloadMemos; }, [reloadMemos]);

  // Probe the compile pipeline once; surface an honest banner when unreachable
  // (mirrors the per-card status logic in MemoCard / the iOS sync queue banner).
  useEffect(() => {
    fetch("/api/compile/status")
      .then((r) => (r.ok ? r.json() : null))
      .then((d: { connected: boolean } | null) => {
        if (d) setServiceConnected(d.connected);
      })
      .catch(() => {});
  }, []);

  // Capture-first home: focus the composer on load, but never on touch devices
  // (forcing the soft keyboard up on mobile is hostile).
  useEffect(() => {
    if (typeof window === "undefined") return;
    const isTouch = window.matchMedia?.("(pointer: coarse)").matches;
    if (!isTouch) taRef.current?.focus();
  }, []);

  // Auto-grow the composer textarea (min 56, max 200).
  useEffect(() => {
    const ta = taRef.current;
    if (!ta) return;
    ta.style.height = "auto";
    ta.style.height = `${Math.min(ta.scrollHeight, 200)}px`;
  }, [draft]);

  const wordCount = draft.replace(/\s/g, "").length;
  const canSave = draft.trim().length > 0 && !saving;

  const handleSave = useCallback(async () => {
    const body = draft.trim();
    if (!body || saving) return;
    setSaving(true);
    setSaveError(null);
    try {
      const r = await fetch("/api/memos", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ body, type: "text", origin: "web" }),
      });
      if (r.ok) {
        setDraft("");
        setSaveOk(true);
        announce("收下了，夜里见");
        if (saveOkTimer.current) clearTimeout(saveOkTimer.current);
        saveOkTimer.current = setTimeout(() => setSaveOk(false), 1800);
        await reloadMemos();
      } else {
        const d = await r.json().catch(() => null);
        // Prefer the server's exact reason when it gives one (validation,
        // rate-limit, auth), otherwise fall back to product voice.
        const msg = d?.error ? String(d.error) : "夜里还远，先再试一次";
        setSaveError(msg);
        announce(msg);
      }
    } catch {
      // Network error — the textarea keeps the draft so nothing is lost.
      setSaveError("夜里还远，先再试一次");
      announce("夜里还远，先再试一次");
    } finally {
      setSaving(false);
    }
  }, [draft, saving, reloadMemos, announce]);

  const handleComposerKey = useCallback(
    (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault();
        void handleSave();
      }
    },
    [handleSave]
  );

  // Manual compile of today's memos. The cron handles midnight automatically;
  // this lets the user weave the day's raw into its daily page on demand.
  //
  // We send the exact memo_ids currently shown in "today" rather than a date.
  // /api/compile's date branch matches a *UTC* calendar day, but "today" here
  // is the user's *local* day (see getTodayMemos / /api/today/memos) — passing
  // ids sidesteps the timezone mismatch and compiles precisely what's on screen.
  const handleCompileToday = useCallback(async () => {
    if (compiling) return;
    const ids = memos.map((m) => m.id);
    if (ids.length === 0) {
      setCompileNote("今天还没有可编译的记录");
      announce("今天还没有可编译的记录");
      scheduleCompileNoteClear();
      return;
    }
    setCompiling(true);
    setCompileNote(null);
    try {
      const r = await fetch("/api/compile", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ memo_ids: ids }),
      });
      const d = await r.json().catch(() => null);
      if (r.ok) {
        const n = (d?.triggered as number | undefined) ?? ids.length;
        const msg = n > 0 ? `已送编译 · ${n} 条` : "今天还没有可编译的记录";
        setCompileNote(msg);
        announce(msg);
        await reloadMemos();
      } else {
        const msg = d?.error ? String(d.error) : "编译触发失败";
        setCompileNote(msg);
        announce(msg);
      }
    } catch {
      setCompileNote("编译触发失败");
      announce("编译触发失败");
    } finally {
      setCompiling(false);
      scheduleCompileNoteClear();
    }
  }, [compiling, memos, reloadMemos, scheduleCompileNoteClear, announce]);

  const handleRetry = useCallback(
    async (id: string) => {
      // Optimistic: mark pending; revert to failed if the recompile call fails.
      setMemos((prev) =>
        prev.map((m) => (m.id === id ? { ...m, compile_status: "pending", compile_error: null } : m))
      );
      try {
        const r = await fetch(`/api/memos/${id}/recompile`, { method: "POST" });
        if (!r.ok) {
          setMemos((prev) =>
            prev.map((m) =>
              m.id === id ? { ...m, compile_status: "failed", compile_error: "重试失败" } : m
            )
          );
          return;
        }
      } catch {
        setMemos((prev) =>
          prev.map((m) =>
            m.id === id ? { ...m, compile_status: "failed", compile_error: "网络错误" } : m
          )
        );
        return;
      }
      await reloadMemos();
    },
    [reloadMemos]
  );

  // Derived: today's compile summary for the daily card.
  const pendingCount = memos.filter(
    (m) => m.compile_status === "pending" || m.compile_status === "running"
  ).length;
  const compiledCount = memos.filter((m) => m.compile_status === "done").length;
  const todayCount = memos.length;

  // Hero rhythm — the slogan retreats as the day fills up:
  //   0 records  → full two-line slogan (welcome / onboarding mood)
  //   ≥1 record  → single calm status line ("已记下 N 条，等夜里编织")
  // The serif title stays, but its content adapts to the user's actual day.
  const heroMode: "intro" | "active" = todayCount === 0 ? "intro" : "active";

  // The on-demand compile button is intentionally restrained: when there's
  // little to weave, we don't tempt the user to break the midnight ritual.
  // It surfaces only once the day has accumulated some material (≥5 raws).
  const showCompileButton = todayCount >= 5;

  return (
    <div className="page home-stream">
      {/* Screen-reader live region for save/compile outcomes. */}
      <p className="sr-only" aria-live="polite" aria-atomic="true">
        {liveMessage}
      </p>

      {/* ── Hero: date + daily compile card ─────────────────────────────── */}
      <div className="home-hero">
        <div>
          <div className="home-hero__eyebrow">
            <Sparkles size={12} strokeWidth={2} aria-hidden="true" />
            {long} · {weekday}
          </div>

          {heroMode === "intro" ? (
            <>
              <h1 className="home-hero__title">
                今天，先把此刻记下来。
                <br />
                <span className="accent">夜里 00 点，它会自己编织成网。</span>
              </h1>
              <p className="home-hero__sub">
                随手记录原始念头，像便签一样留在「今天」。每天午夜自动编译成结构化的日记页，
                昨天与更早的，都会沉淀为可回溯的 wiki。
              </p>
            </>
          ) : (
            <>
              <h1 className="home-hero__title home-hero__title--calm">
                今天还在 <span className="accent">收集念头</span>
                <span className="home-hero__title-tail">。夜里 00 点交给系统编织。</span>
              </h1>
              {dailyPages.length > 0 && (
                <p className="home-hero__sub home-hero__sub--quiet">
                  <Link href={`/wiki/${dailyPages[0]!.slug}`} className="home-hero__yesterday">
                    昨天已编织好 <ArrowUpRight size={12} strokeWidth={2} aria-hidden="true" />
                  </Link>
                </p>
              )}
            </>
          )}
        </div>

        {/* Daily compile card */}
        <section className="daily-compile-card" aria-label="今日编译状态">
          <div className="daily-compile-card__head">
            <span className="daily-compile-card__label">今日</span>
            <span className="daily-compile-card__date">{iso}</span>
          </div>

          {/* Three-beat narrative: 念头 → 已织入网中 → 等夜里 / 已就绪.
              The third beat flips to "已就绪" when the day is fully compiled,
              giving users a felt sense of state progression instead of static
              counts that always sum to the first. */}
          <div className="daily-compile-card__metrics">
            <div className="dcc-metric">
              <div className="dcc-metric__value">{todayCount}</div>
              <div className="dcc-metric__label">此刻的念头</div>
            </div>
            <div className="dcc-metric">
              <div className="dcc-metric__value">{compiledCount}</div>
              <div className="dcc-metric__label">已织入网中</div>
            </div>
            <div className="dcc-metric">
              {pendingCount === 0 && todayCount > 0 ? (
                <>
                  <div className="dcc-metric__value dcc-metric__value--ready" aria-label="已就绪">
                    <span className="dcc-ready-dot" aria-hidden="true" />
                  </div>
                  <div className="dcc-metric__label">已就绪</div>
                </>
              ) : (
                <>
                  <div className="dcc-metric__value">{pendingCount}</div>
                  <div className="dcc-metric__label">等夜里</div>
                </>
              )}
            </div>
          </div>

          {/* Compile button is restrained: only surfaces once enough material
              has accumulated. Below the threshold we keep the midnight ritual
              the only path — quietness reinforces the slogan's promise. */}
          {showCompileButton && (
            <button
              type="button"
              className={`dcc-compile-btn${pendingCount === 0 && !compiling ? " dcc-compile-btn--ghost" : ""}`}
              onClick={handleCompileToday}
              disabled={compiling}
              aria-busy={compiling}
            >
              {compiling ? (
                <>
                  <Loader2 size={14} strokeWidth={2} style={SPIN} aria-hidden="true" />
                  正在送编译…
                </>
              ) : (
                <>
                  <Sparkles size={14} strokeWidth={2} aria-hidden="true" />
                  提前看看今天会织成什么
                </>
              )}
            </button>
          )}

          {/* Visual-only: the dedicated .sr-only live region already announces
              compile outcomes to AT, so this avoids a duplicate read. */}
          <p className="dcc-foot">
            {compileNote ? (
              <span className="dcc-foot__note">{compileNote}</span>
            ) : (
              <>
                <Clock size={11} strokeWidth={2} aria-hidden="true" />
                每天 00:00 自动编织昨天
              </>
            )}
          </p>
        </section>
      </div>

      {/* Midnight-crossing toast: a one-off product beat when the tab stays
          open across 00:00 — turns a potential glitch into a small moment. */}
      {midnightToast && (
        <div className="home-midnight-toast" role="status">
          <Sparkles size={13} strokeWidth={2} aria-hidden="true" />
          {midnightToast}
        </div>
      )}

      {/* Pipeline-unreachable banner (dev w/o Inngest, or outage). */}
      {!serviceConnected && (
        <div className="home-pipeline-warn" role="status">
          <AlertCircle size={14} strokeWidth={2} aria-hidden="true" />
          编译服务未连接 —— 新记录会保存，但暂不会被编译。
        </div>
      )}

      {/* ── Composer ────────────────────────────────────────────────────── */}
      <section className="home-composer" aria-label="记录此刻">
        <textarea
          ref={taRef}
          id="home-composer-input"
          value={draft}
          onChange={(e) => {
            setDraft(e.target.value);
            if (saveError) setSaveError(null);
            if (saveOk) {
              setSaveOk(false);
              if (saveOkTimer.current) clearTimeout(saveOkTimer.current);
            }
          }}
          onKeyDown={handleComposerKey}
          placeholder="此刻在想什么？"
          rows={2}
          className="home-composer__ta"
          aria-label="记下此刻的念头"
          aria-describedby="home-composer-hint"
          aria-keyshortcuts="Meta+Enter Control+Enter"
        />
        <div className="home-composer__bar">
          <span
            id="home-composer-hint"
            className={`home-composer__hint${saveError ? " is-error" : ""}`}
          >
            {saveError
              ? saveError
              : saveOk
                ? "收下了，夜里见 ✓"
                : wordCount > 0
                  ? `${wordCount} 字 · ⌘/Ctrl + ↵ 收下`
                  : "记下此刻，余下交给夜里"}
          </span>
          <button
            type="button"
            className="home-composer__save"
            disabled={!canSave}
            aria-busy={saving}
            onClick={handleSave}
          >
            {saving ? (
              <Loader2 size={13} strokeWidth={2.2} style={SPIN} aria-hidden="true" />
            ) : (
              <Check size={13} strokeWidth={2.2} aria-hidden="true" />
            )}
            收下
          </button>
        </div>
      </section>

      {/* ── Today's raw (flomo cards) ───────────────────────────────────── */}
      <section className="home-section" aria-label="今天的记录">
        <h2 className="home-section__label">
          <span>今天</span>
          <span className="home-section__count">{memos.length}</span>
        </h2>

        {memos.length === 0 ? (
          <div className="home-empty">
            <Sparkles size={26} strokeWidth={1.5} aria-hidden="true" />
            <p>今天还没有记录 —— 在上面写下第一条吧。</p>
          </div>
        ) : (
          <div className="home-memo-grid">
            {memos.map((m) => (
              <MemoCard
                key={m.id}
                memo={m}
                serviceConnected={serviceConnected}
                onRetry={handleRetry}
              />
            ))}
          </div>
        )}
      </section>

      {/* ── Yesterday & earlier (compiled daily wiki) ───────────────────── */}
      <section className="home-section" aria-label="昨天及更早的日记页">
        <h2 className="home-section__label">
          <span>昨天及更早</span>
          {dailyPages.length > 0 && (
            <Link href="/wiki?type=daily" className="home-section__more">
              全部 <ArrowUpRight size={13} strokeWidth={2} aria-hidden="true" />
            </Link>
          )}
        </h2>

        {dailyPages.length === 0 ? (
          <div className="home-empty">
            <FileText size={26} strokeWidth={1.5} aria-hidden="true" />
            <p>还没有编译过的日记页 —— 记录满一天，午夜会自动生成。</p>
          </div>
        ) : (
          /* Each daily page becomes a "small book": title + one whole
             opening line, with a thin spine of N short rules along the
             bottom edge (visual stand-in for "N raw memos went into this").
             Date sits as a quiet corner stamp; full excerpt only emerges
             on hover, so the grid reads like a shelf, not a list. */
          <div className="home-wiki-grid home-wiki-grid--books">
            {dailyPages.map((p) => {
              // Cap the spine at 9 lines so a 50-memo day doesn't become a
              // solid bar; a 9-line spine still reads as "thicker than usual".
              const spineCount = Math.max(0, Math.min(9, p.source_count));
              const pull = firstSentence(p.excerpt);
              // Hover excerpt should reveal *more* than the resting pull line.
              // If excerpt starts with the same first sentence we already show
              // in `pull`, strip it so hover doesn't read as a duplicate.
              const hoverExcerpt = pull && p.excerpt.startsWith(pull)
                ? p.excerpt.slice(pull.length).trim()
                : p.excerpt;
              return (
                <Link
                  key={p.slug}
                  href={`/wiki/${p.slug}`}
                  className="wiki-book"
                  aria-label={`${p.date} ${relativeDayLabel(p.date)} 的日记页：${p.title}（${p.source_count} 条原始）`}
                >
                  <span className="wiki-book__stamp" aria-hidden="true">{p.date}</span>
                  <span className="wiki-book__rel" aria-hidden="true">{relativeDayLabel(p.date)}</span>
                  <h3 className="wiki-book__title">{p.title}</h3>
                  {pull && <p className="wiki-book__pull">{pull}</p>}
                  {hoverExcerpt && <p className="wiki-book__excerpt">{hoverExcerpt}</p>}
                  <div
                    className="wiki-book__spine"
                    aria-hidden="true"
                    title={`${p.source_count} 条原始`}
                  >
                    {Array.from({ length: spineCount }).map((_, i) => (
                      <span key={i} className="wiki-book__spine-line" />
                    ))}
                  </div>
                </Link>
              );
            })}
          </div>
        )}
      </section>
    </div>
  );
}
