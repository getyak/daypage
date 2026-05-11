// Root → always send users into the authenticated app shell.
// The (app)/layout.tsx guard handles the login redirect for signed-out users.
import { redirect } from "next/navigation";

export default function Root() {
  redirect("/home");
}
