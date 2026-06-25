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
function useTodayStrings(): TodayStrings {
  const [today, setToday] = useState<TodayStrings>(computeToday);
  useEffect(() => {
    const t = setInterval(() => {
      setToday((prev) => {
        const next = computeToday();
        return next.iso === prev.iso ? prev : next;
      });
    }, 60_000);
    return () => clearInterval(t);
  }, []);
  return today;
}

// Friendly relative label for a daily wiki card: 昨天 / 前天 / N 天前 / date.
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
  return that.toLocaleDateString("zh-CN", { month: "long", day: "numeric" });
}

// ─── Component ───────────────────────────────────────────────────────────────

export function HomeStream({ initialToday, dailyPages }: HomeStreamProps) {
  const { weekday, long, iso } = useTodayStrings();

  const [memos, setMemos] = useState<MemoCardData[]>(initialToday);
  const [serviceConnected, setServiceConnected] = useState(true);

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
        announce("已保存到今天");
        if (saveOkTimer.current) clearTimeout(saveOkTimer.current);
        saveOkTimer.current = setTimeout(() => setSaveOk(false), 1800);
        await reloadMemos();
      } else {
        const d = await r.json().catch(() => null);
        const msg = d?.error ? String(d.error) : "保存失败，已为你保留草稿";
        setSaveError(msg);
        announce(msg);
      }
    } catch {
      // Network error — the textarea keeps the draft so nothing is lost.
      setSaveError("网络错误，已为你保留草稿，可重试");
      announce("保存失败，网络错误");
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
          <h1 className="home-hero__title">
            今天，先把此刻记下来。
            <br />
            <span className="accent">夜里 00 点，它会自己编织成网。</span>
          </h1>
          <p className="home-hero__sub">
            随手记录原始念头，像便签一样留在「今天」。每天午夜自动编译成结构化的日记页，
            昨天与更早的，都会沉淀为可回溯的 wiki。
          </p>
        </div>

        {/* Daily compile card */}
        <section className="daily-compile-card" aria-label="今日编译">
          <div className="daily-compile-card__head">
            <span className="daily-compile-card__label">今日编译</span>
            <span className="daily-compile-card__date">{iso}</span>
          </div>

          <div className="daily-compile-card__metrics">
            <div className="dcc-metric">
              <div className="dcc-metric__value">{memos.length}</div>
              <div className="dcc-metric__label">今日记录</div>
            </div>
            <div className="dcc-metric">
              <div className="dcc-metric__value">{compiledCount}</div>
              <div className="dcc-metric__label">已编译</div>
            </div>
            <div className="dcc-metric">
              <div className="dcc-metric__value">{pendingCount}</div>
              <div className="dcc-metric__label">待编译</div>
            </div>
          </div>

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
                立即编译今天
              </>
            )}
          </button>

          {/* Visual-only: the dedicated .sr-only live region already announces
              compile outcomes to AT, so this avoids a duplicate read. */}
          <p className="dcc-foot">
            {compileNote ? (
              <span className="dcc-foot__note">{compileNote}</span>
            ) : (
              <>
                <Clock size={11} strokeWidth={2} aria-hidden="true" />
                每天 00:00 自动编译昨天
              </>
            )}
          </p>
        </section>
      </div>

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
                ? "已保存 ✓"
                : wordCount > 0
                  ? `${wordCount} 字 · ⌘/Ctrl + ↵ 保存`
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
            保存
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
          <div className="home-wiki-grid">
            {dailyPages.map((p) => (
              <Link
                key={p.slug}
                href={`/wiki/${p.slug}`}
                className="wiki-day-card"
                aria-label={`${relativeDayLabel(p.date)}的日记页：${p.title}`}
              >
                <div className="wiki-day-card__head">
                  <span className="wiki-day-card__rel">{relativeDayLabel(p.date)}</span>
                  <span className="wiki-day-card__date">{p.date}</span>
                </div>
                <h3 className="wiki-day-card__title">{p.title}</h3>
                <p className="wiki-day-card__excerpt">{p.excerpt}</p>
                <div className="wiki-day-card__foot">
                  <span>
                    <FileText size={11} strokeWidth={2} aria-hidden="true" /> {p.source_count} 条原始
                  </span>
                  <ArrowUpRight size={14} strokeWidth={2} aria-hidden="true" />
                </div>
              </Link>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}
