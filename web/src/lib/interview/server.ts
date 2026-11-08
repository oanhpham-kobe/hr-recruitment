import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { type AppSession, getServerSession } from "@/lib/auth/session";
import { createServerClient } from "@/lib/supabase/server";
import {
  type ApplicationSelectorOption,
  type InterviewApplicationGroup,
  type InterviewFilterPositionOption,
  type InterviewFilterTeamOption,
  type InterviewFilterUnitOption,
  type InterviewFormatOption,
  type InterviewPageData,
  type InterviewPageFilters,
  type InterviewParticipant,
  type InterviewPermissions,
  type InterviewRoomOption,
  type InterviewRound,
  type InterviewScheduleStatus,
  type InterviewUserOption,
  normalizeInterviewFilters,
  type SubmissionSelectorOption,
} from "./model";

const PAGE_SIZE = 10;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export class InterviewAccessError extends Error {
  constructor() {
    super("Interview access is required");
  }
}
export class InterviewReadError extends Error {
  constructor(message = "Interview data could not be loaded") {
    super(message);
  }
}

export interface InterviewReadDeps {
  client?: SupabaseClient;
  resolveSession?: (client: SupabaseClient) => Promise<AppSession>;
  filters?: Partial<InterviewPageFilters>;
  page?: number;
  pageSize?: number;
}

function has(session: AppSession, permission: string): boolean {
  return Boolean(
    session.user?.roles.includes("ROOT_ADMIN") ||
      session.user?.permissions.includes(permission),
  );
}

function permissions(session: AppSession): InterviewPermissions {
  const root = session.user?.roles.includes("ROOT_ADMIN") === true;
  const view = root || has(session, "interviews.view");
  return {
    canView: view,
    canManage: root || has(session, "interviews.manage"),
    canChangeStatus: root || (view && has(session, "interviews.status")),
    canManageParticipants:
      root || (view && has(session, "interviews.participants")),
    canCreateApplication:
      root ||
      (has(session, "submissions.view") &&
        (has(session, "applications.create") ||
          has(session, "applications.manage"))),
    canReactivateApplication: root || has(session, "applications.manage"),
    canDeleteApplication:
      root ||
      has(session, "applications.delete") ||
      has(session, "applications.manage"),
  };
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}
function numberValue(value: unknown, fallback = 1): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}
function scheduleStatus(value: unknown): InterviewScheduleStatus {
  return value === "SCHEDULED" ||
    value === "AWAITING" ||
    value === "CONFIRMED" ||
    value === "CANCELLED"
    ? value
    : "AVAILABLE";
}

function safeSearchTerm(value: string): string {
  return value
    .trim()
    .slice(0, 256)
    .replace(/[,%_().]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function vietnamDateBoundaryIso(value: string, addDays = 0): string | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) return null;
  const [, year, month, day] = match;
  return new Date(
    Date.UTC(Number(year), Number(month) - 1, Number(day) + addDays, -7, 0, 0),
  ).toISOString();
}

function hasInterviewFilters(filters: InterviewPageFilters): boolean {
  return Boolean(
    filters.scheduleStatus ||
      filters.dateFrom ||
      filters.dateTo ||
      filters.location ||
      filters.interviewFormatId ||
      filters.participantAppUserId,
  );
}

export async function loadInterviewPage(
  deps: InterviewReadDeps = {},
): Promise<InterviewPageData> {
  const client = deps.client ?? (await createServerClient());
  const session = await (deps.resolveSession ?? getServerSession)(client);
  if (!session.user?.isInternal) throw new InterviewAccessError();
  const actorPermissions = permissions(session);
  if (!actorPermissions.canView) throw new InterviewAccessError();

  const filters = normalizeInterviewFilters(deps.filters);
  const pageSize =
    Number.isSafeInteger(deps.pageSize) && (deps.pageSize ?? 0) > 0
      ? (deps.pageSize as number)
      : PAGE_SIZE;
  const page =
    Number.isSafeInteger(deps.page) && (deps.page ?? 0) > 0
      ? (deps.page as number)
      : 1;
  const submissionSearch = safeSearchTerm(filters.query);
  const interviewFiltersActive = hasInterviewFilters(filters);
  const participantEmbed = filters.participantAppUserId
    ? ",filtered_participants:interview_participants!inner(app_user_id,is_current)"
    : "";
  const submissionEmbed = submissionSearch
    ? ",filtered_submission:submissions!inner(submission_id,full_name,email_snapshot,phone)"
    : "";
  const interviewEmbed = interviewFiltersActive
    ? `,filtered_interviews:interviews!inner(interview_id,schedule_status_code,start_at,room_id,meeting_link,interview_format_id${participantEmbed})`
    : "";
  const applicationSelect = `application_id,submission_id,unit_id,department_team_id,position_id,hr_owner_id,is_active,version_no,updated_at${submissionEmbed}${interviewEmbed}`;
  let applicationQuery = client
    .from("applications")
    .select(applicationSelect, { count: "exact" })
    .order("updated_at", { ascending: false })
    .range((page - 1) * pageSize, page * pageSize - 1);
  if (filters.activity === "ACTIVE")
    applicationQuery = applicationQuery.eq("is_active", true);
  if (filters.activity === "INACTIVE")
    applicationQuery = applicationQuery.eq("is_active", false);
  if (submissionSearch) {
    const pattern = `%${submissionSearch}%`;
    applicationQuery = applicationQuery.or(
      `full_name.ilike.${pattern},email_snapshot.ilike.${pattern},phone.ilike.${pattern}`,
      { referencedTable: "filtered_submission" },
    );
  }
  if (filters.unitId)
    applicationQuery = applicationQuery.eq("unit_id", filters.unitId);
  if (filters.departmentTeamId)
    applicationQuery = applicationQuery.eq(
      "department_team_id",
      filters.departmentTeamId,
    );
  if (filters.positionId)
    applicationQuery = applicationQuery.eq("position_id", filters.positionId);
  if (filters.hrOwnerId)
    applicationQuery = applicationQuery.eq("hr_owner_id", filters.hrOwnerId);
  if (filters.scheduleStatus)
    applicationQuery = applicationQuery.eq(
      "filtered_interviews.schedule_status_code",
      filters.scheduleStatus,
    );
  const dateFrom = filters.dateFrom
    ? vietnamDateBoundaryIso(filters.dateFrom)
    : null;
  const dateToExclusive = filters.dateTo
    ? vietnamDateBoundaryIso(filters.dateTo, 1)
    : null;
  if (dateFrom)
    applicationQuery = applicationQuery.gte(
      "filtered_interviews.start_at",
      dateFrom,
    );
  if (dateToExclusive)
    applicationQuery = applicationQuery.lt(
      "filtered_interviews.start_at",
      dateToExclusive,
    );
  if (filters.interviewFormatId)
    applicationQuery = applicationQuery.eq(
      "filtered_interviews.interview_format_id",
      filters.interviewFormatId,
    );
  if (filters.location === "ONLINE")
    applicationQuery = applicationQuery.not(
      "filtered_interviews.meeting_link",
      "is",
      null,
    );
  if (filters.location.startsWith("ROOM:"))
    applicationQuery = applicationQuery.eq(
      "filtered_interviews.room_id",
      filters.location.slice(5),
    );
  if (filters.participantAppUserId) {
    applicationQuery = applicationQuery
      .eq(
        "filtered_interviews.filtered_participants.app_user_id",
        filters.participantAppUserId,
      )
      .eq("filtered_interviews.filtered_participants.is_current", true);
  }

  const {
    data: applicationData,
    error: applicationError,
    count,
  } = await applicationQuery;
  if (applicationError || !Array.isArray(applicationData))
    throw new InterviewReadError();

  const applications = applicationData as unknown as Array<
    Record<string, unknown>
  >;
  const applicationIds = applications
    .map((row) => stringValue(row.application_id))
    .filter((id): id is string => id !== null);
  const submissionIds = applications
    .map((row) => stringValue(row.submission_id))
    .filter((id): id is string => id !== null);

  const [submissionsResult, interviewsResult, reference] = await Promise.all([
    submissionIds.length
      ? client
          .from("submissions")
          .select(
            "submission_id,candidate_id,full_name,email_snapshot,phone,submitted_at,status_code",
          )
          .in("submission_id", submissionIds)
      : Promise.resolve({ data: [], error: null }),
    applicationIds.length
      ? client
          .from("interviews")
          .select(
            "interview_id,application_id,round_no,demo_topic,start_at,end_at,interview_format_id,room_id,meeting_link,schedule_status_code,report_status_code,interview_note,is_active,version_no,updated_at",
          )
          .in("application_id", applicationIds)
          .order("round_no", { ascending: true })
      : Promise.resolve({ data: [], error: null }),
    loadReferenceOptions(client),
  ]);

  const requiredResults = [submissionsResult, interviewsResult];
  if (requiredResults.some((result) => result.error))
    throw new InterviewReadError();

  const interviewRows = Array.isArray(interviewsResult.data)
    ? (interviewsResult.data as Array<Record<string, unknown>>)
    : [];
  const interviewIds = interviewRows
    .map((row) => stringValue(row.interview_id))
    .filter((id): id is string => id !== null);
  const { data: participantData, error: participantError } = interviewIds.length
    ? await client
        .from("interview_participants")
        .select(
          "interview_participant_id,interview_id,app_user_id,participant_order,snapshot_name,snapshot_job_title,snapshot_email,is_current,removed_at,version_no",
        )
        .in("interview_id", interviewIds)
        .order("participant_order", { ascending: true })
    : { data: [], error: null };
  if (participantError) throw new InterviewReadError();
  const participantRows = Array.isArray(participantData)
    ? (participantData as Array<Record<string, unknown>>)
    : [];
  const participantIds = participantRows
    .map((row) => stringValue(row.interview_participant_id))
    .filter((id): id is string => id !== null);
  const reportParticipants = new Set<string>();
  if (participantIds.length) {
    const { data: reportData } = await client
      .from("interview_reports")
      .select("interview_participant_id")
      .in("interview_participant_id", participantIds);
    for (const row of Array.isArray(reportData) ? reportData : []) {
      const id = stringValue(
        (row as { interview_participant_id?: unknown })
          .interview_participant_id,
      );
      if (id) reportParticipants.add(id);
    }
  }

  const submissions = new Map<string, Record<string, unknown>>();
  for (const row of Array.isArray(submissionsResult.data)
    ? submissionsResult.data
    : []) {
    const record = row as Record<string, unknown>;
    const id = stringValue(record.submission_id);
    if (id) submissions.set(id, record);
  }
  const units = new Map(
    reference.filterUnits.map((item) => [item.id, item.name]),
  );
  const teams = new Map(
    reference.filterTeams.map((item) => [item.id, item.name]),
  );
  const positions = new Map(
    reference.filterPositions.map((item) => [item.id, item.name]),
  );
  const owners = new Map(
    reference.filterHrOwners.map((item) => [item.id, item.name]),
  );

  const participantsByInterview = new Map<string, InterviewParticipant[]>();
  for (const row of participantRows) {
    const participantId = stringValue(row.interview_participant_id);
    const interviewId = stringValue(row.interview_id);
    const appUserId = stringValue(row.app_user_id);
    const name = stringValue(row.snapshot_name);
    const email = stringValue(row.snapshot_email);
    if (!participantId || !interviewId || !appUserId || !name || !email)
      continue;
    const item: InterviewParticipant = {
      interviewParticipantId: participantId,
      appUserId,
      order: numberValue(row.participant_order),
      name,
      email,
      jobTitle: stringValue(row.snapshot_job_title),
      isCurrent: row.is_current === true,
      removedAt: stringValue(row.removed_at),
      versionNo: numberValue(row.version_no),
      hasReportHistory: reportParticipants.has(participantId),
    };
    const list = participantsByInterview.get(interviewId) ?? [];
    list.push(item);
    participantsByInterview.set(interviewId, list);
  }

  const roundsByApplication = new Map<string, InterviewRound[]>();
  for (const row of interviewRows) {
    const interviewId = stringValue(row.interview_id);
    const applicationId = stringValue(row.application_id);
    if (!interviewId || !applicationId) continue;
    const round: InterviewRound = {
      interviewId,
      applicationId,
      roundNo: numberValue(row.round_no),
      demoTopic: stringValue(row.demo_topic),
      startAt: stringValue(row.start_at),
      endAt: stringValue(row.end_at),
      interviewFormatId: stringValue(row.interview_format_id),
      roomId: stringValue(row.room_id),
      meetingLink: stringValue(row.meeting_link),
      scheduleStatus: scheduleStatus(row.schedule_status_code),
      reportStatus:
        stringValue(row.report_status_code) ?? "INTERVIEW_SCHEDULING",
      interviewNote: stringValue(row.interview_note),
      isActive: row.is_active === true,
      versionNo: numberValue(row.version_no),
      updatedAt: stringValue(row.updated_at) ?? "",
      participants: participantsByInterview.get(interviewId) ?? [],
    };
    const list = roundsByApplication.get(applicationId) ?? [];
    list.push(round);
    roundsByApplication.set(applicationId, list);
  }

  const groups: InterviewApplicationGroup[] = applications.flatMap((row) => {
    const applicationId = stringValue(row.application_id);
    const submissionId = stringValue(row.submission_id);
    const unitId = stringValue(row.unit_id);
    const positionId = stringValue(row.position_id);
    const hrOwnerId = stringValue(row.hr_owner_id);
    if (!applicationId || !submissionId || !unitId || !positionId || !hrOwnerId)
      return [];
    const submission = submissions.get(submissionId);
    if (!submission) return [];
    const candidateId = stringValue(submission.candidate_id);
    const fullName = stringValue(submission.full_name);
    const email = stringValue(submission.email_snapshot);
    const phone = stringValue(submission.phone);
    const submittedAt = stringValue(submission.submitted_at);
    if (!candidateId || !fullName || !email || !phone || !submittedAt)
      return [];
    const teamId = stringValue(row.department_team_id);
    return [
      {
        applicationId,
        submissionId,
        candidateId,
        candidateName: fullName,
        candidateEmail: email,
        candidatePhone: phone,
        submissionDate: submittedAt,
        submissionStatus: stringValue(submission.status_code) ?? "READ",
        unitId,
        unitName: units.get(unitId) ?? "—",
        departmentTeamId: teamId,
        departmentTeamName: teamId ? (teams.get(teamId) ?? "—") : null,
        positionId,
        positionName: positions.get(positionId) ?? "—",
        hrOwnerId,
        hrOwnerName: owners.get(hrOwnerId) ?? "—",
        isActive: row.is_active === true,
        versionNo: numberValue(row.version_no),
        rounds: roundsByApplication.get(applicationId) ?? [],
      },
    ];
  });

  const total = typeof count === "number" ? count : groups.length;
  const pageCount = Math.max(1, Math.ceil(total / pageSize));
  return {
    groups,
    page: Math.min(page, pageCount),
    pageCount,
    permissions: actorPermissions,
    ...reference,
  };
}

async function loadReferenceOptions(client: SupabaseClient): Promise<{
  formats: InterviewFormatOption[];
  rooms: InterviewRoomOption[];
  participantUsers: InterviewUserOption[];
  filterUnits: InterviewFilterUnitOption[];
  filterTeams: InterviewFilterTeamOption[];
  filterPositions: InterviewFilterPositionOption[];
  filterHrOwners: InterviewUserOption[];
}> {
  const [formats, rooms, users, units, teams, positions] = await Promise.all([
    client
      .from("interview_formats")
      .select(
        "interview_format_id,code,name_vi,requires_room,requires_meeting_link,is_active",
      )
      .order("name_vi"),
    client
      .from("rooms")
      .select("room_id,code,display_name,building,is_active")
      .order("display_name"),
    client
      .from("app_users")
      .select("app_user_id,full_name,email,job_title,is_active")
      .order("full_name"),
    client
      .from("organizational_units")
      .select("unit_id,name_vi")
      .order("name_vi"),
    client
      .from("department_teams")
      .select("department_team_id,unit_id,name_vi")
      .order("name_vi"),
    client
      .from("positions")
      .select("position_id,unit_id,department_team_id,name_vi")
      .order("name_vi"),
  ]);
  if (
    formats.error ||
    rooms.error ||
    users.error ||
    units.error ||
    teams.error ||
    positions.error
  )
    throw new InterviewReadError();
  return {
    formats: (Array.isArray(formats.data) ? formats.data : []).flatMap(
      (raw) => {
        const row = raw as Record<string, unknown>;
        const id = stringValue(row.interview_format_id);
        const code = stringValue(row.code);
        const name = stringValue(row.name_vi);
        if (!id || !code || !name) return [];
        return [
          {
            id,
            code,
            name,
            requiresRoom: row.requires_room === true,
            requiresMeetingLink: row.requires_meeting_link === true,
            isActive: row.is_active === true,
          },
        ];
      },
    ),
    rooms: (Array.isArray(rooms.data) ? rooms.data : []).flatMap((raw) => {
      const row = raw as Record<string, unknown>;
      const id = stringValue(row.room_id);
      const name = stringValue(row.display_name);
      if (!id || !name) return [];
      return [
        {
          id,
          code: stringValue(row.code),
          name,
          building: stringValue(row.building),
          isActive: row.is_active === true,
        },
      ];
    }),
    participantUsers: (Array.isArray(users.data) ? users.data : []).flatMap(
      (raw) => {
        const row = raw as Record<string, unknown>;
        const id = stringValue(row.app_user_id);
        const name = stringValue(row.full_name);
        const email = stringValue(row.email);
        if (!id || !name || !email || row.is_active !== true) return [];
        return [{ id, name, email, jobTitle: stringValue(row.job_title) }];
      },
    ),
    filterUnits: (Array.isArray(units.data) ? units.data : []).flatMap(
      (raw) => {
        const row = raw as Record<string, unknown>;
        const id = stringValue(row.unit_id);
        const name = stringValue(row.name_vi);
        return id && name ? [{ id, name }] : [];
      },
    ),
    filterTeams: (Array.isArray(teams.data) ? teams.data : []).flatMap(
      (raw) => {
        const row = raw as Record<string, unknown>;
        const id = stringValue(row.department_team_id);
        const unitId = stringValue(row.unit_id);
        const name = stringValue(row.name_vi);
        return id && unitId && name ? [{ id, unitId, name }] : [];
      },
    ),
    filterPositions: (Array.isArray(positions.data)
      ? positions.data
      : []
    ).flatMap((raw) => {
      const row = raw as Record<string, unknown>;
      const id = stringValue(row.position_id);
      const unitId = stringValue(row.unit_id);
      const name = stringValue(row.name_vi);
      return id && unitId && name
        ? [
            {
              id,
              unitId,
              departmentTeamId: stringValue(row.department_team_id),
              name,
            },
          ]
        : [];
    }),
    filterHrOwners: (Array.isArray(users.data) ? users.data : []).flatMap(
      (raw) => {
        const row = raw as Record<string, unknown>;
        const id = stringValue(row.app_user_id);
        const name = stringValue(row.full_name);
        const email = stringValue(row.email);
        return id && name && email
          ? [{ id, name, email, jobTitle: stringValue(row.job_title) }]
          : [];
      },
    ),
  };
}

async function requireInternalPermission(
  client: SupabaseClient,
  required: string[],
  resolveSession: (
    client: SupabaseClient,
  ) => Promise<AppSession> = getServerSession,
): Promise<AppSession> {
  const session = await resolveSession(client);
  if (!session.user?.isInternal) throw new InterviewAccessError();
  const root = session.user.roles.includes("ROOT_ADMIN");
  if (
    !root &&
    !required.every((permission) =>
      session.user?.permissions.includes(permission),
    )
  )
    throw new InterviewAccessError();
  return session;
}

export async function searchSubmissionOptions(
  rawQuery = "",
  deps: {
    client?: SupabaseClient;
    resolveSession?: (client: SupabaseClient) => Promise<AppSession>;
  } = {},
): Promise<SubmissionSelectorOption[]> {
  const client = deps.client ?? (await createServerClient());
  await requireInternalPermission(
    client,
    ["submissions.view"],
    deps.resolveSession ?? getServerSession,
  );
  const query = safeSearchTerm(rawQuery);
  let builder = client
    .from("submissions")
    .select("submission_id,full_name,email_snapshot,submitted_at,status_code")
    .order("submitted_at", { ascending: false })
    .limit(25);
  if (query) {
    const pattern = `%${query}%`;
    builder = builder.or(
      `full_name.ilike.${pattern},email_snapshot.ilike.${pattern},phone.ilike.${pattern}`,
    );
  }
  const { data, error } = await builder;
  if (error) throw new InterviewReadError();
  return (Array.isArray(data) ? data : []).flatMap((raw) => {
    const row = raw as Record<string, unknown>;
    const submissionId = stringValue(row.submission_id);
    const candidateName = stringValue(row.full_name);
    const verifiedEmail = stringValue(row.email_snapshot);
    const submittedAt = stringValue(row.submitted_at);
    if (!submissionId || !candidateName || !verifiedEmail || !submittedAt)
      return [];
    return [
      {
        submissionId,
        candidateName,
        verifiedEmail,
        submittedAt,
        status: stringValue(row.status_code) ?? "READ",
      },
    ];
  });
}

export async function searchApplicationOptions(
  rawQuery = "",
  deps: {
    client?: SupabaseClient;
    resolveSession?: (client: SupabaseClient) => Promise<AppSession>;
  } = {},
): Promise<ApplicationSelectorOption[]> {
  const client = deps.client ?? (await createServerClient());
  await requireInternalPermission(
    client,
    ["interviews.view"],
    deps.resolveSession ?? getServerSession,
  );
  const query = safeSearchTerm(rawQuery);
  const submissionEmbed = query
    ? ",filtered_submission:submissions!inner(submission_id,full_name,email_snapshot,phone)"
    : "";
  const applicationSelect: string = `application_id,submission_id,version_no,unit_id,department_team_id,position_id${submissionEmbed}`;
  let appBuilder = client
    .from("applications")
    .select(applicationSelect)
    .eq("is_active", true)
    .order("updated_at", { ascending: false })
    .limit(50);
  if (query) {
    const pattern = `%${query}%`;
    appBuilder = appBuilder.or(
      `full_name.ilike.${pattern},email_snapshot.ilike.${pattern},phone.ilike.${pattern}`,
      { referencedTable: "filtered_submission" },
    );
  }
  const { data: apps, error: appError } = await appBuilder;
  if (appError || !Array.isArray(apps)) throw new InterviewReadError();
  const appRows = apps as unknown as Array<Record<string, unknown>>;
  const applicationIds = appRows
    .map((row) => stringValue(row.application_id))
    .filter((id): id is string => Boolean(id));
  const submissionIds = appRows
    .map((row) => stringValue(row.submission_id))
    .filter((id): id is string => Boolean(id));
  if (!applicationIds.length) return [];
  const [subs, rounds, units, teams, positions] = await Promise.all([
    client
      .from("submissions")
      .select("submission_id,full_name,email_snapshot")
      .in("submission_id", submissionIds),
    client
      .from("interviews")
      .select("interview_id,application_id,round_no,version_no")
      .in("application_id", applicationIds)
      .order("round_no", { ascending: false }),
    client.from("organizational_units").select("unit_id,name_vi"),
    client.from("department_teams").select("department_team_id,name_vi"),
    client.from("positions").select("position_id,name_vi"),
  ]);
  if (
    subs.error ||
    rounds.error ||
    units.error ||
    teams.error ||
    positions.error
  )
    throw new InterviewReadError();
  const subMap = new Map<string, Record<string, unknown>>();
  for (const raw of Array.isArray(subs.data) ? subs.data : []) {
    const row = raw as Record<string, unknown>;
    const id = stringValue(row.submission_id);
    if (id) subMap.set(id, row);
  }
  const unitMap = new Map(
    (Array.isArray(units.data) ? units.data : []).map((raw) => {
      const row = raw as Record<string, unknown>;
      return [
        stringValue(row.unit_id) ?? "",
        stringValue(row.name_vi) ?? "—",
      ] as const;
    }),
  );
  const teamMap = new Map(
    (Array.isArray(teams.data) ? teams.data : []).map((raw) => {
      const row = raw as Record<string, unknown>;
      return [
        stringValue(row.department_team_id) ?? "",
        stringValue(row.name_vi) ?? "—",
      ] as const;
    }),
  );
  const positionMap = new Map(
    (Array.isArray(positions.data) ? positions.data : []).map((raw) => {
      const row = raw as Record<string, unknown>;
      return [
        stringValue(row.position_id) ?? "",
        stringValue(row.name_vi) ?? "—",
      ] as const;
    }),
  );
  const latest = new Map<string, Record<string, unknown>>();
  for (const raw of Array.isArray(rounds.data) ? rounds.data : []) {
    const row = raw as Record<string, unknown>;
    const applicationId = stringValue(row.application_id);
    if (applicationId && !latest.has(applicationId))
      latest.set(applicationId, row);
  }
  return appRows.flatMap((row) => {
    const applicationId = stringValue(row.application_id);
    const submissionId = stringValue(row.submission_id);
    const unitId = stringValue(row.unit_id);
    const positionId = stringValue(row.position_id);
    if (!applicationId || !submissionId || !unitId || !positionId) return [];
    const sub = subMap.get(submissionId);
    const round = latest.get(applicationId);
    const candidateName = sub ? stringValue(sub.full_name) : null;
    const candidateEmail = sub ? stringValue(sub.email_snapshot) : null;
    const latestRoundId = round ? stringValue(round.interview_id) : null;
    if (!candidateName || !candidateEmail || !latestRoundId) return [];
    const teamId = stringValue(row.department_team_id);
    const identity = [
      positionMap.get(positionId) ?? "—",
      teamId ? (teamMap.get(teamId) ?? "—") : null,
      unitMap.get(unitId) ?? "—",
    ]
      .filter(Boolean)
      .join(" - ");
    return [
      {
        applicationId,
        label: `${candidateName} — ${identity}`,
        candidateName,
        candidateEmail,
        versionNo: numberValue(row.version_no),
        latestRoundId,
        latestRoundVersionNo: numberValue(round?.version_no),
        latestRoundNo: numberValue(round?.round_no),
      },
    ];
  });
}

export function isValidApplicationId(value: string): boolean {
  return UUID.test(value);
}
