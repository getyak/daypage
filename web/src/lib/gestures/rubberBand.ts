const REVEAL = 132;
const OVERSHOOT = 32;
const DAMP = 0.18;

export function applyRubberBand(rawTx: number): number {
  if (rawTx > 0) return rawTx * DAMP;
  if (rawTx < -REVEAL - OVERSHOOT) {
    return -REVEAL - OVERSHOOT + (rawTx + REVEAL + OVERSHOOT) * DAMP;
  }
  return rawTx;
}

export function snapTarget(committedTx: number): 0 | -132 {
  return committedTx < -REVEAL / 2 ? (-REVEAL as -132) : 0;
}
