import { NextResponse } from "next/server";

// TODO: Post-MVP — implement server-side draft sync backed by user session + DB
// GET /api/drafts/add — fetch the current user's saved /add draft
export async function GET() {
  return NextResponse.json({ error: "Not implemented" }, { status: 501 });
}

// PUT /api/drafts/add — upsert the current user's /add draft
export async function PUT() {
  return NextResponse.json({ error: "Not implemented" }, { status: 501 });
}
