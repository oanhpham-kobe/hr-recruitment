"use client";

import { type ReactNode, useEffect, useId, useRef } from "react";

/** Native disclosure preserves full context without another permanent text row. */
export function PageContext({ children }: { children: ReactNode }) {
  const id = useId();
  const trigger = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const dismiss = (event: Event) => {
      if (event.target instanceof Node && panel.current?.contains(event.target))
        return;
      if (panel.current?.matches(":popover-open")) panel.current.hidePopover();
    };
    window.addEventListener("resize", dismiss);
    window.addEventListener("scroll", dismiss, true);
    return () => {
      window.removeEventListener("resize", dismiss);
      window.removeEventListener("scroll", dismiss, true);
    };
  }, []);
  return (
    <div className="workflow-page-context">
      <button
        ref={trigger}
        type="button"
        popoverTarget={id}
        aria-label="Thông tin về trang / About this page"
      >
        <svg
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.7"
          aria-hidden="true"
        >
          <circle cx="12" cy="12" r="9" />
          <path d="M12 11v6 M12 7v1" />
        </svg>
      </button>
      <div
        ref={panel}
        id={id}
        popover="auto"
        className="workflow-page-context__panel"
        onBeforeToggle={(event) => {
          event.currentTarget.style.visibility = "hidden";
        }}
        onToggle={(event) => {
          const element = event.currentTarget;
          if (!element.matches(":popover-open") || !trigger.current) return;
          const bounds = trigger.current.getBoundingClientRect();
          element.style.left = `${Math.max(12, Math.min(bounds.right - element.offsetWidth, window.innerWidth - element.offsetWidth - 12))}px`;
          element.style.top = `${Math.max(12, Math.min(bounds.bottom + 8, window.innerHeight - element.offsetHeight - 12))}px`;
          element.style.visibility = "visible";
        }}
      >
        {children}
      </div>
    </div>
  );
}
