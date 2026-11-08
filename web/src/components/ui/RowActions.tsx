"use client";

import { type ReactNode, useEffect, useId, useRef, useState } from "react";
import { createPortal } from "react-dom";

/** Native popover keeps secondary row controls above scrolling table bounds. */
export function RowActions({
  children,
  label = "Thao tác khác",
}: {
  children: ReactNode;
  label?: string;
}) {
  const id = useId();
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  const trigger = useRef<HTMLButtonElement>(null);
  const anchorPosition = useRef({ top: 0, left: 0, width: 0, height: 0 });
  useEffect(() => {
    const dismiss = (event: Event) => {
      const panel = document.getElementById(id);
      const rect = trigger.current?.getBoundingClientRect();
      const moved =
        (event.type === "resize" &&
          (window.innerWidth !== anchorPosition.current.width ||
            window.innerHeight !== anchorPosition.current.height)) ||
        (rect &&
          (rect.top !== anchorPosition.current.top ||
            rect.left !== anchorPosition.current.left));
      if (
        moved &&
        panel?.matches(":popover-open") &&
        !(event.target instanceof Node && panel.contains(event.target))
      )
        panel.hidePopover();
    };
    window.addEventListener("resize", dismiss);
    document.addEventListener("scroll", dismiss, true);
    return () => {
      window.removeEventListener("resize", dismiss);
      document.removeEventListener("scroll", dismiss, true);
    };
  }, [id]);
  return (
    <>
      <button
        ref={trigger}
        type="button"
        className="ui-button ui-button--ghost ui-row-actions-trigger"
        popoverTarget={id}
        aria-label={label}
        onClick={(event) => event.stopPropagation()}
      >
        •••
      </button>
      {mounted &&
        createPortal(
          <fieldset
            id={id}
            popover="auto"
            className="ui-row-actions"
            aria-label={label}
            onBeforeToggle={() => {
              const rect = trigger.current?.getBoundingClientRect();
              if (rect)
                anchorPosition.current = {
                  top: rect.top,
                  left: rect.left,
                  width: window.innerWidth,
                  height: window.innerHeight,
                };
            }}
            onKeyDown={(event) => event.stopPropagation()}
            onToggle={(event) => {
              const panel = event.currentTarget;
              if (!panel.matches(":popover-open") || !trigger.current) return;
              const rect = trigger.current.getBoundingClientRect();
              anchorPosition.current = {
                top: rect.top,
                left: rect.left,
                width: window.innerWidth,
                height: window.innerHeight,
              };
              panel.style.left = `${Math.max(12, Math.min(rect.right - panel.offsetWidth, window.innerWidth - panel.offsetWidth - 12))}px`;
              panel.style.top = `${Math.max(12, Math.min(rect.bottom + 4, window.innerHeight - panel.offsetHeight - 12))}px`;
            }}
            onClick={(event) => {
              event.stopPropagation();
              if (
                (event.target as HTMLElement).closest("button:not(:disabled)")
              )
                event.currentTarget.hidePopover();
            }}
          >
            {children}
          </fieldset>,
          document.body,
        )}
    </>
  );
}
