"use client";

import { useEffect, useState } from "react";

export function TopbarDate() {
  const [s, setS] = useState("");

  useEffect(() => {
    const update = () => {
      const d = new Date();
      const wk = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"][d.getDay()];
      const mo = [
        "JAN", "FEB", "MAR", "APR", "MAY", "JUN",
        "JUL", "AUG", "SEP", "OCT", "NOV", "DEC",
      ][d.getMonth()];
      const hh = String(d.getHours()).padStart(2, "0");
      const mm = String(d.getMinutes()).padStart(2, "0");
      setS(`${wk} · ${d.getDate()} ${mo} ${d.getFullYear()} · ${hh}:${mm}`);
    };
    update();
    const t = setInterval(update, 60_000);
    return () => clearInterval(t);
  }, []);

  return (
    <span className="ds-mono-11" style={{ color: "var(--fg-muted)" }}>
      {s}
    </span>
  );
}
