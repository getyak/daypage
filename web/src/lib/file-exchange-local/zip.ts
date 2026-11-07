import { localReject } from "./model.ts";

export interface ZipEntry { path: string; bytes: Uint8Array }
const encode = new TextEncoder();
// Original exchange payload is50MiB, plus its separately bounded256KiB manifest.
// STORE adds at most a fixed header+two512-byte names per bounded file; no ZIP64.
const MAX_PAYLOAD = 50 * 1024 * 1024 + 256 * 1024;
const table = Uint32Array.from({ length: 256 }, (_, value) => {
  let crc = value;
  for (let i = 0; i < 8; i++) crc = (crc & 1) ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
  return crc >>> 0;
});
function checksum(bytes: Uint8Array) {
  let crc = 0xffffffff;
  for (const byte of bytes) crc = table[(crc ^ byte) & 255] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}
export function zipLayout(entries: readonly { path: string; bytes: { byteLength: number } }[]) {
  if (!entries.length || entries.length > 1001) localReject("zip-file-limit");
  const names = new Set<string>(); let payload = 0, size = 22;
  const planned = entries.map(entry => {
    const name = encode.encode(entry.path), folded = entry.path.normalize("NFC").toUpperCase().toLowerCase().normalize("NFC");
    if (!name.length || name.length > 512 || new TextDecoder("utf-8", { fatal: true }).decode(name) !== entry.path ||
        /[\\:\u0000-\u001f\u007f-\u009f]/.test(entry.path) ||
        entry.path.split("/").some(part => part === "" || part === "." || part === "..") || names.has(folded)) localReject("unsafe-zip-path");
    names.add(folded);
    if (!Number.isSafeInteger(entry.bytes.byteLength) || entry.bytes.byteLength < 0) localReject("zip-byte-limit");
    payload += entry.bytes.byteLength; size += 76 + name.length * 2 + entry.bytes.byteLength;
    if (payload > MAX_PAYLOAD || size >= 0xffffffff) localReject("zip-byte-limit");
    return name;
  });
  return { names: planned, size };
}
export function storeZip(entries: readonly ZipEntry[]): Uint8Array {
  const layout = zipLayout(entries), bytes = new Uint8Array(layout.size), view = new DataView(bytes.buffer);
  const central: { offset: number; crc: number; size: number; name: Uint8Array }[] = [];
  let offset = 0;
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i], name = layout.names[i], crc = checksum(entry.bytes), start = offset;
    view.setUint32(offset, 0x04034b50, true); view.setUint16(offset + 4, 20, true);
    view.setUint16(offset + 6, 0x0800, true); view.setUint16(offset + 12, 0x21, true);
    view.setUint32(offset + 14, crc, true); view.setUint32(offset + 18, entry.bytes.byteLength, true);
    view.setUint32(offset + 22, entry.bytes.byteLength, true); view.setUint16(offset + 26, name.length, true);
    bytes.set(name, offset + 30); offset += 30 + name.length; bytes.set(entry.bytes, offset); offset += entry.bytes.length;
    central.push({ offset: start, crc, size: entry.bytes.length, name });
  }
  const directory = offset;
  for (const entry of central) {
    view.setUint32(offset, 0x02014b50, true); view.setUint16(offset + 4, 20, true); view.setUint16(offset + 6, 20, true);
    view.setUint16(offset + 8, 0x0800, true); view.setUint16(offset + 14, 0x21, true);
    view.setUint32(offset + 16, entry.crc, true); view.setUint32(offset + 20, entry.size, true); view.setUint32(offset + 24, entry.size, true);
    view.setUint16(offset + 28, entry.name.length, true); view.setUint32(offset + 42, entry.offset, true);
    bytes.set(entry.name, offset + 46); offset += 46 + entry.name.length;
  }
  view.setUint32(offset, 0x06054b50, true); view.setUint16(offset + 8, entries.length, true); view.setUint16(offset + 10, entries.length, true);
  view.setUint32(offset + 12, offset - directory, true); view.setUint32(offset + 16, directory, true);
  return bytes;
}
