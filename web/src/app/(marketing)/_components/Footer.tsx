import Link from "next/link";

type Lang = "en" | "zh";
type Props = { lang?: Lang };

type Column = {
  title: string;
  links: { href: string; label: string; external?: boolean }[];
};

const EN_COLUMNS: Column[] = [
  {
    title: "Product",
    links: [
      { href: "#capture", label: "Capture" },
      { href: "#compile", label: "Compile" },
      { href: "#wiki", label: "Wiki" },
      { href: "/download", label: "Download" },
    ],
  },
  {
    title: "Resources",
    links: [
      { href: "/manifesto", label: "Manifesto" },
      { href: "/faq", label: "FAQ" },
      { href: "/changelog", label: "Changelog" },
      { href: "https://github.com/getyak/daypage", label: "GitHub", external: true },
    ],
  },
  {
    title: "Company",
    links: [
      { href: "/about", label: "About" },
      { href: "mailto:hello@daypage.app", label: "Contact", external: true },
    ],
  },
  {
    title: "Legal",
    links: [
      { href: "/privacy", label: "Privacy" },
      { href: "/terms", label: "Terms" },
    ],
  },
];

const ZH_COLUMNS: Column[] = [
  {
    title: "产品",
    links: [
      { href: "#capture", label: "捕捉" },
      { href: "#compile", label: "编译" },
      { href: "#wiki", label: "Wiki" },
      { href: "/zh/download", label: "下载" },
    ],
  },
  {
    title: "资源",
    links: [
      { href: "/zh/manifesto", label: "宣言" },
      { href: "/zh/faq", label: "常见问题" },
      { href: "/zh/changelog", label: "更新日志" },
      { href: "https://github.com/getyak/daypage", label: "GitHub", external: true },
    ],
  },
  {
    title: "公司",
    links: [
      { href: "/zh/about", label: "关于" },
      { href: "mailto:hello@daypage.app", label: "联系", external: true },
    ],
  },
  {
    title: "法务",
    links: [
      { href: "/zh/privacy", label: "隐私" },
      { href: "/zh/terms", label: "服务条款" },
    ],
  },
];

const COPY = {
  en: {
    tagline: "Your day, captured raw. Compiled by AI.",
    made: "© 2026 DayPage. Made for nomads who want to remember.",
    langLabel: "Language",
    other: "中文",
    otherHref: "/zh",
    otherHrefLang: "zh-CN",
  },
  zh: {
    tagline: "你的一天,先记下,AI 再整理。",
    made: "© 2026 DayPage。给想记得的数字游民。",
    langLabel: "语言",
    other: "English",
    otherHref: "/",
    otherHrefLang: "en",
  },
} as const;

export function Footer({ lang = "en" }: Props) {
  const columns = lang === "zh" ? ZH_COLUMNS : EN_COLUMNS;
  const c = COPY[lang];
  const homeHref = lang === "zh" ? "/zh" : "/";

  return (
    <footer className="border-t border-[color:var(--border-subtle)] bg-[color:var(--surface-sunken)]">
      <div className="mx-auto max-w-[1440px] px-6 py-20 lg:px-10">
        <div className="grid grid-cols-2 gap-10 md:grid-cols-5">
          <div className="col-span-2 md:col-span-1">
            <Link
              href={homeHref}
              className="inline-flex items-center gap-2 font-serif text-[22px] tracking-[-0.01em] text-[color:var(--fg-primary)]"
            >
              <span
                aria-hidden
                className="inline-flex h-7 w-7 items-center justify-center rounded-lg bg-[color:var(--accent)] text-[13px] font-bold text-[color:var(--bg-warm)]"
                style={{ fontFamily: "var(--font-fraunces), serif" }}
              >
                D
              </span>
              DayPage
            </Link>
            <p className="mt-3 max-w-[220px] text-[13px] leading-relaxed text-[color:var(--fg-muted)]">
              {c.tagline}
            </p>

            {/* Language picker — explicit, not just an arrow */}
            <div className="mt-6">
              <p className="text-[11px] font-semibold uppercase tracking-[0.1em] text-[color:var(--fg-subtle-aa)]">
                {c.langLabel}
              </p>
              <Link
                href={c.otherHref}
                hrefLang={c.otherHrefLang}
                prefetch={false}
                className="mt-2 inline-flex items-center gap-1.5 rounded-full border border-[color:var(--border-subtle)] bg-[color:var(--surface-white)] px-3 py-1.5 text-[12px] font-medium text-[color:var(--fg-muted)] transition-colors hover:border-[color:var(--border-default)] hover:text-[color:var(--fg-primary)]"
              >
                <span aria-hidden>↻</span>
                {c.other}
              </Link>
            </div>
          </div>

          {columns.map((col) => (
            <div key={col.title}>
              <h4 className="text-[12px] font-semibold uppercase tracking-[0.08em] text-[color:var(--fg-subtle-aa)]">
                {col.title}
              </h4>
              <ul className="mt-4 space-y-2.5">
                {col.links.map((link) => (
                  <li key={link.href}>
                    <Link
                      href={link.href}
                      {...(link.external
                        ? { rel: "noopener noreferrer", target: link.href.startsWith("http") ? "_blank" : undefined }
                        : {})}
                      className="text-[14px] text-[color:var(--fg-muted)] transition-colors hover:text-[color:var(--fg-primary)]"
                    >
                      {link.label}
                    </Link>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>

        <div className="mt-16 flex flex-col items-start justify-between gap-4 border-t border-[color:var(--border-subtle)] pt-8 md:flex-row md:items-center">
          <p className="text-[12px] text-[color:var(--fg-subtle-aa)]">{c.made}</p>
          <div className="flex items-center gap-4 text-[12px] text-[color:var(--fg-subtle-aa)]">
            <Link
              href="https://github.com/getyak/daypage"
              aria-label="GitHub"
              target="_blank"
              rel="noopener noreferrer"
            >
              GitHub
            </Link>
            <span>·</span>
            <span>v0.5</span>
          </div>
        </div>
      </div>
    </footer>
  );
}
