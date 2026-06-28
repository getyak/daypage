import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";

// OAuth + magic-link callback. Supabase appends `?code=...` after the user
// confirms (Apple PKCE flow or email link click); we exchange it for a session
// cookie, then forward to `next` (default /home). Errors come back via
// `?error_description=` and are surfaced on /login as a flash.
export async function GET(request: NextRequest) {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const next = url.searchParams.get("next") ?? "/home";
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
