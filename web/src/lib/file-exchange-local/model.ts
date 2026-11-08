import type { ExchangeFile, ExchangeManifest } from "../file-exchange/contract.ts";

export const LOCAL_PARSER_VERSION = "daypage-file-exchange-v1.browser-local.1";
export interface LocalOwner { realm: string; uid: string }
export interface SourceIdentity {
  exportID: string; contentDigest: string; manifestDigest: string; parserVersion: string;
}
export interface LocalFileDescriptor extends Omit<ExchangeFile, "kind"> { kind: ExchangeFile["kind"] | "manifest" }
export interface ImportJob extends SourceIdentity {
  realm: string; uid: string; namespace: string; generation: string;
  status: "pending" | "committed"; createdAt: string;
  manifest: ExchangeManifest; expected: LocalFileDescriptor[];
}
export interface ImportReceipt extends SourceIdentity {
  realm: string; uid: string; namespace: string; generation: string;
  committedAt: string; notes: number; reviews: number; files: number; bytes: number;
}
export class LocalExchangeError extends Error {
  readonly code: string;
  constructor(code: string) { super(code); this.code = code; this.name = "LocalExchangeError"; }
}
export function localReject(code: string): never { throw new LocalExchangeError(code); }
export function projectRealm(value: string): string {
  let url: URL;
  try { url = new URL(value); } catch { return localReject("invalid-project-realm"); }
  if (url.username || url.password || url.search || url.hash ||
      (url.protocol !== "https:" && !(url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)))) {
    return localReject("invalid-project-realm");
  }
  return url.origin + url.pathname.replace(/\/+$/, "");
}
export function makeOwner(realm: string, uid: string): LocalOwner {
  if (!/^[\da-f]{8}-(?:[\da-f]{4}-){3}[\da-f]{12}$/i.test(uid)) localReject("invalid-owner");
  return Object.freeze({ realm: projectRealm(realm), uid });
}
export function ownerKey(owner: LocalOwner, ...suffix: string[]): string[] { return [owner.realm, owner.uid, ...suffix]; }
export function assertSameSource(stored: SourceIdentity, selected: SourceIdentity): void {
  if (stored.exportID !== selected.exportID || stored.contentDigest !== selected.contentDigest ||
      stored.manifestDigest !== selected.manifestDigest || stored.parserVersion !== selected.parserVersion) localReject("source-conflict");
}
export function selectionPaths(files: readonly { name: string; webkitRelativePath?: string }[]): string[] {
  if (!files.length) return [];
  const relative = files.map(file => file.webkitRelativePath ?? "");
  if (relative.every(path => path === "")) return files.map(file => file.name);
  const root = relative[0].split("/")[0];
  if (!root || relative.some(path => !path.startsWith(root + "/") || path.split("/").length < 2)) localReject("select-one-folder");
  return relative.map(path => path.slice(root.length + 1));
}
