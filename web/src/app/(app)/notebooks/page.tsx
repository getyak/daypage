import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { projectRealm } from "@/lib/file-exchange-local/model";
import { NotebooksClient } from "./NotebooksClient";

export default async function NotebooksPage() {
  const client = await createClient();
  const { data: { user }, error } = await client.auth.getUser();
  if (error || !user) redirect("/login?next=%2Fnotebooks");
  // Only verified identity and public configuration cross the RSC boundary.
  // Selected files and notebook content never leave the Client Component.
  return <NotebooksClient initialUID={user.id} realm={projectRealm(process.env.NEXT_PUBLIC_SUPABASE_URL ?? "")} />;
}
