import type { Metadata } from "next";
import { Space_Grotesk, Inter, JetBrains_Mono, Fraunces } from "next/font/google";
import Script from "next/script";
import { QueryProvider } from "@/components/QueryProvider";
import { ThemeProvider } from "@/components/ThemeProvider";
import "./globals.css";

// Inline script runs synchronously before React hydration to avoid theme flash.
// Use next/script with `beforeInteractive` — React 19 refuses to execute a raw
// <script> rendered as a React child, so the previous inline form produced a
// console warning ("Scripts inside React components are never executed…") and
// on client-side re-renders simply did not run.
const themeScript = `
(function(){try{var s=localStorage.getItem('codex.settings.v1');var t=s?JSON.parse(s).theme:'system';document.documentElement.setAttribute('data-theme',t||'system');}catch(e){}})();
`;

const spaceGrotesk = Space_Grotesk({
  variable: "--font-space-grotesk",
  subsets: ["latin"],
  weight: ["500", "700"],
  display: "swap",
});

const inter = Inter({
  variable: "--font-inter",
  subsets: ["latin"],
  weight: ["400", "500", "600"],
  display: "swap",
});

const jetbrainsMono = JetBrains_Mono({
  variable: "--font-jetbrains-mono",
  subsets: ["latin"],
  weight: ["400", "500"],
  display: "swap",
});

const fraunces = Fraunces({
  variable: "--font-fraunces",
  subsets: ["latin"],
  weight: ["600"],
  display: "swap",
});

export const metadata: Metadata = {
  title: "DayPage",
  description: "AI-assisted journaling for anyone who wants to record their day.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      data-theme="system"
      className={`${spaceGrotesk.variable} ${inter.variable} ${jetbrainsMono.variable} ${fraunces.variable} h-full antialiased`}
      // Some browser extensions (e.g. Immersive Translate) inject attributes
      // onto <html> before React hydrates, causing a top-level mismatch warning.
      // Suppressing only on <html> is the React/Next recommended workaround.
      suppressHydrationWarning
    >
      <head>
        {/* Prevents theme flash by setting data-theme before first paint.
            beforeInteractive is the only safe strategy here — it lets Next.js
            emit the <script> into the SSR HTML stream so the browser parser
            executes it synchronously, before React hydrates. */}
        <Script id="theme-no-flash" strategy="beforeInteractive">
          {themeScript}
        </Script>
      </head>
      <body className="min-h-full bg-bg-warm text-fg-primary font-body">
        <ThemeProvider />
        <QueryProvider>{children}</QueryProvider>
      </body>
    </html>
  );
}
