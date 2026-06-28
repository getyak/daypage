"use client";

import Link from "next/link";
import { useEffect, useState } from "react";

const NAV_LINKS = [
  { href: "#capture", label: "Product" },
  { href: "#features", label: "Features" },
  { href: "/manifesto", label: "Manifesto" },
  { href: "/changelog", label: "Changelog" },
];

export function Nav() {
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 24);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <header
      data-scrolled={scrolled}
      className="fixed inset-x-0 top-0 z-50 transition-[background-color,backdrop-filter,border-color] duration-300 data-[scrolled=true]:border-b data-[scrolled=true]:border-[color:var(--border-subtle)] data-[scrolled=true]:bg-[color:var(--bg-warm)]/72 data-[scrolled=true]:backdrop-blur-xl"
    >
      <nav className="mx-auto flex h-16 max-w-[1280px] items-center justify-between px-6 lg:px-10">
        <Link
          href="/"
          className="font-serif text-[20px] tracking-[-0.01em] text-[color:var(--fg-primary)]"
        >
          DayPage
        </Link>

        <ul className="hidden items-center gap-8 md:flex">
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

        <div className="flex items-center gap-3">
          <Link
            href="/home"
            className="hidden text-[14px] font-medium text-[color:var(--fg-muted)] transition-colors hover:text-[color:var(--fg-primary)] md:inline"
          >
            Sign in
          </Link>
          <Link
            href="/download"
            className="inline-flex h-9 items-center rounded-full bg-[color:var(--accent)] px-4 text-[13px] font-medium text-[color:var(--bg-warm)] transition-[background-color,transform] duration-200 hover:bg-[color:var(--accent-hover)] active:scale-[0.98]"
          >
            Get DayPage
          </Link>
        </div>
      </nav>
    </header>
  );
}
