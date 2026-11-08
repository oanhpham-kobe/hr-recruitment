import assert from "node:assert/strict";
import test from "node:test";
import {
  formatInterviewTime,
  INTERVIEW_COLUMNS,
  nextExpandedApplicationId,
  normalizeInterviewFilters,
} from "@/lib/interview/model";

test("Interview columns reserve accessible selection, status and action targets", () => {
  assert.equal(INTERVIEW_COLUMNS.length, 7);
  assert.equal(INTERVIEW_COLUMNS[0], 48);
  assert.ok(INTERVIEW_COLUMNS[4] >= 144 + 24);
  assert.ok(INTERVIEW_COLUMNS[6] >= 44 + 24);
  assert.ok(
    INTERVIEW_COLUMNS.slice(1, 4).every((width) => typeof width === "string"),
  );
});

test("only one Application group is expanded at a time", () => {
  assert.equal(nextExpandedApplicationId(null, "app-a"), "app-a");
  assert.equal(nextExpandedApplicationId("app-a", "app-b"), "app-b");
  assert.equal(nextExpandedApplicationId("app-a", "app-a"), null);
});

test("Interview filters keep PII query as bounded client/server state", () => {
  const normalized = normalizeInterviewFilters({
    query: `  ${"A".repeat(300)}  `,
    activity: "INACTIVE",
  });
  assert.equal(normalized.activity, "INACTIVE");
  assert.equal(normalized.query.length, 256);
  assert.deepEqual(normalizeInterviewFilters({ activity: "ACTIVE" }), {
    query: "",
    activity: "ACTIVE",
    unitId: "",
    departmentTeamId: "",
    positionId: "",
    scheduleStatus: "",
    dateFrom: "",
    dateTo: "",
    location: "",
    interviewFormatId: "",
    participantAppUserId: "",
    hrOwnerId: "",
  });
});

test("Interview canonical filters normalize UUIDs, status, dates and location safely", () => {
  const uuid = "11111111-1111-4111-8111-111111111111";
  const normalized = normalizeInterviewFilters({
    unitId: uuid,
    departmentTeamId: "not-a-uuid",
    positionId: uuid,
    scheduleStatus: "CONFIRMED",
    dateFrom: "2026-09-08",
    dateTo: "bad-date",
    location: `ROOM:${uuid}`,
    interviewFormatId: uuid,
    participantAppUserId: uuid,
    hrOwnerId: uuid,
  });
  assert.equal(normalized.unitId, uuid);
  assert.equal(normalized.departmentTeamId, "");
  assert.equal(normalized.positionId, uuid);
  assert.equal(normalized.scheduleStatus, "CONFIRMED");
  assert.equal(normalized.dateFrom, "2026-09-08");
  assert.equal(normalized.dateTo, "");
  assert.equal(normalized.location, `ROOM:${uuid}`);
  assert.equal(normalized.interviewFormatId, uuid);
  assert.equal(normalized.participantAppUserId, uuid);
  assert.equal(normalized.hrOwnerId, uuid);
  assert.equal(
    normalizeInterviewFilters({ scheduleStatus: "INVALID" as never })
      .scheduleStatus,
    "",
  );
  assert.equal(
    normalizeInterviewFilters({ location: "javascript:bad" }).location,
    "",
  );
});

test("Interview time renders time first and date second in Vietnam timezone", () => {
  const value = formatInterviewTime(
    "2026-05-20T07:00:00.000Z",
    "2026-05-20T08:30:00.000Z",
  );
  assert.match(value, /^14:00 – 15:30 · 20\/05\/2026$/);
  assert.equal(formatInterviewTime(null, null), "Chưa xếp lịch");
});
