"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

interface NewButtonProps {
  kind?: "primary" | "soft" | "ghost";
  label?: string;
}

function NewButton({ kind = "soft", label = "New" }: NewButtonProps) {
  const router = useRouter();
  const [loading, setLoading] = useState(false);

  async function handleNew() {
    setLoading(true);
    try {
      const res = await fetch("/api/chat/threads", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({}),
      });
      if (res.ok) {
        const thread = (await res.json()) as { id: string };
        router.push(`/chat/${thread.id}`);
        router.refresh();
      }
    } catch {
      // ignore
    } finally {
      setLoading(false);
    }
  }

  return (
    <button
      type="button"
      className={`btn btn--${kind} btn--sm`}
      onClick={handleNew}
      disabled={loading}
    >
      {loading ? "…" : label}
    </button>
  );
}

export const ThreadList = { NewButton };
