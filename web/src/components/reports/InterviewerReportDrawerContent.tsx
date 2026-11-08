"use client";

import { Button } from "@/components/ui/Button";
import {
  type InterviewerReportRound,
  REPORT_FIELD_KEYS,
  type ReportApplicationGroup,
  type ReportFields,
  safeMeetingHref,
} from "@/lib/reports/model";
import {
  displayReportText,
  formatReportTime,
  REPORT_FIELD_LABELS,
  ReportFieldValues,
  type ReportLocale,
  type ReportMode,
  reportFormatName,
  reportPosition,
} from "./reportUi";

export function InterviewerReportDrawerContent({
  round,
  group,
  locale,
  mode,
  draft,
  pending,
  onDraftChange,
  onSelectRound,
  onLocaleChange,
}: {
  round: InterviewerReportRound;
  group: ReportApplicationGroup | null;
  locale: ReportLocale;
  mode: ReportMode;
  draft: ReportFields;
  pending: boolean;
  onDraftChange: (
    key: (typeof REPORT_FIELD_KEYS)[number],
    value: string,
  ) => void;
  onSelectRound: (round: InterviewerReportRound) => void;
  onLocaleChange: (locale: ReportLocale) => void;
}) {
  const t = (vi: string, en: string) => (locale === "vi" ? vi : en);
  const meetingHref = safeMeetingHref(round.meetingLink);

  return (
    <div className="interviewer-report__drawer">
      <fieldset
        className="language-switcher interviewer-report__drawer-locale"
        disabled={pending}
      >
        <legend className="sr-only">
          {t("Chọn ngôn ngữ", "Choose language")}
        </legend>
        <button
          type="button"
          className={`lang-btn ${locale === "vi" ? "active" : ""}`.trim()}
          aria-pressed={locale === "vi"}
          aria-label={locale === "vi" ? "Tiếng Việt, đang chọn" : "Vietnamese"}
          onClick={() => onLocaleChange("vi")}
        >
          VI
        </button>
        <span className="lang-divider" aria-hidden="true">
          |
        </span>
        <button
          type="button"
          className={`lang-btn ${locale === "en" ? "active" : ""}`.trim()}
          aria-pressed={locale === "en"}
          aria-label={locale === "en" ? "English, selected" : "Tiếng Anh"}
          onClick={() => onLocaleChange("en")}
        >
          EN
        </button>
      </fieldset>

      {mode === "view" && group && group.rounds.length > 1 ? (
        <fieldset className="interviewer-report__round-switcher">
          <legend className="sr-only">
            {t("Chọn vòng phỏng vấn", "Choose interview round")}
          </legend>
          {group.rounds.map((item) => (
            <Button
              key={item.interviewId}
              variant={
                item.interviewId === round.interviewId ? "primary" : "secondary"
              }
              aria-pressed={item.interviewId === round.interviewId}
              onClick={() => onSelectRound(item)}
            >
              {t("Vòng", "Round")} {item.roundNo}
            </Button>
          ))}
        </fieldset>
      ) : null}

      <section
        className="interviewer-report__panel"
        aria-labelledby="report-interview-info"
      >
        <h3 id="report-interview-info">
          {t("Thông tin phỏng vấn", "Interview information")}
        </h3>
        <dl className="interviewer-report__facts">
          <div>
            <dt>{t("Ứng viên", "Candidate")}</dt>
            <dd>{round.candidateName}</dd>
          </div>
          <div>
            <dt>{t("Vị trí", "Position")}</dt>
            <dd>{reportPosition(round, locale)}</dd>
          </div>
          <div>
            <dt>{t("Vòng", "Round")}</dt>
            <dd>
              {round.roundNo}
              {!round.isCurrentRound ? ` · ${t("Lịch sử", "Historical")}` : ""}
            </dd>
          </div>
          <div>
            <dt>{t("Thời gian", "Interview time")}</dt>
            <dd>{formatReportTime(round.startAt, locale)}</dd>
          </div>
          <div>
            <dt>{t("Hình thức", "Format")}</dt>
            <dd>{reportFormatName(round, locale)}</dd>
          </div>
          <div>
            <dt>{t("Địa điểm", "Location")}</dt>
            <dd>{displayReportText(round.roomName)}</dd>
          </div>
        </dl>
        {meetingHref ? (
          <a
            className="interviewer-report__meeting-link"
            href={meetingHref}
            target="_blank"
            rel="noreferrer"
          >
            {t("Mở liên kết phỏng vấn", "Open interview link")}
          </a>
        ) : null}
      </section>

      <section
        className="interviewer-report__panel"
        aria-labelledby="report-own-info"
      >
        <h3 id="report-own-info">{t("Báo cáo của tôi", "My report")}</h3>
        {mode === "edit" && round.canEdit ? (
          <div className="interviewer-report__form">
            {(["evaluation", "decision"] as const).map((section) => (
              <fieldset key={section} disabled={pending}>
                <legend>
                  {section === "evaluation"
                    ? t("Đánh giá và nhận xét", "Evaluation and Comment")
                    : t("Kết luận", "Decision")}
                </legend>
                {REPORT_FIELD_KEYS.filter(
                  (key) => REPORT_FIELD_LABELS[key][2] === section,
                ).map((key) => (
                  <label key={key}>
                    <span>
                      {REPORT_FIELD_LABELS[key][locale === "vi" ? 0 : 1]}
                    </span>
                    <textarea
                      name={key}
                      rows={3}
                      value={draft[key] ?? ""}
                      onChange={(event) =>
                        onDraftChange(key, event.target.value)
                      }
                    />
                  </label>
                ))}
              </fieldset>
            ))}
            <p className="helper-text">
              {t(
                "Tất cả trường đều không bắt buộc. Báo cáo không có chấm điểm hoặc xếp hạng.",
                "All fields are optional. This report has no scoring or rating.",
              )}
            </p>
          </div>
        ) : (
          <ReportFieldValues fields={round.ownReport} locale={locale} />
        )}
      </section>

      {round.isCurrentRound && round.preview ? (
        <section
          className="interviewer-report__panel interviewer-report__preview"
          aria-labelledby="report-shared-preview"
        >
          <h3 id="report-shared-preview">
            {t("Xem trước báo cáo chung", "Shared report preview")}
          </h3>
          <div className="interviewer-report__preview-participants">
            {round.preview.participants.map((participant, index) => (
              <article
                key={`${participant.participantOrder}-${participant.name}`}
              >
                <h4>
                  {index + 1}. {participant.name}
                </h4>
                {participant.jobTitle ? (
                  <p className="meta">{participant.jobTitle}</p>
                ) : null}
                <ReportFieldValues
                  fields={participant.report}
                  locale={locale}
                />
              </article>
            ))}
          </div>
          <div className="interviewer-report__decision">
            <h4>{t("Kết luận chung", "Final decision")}</h4>
            <dl>
              <div>
                <dt>
                  {REPORT_FIELD_LABELS.conclusion[locale === "vi" ? 0 : 1]}
                </dt>
                <dd>
                  {displayReportText(round.preview.finalDecision.conclusion)}
                </dd>
              </div>
              <div>
                <dt>
                  {
                    REPORT_FIELD_LABELS.expected_specific_job_assigned[
                      locale === "vi" ? 0 : 1
                    ]
                  }
                </dt>
                <dd>
                  {displayReportText(
                    round.preview.finalDecision.expectedSpecificJobAssigned,
                  )}
                </dd>
              </div>
              <div>
                <dt>
                  {
                    REPORT_FIELD_LABELS.expected_recruitment_time[
                      locale === "vi" ? 0 : 1
                    ]
                  }
                </dt>
                <dd>
                  {displayReportText(
                    round.preview.finalDecision.expectedRecruitmentTime,
                  )}
                </dd>
              </div>
            </dl>
          </div>
        </section>
      ) : (
        <p className="interviewer-report__historical-note">
          {t(
            "Vòng lịch sử chỉ hiển thị thông tin và báo cáo của bạn; Preview hiện hành chỉ dùng Current Round.",
            "Historical rounds show your own report only; the shared preview uses the Current Round only.",
          )}
        </p>
      )}
    </div>
  );
}
