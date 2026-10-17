// remark plugin: link conventional hashtags and existing mention tokens in
// rich text.
//
//   #会议/周报  -> /memos?q=%23会议%2F周报   (text search on the history page)
//   @alice     -> /wiki/alice               (existing mention links, kept)
//
// Rules (this batch does NOT claim exact flomo taxonomy — unused/catalog
// punctuation tags belong to the parent's later account-catalog contract):
//   - a tag starts at a word boundary and its body is letters/digits (any
//     script, including CJK) plus `_ - /`, so multi-level paths work;
//   - trailing separators are not part of the tag, and trailing Chinese or
//     ASCII punctuation is never absorbed (`#标签，` tags `#标签`);
//   - text inside link/definition/code nodes is NEVER rewritten (no nested
//     links, code and link destinations stay untouched).

interface MdastNode {
  type: string;
  value?: string;
  url?: string;
  children?: MdastNode[];
}

const TAG_BODY_RE = /[\p{L}\p{N}_\-/]/u;
const TAG_FIRST_RE = /[\p{L}\p{N}_]/u;
const BOUNDARY_RE = /[\p{L}\p{N}_#]/u;

interface TagMatch {
  start: number;
  end: number;
  kind: "hashtag" | "mention";
  tag: string;
}

function scan(text: string): TagMatch[] {
  const matches: TagMatch[] = [];
  for (let i = 0; i < text.length; i += 1) {
    const marker = text[i];
    if (marker !== "#" && marker !== "@") continue;
    if (i > 0 && BOUNDARY_RE.test(text[i - 1])) continue;

    const kind = marker === "#" ? "hashtag" : "mention";
    const first = text[i + 1];
    if (first === undefined || !TAG_FIRST_RE.test(first)) continue;

    let end = i + 2;
    while (end < text.length && TAG_BODY_RE.test(text[end])) end += 1;

    let tag = text.slice(i + 1, end);
    // Separators are meaningful inside a multi-level path but never trailing.
    const trimmed = tag.replace(/[/-]+$/u, "");
    if (trimmed.length === 0) continue;
    tag = trimmed;
    end = i + 1 + tag.length;
    matches.push({ start: i, end, kind, tag });
    i = end - 1;
  }
  return matches;
}

function hashtagHref(tag: string): string {
  return `/memos?q=${encodeURIComponent(`#${tag}`)}`;
}

function mentionHref(tag: string): string {
  return `/wiki/${encodeURIComponent(tag)}`;
}

function rewriteTextNode(node: MdastNode): MdastNode[] {
  const text = node.value ?? "";
  const matches = scan(text);
  if (matches.length === 0) return [node];

  const out: MdastNode[] = [];
  let pos = 0;
  for (const match of matches) {
    if (match.start > pos) {
      out.push({ type: "text", value: text.slice(pos, match.start) });
    }
    const raw = text.slice(match.start, match.end);
    out.push({
      type: "link",
      url: match.kind === "hashtag" ? hashtagHref(match.tag) : mentionHref(match.tag),
      children: [{ type: "text", value: raw }],
    });
    pos = match.end;
  }
  if (pos < text.length) out.push({ type: "text", value: text.slice(pos) });
  return out;
}

const LINK_TYPES = new Set(["link", "linkReference", "definition"]);

function walk(node: MdastNode): void {
  if (!node.children || LINK_TYPES.has(node.type)) return;
  const next: MdastNode[] = [];
  for (const child of node.children) {
    if (child.type === "text" && !LINK_TYPES.has(node.type)) {
      next.push(...rewriteTextNode(child));
    } else {
      walk(child);
      next.push(child);
    }
  }
  node.children = next;
}

/** remark plugin factory (no unified/remark imports needed). */
export function remarkMemoTags(): (tree: MdastNode) => void {
  return (tree: MdastNode) => {
    walk(tree);
  };
}
