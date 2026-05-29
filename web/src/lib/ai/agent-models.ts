// ─── US-031: selectable agent models ─────────────────────────────────────────
// The unified `llm` façade (src/lib/ai/index.ts) currently routes chat to
// OpenAI, so the selectable models are OpenAI chat models. The list is the
// single source of truth shared by the API (validation) and the UI (dropdown).
// `chatStream` accepts a `model` override, so picking any of these just sets
// that override per agent.

export interface AgentModelOption {
  id: string;
  label: string;
  hint: string;
}

export const AGENT_MODELS: readonly AgentModelOption[] = [
  { id: "gpt-4o-mini", label: "GPT-4o mini", hint: "Fast & cheap — good default" },
  { id: "gpt-4o", label: "GPT-4o", hint: "Most capable, higher cost" },
  { id: "gpt-4.1-mini", label: "GPT-4.1 mini", hint: "Balanced reasoning" },
] as const;

export const DEFAULT_AGENT_MODEL = AGENT_MODELS[0].id;

export function isValidAgentModel(model: string): boolean {
  return AGENT_MODELS.some((m) => m.id === model);
}
