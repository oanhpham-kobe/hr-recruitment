"use client";

import { useMemo, useState } from "react";
import { useAppLocale } from "@/components/shell/LocaleProvider";
import { AsyncStatus } from "@/components/ui/AsyncStatus";
import { Button } from "@/components/ui/Button";
import { Drawer } from "@/components/ui/Drawer";
import { PageContext } from "@/components/ui/PageContext";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { TableScrollContainer } from "@/components/ui/TableScrollContainer";
import {
  changedReportFields,
  EMPTY_REPORT_FIELDS,
  groupInterviewerReportRounds,
  type InterviewerReportPageData,
  type InterviewerReportRound,
  REPORT_STATUS_LABELS,
  type ReportFieldKey,
  type ReportFields,
} from "@/lib/reports/model";
import type {
  SaveInterviewerReportInput,
  SaveInterviewerReportResult,
} from "@/lib/reports/server";
import { InterviewerReportDrawerContent } from "./InterviewerReportDrawerContent";
import {
  cloneReportFields,
  formatReportTime,
  type ReportFeedback,
  type ReportMode,
  reportFeedbackMessage,
  reportPosition,
  reportStatusTone,
} from "./reportUi";

export function InterviewerReportView({
  initialData,
  onSave,
  onRefresh,
}: {
  initialData: InterviewerReportPageData;
  onSave: (
    input: SaveInterviewerReportInput,
  ) => Promise<SaveInterviewerReportResult>;
  onRefresh: () => Promise<InterviewerReportPageData>;
}) {
  const { locale, setLocale } = useAppLocale();
  const t = (vi: string, en: string) => (locale === "vi" ? vi : en);
  const [data, setData] = useState(initialData);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [mode, setMode] = useState<ReportMode>("view");
  const [draft, setDraft] = useState<ReportFields>({ ...EMPTY_REPORT_FIELDS });
  const [base, setBase] = useState<ReportFields>({ ...EMPTY_REPORT_FIELDS });
  const [pending, setPending] = useState(false);
  const [feedback, setFeedback] = useState<ReportFeedback>(null);
  const groups = useMemo(
    () => groupInterviewerReportRounds(data.rounds),
    [data.rounds],
  );
  const round = selectedId
    ? (data.rounds.find((item) => item.interviewId === selectedId) ?? null)
    : null;
  const group = round
    ? (groups.find((item) => item.applicationId === round.applicationId) ??
      null)
    : null;

  function selectRound(
    nextRound: InterviewerReportRound,
    nextMode: ReportMode,
  ) {
    if (pending) return;
    setSelectedId(nextRound.interviewId);
    setMode(nextMode);
    setBase(cloneReportFields(nextRound.ownReport));
    setDraft(cloneReportFields(nextRound.ownReport));
    setFeedback(null);
  }

  function closeDrawer() {
    if (pending) return;
    setSelectedId(null);
    setMode("view");
    setFeedback(null);
  }

  async function refreshSelected(interviewId: string) {
    const next = await onRefresh();
    setData(next);
    const fresh = next.rounds.find((item) => item.interviewId === interviewId);
    if (fresh) {
      setSelectedId(fresh.interviewId);
      setBase(cloneReportFields(fresh.ownReport));
      setDraft(cloneReportFields(fresh.ownReport));
    }
    return fresh;
  }

  async function saveReport() {
    if (!round?.canEdit || pending) return;

    const changed = changedReportFields(base, draft);
    if (Object.keys(changed.patches).length === 0) {
      if (round.hasOwnReport) {
        setFeedback({ kind: "warning", code: "NO_CHANGES" });
        return;
      }
      changed.patches.professional_knowledge = "";
      changed.baseValues.professional_knowledge = null;
    }

    setPending(true);
    setFeedback(null);
    try {
      const result = await onSave({
        interviewParticipantId: round.interviewParticipantId,
        expectedVersionNo: round.ownVersionNo,
        patches: changed.patches,
        baseValues: changed.baseValues,
      });
      if (!result.success) {
        const stale = result.error.code === "STALE_VERSION";
        setFeedback({
          kind: stale ? "warning" : "error",
          code: stale ? "STALE_RELOADED" : "SAVE_FAILED",
        });
        if (stale) {
          await refreshSelected(round.interviewId);
          setMode("view");
        }
        return;
      }

      await refreshSelected(round.interviewId);
      setMode("view");
      setFeedback({ kind: "success", code: "SAVE_SUCCEEDED" });
    } catch {
      setFeedback({ kind: "error", code: "ACTION_FAILED" });
    } finally {
      setPending(false);
    }
  }

  const drawerFooter = round ? (
    mode === "edit" ? (
      <div className="interviewer-report__drawer-actions">
        <Button disabled={pending} onClick={() => setMode("view")}>
          {t("Hủy", "Cancel")}
        </Button>
        <Button variant="primary" pending={pending} onClick={saveReport}>
          {t("Lưu báo cáo", "Save report")}
        </Button>
      </div>
    ) : round.canEdit ? (
      <Button
        variant="primary"
        className={round.hasOwnReport ? "workflow-edit-action" : undefined}
        onClick={() => selectRound(round, "edit")}
      >
        {round.hasOwnReport ? t("Sửa", "Edit") : t("Báo cáo PV", "Report")}
      </Button>
    ) : undefined
  ) : undefined;

  return (
    <section
      className="interviewer-report workflow-list-page"
      aria-labelledby="interviewer-report-title"
      aria-busy={pending || undefined}
    >
      <div className="interviewer-report__heading">
        <div className="workflow-page-heading">
          <h1 id="interviewer-report-title">
            {t("Báo cáo phỏng vấn", "Interview Reports")}
          </h1>
          <PageContext>
            {t(
              "Chỉ hiển thị các vòng phỏng vấn bạn được phân công và còn quyền truy cập.",
              "Only interview rounds you participated in and still have access to are available.",
            )}
          </PageContext>
        </div>
      </div>

      {!round && feedback ? (
        <AsyncStatus kind={feedback.kind}>
          {reportFeedbackMessage(feedback, locale)}
        </AsyncStatus>
      ) : null}

      {groups.length === 0 ? (
        <div className="interviewer-report__empty" role="status">
          <strong>
            {t("Chưa có báo cáo khả dụng.", "No reports available.")}
          </strong>
        </div>
      ) : (
        <TableScrollContainer className="interviewer-report__table-scroll">
          <table className="interviewer-report__table">
            <thead>
              <tr>
                {[
                  t("Ứng viên", "Candidate"),
                  t("Vị trí", "Position"),
                  t("Vòng", "Round"),
                  t("Thời gian", "Interview time"),
                  t("Trạng thái", "Status"),
                  t("Thao tác", "Actions"),
                ].map((heading) => (
                  <th scope="col" key={heading}>
                    {heading}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {groups.map((item) => {
                const primary = item.primaryRound;
                return (
                  <tr key={item.applicationId}>
                    <td data-label={t("Ứng viên", "Candidate")}>
                      <strong>{item.candidateName}</strong>
                    </td>
                    <td data-label={t("Vị trí", "Position")}>
                      {reportPosition(primary, locale)}
                    </td>
                    <td data-label={t("Vòng", "Round")}>
                      {t("Vòng", "Round")} {primary.roundNo}
                      {!primary.isCurrentRound ? (
                        <span className="interviewer-report__historical">
                          {t("Lịch sử", "Historical")}
                        </span>
                      ) : null}
                    </td>
                    <td data-label={t("Thời gian", "Interview time")}>
                      {formatReportTime(primary.startAt, locale)}
                    </td>
                    <td data-label={t("Trạng thái", "Status")}>
                      <StatusBadge
                        tone={reportStatusTone(primary.displayReportStatus)}
                        className="interviewer-report__status-badge"
                      >
                        {
                          REPORT_STATUS_LABELS[primary.displayReportStatus][
                            locale
                          ]
                        }
                      </StatusBadge>
                    </td>
                    <td data-label={t("Thao tác", "Actions")}>
                      <div className="interviewer-report__actions">
                        {primary.canEdit ? (
                          <Button
                            variant="primary"
                            className={
                              primary.hasOwnReport
                                ? "workflow-edit-action"
                                : undefined
                            }
                            onClick={() => selectRound(primary, "edit")}
                          >
                            {primary.hasOwnReport
                              ? t("Sửa", "Edit")
                              : t("Báo cáo PV", "Report")}
                          </Button>
                        ) : null}
                        <Button onClick={() => selectRound(primary, "view")}>
                          {t("Xem", "View")}
                        </Button>
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </TableScrollContainer>
      )}

      <Drawer
        open={Boolean(round)}
        title={t("Báo cáo phỏng vấn", "Interview Report")}
        onClose={closeDrawer}
        footer={drawerFooter}
      >
        {round ? (
          <>
            {feedback ? (
              <AsyncStatus kind={feedback.kind}>
                {reportFeedbackMessage(feedback, locale)}
              </AsyncStatus>
            ) : null}
            <InterviewerReportDrawerContent
              round={round}
              group={group}
              locale={locale}
              mode={mode}
              draft={draft}
              pending={pending}
              onDraftChange={(key: ReportFieldKey, value: string) => {
                if (pending) return;
                setDraft((current) => ({ ...current, [key]: value }));
              }}
              onSelectRound={(item) => selectRound(item, "view")}
              onLocaleChange={setLocale}
            />
          </>
        ) : null}
      </Drawer>
    </section>
  );
}
