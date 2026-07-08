import { NextResponse } from "next/server";

// Standard JSON error responses shared across API route handlers. Each mirrors
// the `NextResponse.json({ error }, { status })` shape the routes used inline,
// so swapping to these helpers is behaviour-preserving.

export function unauthorized(message = "Unauthorized") {
  return NextResponse.json({ error: message }, { status: 401 });
}

export function badRequest(message = "Bad Request") {
  return NextResponse.json({ error: message }, { status: 400 });
}

export function forbidden(message = "Forbidden") {
  return NextResponse.json({ error: message }, { status: 403 });
}

export function notFound(message = "Not Found") {
  return NextResponse.json({ error: message }, { status: 404 });
}

export function serverError(message = "Internal Server Error") {
  return NextResponse.json({ error: message }, { status: 500 });
}
