import assert from "node:assert/strict";
import test from "node:test";

test("Prototype Final Decision date-sort regression", () => {
  const parsePrototypeDateTime = (value: string | undefined): number => {
    if (!value) return Number.NEGATIVE_INFINITY;
    const match = value.match(/^(\d{2})\/(\d{2})\/(\d{4})\s+(\d{2}):(\d{2})$/);
    if (!match) return Number.NEGATIVE_INFINITY;
    const [, dd, mm, yyyy, hh, min] = match;
    return Date.UTC(
      Number(yyyy),
      Number(mm) - 1,
      Number(dd),
      Number(hh),
      Number(min),
    );
  };

  const reports: [
    string,
    { decisionUpdatedAt?: string; updatedAt?: string; conclusion?: string },
  ][] = [
    ["u2", { updatedAt: "01/08/2026 10:00", conclusion: "Hire" }],
    ["u1", { decisionUpdatedAt: "31/08/2026 10:00", conclusion: "Hire" }],
    ["u3", { decisionUpdatedAt: "15/07/2026 14:00", conclusion: "Hire" }],
  ];

  reports.sort((a, b) => {
    const bt = parsePrototypeDateTime(
      b[1].decisionUpdatedAt || b[1].updatedAt || "",
    );
    const at = parsePrototypeDateTime(
      a[1].decisionUpdatedAt || a[1].updatedAt || "",
    );
    if (bt !== at) return bt - at;
    return String(b[0]).localeCompare(String(a[0]));
  });

  // 31/08/2026 10:00 must sort BEFORE 01/08/2026 10:00 (newest first)
  assert.equal(reports[0][0], "u1", "31/08/2026 must sort before 01/08/2026");
  assert.equal(reports[1][0], "u2", "01/08/2026 must sort second");
  assert.equal(reports[2][0], "u3", "15/07/2026 must sort third");
});

test("Prototype candidateStatusLabel maps DONE and CLOSED to Hoàn thành", () => {
  const candidateStatusLabel = (status: string): string =>
    ({
      NEW: "Mới",
      READ: "Đang xử lý",
      PROCESSED: "Đang xử lý",
      DONE: "Hoàn thành",
      CLOSED: "Hoàn thành",
    })[status] || status;

  assert.equal(candidateStatusLabel("NEW"), "Mới");
  assert.equal(candidateStatusLabel("READ"), "Đang xử lý");
  assert.equal(candidateStatusLabel("PROCESSED"), "Đang xử lý");
  assert.equal(candidateStatusLabel("DONE"), "Hoàn thành");
  assert.equal(candidateStatusLabel("CLOSED"), "Hoàn thành");
});
