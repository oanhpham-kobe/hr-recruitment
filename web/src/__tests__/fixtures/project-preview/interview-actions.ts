import type {
  CopyInterviewScheduleInput,
  SaveInterviewScheduleInput,
} from "@/lib/commands/interview-lifecycle";
import type {
  InterviewPageData,
  InterviewPageFilters,
  InterviewRound,
  InterviewScheduleStatus,
} from "@/lib/interview/model";
import { assignmentOptions, createApplicationAction } from "./inbox-actions";
import {
  canManage,
  currentRound,
  fail,
  findRound,
  hasPermission,
  mutate,
  newRound,
  now,
  ok,
  read,
  type State,
} from "./store";
export function interviewData(
  filters?: Partial<InterviewPageFilters>,
): InterviewPageData {
  const s = read();
  const manage = hasPermission(s, "interviews.manage");
  const canView = hasPermission(s, "interviews.view");
  const cat = s.catalogs;
  return {
    groups: (canView ? s.applications : []).filter(
      (a) =>
        (!filters?.activity ||
          filters.activity === "ALL" ||
          a.isActive === (filters.activity === "ACTIVE")) &&
        (!filters?.query ||
          `${a.candidateName} ${a.candidateEmail}`
            .toLowerCase()
            .includes(filters.query.toLowerCase())) &&
        (!filters?.unitId || a.unitId === filters.unitId) &&
        (!filters?.departmentTeamId ||
          a.departmentTeamId === filters.departmentTeamId) &&
        (!filters?.positionId || a.positionId === filters.positionId) &&
        (!filters?.hrOwnerId || a.hrOwnerId === filters.hrOwnerId) &&
        a.rounds.some(
          (r) =>
            (!filters?.scheduleStatus ||
              r.scheduleStatus === filters.scheduleStatus) &&
            (!filters?.dateFrom ||
              (r.startAt && r.startAt.slice(0, 10) >= filters.dateFrom)) &&
            (!filters?.dateTo ||
              (r.startAt && r.startAt.slice(0, 10) <= filters.dateTo)) &&
            (!filters?.interviewFormatId ||
              r.interviewFormatId === filters.interviewFormatId) &&
            (!filters?.participantAppUserId ||
              r.participants.some(
                (p) =>
                  p.isCurrent && p.appUserId === filters.participantAppUserId,
              )) &&
            (!filters?.location ||
              (filters.location === "ONLINE"
                ? Boolean(r.meetingLink)
                : r.roomId === filters.location)),
        ),
    ),
    page: 1,
    pageCount: 1,
    formats: cat.interview_formats.map((v) => ({
      id: v.id,
      code: v.code,
      name: v.nameVi,
      requiresRoom: Boolean(v.metadata?.requires_room),
      requiresMeetingLink: Boolean(v.metadata?.requires_meeting_link),
      isActive: v.isActive,
    })),
    rooms: cat.rooms.map((v) => ({
      id: v.id,
      code: v.code,
      name: v.nameVi,
      building: String(v.metadata?.building ?? "B1"),
      isActive: v.isActive,
    })),
    participantUsers: s.users
      .filter((u) => u.isActive)
      .map((u) => ({
        id: u.appUserId,
        name: u.fullName,
        email: u.email,
        jobTitle: u.jobTitle,
      })),
    filterUnits: cat.organizational_units.map((v) => ({
      id: v.id,
      name: v.nameVi,
    })),
    filterTeams: cat.department_teams.map((v) => ({
      id: v.id,
      name: v.nameVi,
      unitId: String(v.metadata?.unit_id),
    })),
    filterPositions: cat.positions.map((v) => ({
      id: v.id,
      name: v.nameVi,
      unitId: String(v.metadata?.unit_id),
      departmentTeamId: v.metadata?.department_team_id
        ? String(v.metadata.department_team_id)
        : null,
    })),
    filterHrOwners: s.users
      .filter((u) => u.isActive && u.isHr)
      .map((u) => ({
        id: u.appUserId,
        name: u.fullName,
        email: u.email,
        jobTitle: u.jobTitle,
      })),
    permissions: {
      canView,
      canManage: manage,
      canChangeStatus: hasPermission(s, "interviews.status"),
      canManageParticipants: hasPermission(s, "interviews.participants"),
      canCreateApplication:
        hasPermission(s, "applications.create") ||
        hasPermission(s, "applications.manage"),
      canReactivateApplication: hasPermission(s, "applications.manage"),
      canDeleteApplication: hasPermission(s, "applications.manage"),
    },
  };
}
export async function queryInterviewPageAction(input?: {
  filters: InterviewPageFilters;
}) {
  return interviewData(input?.filters);
}
export async function searchSubmissionOptionsAction(query: string) {
  return ok(
    read()
      .submissions.filter(
        (v) =>
          read().candidateActive &&
          `${v.full_name} ${v.email}`
            .toLowerCase()
            .includes(query.toLowerCase()),
      )
      .map((v) => ({
        submissionId: v.submission_id,
        candidateName: v.full_name,
        verifiedEmail: v.email,
        submittedAt: v.submitted_at,
        status: v.status_code,
      })),
  );
}
export async function searchApplicationOptionsAction(query: string) {
  return ok(
    read()
      .applications.filter(
        (a) =>
          a.isActive &&
          a.candidateName.toLowerCase().includes(query.toLowerCase()),
      )
      .map((a) => ({
        applicationId: a.applicationId,
        label: `${a.candidateName} — ${a.positionName}`,
        candidateName: a.candidateName,
        candidateEmail: a.candidateEmail,
        versionNo: a.versionNo,
        latestRoundId: currentRound(a)?.interviewId,
        latestRoundVersionNo: currentRound(a)?.versionNo,
        latestRoundNo: currentRound(a)?.roundNo,
      })),
  );
}
export async function getInterviewAssignmentOptionsAction() {
  return ok(assignmentOptions());
}
export const createInterviewApplicationAction = createApplicationAction;
function roundCommand(
  label: string,
  input: { interviewId: string; expectedVersion?: number },
  fn: (r: InterviewRound, s: State) => undefined | string,
  permission = "interviews.manage",
) {
  return mutate(label, (s) => {
    if (!hasPermission(s, permission)) return fail("FORBIDDEN");
    const found = findRound(s, input.interviewId);
    if (!found) return fail("NOT_FOUND");
    if (
      input.expectedVersion !== undefined &&
      found.round.versionNo !== input.expectedVersion
    )
      return fail("STALE_VERSION");
    const error = fn(found.round, s);
    if (error) return fail(error);
    const conflict = resourceConflict(s, found.round);
    if (conflict) return fail(conflict);
    found.round.versionNo++;
    found.round.updatedAt = now();
    return ok({
      interview_id: found.round.interviewId,
      version_no: found.round.versionNo,
    });
  });
}
export async function createNextRoundAction(input: { applicationId: string }) {
  return mutate("Tạo vòng mới / Next round", (s) => {
    const app = s.applications.find(
      (a) => a.applicationId === input.applicationId,
    );
    if (!canManage(s)) return fail("FORBIDDEN");
    if (
      !app?.isActive ||
      !app.rounds.reduce((a, b) => (a.roundNo > b.roundNo ? a : b)).isActive
    )
      return fail("INVALID_STATE");
    const round = newRound(
      app.applicationId,
      Math.max(...app.rounds.map((r) => r.roundNo), 0) + 1,
    );
    app.rounds.push(round);
    app.versionNo++;
    s.roundMeta[round.interviewId] = { visible: true, note: "" };
    return ok({ interview_id: round.interviewId });
  });
}
function schedule(
  r: InterviewRound,
  input: Omit<SaveInterviewScheduleInput, "demoTopic" | "interviewNote">,
  state: State,
) {
  if (
    input.interviewFormatId &&
    input.interviewFormatId !== r.interviewFormatId &&
    !state.catalogs.interview_formats.some(
      (format) => format.id === input.interviewFormatId && format.isActive,
    )
  )
    return "INACTIVE_FORMAT_NOT_SELECTABLE";
  if (
    input.startAt &&
    input.endAt &&
    Date.parse(input.endAt) <= Date.parse(input.startAt)
  )
    return "VALIDATION_ERROR";
  r.startAt = input.startAt;
  r.endAt = input.endAt;
  r.interviewFormatId = input.interviewFormatId;
  r.roomId = input.roomId;
  r.meetingLink = input.meetingLink;
}
export async function saveInterviewScheduleAction(
  input: SaveInterviewScheduleInput,
) {
  return roundCommand("Lưu lịch / Save schedule", input, (r, s) => {
    if (r.scheduleStatus === "CONFIRMED") return "CONFIRMED_LOCKED";
    const err = schedule(r, input, s);
    if (err) return err;
    r.demoTopic = input.demoTopic;
    r.interviewNote = input.interviewNote;
  });
}
export async function rescheduleConfirmedAction(
  input: Omit<SaveInterviewScheduleInput, "demoTopic" | "interviewNote">,
) {
  return roundCommand("Đổi lịch đã xác nhận / Reschedule", input, (r, s) => {
    const error = schedule(r, input, s);
    if (error) return error;
    r.scheduleStatus = "SCHEDULED";
  });
}
export async function changeInterviewStatusAction(input: {
  interviewId: string;
  expectedVersion: number;
  status: InterviewScheduleStatus;
}) {
  return roundCommand(
    "Đổi trạng thái lịch / Schedule status",
    input,
    (r) => {
      r.scheduleStatus = input.status;
    },
    "interviews.status",
  );
}
export async function copyInterviewScheduleAction(
  input: CopyInterviewScheduleInput,
) {
  return mutate("Sao chép lịch / Copy schedule", (s) => {
    if (!canManage(s)) return fail("FORBIDDEN");
    const source = findRound(s, input.sourceInterviewId);
    const target = findRound(s, input.expectedTargetRoundId);
    if (!source || !target) return fail("NOT_FOUND");
    if (
      source.round.versionNo !== input.expectedSourceVersion ||
      target.round.versionNo !== input.expectedTargetRoundVersion ||
      target.app.versionNo !== input.expectedTargetApplicationVersion
    )
      return fail("STALE_VERSION");
    if (target.round.scheduleStatus === "CONFIRMED")
      return fail("CONFIRMED_LOCKED");
    const err = schedule(
      target.round,
      {
        ...input,
        interviewId: target.round.interviewId,
        expectedVersion: target.round.versionNo,
      },
      s,
    );
    if (err) return fail(err);
    target.round.interviewNote = input.interviewNote;
    target.round.versionNo++;
    for (const userId of input.participantAppUserIds)
      addParticipant(target.round, userId, s);
    const conflict = resourceConflict(s, target.round);
    if (conflict) return fail(conflict);
    return ok({ interview_id: target.round.interviewId });
  });
}
function addParticipant(round: InterviewRound, userId: string, s: State) {
  const user = s.users.find((u) => u.appUserId === userId && u.isActive);
  if (!user) return;
  if (round.participants.some((p) => p.appUserId === userId && p.isCurrent))
    return;
  round.participants.push({
    interviewParticipantId: crypto.randomUUID(),
    appUserId: userId,
    order: round.participants.length + 1,
    name: user.fullName,
    email: user.email,
    jobTitle: user.jobTitle,
    isCurrent: true,
    removedAt: null,
    versionNo: 1,
    hasReportHistory: false,
  });
}
export async function addInterviewParticipantAction(input: {
  interviewId: string;
  appUserId: string;
}) {
  return roundCommand(
    "Thêm người phỏng vấn / Add participant",
    input,
    (r, s) => {
      addParticipant(r, input.appUserId, s);
    },
    "interviews.participants",
  );
}
export async function removeInterviewParticipantAction(input: {
  interviewParticipantId: string;
  expectedVersion: number;
}) {
  return participantCommand(input, false);
}
export async function readdInterviewParticipantAction(input: {
  interviewParticipantId: string;
  restoreMode: string;
}) {
  return participantCommand(input, true);
}
function participantCommand(
  input: {
    interviewParticipantId: string;
    expectedVersion?: number;
    restoreMode?: string;
  },
  restore: boolean,
) {
  return mutate(
    restore ? "Khôi phục participant / Restore" : "Gỡ participant / Remove",
    (s) => {
      if (!canManage(s)) return fail("FORBIDDEN");
      for (const app of s.applications)
        for (const r of app.rounds) {
          const p = r.participants.find(
            (p) => p.interviewParticipantId === input.interviewParticipantId,
          );
          if (p) {
            if (
              input.expectedVersion !== undefined &&
              p.versionNo !== input.expectedVersion
            )
              return fail("STALE_VERSION");
            p.isCurrent = restore;
            p.removedAt = restore ? null : now();
            p.versionNo++;
            r.versionNo++;
            const conflict = resourceConflict(s, r);
            if (conflict) return fail(conflict);
            if (restore && input.restoreMode === "CREATE_NEW_REPORT")
              s.reports
                .filter((v) => v.participantId === p.interviewParticipantId)
                .forEach((v) => {
                  v.active = false;
                });
            return ok({});
          }
        }
      return fail("NOT_FOUND");
    },
  );
}
export async function reorderInterviewParticipantsAction(input: {
  interviewId: string;
  participantIds: string[];
  expectedVersions: number[];
}) {
  return roundCommand("Thứ tự participant / Reorder", input, (r) => {
    if (
      input.participantIds.some(
        (p, i) =>
          r.participants.find((v) => v.interviewParticipantId === p)
            ?.versionNo !== input.expectedVersions[i],
      )
    )
      return "STALE_VERSION";
    input.participantIds.forEach((p, i) => {
      const v = r.participants.find((v) => v.interviewParticipantId === p);
      if (v) {
        v.order = i + 1;
        v.versionNo++;
      }
    });
  });
}
export async function reactivateInterviewAction(input: {
  interviewId: string;
  expectedVersion: number;
}) {
  return roundCommand("Kích hoạt vòng / Reactivate round", input, (r) => {
    r.isActive = true;
  });
}
export async function deleteOrInactivateInterviewAction(input: {
  interviewId: string;
  expectedVersion: number;
}) {
  return roundCommand("Ngừng vòng / Inactivate round", input, (r, s) => {
    const app = findRound(s, r.interviewId)?.app;
    if (!app) return "NOT_FOUND";
    if (app.rounds.some((v) => v.roundNo > r.roundNo))
      return "LATER_ROUND_EXISTS";
    r.isActive = false;
  });
}
export async function reactivateApplicationAction(input: {
  applicationId: string;
  expectedVersion: number;
}) {
  return mutate("Kích hoạt Application", (s) => {
    const a = s.applications.find(
      (a) => a.applicationId === input.applicationId,
    );
    if (!canManage(s)) return fail("FORBIDDEN");
    if (!a) return fail("NOT_FOUND");
    if (a.versionNo !== input.expectedVersion) return fail("STALE_VERSION");
    a.isActive = true;
    for (const round of a.rounds) {
      const conflict = resourceConflict(s, round);
      if (conflict) return fail(conflict);
    }
    a.versionNo++;
    return ok({});
  });
}
export async function deleteOrInactivateApplicationAction(
  applicationId: string,
) {
  return mutate("Ngừng Application / Inactivate", (s) => {
    if (!canManage(s)) return fail("FORBIDDEN");
    const a = s.applications.find((a) => a.applicationId === applicationId);
    if (!a) return fail("NOT_FOUND");
    a.isActive = false;
    a.versionNo++;
    return ok({});
  });
}
export async function getInterviewEmailCapabilitiesAction() {
  return {
    canSend: hasPermission(read(), "interviews.email"),
    canViewHistory: hasPermission(read(), "emails.history_view"),
    canDeleteHistory: hasPermission(read(), "emails.delete"),
  };
}
export async function previewInterviewEmailAction(input: {
  interviewId: string;
  emailType: string;
  applicationId: string;
  submissionId: string;
}) {
  const found = findRound(read(), input.interviewId);
  if (!found) return fail("NOT_FOUND");
  return ok({
    recipients: {
      to:
        input.emailType === "INTERVIEW_INVITATION"
          ? [found.app.candidateEmail]
          : found.round.participants
              .filter((p) => p.isCurrent)
              .map((p) => p.email),
      cc: [],
    },
    subject: `[MÔ PHỎNG / SIMULATION] Phỏng vấn ${found.app.candidateName}`,
    body_text: `Chỉ là dữ liệu mẫu. Không gửi email.\nVòng ${found.round.roundNo}\n${found.round.startAt ?? "Chưa có lịch"}`,
    template_version: "preview-1",
    environment_code: "TEST" as const,
    context_fingerprint: "a".repeat(64),
    preview_fingerprint: String(found.round.versionNo).padStart(64, "0"),
    email_type: input.emailType,
    interview_id: input.interviewId,
    application_id: input.applicationId,
    submission_id: input.submissionId,
  });
}
export async function enqueueInterviewEmailAction(input: {
  request: {
    interview_id: string;
    email_type: string;
    application_id: string;
    submission_id: string;
    preview_fingerprint: string;
  };
}) {
  const p = await previewInterviewEmailAction({
    interviewId: input.request.interview_id,
    emailType: input.request.email_type,
    applicationId: input.request.application_id,
    submissionId: input.request.submission_id,
  });
  if (!p.success) return p;
  if (p.data.preview_fingerprint !== input.request.preview_fingerprint)
    return fail("STALE_PREVIEW");
  return mutate("Email mô phỏng — chờ / Queued, no delivery", (s) => {
    if (!hasPermission(s, "interviews.email")) return fail("FORBIDDEN");
    const eid = crypto.randomUUID();
    s.emails.push({
      id: eid,
      interviewId: input.request.interview_id,
      subject: p.data.subject,
      body: p.data.body_text,
      recipients: p.data.recipients.to,
      at: now(),
      deleted: false,
    });
    return ok({ email_outbox_id: eid });
  });
}
export async function bulkEnqueueInterviewEmailsAction(input: {
  requests: Parameters<typeof enqueueInterviewEmailAction>[0]["request"][];
}) {
  const success = [];
  const failed = [];
  for (const request of input.requests) {
    const result = await enqueueInterviewEmailAction({ request });
    if (result.success)
      success.push({
        id: request.interview_id,
        ...request,
        email_outbox_id: result.data.email_outbox_id,
      });
    else failed.push({ id: request.interview_id, error: result.error });
  }
  return ok({ success, failed });
}
export async function loadInterviewEmailHistoryAction(_interviewId: string) {
  return ok([]);
}
export async function deleteEmailHistoryEntryAction(input: {
  emailHistoryId: string;
}) {
  return mutate("Ẩn bản ghi email mẫu", (s) => {
    if (!canManage(s)) return fail("FORBIDDEN");
    const e = s.emails.find((v) => v.id === input.emailHistoryId);
    if (e) e.deleted = true;
    return ok({ email_history_id: input.emailHistoryId });
  });
}

function resourceConflict(s: State, r: InterviewRound): string | undefined {
  const owner = findRound(s, r.interviewId)?.app;
  if (
    !owner?.isActive ||
    !r.isActive ||
    r.scheduleStatus === "CANCELLED" ||
    !r.startAt ||
    !r.endAt
  )
    return;
  const start = Date.parse(r.startAt),
    end = Date.parse(r.endAt);
  if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start)
    return "VALIDATION_ERROR";
  const format = s.catalogs.interview_formats.find(
    (v) => v.id === r.interviewFormatId,
  );
  if (!format) return "FORMAT_REQUIRED";
  if (format.metadata?.requires_room && !r.roomId) return "ROOM_REQUIRED";
  if (format.metadata?.requires_meeting_link && !r.meetingLink)
    return "MEETING_LINK_REQUIRED";
  for (const app of s.applications) {
    if (!app.isActive) continue;
    for (const other of app.rounds) {
      if (
        other.interviewId === r.interviewId ||
        !other.isActive ||
        other.scheduleStatus === "CANCELLED" ||
        !other.startAt ||
        !other.endAt
      )
        continue;
      if (start >= Date.parse(other.endAt) || end <= Date.parse(other.startAt))
        continue;
      if (owner.candidateId === app.candidateId)
        return "CANDIDATE_SCHEDULE_CONFLICT";
      if (r.roomId && r.roomId === other.roomId)
        return "ROOM_SCHEDULE_CONFLICT";
      if (
        r.participants.some(
          (p) =>
            p.isCurrent &&
            other.participants.some(
              (o) => o.isCurrent && o.appUserId === p.appUserId,
            ),
        )
      )
        return "PARTICIPANT_SCHEDULE_CONFLICT";
    }
  }
}
