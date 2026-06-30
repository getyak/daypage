// Centralized SEO constants. Single source of truth for the whole site —
// changing the canonical URL or brand line here updates layout metadata,
// sitemap, robots, OG image, and JSON-LD in one shot.

export const SITE_URL =
  process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/$/, "") ||
  "https://daypage.app";

export const SITE_NAME = "DayPage";

export const SITE_TAGLINE = "Your day, captured raw. Compiled by AI.";

export const SITE_DESCRIPTION =
  "DayPage is a local-first journaling app for nomads. Dump voice, text, and photos into Today — at 2am, AI compiles your raw fragments into a structured diary and a knowledge wiki that grows with every day.";

export const SITE_DESCRIPTION_ZH =
  "DayPage 是一款为数字游民设计的本地优先日记应用。把语音、文字、照片随手扔进 Today,凌晨 2 点 AI 自动把碎片编译成结构化日记与持续生长的知识图谱。";

export const SITE_KEYWORDS = [
  "DayPage",
  "AI journaling",
  "AI 日记",
  "personal knowledge management",
  "daily log",
  "digital nomad app",
  "local-first journal",
  "voice journaling",
  "knowledge graph",
  "second brain",
  "diary app",
  "Whisper transcription",
  "iOS journaling app",
];

export const BRAND = {
  primary: "#7C2D12",
  background: "#FBF7EE",
  ink: "#2A1F18",
};

export const SOCIAL = {
  github: "https://github.com/getyak/daypage",
  twitter: "@daypage_app",
  email: "hello@daypage.app",
};

export const APP = {
  platform: "iOS 16+",
  pricing: "Free",
  category: "ProductivityApplication",
};

export const OG_IMAGE = {
  width: 1200,
  height: 630,
  alt: `${SITE_NAME} — ${SITE_TAGLINE}`,
};

export const PUBLIC_ROUTES = [
  { path: "/", priority: 1.0, changefreq: "weekly" as const },
  { path: "/manifesto", priority: 0.8, changefreq: "monthly" as const },
  { path: "/download", priority: 0.9, changefreq: "monthly" as const },
  { path: "/changelog", priority: 0.7, changefreq: "weekly" as const },
  { path: "/about", priority: 0.6, changefreq: "yearly" as const },
  { path: "/faq", priority: 0.7, changefreq: "monthly" as const },
  { path: "/privacy", priority: 0.4, changefreq: "yearly" as const },
  { path: "/terms", priority: 0.4, changefreq: "yearly" as const },
];

export function absoluteUrl(path: string): string {
  if (path.startsWith("http")) return path;
  return `${SITE_URL}${path.startsWith("/") ? path : `/${path}`}`;
}
