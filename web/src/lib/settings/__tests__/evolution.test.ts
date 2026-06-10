import { describe, it, expect } from "vitest";

import {
  DEFAULT_EVOLUTION_CONFIG,
  DEFAULT_PER_TREE_BUDGET_TOKENS,
  EVOLUTION_SETTINGS_KEY,
  LEGACY_EVOLUTION_ENABLED_KEY,
  evolutionConfigSchema,
  readEvolutionConfig,
  shouldRunOnTick,
} from "@/lib/settings/evolution";

// US-021: the `evolution` block round-trips through GET/PUT /api/settings and
// drives the Gateway scheduler + Suggester cadence. These tests pin down the
// read/write contract (schema defaults, legacy fallback, malformed degradation)
// and the `daily`/`hourly` tick decision.

describe("evolutionConfigSchema (write path — zod validation + defaults)", () => {
  it("fills every field from defaults on an empty object", () => {
    const parsed = evolutionConfigSchema.parse({});
    expect(parsed).toEqual({
      enabled: false,
      schedule: "hourly",
      channel: "telegram",
      perTreeBudgetTokens: DEFAULT_PER_TREE_BUDGET_TOKENS,
    });
    // dailyHour is optional and absent unless provided.
    expect(parsed).not.toHaveProperty("dailyHour");
  });

  it("DEFAULT_EVOLUTION_CONFIG matches the schema-parsed defaults", () => {
    expect(DEFAULT_EVOLUTION_CONFIG).toEqual(evolutionConfigSchema.parse({}));
  });

  it("accepts a fully-specified daily config", () => {
    const parsed = evolutionConfigSchema.parse({
      enabled: true,
      schedule: "daily",
      dailyHour: 9,
      channel: "telegram",
      perTreeBudgetTokens: 8000,
    });
    expect(parsed).toEqual({
      enabled: true,
      schedule: "daily",
      dailyHour: 9,
      channel: "telegram",
      perTreeBudgetTokens: 8000,
    });
  });

  it("rejects an unknown schedule", () => {
    expect(
      evolutionConfigSchema.safeParse({ schedule: "weekly" }).success
    ).toBe(false);
  });

  it("rejects an unknown channel", () => {
    expect(
      evolutionConfigSchema.safeParse({ channel: "email" }).success
    ).toBe(false);
  });

  it("rejects dailyHour out of the 0–23 range", () => {
    expect(evolutionConfigSchema.safeParse({ dailyHour: 24 }).success).toBe(
      false
    );
    expect(evolutionConfigSchema.safeParse({ dailyHour: -1 }).success).toBe(
      false
    );
  });

  it("rejects a non-positive perTreeBudgetTokens", () => {
    expect(
      evolutionConfigSchema.safeParse({ perTreeBudgetTokens: 0 }).success
    ).toBe(false);
    expect(
      evolutionConfigSchema.safeParse({ perTreeBudgetTokens: -100 }).success
    ).toBe(false);
  });

  it("rejects a non-integer dailyHour / budget", () => {
    expect(evolutionConfigSchema.safeParse({ dailyHour: 9.5 }).success).toBe(
      false
    );
    expect(
      evolutionConfigSchema.safeParse({ perTreeBudgetTokens: 100.5 }).success
    ).toBe(false);
  });
});

describe("readEvolutionConfig (read path)", () => {
  it("returns defaults for null/undefined/empty settings", () => {
    expect(readEvolutionConfig(null)).toEqual(DEFAULT_EVOLUTION_CONFIG);
    expect(readEvolutionConfig(undefined)).toEqual(DEFAULT_EVOLUTION_CONFIG);
    expect(readEvolutionConfig({})).toEqual(DEFAULT_EVOLUTION_CONFIG);
  });

  it("reads a present block, filling missing fields with defaults", () => {
    const config = readEvolutionConfig({
      [EVOLUTION_SETTINGS_KEY]: {
        enabled: true,
        schedule: "daily",
        dailyHour: 7,
      },
    });
    expect(config).toEqual({
      enabled: true,
      schedule: "daily",
      dailyHour: 7,
      channel: "telegram",
      perTreeBudgetTokens: DEFAULT_PER_TREE_BUDGET_TOKENS,
    });
  });

  it("honours the legacy evolution_enabled=true flag as enabled defaults", () => {
    const config = readEvolutionConfig({
      [LEGACY_EVOLUTION_ENABLED_KEY]: true,
    });
    expect(config).toEqual({ ...DEFAULT_EVOLUTION_CONFIG, enabled: true });
  });

  it("treats legacy string 'true' as enabled", () => {
    const config = readEvolutionConfig({
      [LEGACY_EVOLUTION_ENABLED_KEY]: "true",
    });
    expect(config.enabled).toBe(true);
  });

  it("prefers an explicit block over the legacy flag", () => {
    const config = readEvolutionConfig({
      [LEGACY_EVOLUTION_ENABLED_KEY]: true,
      [EVOLUTION_SETTINGS_KEY]: { enabled: false },
    });
    expect(config.enabled).toBe(false);
  });

  it("degrades a malformed block to defaults rather than throwing", () => {
    const config = readEvolutionConfig({
      [EVOLUTION_SETTINGS_KEY]: { schedule: "weekly", perTreeBudgetTokens: -5 },
    });
    expect(config).toEqual(DEFAULT_EVOLUTION_CONFIG);
  });
});

describe("shouldRunOnTick (cadence decision)", () => {
  it("never runs when disabled, whatever the schedule", () => {
    expect(
      shouldRunOnTick({ ...DEFAULT_EVOLUTION_CONFIG, enabled: false }, 9)
    ).toBe(false);
  });

  it("runs every tick when hourly + enabled", () => {
    const config = { ...DEFAULT_EVOLUTION_CONFIG, enabled: true };
    expect(shouldRunOnTick(config, 0)).toBe(true);
    expect(shouldRunOnTick(config, 13)).toBe(true);
    expect(shouldRunOnTick(config, 23)).toBe(true);
  });

  it("runs daily only on the configured dailyHour", () => {
    const config = {
      ...DEFAULT_EVOLUTION_CONFIG,
      enabled: true,
      schedule: "daily" as const,
      dailyHour: 9,
    };
    expect(shouldRunOnTick(config, 9)).toBe(true);
    expect(shouldRunOnTick(config, 8)).toBe(false);
    expect(shouldRunOnTick(config, 10)).toBe(false);
  });

  it("daily without dailyHour runs on whatever tick it first sees", () => {
    const config = {
      ...DEFAULT_EVOLUTION_CONFIG,
      enabled: true,
      schedule: "daily" as const,
    };
    expect(shouldRunOnTick(config, 4)).toBe(true);
    expect(shouldRunOnTick(config, 17)).toBe(true);
  });
});
