import { describe, it, expect, vi } from "vitest";

// Stub the db client so the pure graph-analysis helpers can be unit-tested
// without a DATABASE_URL (gap-detect.ts imports db/client at module load).
vi.mock("@/lib/db/client", () => ({ db: {} }));

import {
  detectCommunities,
  gapSignature,
  GAP_SIMILARITY_THRESHOLD,
  GAP_SIMILARITY_CEILING,
  MIN_GAP_CLUSTER_SIZE,
} from "@/lib/inngest/functions/gap-detect";

describe("detectCommunities", () => {
  it("groups linked pages into one community and leaves unlinked pages separate", () => {
    const pages = ["a", "b", "c", "d", "e"];
    const edges = [
      { from: "a", to: "b" },
      { from: "b", to: "c" },
      { from: "d", to: "e" },
    ];
    const communities = detectCommunities(pages, edges).map((c) => c.sort());
    // Two communities: {a,b,c} and {d,e}
    expect(communities).toHaveLength(2);
    const sizes = communities.map((c) => c.length).sort();
    expect(sizes).toEqual([2, 3]);
  });

  it("treats every page as its own community when there are no edges", () => {
    const pages = ["a", "b", "c"];
    const communities = detectCommunities(pages, []);
    expect(communities).toHaveLength(3);
  });

  it("ignores edges that reference unknown pages", () => {
    const pages = ["a", "b"];
    const edges = [
      { from: "a", to: "ghost" },
      { from: "a", to: "b" },
    ];
    const communities = detectCommunities(pages, edges);
    expect(communities).toHaveLength(1);
    expect(communities[0].sort()).toEqual(["a", "b"]);
  });
});

describe("gapSignature", () => {
  it("is order-independent across the two clusters", () => {
    const a = ["p1", "p2"];
    const b = ["p3", "p4"];
    expect(gapSignature(a, b)).toBe(gapSignature(b, a));
  });

  it("is order-independent within a cluster", () => {
    expect(gapSignature(["p2", "p1"], ["p4", "p3"])).toBe(
      gapSignature(["p1", "p2"], ["p3", "p4"])
    );
  });

  it("differs for different cluster pairs", () => {
    expect(gapSignature(["p1"], ["p2"])).not.toBe(
      gapSignature(["p1"], ["p3"])
    );
  });
});

describe("gap thresholds", () => {
  it("defines a sane sweet-spot similarity band", () => {
    expect(GAP_SIMILARITY_THRESHOLD).toBeLessThan(GAP_SIMILARITY_CEILING);
    expect(GAP_SIMILARITY_THRESHOLD).toBeGreaterThan(0);
    expect(GAP_SIMILARITY_CEILING).toBeLessThanOrEqual(1);
  });

  it("requires clusters of at least a few pages", () => {
    expect(MIN_GAP_CLUSTER_SIZE).toBeGreaterThanOrEqual(2);
  });
});
