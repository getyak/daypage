import { createBrowserClient } from "@supabase/ssr";

// Test-only sibling page. Public SDK calls create the real cookie/BroadcastChannel
// events; no product callback, React/store state or window debug handle is used.
const root = document.documentElement;
const realm = root.dataset.realm, publicKey = root.dataset.publicKey;
if (realm !== location.origin + "/__get443_supabase" ||
    publicKey !== "synthetic-get443-public-key-not-a-credential") throw new Error("synthetic-peer-config");
const client = createBrowserClient(realm, publicKey);
const status = document.querySelector<HTMLOutputElement>("#peer-status");
const eventOutput = document.querySelector<HTMLOutputElement>("#peer-event");
if (!status || !eventOutput) throw new Error("synthetic-peer-markup");
const owners = {
  A: { id: "aaaaaaaa-0000-4000-8000-000000000001", email: "synthetic-a@get443.invalid" },
  B: { id: "bbbbbbbb-0000-4000-8000-000000000002", email: "synthetic-b@get443.invalid" },
} as const;
const { data: { subscription } } = client.auth.onAuthStateChange((event, session) => {
  const owner = session ? session.user.id === owners.A.id ? "A" : session.user.id === owners.B.id ? "B" : "unexpected" : "none";
  eventOutput.textContent = event + ":" + owner;
});
for (const owner of ["A", "B"] as const) {
  const form = document.querySelector<HTMLFormElement>("#sign-in-" + owner);
  if (!form) throw new Error("synthetic-peer-form");
  form.addEventListener("submit", event => {
    event.preventDefault(); status.textContent = "Signing in " + owner;
    void client.auth.signInWithPassword({ email: owners[owner].email, password: "get443-synthetic-fixture-input" })
      .then(({ data, error }) => {
        status.textContent = !error && data.user?.id === owners[owner].id ? "Signed in " + owner : "Synthetic sign-in failed";
      }, () => { status.textContent = "Synthetic sign-in failed"; });
  });
}
const signOut = document.querySelector<HTMLFormElement>("#sign-out");
if (!signOut) throw new Error("synthetic-peer-form");
signOut.addEventListener("submit", event => {
  event.preventDefault(); status.textContent = "Signing out";
  void client.auth.signOut({ scope: "local" }).then(({ error }) => {
    status.textContent = error ? "Synthetic sign-out failed" : "Signed out local session";
  }, () => { status.textContent = "Synthetic sign-out failed"; });
});
window.addEventListener("pagehide", () => subscription.unsubscribe(), { once: true });
