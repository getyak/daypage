type Tone = "warm" | "dark" | "sunken";

const TONE_CLASSES: Record<Tone, string> = {
  warm: "bg-[color:var(--bg-warm)] text-[color:var(--fg-primary)]",
  dark: "bg-[color:var(--fg-primary)] text-[color:var(--bg-warm)]",
  sunken: "bg-[color:var(--surface-sunken)] text-[color:var(--fg-primary)]",
};

interface PlaceholderProps {
  id: string;
  label: string;
  title: string;
  body: string;
  tone?: Tone;
  minHeight?: string;
}

export function PlaceholderSection({
  id,
  label,
  title,
  body,
  tone = "warm",
  minHeight = "min-h-[100svh]",
}: PlaceholderProps) {
  const isDark = tone === "dark";
  return (
    <section
      id={id}
      className={`relative flex ${minHeight} items-center ${TONE_CLASSES[tone]}`}
    >
      <div className="mx-auto w-full max-w-[1100px] px-6 py-32 lg:px-10">
        <p
          className={`mb-6 text-[12px] font-semibold uppercase tracking-[0.12em] ${
            isDark
              ? "text-[color:var(--surface-sunken)]/60"
              : "text-[color:var(--fg-subtle-aa)]"
          }`}
        >
          {label}
        </p>
        <h2
          className={`max-w-[820px] font-serif text-[clamp(36px,5.5vw,68px)] leading-[1.05] tracking-[-0.02em] ${
            isDark ? "text-[color:var(--bg-warm)]" : ""
          }`}
        >
          {title}
        </h2>
        <p
          className={`mt-8 max-w-[620px] text-[18px] leading-[1.6] ${
            isDark
              ? "text-[color:var(--surface-sunken)]/80"
              : "text-[color:var(--fg-muted)]"
          }`}
        >
          {body}
        </p>
      </div>
    </section>
  );
}
