"use client";
import { useActionState } from "react";
import { sendMagicLink, type MagicLinkState } from "./actions";

const INITIAL: MagicLinkState = { status: "idle" };

function Spinner() {
  return (
    <svg
      className="btn__spinner"
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 16 16"
      aria-hidden="true"
    >
      <circle
        cx="8"
        cy="8"
        r="6"
        stroke="currentColor"
        strokeOpacity="0.3"
        strokeWidth="2"
      />
      <path
        d="M14 8a6 6 0 0 0-6-6"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
      />
    </svg>
  );
}

function SuccessView({ email, onReset }: { email: string; onReset: () => void }) {
  return (
    <div className="login-success" role="status" aria-live="polite" aria-atomic="true">
      <div className="login-success__icon" aria-hidden="true">
        <svg
          width="32"
          height="32"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <rect x="2" y="4" width="20" height="16" rx="2" />
          <path d="m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7" />
        </svg>
      </div>
      <p className="login-success__title">Check your inbox</p>
      <p className="login-success__body">
        We sent a sign-in link to{" "}
        <strong className="login-success__email">{email}</strong>.
        It expires in 1 hour.
      </p>
      <button
        type="button"
        className="btn btn--ghost btn--sm login-success__back"
        onClick={onReset}
      >
        ← Use a different email
      </button>
    </div>
  );
}

export function EmailSignInForm() {
  const [state, formAction, isPending] = useActionState(sendMagicLink, INITIAL);

  if (state.status === "sent") {
    return (
      <SuccessView
        email={state.email}
        onReset={() => window.location.reload()}
      />
    );
  }

  return (
    <form action={formAction} className="login-email-form" noValidate>
      <div className="login-field">
        <label htmlFor="login-email" className="login-field__label">
          Email address
        </label>
        <input
          id="login-email"
          type="email"
          name="email"
          required
          placeholder="you@example.com"
          aria-invalid={state.status === "error" ? "true" : undefined}
          aria-describedby={state.status === "error" ? "login-email-err" : undefined}
          className="login-input"
          disabled={isPending}
          autoComplete="email"
          suppressHydrationWarning
        />
        {state.status === "error" && (
          <p
            id="login-email-err"
            className="login-field__error"
            role="alert"
            aria-live="assertive"
          >
            {state.message}
          </p>
        )}
      </div>
      <button
        type="submit"
        className="btn btn--secondary btn--md w-full"
        disabled={isPending}
        aria-busy={isPending ? "true" : undefined}
      >
        {isPending && <Spinner />}
        {isPending ? "Sending…" : "Send magic link"}
      </button>
    </form>
  );
}
