import type { LocalOwner } from "./model.ts";
import { localReject, makeOwner } from "./model.ts";
export interface AbortableTransaction { abort(): void }
export class OwnerLease {
  readonly owner: LocalOwner;
  readonly signal: AbortSignal;
  private controller = new AbortController();
  private transactions = new Set<AbortableTransaction>();
  private isCurrent: () => boolean;
  private release: () => void;
  constructor(owner: LocalOwner, isCurrent: () => boolean, release: () => void) {
    this.owner = owner; this.signal = this.controller.signal; this.isCurrent = isCurrent; this.release = release;
  }
  check(): void {
    this.signal.throwIfAborted();
    if (!this.isCurrent()) localReject("owner-changed");
  }
  track(transaction: AbortableTransaction): () => void {
    this.check(); this.transactions.add(transaction);
    return () => this.transactions.delete(transaction);
  }
  cancel(): void {
    this.controller.abort(new DOMException("Operation stopped", "AbortError"));
    for (const transaction of this.transactions) {
      try { transaction.abort(); } catch { /* It may already have committed. Its old-owner receipt remains authoritative. */ }
    }
    this.transactions.clear(); this.release();
  }
  close(): void { this.cancel(); }
}
export class OwnerEpoch {
  owner: LocalOwner | null = null;
  private generation = 0;
  private leases = new Set<OwnerLease>();
  authorize(owner: LocalOwner) { this.revoke(); this.owner = makeOwner(owner.realm, owner.uid); }
  revoke() {
    this.owner = null; this.generation++;
    for (const lease of this.leases) lease.cancel();
    this.leases.clear();
  }
  lease() {
    if (!this.owner) return localReject("owner-unverified");
    const owner = this.owner, generation = this.generation;
    const lease = new OwnerLease(owner, () => this.owner === owner && this.generation === generation, () => this.leases.delete(lease));
    this.leases.add(lease); return lease;
  }
}
