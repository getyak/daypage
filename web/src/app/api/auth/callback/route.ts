import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";

// OAuth + magic-link callback. Supabase appends `?code=...` after the user
// confirms (Apple PKCE flow or email link click); we exchange it for a session
// cookie, then forward to `next` (default /home). Errors come back via
// `?error_description=` and are surfaced on /login as a flash.
// Only same-origin relative paths are safe redirect targets. Reject absolute
// URLs (http://evil.com), protocol-relative URLs (//evil.com), and anything
// that doesn't start with a single "/" — otherwise `next` becomes an open
// redirect an attacker can use to phish credentials. Default to /home.
function safeNext(raw: string | null): string {
  if (!raw) return "/home";
  // Must be a path rooted at "/" but not "//" (protocol-relative) or "/\".
  if (!raw.startsWith("/") || raw.startsWith("//") || raw.startsWith("/\\")) {
    return "/home";
  }
  return raw;
}

export async function GET(request: NextRequest) {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const next = safeNext(url.searchParams.get("next"));
  const errorDescription = url.searchParams.get("error_description");

  if (errorDescription) {
    const back = new URL("/login", url.origin);
    back.searchParams.set("error", errorDescription);
    return NextResponse.redirect(back);
  }

  if (code) {
    const supabase = await createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (error) {
      const back = new URL("/login", url.origin);
      back.searchParams.set("error", error.message);
      return NextResponse.redirect(back);
    }
  }

  return NextResponse.redirect(new URL(next, url.origin));
}
