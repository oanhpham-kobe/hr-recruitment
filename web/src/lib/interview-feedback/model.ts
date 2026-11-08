export interface Question {
  key: string;
  label: string;
  required: boolean;
}
export interface Template {
  template_id: string;
  family_id: string;
  version_no: number;
  name: string;
  questions: Question[];
  published_at: string;
}
export interface InterviewContext {
  interview_id: string;
  application_id: string;
  candidate_name: string;
  position_name: string;
  unit_name: string;
  round_no: number;
  start_at: string | null;
  end_at: string | null;
  readable: boolean;
  writable: boolean;
}
export interface InterviewOption extends InterviewContext {
  collection_id: string | null;
  participants: { participant_id: string; evaluator_name: string }[];
}
export interface Collection {
  collection_id: string;
  interview_id: string;
  template_id: string;
  deadline_at: string | null;
  created_at: string;
}
export interface Invitation {
  invitation_id: string;
  participant_id: string;
  evaluator_name: string;
  state: "DRAFT" | "SUBMITTED" | "REVOKED";
  answers: Record<string, string>;
  version_no: number;
  submitted_at: string | null;
  available: boolean;
  delivery_state: "PROVIDER_PAUSED";
}
export interface Blocker {
  invitation_id: string;
  evaluator_name: string;
  reason: string;
}
export interface Snapshot {
  context: InterviewContext;
  template: Template;
  evaluators: {
    invitation_id: string;
    participant_id: string;
    evaluator_name: string;
    answer_version_no: number;
    submitted_at: string;
  }[];
  questions: (Question & {
    answers: {
      invitation_id: string;
      evaluator_name: string;
      answer: string | null;
    }[];
  })[];
}
export interface Consolidation {
  collection_id: string;
  title: string;
  overall_summary: string;
  snapshot: Snapshot;
  version_no: number;
  state: "DRAFT" | "APPROVED";
  created_at: string;
  approved_at: string | null;
}
interface DetailBase {
  collection: Collection;
  context: InterviewContext;
  template: Template;
}
export interface HrDetail extends DetailBase {
  mode: "HR";
  invitations: Invitation[];
  blockers: Blocker[];
  consolidation: Consolidation | null;
}
export interface OwnDetail extends DetailBase {
  mode: "OWN";
  invitation: Invitation;
}
export type Detail = HrDetail | OwnDetail;
export interface CollectionSummary extends Collection {
  context: InterviewContext;
  selected_count: number;
  submitted_count: number;
  blockers: Blocker[];
  consolidation_state: null | "DRAFT" | "APPROVED";
}
export interface OwnInvitationSummary {
  invitation_id: string;
  collection_id: string;
  evaluator_name: string;
  state: Invitation["state"];
  version_no: number;
  deadline_at: string | null;
  context: InterviewContext;
}
export interface Workspace {
  can_manage: boolean;
  templates: Template[];
  interviews: InterviewOption[];
  collections: CollectionSummary[];
  invitations: OwnInvitationSummary[];
}
export type Result<T> =
  | { success: true; data: T }
  | { success: false; error: { code: string } };
export interface PublishInput {
  name: string;
  questions: Question[];
  previousTemplateId: string | null;
  idempotencyKey: string;
}
export interface CreateInput {
  interviewId: string;
  templateId: string;
  participantIds: string[];
  deadlineAt: string | null;
  idempotencyKey: string;
}
export interface ResponseInput {
  invitationId: string;
  answers: Record<string, string>;
  expectedVersionNo: number;
  submit: boolean;
}
export interface ConsolidationInput {
  collectionId: string;
  title: string;
  overallSummary: string;
  expectedVersionNo: number;
  approve: boolean;
}
export interface FeedbackApi {
  workspace: (offset?: number) => Promise<Result<Workspace>>;
  collection: (id: string) => Promise<Result<Detail>>;
  invitation: (id: string) => Promise<Result<OwnDetail>>;
  publish: (input: PublishInput) => Promise<Result<Template>>;
  create: (input: CreateInput) => Promise<Result<Collection>>;
  respond: (input: ResponseInput) => Promise<Result<Invitation>>;
  revoke: (input: {
    invitationId: string;
    expectedVersionNo: number;
  }) => Promise<Result<Invitation>>;
  consolidate: (input: ConsolidationInput) => Promise<Result<Consolidation>>;
}
export const EMPTY_WORKSPACE: Workspace = {
  can_manage: false,
  templates: [],
  interviews: [],
  collections: [],
  invitations: [],
};
export const TRIAL_QUESTIONS: Question[] = [
  {
    key: "professional_knowledge",
    label: "Kiến thức chuyên môn / Professional Knowledge",
    required: false,
  },
  {
    key: "necessary_skills",
    label: "Kỹ năng cần thiết / Necessary Skills",
    required: false,
  },
  {
    key: "qualities_personality",
    label: "Phẩm chất, tính cách / Qualities and Personality",
    required: false,
  },
  {
    key: "strengths_limitations",
    label: "Điểm mạnh và hạn chế / Strengths and Limitations",
    required: false,
  },
  { key: "other_comment", label: "Khác / Other", required: false },
];
