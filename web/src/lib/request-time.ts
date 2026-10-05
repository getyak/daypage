import "server-only";
import { connection } from "next/server";

/** Read the clock at the dynamic request boundary, outside component rendering. */
export async function requestTime(): Promise<number> {
  await connection();
  return Date.now();
}
