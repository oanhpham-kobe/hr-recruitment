"use client";
import type { ReactNode } from "react";
import { useRef } from "react";
import { createPortal } from "react-dom";
import { useOverlayFocus } from "./overlay";
export function Dialog({
  open,
  title,
  children,
  onClose,
  footer,
}: {
  open: boolean;
  title: string;
  children: ReactNode;
  onClose: () => void;
  footer?: ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  useOverlayFocus(open, ref, onClose);
  if (!open || typeof document === "undefined") return null;
  return createPortal(
    <div className="ui-overlay">
      <button
        type="button"
        className="ui-overlay__backdrop"
        aria-label="Đóng / Close"
        onClick={onClose}
      />
      <div
        ref={ref}
        className="ui-dialog"
        role="dialog"
        aria-modal="true"
        aria-label={title}
      >
        <header>
          <h2>{title}</h2>
          <button
            type="button"
            className="ui-icon-button"
            onClick={onClose}
            aria-label="Đóng / Close"
          >
            ×
          </button>
        </header>
        <div className="ui-dialog__body">{children}</div>
        {footer ? <footer>{footer}</footer> : null}
      </div>
    </div>,
    document.body,
  );
}
