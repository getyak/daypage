import { signIn } from "@/auth";
import { EmailSignInForm } from "./EmailSignInForm";
import { LoginSubmitButton } from "./LoginSubmitButton";

export const metadata = {
  title: "Sign in — DayPage",
  description: "Capture anything. AI compiles everything.",
};

const ERROR_MESSAGES: Record<string, string> = {
  OAuthAccountNotLinked:
    "This email is linked to a different sign-in method. Try the other option below.",
  OAuthSignin: "Error connecting to Apple Sign In. Please try again.",
  EmailSignin: "Could not send the magic link. Please try again.",
  Verification: "This link has expired or was already used. Request a new one.",
  AccessDenied: "Your account doesn't have access to DayPage.",
  Configuration: "Server configuration error. Please contact support.",
  Default: "Something went wrong. Please try again.",
};

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string; callbackUrl?: string }>;
}) {
  const { error } = await searchParams;
  const errorMsg = error
    ? (ERROR_MESSAGES[error] ?? ERROR_MESSAGES.Default)
    : null;

  return (
    <div className="login-shell">
      <main className="login-card" role="main" aria-labelledby="login-heading">
        {/* Brand */}
        <div className="login-brand">
          <div className="login-brand__mark" aria-hidden="true">
            <svg
              width="36"
              height="36"
              viewBox="0 0 36 36"
              fill="none"
              xmlns="http://www.w3.org/2000/svg"
            >
              <rect x="1" y="1" width="34" height="34" rx="10" fill="var(--accent)" />
              <path d="M18 8 L28 18 L18 28 L8 18 Z" fill="white" opacity="0.9" />
              <circle cx="18" cy="18" r="4" fill="var(--accent)" />
            </svg>
          </div>
          <div>
            <h1 id="login-heading" className="login-brand__name">
              DayPage
            </h1>
            <p className="login-brand__tagline">
              Capture anything. AI compiles everything.
            </p>
          </div>
        </div>

        {/* Feature highlights */}
        <ul className="login-bullets" aria-label="Key features">
          <li>
            <span className="login-bullet__icon" aria-hidden="true">✦</span>
            Dump notes, photos, voice memos freely
          </li>
          <li>
            <span className="login-bullet__icon" aria-hidden="true">✦</span>
            AI turns your day into a structured diary
          </li>
          <li>
            <span className="login-bullet__icon" aria-hidden="true">✦</span>
            Knowledge graph grows with every entry
          </li>
        </ul>

        <hr className="login-divider" aria-hidden="true" />

        {/* URL-param error banner (from NextAuth callback errors) */}
        {errorMsg && (
          <div role="alert" className="login-error-banner" aria-live="assertive">
            <svg
              width="16"
              height="16"
              viewBox="0 0 16 16"
              fill="none"
              aria-hidden="true"
              style={{ flexShrink: 0, marginTop: 1 }}
            >
              <circle cx="8" cy="8" r="7" stroke="currentColor" strokeWidth="1.5" />
              <path
                d="M8 5v3.5"
                stroke="currentColor"
                strokeWidth="1.5"
                strokeLinecap="round"
              />
              <circle cx="8" cy="11.5" r="0.75" fill="currentColor" />
            </svg>
            <span>{errorMsg}</span>
          </div>
        )}

        {/* Apple sign-in */}
        <form
          action={async () => {
            "use server";
            await signIn("apple", { redirectTo: "/home" });
          }}
        >
          <LoginSubmitButton kind="primary">
            <svg
              width="14"
              height="16"
              viewBox="0 0 814 1000"
              fill="currentColor"
              aria-hidden="true"
              focusable="false"
              style={{ flexShrink: 0 }}
            >
              <path d="M788.1 340.9c-5.8 4.5-108.2 62.2-108.2 190.5 0 148.4 130.3 200.9 134.2 202.2-.6 3.2-20.7 71.9-68.7 141.9-42.8 61.6-87.5 123.1-155.5 123.1s-85.5-39.5-164-39.5c-76.5 0-103.7 40.8-165.9 40.8s-105-37.6-152.8-103.9C119 447.8 93.1 302.2 93.1 263.4c0-137.1 89.2-209.3 176.4-209.3 63.8 0 117 43.1 156.5 43.1 37.5 0 96.8-45.1 171.9-45.1 27.6 0 128 2.6 198.7 99.8zm-234-181.5c31.1-36.9 53.1-88.1 53.1-139.3 0-7.1-.6-14.3-1.9-20.1-50.6 1.9-110.8 33.7-147.1 75.8-28.5 32.4-55.1 83.6-55.1 135.5 0 7.8 1.3 15.6 1.9 18.1 3.2.6 8.4 1.3 13.6 1.3 45.4 0 102.5-30.4 135.5-71.3z" />
            </svg>
            Continue with Apple
          </LoginSubmitButton>
        </form>

        {/* OR divider */}
        <div className="login-or" role="separator" aria-label="or">
          <span aria-hidden="true">or</span>
        </div>

        {/* Email magic link — full state management (loading/success/error) */}
        <EmailSignInForm />

        {/* Dev-only shortcut */}
        {process.env.NODE_ENV === "development" && (
          <form
            action={async (formData) => {
              "use server";
              await signIn("dev", {
                email: formData.get("email") || "dev@daypage.local",
                redirectTo: "/home",
              });
            }}
            className="login-dev"
          >
            <p className="ds-body-sm" style={{ color: "var(--fg-muted)" }}>
              Dev-only (E2E shortcut)
            </p>
            <input
              type="email"
              name="email"
              defaultValue="dev@daypage.local"
              placeholder="dev@daypage.local"
              aria-label="Dev email address"
              className="login-input login-input--sunken"
              suppressHydrationWarning
            />
            <LoginSubmitButton kind="ghost">Dev login (no email)</LoginSubmitButton>
          </form>
        )}

        {/* Privacy footnote */}
        <p className="login-footnote">
          By signing in you agree to our{" "}
          <a href="/privacy" className="login-footnote__link">
            privacy policy
          </a>
          .
        </p>
      </main>
    </div>
  );
}
