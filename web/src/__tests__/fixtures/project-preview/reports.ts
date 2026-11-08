import type { HrReportFilters, HrReportPageData } from "@/lib/reports/hr-model";
import {
  EMPTY_REPORT_FIELDS,
  type InterviewerReportPageData,
  projectInterviewerReportStatus,
  type RawReportStatus,
  type ReportFields,
} from "@/lib/reports/model";
import type { SaveInterviewerReportInput } from "@/lib/reports/server";
import {
  currentRound,
  fail,
  findRound,
  hasPermission,
  mutate,
  now,
  ok,
  PEOPLE,
  read,
  type State,
} from "./store";

function participantReports(s: State, interviewId: string) {
  const f = findRound(s, interviewId);
  return (
    f?.round.participants
      .filter((p) => p.isCurrent)
      .map((p) => ({
        p,
        report: s.reports.find(
          (r) => r.participantId === p.interviewParticipantId && r.active,
        ),
      })) ?? []
  );
}
function decision(s: State, interviewId: string) {
  return participantReports(s, interviewId)
    .filter(
      (v) =>
        v.report &&
        [
          "conclusion",
          "expected_specific_job_assigned",
          "expected_recruitment_time",
        ].some((k) => v.report?.fields[k as keyof ReportFields]?.trim()),
    )
    .sort(
      (a, b) =>
        (b.report?.decisionAt ?? "").localeCompare(
          a.report?.decisionAt ?? "",
        ) || (b.report?.reportId ?? "").localeCompare(a.report?.reportId ?? ""),
    )[0];
}
export function hrData(filters?: Partial<HrReportFilters>): HrReportPageData {
  const s = read();
  const rows = s.applications
    .filter((a) => hasPermission(s, "reports.view") && a.isActive)
    .flatMap((a) => {
      const r = currentRound(a);
      if (!r) return [];
      const source = decision(s, r.interviewId);
      const meta = s.roundMeta[r.interviewId] ?? { visible: true, note: "" };
      return [
        {
          applicationId: a.applicationId,
          interviewId: r.interviewId,
          roundNo: r.roundNo,
          interviewVersionNo: r.versionNo,
          candidateName: a.candidateName,
          positionNameVi: a.positionName,
          positionNameEn: null,
          startAt: r.startAt,
          endAt: r.endAt,
          formatNameVi:
            s.catalogs.interview_formats.find(
              (f) => f.id === r.interviewFormatId,
            )?.nameVi ?? null,
          formatNameEn: null,
          roomName:
            s.catalogs.rooms.find((f) => f.id === r.roomId)?.nameVi ?? null,
          reportStatus: r.reportStatus as RawReportStatus,
          hrReportNote: meta.note,
          visibleToInterviewers: meta.visible,
          lastUpdatedAt: r.updatedAt,
          lastUpdatedByName: PEOPLE[s.persona].name,
          drawer: {
            hrOwnerName: a.hrOwnerName,
            participants: participantReports(s, r.interviewId).map(
              ({ p, report }) => ({
                interviewParticipantId: p.interviewParticipantId,
                participantOrder: p.order,
                name: p.name,
                jobTitle: p.jobTitle,
                interviewReportId: report?.reportId ?? null,
                reportVersionNo: report?.version ?? 0,
                report: report?.fields ?? { ...EMPTY_REPORT_FIELDS },
                updatedAt: report?.updatedAt ?? null,
                updatedByName: report?.updatedBy ?? null,
              }),
            ),
            finalDecision: {
              sourceInterviewReportId: source?.report?.reportId ?? null,
              sourceParticipantName: source?.p.name ?? null,
              conclusion: source?.report?.fields.conclusion ?? null,
              expectedSpecificJobAssigned:
                source?.report?.fields.expected_specific_job_assigned ?? null,
              expectedRecruitmentTime:
                source?.report?.fields.expected_recruitment_time ?? null,
              updatedAt: source?.report?.decisionAt ?? null,
              updatedByName: source?.report?.updatedBy ?? null,
            },
          },
        },
      ];
    })
    .filter(
      (r) =>
        (!filters?.status || filters.status === r.reportStatus) &&
        (!filters?.search ||
          r.candidateName
            .toLowerCase()
            .includes(filters.search.toLowerCase())) &&
        (!filters?.visibility ||
          filters.visibility === "ALL" ||
          r.visibleToInterviewers === (filters.visibility === "VISIBLE")),
    );
  return {
    rows,
    page: 1,
    pageSize: 20,
    total: rows.length,
    pageCount: 1,
    permissions: {
      manageStatus: hasPermission(s, "reports.manage_status"),
      visibility: hasPermission(s, "reports.visibility"),
      editInterviewer: hasPermission(s, "reports.edit_interviewer"),
      delete: hasPermission(s, "reports.delete"),
    },
  };
}
export function ownReportData(): InterviewerReportPageData {
  const s = read();
  const user = PEOPLE[s.persona].id;
  return {
    rounds: s.applications
      .filter((a) => a.isActive)
      .flatMap((a) =>
        a.rounds
          .filter(
            (r) => r.isActive && s.roundMeta[r.interviewId]?.visible !== false,
          )
          .flatMap((r) => {
            const p = r.participants.find(
              (p) => p.appUserId === user && p.isCurrent,
            );
            if (!p || !s.users.find((u) => u.appUserId === user && u.isActive))
              return [];
            const report = s.reports.find(
              (v) => v.participantId === p.interviewParticipantId && v.active,
            );
            return [
              {
                applicationId: a.applicationId,
                interviewId: r.interviewId,
                roundNo: r.roundNo,
                isCurrentRound: currentRound(a)?.interviewId === r.interviewId,
                candidateName: a.candidateName,
                positionNameVi: a.positionName,
                positionNameEn: null,
                startAt: r.startAt,
                endAt: r.endAt,
                formatNameVi:
                  s.catalogs.interview_formats.find(
                    (v) => v.id === r.interviewFormatId,
                  )?.nameVi ?? null,
                formatNameEn: null,
                roomName:
                  s.catalogs.rooms.find((v) => v.id === r.roomId)?.nameVi ??
                  null,
                meetingLink: null,
                displayReportStatus: projectInterviewerReportStatus(
                  r.reportStatus as RawReportStatus,
                ),
                canEdit:
                  currentRound(a)?.interviewId === r.interviewId &&
                  !["HIRED", "REJECTED"].includes(r.reportStatus),
                interviewParticipantId: p.interviewParticipantId,
                hasOwnReport: Boolean(report),
                ownVersionNo: report?.version ?? 0,
                ownReport: report?.fields ?? { ...EMPTY_REPORT_FIELDS },
                preview:
                  currentRound(a)?.interviewId === r.interviewId
                    ? {
                        participants: participantReports(s, r.interviewId).map(
                          ({ p, report }) => ({
                            participantOrder: p.order,
                            name: p.name,
                            jobTitle: p.jobTitle,
                            report: report?.fields ?? {
                              ...EMPTY_REPORT_FIELDS,
                            },
                          }),
                        ),
                        finalDecision: {
                          conclusion:
                            decision(s, r.interviewId)?.report?.fields
                              .conclusion ?? null,
                          expectedSpecificJobAssigned:
                            decision(s, r.interviewId)?.report?.fields
                              .expected_specific_job_assigned ?? null,
                          expectedRecruitmentTime:
                            decision(s, r.interviewId)?.report?.fields
                              .expected_recruitment_time ?? null,
                        },
                      }
                    : null,
              },
            ];
          }),
      ),
  };
}
export async function saveReport(
  input: SaveInterviewerReportInput,
  hr = false,
) {
  return mutate("Lưu report cá nhân / Save legacy report", (s) => {
    for (const a of s.applications)
      for (const r of a.rounds) {
        const p = r.participants.find(
          (p) => p.interviewParticipantId === input.interviewParticipantId,
        );
        if (!p) continue;
        if (
          !a.isActive ||
          !r.isActive ||
          !p.isCurrent ||
          (!hr && s.roundMeta[r.interviewId]?.visible === false) ||
          currentRound(a)?.interviewId !== r.interviewId ||
          (!hr && ["HIRED", "REJECTED"].includes(r.reportStatus))
        )
          return fail("INVALID_STATE");
        if (
          hr
            ? !hasPermission(s, "reports.edit_interviewer")
            : p.appUserId !== PEOPLE[s.persona].id
        )
          return fail("FORBIDDEN");
        let report = s.reports.find(
          (v) => v.participantId === p.interviewParticipantId && v.active,
        );
        if ((report?.version ?? 0) !== input.expectedVersionNo)
          return fail("STALE_VERSION");
        const previous = report?.fields ?? { ...EMPTY_REPORT_FIELDS };
        const changed = Object.keys(input.patches).filter(
          (k) =>
            previous[k as keyof ReportFields] !==
            input.patches[k as keyof ReportFields],
        );
        if (!report) {
          report = {
            participantId: p.interviewParticipantId,
            reportId: crypto.randomUUID(),
            version: 0,
            fields: { ...EMPTY_REPORT_FIELDS },
            updatedAt: now(),
            decisionAt: null,
            updatedBy: PEOPLE[s.persona].name,
            active: true,
          };
          s.reports.push(report);
        }
        Object.assign(report.fields, input.patches);
        report.version++;
        report.updatedAt = now();
        report.updatedBy = PEOPLE[s.persona].name;
        if (
          changed.some((k) =>
            [
              "conclusion",
              "expected_specific_job_assigned",
              "expected_recruitment_time",
            ].includes(k),
          )
        )
          report.decisionAt = now();
        p.hasReportHistory = true;
        return ok({
          interviewReportId: report.reportId,
          versionNo: report.version,
        });
      }
    return fail("NOT_FOUND");
  });
}
export async function reportMutation(input: {
  interviewId: string;
  expectedVersionNo: number;
  status?: RawReportStatus;
  note?: string | null;
  visible?: boolean;
}) {
  return mutate("Cập nhật HR report / HR report update", (s) => {
    if (
      !hasPermission(
        s,
        input.visible !== undefined
          ? "reports.visibility"
          : "reports.manage_status",
      )
    )
      return fail("FORBIDDEN");
    const f = findRound(s, input.interviewId);
    if (!f) return fail("NOT_FOUND");
    if (f.round.versionNo !== input.expectedVersionNo)
      return fail("STALE_VERSION");
    if (input.status) f.round.reportStatus = input.status;
    s.roundMeta[input.interviewId] ??= { visible: true, note: "" };
    if (input.note !== undefined)
      s.roundMeta[input.interviewId].note = input.note ?? "";
    if (input.visible !== undefined)
      s.roundMeta[input.interviewId].visible = input.visible;
    f.round.versionNo++;
    return ok({});
  });
}
export async function deleteReport(input: {
  interviewReportId: string;
  expectedVersionNo: number;
}) {
  return mutate("Ngừng report / Inactivate report", (s) => {
    if (!hasPermission(s, "reports.delete")) return fail("FORBIDDEN");
    const r = s.reports.find((v) => v.reportId === input.interviewReportId);
    if (!r) return fail("NOT_FOUND");
    if (r.version !== input.expectedVersionNo) return fail("STALE_VERSION");
    r.active = false;
    return ok({});
  });
}

export async function bulkReportStatus(input: {
  targets: { interviewId: string; expectedVersionNo: number }[];
  status: RawReportStatus;
}) {
  return mutate("Trạng thái nhiều báo cáo / Bulk report status", (s) => {
    if (!hasPermission(s, "reports.manage_status")) return fail("FORBIDDEN");
    for (const target of input.targets) {
      const f = findRound(s, target.interviewId);
      if (
        !f?.app.isActive ||
        currentRound(f.app)?.interviewId !== target.interviewId
      )
        return fail("INVALID_STATE");
      if (f.round.versionNo !== target.expectedVersionNo)
        return fail("STALE_VERSION");
    }
    for (const target of input.targets) {
      const f = findRound(s, target.interviewId);
      if (!f) return fail("NOT_FOUND");
      f.round.reportStatus = input.status;
      f.round.versionNo++;
    }
    return ok({});
  });
}
