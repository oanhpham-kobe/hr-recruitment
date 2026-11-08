"use client";

import { useEffect, useMemo, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import type { AssignmentOptions } from "@/lib/application-inbox/submission-detail-model";
import type {
  ApplicationSelectorOption,
  InterviewApplicationGroup,
  InterviewFormatOption,
  InterviewRoomOption,
  InterviewRound,
  InterviewUserOption,
  SubmissionSelectorOption,
} from "@/lib/interview/model";
import { vietnamLocalToIso } from "./InterviewDrawer";

function localInput(value: string | null): string {
  if (!value) return "";
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Ho_Chi_Minh",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(new Date(value));
  const get = (type: string) =>
    parts.find((part) => part.type === type)?.value ?? "";
  return `${get("year")}-${get("month")}-${get("day")}T${get("hour")}:${get("minute")}`;
}

export function ApplicationAssignmentDialog({
  open,
  pending,
  onClose,
  onSearchSubmissions,
  onLoadAssignmentOptions,
  onSubmit,
}: {
  open: boolean;
  pending: boolean;
  onClose: () => void;
  onSearchSubmissions: (query: string) => Promise<SubmissionSelectorOption[]>;
  onLoadAssignmentOptions: () => Promise<AssignmentOptions | null>;
  onSubmit: (input: {
    submissionId: string;
    unitId: string;
    departmentTeamId: string | null;
    positionId: string;
    hrOwnerId: string;
    confirmDuplicate: boolean;
  }) => void;
}) {
  const [query, setQuery] = useState("");
  const [submissions, setSubmissions] = useState<SubmissionSelectorOption[]>(
    [],
  );
  const [assignment, setAssignment] = useState<AssignmentOptions | null>(null);
  const [submissionId, setSubmissionId] = useState("");
  const [unitId, setUnitId] = useState("");
  const [teamId, setTeamId] = useState("");
  const [positionId, setPositionId] = useState("");
  const [hrOwnerId, setHrOwnerId] = useState("");
  const [confirmDuplicate, setConfirmDuplicate] = useState(false);

  useEffect(() => {
    if (!open) return;
    let active = true;
    Promise.all([onSearchSubmissions(""), onLoadAssignmentOptions()]).then(
      ([submissionData, assignmentData]) => {
        if (!active) return;
        setSubmissions(submissionData);
        setAssignment(assignmentData);
      },
    );
    return () => {
      active = false;
    };
  }, [open, onLoadAssignmentOptions, onSearchSubmissions]);

  const teams =
    assignment?.department_teams.filter((team) => team.unit_id === unitId) ??
    [];
  const positions =
    assignment?.positions.filter(
      (position) =>
        position.unit_id === unitId &&
        (!teamId || position.department_team_id === teamId),
    ) ?? [];
  const canSubmit = Boolean(submissionId && unitId && positionId && hrOwnerId);

  return (
    <Dialog
      open={open}
      title="Ứng tuyển — chọn Phiếu cụ thể"
      onClose={onClose}
      footer={
        <Button
          variant="primary"
          pending={pending}
          disabled={!canSubmit}
          onClick={() =>
            onSubmit({
              submissionId,
              unitId,
              departmentTeamId: teamId || null,
              positionId,
              hrOwnerId,
              confirmDuplicate,
            })
          }
        >
          Tạo / cập nhật Application
        </Button>
      }
    >
      <div className="interview-dialog-stack">
        <div className="interview-search-row">
          <label>
            Tìm Phiếu theo Tên / Email / SĐT
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              autoComplete="off"
            />
          </label>
          <Button
            disabled={pending}
            onClick={async () =>
              setSubmissions(await onSearchSubmissions(query))
            }
          >
            Tìm
          </Button>
        </div>
        <div className="interview-submission-selector">
          <strong id="submission-selector-label">Phiếu ứng tuyển cụ thể</strong>
          <div
            className="interview-submission-options"
            role="listbox"
            aria-labelledby="submission-selector-label"
          >
            {submissions.map((option) => (
              <button
                key={option.submissionId}
                type="button"
                role="option"
                aria-selected={submissionId === option.submissionId}
                className="interview-submission-option"
                onClick={() => setSubmissionId(option.submissionId)}
              >
                <strong>{option.candidateName}</strong>
                <span>{option.verifiedEmail}</span>
                <span>
                  Phiếu:{" "}
                  {new Date(option.submittedAt).toLocaleString("vi-VN", {
                    timeZone: "Asia/Ho_Chi_Minh",
                  })}{" "}
                  · {option.status}
                </span>
              </button>
            ))}
          </div>
          <span className="interview-field-hint">
            Không tự suy ra Phiếu mới nhất.
          </span>
        </div>
        <label>
          Khoa / Phòng
          <select
            value={unitId}
            onChange={(event) => {
              setUnitId(event.target.value);
              setTeamId("");
              setPositionId("");
            }}
          >
            <option value="">Chọn Khoa / Phòng</option>
            {assignment?.units.map((unit) => (
              <option key={unit.unit_id} value={unit.unit_id}>
                {unit.name_vi}
              </option>
            ))}
          </select>
        </label>
        <label>
          Ngành / Tổ
          <select
            value={teamId}
            onChange={(event) => {
              setTeamId(event.target.value);
              setPositionId("");
            }}
          >
            <option value="">Không chọn</option>
            {teams.map((team) => (
              <option
                key={team.department_team_id}
                value={team.department_team_id}
              >
                {team.name_vi}
              </option>
            ))}
          </select>
        </label>
        <label>
          Vị trí
          <select
            value={positionId}
            onChange={(event) => setPositionId(event.target.value)}
          >
            <option value="">Chọn vị trí</option>
            {positions.map((position) => (
              <option key={position.position_id} value={position.position_id}>
                {position.name_vi}
              </option>
            ))}
          </select>
        </label>
        <label>
          HR phụ trách
          <select
            value={hrOwnerId}
            onChange={(event) => setHrOwnerId(event.target.value)}
          >
            <option value="">Chọn HR</option>
            {assignment?.hr_owners.map((owner) => (
              <option key={owner.app_user_id} value={owner.app_user_id}>
                {owner.full_name} — {owner.email}
              </option>
            ))}
          </select>
        </label>
        <label className="interview-checkbox-label">
          <input
            type="checkbox"
            checked={confirmDuplicate}
            onChange={(event) => setConfirmDuplicate(event.target.checked)}
          />
          Xác nhận tiếp tục nếu đúng identity Application đã tồn tại (update
          cùng Application ID).
        </label>
      </div>
    </Dialog>
  );
}

export function CopyScheduleDialog({
  open,
  sourceApplication,
  sourceRound,
  formats,
  rooms,
  users,
  pending,
  onClose,
  onSearchApplications,
  onSubmit,
}: {
  open: boolean;
  sourceApplication: InterviewApplicationGroup;
  sourceRound: InterviewRound;
  formats: InterviewFormatOption[];
  rooms: InterviewRoomOption[];
  users: InterviewUserOption[];
  pending: boolean;
  onClose: () => void;
  onSearchApplications: (query: string) => Promise<ApplicationSelectorOption[]>;
  onSubmit: (input: {
    target: ApplicationSelectorOption;
    startAt: string | null;
    endAt: string | null;
    interviewFormatId: string | null;
    roomId: string | null;
    meetingLink: string | null;
    interviewNote: string | null;
    participantAppUserIds: string[];
  }) => void;
}) {
  const [query, setQuery] = useState("");
  const [targets, setTargets] = useState<ApplicationSelectorOption[]>([]);
  const [targetId, setTargetId] = useState("");
  const [startAt, setStartAt] = useState(localInput(sourceRound.startAt));
  const [endAt, setEndAt] = useState(localInput(sourceRound.endAt));
  const [formatId, setFormatId] = useState(sourceRound.interviewFormatId ?? "");
  const [roomId, setRoomId] = useState(sourceRound.roomId ?? "");
  const [meetingLink, setMeetingLink] = useState(sourceRound.meetingLink ?? "");
  const [note, setNote] = useState(sourceRound.interviewNote ?? "");
  const [participantIds, setParticipantIds] = useState<string[]>(
    sourceRound.participants
      .filter(
        (p) => p.isCurrent && users.some((user) => user.id === p.appUserId),
      )
      .sort((a, b) => a.order - b.order)
      .map((p) => p.appUserId),
  );
  const [normalizationNotice, setNormalizationNotice] = useState<string | null>(
    null,
  );

  useEffect(() => {
    if (!open) return;
    let active = true;
    onSearchApplications("").then((data) => {
      if (!active) return;
      setTargets(data);
      const same = data.find(
        (option) => option.applicationId === sourceApplication.applicationId,
      );
      if (same) setTargetId(same.applicationId);
    });
    return () => {
      active = false;
    };
  }, [open, onSearchApplications, sourceApplication.applicationId]);

  const target = targets.find((option) => option.applicationId === targetId);
  const selectedFormat = formats.find((format) => format.id === formatId);
  const activeFormats = formats.filter((format) => format.isActive);
  const activeRooms = rooms.filter((room) => room.isActive);
  const startIso = startAt ? vietnamLocalToIso(startAt) : null;
  const endIso = endAt ? vietnamLocalToIso(endAt) : null;
  const scheduleEmpty = !startAt && !endAt;
  const scheduleComplete = Boolean(
    startAt && endAt && startIso && endIso && startIso < endIso && formatId,
  );
  const canSubmit = Boolean(target && (scheduleEmpty || scheduleComplete));
  const inactivePrefillParticipants = sourceRound.participants.filter(
    (participant) =>
      participant.isCurrent &&
      !users.some((user) => user.id === participant.appUserId),
  );
  const orderedSelectedUsers = useMemo(
    () =>
      participantIds
        .map((id) => users.find((user) => user.id === id))
        .filter((user): user is InterviewUserOption => Boolean(user)),
    [participantIds, users],
  );

  return (
    <Dialog
      open={open}
      title={`Copy lịch — ${sourceApplication.candidateName} / Vòng ${sourceRound.roundNo}`}
      onClose={onClose}
      footer={
        <Button
          variant="primary"
          pending={pending}
          disabled={!canSubmit}
          onClick={() => {
            if (!target) return;
            onSubmit({
              target,
              startAt: startIso,
              endAt: endIso,
              interviewFormatId: formatId || null,
              roomId: selectedFormat?.requiresRoom ? roomId || null : null,
              meetingLink: selectedFormat?.requiresMeetingLink
                ? meetingLink.trim() || null
                : null,
              interviewNote: note.trim() || null,
              participantAppUserIds: participantIds,
            });
          }}
        >
          Save Copy
        </Button>
      }
    >
      <div className="interview-dialog-stack">
        <p className="interview-info-note">
          Đây chỉ là draft trên client. Chưa có dữ liệu được ghi cho đến khi bấm
          Save Copy. Demo Topic của vòng đích luôn để trống.
        </p>
        <div className="interview-search-row">
          <label>
            Tìm Application đích
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
          </label>
          <Button
            disabled={pending}
            onClick={async () => setTargets(await onSearchApplications(query))}
          >
            Tìm
          </Button>
        </div>
        <label>
          Application đích
          <select
            value={targetId}
            onChange={(event) => setTargetId(event.target.value)}
          >
            <option value="">Chọn Application</option>
            {targets.map((option) => (
              <option key={option.applicationId} value={option.applicationId}>
                {option.label} — Vòng hiện tại {option.latestRoundNo}
              </option>
            ))}
          </select>
        </label>
        <div className="interview-form-grid">
          <label>
            Bắt đầu
            <input
              type="datetime-local"
              value={startAt}
              onChange={(event) => setStartAt(event.target.value)}
            />
          </label>
          <label>
            Kết thúc
            <input
              type="datetime-local"
              value={endAt}
              onChange={(event) => setEndAt(event.target.value)}
            />
          </label>
          <label>
            Hình thức
            <select
              value={formatId}
              onChange={(event) => {
                const value = event.target.value;
                setFormatId(value);
                const format = formats.find((item) => item.id === value);
                const cleared: string[] = [];
                if (!format?.requiresRoom && roomId) {
                  setRoomId("");
                  cleared.push("Phòng");
                }
                if (!format?.requiresMeetingLink && meetingLink) {
                  setMeetingLink("");
                  cleared.push("Meeting Link");
                }
                setNormalizationNotice(
                  cleared.length
                    ? `${cleared.join(" và ")} đã được xóa vì không áp dụng cho hình thức mới.`
                    : null,
                );
              }}
            >
              <option value="">Chọn hình thức</option>
              {activeFormats.map((format) => (
                <option key={format.id} value={format.id}>
                  {format.name}
                </option>
              ))}
            </select>
          </label>
          {normalizationNotice ? (
            <p
              className="interview-field-hint interview-form-span"
              role="status"
              aria-live="polite"
            >
              {normalizationNotice}
            </p>
          ) : null}
          {selectedFormat?.requiresRoom ? (
            <label>
              Phòng
              <select
                value={roomId}
                onChange={(event) => setRoomId(event.target.value)}
              >
                <option value="">Chọn phòng</option>
                {activeRooms.map((room) => (
                  <option key={room.id} value={room.id}>
                    {room.name}
                  </option>
                ))}
              </select>
            </label>
          ) : null}
          {selectedFormat?.requiresMeetingLink ? (
            <label>
              Meeting Link
              <input
                type="url"
                value={meetingLink}
                onChange={(event) => setMeetingLink(event.target.value)}
              />
            </label>
          ) : null}
          <label className="interview-form-span">
            Interview Note
            <textarea
              rows={3}
              value={note}
              onChange={(event) => setNote(event.target.value)}
            />
          </label>
        </div>
        {inactivePrefillParticipants.length ? (
          <div className="ui-alert ui-alert--warning" role="status">
            {inactivePrefillParticipants
              .map((participant) => participant.name)
              .join(", ")}{" "}
            không còn Active nên không được prefill vào Copy. Hãy chọn
            Participant Active thay thế nếu cần.
          </div>
        ) : null}
        <fieldset className="interview-copy-participants">
          <legend>Participants prefill — có thể chỉnh trước Save Copy</legend>
          {users.map((user) => (
            <label key={user.id}>
              <input
                type="checkbox"
                checked={participantIds.includes(user.id)}
                onChange={(event) =>
                  setParticipantIds((current) =>
                    event.target.checked
                      ? [...current, user.id]
                      : current.filter((id) => id !== user.id),
                  )
                }
              />
              {user.name} — {user.email}
            </label>
          ))}
          {orderedSelectedUsers.length ? (
            <p className="interview-field-hint">
              Thứ tự hiện tại:{" "}
              {orderedSelectedUsers.map((user) => user.name).join(" → ")}
            </p>
          ) : null}
        </fieldset>
      </div>
    </Dialog>
  );
}
