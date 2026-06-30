import type { Metadata } from "next";
import { auth } from "@/lib/auth/session";
import { MarketingLanding } from "./(marketing)/_components/MarketingLanding";

export const metadata: Metadata = {
  alternates: {
    canonical: "/",
    languages: {
      en: "/",
      "zh-CN": "/zh",
      "x-default": "/",
    },
  },
};

export default async function Root() {
  const session = await auth().catch(() => null);
  return <MarketingLanding user={session?.user ?? null} />;
}
