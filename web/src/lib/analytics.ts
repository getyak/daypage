type EventPayload = Record<string, unknown>;

export function sendEvent(name: string, payload?: EventPayload): void {
  if (process.env.NODE_ENV === "development") return;

  try {
    void fetch("/api/analytics", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name, ...payload }),
      keepalive: true,
    });
  } catch {
    // best-effort
  }
}
