import {
  type Collection,
  type Consolidation,
  type Detail,
  type FeedbackApi,
  type HrDetail,
  type InterviewOption,
  type Invitation,
  type OwnDetail,
  type Result,
  type Template,
  TRIAL_QUESTIONS,
  type Workspace,
} from "@/lib/interview-feedback/model";
export const PREVIEW_STORAGE_KEY = "eiu-synthetic-interview-feedback-v1";
export type PreviewPersona = "hr" | "evaluator-one" | "evaluator-two";
const id = (n: number) =>
  `10100000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const participantIds = [id(11), id(12)];
export const PREVIEW_PEOPLE = [
  { id: "hr", name: "HR — Nguyễn Hải Anh" },
  { id: "evaluator-one", name: "Nguyễn Minh Tâm" },
  { id: "evaluator-two", name: "Trần Thu Hà" },
] as const;
interface State {
  templates: Template[];
  interviews: InterviewOption[];
  collections: Collection[];
  invitations: (Invitation & { collection_id: string })[];
  reports: Consolidation[];
  published: Record<string, string>;
}
function seed(): State {
  return {
    templates: [
      {
        template_id: id(1),
        family_id: id(1),
        version_no: 1,
        name: "Phiếu nhận xét phỏng vấn / Interview feedback",
        questions: TRIAL_QUESTIONS.map((q) => ({ ...q })),
        published_at: "2026-11-05T00:00:00Z",
      },
    ],
    interviews: [
      {
        interview_id: id(2),
        application_id: id(3),
        candidate_name: "Lê Phương Linh (dữ liệu mẫu)",
        position_name: "Giảng viên Công nghệ thông tin",
        unit_name: "Khoa Công nghệ thông tin",
        round_no: 2,
        start_at: "2026-11-10T02:00:00Z",
        end_at: "2026-11-10T03:00:00Z",
        readable: true,
        writable: true,
        collection_id: null,
        participants: participantIds.map((p, i) => ({
          participant_id: p,
          evaluator_name: PREVIEW_PEOPLE[i + 1].name,
        })),
      },
    ],
    collections: [],
    invitations: [],
    reports: [],
    published: {},
  };
}
function read(): State {
  try {
    const raw = localStorage.getItem(PREVIEW_STORAGE_KEY);
    if (raw) return JSON.parse(raw) as State;
  } catch {}
  const state = seed();
  write(state);
  return state;
}
function write(state: State) {
  localStorage.setItem(PREVIEW_STORAGE_KEY, JSON.stringify(state));
}
export function resetPreview() {
  write(seed());
}
const ok = <T>(data: T): Result<T> => ({
  success: true,
  data: structuredClone(data),
});
const fail = <T>(code: string): Result<T> => ({
  success: false,
  error: { code },
});
const ownParticipant = (persona: PreviewPersona) =>
  persona === "evaluator-one"
    ? participantIds[0]
    : persona === "evaluator-two"
      ? participantIds[1]
      : null;
function detail(
  state: State,
  collection: Collection,
  persona: PreviewPersona,
  ownId?: string,
): Result<Detail> {
  const context = state.interviews.find(
    (i) => i.interview_id === collection.interview_id,
  );
  const template = state.templates.find(
    (t) => t.template_id === collection.template_id,
  );
  if (!context || !template) return fail("NOT_FOUND");
  const invitations = state.invitations.filter(
    (i) => i.collection_id === collection.collection_id,
  );
  const base = { collection, context, template };
  if (persona !== "hr" || ownId) {
    const invitation = invitations.find(
      (i) =>
        i.participant_id === ownParticipant(persona) &&
        (!ownId || i.invitation_id === ownId),
    );
    if (!invitation?.available || invitation.state === "REVOKED")
      return fail("FORBIDDEN");
    return ok({ ...base, mode: "OWN", invitation } as OwnDetail);
  }
  const blockers = invitations
    .filter((i) => i.state !== "SUBMITTED" || !i.available)
    .map((i) => ({
      invitation_id: i.invitation_id,
      evaluator_name: i.evaluator_name,
      reason:
        i.state === "REVOKED"
          ? "INVITATION_REVOKED"
          : !i.available
            ? "EVALUATOR_UNAVAILABLE"
            : "RESPONSE_NOT_SUBMITTED",
    }));
  return ok({
    ...base,
    mode: "HR",
    invitations,
    blockers,
    consolidation:
      state.reports.find((r) => r.collection_id === collection.collection_id) ??
      null,
  } as HrDetail);
}
export function previewApi(persona: PreviewPersona): FeedbackApi {
  return {
    async workspace(offset = 0) {
      const s = read();
      const summaries = s.collections.map((c) => {
        const d = detail(s, c, "hr");
        if (!d.success || d.data.mode !== "HR")
          throw new Error("Invalid synthetic state");
        return {
          ...c,
          context: d.data.context,
          selected_count: d.data.invitations.length,
          submitted_count: d.data.invitations.filter(
            (i) => i.state === "SUBMITTED" && i.available,
          ).length,
          blockers: d.data.blockers,
          consolidation_state: d.data.consolidation?.state ?? null,
        };
      });
      const invitations = s.invitations
        .filter(
          (i) =>
            i.participant_id === ownParticipant(persona) &&
            i.available &&
            i.state !== "REVOKED",
        )
        .map((i) => {
          const c = s.collections.find(
            (c) => c.collection_id === i.collection_id,
          );
          if (!c) throw new Error("Invalid synthetic state");
          return {
            invitation_id: i.invitation_id,
            collection_id: c.collection_id,
            evaluator_name: i.evaluator_name,
            state: i.state,
            version_no: i.version_no,
            deadline_at: c.deadline_at,
            context: s.interviews.find(
              (v) => v.interview_id === c.interview_id,
            ) as InterviewOption,
          };
        });
      return ok({
        can_manage: persona === "hr",
        templates:
          persona === "hr" ? s.templates.slice(offset, offset + 50) : [],
        interviews:
          persona === "hr" ? s.interviews.slice(offset, offset + 50) : [],
        collections:
          persona === "hr" ? summaries.slice(offset, offset + 50) : [],
        invitations: invitations.slice(offset, offset + 50),
      } as Workspace);
    },
    async collection(collectionId) {
      const s = read();
      const c = s.collections.find((c) => c.collection_id === collectionId);
      return c ? detail(s, c, persona) : fail("NOT_FOUND");
    },
    async invitation(invitationId) {
      const s = read();
      const i = s.invitations.find((i) => i.invitation_id === invitationId);
      const c = s.collections.find((c) => c.collection_id === i?.collection_id);
      if (!c) return fail("NOT_FOUND");
      return detail(s, c, persona, invitationId) as Result<OwnDetail>;
    },
    async publish(input) {
      if (persona !== "hr") return fail("FORBIDDEN");
      if (
        !input.name.trim() ||
        input.questions.length < 1 ||
        input.questions.length > 30 ||
        input.questions.some((q) => !q.label.trim())
      )
        return fail("VALIDATION_ERROR");
      const s = read();
      const replay = s.templates.find(
        (t) => t.template_id === s.published[input.idempotencyKey],
      );
      if (replay) return ok(replay);
      const previous = s.templates.find(
        (t) => t.template_id === input.previousTemplateId,
      );
      const templateId = crypto.randomUUID();
      const value: Template = {
        template_id: templateId,
        family_id: previous?.family_id ?? templateId,
        version_no: previous
          ? Math.max(
              ...s.templates
                .filter((t) => t.family_id === previous.family_id)
                .map((t) => t.version_no),
            ) + 1
          : 1,
        name: input.name.trim(),
        questions: structuredClone(input.questions),
        published_at: new Date().toISOString(),
      };
      s.templates.push(value);
      s.published[input.idempotencyKey] = value.template_id;
      write(s);
      return ok(value);
    },
    async create(input) {
      if (persona !== "hr") return fail("FORBIDDEN");
      const s = read();
      const existing = s.collections.find(
        (c) => c.interview_id === input.interviewId,
      );
      if (existing) return ok(existing);
      const interview = s.interviews.find(
        (i) => i.interview_id === input.interviewId,
      );
      if (!interview?.writable) return fail("CONTEXT_NOT_WRITABLE");
      if (
        !s.templates.some((t) => t.template_id === input.templateId) ||
        !input.participantIds.length ||
        input.participantIds.some(
          (p) => !interview.participants.some((v) => v.participant_id === p),
        ) ||
        (input.deadlineAt && Date.parse(input.deadlineAt) <= Date.now())
      )
        return fail("VALIDATION_ERROR");
      const c: Collection = {
        collection_id: crypto.randomUUID(),
        interview_id: input.interviewId,
        template_id: input.templateId,
        deadline_at: input.deadlineAt,
        created_at: new Date().toISOString(),
      };
      s.collections.push(c);
      interview.collection_id = c.collection_id;
      for (const p of input.participantIds) {
        s.invitations.push({
          invitation_id: crypto.randomUUID(),
          participant_id: p,
          evaluator_name:
            interview.participants.find((v) => v.participant_id === p)
              ?.evaluator_name ?? "",
          state: "DRAFT",
          answers: {},
          version_no: 1,
          submitted_at: null,
          available: true,
          delivery_state: "PROVIDER_PAUSED",
          collection_id: c.collection_id,
        });
      }
      write(s);
      return ok(c);
    },
    async respond(input) {
      const s = read();
      const i = s.invitations.find(
        (v) => v.invitation_id === input.invitationId,
      );
      if (!i || i.participant_id !== ownParticipant(persona) || !i.available)
        return fail("FORBIDDEN");
      const c = s.collections.find((c) => c.collection_id === i.collection_id);
      if (!c) return fail("NOT_FOUND");
      if (i.state === "REVOKED") return fail("INVITATION_REVOKED");
      if (i.state === "SUBMITTED") {
        if (
          input.submit &&
          JSON.stringify(input.answers) === JSON.stringify(i.answers) &&
          [i.version_no, i.version_no - 1].includes(input.expectedVersionNo)
        )
          return ok(i);
        return fail("ALREADY_SUBMITTED");
      }
      if (c.deadline_at && Date.parse(c.deadline_at) <= Date.now())
        return fail("DEADLINE_PASSED");
      if (i.version_no !== input.expectedVersionNo)
        return fail("STALE_VERSION");
      const template = s.templates.find((t) => t.template_id === c.template_id);
      if (!template) return fail("NOT_FOUND");
      if (
        input.submit &&
        template.questions.some(
          (q) => q.required && !input.answers[q.key]?.trim(),
        )
      )
        return fail("REQUIRED_ANSWER_MISSING");
      i.answers = structuredClone(input.answers);
      i.version_no++;
      if (input.submit) {
        i.state = "SUBMITTED";
        i.submitted_at = new Date().toISOString();
      }
      write(s);
      return ok(i);
    },
    async revoke(input) {
      if (persona !== "hr") return fail("FORBIDDEN");
      const s = read();
      const i = s.invitations.find(
        (v) => v.invitation_id === input.invitationId,
      );
      if (!i) return fail("NOT_FOUND");
      if (i.version_no !== input.expectedVersionNo)
        return fail("STALE_VERSION");
      if (i.state !== "DRAFT") return fail("ALREADY_SUBMITTED");
      i.state = "REVOKED";
      i.version_no++;
      write(s);
      return ok(i);
    },
    async consolidate(input) {
      if (persona !== "hr") return fail("FORBIDDEN");
      const s = read();
      const c = s.collections.find(
        (c) => c.collection_id === input.collectionId,
      );
      if (!c) return fail("NOT_FOUND");
      const d = detail(s, c, "hr");
      if (!d.success || d.data.mode !== "HR") return fail("FORBIDDEN");
      if (!d.data.context.writable) return fail("CONTEXT_NOT_WRITABLE");
      if (d.data.blockers.length) return fail("COMPLETENESS_REQUIRED");
      if (!input.title.trim()) return fail("VALIDATION_ERROR");
      let r = s.reports.find((r) => r.collection_id === input.collectionId);
      if (r?.state === "APPROVED") return fail("ALREADY_APPROVED");
      if ((r?.version_no ?? 0) !== input.expectedVersionNo)
        return fail("STALE_VERSION");
      if (!r) {
        if (input.approve) return fail("VALIDATION_ERROR");
        const data = d.data;
        r = {
          collection_id: c.collection_id,
          title: input.title,
          overall_summary: input.overallSummary,
          version_no: 1,
          state: "DRAFT",
          created_at: new Date().toISOString(),
          approved_at: null,
          snapshot: {
            context: structuredClone(data.context),
            template: structuredClone(data.template),
            evaluators: data.invitations.map((i) => ({
              invitation_id: i.invitation_id,
              participant_id: i.participant_id,
              evaluator_name: i.evaluator_name,
              answer_version_no: i.version_no,
              submitted_at: i.submitted_at ?? "",
            })),
            questions: data.template.questions.map((q) => ({
              ...q,
              answers: data.invitations.map((i) => ({
                invitation_id: i.invitation_id,
                evaluator_name: i.evaluator_name,
                answer: i.answers[q.key] ?? null,
              })),
            })),
          },
        };
        s.reports.push(r);
      } else {
        r.version_no++;
        r.title = input.title;
        r.overall_summary = input.overallSummary;
      }
      if (input.approve) {
        r.state = "APPROVED";
        r.approved_at = new Date().toISOString();
      }
      write(s);
      return ok(r);
    },
  };
}
