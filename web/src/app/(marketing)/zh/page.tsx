import type { Metadata } from "next";
import { auth } from "@/lib/auth/session";
import { SITE_DESCRIPTION_ZH, SITE_URL } from "@/lib/seo";
import { MarketingZhLanding } from "../_components/MarketingZhLanding";

export const metadata: Metadata = {
  title: "你的一天,先记下,AI 再整理",
  description: SITE_DESCRIPTION_ZH,
  alternates: {
    canonical: "/zh",
    languages: {
      en: "/",
      "zh-CN": "/zh",
      "x-default": "/",
    },
  },
  openGraph: {
    title: "你的一天,先记下,AI 再整理",
    description: SITE_DESCRIPTION_ZH,
    url: `${SITE_URL}/zh`,
    locale: "zh_CN",
    alternateLocale: ["en_US"],
  },
  twitter: {
    title: "你的一天,先记下,AI 再整理",
    description: SITE_DESCRIPTION_ZH,
  },
};

export default async function ZhLandingPage() {
  const session = await auth().catch(() => null);
  return <MarketingZhLanding user={session?.user ?? null} />;
}
