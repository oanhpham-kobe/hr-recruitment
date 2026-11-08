import type {
  ApplicationInboxFilters,
  ApplicationInboxGroup,
} from "@/lib/application-inbox/model";
import {
  filterApplicationInboxGroups,
  paginateApplicationInboxGroups,
} from "@/lib/application-inbox/model";
import type { AssignmentOptions } from "@/lib/application-inbox/submission-detail-model";
import type { UpdateSubmissionAggregateInput } from "@/lib/commands/submission-status";
import {
  canManage,
  derive,
  hasPermission,
  id,
  mutate,
  newRound,
  now,
  ok,
  read,
  simpleFail,
} from "./store";
export function assignmentOptions(): AssignmentOptions {
  const s = read();
  return {
    units: s.catalogs.organizational_units
      .filter((x) => x.isActive)
      .map((x) => ({ unit_id: x.id, code: x.code, name_vi: x.nameVi })),
    department_teams: s.catalogs.department_teams
      .filter((x) => x.isActive)
      .map((x) => ({
        department_team_id: x.id,
        unit_id: String(x.metadata?.unit_id ?? id(100)),
        code: x.code,
        name_vi: x.nameVi,
      })),
    positions: s.catalogs.positions
      .filter((x) => x.isActive)
      .map((x) => ({
        position_id: x.id,
        unit_id: String(x.metadata?.unit_id ?? id(100)),
        department_team_id: x.metadata?.department_team_id
          ? String(x.metadata.department_team_id)
          : null,
        code: x.code,
        name_vi: x.nameVi,
      })),
    hr_owners: s.users
      .filter((u) => u.isActive && u.isHr)
      .map((u) => ({
        app_user_id: u.appUserId,
        full_name: u.fullName,
        email: u.email,
      })),
  };
}
export function inboxGroups(): ApplicationInboxGroup[] {
  const s = read();
  return [
    {
      candidateId: id(1),
      email: "candidate@example.test",
      isCandidateActive: s.candidateActive,
      candidateVersionNo: s.candidateVersion,
      latestSubmissionId: s.submissions.at(-1)?.submission_id ?? "",
      latestSubmissionVersionNo: s.submissions.at(-1)?.version_no ?? 1,
      submissions: [...s.submissions].reverse().map((v) => ({
        submissionId: v.submission_id,
        candidateId: v.candidate_id,
        status: v.status_code,
        fullName: v.full_name,
        dateOfBirth: v.date_of_birth,
        gender: v.gender_code,
        phone: v.phone,
        hrNote: v.hr_note,
        submittedAt: v.submitted_at,
        hasApplication: v.applications.some((a) => a.is_active),
        versionNo: v.version_no,
      })),
    },
  ];
}
export async function queryApplicationInbox(input: {
  filters: ApplicationInboxFilters;
  page: number;
  pageSize: number;
}) {
  return paginateApplicationInboxGroups(
    filterApplicationInboxGroups(inboxGroups(), input.filters),
    input.page,
    input.pageSize,
  );
}
export async function getSubmissionDetailAction(submissionId: string) {
  const s = read();
  if (!["hr", "limited", "root"].includes(s.persona))
    return simpleFail("FORBIDDEN");
  const sub = s.submissions.find((v) => v.submission_id === submissionId);
  return sub ? ok(sub) : simpleFail("NOT_FOUND");
}
export async function openSubmissionAction(submissionId: string) {
  return mutate("Mở phiếu / Open submission", (s) => {
    const sub = s.submissions.find((v) => v.submission_id === submissionId);
    if (!sub) return simpleFail("NOT_FOUND");
    if (canManage(s) && sub.status_code === "NEW") {
      sub.status_code = "READ";
      sub.version_no++;
    }
    return ok({
      submission_id: sub.submission_id,
      status_code: sub.status_code,
      version_no: sub.version_no,
    });
  });
}
export async function updateSubmissionAggregateAction(
  input: UpdateSubmissionAggregateInput,
) {
  return mutate("HR sửa phiếu / Edit submission", (s) => {
    if (!hasPermission(s, "submissions.edit")) return simpleFail("FORBIDDEN");
    const v = s.submissions.find((v) => v.submission_id === input.submissionId);
    if (!v) return simpleFail("NOT_FOUND");
    if (v.version_no !== input.expectedVersion)
      return simpleFail("STALE_VERSION");
    if (input.fullName != null) v.full_name = input.fullName;
    if (input.phone !== undefined) v.phone = input.phone;
    if (input.dateOfBirth !== undefined) v.date_of_birth = input.dateOfBirth;
    if (input.genderCode === "MALE" || input.genderCode === "FEMALE")
      v.gender_code = input.genderCode;
    if (input.currentAddress !== undefined)
      v.current_address = input.currentAddress;
    if (input.hrNote !== undefined) v.hr_note = input.hrNote;
    if (input.recruitmentSourceId !== undefined)
      v.recruitment_source_id = input.recruitmentSourceId;
    if (input.education)
      v.education = input.education.map((e, i) => ({
        education_id: crypto.randomUUID(),
        sort_order: i + 1,
        period_text: e.periodText ?? null,
        qualification_id: e.qualificationId ?? null,
        qualification_name: e.degreeName ?? null,
        major: e.majorName ?? null,
        institution: e.institutionName ?? null,
      }));
    v.version_no++;
    v.updated_at = now();
    return ok({
      submission_id: v.submission_id,
      version_no: v.version_no,
      changed_fields: Object.keys(input),
    });
  });
}
export async function updateSubmissionHrNoteAction(input: {
  submissionId: string;
  hrNote: string | null;
  expectedVersion: number;
}) {
  return updateSubmissionAggregateAction(input);
}
export async function getRecruitmentSourcesAction() {
  return read().catalogs.recruitment_sources.map((x) => ({
    recruitment_source_id: x.id,
    code: x.code,
    name_vi: x.nameVi,
  }));
}
export async function getQualificationLevelsAction() {
  return read().catalogs.qualification_levels.map((x) => ({
    qualification_id: x.id,
    code: x.code,
    name_vi: x.nameVi,
  }));
}
export async function getAssignmentOptionsAction() {
  return ok(assignmentOptions());
}
export async function getDocumentSignedUrlAction() {
  return simpleFail(
    "PREVIEW_METADATA_ONLY — Tài liệu mẫu không có URL riêng tư; mở mục Tài liệu mô phỏng trong hướng dẫn",
  );
}
export async function createApplicationAction(input: {
  submissionId: string;
  unitId: string;
  departmentTeamId?: string | null;
  positionId: string;
  hrOwnerId: string;
  confirmDuplicate?: boolean;
}) {
  return mutate("Gán Application + Vòng 1 / Assign application", (s) => {
    if (
      !hasPermission(s, "applications.create") &&
      !hasPermission(s, "applications.manage")
    )
      return simpleFail("FORBIDDEN");
    const sub = s.submissions.find(
      (v) => v.submission_id === input.submissionId,
    );
    if (!sub || !s.candidateActive) return simpleFail("NOT_FOUND");
    const existing = s.applications.find(
      (a) =>
        a.submissionId === input.submissionId &&
        a.unitId === input.unitId &&
        a.positionId === input.positionId &&
        a.departmentTeamId === (input.departmentTeamId || null),
    );
    if (existing) {
      if (!input.confirmDuplicate) return simpleFail("DUPLICATE_APPLICATION");
      if (!existing.isActive) return simpleFail("APPLICATION_INACTIVE");
      existing.hrOwnerId = input.hrOwnerId;
      existing.hrOwnerName =
        s.users.find((u) => u.appUserId === input.hrOwnerId)?.fullName ??
        existing.hrOwnerName;
      existing.versionNo++;
      derive(s);
      return ok({ application_id: existing.applicationId, created: false });
    }
    const unit = s.catalogs.organizational_units.find(
      (x) => x.id === input.unitId && x.isActive,
    );
    const position = s.catalogs.positions.find(
      (x) => x.id === input.positionId && x.isActive,
    );
    const hr = s.users.find(
      (u) => u.appUserId === input.hrOwnerId && u.isActive && u.isHr,
    );
    if (!unit || !position || !hr) return simpleFail("VALIDATION_ERROR");
    const appId = crypto.randomUUID();
    const round = newRound(appId, 1);
    s.applications.push({
      applicationId: appId,
      submissionId: sub.submission_id,
      candidateId: sub.candidate_id,
      candidateName: sub.full_name,
      candidateEmail: sub.email,
      candidatePhone: sub.phone ?? "",
      submissionDate: sub.submitted_at,
      submissionStatus: "PROCESSED",
      unitId: unit.id,
      unitName: unit.nameVi,
      departmentTeamId: input.departmentTeamId || null,
      departmentTeamName:
        s.catalogs.department_teams.find((x) => x.id === input.departmentTeamId)
          ?.nameVi ?? null,
      positionId: position.id,
      positionName: position.nameVi,
      hrOwnerId: hr.appUserId,
      hrOwnerName: hr.fullName,
      isActive: true,
      versionNo: 1,
      rounds: [round],
    });
    s.roundMeta[round.interviewId] = { visible: true, note: "" };
    derive(s);
    return ok({
      application_id: appId,
      round1_interview_id: round.interviewId,
      created: true,
    });
  });
}
export async function bulkSetLatestSubmissionManualStatusAction(input: {
  items: { expectedLatestSubmissionId: string; expectedVersion: number }[];
  statusCode: "NEW" | "READ";
}) {
  return mutate("Đổi trạng thái phiếu / Manual status", (s) => {
    if (!canManage(s)) return simpleFail("FORBIDDEN");
    for (const item of input.items) {
      const sub = s.submissions.find(
        (v) => v.submission_id === item.expectedLatestSubmissionId,
      );
      if (!sub || sub.version_no !== item.expectedVersion)
        return simpleFail("STALE_VERSION");
      if (
        s.applications.some(
          (a) => a.submissionId === sub.submission_id && a.isActive,
        )
      )
        return simpleFail("ACTIVE_APPLICATION_EXISTS");
    }
    for (const item of input.items) {
      const sub = s.submissions.find(
        (v) => v.submission_id === item.expectedLatestSubmissionId,
      );
      if (sub) {
        sub.status_code = input.statusCode;
        sub.version_no++;
      }
    }
    return ok({ count: input.items.length, items: [] });
  });
}
export async function bulkSetCandidateActiveAction(input: {
  items: { candidateId: string; expectedVersion: number }[];
  active: boolean;
}) {
  return mutate("Trạng thái ứng viên / Candidate activity", (s) => {
    if (!hasPermission(s, "candidates.active_manage"))
      return simpleFail("FORBIDDEN");
    if (input.items.some((i) => i.expectedVersion !== s.candidateVersion))
      return simpleFail("STALE_VERSION");
    s.candidateActive = input.active;
    s.candidateVersion++;
    if (input.active)
      s.submissions.forEach((v) => {
        if (v.status_code === "NEW") {
          v.status_code = "READ";
          v.version_no++;
        }
      });
    return ok({
      count: 1,
      items: input.items.map((i) => ({
        candidate_id: i.candidateId,
        is_active: input.active,
        version_no: s.candidateVersion,
      })),
    });
  });
}
export async function setCandidateActiveAction(input: {
  candidateId: string;
  active: boolean;
  expectedVersion: number;
}) {
  const result = await bulkSetCandidateActiveAction({
    items: [input],
    active: input.active,
  });
  return result.success ? ok(result.data.items[0]) : result;
}
