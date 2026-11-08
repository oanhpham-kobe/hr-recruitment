"use client";
import type { RefObject } from "react";
import { useEffect, useRef } from "react";

const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

let activeOverlayLocks = 0;
let originalBodyOverflow: string | null = null;
const overlayStack: symbol[] = [];

function acquireBackgroundLock() {
  if (activeOverlayLocks === 0) {
    const appRoot = document.getElementById("app-root");
    originalBodyOverflow = document.body.style.overflow;
    appRoot?.setAttribute("inert", "");
    appRoot?.setAttribute("aria-hidden", "true");
    document.body.style.overflow = "hidden";
  }
  activeOverlayLocks += 1;
}

function releaseBackgroundLock() {
  activeOverlayLocks = Math.max(0, activeOverlayLocks - 1);
  if (activeOverlayLocks !== 0) return;

  const appRoot = document.getElementById("app-root");
  appRoot?.removeAttribute("inert");
  appRoot?.removeAttribute("aria-hidden");
  document.body.style.overflow = originalBodyOverflow ?? "";
  originalBodyOverflow = null;
}

function pushOverlay(token: symbol) {
  overlayStack.push(token);
  acquireBackgroundLock();
}

function popOverlay(token: symbol) {
  const index = overlayStack.lastIndexOf(token);
  if (index >= 0) overlayStack.splice(index, 1);
  releaseBackgroundLock();
}

export function useOverlayFocus(
  open: boolean,
  containerRef: RefObject<HTMLElement | null>,
  onClose: () => void,
) {
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  useEffect(() => {
    if (!open) return;
    const token = Symbol("overlay");
    const previous =
      document.activeElement instanceof HTMLElement
        ? document.activeElement
        : null;

    pushOverlay(token);

    const focusable = () =>
      Array.from(
        containerRef.current?.querySelectorAll<HTMLElement>(FOCUSABLE) ?? [],
      );
    requestAnimationFrame(() => focusable()[0]?.focus());

    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        if (overlayStack[overlayStack.length - 1] !== token) return;
        event.preventDefault();
        onCloseRef.current();
        return;
      }
      if (event.key !== "Tab") return;
      if (overlayStack[overlayStack.length - 1] !== token) return;
      const items = focusable();
      if (!items.length) return;
      const first = items[0];
      const last = items[items.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };

    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("keydown", onKey);
      popOverlay(token);
      previous?.focus();
    };
  }, [open, containerRef]);
}
