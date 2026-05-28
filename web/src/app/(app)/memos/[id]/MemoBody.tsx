"use client";

import Link from "next/link";
import type { ReactNode } from "react";

interface MemoBodyProps {
  body: string;
}

const URL_RE = /https?:\/\/[^\s<>"']+/g;
const HASHTAG_RE = /(?:^|(?<=\s))(#[^\s#]+)/g;
const MENTION_RE = /(?:^|(?<=\s))(@[^\s@]+)/g;

function stripDangerousProtocol(url: string): string | null {
  try {
    const u = new URL(url);
    return u.protocol === "http:" || u.protocol === "https:" ? url : null;
  } catch {
    return null;
  }
}

type Segment =
  | { kind: "text"; value: string }
  | { kind: "url"; value: string }
  | { kind: "hashtag"; value: string }
  | { kind: "mention"; value: string };

function parseSegments(text: string): Segment[] {
  // Build a combined split by finding all matches across the text
  const matches: Array<{ start: number; end: number; kind: "url" | "hashtag" | "mention"; value: string }> = [];

  let m: RegExpExecArray | null;

  URL_RE.lastIndex = 0;
  while ((m = URL_RE.exec(text)) !== null) {
    matches.push({ start: m.index, end: m.index + m[0].length, kind: "url", value: m[0] });
  }

  HASHTAG_RE.lastIndex = 0;
  while ((m = HASHTAG_RE.exec(text)) !== null) {
    // m[1] is the hashtag token; compute actual start
    const tokenStart = m.index + m[0].indexOf(m[1]);
    matches.push({ start: tokenStart, end: tokenStart + m[1].length, kind: "hashtag", value: m[1] });
  }

  MENTION_RE.lastIndex = 0;
  while ((m = MENTION_RE.exec(text)) !== null) {
    const tokenStart = m.index + m[0].indexOf(m[1]);
    matches.push({ start: tokenStart, end: tokenStart + m[1].length, kind: "mention", value: m[1] });
  }

  // Sort by start, resolve overlaps (first wins)
  matches.sort((a, b) => a.start - b.start);
  const resolved: typeof matches = [];
  let cursor = 0;
  for (const match of matches) {
    if (match.start >= cursor) {
      resolved.push(match);
      cursor = match.end;
    }
  }

  const segments: Segment[] = [];
  let pos = 0;
  for (const match of resolved) {
    if (match.start > pos) {
      segments.push({ kind: "text", value: text.slice(pos, match.start) });
    }
    segments.push({ kind: match.kind, value: match.value });
    pos = match.end;
  }
  if (pos < text.length) {
    segments.push({ kind: "text", value: text.slice(pos) });
  }
  return segments;
}

const inlineStyle: React.CSSProperties = {
  color: "var(--accent)",
  textDecoration: "none",
  fontWeight: 500,
};

function RichLine({ line }: { line: string }) {
  const segments = parseSegments(line);
  return (
    <>
      {segments.map((seg, i): ReactNode => {
        if (seg.kind === "url") {
          const safe = stripDangerousProtocol(seg.value);
          if (!safe) return <span key={i}>{seg.value}</span>;
          return (
            <a key={i} href={safe} className="memo-link" target="_blank" rel="noopener noreferrer" style={inlineStyle}>
              {seg.value}
            </a>
          );
        }
        if (seg.kind === "hashtag") {
          const tag = seg.value.slice(1);
          return (
            <Link key={i} href={`/wiki/tag/${encodeURIComponent(tag)}`} style={{ ...inlineStyle, textDecoration: "none" }}>
              {seg.value}
            </Link>
          );
        }
        if (seg.kind === "mention") {
          const name = seg.value.slice(1);
          return (
            <Link key={i} href={`/wiki/${encodeURIComponent(name)}`} style={{ ...inlineStyle, textDecoration: "none" }}>
              {seg.value}
            </Link>
          );
        }
        return <span key={i}>{seg.value}</span>;
      })}
    </>
  );
}

export function MemoBody({ body }: MemoBodyProps) {
  if (!body) {
    return (
      <div style={{ padding: "0 24px 30px" }}>
        <span style={{ color: "var(--fg-subtle)", fontStyle: "italic" }}>No content</span>
      </div>
    );
  }

  const lines = body.split("\n");

  return (
    <div
      style={{
        padding: "0 24px 30px",
        fontSize: "16.5px",
        lineHeight: 1.72,
        letterSpacing: "0.1px",
        textWrap: "pretty" as React.CSSProperties["textWrap"],
        whiteSpace: "pre-line",
        color: "var(--fg-primary)",
        wordBreak: "break-word",
      }}
    >
      {lines.map((line, i) => (
        <span key={i}>
          <RichLine line={line} />
          {i < lines.length - 1 && "\n"}
        </span>
      ))}
    </div>
  );
}
