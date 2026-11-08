import { InterviewPage } from "@/components/interview/InterviewPage";
import {
  InterviewAccessError,
  loadInterviewPage,
} from "@/lib/interview/server";
import "@/styles/interview.css";

export const dynamic = "force-dynamic";

export default async function InterviewsPage({
  searchParams,
}: {
  searchParams: Promise<{
    page?: string | string[];
    activity?: string | string[];
  }>;
}) {
  const params = await searchParams;
  const rawPage = Array.isArray(params.page) ? params.page[0] : params.page;
  const requestedPage = Number(rawPage);
  const page =
    Number.isSafeInteger(requestedPage) && requestedPage > 0
      ? requestedPage
      : 1;
  const rawActivity = Array.isArray(params.activity)
    ? params.activity[0]
    : params.activity;
  const activity =
    rawActivity === "INACTIVE" || rawActivity === "ALL"
      ? rawActivity
      : "ACTIVE";

  try {
    const data = await loadInterviewPage({ filters: { activity }, page });
    return <InterviewPage initialData={data} initialActivity={activity} />;
  } catch (error) {
    const message =
      error instanceof InterviewAccessError
        ? "Bạn không có quyền xem Lịch phỏng vấn."
        : "Không thể tải Lịch phỏng vấn. Vui lòng thử lại.";
    return (
      <section
        className="interview-page"
        aria-labelledby="interview-page-title"
      >
        <h1 id="interview-page-title">Lịch phỏng vấn / Interviews</h1>
        <div className="ui-alert ui-alert--error" role="alert">
          {message}
        </div>
      </section>
    );
  }
}
