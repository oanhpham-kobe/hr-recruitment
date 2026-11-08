import {
  type ApplicationInboxGroup,
  latestSubmission,
  type SubmissionStatus,
} from "@/lib/application-inbox/model";

export const SUBMISSION_STATUS_LABEL: Record<SubmissionStatus, string> = {
  NEW: "Mới",
  READ: "Đã đọc",
  PROCESSED: "Đang xử lý",
  DONE: "Hoàn tất",
  CLOSED: "Đã đóng",
};

const STATUS_CLASS: Record<SubmissionStatus, string> = {
  NEW: "status-badge--warning",
  READ: "status-badge--info",
  PROCESSED: "status-badge--followup",
  DONE: "status-badge--success",
  CLOSED: "status-badge--neutral",
};

const DATE_TIME_FORMATTER = new Intl.DateTimeFormat("vi-VN", {
  dateStyle: "short",
  timeStyle: "short",
  timeZone: "Asia/Ho_Chi_Minh",
});

function formatDateOfBirth(value: string | null): string {
  if (!value) return "—";
  const [year, month, day] = value.split("-");
  return year && month && day ? `${day}/${month}/${year}` : value;
}

function formatSubmittedAt(value: string): string {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "—" : DATE_TIME_FORMATTER.format(date);
}

function formatGender(value: "MALE" | "FEMALE" | null): string {
  if (value === "MALE") return "Nam";
  if (value === "FEMALE") return "Nữ";
  return "—";
}

interface ApplicationInboxTableRowsProps {
  expandedCandidateId: string | null;
  groups: ApplicationInboxGroup[];
  onToggleCandidate: (candidateId: string) => void;
  onToggleSelectedCandidate: (candidateId: string, selected: boolean) => void;
  onOpenSubmission?: (submissionId: string) => void;
  selectedCandidateIds: ReadonlySet<string>;
}
export function ApplicationInboxTableRows({
  expandedCandidateId,
  groups,
  onOpenSubmission,
  onToggleCandidate,
  onToggleSelectedCandidate,
  selectedCandidateIds,
}: ApplicationInboxTableRowsProps) {
  return groups.map((group) => {
    const latest = latestSubmission(group);
    const expandable = group.submissions.length > 1;
    const expanded = expandedCandidateId === group.candidateId;
    const groupId = `candidate-group-${group.candidateId}`;

    return (
      <tbody id={groupId} key={group.candidateId}>
        <tr
          className={`application-inbox__parent-row${expandable ? " application-inbox__parent-row--expandable" : ""}`}
          onClick={
            expandable
              ? (event) => {
                  if (
                    event.target instanceof Element &&
                    event.target.closest(
                      ".application-inbox__selection-control",
                    )
                  ) {
                    return;
                  }
                  onToggleCandidate(group.candidateId);
                }
              : undefined
          }
        >
          <td className="application-inbox__select-cell" data-label="Chọn">
            <label className="application-inbox__selection-control">
              <input
                type="checkbox"
                checked={selectedCandidateIds.has(group.candidateId)}
                aria-label={`Chọn Candidate ${latest.fullName}`}
                onClick={(event) => event.stopPropagation()}
                onChange={(event) => {
                  event.stopPropagation();
                  onToggleSelectedCandidate(
                    group.candidateId,
                    event.target.checked,
                  );
                }}
              />
            </label>
          </td>
          <td data-label="Candidate">
            {expandable ? (
              <button
                type="button"
                className="application-inbox__expand-button"
                aria-expanded={expanded}
                aria-controls={groupId}
                aria-label={`${expanded ? "Thu gọn" : "Mở"} lịch sử phiếu của Candidate ${latest.fullName}`}
                onClick={(event) => {
                  event.stopPropagation();
                  onToggleCandidate(group.candidateId);
                }}
              >
                <span aria-hidden="true">{expanded ? "▾" : "▸"}</span>
                <span>
                  <strong>{latest.fullName}</strong>
                  <small>{group.submissions.length} phiếu</small>
                </span>
              </button>
            ) : (
              <strong className="application-inbox__plain-name">
                {latest.fullName}
              </strong>
            )}
          </td>
          <td className="wrap-anywhere" data-label="Email">
            {group.email}
          </td>
          <td data-label="Ngày sinh">
            {formatDateOfBirth(latest.dateOfBirth)}
          </td>
          <td data-label="Giới tính">{formatGender(latest.gender)}</td>
          <td data-label="SĐT">{latest.phone ?? "—"}</td>
          <td data-label="Trạng thái">
            <span className={`status-badge ${STATUS_CLASS[latest.status]}`}>
              {SUBMISSION_STATUS_LABEL[latest.status]}
            </span>
            {!group.isCandidateActive && (
              <span className="candidate-status-badge">Candidate inactive</span>
            )}
          </td>
          <td data-label="HR Note">
            <span className="workflow-note-excerpt">
              {latest.hrNote ?? "—"}
            </span>
          </td>
          <td data-label="Thao tác">
            <button
              type="button"
              className="btn-secondary application-inbox__action-btn"
              aria-label={`Xem chi tiết phiếu của Candidate ${latest.fullName}`}
              onClick={(event) => {
                event.stopPropagation();
                onOpenSubmission?.(latest.submissionId);
              }}
            >
              Chi tiết
            </button>
          </td>
        </tr>
        {expanded &&
          group.submissions.slice(1).map((submission) => (
            <tr
              key={submission.submissionId}
              className="application-inbox__child-row"
            >
              <td aria-hidden="true" data-mobile-hidden="true" />
              <td data-label="Loại">
                <span className="application-inbox__child-label">
                  Ngày ứng tuyển
                </span>
              </td>
              <td aria-hidden="true" data-mobile-hidden="true" />
              <td data-label="Ngày ứng tuyển">
                {formatSubmittedAt(submission.submittedAt)}
              </td>
              <td aria-hidden="true" data-mobile-hidden="true" />
              <td aria-hidden="true" data-mobile-hidden="true" />
              <td data-label="Trạng thái">
                <span
                  className={`status-badge ${STATUS_CLASS[submission.status]}`}
                >
                  {SUBMISSION_STATUS_LABEL[submission.status]}
                </span>
              </td>
              <td data-label="HR Note">
                <span className="workflow-note-excerpt">
                  {submission.hrNote ?? "—"}
                </span>
              </td>
              <td data-label="Thao tác">
                <button
                  type="button"
                  className="btn-secondary application-inbox__action-btn"
                  aria-label={`Xem chi tiết phiếu ngày ${formatSubmittedAt(submission.submittedAt)} của Candidate ${latest.fullName}`}
                  onClick={(event) => {
                    event.stopPropagation();
                    onOpenSubmission?.(submission.submissionId);
                  }}
                >
                  Chi tiết
                </button>
              </td>
            </tr>
          ))}
      </tbody>
    );
  });
}
