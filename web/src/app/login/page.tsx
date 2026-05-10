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

        <form className="flex flex-col gap-3">
          <input
            type="email"
            name="email"
            placeholder="your@email.com"
            className="w-full px-3 py-2 rounded-[var(--radius-sm)] border border-accent-border bg-surface-white text-fg-primary text-sm outline-none focus:ring-2 focus:ring-accent/30"
          />
          <button type="submit" className="btn btn--secondary btn--md w-full">
            Send magic link
          </button>
        </form>
      </div>
    </div>
  );
}
