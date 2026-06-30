"use client";

import type { SessionUser } from "@/lib/auth/session";
import { LenisProvider } from "./LenisProvider";
import { NavClient } from "./NavClient";
import { Footer } from "./Footer";
import { HeroSection } from "./HeroSection";
import { SocialProof } from "./SocialProof";
import { PlatformStrip } from "./PlatformStrip";
import { ProblemSection } from "./ProblemSection";
import { CaptureSection } from "./CaptureSection";
import { CompileSection } from "./CompileSection";
import { WikiSection } from "./WikiSection";
import { PlaceholderSection } from "./PlaceholderSections";

type Props = { user: SessionUser | null };

export function MarketingLanding({ user }: Props) {
  return (
    <LenisProvider>
      <main id="main" className="relative bg-[color:var(--bg-warm)]">
        <NavClient user={user} lang="en" />
        <HeroSection />

        <SocialProof />

        <PlatformStrip />

        <ProblemSection />

        <CaptureSection />

        <CompileSection />

        <WikiSection />

        <PlaceholderSection
          id="features"
          tone="sunken"
          label="What's inside"
          title="Built for the way you actually live."
          body="Local-first storage. Offline capture. Sync only when you say so. Whisper-grade transcription. EXIF-aware photo memos. A graph view that doesn't look like a science fair."
        />

        <PlaceholderSection
          id="cta"
          tone="warm"
          label="Start today"
          title="Today is for dumping. Tomorrow is for reading."
          body="Free. No account required. Download for iOS, with macOS in private beta. Your data stays on your device until you decide otherwise."
        />

        <Footer />
      </main>
    </LenisProvider>
  );
}
