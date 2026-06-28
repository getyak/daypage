import { NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, memos } from "@/lib/db/schema";
import { eq, and, gte, lt, sql, desc } from "drizzle-orm";

// 5-minute cache keyed on weather invalidation
export const revalidate = 300;

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

type WeatherPayload = {
  temp: number | null;
  condition: string | null;
  icon: string | null;
};

async function fetchWeather(): Promise<WeatherPayload> {
  const apiKey = process.env.OPENWEATHER_API_KEY;
  if (!apiKey) return { temp: null, condition: null, icon: null };

  try {
    const res = await fetch(
      `https://api.openweathermap.org/data/2.5/weather?q=Beijing&appid=${apiKey}&units=metric&lang=zh_cn`,
      { next: { revalidate: 300 } }
    );
    if (!res.ok) return { temp: null, condition: null, icon: null };
    const data = await res.json();
    return {
      temp: Math.round(data.main?.temp ?? 0),
      condition: data.weather?.[0]?.description ?? null,
      icon: data.weather?.[0]?.icon ?? null,
    };
  } catch {
    return { temp: null, condition: null, icon: null };
  }
}

export async function GET() {
  const session = await auth();
  if (!session?.user?.email) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const userId = await resolveUserId(session.user.email);
  if (!userId) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const now = new Date();
  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const tomorrowStart = new Date(todayStart.getTime() + 86_400_000);

  const [memoCountResult, latestMemoRows, apiWeather] = await Promise.all([
    db
      .select({ count: sql<number>`count(*)::int` })
      .from(memos)
      .where(
        and(
          eq(memos.user_id, userId),
          gte(memos.created_at, todayStart),
          lt(memos.created_at, tomorrowStart)
        )
      ),
    // Pull today's most recent memo so the hero subline can reflect the place
    // and weather captured in the field, without a live geolocation lookup.
    db
      .select({ location: memos.location, weather: memos.weather })
      .from(memos)
      .where(
        and(
          eq(memos.user_id, userId),
          gte(memos.created_at, todayStart),
          lt(memos.created_at, tomorrowStart)
        )
      )
      .orderBy(desc(memos.created_at))
      .limit(1),
    fetchWeather(),
  ]);

  // Prefer the weather stamped on today's latest memo; fall back to the live
  // API only when a memo did not carry one.
  const memoWeatherRaw = latestMemoRows[0]?.weather as
    | { temp?: number | null; condition?: string | null; icon?: string | null }
    | null
    | undefined;
  const weather: WeatherPayload =
    memoWeatherRaw && typeof memoWeatherRaw.temp === "number"
      ? {
          temp: memoWeatherRaw.temp ?? null,
          condition: memoWeatherRaw.condition ?? null,
          icon: memoWeatherRaw.icon ?? null,
        }
      : apiWeather;

  const memoLocationRaw = latestMemoRows[0]?.location as
    | { name?: string | null }
    | null
    | undefined;
  const location: string | null = memoLocationRaw?.name ?? null;

  const weekdayZh = new Intl.DateTimeFormat("zh-CN", {
    weekday: "long",
  }).format(now);

  const weekday = new Intl.DateTimeFormat("en-US", {
    weekday: "long",
  }).format(now);

  const dateDisplay = new Intl.DateTimeFormat("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  })
    .format(now)
    .toUpperCase();

  return NextResponse.json(
    {
      weekday,
      weekday_zh: weekdayZh,
      date_iso: now.toISOString().slice(0, 10),
      date_display: dateDisplay,
      memo_count: memoCountResult[0]?.count ?? 0,
      weather,
      location,
    },
    {
      headers: {
        "Cache-Control": "public, s-maxage=300, stale-while-revalidate=60",
      },
    }
  );
}
