import type { MasterDataItemRecord } from "@/app/master-data/actions";
import type { InternalUserDirectoryRecord } from "@/app/users/actions";
import type { SubmissionDetail } from "@/lib/application-inbox/submission-detail-model";
import type {
  InterviewApplicationGroup,
  InterviewRound,
} from "@/lib/interview/model";
import type {
  Collection,
  Consolidation,
  Invitation,
  Template,
} from "@/lib/interview-feedback/model";
import { TRIAL_QUESTIONS } from "@/lib/interview-feedback/model";
import type { ReportFields } from "@/lib/reports/model";
export const STORE_KEY = "eiu-project-synthetic-uat-v1";
export const id = (n: number) =>
  `20100000-0000-4000-8000-${String(n).padStart(12, "0")}`;
export type Persona =
  | "candidate"
  | "hr"
  | "limited"
  | "interviewerA"
  | "interviewerB"
  | "root";
export const PEOPLE: Record<Persona, { id: string; name: string }> = {
  candidate: { id: id(1), name: "Ứng viên / Candidate" },
  hr: { id: id(2), name: "HR — Nguyễn Hải Anh" },
  limited: { id: id(3), name: "HR chỉ xem / Read-only HR" },
  interviewerA: { id: id(4), name: "Nguyễn Minh Tâm" },
  interviewerB: { id: id(5), name: "Trần Thu Hà" },
  root: { id: id(6), name: "Root Admin" },
};
export const MASTER_NAMES: Record<string, string> = {
  organizational_units: "Khoa / Phòng",
  department_teams: "Ngành / Tổ",
  positions: "Vị trí",
  position_groups: "Nhóm vị trí",
  rooms: "Phòng phỏng vấn",
  interview_formats: "Hình thức phỏng vấn",
  qualification_levels: "Trình độ học vấn",
  recruitment_sources: "Nguồn tuyển dụng",
  document_types: "Loại tài liệu",
  cancellation_reasons: "Lý do hủy",
  rejection_reasons: "Lý do từ chối",
};
export interface LegacyReport {
  participantId: string;
  reportId: string;
  version: number;
  fields: ReportFields;
  updatedAt: string;
  decisionAt: string | null;
  updatedBy: string;
  active: boolean;
}
export interface EmailRecord {
  id: string;
  interviewId: string;
  subject: string;
  body: string;
  recipients: string[];
  at: string;
  deleted: boolean;
}
export interface State {
  revision: number;
  persona: Persona;
  candidateActive: boolean;
  candidateVersion: number;
  submissions: SubmissionDetail[];
  applications: InterviewApplicationGroup[];
  users: (InternalUserDirectoryRecord & { permissions: string[] })[];
  catalogs: Record<string, MasterDataItemRecord[]>;
  reports: LegacyReport[];
  roundMeta: Record<string, { visible: boolean; note: string }>;
  feedback: {
    templates: Template[];
    collections: Collection[];
    invitations: (Invitation & { collection_id: string })[];
    reports: Consolidation[];
    published: Record<string, string>;
  };
  emails: EmailRecord[];
  events: { id: string; at: string; actor: string; action: string }[];
  notes: string;
  checks: Record<string, boolean>;
  uploadNames: Record<string, string>;
}
export const now = () => new Date().toISOString();
export function seedState(): State {
  const catalogs: State["catalogs"] = {};
  Object.keys(MASTER_NAMES).forEach((key, index) => {
    catalogs[key] = [
      {
        id: id(100 + index),
        code: key === "document_types" ? "CV_RESUME" : `SAMPLE_${index}`,
        nameVi: MASTER_NAMES[key],
        nameEn: MASTER_NAMES[key],
        isActive: true,
        versionNo: 1,
        metadata: {},
      },
    ];
  });
  catalogs.organizational_units[0].nameVi = "Khoa Công nghệ thông tin";
  catalogs.positions[0].nameVi = "Giảng viên CNTT";
  catalogs.positions[0].metadata = {
    unit_id: id(100),
    department_team_id: id(101),
    position_group_id: id(103),
  };
  catalogs.department_teams[0].metadata = { unit_id: id(100) };
  catalogs.interview_formats[0].metadata = {
    requires_room: true,
    requires_meeting_link: false,
    requires_demo_topic: false,
  };
  catalogs.document_types[0].metadata = { scope_code: "SUBMISSION" };
  catalogs.interview_formats.push({
    id: id(120),
    code: "ONLINE",
    nameVi: "Trực tuyến",
    nameEn: "Online",
    isActive: true,
    versionNo: 1,
    metadata: { requires_room: false, requires_meeting_link: true },
  });
  for (const [index, code] of [
    "DEGREE",
    "TRANSCRIPT",
    "CERTIFICATE",
    "OTHER",
  ].entries())
    catalogs.document_types.push({
      id: id(130 + index),
      code,
      nameVi: (
        {
          DEGREE: "Bằng cấp",
          TRANSCRIPT: "Bảng điểm",
          CERTIFICATE: "Chứng chỉ",
          OTHER: "Khác",
        } as Record<string, string>
      )[code],
      nameEn: code,
      isActive: true,
      versionNo: 1,
      metadata: { scope_code: "SUBMISSION" },
    });
  const s: State = {
    revision: 1,
    persona: "hr",
    candidateActive: true,
    candidateVersion: 1,
    submissions: [],
    applications: [],
    users: Object.entries(PEOPLE)
      .filter(([key]) => key !== "candidate")
      .map(([key, p]) => ({
        appUserId: p.id,
        email: `${key}@eiu.edu.vn`,
        fullName: p.name,
        jobTitle: key.startsWith("interviewer")
          ? "Giảng viên"
          : "Chuyên viên HR",
        unitId: id(100),
        isActive: true,
        isRootAdmin: key === "root",
        isHr: ["hr", "limited", "root"].includes(key),
        identityBound: true,
        versionNo: 1,
        permissions:
          key === "limited"
            ? ["submissions.view", "reports.view", "interviews.view"]
            : key === "hr"
              ? [
                  "submissions.view",
                  "submissions.status",
                  "candidates.active_manage",
                  "submissions.edit",
                  "applications.create",
                  "applications.manage",
                  "interviews.view",
                  "interviews.manage",
                  "interviews.status",
                  "interviews.participants",
                  "interviews.email",
                  "reports.view",
                  "reports.manage_status",
                  "reports.visibility",
                  "reports.edit_interviewer",
                  "reports.delete",
                  "master_data.manage",
                  "users.directory_read",
                  "emails.history_view",
                ]
              : [],
      })),
    catalogs,
    reports: [],
    roundMeta: {},
    feedback: {
      templates: [
        {
          template_id: id(200),
          family_id: id(200),
          version_no: 1,
          name: "Phiếu nhận xét phỏng vấn / Interview feedback",
          questions: TRIAL_QUESTIONS.map((q) => ({ ...q })),
          published_at: now(),
        },
      ],
      collections: [],
      invitations: [],
      reports: [],
      published: {},
    },
    emails: [],
    events: [],
    notes: "",
    checks: {},
    uploadNames: {},
  };
  s.submissions.push(
    newSubmission("Lê Phương Linh", id(10)),
    newSubmission("Trần Quốc Bảo", id(11)),
  );
  return s;
}
export function newSubmission(
  name: string,
  submissionId = crypto.randomUUID(),
): SubmissionDetail {
  return {
    submission_id: submissionId,
    candidate_id: id(1),
    status_code: "NEW",
    full_name: name,
    date_of_birth: "1995-05-20",
    gender_code: "FEMALE",
    current_address: "Bình Dương — dữ liệu mẫu",
    phone: "0900000000",
    email: "candidate@example.test",
    other_info: null,
    hr_note: null,
    recruitment_source_id: id(107),
    recruitment_source_name: "Website EIU",
    submitted_at: now(),
    updated_at: now(),
    updated_by_name: "Candidate (synthetic)",
    version_no: 1,
    education: [],
    work_experiences: [],
    activities: [],
    documents: [
      {
        document_id: crypto.randomUUID(),
        logical_document_id: crypto.randomUUID(),
        document_type_id: id(108),
        document_type_code: "CV_RESUME",
        document_type_name: "CV mẫu — metadata only",
        original_filename: "CV-mau.pdf",
        mime_type: "application/pdf",
        file_size_bytes: 1024,
        uploaded_at: now(),
      },
    ],
    applications: [],
  };
}
let memory: State | undefined;
let memoryOnly = false;
export const persistenceAvailable = () => !memoryOnly;
export function read(): State {
  if (memoryOnly) return structuredClone(memory ?? seedState());
  try {
    const raw = localStorage.getItem(STORE_KEY);
    if (raw) return JSON.parse(raw) as State;
  } catch {
    memoryOnly = true;
  }
  return structuredClone(memory ?? seedState());
}
export function save(state: State) {
  state.revision++;
  memory = structuredClone(state);
  try {
    localStorage.setItem(STORE_KEY, JSON.stringify(state));
  } catch {
    memoryOnly = true;
  }
  if (typeof window !== "undefined")
    window.dispatchEvent(new Event("project-preview-change"));
}
export function reset() {
  const s = seedState();
  save(s);
}
export function mutate<T>(action: string, fn: (s: State) => T): T {
  const s = read();
  const result = fn(s);
  if (
    result &&
    typeof result === "object" &&
    "success" in result &&
    result.success === false
  )
    return result;
  s.events.unshift({
    id: crypto.randomUUID(),
    at: now(),
    actor: PEOPLE[s.persona].name,
    action,
  });
  derive(s);
  save(s);
  return result;
}
export function canManage(s = read()) {
  return (
    ["hr", "root"].includes(s.persona) &&
    s.users.some((u) => u.appUserId === PEOPLE[s.persona].id && u.isActive)
  );
}
export function isRoot(s = read()) {
  return s.persona === "root";
}
export function currentRound(app: InterviewApplicationGroup) {
  return [...app.rounds]
    .filter((r) => r.isActive)
    .sort((a, b) => b.roundNo - a.roundNo)[0];
}
export function findRound(s: State, interviewId: string) {
  for (const app of s.applications) {
    const round = app.rounds.find((r) => r.interviewId === interviewId);
    if (round) return { app, round };
  }
  return null;
}
export function derive(s: State) {
  for (const sub of s.submissions) {
    const apps = s.applications.filter(
      (a) => a.submissionId === sub.submission_id,
    );
    const active = apps.filter((a) => a.isActive);
    if (active.some((a) => currentRound(a)?.reportStatus === "HIRED"))
      sub.status_code = "DONE";
    else if (
      active.length &&
      active.every((a) => currentRound(a)?.reportStatus === "REJECTED")
    )
      sub.status_code = "CLOSED";
    else if (active.length) sub.status_code = "PROCESSED";
    else if (["PROCESSED", "DONE", "CLOSED"].includes(sub.status_code))
      sub.status_code = "READ";
    sub.applications = apps.map((a) => ({
      application_id: a.applicationId,
      unit_id: a.unitId,
      unit_name: a.unitName,
      department_team_id: a.departmentTeamId,
      department_team_name: a.departmentTeamName,
      position_id: a.positionId,
      position_name: a.positionName,
      hr_owner_id: a.hrOwnerId,
      hr_owner_name: a.hrOwnerName,
      is_active: a.isActive,
      version_no: a.versionNo,
      created_at: sub.submitted_at,
      round1_interview_id:
        a.rounds.find((r) => r.roundNo === 1)?.interviewId ?? null,
      round_count: a.rounds.length,
    }));
  }
}
export function newRound(appId: string, roundNo: number): InterviewRound {
  return {
    interviewId: crypto.randomUUID(),
    applicationId: appId,
    roundNo,
    demoTopic: null,
    startAt: null,
    endAt: null,
    interviewFormatId: null,
    roomId: null,
    meetingLink: null,
    scheduleStatus: "AVAILABLE",
    reportStatus: "INTERVIEW_SCHEDULING",
    interviewNote: null,
    isActive: true,
    versionNo: 1,
    updatedAt: now(),
    participants: [],
  };
}
export const ok = <T>(data: T) => ({ success: true as const, data });
export const fail = (code: string) => ({
  success: false as const,
  error: {
    code,
    message: `${code} — thao tác mô phỏng bị từ chối / simulated action rejected`,
  },
});
export const simpleFail = (code: string) => ({
  success: false as const,
  code,
  error: `${code} — thao tác mô phỏng bị từ chối / simulated action rejected`,
});

export function hasPermission(s: State, permission: string) {
  const u = s.users.find((u) => u.appUserId === PEOPLE[s.persona].id);
  return Boolean(
    u?.isActive &&
      u.identityBound &&
      (u.isRootAdmin || (u.isHr && u.permissions.includes(permission))),
  );
}
