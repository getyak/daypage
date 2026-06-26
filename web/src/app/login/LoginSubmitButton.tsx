"use client";
import { useFormStatus } from "react-dom";

interface Props {
  children: React.ReactNode;
  kind?: "primary" | "secondary" | "ghost";
  className?: string;
}

function Spinner() {
  return (
    <svg
      className="btn__spinner"
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 16 16"
      aria-hidden="true"
    >
      <circle cx="8" cy="8" r="6" stroke="currentColor" strokeOpacity="0.3" strokeWidth="2" />
      <path d="M14 8a6 6 0 0 0-6-6" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
    </svg>
  );
}

export function LoginSubmitButton({ children, kind = "primary", className = "" }: Props) {
  const { pending } = useFormStatus();
  return (
    <button
      type="submit"
      disabled={pending}
      aria-busy={pending ? "true" : undefined}
      className={`btn btn--${kind} btn--md w-full ${className}`}
    >
      {pending ? <Spinner /> : null}
      {children}
    </button>
  );
}
