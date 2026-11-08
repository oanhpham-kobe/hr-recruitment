import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import { type AppSession, getServerSession } from "@/lib/auth/session";
import { createServerClient } from "@/lib/supabase/server";
import type {
  Collection,
  Consolidation,
  ConsolidationInput,
  CreateInput,
  Detail,
  Invitation,
  OwnDetail,
  PublishInput,
  ResponseInput,
  Result,
  Template,
  Workspace,
} from "./model";
import { validRpcData } from "./validation";
export interface FeedbackDeps {
  client?: SupabaseClient;
  resolveSession?: (client: SupabaseClient) => Promise<AppSession>;
}
const uuid = (v: unknown): v is string =>
  typeof v === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    v,
  );
const version = (v: unknown, zero = false) =>
  Number.isSafeInteger(v) && Number(v) >= (zero ? 0 : 1);
const text = (v: unknown, max: number, required = false): v is string =>
  typeof v === "string" &&
  v.length <= max &&
  (!required || v.trim().length > 0);
const failure = <T>(code: string): Result<T> => ({
  success: false,
  error: { code },
});
export function canManageFeedback(session: AppSession) {
  return Boolean(
    session.user?.isInternal &&
      (session.user.roles.includes("ROOT_ADMIN") ||
        (session.user.permissions.includes("interviews.manage") &&
          session.user.permissions.includes("reports.view"))),
  );
}
async function rpc<T>(
  name: string,
  args: Record<string, unknown>,
  manage: boolean,
  deps: FeedbackDeps,
): Promise<Result<T>> {
  try {
    const client = deps.client ?? (await createServerClient());
    const session = await (deps.resolveSession ?? getServerSession)(client);
    if (!session.user) return failure("UNAUTHENTICATED");
    if (!session.user.isInternal || (manage && !canManageFeedback(session)))
      return failure("FORBIDDEN");
    const { data, error } = await client.rpc(name, args);
    if (error || !data || typeof data !== "object")
      return failure("COMMAND_FAILED");
    if (data.success === true)
      return validRpcData(name, data.data)
        ? { success: true, data: data.data as T }
        : failure("INVALID_RESPONSE");
    const allowed = [
      "UNAUTHENTICATED",
      "FORBIDDEN",
      "NOT_FOUND",
      "VALIDATION_ERROR",
      "STALE_VERSION",
      "CONTEXT_NOT_WRITABLE",
      "DEADLINE_PASSED",
      "REQUIRED_ANSWER_MISSING",
      "ALREADY_SUBMITTED",
      "INVITATION_REVOKED",
      "COMPLETENESS_REQUIRED",
      "ALREADY_APPROVED",
    ];
    return failure(
      allowed.includes(data.error_code) ? data.error_code : "COMMAND_FAILED",
    );
  } catch {
    return failure("COMMAND_FAILED");
  }
}
export function loadFeedbackWorkspace(
  offset = 0,
  deps: FeedbackDeps = {},
): Promise<Result<Workspace>> {
  if (!Number.isSafeInteger(offset) || offset < 0)
    return Promise.resolve(failure("VALIDATION_ERROR"));
  return rpc(
    "get_interview_feedback_workspace",
    { p_limit: 50, p_offset: offset },
    false,
    deps,
  );
}
export function loadFeedbackCollection(
  id: string,
  deps: FeedbackDeps = {},
): Promise<Result<Detail>> {
  if (!uuid(id)) return Promise.resolve(failure("VALIDATION_ERROR"));
  return rpc(
    "get_interview_feedback_collection",
    { p_collection_id: id },
    false,
    deps,
  );
}
export function loadFeedbackInvitation(
  id: string,
  deps: FeedbackDeps = {},
): Promise<Result<OwnDetail>> {
  if (!uuid(id)) return Promise.resolve(failure("VALIDATION_ERROR"));
  return rpc(
    "get_interview_feedback_invitation",
    { p_invitation_id: id },
    false,
    deps,
  );
}
export function publishFeedbackTemplate(
  input: PublishInput,
  deps: FeedbackDeps = {},
): Promise<Result<Template>> {
  if (
    !input ||
    !text(input.name, 200, true) ||
    !uuid(input.idempotencyKey) ||
    (input.previousTemplateId !== null && !uuid(input.previousTemplateId)) ||
    !Array.isArray(input.questions) ||
    input.questions.length < 1 ||
    input.questions.length > 30 ||
    input.questions.some(
      (q) =>
        !q ||
        typeof q.key !== "string" ||
        !/^[a-z][a-z0-9_]{0,63}$/.test(q.key) ||
        !text(q.label, 1000, true) ||
        typeof q.required !== "boolean" ||
        Object.keys(q).some((k) => !["key", "label", "required"].includes(k)),
    ) ||
    new Set(input.questions.map((q) => q.key)).size !== input.questions.length
  )
    return Promise.resolve(failure("VALIDATION_ERROR"));
  return rpc(
    "publish_interview_feedback_template",
    {
      p_name: input.name.trim(),
      p_questions: input.questions,
      p_previous_template_id: input.previousTemplateId,
      p_idempotency_key: input.idempotencyKey,
    },
    true,
    deps,
  );
}
export function createFeedbackCollection(
  input: CreateInput,
  deps: FeedbackDeps = {},
): Promise<Result<Collection>> {
  if (
    !input ||
    !uuid(input.interviewId) ||
    !uuid(input.templateId) ||
    !uuid(input.idempotencyKey) ||
    !Array.isArray(input.participantIds) ||
    input.participantIds.length < 1 ||
    input.participantIds.length > 100 ||
    !input.participantIds.every(uuid) ||
    new Set(input.participantIds).size !== input.participantIds.length ||
    (input.deadlineAt !== null &&
      (typeof input.deadlineAt !== "string" ||
        !Number.isFinite(Date.parse(input.deadlineAt))))
  )
    return Promise.resolve(failure("VALIDATION_ERROR"));
  return rpc(
    "create_interview_feedback_collection",
    {
      p_interview_id: input.interviewId,
      p_template_id: input.templateId,
      p_participant_ids: input.participantIds,
      p_deadline_at: input.deadlineAt,
      p_idempotency_key: input.idempotencyKey,
    },
    true,
    deps,
  );
}
export function saveFeedbackResponse(
  input: ResponseInput,
  deps: FeedbackDeps = {},
): Promise<Result<Invitation>> {
  if (
    !input ||
    !uuid(input.invitationId) ||
    !version(input.expectedVersionNo) ||
    typeof input.submit !== "boolean" ||
    !input.answers ||
    typeof input.answers !== "object" ||
    Array.isArray(input.answers) ||
    Object.keys(input.answers).length > 30 ||
    Object.entries(input.answers).some(
      ([k, v]) => !/^[a-z][a-z0-9_]{0,63}$/.test(k) || !text(v, 10000),
    )
  )
    return Promise.resolve(failure("VALIDATION_ERROR"));
  return rpc(
    "save_interview_feedback_response",
    {
      p_invitation_id: input.invitationId,
      p_answers: input.answers,
      p_expected_version_no: input.expectedVersionNo,
      p_submit: input.submit,
    },
    false,
    deps,
  );
}
export function revokeFeedbackInvitation(
  input: { invitationId: string; expectedVersionNo: number },
  deps: FeedbackDeps = {},
): Promise<Result<Invitation>> {
  if (!input || !uuid(input.invitationId) || !version(input.expectedVersionNo))
    return Promise.resolve(failure("VALIDATION_ERROR"));
  return rpc(
    "revoke_interview_feedback_invitation",
    {
      p_invitation_id: input.invitationId,
      p_expected_version_no: input.expectedVersionNo,
    },
    true,
    deps,
  );
}
export function saveFeedbackConsolidation(
  input: ConsolidationInput,
  deps: FeedbackDeps = {},
): Promise<Result<Consolidation>> {
  if (
    !input ||
    !uuid(input.collectionId) ||
    !version(input.expectedVersionNo, true) ||
    !text(input.title, 200, true) ||
    !text(input.overallSummary, 20000) ||
    typeof input.approve !== "boolean" ||
    (input.approve && input.expectedVersionNo === 0)
  )
    return Promise.resolve(failure("VALIDATION_ERROR"));
  return rpc(
    "save_interview_feedback_consolidation",
    {
      p_collection_id: input.collectionId,
      p_title: input.title.trim(),
      p_overall_summary: input.overallSummary,
      p_expected_version_no: input.expectedVersionNo,
      p_approve: input.approve,
    },
    true,
    deps,
  );
}
