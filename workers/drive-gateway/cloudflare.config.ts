import { defineConfig } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

export default defineConfig({
  worker: {
    name: "eiu-private-drive-gateway",
    compatibilityDate: "2026-11-05",
    entrypoint,
    placement: { region: "aws:ap-southeast-1" },
    observability: {
      enabled: true,
      redactQueryString: true,
      logs: { enabled: true, invocationLogs: false },
      traces: { enabled: true },
    },
    // Secrets and origins are provisioned separately. No cron is enabled until
    // the provider-specific claim migration and runtime scanner are verified.
    workersDev: true,
    previewUrls: false,
  },
});
