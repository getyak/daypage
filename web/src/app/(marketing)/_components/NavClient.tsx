"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import type { SessionUser } from "@/lib/auth/session";
import { UserMenu } from "./UserMenu";
import { LangSwitcher } from "./LangSwitcher";

const NAV_LINKS = [
  { href: "#platforms", label: "Platforms" },
  { href: "#capture", label: "Product" },
  { href: "/manifesto", label: "Manifesto" },
  { href: "/changelog", label: "Changelog" },
];

type Props = {
  user: SessionUser | null;
  lang?: "en" | "zh";
};

export function NavClient({ user, lang = "en" }: Props) {
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 24);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  const T =
    lang === "zh"
      ? { signIn: "登录", getDayPage: "下载", openApp: "打开 DayPage" }
      : { signIn: "Sign in", getDayPage: "Get DayPage", openApp: "Open DayPage" };

  return (
    <header
      data-scrolled={scrolled}
      className="fixed inset-x-0 top-0 z-50 transition-[background-color,backdrop-filter,border-color] duration-300 data-[scrolled=true]:border-b data-[scrolled=true]:border-[color:var(--border-subtle)] data-[scrolled=true]:bg-[color:var(--bg-warm)]/72 data-[scrolled=true]:backdrop-blur-xl"
    >
      <nav className="mx-auto flex h-16 max-w-[1440px] items-center justify-between px-6 lg:px-10">
        <Link
          href={lang === "zh" ? "/zh" : "/"}
          className="group inline-flex items-center gap-2.5"
          aria-label="DayPage home"
        >
          <span
            aria-hidden
            className="inline-flex h-7 w-7 items-center justify-center rounded-lg bg-[color:var(--accent)] text-[13px] font-bold text-[color:var(--bg-warm)] transition-transform duration-300 group-hover:scale-110"
            style={{ fontFamily: "var(--font-fraunces), serif" }}
          >
            D
          </span>
          <span className="font-serif text-[20px] tracking-[-0.01em] text-[color:var(--fg-primary)]">
            DayPage
          </span>
        </Link>

        <ul className="hidden items-center gap-7 md:flex">
          {NAV_LINKS.map((link) => (
            <li key={link.href}>
              <Link
                href={link.href}
                className="text-[14px] font-medium text-[color:var(--fg-muted)] transition-colors hover:text-[color:var(--fg-primary)]"
              >
                {link.label}
              </Link>
            </li>
          ))}
        </ul>

        <div className="flex items-center gap-2 md:gap-3">
          <LangSwitcher lang={lang} />
          {user ? (
            <>
              <Link
                href="/today"
                className="cta-magnetic hidden h-9 items-center rounded-full bg-[color:var(--accent)] px-4 text-[13px] font-medium text-[color:var(--bg-warm)] hover:bg-[color:var(--accent-hover)] md:inline-flex"
              >
                {T.openApp}
              </Link>
              <UserMenu user={user} lang={lang} />
            </>
          ) : (
            <>
              <Link
                href="/login"
                className="hidden text-[14px] font-medium text-[color:var(--fg-muted)] transition-colors hover:text-[color:var(--fg-primary)] md:inline"
              >
                {T.signIn}
              </Link>
              <Link
                href="/download"
                className="cta-magnetic inline-flex h-9 items-center rounded-full bg-[color:var(--accent)] px-4 text-[13px] font-medium text-[color:var(--bg-warm)] hover:bg-[color:var(--accent-hover)]"
              >
                {T.getDayPage}
              </Link>
            </>
          )}
        </div>
      </nav>
    </header>
  );
}
