import type { Metadata } from "next";
import { auth, signIn } from "@/auth";
import { redirect } from "next/navigation";
import { BookOpen, Sparkles, Network } from "lucide-react";
import { LoginSubmitButton } from "./login/LoginSubmitButton";

export const metadata: Metadata = {
  title: "DayPage — Your personal AI knowledge system",
  description:
    "Capture freely. AI compiles your daily notes into structured diary entries and a living knowledge network.",
};

async function getSession() {
  try {
    return await auth();
  } catch {
    return null;
  }
}

const ERROR_MESSAGES: Record<string, string> = {
  OAuthAccountNotLinked:
    "This email is linked to a different sign-in method. Try the other option.",
  OAuthSignin: "Error connecting to Apple Sign In. Please try again.",
  EmailSignin: "Could not send the magic link. Please try again.",
  Verification: "This link has expired or was already used. Request a new one.",
  AccessDenied: "Your account doesn't have access to DayPage.",
  Default: "Something went wrong. Please try again.",
};

const APPLE_SVG = (
  <svg
    width="14"
    height="16"
    viewBox="0 0 814 1000"
    fill="currentColor"
    aria-hidden="true"
    style={{ flexShrink: 0 }}
  >
    <path d="M788.1 340.9c-5.8 4.5-108.2 62.2-108.2 190.5 0 148.4 130.3 200.9 134.2 202.2-.6 3.2-20.7 71.9-68.7 141.9-42.8 61.6-87.5 123.1-155.5 123.1s-85.5-39.3-164-39.3c-76.5 0-103.7 40.8-165.9 40.8s-105.5-41-148.2-128.2c-49.5-101.2-75.2-290.9-75.2-378.4 0-178.4 116.9-272.5 231.7-272.5 61.4 0 112.6 40.4 151.8 40.4 37.5 0 96.7-41.9 162.5-41.9zm-90.5-166.8c34.5-39.5 60.9-94.1 60.9-148.6 0-7.6-.9-15.2-2.4-22.1-57 2.2-124.3 38.3-165.9 88.3-32 36.5-62.8 95-62.8 150.6 0 8.7 1.4 17.1 2.1 19.8 3.6.6 8.7 1.4 13.7 1.4 52.1 0 117.2-34.6 154.4-89.4z" />
  </svg>
);

export default async function LandingPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const session = await getSession();
  if (session?.user) redirect("/home");

  const { error } = await searchParams;
  const errorMsg = error ? (ERROR_MESSAGES[error] ?? ERROR_MESSAGES.Default) : null;

  return (
    <main className="min-h-screen bg-bg-warm">
      {/* Skip to sign-in for keyboard users */}
      <a
        href="#auth-section"
        className="sr-only focus:not-sr-only focus:fixed focus:top-4 focus:left-4 focus:z-50 btn btn--primary btn--sm"
      >
        Skip to sign in
      </a>

      <div className="min-h-screen flex flex-col lg:flex-row">
        {/* ── Hero ──────────────────────────────────────────────── */}
        <section
          aria-labelledby="hero-heading"
          className="flex flex-col justify-center px-8 py-16 lg:flex-1 lg:px-16 xl:px-24 landing-fade-in"
        >
          <div className="max-w-lg">
            {/* Brand */}
            <div className="flex items-center gap-3 mb-10">
              <div
                className="landing-logo-mark w-9 h-9 rounded-[var(--radius-card)] bg-accent flex items-center justify-center flex-shrink-0"
                aria-hidden="true"
              >
                <span className="text-white font-display font-bold text-base leading-none select-none">
                  D
                </span>
              </div>
              <span
                className="font-display font-bold text-fg-primary"
                style={{ fontSize: "1.25rem", letterSpacing: "-0.01em" }}
              >
                DayPage
              </span>
            </div>

            <h1
              id="hero-heading"
              className="font-display font-bold text-fg-primary"
              style={{
                fontSize: "clamp(2.25rem, 4vw, 3.25rem)",
                lineHeight: 1.1,
                letterSpacing: "-0.02em",
              }}
            >
              Your thoughts,
              <br />
              compiled by AI.
            </h1>

            <p
              className="mt-4 text-fg-muted leading-relaxed max-w-md"
              style={{ fontSize: "1.0625rem" }}
            >
              Capture raw notes throughout the day. DayPage&apos;s AI turns them
              into structured diary entries and a living knowledge graph —
              automatically.
            </p>

            <ul
              aria-label="Key features"
              className="mt-10 flex flex-col gap-5 landing-fade-in--delayed"
            >
              {[
                {
                  icon: BookOpen,
                  label: "Capture freely",
                  desc: "Text, voice, photos — any format, any time",
                },
                {
                  icon: Sparkles,
                  label: "AI compiles daily",
                  desc: "Structured diary entries generated each morning",
                },
                {
                  icon: Network,
                  label: "Knowledge network",
                  desc: "Entities and themes connected automatically",
                },
              ].map(({ icon: Icon, label, desc }) => (
                <li key={label} className="landing-feature">
                  <div className="landing-feature__icon" aria-hidden="true">
                    <Icon size={16} />
                  </div>
                  <div>
                    <div className="text-sm font-semibold text-fg-primary">{label}</div>
                    <div className="text-xs text-fg-muted mt-0.5">{desc}</div>
                  </div>
                </li>
              ))}
            </ul>
          </div>
        </section>

        {/* ── Auth card ─────────────────────────────────────────── */}
        <section
          id="auth-section"
          aria-label="Sign in to DayPage"
          className="flex items-center justify-center px-6 pb-16 pt-8 lg:pb-0 lg:pt-0 lg:px-16 lg:w-[480px] lg:border-l lg:border-border-subtle landing-fade-in--card"
        >
          <div
            className="card landing-auth-card w-full max-w-sm flex flex-col gap-5"
            style={{ boxShadow: "var(--shadow-composer)", padding: "24px" }}
          >
            {/* Card header */}
            <div className="flex flex-col gap-1">
              <h2
                className="font-display font-bold text-fg-primary"
                style={{ fontSize: "1.25rem", letterSpacing: "-0.01em" }}
              >
                Get started
              </h2>
              <p className="text-sm text-fg-muted">
                Sign in with Apple ID or email — no password required.
              </p>
            </div>

            {/* Error banner */}
            {errorMsg && (
              <div
                role="alert"
                aria-live="assertive"
                className="login-error-banner"
              >
                <svg
                  width="16"
                  height="16"
                  viewBox="0 0 16 16"
                  fill="none"
                  aria-hidden="true"
                  style={{ flexShrink: 0, marginTop: 1 }}
                >
                  <circle cx="8" cy="8" r="7" stroke="currentColor" strokeWidth="1.5" />
                  <path d="M8 5v3.5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
                  <circle cx="8" cy="11.5" r="0.75" fill="currentColor" />
                </svg>
                <span>{errorMsg}</span>
              </div>
            )}

            {/* Apple */}
            <form
              action={async () => {
                "use server";
                await signIn("apple", { redirectTo: "/home" });
              }}
            >
              <LoginSubmitButton kind="primary">
                {APPLE_SVG}
                Sign in with Apple
              </LoginSubmitButton>
            </form>

            {/* Divider */}
            <div className="login-divider" aria-hidden="true">or</div>

            {/* Magic link */}
            <form
              action={async (formData) => {
                "use server";
                await signIn("nodemailer", {
                  email: formData.get("email"),
                  redirectTo: "/home",
                });
              }}
              className="flex flex-col gap-3"
            >
              <div>
                <label
                  htmlFor="landing-email"
                  className="block text-sm font-medium text-fg-primary mb-1.5"
                >
                  Email address
                </label>
                <input
                  id="landing-email"
                  type="email"
                  name="email"
                  required
                  placeholder="your@email.com"
                  autoComplete="email"
                  className="w-full px-3 py-2 rounded-[var(--radius-sm)] border border-accent-border bg-surface-white text-fg-primary text-sm outline-none focus:ring-2 focus:ring-accent/30 transition-all placeholder:text-fg-subtle"
                  suppressHydrationWarning
                />
              </div>
              <LoginSubmitButton kind="secondary">Send magic link</LoginSubmitButton>
            </form>

            {/* Trust signal */}
            <p className="text-xs text-center text-fg-subtle pt-1">
              No credit card needed. Your data stays private.
            </p>
          </div>
        </section>
      </div>
    </main>
  );
}
