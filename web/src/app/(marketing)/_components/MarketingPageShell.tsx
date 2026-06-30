import type { ReactNode } from "react";
import { Footer } from "./Footer";
import { Nav } from "./Nav";

type Props = {
  eyebrow?: string;
  title: string;
  lede?: string;
  lang?: "en" | "zh";
  children: ReactNode;
};

export async function MarketingPageShell({
  eyebrow,
  title,
  lede,
  lang = "en",
  children,
}: Props) {
  return (
    <main
      id="main"
      className="relative min-h-screen bg-[color:var(--bg-warm)]"
    >
      <Nav lang={lang} />
      <header className="mx-auto max-w-[820px] px-6 pb-12 pt-32 lg:px-10 lg:pt-40">
        {eyebrow ? (
          <p className="mb-5 text-[12px] font-medium uppercase tracking-[0.14em] text-[color:var(--accent)]">
            {eyebrow}
          </p>
        ) : null}
        <h1 className="font-serif text-[clamp(40px,6vw,68px)] leading-[1.05] tracking-[-0.025em] text-[color:var(--fg-primary)]">
          {title}
        </h1>
        {lede ? (
          <p className="mt-6 max-w-[640px] text-[18px] leading-[1.6] text-[color:var(--fg-muted)]">
            {lede}
          </p>
        ) : null}
      </header>
      <article className="mx-auto max-w-[720px] px-6 pb-32 text-[16px] leading-[1.75] text-[color:var(--fg-primary)] lg:px-10 [&_h2]:mt-14 [&_h2]:font-serif [&_h2]:text-[28px] [&_h2]:tracking-[-0.01em] [&_h2]:text-[color:var(--fg-primary)] [&_h3]:mt-10 [&_h3]:font-serif [&_h3]:text-[20px] [&_p]:mt-5 [&_p]:text-[color:var(--fg-muted)] [&_ul]:mt-5 [&_ul]:list-disc [&_ul]:pl-6 [&_ul]:text-[color:var(--fg-muted)] [&_li]:mt-2 [&_a]:text-[color:var(--accent)] [&_a]:underline-offset-4 hover:[&_a]:underline">
        {children}
      </article>
      <Footer lang={lang} />
    </main>
  );
}
