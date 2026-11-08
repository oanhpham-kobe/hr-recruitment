import { redirect } from "next/navigation";

export default function AuthCandidatePage() {
  redirect("/login?persona=candidate");
}
