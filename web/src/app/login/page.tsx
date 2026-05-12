import { signIn } from "@/auth";

export default function LoginPage() {
  return (
    <div className="min-h-screen bg-bg-warm flex items-center justify-center">
      <div className="card w-full max-w-sm flex flex-col gap-6">
        <div className="flex flex-col gap-1">
          <h1 className="ds-h1">DayPage</h1>
          <p className="ds-body-md text-fg-muted">Your personal AI knowledge system</p>
        </div>

        <form
          action={async () => {
            "use server";
            await signIn("apple", { redirectTo: "/home" });
          }}
        >
          <button
            type="submit"
            className="btn btn--primary btn--md w-full"
          >
            Sign in with Apple
          </button>
        </form>

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
          <input
            type="email"
            name="email"
            required
            placeholder="your@email.com"
            aria-label="Email address"
            className="w-full px-3 py-2 rounded-[var(--radius-sm)] border border-accent-border bg-surface-white text-fg-primary text-sm outline-none focus:ring-2 focus:ring-accent/30"
            suppressHydrationWarning
          />
          <button type="submit" className="btn btn--secondary btn--md w-full">
            Send magic link
          </button>
        </form>

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
            <button
              type="submit"
              className="btn btn--ghost btn--md w-full"
              style={{ borderStyle: "dashed" }}
            >
              Dev login (no email)
            </button>
          </form>
        )}
      </div>
    </div>
  );
}
