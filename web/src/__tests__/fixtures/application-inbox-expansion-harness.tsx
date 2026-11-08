import { useState } from "react";
import { createRoot } from "react-dom/client";
import { ApplicationInboxTableRows } from "@/components/inbox/ApplicationInboxTableRows";
import {
  APPLICATION_INBOX_COLUMNS,
  type ApplicationInboxGroup,
  nextExpandedCandidateId,
} from "@/lib/application-inbox/model";
import "@/app/globals.css";

const GROUPS: ApplicationInboxGroup[] = [
  {
    candidateId: "candidate-1",
    email: "an@example.com",
    isCandidateActive: true,
    candidateVersionNo: 1,
    latestSubmissionId: "submission-2",
    latestSubmissionVersionNo: 1,
    submissions: [
      {
        submissionId: "submission-2",
        candidateId: "candidate-1",
        status: "READ",
        fullName: "Nguyễn Thị An",
        dateOfBirth: "1995-08-15",
        gender: "FEMALE",
        phone: "0901 234 567",
        hrNote: "Đã liên hệ",
        submittedAt: "2026-09-02T09:00:00.000Z",
        hasApplication: false,
        versionNo: 1,
      },
      {
        submissionId: "submission-1",
        candidateId: "candidate-1",
        status: "NEW",
        fullName: "Nguyễn Thị An",
        dateOfBirth: "1995-08-15",
        gender: "FEMALE",
        phone: "0901 234 567",
        hrNote: "Chờ xử lý",
        submittedAt: "2026-08-15T09:00:00.000Z",
        hasApplication: false,
        versionNo: 1,
      },
    ],
  },
  {
    candidateId: "candidate-2",
    email: "binh@example.com",
    isCandidateActive: true,
    candidateVersionNo: 1,
    latestSubmissionId: "submission-4",
    latestSubmissionVersionNo: 1,
    submissions: [
      {
        submissionId: "submission-4",
        candidateId: "candidate-2",
        status: "PROCESSED",
        fullName: "Trần Minh Bình",
        dateOfBirth: "1994-04-01",
        gender: "MALE",
        phone: "0987 654 321",
        hrNote: "Đang phỏng vấn",
        submittedAt: "2026-09-01T09:00:00.000Z",
        hasApplication: true,
        versionNo: 1,
      },
      {
        submissionId: "submission-3",
        candidateId: "candidate-2",
        status: "READ",
        fullName: "Trần Minh Bình",
        dateOfBirth: "1994-04-01",
        gender: "MALE",
        phone: "0987 654 321",
        hrNote: "Lần trước",
        submittedAt: "2026-08-01T09:00:00.000Z",
        hasApplication: false,
        versionNo: 1,
      },
    ],
  },
];

export function ApplicationInboxExpansionHarness() {
  const [expandedCandidateId, setExpandedCandidateId] = useState<string | null>(
    null,
  );
  const [selectedCandidateIds, setSelectedCandidateIds] = useState<Set<string>>(
    new Set(),
  );

  return (
    <table className="application-inbox__table">
      <colgroup>
        {APPLICATION_INBOX_COLUMNS.map((column) => (
          <col
            className={`application-inbox__col--${column.key}`}
            key={column.key}
          />
        ))}
      </colgroup>
      <thead>
        <tr>
          {APPLICATION_INBOX_COLUMNS.map((column) => (
            <th key={column.key} scope="col">
              {column.label}
            </th>
          ))}
        </tr>
      </thead>
      <ApplicationInboxTableRows
        expandedCandidateId={expandedCandidateId}
        groups={GROUPS}
        onToggleCandidate={(candidateId) =>
          setExpandedCandidateId((current) =>
            nextExpandedCandidateId(current, candidateId),
          )
        }
        onToggleSelectedCandidate={(candidateId, selected) =>
          setSelectedCandidateIds((current) => {
            const next = new Set(current);
            if (selected) next.add(candidateId);
            else next.delete(candidateId);
            return next;
          })
        }
        selectedCandidateIds={selectedCandidateIds}
      />
    </table>
  );
}

const root = document.getElementById("root");
if (!root) throw new Error("Missing application inbox test root");
createRoot(root).render(<ApplicationInboxExpansionHarness />);
