"use client";

import { useEffect, useMemo, useState } from "react";
import { getInterviewEmailCapabilitiesAction } from "@/app/interviews/actions";
import { Button } from "@/components/ui/Button";
import type { InterviewEmailType } from "@/lib/commands/email-commands";
import {
  formatInterviewTime,
  type InterviewApplicationGroup,
  type InterviewRound,
} from "@/lib/interview/model";
import { EmailPreviewDialog } from "./EmailPreviewDialog";

let capabilitiesPromise: ReturnType<
  typeof getInterviewEmailCapabilitiesAction
> | null = null;

function loadCapabilities() {
  capabilitiesPromise ??= getInterviewEmailCapabilitiesAction().catch(
    (error) => {
      capabilitiesPromise = null;
      throw error;
    },
  );
  return capabilitiesPromise;
}

export function InterviewRowEmailActions({
  application,
  round,
  disabled = false,
}: {
  application: InterviewApplicationGroup;
  round: InterviewRound;
  disabled?: boolean;
}) {
  const [canSend, setCanSend] = useState(false);
  const [resolved, setResolved] = useState(false);
  const [emailType, setEmailType] = useState<InterviewEmailType | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    void loadCapabilities()
      .then((capabilities) => {
        if (!active) return;
        setCanSend(capabilities.canSend);
        setResolved(true);
      })
      .catch(() => {
        if (!active) return;
        setCanSend(false);
        setResolved(true);
      });
    return () => {
      active = false;
    };
  }, []);

  const hasCurrentParticipants = useMemo(
    () => round.participants.some((participant) => participant.isCurrent),
    [round.participants],
  );
  const operational = application.isActive && round.isActive;
  const contextSummary = `Vòng ${round.roundNo} · ${formatInterviewTime(round.startAt, round.endAt)}`;

  if (!resolved || !canSend) return null;

  return (
    <>
      <Button
        variant="ghost"
        disabled={disabled || !operational || !application.candidateEmail}
        aria-label={`Gửi thư ứng viên ${application.candidateName}`}
        onClick={() => {
          setNotice(null);
          setEmailType("INTERVIEW_INVITATION");
        }}
      >
        Gửi UV
      </Button>
      <Button
        variant="ghost"
        disabled={disabled || !operational || !hasCurrentParticipants}
        aria-label={`Gửi thư người tham dự Vòng ${round.roundNo}`}
        onClick={() => {
          setNotice(null);
          setEmailType("INTERVIEW_PARTICIPANT_INVITATION");
        }}
      >
        Gửi NTG
      </Button>
      {notice ? (
        <span className="interview-field-hint" role="status" aria-live="polite">
          {notice}
        </span>
      ) : null}
      {emailType ? (
        <EmailPreviewDialog
          open
          emailType={emailType}
          interviewId={round.interviewId}
          applicationId={application.applicationId}
          submissionId={application.submissionId}
          contextSummary={contextSummary}
          onClose={() => setEmailType(null)}
          onQueued={() => setNotice("Đã đưa vào hàng đợi gửi thư")}
        />
      ) : null}
    </>
  );
}
