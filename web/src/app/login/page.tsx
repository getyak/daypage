import { signIn } from "@/auth";
import { LoginSubmitButton } from "./LoginSubmitButton";

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
    <div className="min-h-screen bg-bg-warm flex items-center justify-center px-4 py-12">
      <div className="card w-full max-w-sm flex flex-col gap-6">
        {/* ── Header ── */}
        <div className="flex flex-col gap-1.5">
          <div
            className="w-8 h-8 rounded-[var(--radius-small)] bg-accent flex items-center justify-center mb-2"
            aria-hidden="true"
          >
            <span className="text-white font-display font-bold text-sm leading-none">D</span>
          </div>
          <h1 className="ds-h1">DayPage</h1>
          <p className="ds-body-md text-fg-muted">Your personal AI knowledge system</p>
        </div>

        {/* ── Error banner ── */}
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
              <path d="M8 5v3.5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
              <circle cx="8" cy="11.5" r="0.75" fill="currentColor" />
            </svg>
            <span>{errorMsg}</span>
          </div>
        )}

        {/* ── Apple sign-in ── */}
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
              style={{ flexShrink: 0 }}
            >
              <path d="M788.1 340.9c-5.8 4.5-108.2 62.2-108.2 190.5 0 148.4 130.3 200.9 134.2 202.2-.6 3.2-20.7 71.9-68.7 141.9-42.8 61.6-87.5 123.1-155.5 123.1s-85.5-39.3-164-39.3c-76.5 0-103.7 40.8-165.9 40.8s-105.5-41-148.2-128.2c-49.5-101.2-75.2-290.9-75.2-378.4 0-178.4 116.9-272.5 231.7-272.5 61.4 0 112.6 40.4 151.8 40.4 37.5 0 96.7-41.9 162.5-41.9zm-90.5-166.8c34.5-39.5 60.9-94.1 60.9-148.6 0-7.6-.9-15.2-2.4-22.1-57 2.2-124.3 38.3-165.9 88.3-32 36.5-62.8 95-62.8 150.6 0 8.7 1.4 17.1 2.1 19.8 3.6.6 8.7 1.4 13.7 1.4 52.1 0 117.2-34.6 154.4-89.4z" />
            </svg>
            Sign in with Apple
          </LoginSubmitButton>
        </form>

        {/* ── Divider ── */}
        <div className="login-divider" aria-hidden="true">or</div>

        {/* ── Magic link ── */}
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
              htmlFor="login-email"
              className="block text-sm font-medium text-fg-primary mb-1.5"
            >
              Email address
            </label>
            <input
              id="login-email"
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

        {/* ── Dev shortcut ── */}
        {process.env.NODE_ENV === "development" && (
          <form
            action={async (formData) => {
              "use server";
              await signIn("dev", {
                email: formData.get("email") || "dev@daypage.local",
                redirectTo: "/home",
              });
            }}
            className="flex flex-col gap-3 pt-4 border-t border-dashed border-accent-border"
          >
            <p className="ds-body-sm text-fg-muted">Dev-only (E2E shortcut)</p>
            <input
              type="email"
              name="email"
              defaultValue="dev@daypage.local"
              placeholder="dev@daypage.local"
              aria-label="Dev email address"
              className="w-full px-3 py-2 rounded-[var(--radius-sm)] border border-accent-border bg-surface-sunken text-fg-primary text-sm outline-none"
              suppressHydrationWarning
            />
            <LoginSubmitButton kind="ghost">Dev login (no email)</LoginSubmitButton>
          </form>
        )}
      </div>
    </div>
  );
}
