import Link from "next/link";

const COLUMNS = [
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
      { href: "/changelog", label: "Changelog" },
      { href: "https://github.com/getyak/daypage", label: "GitHub" },
    ],
  },
  {
    title: "Company",
    links: [
      { href: "/about", label: "About" },
      { href: "mailto:hello@daypage.app", label: "Contact" },
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

export function Footer() {
  const year = 2026;

  return (
    <footer className="border-t border-[color:var(--border-subtle)] bg-[color:var(--surface-sunken)]">
      <div className="mx-auto max-w-[1280px] px-6 py-20 lg:px-10">
        <div className="grid grid-cols-2 gap-10 md:grid-cols-5">
          <div className="col-span-2 md:col-span-1">
            <Link
              href="/"
              className="font-serif text-[22px] tracking-[-0.01em] text-[color:var(--fg-primary)]"
            >
              DayPage
            </Link>
            <p className="mt-3 max-w-[220px] text-[13px] leading-relaxed text-[color:var(--fg-muted)]">
              Your day, captured raw. Compiled by AI.
            </p>
          </div>

          {COLUMNS.map((col) => (
            <div key={col.title}>
              <h4 className="text-[12px] font-semibold uppercase tracking-[0.08em] text-[color:var(--fg-subtle-aa)]">
                {col.title}
              </h4>
              <ul className="mt-4 space-y-2.5">
                {col.links.map((link) => (
                  <li key={link.href}>
                    <Link
                      href={link.href}
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
          <p className="text-[12px] text-[color:var(--fg-subtle-aa)]">
            © {year} DayPage. Made for nomads who want to remember.
          </p>
          <div className="flex items-center gap-4 text-[12px] text-[color:var(--fg-subtle-aa)]">
            <Link href="https://github.com/getyak/daypage" aria-label="GitHub">
              GitHub
            </Link>
            <span>·</span>
            <span>v0.1</span>
          </div>
        </div>
      </div>
    </footer>
  );
}
