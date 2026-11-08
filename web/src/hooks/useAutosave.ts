"use client";

import { useEffect, useRef, useState } from "react";

export type AutosaveStatus = "IDLE" | "SAVING" | "SAVED" | "RESTORED";

export type DraftEnvelope<T> = {
  sessionId: string;
  expiresAt: string;
  data: T;
};

interface UseAutosaveOptions<T> {
  sessionId: string;
  expiresAt: string;
  data: T;
  debounceMs?: number;
  onRestore?: (restoredData: T) => void;
}

export function useAutosave<T>({
  sessionId,
  expiresAt,
  data,
  debounceMs = 800,
  onRestore,
}: UseAutosaveOptions<T>) {
  const [status, setStatus] = useState<AutosaveStatus>("IDLE");
  const [lastSavedAt, setLastSavedAt] = useState<Date | null>(null);
  const storageKey = `eiu_candidate_form_draft_${sessionId}`;
  const isInitialMount = useRef(true);
  const onRestoreRef = useRef(onRestore);
  onRestoreRef.current = onRestore;

  // Restore draft on mount from sessionStorage
  useEffect(() => {
    if (typeof window === "undefined" || !sessionId) {
      return;
    }
    try {
      const saved = sessionStorage.getItem(storageKey);
      if (saved) {
        const parsed = JSON.parse(saved) as DraftEnvelope<T>;
        const expiryTime = parsed.expiresAt
          ? new Date(parsed.expiresAt).getTime()
          : Infinity;
        const isFuture = expiryTime > Date.now();

        if (parsed.sessionId === sessionId && isFuture && parsed.data) {
          onRestoreRef.current?.(parsed.data);
          setStatus("RESTORED");
        } else {
          sessionStorage.removeItem(storageKey);
        }
      }
    } catch {
      // Ignore sessionStorage parse errors
    }
  }, [sessionId, storageKey]);

  // Debounced save to sessionStorage on data change
  useEffect(() => {
    if (isInitialMount.current) {
      isInitialMount.current = false;
      return;
    }

    if (!sessionId || typeof window === "undefined") {
      return;
    }

    setStatus("SAVING");
    const timer = setTimeout(() => {
      try {
        const envelope: DraftEnvelope<T> = {
          sessionId,
          expiresAt,
          data,
        };
        sessionStorage.setItem(storageKey, JSON.stringify(envelope));
        setStatus("SAVED");
        setLastSavedAt(new Date());
      } catch {
        setStatus("IDLE");
      }
    }, debounceMs);

    return () => clearTimeout(timer);
  }, [data, sessionId, expiresAt, debounceMs, storageKey]);

  const clearDraft = () => {
    if (typeof window !== "undefined") {
      try {
        sessionStorage.removeItem(storageKey);
        setStatus("IDLE");
        setLastSavedAt(null);
      } catch {
        // Ignore removal errors
      }
    }
  };

  const getStatusMessage = (): string => {
    switch (status) {
      case "SAVING":
        return "Đang lưu bản nháp... / Saving draft...";
      case "SAVED":
        return "Đã lưu bản nháp tự động / Draft autosaved";
      case "RESTORED":
        return "Đã khôi phục bản nháp đã lưu / Restored saved draft";
      default:
        return "";
    }
  };

  return {
    status,
    lastSavedAt,
    clearDraft,
    statusMessage: getStatusMessage(),
  };
}
