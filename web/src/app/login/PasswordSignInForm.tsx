"use client";
import { useActionState } from "react";
import { passwordSignIn, type PasswordState } from "./actions";

const INITIAL: PasswordState = { status: "idle" };

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

export function PasswordSignInForm({ callbackUrl = "/memos" }: { callbackUrl?: string }) {
  const [state, formAction, isPending] = useActionState(passwordSignIn, INITIAL);
  const errorId = "login-password-err";

  return (
    <form action={formAction} className="login-password-form login-email-form" noValidate>
      <input type="hidden" name="callbackUrl" value={callbackUrl} />
      <div className="login-field">
        <label htmlFor="login-password-email" className="login-field__label">
          Email address
        </label>
        <input
          id="login-password-email"
          type="email"
          name="email"
          required
          placeholder="you@example.com"
          aria-invalid={state.status === "error" ? "true" : undefined}
          aria-describedby={state.status === "error" ? errorId : undefined}
          className="login-input"
          disabled={isPending}
          autoComplete="email"
          suppressHydrationWarning
        />
      </div>
      <div className="login-field">
        <label htmlFor="login-password" className="login-field__label">
          Password
        </label>
        <input
          id="login-password"
          type="password"
          name="password"
          required
          aria-invalid={state.status === "error" ? "true" : undefined}
          aria-describedby={state.status === "error" ? errorId : undefined}
          className="login-input"
          disabled={isPending}
          autoComplete="current-password"
          suppressHydrationWarning
        />
        {state.status === "error" && (
          <p
            id={errorId}
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
        className="btn btn--primary btn--md w-full"
        disabled={isPending}
        aria-busy={isPending ? "true" : undefined}
      >
        {isPending && <Spinner />}
        {isPending ? "Signing in…" : "Sign in"}
      </button>
    </form>
  );
}
