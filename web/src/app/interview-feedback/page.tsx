import { redirect } from "next/navigation";
import {
  FeedbackError,
  InterviewFeedbackPage,
} from "@/components/interview-feedback/InterviewFeedbackPage";
import { loadFeedbackWorkspace } from "@/lib/interview-feedback/server";
import "@/styles/interview-feedback.css";
export const dynamic = "force-dynamic";
export default async function Page() {
  const result = await loadFeedbackWorkspace();
  if (!result.success) {
    if (result.error.code === "UNAUTHENTICATED")
      redirect("/login?persona=internal&next=%2Finterview-feedback");
    return <FeedbackError code={result.error.code} />;
  }
  return <InterviewFeedbackPage initialData={result.data} />;
}
