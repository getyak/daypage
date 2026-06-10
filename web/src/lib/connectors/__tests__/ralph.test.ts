import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { WorkOrder as WorkOrderRow } from "@/lib/db/schema";

import {
  dispatch,
  toRalphStory,
  ralphAdapter,
  type RalphPrdFragment,
} from "../ralph";
import { getAdapter } from "../index";

// US-027 tests. The Ralph adapter translates a mature WorkOrder/tree_node into a
// legal Ralph prd.json story and writes it as a fragment. We exercise it against
// a real temp drop dir (no DB, no live process) and assert the written fragment
// is a structurally valid prd.json story.

// Build a WorkOrder row with sane defaults; override per-test.
function makeOrder(overrides: Partial<WorkOrderRow> = {}): WorkOrderRow {
  return {
    id: "11111111-1111-1111-1111-111111111111",
    user_id: "22222222-2222-2222-2222-222222222222",
    suggestion_id: null,
    intent: "As a user I want swipeable cards on the Today screen",
    context: {},
    output_spec: null,
    gate: "approve-first",
    callback: null,
    budget_tokens: null,
    status: "pending",
    result_ref: null,
    created_at: new Date("2026-06-10T00:00:00.000Z"),
    ...overrides,
  } as WorkOrderRow;
}

let dropDir: string;

beforeEach(async () => {
  dropDir = await fs.mkdtemp(path.join(os.tmpdir(), "ralph-conn-"));
});

afterEach(async () => {
  await fs.rm(dropDir, { recursive: true, force: true });
});

// A valid Ralph story has the exact field shape of scripts/ralph/prd.json's
// userStories[] element.
function assertValidStory(
  story: unknown
): asserts story is Record<string, unknown> {
  expect(story).toBeTypeOf("object");
  const s = story as Record<string, unknown>;
  expect(typeof s.id).toBe("string");
  expect((s.id as string).length).toBeGreaterThan(0);
  expect(typeof s.title).toBe("string");
  expect((s.title as string).length).toBeGreaterThan(0);
  expect(typeof s.description).toBe("string");
  expect(Array.isArray(s.acceptanceCriteria)).toBe(true);
  expect((s.acceptanceCriteria as unknown[]).length).toBeGreaterThan(0);
  for (const c of s.acceptanceCriteria as unknown[]) {
    expect(typeof c).toBe("string");
  }
  expect(typeof s.priority).toBe("number");
  expect(typeof s.passes).toBe("boolean");
  expect(typeof s.notes).toBe("string");
}

describe("toRalphStory", () => {
  it("maps a WorkOrder into a legal Ralph story", () => {
    const story = toRalphStory(makeOrder());
    assertValidStory(story);
    expect(story.id).toBe("RALPH-11111111-1111-1111-1111-111111111111");
    expect(story.description).toBe(
      "As a user I want swipeable cards on the Today screen"
    );
    // No context title/criteria → title falls back to intent, criteria to default.
    expect(story.title).toBe(story.description);
    expect(story.acceptanceCriteria).toEqual([
      "Deliver: As a user I want swipeable cards on the Today screen",
    ]);
    expect(story.priority).toBe(1);
    expect(story.passes).toBe(false);
  });

  it("prefers tree-node title and context acceptance criteria when present", () => {
    const story = toRalphStory(
      makeOrder({
        context: {
          node_title: "Today card UX",
          tree_title: "Improve Today screen",
          acceptance_criteria: ["Swipe left shares", "  Swipe right pins  ", ""],
        },
      })
    );
    expect(story.title).toBe("Today card UX");
    // Blanks dropped, whitespace trimmed.
    expect(story.acceptanceCriteria).toEqual([
      "Swipe left shares",
      "Swipe right pins",
    ]);
  });

  it("falls back to output_spec for acceptance when context has none", () => {
    const story = toRalphStory(
      makeOrder({ output_spec: "A working swipe gesture handler" })
    );
    expect(story.acceptanceCriteria).toEqual([
      "A working swipe gesture handler",
    ]);
  });
});

describe("dispatch", () => {
  it("writes a structurally valid prd.json fragment to the drop dir", async () => {
    const order = makeOrder();
    const result = await dispatch(order, { dir: dropDir });

    expect(result.status).toBe("active");
    expect(result.ref).toBe(path.join(dropDir, `${order.id}.prd.json`));

    const raw = await fs.readFile(result.ref!, "utf8");
    const parsed = JSON.parse(raw) as RalphPrdFragment;

    expect(Array.isArray(parsed.userStories)).toBe(true);
    expect(parsed.userStories).toHaveLength(1);
    assertValidStory(parsed.userStories[0]);
    expect(parsed.userStories[0].id).toBe(`RALPH-${order.id}`);
  });

  it("returns a failed outcome (not a throw) when the dir is unwritable", async () => {
    // Point at a path whose parent is a file, so mkdir fails.
    const file = path.join(dropDir, "not-a-dir");
    await fs.writeFile(file, "x", "utf8");
    const result = await dispatch(makeOrder(), {
      dir: path.join(file, "child"),
    });
    expect(result.status).toBe("failed");
    expect(result.ref).toBeNull();
    expect(result.error).toBeTruthy();
  });
});

describe("poll / collect", () => {
  it("reports running for a fresh fragment, done after passes flips", async () => {
    const order = makeOrder();
    const { ref } = await dispatch(order, { dir: dropDir });

    expect(await ralphAdapter.poll(ref!)).toEqual({ state: "running" });
    expect(await ralphAdapter.collect(ref!)).toEqual({
      ready: false,
      ref: ref,
    });

    // Ralph mutates the fragment in place, flipping passes once done.
    const raw = await fs.readFile(ref!, "utf8");
    const parsed = JSON.parse(raw) as RalphPrdFragment;
    parsed.userStories[0].passes = true;
    await fs.writeFile(ref!, JSON.stringify(parsed), "utf8");

    expect(await ralphAdapter.poll(ref!)).toEqual({ state: "done" });
    expect(await ralphAdapter.collect(ref!)).toEqual({
      ready: true,
      ref: ref,
    });
  });

  it("reports unknown for a missing fragment", async () => {
    const result = await ralphAdapter.poll(path.join(dropDir, "nope.prd.json"));
    expect(result.state).toBe("unknown");
  });
});

describe("getAdapter registry", () => {
  it("returns the ralph adapter for the ralph backend", () => {
    expect(getAdapter("ralph")).toBe(ralphAdapter);
    expect(getAdapter("ralph").backend).toBe("ralph");
  });

  it("returns a claude-code adapter for the claude-code backend", () => {
    const adapter = getAdapter("claude-code");
    expect(adapter.backend).toBe("claude-code");
    expect(typeof adapter.dispatch).toBe("function");
    expect(typeof adapter.poll).toBe("function");
    expect(typeof adapter.collect).toBe("function");
  });

  it("throws for an unregistered backend", () => {
    expect(() => getAdapter("openclaw")).toThrow(/No executor adapter/);
    expect(() => getAdapter("sandbox")).toThrow(/No executor adapter/);
  });
});
