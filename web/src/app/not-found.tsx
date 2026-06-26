import Link from "next/link";

export default function NotFound() {
  return (
    <main className="min-h-screen bg-bg-warm flex items-center justify-center px-6">
      <div className="flex flex-col items-center gap-6 text-center max-w-sm">
        <div
          className="w-12 h-12 rounded-[var(--radius-card)] bg-accent flex items-center justify-center"
          aria-hidden="true"
        >
          <span className="text-white font-display font-bold text-xl leading-none">D</span>
        </div>

        <div className="flex flex-col gap-2">
          <h1
            className="font-display font-bold text-fg-primary"
            style={{ fontSize: "1.5rem", letterSpacing: "-0.01em" }}
          >
            Page not found
          </h1>
          <p className="text-sm text-fg-muted leading-relaxed">
            This page doesn&apos;t exist or has been moved.
          </p>
        </div>

        <div className="flex flex-col gap-3 w-full">
          <Link href="/home" className="btn btn--primary btn--md w-full">
            Go to home
          </Link>
          <Link href="/login" className="btn btn--ghost btn--md w-full">
            Sign in
          </Link>
        </div>
      </div>
    </main>
  );
}
