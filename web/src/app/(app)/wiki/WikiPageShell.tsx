import type { ReactNode } from "react";
import "./wiki-reading.css";

export function WikiPageShell({
  nav,
  main,
}: {
  nav: ReactNode;
  main: ReactNode;
}) {
  return (
    <div className="wiki-reader">
      <details className="wiki-page-browser">
        <summary>Browse pages</summary>
        <nav className="wiki__nav" aria-label="Knowledge pages">{nav}</nav>
      </details>
      <div className="wiki__page">{main}</div>
    </div>
  );
}
