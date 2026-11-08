import type React from "react";
import { SkipLink } from "./SkipLink";

export function CandidateShell({ children }: { children: React.ReactNode }) {
  return (
    <div className="candidate-shell">
      <SkipLink />
      {children}
    </div>
  );
}
