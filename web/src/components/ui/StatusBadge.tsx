import type { ButtonHTMLAttributes, ReactNode } from "react";

type Tone = "success" | "warning" | "danger" | "info" | "neutral" | "followup";
interface Common {
  children: ReactNode;
  tone?: Tone;
  operationalInterview?: boolean;
  className?: string;
}
type Props = Common &
  (
    | ({
        interactive: true;
        "aria-label": string;
      } & ButtonHTMLAttributes<HTMLButtonElement>)
    | { interactive?: false }
  );
export function StatusBadge(props: Props) {
  const tone = props.tone ?? "neutral";
  const cls =
    `ui-status-badge ui-status-badge--${tone} ${props.operationalInterview ? "ui-status-badge--interview" : ""} ${props.className ?? ""}`.trim();
  if (props.interactive) {
    const {
      children,
      interactive: _interactive,
      tone: _tone,
      operationalInterview: _op,
      className: _className,
      ...buttonProps
    } = props;
    return (
      <button type="button" {...buttonProps} className={cls}>
        {children}
      </button>
    );
  }
  return <span className={cls}>{props.children}</span>;
}
