// Utilities for chunking text and averaging embeddings for the compile pipeline.
// Server-only — called from Inngest functions.

import "server-only";
import { createHash } from "crypto";

const APPROX_CHARS_PER_TOKEN = 4;
const MAX_TOKENS = 512;
const MAX_CHARS = MAX_TOKENS * APPROX_CHARS_PER_TOKEN;

/** Split text into chunks of ≤512 tokens (approximated by char count). */
export function chunkText(text: string): string[] {
  if (text.length <= MAX_CHARS) return [text];
  const chunks: string[] = [];
  let start = 0;
  while (start < text.length) {
    let end = start + MAX_CHARS;
    if (end < text.length) {
      // Break at word boundary
      const spaceIdx = text.lastIndexOf(" ", end);
      if (spaceIdx > start) end = spaceIdx;
    }
    chunks.push(text.slice(start, end).trim());
    start = end;
  }
  return chunks.filter((c) => c.length > 0);
}

/** Average multiple embedding vectors into one. */
export function averageEmbeddings(vecs: number[][]): number[] {
  if (vecs.length === 0) return [];
  if (vecs.length === 1) return vecs[0];
  const len = vecs[0].length;
  const result = new Array<number>(len).fill(0);
  for (const vec of vecs) {
    for (let i = 0; i < len; i++) {
      result[i] += vec[i];
    }
  }
  for (let i = 0; i < len; i++) {
    result[i] /= vecs.length;
  }
  return result;
}

/** SHA-256 hash of text for cache keying. */
export function hashText(text: string): string {
  return createHash("sha256").update(text).digest("hex");
}
