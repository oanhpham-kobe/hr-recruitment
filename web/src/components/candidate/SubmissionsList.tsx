"use client";

export type CandidateSubmissionSummary = {
  submissionId: string;
  submittedAt: string;
  statusCode: "NEW" | "READ" | "PROCESSED" | "DONE" | "CLOSED" | string;
  versionNo: number;
};

interface SubmissionsListProps {
  submissions: CandidateSubmissionSummary[];
  onEditSubmission?: (submissionId: string) => void;
  onViewSubmission?: (submissionId: string) => void;
  onNewApplication?: () => void;
}

export function SubmissionsList({
  submissions,
  onEditSubmission,
  onViewSubmission,
  onNewApplication,
}: SubmissionsListProps) {
  const mapStatusToDisplay = (status: string) => {
    switch (status) {
      case "NEW":
        return {
          label: "Mới / New",
          badgeClass: "badge-new",
          canEdit: true,
        };
      case "READ":
      case "PROCESSED":
        return {
          label: "Đang xử lý / Processing",
          badgeClass: "badge-processing",
          canEdit: false,
        };
      case "DONE":
      case "CLOSED":
        return {
          label: "Hoàn thành / Completed",
          badgeClass: "badge-completed",
          canEdit: false,
        };
      default:
        return {
          label: status,
          badgeClass: "badge-new",
          canEdit: false,
        };
    }
  };

  const formatDate = (isoString: string): string => {
    try {
      const d = new Date(isoString);
      return d.toLocaleDateString("vi-VN", {
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
      });
    } catch {
      return isoString;
    }
  };

  return (
    <div className="portal-submissions-view">
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          marginBottom: "20px",
          flexWrap: "wrap",
          gap: "12px",
        }}
      >
        <h2 style={{ fontSize: "20px", fontWeight: 700, margin: 0 }}>
          Hồ sơ đã nộp / My Submissions
        </h2>
        {onNewApplication && (
          <button
            type="button"
            className="btn btn-primary"
            onClick={onNewApplication}
          >
            + Đăng ký mới / New Application
          </button>
        )}
      </div>

      {submissions.length === 0 ? (
        <div
          style={{
            padding: "32px",
            textAlign: "center",
            backgroundColor: "var(--canvas)",
            borderRadius: "8px",
          }}
        >
          <p style={{ fontSize: "16px", color: "var(--ink-600)" }}>
            Bạn chưa có hồ sơ nào được ghi nhận trong hệ thống.
          </p>
          {onNewApplication && (
            <button
              type="button"
              className="btn btn-primary"
              onClick={onNewApplication}
              style={{ marginTop: "12px" }}
            >
              Nộp hồ sơ ngay / Apply Now
            </button>
          )}
        </div>
      ) : (
        <div className="table-responsive">
          <table
            className="submissions-table"
            aria-label="Danh sách hồ sơ của tôi"
          >
            <thead>
              <tr>
                <th scope="col" style={{ width: "60px" }}>
                  STT
                </th>
                <th scope="col">Ngày ứng tuyển / Submitted At</th>
                <th scope="col" style={{ width: "160px" }}>
                  Trạng thái / Status
                </th>
                <th scope="col" style={{ width: "140px" }}>
                  Thao tác / Actions
                </th>
              </tr>
            </thead>
            <tbody>
              {submissions.map((sub, index) => {
                const { label, badgeClass, canEdit } = mapStatusToDisplay(
                  sub.statusCode,
                );
                return (
                  <tr key={sub.submissionId}>
                    <td data-label="STT">{index + 1}</td>
                    <td data-label="Ngày ứng tuyển / Submitted">
                      {formatDate(sub.submittedAt)} (v{sub.versionNo})
                    </td>
                    <td data-label="Trạng thái / Status">
                      <span className={`status-badge ${badgeClass}`}>
                        {label}
                      </span>
                    </td>
                    <td data-label="Thao tác / Actions">
                      {canEdit && onEditSubmission ? (
                        <button
                          type="button"
                          className="btn btn-secondary workflow-edit-action"
                          style={{
                            minHeight: "44px",
                            padding: "8px 12px",
                            fontSize: "16px",
                          }}
                          onClick={() => onEditSubmission(sub.submissionId)}
                          aria-label={`Chỉnh sửa hồ sơ nộp ngày ${formatDate(sub.submittedAt)}`}
                        >
                          Chỉnh sửa
                        </button>
                      ) : onViewSubmission ? (
                        <button
                          type="button"
                          className="btn btn-secondary"
                          style={{
                            minHeight: "44px",
                            padding: "8px 12px",
                            fontSize: "16px",
                          }}
                          onClick={() => onViewSubmission(sub.submissionId)}
                          aria-label={`Xem hồ sơ nộp ngày ${formatDate(sub.submittedAt)}`}
                        >
                          Chi tiết
                        </button>
                      ) : (
                        <span
                          style={{
                            fontSize: "16px",
                            color: "var(--ink-600)",
                          }}
                        >
                          Đã ghi nhận
                        </span>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
