import type { Metadata, Viewport } from "next";
import { Space_Grotesk, Inter, JetBrains_Mono, Fraunces } from "next/font/google";
import { QueryProvider } from "@/components/QueryProvider";
import { ThemeProvider } from "@/components/ThemeProvider";
import { JsonLd } from "@/components/JsonLd";
import {
  BRAND,
  OG_IMAGE,
  SITE_DESCRIPTION,
  SITE_KEYWORDS,
  SITE_NAME,
  SITE_TAGLINE,
  SITE_URL,
  SOCIAL,
} from "@/lib/seo";
import "./globals.css";

// Inline script runs synchronously before React hydration to avoid theme flash.
// In Next.js 16 / React 19 App Router, a raw <script dangerouslySetInnerHTML>
// in <head> is hoisted into the SSR HTML stream and executed by the browser
// parser before hydration. (next/script `beforeInteractive` rendered as a React
// child throws "Scripts inside React components are never executed…" here.)
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
  weight: ["400", "600"],
  style: ["normal", "italic"],
  display: "swap",
  preload: true,
});

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: {
    default: `${SITE_NAME} — ${SITE_TAGLINE}`,
    template: `%s · ${SITE_NAME}`,
  },
  description: SITE_DESCRIPTION,
  applicationName: SITE_NAME,
  keywords: SITE_KEYWORDS,
  authors: [{ name: SITE_NAME, url: SITE_URL }],
  creator: SITE_NAME,
  publisher: SITE_NAME,
  category: "productivity",
  alternates: {
    canonical: "/",
    languages: {
      en: "/",
      "zh-CN": "/zh",
      "x-default": "/",
    },
  },
  openGraph: {
    type: "website",
    siteName: SITE_NAME,
    title: `${SITE_NAME} — ${SITE_TAGLINE}`,
    description: SITE_DESCRIPTION,
    url: SITE_URL,
    locale: "en_US",
    alternateLocale: ["zh_CN"],
    images: [
      {
        url: "/opengraph-image.png",
        width: OG_IMAGE.width,
        height: OG_IMAGE.height,
        alt: OG_IMAGE.alt,
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: `${SITE_NAME} — ${SITE_TAGLINE}`,
    description: SITE_DESCRIPTION,
    site: SOCIAL.twitter,
    creator: SOCIAL.twitter,
    images: ["/opengraph-image.png"],
  },
  robots: {
    index: true,
    follow: true,
    nocache: false,
    googleBot: {
      index: true,
      follow: true,
      "max-snippet": -1,
      "max-image-preview": "large",
      "max-video-preview": -1,
    },
  },
  icons: {
    icon: [{ url: "/icon", type: "image/png", sizes: "32x32" }],
    apple: [{ url: "/apple-icon", sizes: "180x180", type: "image/png" }],
  },
  manifest: "/manifest.webmanifest",
  formatDetection: {
    email: false,
    address: false,
    telephone: false,
  },
  other: {
    "apple-mobile-web-app-capable": "yes",
    "apple-mobile-web-app-status-bar-style": "default",
    "apple-mobile-web-app-title": SITE_NAME,
  },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  maximumScale: 5,
  viewportFit: "cover",
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: BRAND.background },
    { media: "(prefers-color-scheme: dark)", color: BRAND.ink },
  ],
  colorScheme: "light dark",
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
            A raw <script> in <head> is emitted into the SSR HTML stream and run
            synchronously by the browser parser, before React hydrates. */}
        <script
          id="theme-no-flash"
          dangerouslySetInnerHTML={{ __html: themeScript }}
        />
        <JsonLd />
      </head>
      <body className="min-h-full bg-bg-warm text-fg-primary font-body">
        <a
          href="#main"
          className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-[100] focus:rounded-full focus:bg-[color:var(--fg-primary)] focus:px-4 focus:py-2 focus:text-[13px] focus:font-medium focus:text-[color:var(--bg-warm)]"
        >
          Skip to content
        </a>
        <ThemeProvider />
        <QueryProvider>{children}</QueryProvider>
      </body>
    </html>
  );
}
