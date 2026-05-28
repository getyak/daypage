import { NextResponse } from "next/server";

export async function GET() {
  return NextResponse.json({
    streak_days: 12,
    pages_total: 847,
    words_this_year: 142350,
    words_this_year_display: "142K",
  });
}
