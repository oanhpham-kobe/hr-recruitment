import { ApplicationInboxTable } from "@/components/inbox/ApplicationInboxTable";
import {
  ApplicationInboxAccessError,
  loadApplicationInbox,
} from "@/lib/application-inbox/server";

export const dynamic = "force-dynamic";

export default async function Home({
  searchParams,
}: {
  searchParams: Promise<{ page?: string | string[] }>;
}) {
  const params = await searchParams;
  const pageValue = Array.isArray(params.page) ? params.page[0] : params.page;
  const requestedPage = Number(pageValue);
  const page =
    Number.isSafeInteger(requestedPage) && requestedPage > 0
      ? requestedPage
      : 1;

  try {
    const inbox = await loadApplicationInbox({ page });
    return (
      <ApplicationInboxTable
        groups={inbox.groups}
        page={inbox.page}
        pageCount={inbox.pageCount}
      />
    );
  } catch (error) {
    const message =
      error instanceof ApplicationInboxAccessError
        ? "Bạn không có quyền xem Phiếu Ứng tuyển."
        : "Không thể tải Phiếu Ứng tuyển. Vui lòng thử lại.";

    return <ApplicationInboxTable groups={[]} errorMessage={message} />;
  }
}
