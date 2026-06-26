"use client";
import { useEffect } from "react";
import Link from "next/link";

export default function RootError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error("[Landing error]", error);
  }, [error]);

  return (
    <main className="min-h-screen bg-bg-warm flex items-center justify-center px-6">
      <div className="card w-full max-w-sm flex flex-col gap-5 text-center">
        <div>
          <div
            className="w-10 h-10 rounded-[var(--radius-card)] bg-accent flex items-center justify-center mx-auto mb-4"
            aria-hidden="true"
          >
            <span className="text-white font-display font-bold text-lg leading-none">
              D
            </span>
          </div>
          <h1 className="font-display font-bold text-fg-primary" style={{ fontSize: "1.25rem" }}>
            Something went wrong
          </h1>
          <p className="mt-2 text-sm text-fg-muted">
            We had trouble loading the page. Please try again.
          </p>
        </div>
        <div className="flex flex-col gap-3">
          <button
            onClick={reset}
            className="btn btn--primary btn--md w-full"
          >
            Try again
          </button>
          <Link href="/login" className="btn btn--ghost btn--md w-full">
            Go to sign in
          </Link>
        </div>
      </div>
    </main>
  );
}
