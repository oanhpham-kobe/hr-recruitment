"use client";
import {
  collectionAction,
  consolidateAction,
  createAction,
  invitationAction,
  publishAction,
  respondAction,
  revokeAction,
  workspaceAction,
} from "@/app/interview-feedback/actions";
import type { Detail, Workspace } from "@/lib/interview-feedback/model";
import { errorText, useFeedbackText } from "./FeedbackDetail";
import { InterviewFeedbackView } from "./InterviewFeedbackView";

const api = {
  workspace: workspaceAction,
  collection: collectionAction,
  invitation: invitationAction,
  publish: publishAction,
  create: createAction,
  respond: respondAction,
  revoke: revokeAction,
  consolidate: consolidateAction,
};
export function InterviewFeedbackPage({
  initialData,
  initialDetail,
}: {
  initialData: Workspace;
  initialDetail?: Detail;
}) {
  return (
    <InterviewFeedbackView
      initialData={initialData}
      initialDetail={initialDetail}
      api={api}
    />
  );
}
export function FeedbackError({ code }: { code: string }) {
  const t = useFeedbackText();
  return (
    <section className="feedback-page">
      <h1>{t("Nhận xét phỏng vấn", "Interview feedback")}</h1>
      <p role="alert">{errorText(code, t)}</p>
      <a href="/interview-feedback">{t("Về danh sách", "Back to workspace")}</a>
    </section>
  );
}
