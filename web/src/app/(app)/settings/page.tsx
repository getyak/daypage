import { auth, signOut } from "@/auth";
import { redirect } from "next/navigation";
import { SettingsClient } from "./SettingsClient";

export const metadata = {
  title: "Settings · DayPage",
};

export default async function SettingsPage() {
  const session = await auth();
  if (!session?.user) redirect("/login");

  async function handleSignOut() {
    "use server";
    await signOut({ redirectTo: "/login" });
  }

  return (
    <SettingsClient
      user={{
        name: session.user.name ?? null,
        email: session.user.email ?? null,
        plan: "free",
      }}
      signOutAction={handleSignOut}
    />
  );
}
