import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { safeNextPath } from "@/lib/auth/safe-next";

// OAuth + magic-link callback. Supabase appends `?code=...` after the user
// confirms (Apple PKCE flow or email link click); we exchange it for a session
// cookie, then forward to `next` (default /memos). Authentication failures
// become static error codes; provider messages never enter redirect URLs.
// Only same-origin relative paths are safe redirect targets. Reject absolute
// URLs (http://evil.com), protocol-relative URLs (//evil.com), and anything
// that doesn't start with a single "/" — otherwise `next` becomes an open
// redirect an attacker can use to phish credentials. Default to /memos.
export async function GET(request: NextRequest) {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const next = safeNextPath(url.searchParams.get("next"), "/memos");

  if (url.searchParams.has("error_description") || url.searchParams.has("error")) {
    const back = new URL("/login", url.origin);
    back.searchParams.set("error", "Verification");
    return NextResponse.redirect(back);
  }

  if (code) {
    const supabase = await createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (error) {
      const back = new URL("/login", url.origin);
      back.searchParams.set("error", "Verification");
      return NextResponse.redirect(back);
    }
  }

  return NextResponse.redirect(new URL(next, url.origin));
}
