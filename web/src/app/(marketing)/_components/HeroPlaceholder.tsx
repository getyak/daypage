export function HeroPlaceholder() {
  return (
    <section className="relative flex min-h-[100svh] items-center justify-center overflow-hidden bg-[color:var(--bg-warm)]">
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 opacity-60"
        style={{
          background:
            "radial-gradient(ellipse 90% 60% at 50% 30%, rgba(93,48,0,0.06), transparent 60%), radial-gradient(ellipse 70% 50% at 70% 80%, rgba(201,166,119,0.10), transparent 60%)",
        }}
      />
      <div className="relative mx-auto max-w-[1100px] px-6 pt-24 text-center lg:px-10">
        <p className="mb-6 inline-flex items-center gap-2 rounded-full border border-[color:var(--border-subtle)] bg-[color:var(--surface-white)]/70 px-3 py-1 text-[12px] font-medium text-[color:var(--fg-subtle-aa)] backdrop-blur">
          <span className="h-1.5 w-1.5 rounded-full bg-[color:var(--accent)]" />
          Now in private beta · iOS
        </p>
        <h1 className="font-serif text-[clamp(48px,8vw,96px)] leading-[1.02] tracking-[-0.025em] text-[color:var(--fg-primary)]">
          Your day,
          <br />
          captured raw.
          <br />
          <em className="font-normal italic text-[color:var(--accent)]">
            Compiled by AI.
          </em>
        </h1>
        <p className="mx-auto mt-8 max-w-[560px] text-[18px] leading-[1.55] text-[color:var(--fg-muted)]">
          Dump voice, text, photos into Today. At 2am, AI compiles your raw
          fragments into a structured diary and a knowledge wiki that grows
          with every day.
        </p>
        <div className="mt-10 flex flex-col items-center justify-center gap-3 sm:flex-row">
          <a
            href="/download"
            className="inline-flex h-12 items-center justify-center rounded-full bg-[color:var(--accent)] px-7 text-[15px] font-medium text-[color:var(--bg-warm)] shadow-[0_8px_24px_-12px_rgba(93,48,0,0.6)] transition-[transform,background-color] duration-200 hover:bg-[color:var(--accent-hover)] active:scale-[0.98]"
          >
            Start your first day →
          </a>
          <a
            href="/manifesto"
            className="inline-flex h-12 items-center justify-center rounded-full border border-[color:var(--border-default)] bg-[color:var(--surface-white)] px-6 text-[15px] font-medium text-[color:var(--fg-primary)] transition-colors hover:border-[color:var(--fg-muted)]"
          >
            Read the manifesto
          </a>
        </div>
        <p className="mt-6 text-[13px] text-[color:var(--fg-subtle-aa)]">
          Free. No account required. Local-first.
        </p>
      </div>

      <div
        aria-hidden
        className="absolute bottom-10 left-1/2 -translate-x-1/2 animate-bounce text-[color:var(--fg-subtle-aa)]"
      >
        <svg width="20" height="20" viewBox="0 0 20 20" fill="none">
          <path
            d="M5 8l5 5 5-5"
            stroke="currentColor"
            strokeWidth="1.5"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      </div>
    </section>
  );
}
