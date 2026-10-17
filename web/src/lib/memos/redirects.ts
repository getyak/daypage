// Login redirect helper: keep the intended destination when we can observe it.
//
// A Server Component layout cannot read the request URL directly; the
// destination is only available when a request header carries the path (e.g.
// an `x-pathname` forward). The value is sanitised to a same-origin path
// before it is echoed into `callbackUrl` — no open redirects.

import { safeNextPath } from "@/lib/auth/safe-next";

export function loginRedirectTarget(destination: string | null | undefined): string {
  const next = safeNextPath(destination ?? "", "");
  return next ? `/login?callbackUrl=${encodeURIComponent(next)}` : "/login";
}
