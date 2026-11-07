export type LocalPresentation = "image/png" | "image/jpeg" | "image/gif" | "image/webp" | "audio/wav" | "audio/mpeg" | "text/plain" | null;
/** A bounded, opt-in browser presentation hint; never a remote URL or trust/identity claim. */
export function localPresentation(path: string, bytes: Uint8Array): LocalPresentation {
  const prefix = (values: number[]) => values.every((value, index) => bytes[index] === value);
  const ascii = (start: number, end: number) => String.fromCharCode(...bytes.slice(start, end));
  if (prefix([137, 80, 78, 71, 13, 10, 26, 10])) return "image/png";
  if (prefix([255, 216, 255])) return "image/jpeg";
  if (ascii(0, 6) === "GIF87a" || ascii(0, 6) === "GIF89a") return "image/gif";
  if (ascii(0, 4) === "RIFF" && ascii(8, 12) === "WEBP") return "image/webp";
  if (ascii(0, 4) === "RIFF" && ascii(8, 12) === "WAVE") return "audio/wav";
  if (ascii(0, 3) === "ID3" || (bytes[0] === 255 && (bytes[1] & 0xe0) === 0xe0)) return "audio/mpeg";
  if (bytes.length <= 4 * 1024 * 1024 && /\.(?:txt|md|json|csv)$/i.test(path)) {
    try { new TextDecoder("utf-8", { fatal: true }).decode(bytes); return "text/plain"; } catch { return null; }
  }
  return null;
}
