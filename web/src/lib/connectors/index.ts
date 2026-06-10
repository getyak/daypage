// US-027: executor-adapter registry.
//
// `getAdapter(backend)` resolves the concrete ExecutorAdapter for a backend so
// the Gateway can dispatch/poll/collect against any executor through the uniform
// interface. Backends without a real adapter yet (sandbox) throw a clear error
// rather than silently no-op'ing.

import { claudeCodeAdapter } from "./claude-code";
import { openclawAdapter } from "./openclaw";
import { ralphAdapter } from "./ralph";
import type { AdapterBackend, ExecutorAdapter } from "./types";

export type {
  AdapterBackend,
  CollectResult,
  DispatchOutcome,
  ExecutorAdapter,
  PollResult,
} from "./types";

const ADAPTERS: Partial<Record<AdapterBackend, ExecutorAdapter>> = {
  "claude-code": claudeCodeAdapter,
  openclaw: openclawAdapter,
  ralph: ralphAdapter,
};

/**
 * Return the adapter registered for `backend`. Throws when no implementation is
 * registered yet (e.g. `sandbox`) so the caller fails loudly rather than
 * dispatching into a void.
 */
export function getAdapter(backend: AdapterBackend): ExecutorAdapter {
  const adapter = ADAPTERS[backend];
  if (!adapter) {
    throw new Error(`No executor adapter registered for backend: ${backend}`);
  }
  return adapter;
}
