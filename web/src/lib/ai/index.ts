// ─── Unified LLM façade ──────────────────────────────────────────────────────
// Server-only — all capabilities currently route to OpenAI.
//   chat / chatStream → OpenAI (gpt-4o-mini by default, override via OPENAI_MODEL)
//   embed             → OpenAI text-embedding-3-small (1536-dim)
//   transcribe        → OpenAI whisper-1
// Callers should `import { llm } from "@/lib/ai"` and never touch backends
// directly. DeepSeek is kept in-tree (deepseek.ts) but unused; re-route here
// to switch back.

import "server-only";
import { LLMProvider } from "./provider";
import { openai } from "./openai";

export const llm: LLMProvider = openai;

// Re-export types for convenience.
export type {
  LLMProvider,
  ChatMessage,
  ChatResponse,
  EmbedResponse,
  TranscribeResponse,
} from "./provider";
export { ProviderError } from "./provider";
