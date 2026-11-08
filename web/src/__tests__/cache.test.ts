import assert from "node:assert/strict";
import test from "node:test";

import { getSensitiveCacheHeaders } from "@/lib/security/cache";

test("getSensitiveCacheHeaders prevents shared caching of sensitive responses", () => {
  assert.deepEqual(getSensitiveCacheHeaders(), {
    "Cache-Control": "private, no-store",
  });
});
