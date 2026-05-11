import { auth } from "@/auth";
import { NextResponse } from "next/server";

export default auth((req) => {
  const { pathname } = req.nextUrl;
  const isLoggedIn = !!req.auth;
  const appPaths = ["/home", "/add", "/chat", "/wiki", "/inbox"];

  if (!isLoggedIn && appPaths.some((p) => pathname.startsWith(p))) {
    return NextResponse.redirect(new URL("/login", req.url));
  }

  const response = NextResponse.next();
  response.headers.set("x-pathname", pathname);
  return response;
});

export const config = {
  matcher: ["/home/:path*", "/add/:path*", "/chat/:path*", "/wiki/:path*", "/inbox/:path*"],
};
