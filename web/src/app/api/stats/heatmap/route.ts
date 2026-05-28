import { NextResponse } from "next/server";

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const weeks = parseInt(searchParams.get("weeks") ?? "16", 10);

  return NextResponse.json({
    weeks,
    from: "",
    to: "",
    cells: [] as Array<{ date: string; count: number }>,
    streak: 0,
  });
}
