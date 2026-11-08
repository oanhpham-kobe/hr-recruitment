import type { ReactNode } from "react";
export function TableScrollContainer({
  children,
  className = "",
}: {
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className={`ui-table-scroll ${className}`.trim()}>{children}</div>
  );
}
