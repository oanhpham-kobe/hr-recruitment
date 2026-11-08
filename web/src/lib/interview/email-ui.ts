import type {
  EmailHistoryEntry,
  EmailHistoryStatus,
} from "@/lib/commands/email-commands";

export type EmailHistoryTone =
  | "success"
  | "warning"
  | "danger"
  | "info"
  | "neutral";

export type EmailHistoryDeleteClassification = "TEST_RECORD" | "WRONG_RECORD";

export function emailHistoryStatusTone(
  status: EmailHistoryStatus,
): EmailHistoryTone {
  if (status === "SENT") return "success";
  if (status === "FAILED") return "danger";
  if (status === "CANCELLED") return "warning";
  return "neutral";
}

export function formatEmailHistoryRecipients(
  recipients: EmailHistoryEntry["recipients"],
): string {
  if (Array.isArray(recipients)) return recipients.join(", ");
  const values = [...(recipients.to ?? []), ...(recipients.cc ?? [])];
  return values.join(", ");
}

export function emailHistoryTimestamp(entry: EmailHistoryEntry): string {
  return entry.sent_at ?? entry.created_at;
}

export function validateEmailHistoryDeletion(
  classification: EmailHistoryDeleteClassification,
  reason: string,
  testRecordAllowed: boolean,
): string | null {
  const normalized = reason.trim();
  if (classification === "TEST_RECORD" && !testRecordAllowed)
    return "TEST_RECORD chỉ áp dụng cho bản ghi môi trường TEST.";
  if (classification === "WRONG_RECORD" && !normalized)
    return "WRONG_RECORD yêu cầu lý do xóa.";
  if (normalized.length > 1000) return "Lý do xóa tối đa 1000 ký tự.";
  return null;
}
