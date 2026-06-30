import { auth } from "@/lib/auth/session";
import { NavClient } from "./NavClient";

type Props = { lang?: "en" | "zh" };

// Server wrapper: resolves the Supabase user once per request and hands it to
// the client nav. Keeps the import surface (`<Nav />`) unchanged for every
// caller. Lang prop lets the Chinese landing render Chinese labels without
// duplicating the whole nav.
export async function Nav({ lang = "en" }: Props) {
  const session = await auth().catch(() => null);
  return <NavClient user={session?.user ?? null} lang={lang} />;
}
