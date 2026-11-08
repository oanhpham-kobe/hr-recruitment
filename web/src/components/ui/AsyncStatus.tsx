import type { ReactNode } from "react";
export function AsyncStatus({
  children,
  kind = "info",
}: {
  children: ReactNode;
  kind?: "info" | "success" | "error" | "warning";
}) {
  return (
    <div
      className={`ui-async-status ui-async-status--${kind}`}
      role={kind === "error" ? "alert" : "status"}
      aria-live={kind === "error" ? "assertive" : "polite"}
    >
      {children}
    </div>
  );
}
