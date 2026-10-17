// Safe Markdown rendering for memo bodies (original text at storage is never
// rewritten). react-markdown + remark-gfm parse the original Markdown;
// rehype-sanitize strips raw HTML and dangerous URL protocols; the
// remarkMemoTags plugin adds hashtag/mention links outside code/link nodes.
// Remote <img> embeds are not rendered: memo media is served as attachments
// through the authenticated same-origin route.

import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import rehypeSanitize, { defaultSchema } from "rehype-sanitize";
import { remarkMemoTags } from "./remark-hashtags";
import type { ReactNode } from "react";

const sanitizeSchema = {
  ...defaultSchema,
  tagNames: (defaultSchema.tagNames ?? []).filter((tag) => tag !== "img"),
};

function isExternalHref(href: string): boolean {
  return /^https?:\/\//i.test(href);
}

function MemoLink({ href, children }: { href?: string; children?: ReactNode }) {
  if (!href) return <span>{children}</span>;
  if (isExternalHref(href)) {
    return (
      <a href={href} target="_blank" rel="noopener noreferrer" className="memo-link">
        {children}
      </a>
    );
  }
  return (
    <a href={href} className="memo-link">
      {children}
    </a>
  );
}

export function MemoMarkdown({ body }: { body: string }) {
  return (
    <ReactMarkdown
      remarkPlugins={[remarkGfm, remarkMemoTags]}
      rehypePlugins={[[rehypeSanitize, sanitizeSchema]]}
      components={{ a: MemoLink }}
    >
      {body}
    </ReactMarkdown>
  );
}
