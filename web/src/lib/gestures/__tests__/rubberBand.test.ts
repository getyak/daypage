import { describe, it, expect } from "vitest";
import { applyRubberBand, snapTarget } from "../rubberBand";

describe("applyRubberBand", () => {
  it("tx=0: returns 0 (pass-through, no rubber-band)", () => {
    expect(applyRubberBand(0)).toBe(0);
  });

  it("tx=-66: returns -66 (within normal swipe range, no rubber-band)", () => {
    expect(applyRubberBand(-66)).toBe(-66);
  });

  it("tx=-132: returns -132 (exactly at reveal boundary, no rubber-band)", () => {
    expect(applyRubberBand(-132)).toBe(-132);
  });

  it("tx=-164: returns -164 (exactly at overshoot boundary, no rubber-band)", () => {
    expect(applyRubberBand(-164)).toBe(-164);
  });

  it("tx=-200: applies rubber-band left overshoot (beyond -164)", () => {
    // -164 + (-200 + 164) * 0.18 = -164 + (-36) * 0.18 = -164 - 6.48 = -170.48
    expect(applyRubberBand(-200)).toBeCloseTo(-170.48, 5);
  });

  it("tx=+50: applies rubber-band right swipe (positive tx)", () => {
    // 50 * 0.18 = 9
    expect(applyRubberBand(50)).toBeCloseTo(9, 5);
  });
});

describe("snapTarget", () => {
  it("committedTx=0: snaps to 0", () => {
    expect(snapTarget(0)).toBe(0);
  });

  it("committedTx=-65: does not exceed threshold, snaps to 0", () => {
    expect(snapTarget(-65)).toBe(0);
  });

  it("committedTx=-66: exactly at threshold boundary, snaps to 0 (strict less-than)", () => {
    // PRD: committedTx < -REVEAL/2; -66 is not < -66, so snaps to 0
    expect(snapTarget(-66)).toBe(0);
  });

  it("committedTx=-132: past threshold, snaps to -132", () => {
    expect(snapTarget(-132)).toBe(-132);
  });
});
