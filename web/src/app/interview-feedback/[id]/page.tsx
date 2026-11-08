import { redirect } from "next/navigation";
import {
  FeedbackError,
  InterviewFeedbackPage,
} from "@/components/interview-feedback/InterviewFeedbackPage";
import { EMPTY_WORKSPACE } from "@/lib/interview-feedback/model";
import { loadFeedbackInvitation } from "@/lib/interview-feedback/server";
import "@/styles/interview-feedback.css";
export const dynamic = "force-dynamic";
export default async function Page({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const result = await loadFeedbackInvitation(id);
  if (!result.success) {
    if (result.error.code === "UNAUTHENTICATED")
      redirect(
        `/login?persona=internal&next=${encodeURIComponent(`/interview-feedback/${id}`)}`,
      );
    return <FeedbackError code={result.error.code} />;
  }
  return (
    <InterviewFeedbackPage
      initialData={EMPTY_WORKSPACE}
      initialDetail={result.data}
    />
  );
}
