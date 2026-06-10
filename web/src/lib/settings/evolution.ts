import { z } from "zod";

// US-021: the `evolution` block stored under `user_settings.settings`. It
// configures *when* the autonomous evolution loop generates suggestions and how
// they are pushed. The Gateway scheduler (scheduler-tick) and the Suggester
// read this block to decide whether/when to run and what per-tree token budget
// to spend.
//
// The block is one key inside the free-form `settings` jsonb so it round-trips
// through the existing GET/PUT /api/settings route without a schema migration.
// A legacy `evolution_enabled` boolean predates this block; `readEvolutionConfig`
// honours it as a fallback so already-opted-in users keep running.

export const EVOLUTION_SETTINGS_KEY = "evolution";

// Legacy opt-in flag (pre-US-021). Kept for backward compatibility: a user with
// only `evolution_enabled: true` is treated as enabled with default cadence.
export const LEGACY_EVOLUTION_ENABLED_KEY = "evolution_enabled";

// How often suggestions are generated/pushed. `hourly` follows the Gateway tick
// cron directly; `daily` only fires on the tick whose hour matches `dailyHour`.
export const EVOLUTION_SCHEDULES = ["hourly", "daily"] as const;
export type EvolutionSchedule = (typeof EVOLUTION_SCHEDULES)[number];

// Where suggestions are delivered. Telegram is the only supported channel today
// (US-011), modelled as an enum so adding channels later is a non-breaking widen.
export const EVOLUTION_CHANNELS = ["telegram"] as const;
export type EvolutionChannel = (typeof EVOLUTION_CHANNELS)[number];

// Default per-tree token budget the Suggester is allowed to spend per run.
export const DEFAULT_PER_TREE_BUDGET_TOKENS = 4000;

// The validated shape. `dailyHour` is the local hour (0–23) a `daily` schedule
// fires on; it is optional and ignored for `hourly`.
export const evolutionConfigSchema = z.object({
  enabled: z.boolean().default(false),
  schedule: z.enum(EVOLUTION_SCHEDULES).default("hourly"),
  dailyHour: z.number().int().min(0).max(23).optional(),
  channel: z.enum(EVOLUTION_CHANNELS).default("telegram"),
  perTreeBudgetTokens: z
    .number()
    .int()
    .positive()
    .default(DEFAULT_PER_TREE_BUDGET_TOKENS),
});

export type EvolutionConfig = z.infer<typeof evolutionConfigSchema>;

// The defaults a brand-new (or legacy-only) user is treated as having. Computed
// from the schema so the default values live in exactly one place.
export const DEFAULT_EVOLUTION_CONFIG: EvolutionConfig =
  evolutionConfigSchema.parse({});

// Parse the `evolution` block out of an arbitrary `settings` object, applying
// schema defaults for any missing field. Falls back to the legacy
// `evolution_enabled` flag when no block is present. Never throws — a malformed
// block degrades to defaults so a bad write can't break the scheduler.
export function readEvolutionConfig(
  settings: Record<string, unknown> | null | undefined
): EvolutionConfig {
  const raw = settings?.[EVOLUTION_SETTINGS_KEY];

  if (raw !== undefined && raw !== null) {
    const parsed = evolutionConfigSchema.safeParse(raw);
    if (parsed.success) return parsed.data;
    // Malformed block: degrade to defaults rather than crash the loop.
    return { ...DEFAULT_EVOLUTION_CONFIG };
  }

  // No block — honour the legacy boolean opt-in.
  const legacy = settings?.[LEGACY_EVOLUTION_ENABLED_KEY];
  if (legacy === true || legacy === "true") {
    return { ...DEFAULT_EVOLUTION_CONFIG, enabled: true };
  }

  return { ...DEFAULT_EVOLUTION_CONFIG };
}

// Whether the evolution loop should run on a tick firing at `tickHour` (local
// hour, 0–23). `hourly` runs every tick; `daily` runs only on the configured
// hour (defaulting to the tick hour when `dailyHour` is unset, i.e. run once).
export function shouldRunOnTick(
  config: EvolutionConfig,
  tickHour: number
): boolean {
  if (!config.enabled) return false;
  if (config.schedule === "hourly") return true;
  // daily
  const targetHour = config.dailyHour ?? tickHour;
  return tickHour === targetHour;
}
