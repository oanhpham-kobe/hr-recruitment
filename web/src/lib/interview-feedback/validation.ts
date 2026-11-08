import type { Detail, Workspace } from "./model";

type Row = Record<string, unknown>;
const obj = (v: unknown): v is Row =>
  Boolean(v && typeof v === "object" && !Array.isArray(v));
const str = (v: unknown): v is string => typeof v === "string";
const bool = (v: unknown) => typeof v === "boolean";
const num = (v: unknown) => Number.isSafeInteger(v) && Number(v) >= 1;
const nullableString = (v: unknown) => v === null || str(v);
const id = (v: unknown) =>
  str(v) &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    v,
  );
const list = (v: unknown, valid: (x: unknown) => boolean) =>
  Array.isArray(v) && v.every(valid);
const questions = (v: unknown) =>
  list(v, (q) => obj(q) && str(q.key) && str(q.label) && bool(q.required));
export const validTemplate = (v: unknown) =>
  obj(v) &&
  id(v.template_id) &&
  id(v.family_id) &&
  num(v.version_no) &&
  str(v.name) &&
  questions(v.questions) &&
  str(v.published_at);
const context = (v: unknown) =>
  obj(v) &&
  id(v.interview_id) &&
  id(v.application_id) &&
  str(v.candidate_name) &&
  str(v.position_name) &&
  str(v.unit_name) &&
  num(v.round_no) &&
  nullableString(v.start_at) &&
  nullableString(v.end_at) &&
  bool(v.readable) &&
  bool(v.writable);
export const validCollection = (v: unknown) =>
  obj(v) &&
  id(v.collection_id) &&
  id(v.interview_id) &&
  id(v.template_id) &&
  nullableString(v.deadline_at) &&
  str(v.created_at);
export const validInvitation = (v: unknown) =>
  obj(v) &&
  id(v.invitation_id) &&
  id(v.participant_id) &&
  str(v.evaluator_name) &&
  ["DRAFT", "SUBMITTED", "REVOKED"].includes(String(v.state)) &&
  obj(v.answers) &&
  Object.values(v.answers).every(str) &&
  num(v.version_no) &&
  nullableString(v.submitted_at) &&
  bool(v.available) &&
  v.delivery_state === "PROVIDER_PAUSED";
const blockers = (v: unknown) =>
  list(
    v,
    (b) =>
      obj(b) && id(b.invitation_id) && str(b.evaluator_name) && str(b.reason),
  );
export const validConsolidation = (v: unknown): boolean =>
  obj(v) &&
  id(v.collection_id) &&
  str(v.title) &&
  str(v.overall_summary) &&
  num(v.version_no) &&
  ["DRAFT", "APPROVED"].includes(String(v.state)) &&
  str(v.created_at) &&
  nullableString(v.approved_at) &&
  obj(v.snapshot) &&
  context(v.snapshot.context) &&
  validTemplate(v.snapshot.template) &&
  list(
    v.snapshot.evaluators,
    (e) =>
      obj(e) &&
      id(e.invitation_id) &&
      id(e.participant_id) &&
      str(e.evaluator_name) &&
      num(e.answer_version_no) &&
      str(e.submitted_at),
  ) &&
  list(
    v.snapshot.questions,
    (q) =>
      obj(q) &&
      str(q.key) &&
      str(q.label) &&
      bool(q.required) &&
      list(
        q.answers,
        (a) =>
          obj(a) &&
          id(a.invitation_id) &&
          str(a.evaluator_name) &&
          nullableString(a.answer),
      ),
  );
export function validDetail(v: unknown): v is Detail {
  return (
    obj(v) &&
    validCollection(v.collection) &&
    context(v.context) &&
    validTemplate(v.template) &&
    (v.mode === "OWN"
      ? validInvitation(v.invitation)
      : v.mode === "HR" &&
        list(v.invitations, validInvitation) &&
        blockers(v.blockers) &&
        (v.consolidation === null || validConsolidation(v.consolidation)))
  );
}
export function validWorkspace(v: unknown): v is Workspace {
  return (
    obj(v) &&
    bool(v.can_manage) &&
    list(v.templates, validTemplate) &&
    list(
      v.interviews,
      (i) =>
        obj(i) &&
        context(i) &&
        (i.collection_id === null || id(i.collection_id)) &&
        list(
          i.participants,
          (p) => obj(p) && id(p.participant_id) && str(p.evaluator_name),
        ),
    ) &&
    list(
      v.collections,
      (c) =>
        obj(c) &&
        validCollection(c) &&
        context(c.context) &&
        Number.isSafeInteger(c.selected_count) &&
        Number(c.selected_count) >= 0 &&
        Number.isSafeInteger(c.submitted_count) &&
        Number(c.submitted_count) >= 0 &&
        blockers(c.blockers) &&
        [null, "DRAFT", "APPROVED"].includes(
          c.consolidation_state as null | string,
        ),
    ) &&
    list(
      v.invitations,
      (i) =>
        obj(i) &&
        id(i.invitation_id) &&
        id(i.collection_id) &&
        str(i.evaluator_name) &&
        ["DRAFT", "SUBMITTED", "REVOKED"].includes(String(i.state)) &&
        num(i.version_no) &&
        nullableString(i.deadline_at) &&
        context(i.context),
    )
  );
}
export function validRpcData(name: string, data: unknown): boolean {
  switch (name) {
    case "get_interview_feedback_workspace":
      return validWorkspace(data);
    case "get_interview_feedback_collection":
      return validDetail(data);
    case "get_interview_feedback_invitation":
      return validDetail(data) && data.mode === "OWN";
    case "publish_interview_feedback_template":
      return validTemplate(data);
    case "create_interview_feedback_collection":
      return validCollection(data);
    case "save_interview_feedback_response":
    case "revoke_interview_feedback_invitation":
      return validInvitation(data);
    case "save_interview_feedback_consolidation":
      return validConsolidation(data);
    default:
      return false;
  }
}
