import { auth } from "@/auth";
import { NextResponse } from "next/server";

export default auth((req) => {
  const { pathname } = req.nextUrl;
  const isLoggedIn = !!req.auth;

  // Redirect unauthenticated users away from app routes
  if (!isLoggedIn && pathname.startsWith("/home")) {
    return NextResponse.redirect(new URL("/login", req.url));
  }
  if (!isLoggedIn && !pathname.startsWith("/login") && !pathname.startsWith("/api")) {
    const appPaths = ["/home", "/add", "/chat", "/wiki", "/inbox"];
    if (appPaths.some((p) => pathname.startsWith(p))) {
      return NextResponse.redirect(new URL("/login", req.url));
    }
  }
});

export const config = {
  matcher: ["/home/:path*", "/add/:path*", "/chat/:path*", "/wiki/:path*", "/inbox/:path*"],
};
