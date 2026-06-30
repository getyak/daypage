"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

type Props = { lang?: "en" | "zh" };

/**
 * Two-way EN/中 toggle. Strips/prepends the /zh prefix on the current path
 * and persists the choice as a cookie so middleware can honor it next visit.
 */
export function LangSwitcher({ lang = "en" }: Props) {
  const pathname = usePathname() || "/";
  const target =
    lang === "zh"
      ? pathname.replace(/^\/zh(?=\/|$)/, "") || "/"
      : pathname === "/"
        ? "/zh"
        : `/zh${pathname}`;
  const nextLang: "en" | "zh" = lang === "zh" ? "en" : "zh";

  function persist() {
    document.cookie = `daypage-lang=${nextLang}; path=/; max-age=31536000; samesite=lax`;
  }

  return (
    <Link
      href={target}
      hrefLang={nextLang}
      prefetch={false}
      onClick={persist}
      aria-label={lang === "zh" ? "Switch to English" : "切换到中文"}
      className="group inline-flex h-8 items-center gap-1 rounded-full border border-[color:var(--border-subtle)] bg-[color:var(--surface-white)]/70 px-3 text-[12px] font-medium text-[color:var(--fg-muted)] backdrop-blur transition-all duration-200 hover:border-[color:var(--border-default)] hover:text-[color:var(--fg-primary)]"
    >
      <span
        className={`transition-opacity ${lang === "en" ? "text-[color:var(--fg-primary)]" : "opacity-60"}`}
      >
        EN
      </span>
      <span aria-hidden className="opacity-30">/</span>
      <span
        className={`transition-opacity ${lang === "zh" ? "text-[color:var(--fg-primary)]" : "opacity-60"}`}
      >
        中
      </span>
    </Link>
  );
}
