"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import type { SessionUser } from "@/lib/auth/session";
import { signOutAction } from "./actions";

type Props = {
  user: SessionUser;
  lang?: "en" | "zh";
};

function initialsFor(user: SessionUser): string {
  if (user.name) {
    return user.name
      .trim()
      .split(/\s+/)
      .slice(0, 2)
      .map((w) => w[0]?.toUpperCase() ?? "")
      .join("");
  }
  if (user.email) return user.email[0]?.toUpperCase() ?? "?";
  return "?";
}

// Deterministic warm gradient from the user id so the avatar feels personal
// without storing prefs. Hue stays in the amber band to match the brand.
function gradientFor(id: string): string {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) | 0;
  const hue = Math.abs(h) % 60;
  const c1 = `hsl(${hue + 20}, 62%, 38%)`;
  const c2 = `hsl(${hue + 5}, 70%, 24%)`;
  return `linear-gradient(135deg, ${c1} 0%, ${c2} 100%)`;
}

export function UserMenu({ user, lang = "en" }: Props) {
  const [open, setOpen] = useState(false);
  const wrap = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function onClick(e: MouseEvent) {
      if (!wrap.current?.contains(e.target as Node)) setOpen(false);
    }
    function onEsc(e: KeyboardEvent) {
      if (e.key === "Escape") setOpen(false);
    }
    document.addEventListener("mousedown", onClick);
    document.addEventListener("keydown", onEsc);
    return () => {
      document.removeEventListener("mousedown", onClick);
      document.removeEventListener("keydown", onEsc);
    };
  }, []);

  const T =
    lang === "zh"
      ? { open: "打开", settings: "设置", signOut: "退出登录", label: "用户菜单" }
      : { open: "Today", settings: "Settings", signOut: "Sign out", label: "User menu" };

  return (
    <div ref={wrap} className="relative">
      <button
        type="button"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label={T.label}
        onClick={() => setOpen((o) => !o)}
        className="group inline-flex h-9 w-9 items-center justify-center rounded-full text-[12px] font-semibold uppercase text-[color:var(--bg-warm)] shadow-[0_4px_12px_-4px_rgba(93,48,0,0.35)] ring-2 ring-transparent transition-all duration-200 hover:scale-[1.05] hover:ring-[color:var(--accent-soft)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color:var(--accent)] aria-[expanded=true]:scale-[1.05] aria-[expanded=true]:ring-[color:var(--accent-soft)]"
        style={{
          background: gradientFor(user.id),
          fontFamily: "var(--font-inter), sans-serif",
        }}
      >
        {initialsFor(user)}
      </button>

      <div
        role="menu"
        data-open={open}
        className="invisible absolute right-0 top-12 w-64 origin-top-right scale-95 rounded-2xl border border-[color:var(--border-subtle)] bg-[color:var(--surface-white)] p-2 opacity-0 shadow-[0_24px_60px_-20px_rgba(60,40,15,0.32)] backdrop-blur-xl transition-[opacity,transform,visibility] duration-200 data-[open=true]:visible data-[open=true]:scale-100 data-[open=true]:opacity-100"
      >
        <div className="flex items-center gap-3 rounded-xl px-3 py-2.5">
          <span
            aria-hidden
            className="inline-flex h-9 w-9 items-center justify-center rounded-full text-[12px] font-semibold uppercase text-[color:var(--bg-warm)]"
            style={{ background: gradientFor(user.id) }}
          >
            {initialsFor(user)}
          </span>
          <div className="min-w-0 flex-1">
            <p className="truncate text-[13px] font-medium text-[color:var(--fg-primary)]">
              {user.name ?? user.email?.split("@")[0] ?? "Signed in"}
            </p>
            {user.email && (
              <p className="truncate text-[11px] text-[color:var(--fg-subtle-aa)]">
                {user.email}
              </p>
            )}
          </div>
        </div>

        <div className="my-1 h-px bg-[color:var(--border-subtle)]" />

        <Link
          href="/today"
          role="menuitem"
          onClick={() => setOpen(false)}
          className="flex items-center justify-between rounded-xl px-3 py-2 text-[13px] text-[color:var(--fg-primary)] transition-colors hover:bg-[color:var(--surface-sunken)]"
        >
          <span>{T.open}</span>
          <span className="text-[color:var(--fg-subtle-aa)]">↗</span>
        </Link>
        <Link
          href="/settings"
          role="menuitem"
          onClick={() => setOpen(false)}
          className="flex items-center justify-between rounded-xl px-3 py-2 text-[13px] text-[color:var(--fg-primary)] transition-colors hover:bg-[color:var(--surface-sunken)]"
        >
          <span>{T.settings}</span>
          <span className="text-[color:var(--fg-subtle-aa)]">↗</span>
        </Link>

        <div className="my-1 h-px bg-[color:var(--border-subtle)]" />

        <form action={signOutAction}>
          <button
            type="submit"
            role="menuitem"
            className="flex w-full items-center justify-between rounded-xl px-3 py-2 text-left text-[13px] text-[color:var(--fg-muted)] transition-colors hover:bg-[color:var(--surface-sunken)] hover:text-[color:var(--fg-primary)]"
          >
            <span>{T.signOut}</span>
          </button>
        </form>
      </div>
    </div>
  );
}
