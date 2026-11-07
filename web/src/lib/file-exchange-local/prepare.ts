import { previewExchange, sha256 } from "../file-exchange/preview.ts";
import type { ExchangePreview } from "../file-exchange/preview.ts";
import { LOCAL_PARSER_VERSION } from "./model.ts";
import type { LocalFileDescriptor, SourceIdentity } from "./model.ts";
import { zipLayout } from "./zip.ts";

export interface PreparedImport {
  preview: ExchangePreview; identity: SourceIdentity;
  expected: LocalFileDescriptor[]; originals: ReadonlyMap<string, Uint8Array>;
}
/** Recheck immutable private byte copies at the confirmation boundary. No I/O adapter. */
export async function prepareImport(selected: ExchangePreview, signal?: AbortSignal): Promise<PreparedImport> {
  signal?.throwIfAborted();
  const originals = new Map([...selected.files].map(([path, bytes]) => [path, Uint8Array.from(bytes)]));
  originals.set("daypage-exchange.json", Uint8Array.from(selected.manifestBytes));
  const preview = await previewExchange([...originals].map(([path, bytes]) => ({ path, size: bytes.byteLength, read: async () => bytes })), signal);
  const manifestDigest = await sha256(preview.manifestBytes); signal?.throwIfAborted();
  const expected: LocalFileDescriptor[] = [{ path: "daypage-exchange.json", kind: "manifest",
    bytes: preview.manifestBytes.byteLength, sha256: manifestDigest }, ...preview.manifest.files.map(file => ({ ...file }))];
  // Every admitted notebook must have a complete, bounded exact-byte recovery path.
  zipLayout([...originals].map(([path, bytes]) => ({ path, bytes })));
  return { preview, expected, originals, identity: { exportID: preview.manifest.export_id.toLowerCase(),
    contentDigest: preview.manifest.content_sha256, manifestDigest, parserVersion: LOCAL_PARSER_VERSION } };
}
