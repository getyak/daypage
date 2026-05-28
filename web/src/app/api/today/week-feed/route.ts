import { NextRequest, NextResponse } from "next/server";

export const revalidate = 0;

export type WeekFeedItem = {
  id: string;
  date_slug: string;
  day: string;
  date_display: string;
  title: string;
  lede: string;
  tags: string[];
  word_count: number;
  memo_count: number;
};

export async function GET(req: NextRequest) {
  const limitParam = req.nextUrl.searchParams.get("limit");
  const limit = Math.min(Math.max(parseInt(limitParam ?? "7", 10) || 7, 1), 30);
  void limit;

  return NextResponse.json({ items: [] satisfies WeekFeedItem[] });
}
