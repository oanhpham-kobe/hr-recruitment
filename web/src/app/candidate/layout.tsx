import "server-only";
import { redirect } from "next/navigation";
import { provisionCandidateIdentity } from "@/lib/auth/candidate";
import { createServerClient } from "@/lib/supabase/server";

export default async function CandidateLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const supabase = await createServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/auth/candidate");
  }

  const identityRes = await provisionCandidateIdentity(supabase);
  if (!identityRes.success || !identityRes.data?.is_active) {
    redirect("/auth/candidate");
  }

  return <>{children}</>;
}
