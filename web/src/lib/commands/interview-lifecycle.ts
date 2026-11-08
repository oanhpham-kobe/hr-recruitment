import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { type AppSession, getServerSession } from "@/lib/auth/session";
import { createServerClient } from "@/lib/supabase/server";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SCHEDULE_STATUSES = new Set([
  "AVAILABLE",
  "SCHEDULED",
  "AWAITING",
  "CONFIRMED",
  "CANCELLED",
]);

function optionalUuid(value: string | null): boolean {
  return value === null || UUID.test(value);
}

export type InterviewCommandError = { code: string; message: string };
export type InterviewCommandResult<T = Record<string, unknown>> =
  | { success: true; data: T }
  | { success: false; error: InterviewCommandError };

export interface InterviewCommandDeps {
  client?: SupabaseClient;
  resolveSession?: (client: SupabaseClient) => Promise<AppSession>;
}

type ActorContext = {
  client: SupabaseClient;
  session: AppSession;
  isRoot: boolean;
};

function safeMessage(code: string): string {
  const messages: Record<string, string> = {
    UNAUTHENTICATED: "Vui lòng đăng nhập lại.",
    FORBIDDEN: "Bạn không có quyền thực hiện thao tác này.",
    NOT_FOUND: "Không tìm thấy dữ liệu cần cập nhật.",
    STALE_VERSION: "Dữ liệu đã thay đổi. Vui lòng tải lại trạng thái mới nhất.",
    INVALID_STATE: "Trạng thái hiện tại không cho phép thao tác này.",
    VALIDATION_ERROR: "Dữ liệu chưa hợp lệ. Vui lòng kiểm tra lại.",
    INVALID_INTERVAL: "Khoảng thời gian phỏng vấn không hợp lệ.",
    LATEST_ROUND_REQUIRED:
      "Chỉ vòng phỏng vấn mới nhất được phép thực hiện thao tác này.",
    SCHEDULE_CONFLICT_CANDIDATE: "Ứng viên đang trùng lịch phỏng vấn.",
    SCHEDULE_CONFLICT_ROOM: "Phòng đang trùng lịch phỏng vấn.",
    SCHEDULE_CONFLICT_INTERVIEWER: "Người tham dự đang trùng lịch phỏng vấn.",
    CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED:
      "Có người tham dự hiện tại đã ngừng hoạt động. Vui lòng thay thế trước.",
    USER_INACTIVE_NOT_SELECTABLE:
      "Người dùng đã ngừng hoạt động và không thể chọn.",
    DUPLICATE_PARTICIPANT: "Người này đã có trong danh sách tham dự.",
    ACTIVE_APPLICATION_OWNER_REASSIGN_REQUIRED:
      "HR phụ trách hiện tại không còn hợp lệ. Vui lòng phân công lại.",
    IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_REQUEST:
      "Yêu cầu đã thay đổi. Vui lòng thực hiện lại thao tác mới.",
  };
  return messages[code] ?? "Không thể hoàn tất thao tác. Vui lòng thử lại.";
}

async function actorContext(
  deps: InterviewCommandDeps,
): Promise<ActorContext | null> {
  const client = deps.client ?? (await createServerClient());
  const session = await (deps.resolveSession ?? getServerSession)(client);
  if (!session.user?.isInternal) return null;
  return {
    client,
    session,
    isRoot: session.user.roles.includes("ROOT_ADMIN"),
  };
}

function authorized(
  ctx: ActorContext,
  permissions: string[],
  mode: "all" | "any" = "all",
): boolean {
  if (ctx.isRoot) return true;
  const owned = ctx.session.user?.permissions ?? [];
  return mode === "all"
    ? permissions.every((permission) => owned.includes(permission))
    : permissions.some((permission) => owned.includes(permission));
}

function invalid(message: string): InterviewCommandResult<never> {
  return { success: false, error: { code: "VALIDATION_ERROR", message } };
}

function positiveVersion(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

async function executeRpc<T>(
  ctx: ActorContext,
  name: string,
  args: Record<string, unknown>,
): Promise<InterviewCommandResult<T>> {
  const { data, error } = await ctx.client.rpc(name, args);
  if (error) {
    console.error(`[interview-command] ${name} RPC error`, error.message);
    return {
      success: false,
      error: {
        code: "INTERNAL_ERROR",
        message: "Không thể hoàn tất thao tác.",
      },
    };
  }
  const result = data as {
    success?: boolean;
    error_code?: unknown;
    data?: T;
  } | null;
  if (!result?.success || result.data === undefined) {
    const code =
      typeof result?.error_code === "string"
        ? result.error_code
        : "INTERNAL_ERROR";
    return { success: false, error: { code, message: safeMessage(code) } };
  }
  return { success: true, data: result.data };
}

async function withPermission<T>(
  deps: InterviewCommandDeps,
  permissions: string[],
  run: (ctx: ActorContext) => Promise<InterviewCommandResult<T>>,
  mode: "all" | "any" = "all",
): Promise<InterviewCommandResult<T>> {
  const ctx = await actorContext(deps);
  if (!ctx)
    return {
      success: false,
      error: {
        code: "UNAUTHENTICATED",
        message: safeMessage("UNAUTHENTICATED"),
      },
    };
  if (!authorized(ctx, permissions, mode))
    return {
      success: false,
      error: { code: "FORBIDDEN", message: safeMessage("FORBIDDEN") },
    };
  return run(ctx);
}

export async function createNextInterviewRound(
  input: { applicationId: string; idempotencyKey: string },
  deps: InterviewCommandDeps = {},
) {
  if (!UUID.test(input.applicationId) || !UUID.test(input.idempotencyKey))
    return invalid("Application hoặc idempotency key không hợp lệ.");
  return withPermission(deps, ["interviews.manage"], (ctx) =>
    executeRpc(ctx, "create_next_interview_round", {
      p_application_id: input.applicationId,
      p_idempotency_key: input.idempotencyKey,
    }),
  );
}

export interface SaveInterviewScheduleInput {
  interviewId: string;
  startAt: string | null;
  endAt: string | null;
  interviewFormatId: string | null;
  roomId: string | null;
  meetingLink: string | null;
  demoTopic: string | null;
  interviewNote: string | null;
  expectedVersion: number;
  idempotencyKey: string;
}

export async function saveInterviewSchedule(
  input: SaveInterviewScheduleInput,
  deps: InterviewCommandDeps = {},
) {
  if (
    !UUID.test(input.interviewId) ||
    !positiveVersion(input.expectedVersion) ||
    !UUID.test(input.idempotencyKey)
  )
    return invalid("Interview, version hoặc idempotency key không hợp lệ.");
  if ((input.startAt === null) !== (input.endAt === null))
    return invalid("Giờ bắt đầu và kết thúc phải được nhập cùng nhau.");
  return withPermission(deps, ["interviews.manage"], (ctx) =>
    executeRpc(ctx, "save_interview_schedule", {
      p_interview_id: input.interviewId,
      p_start_at: input.startAt,
      p_end_at: input.endAt,
      p_interview_format_id: input.interviewFormatId,
      p_room_id: input.roomId,
      p_meeting_link: input.meetingLink,
      p_demo_topic: input.demoTopic,
      p_interview_note: input.interviewNote,
      p_expected_version: input.expectedVersion,
      p_idempotency_key: input.idempotencyKey,
    }),
  );
}

export async function changeInterviewScheduleStatus(
  input: { interviewId: string; status: string; expectedVersion: number },
  deps: InterviewCommandDeps = {},
) {
  if (
    !UUID.test(input.interviewId) ||
    !positiveVersion(input.expectedVersion) ||
    !SCHEDULE_STATUSES.has(input.status)
  )
    return invalid("Interview, version hoặc trạng thái không hợp lệ.");
  return withPermission(deps, ["interviews.status", "interviews.view"], (ctx) =>
    executeRpc(ctx, "change_interview_schedule_status", {
      p_interview_id: input.interviewId,
      p_schedule_status_code: input.status,
      p_expected_version: input.expectedVersion,
    }),
  );
}

export async function rescheduleConfirmedInterview(
  input: Omit<SaveInterviewScheduleInput, "demoTopic" | "interviewNote">,
  deps: InterviewCommandDeps = {},
) {
  if (
    !UUID.test(input.interviewId) ||
    !positiveVersion(input.expectedVersion) ||
    !UUID.test(input.idempotencyKey) ||
    !input.startAt ||
    !input.endAt ||
    !input.interviewFormatId ||
    !UUID.test(input.interviewFormatId) ||
    !optionalUuid(input.roomId)
  )
    return invalid("Thông tin xếp lại lịch chưa hợp lệ.");
  return withPermission(deps, ["interviews.manage"], (ctx) =>
    executeRpc(ctx, "reschedule_confirmed_interview", {
      p_interview_id: input.interviewId,
      p_start_at: input.startAt,
      p_end_at: input.endAt,
      p_interview_format_id: input.interviewFormatId,
      p_room_id: input.roomId,
      p_meeting_link: input.meetingLink,
      p_expected_version: input.expectedVersion,
      p_idempotency_key: input.idempotencyKey,
    }),
  );
}

export interface CopyInterviewScheduleInput {
  sourceInterviewId: string;
  targetApplicationId: string;
  expectedSourceVersion: number;
  expectedTargetApplicationVersion: number;
  expectedTargetRoundId: string;
  expectedTargetRoundVersion: number;
  startAt: string | null;
  endAt: string | null;
  interviewFormatId: string | null;
  roomId: string | null;
  meetingLink: string | null;
  interviewNote: string | null;
  participantAppUserIds: string[];
  idempotencyKey: string;
}

export async function copyInterviewSchedule(
  input: CopyInterviewScheduleInput,
  deps: InterviewCommandDeps = {},
) {
  if (
    ![
      input.sourceInterviewId,
      input.targetApplicationId,
      input.expectedTargetRoundId,
      input.idempotencyKey,
    ].every((value) => UUID.test(value)) ||
    !positiveVersion(input.expectedSourceVersion) ||
    !positiveVersion(input.expectedTargetApplicationVersion) ||
    !positiveVersion(input.expectedTargetRoundVersion) ||
    !input.participantAppUserIds.every((id) => UUID.test(id)) ||
    !optionalUuid(input.interviewFormatId) ||
    !optionalUuid(input.roomId) ||
    (input.startAt === null) !== (input.endAt === null) ||
    (input.startAt !== null && input.interviewFormatId === null)
  )
    return invalid("Copy payload không hợp lệ.");
  return withPermission(deps, ["interviews.manage", "interviews.view"], (ctx) =>
    executeRpc(ctx, "copy_interview_schedule", {
      p_source_interview_id: input.sourceInterviewId,
      p_target_application_id: input.targetApplicationId,
      p_expected_source_version: input.expectedSourceVersion,
      p_expected_target_application_version:
        input.expectedTargetApplicationVersion,
      p_expected_target_round_id: input.expectedTargetRoundId,
      p_expected_target_round_version: input.expectedTargetRoundVersion,
      p_start_at: input.startAt,
      p_end_at: input.endAt,
      p_interview_format_id: input.interviewFormatId,
      p_room_id: input.roomId,
      p_meeting_link: input.meetingLink,
      p_interview_note: input.interviewNote,
      p_participant_app_user_ids: input.participantAppUserIds,
      p_idempotency_key: input.idempotencyKey,
    }),
  );
}

export async function reactivateApplication(
  input: { applicationId: string; expectedVersion: number },
  deps: InterviewCommandDeps = {},
) {
  if (
    !UUID.test(input.applicationId) ||
    !positiveVersion(input.expectedVersion)
  )
    return invalid("Application hoặc version không hợp lệ.");
  return withPermission(deps, ["applications.manage"], (ctx) =>
    executeRpc(ctx, "reactivate_application", {
      p_application_id: input.applicationId,
      p_expected_version: input.expectedVersion,
    }),
  );
}

export async function deleteOrInactivateApplication(
  applicationId: string,
  deps: InterviewCommandDeps = {},
) {
  if (!UUID.test(applicationId)) return invalid("Application không hợp lệ.");
  return withPermission(
    deps,
    ["applications.delete", "applications.manage"],
    (ctx) =>
      executeRpc(ctx, "delete_or_inactivate_application", {
        p_application_id: applicationId,
      }),
    "any",
  );
}

export async function reactivateInterview(
  input: { interviewId: string; expectedVersion: number },
  deps: InterviewCommandDeps = {},
) {
  if (!UUID.test(input.interviewId) || !positiveVersion(input.expectedVersion))
    return invalid("Interview hoặc version không hợp lệ.");
  return withPermission(deps, ["interviews.manage"], (ctx) =>
    executeRpc(ctx, "reactivate_interview", {
      p_interview_id: input.interviewId,
      p_expected_version: input.expectedVersion,
    }),
  );
}

export async function deleteOrInactivateInterview(
  input: { interviewId: string; expectedVersion: number },
  deps: InterviewCommandDeps = {},
) {
  if (!UUID.test(input.interviewId) || !positiveVersion(input.expectedVersion))
    return invalid("Interview hoặc version không hợp lệ.");
  return withPermission(deps, ["interviews.manage", "interviews.view"], (ctx) =>
    executeRpc(ctx, "delete_or_inactivate_interview", {
      p_interview_id: input.interviewId,
      p_expected_version: input.expectedVersion,
    }),
  );
}

export async function addInterviewParticipant(
  input: { interviewId: string; appUserId: string; idempotencyKey: string },
  deps: InterviewCommandDeps = {},
) {
  if (
    ![input.interviewId, input.appUserId, input.idempotencyKey].every((value) =>
      UUID.test(value),
    )
  )
    return invalid("Participant payload không hợp lệ.");
  return withPermission(
    deps,
    ["interviews.participants", "interviews.view"],
    (ctx) =>
      executeRpc(ctx, "add_interview_participant", {
        p_interview_id: input.interviewId,
        p_app_user_id: input.appUserId,
        p_idempotency_key: input.idempotencyKey,
      }),
  );
}

export async function removeInterviewParticipant(
  input: { interviewParticipantId: string; expectedVersion: number },
  deps: InterviewCommandDeps = {},
) {
  if (
    !UUID.test(input.interviewParticipantId) ||
    !positiveVersion(input.expectedVersion)
  )
    return invalid("Participant hoặc version không hợp lệ.");
  return withPermission(
    deps,
    ["interviews.participants", "interviews.view"],
    (ctx) =>
      executeRpc(ctx, "remove_interview_participant", {
        p_interview_participant_id: input.interviewParticipantId,
        p_expected_version: input.expectedVersion,
      }),
  );
}

export async function readdInterviewParticipant(
  input: {
    interviewParticipantId: string;
    restoreMode: "RESTORE_OLD_REPORT" | "CREATE_NEW_REPORT";
    idempotencyKey: string;
  },
  deps: InterviewCommandDeps = {},
) {
  if (
    !UUID.test(input.interviewParticipantId) ||
    !UUID.test(input.idempotencyKey) ||
    !["RESTORE_OLD_REPORT", "CREATE_NEW_REPORT"].includes(input.restoreMode)
  )
    return invalid("Re-add payload không hợp lệ.");
  return withPermission(
    deps,
    ["interviews.participants", "interviews.view"],
    (ctx) =>
      executeRpc(ctx, "readd_interview_participant", {
        p_interview_participant_id: input.interviewParticipantId,
        p_restore_mode: input.restoreMode,
        p_idempotency_key: input.idempotencyKey,
      }),
  );
}

export async function reorderInterviewParticipants(
  input: {
    interviewId: string;
    participantIds: string[];
    expectedVersions: number[];
  },
  deps: InterviewCommandDeps = {},
) {
  if (
    !UUID.test(input.interviewId) ||
    input.participantIds.length !== input.expectedVersions.length ||
    !input.participantIds.every((id) => UUID.test(id)) ||
    !input.expectedVersions.every(positiveVersion)
  )
    return invalid("Thứ tự Participant hoặc version không hợp lệ.");
  return withPermission(
    deps,
    ["interviews.participants", "interviews.view"],
    (ctx) =>
      executeRpc(ctx, "reorder_interview_participants", {
        p_interview_id: input.interviewId,
        p_ordered_participant_ids: input.participantIds,
        p_expected_versions: input.expectedVersions,
      }),
  );
}
