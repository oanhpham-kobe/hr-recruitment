"use client";

import { useAppLocale } from "@/components/shell/LocaleProvider";
import { AsyncStatus } from "@/components/ui/AsyncStatus";

export function InterviewerReportErrorState({
  kind,
}: {
  kind: "access" | "load";
}) {
  const { locale } = useAppLocale();
  const vi = locale === "vi";

  return (
    <section
      className="interviewer-report"
      aria-labelledby="interviewer-report-title"
    >
      <h1 id="interviewer-report-title">
        {vi ? "Báo cáo phỏng vấn" : "Interview Reports"}
      </h1>
      <AsyncStatus kind="error">
        {kind === "access"
          ? vi
            ? "Bạn không có quyền xem Báo cáo phỏng vấn."
            : "You do not have access to Interview Reports."
          : vi
            ? "Không thể tải Báo cáo phỏng vấn. Vui lòng thử lại."
            : "Interview Reports could not be loaded. Please try again."}
      </AsyncStatus>
    </section>
  );
}
