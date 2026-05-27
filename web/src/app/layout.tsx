import type { Metadata } from "next";
import { Space_Grotesk, Inter, JetBrains_Mono } from "next/font/google";
import { QueryProvider } from "@/components/QueryProvider";
import { ThemeProvider } from "@/components/ThemeProvider";
import "./globals.css";

// Inline script runs synchronously before React hydration to avoid theme flash.
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
      className={`${spaceGrotesk.variable} ${inter.variable} ${jetbrainsMono.variable} h-full antialiased`}
      // Some browser extensions (e.g. Immersive Translate) inject attributes
      // onto <html> before React hydrates, causing a top-level mismatch warning.
      // Suppressing only on <html> is the React/Next recommended workaround.
      suppressHydrationWarning
    >
      <head>
        {/* Prevents theme flash by setting data-theme before first paint */}
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
      </head>
      <body className="min-h-full bg-bg-warm text-fg-primary font-body">
        <ThemeProvider />
        <QueryProvider>{children}</QueryProvider>
      </body>
    </html>
  );
}
