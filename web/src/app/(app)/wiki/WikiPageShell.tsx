"use client";

import { useState } from "react";

type Tab = "nav" | "page";

export function WikiPageShell({
  nav,
  main,
}: {
  nav: React.ReactNode;
  main: React.ReactNode;
}) {
  const [tab, setTab] = useState<Tab>("page");

  return (
    <>
      <div className="mobile-tab-bar" aria-label="Wiki sections">
        <button
          className={`mobile-tab-bar__btn${tab === "nav" ? " is-active" : ""}`}
          onClick={() => setTab("nav")}
        >
          Pages
        </button>
        <button
          className={`mobile-tab-bar__btn${tab === "page" ? " is-active" : ""}`}
          onClick={() => setTab("page")}
        >
          Content
        </button>
      </div>
      <div className={`wiki wiki--show-${tab === "nav" ? "nav" : "page"}`}>
        <aside className="wiki__nav">{nav}</aside>
        <main className="wiki__page">{main}</main>
      </div>
    </>
  );
}
