"use client";

import type { ReactNode } from "react";
import { useRef } from "react";
import { createPortal } from "react-dom";
import { useOverlayFocus } from "./overlay";

export function Drawer({
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
  const ref = useRef<HTMLElement>(null);
  useOverlayFocus(open, ref, onClose);

  if (!open || typeof document === "undefined") return null;

  return createPortal(
    <div className="ui-overlay ui-overlay--drawer">
      <button
        type="button"
        className="ui-overlay__backdrop"
        aria-label="Đóng / Close"
        onClick={onClose}
      />
      <aside
        ref={ref}
        className="ui-drawer"
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
        <div className="ui-drawer__body">{children}</div>
        {footer ? <footer>{footer}</footer> : null}
      </aside>
    </div>,
    document.body,
  );
}
