"use client";

import { useEffect } from "react";

export interface ErrorBoundaryProps {
  error: Error & { digest?: string };
  reset: () => void;
}

export default function ErrorBoundary({ error, reset }: ErrorBoundaryProps) {
  useEffect(() => {
    // Error logged for diagnostics
    console.error("Application error:", error);
  }, [error]);

  return (
    <div role="alert" className="error-boundary">
      <h2 className="error-title">Đã xảy ra lỗi / An error occurred</h2>
      <p className="error-message">
        {error.message ||
          "Hệ thống gặp sự cố không mong muốn. Vui lòng thử lại."}
      </p>
      <button type="button" onClick={() => reset()} className="btn-primary">
        Thử lại / Try again
      </button>
    </div>
  );
}
