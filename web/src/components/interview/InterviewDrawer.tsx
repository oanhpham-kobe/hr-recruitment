"use client";

import { useMemo, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Drawer } from "@/components/ui/Drawer";
import { StatusMenu } from "@/components/ui/StatusMenu";
import {
  formatInterviewTime,
  INTERVIEW_STATUS_LABEL,
  type InterviewApplicationGroup,
  type InterviewFormatOption,
  type InterviewParticipant,
  type InterviewPermissions,
  type InterviewRoomOption,
  type InterviewRound,
  type InterviewScheduleStatus,
  type InterviewUserOption,
} from "@/lib/interview/model";
import { InterviewEmailActions } from "./InterviewEmailActions";

const STATUS_OPTIONS = Object.entries(INTERVIEW_STATUS_LABEL).map(
  ([value, label]) => ({ value, label }),
);

function toLocalInput(value: string | null): string {
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

export function vietnamLocalToIso(value: string): string | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(value);
  if (!match) return null;
  const [, y, m, d, h, minute] = match;
  return new Date(
    Date.UTC(
      Number(y),
      Number(m) - 1,
      Number(d),
      Number(h) - 7,
      Number(minute),
    ),
  ).toISOString();
}

export interface InterviewDrawerProps {
  open: boolean;
  application: InterviewApplicationGroup;
  round: InterviewRound;
  formats: InterviewFormatOption[];
  rooms: InterviewRoomOption[];
  users: InterviewUserOption[];
  permissions: InterviewPermissions;
  pending: boolean;
  onClose: () => void;
  onSave: (input: {
    startAt: string | null;
    endAt: string | null;
    interviewFormatId: string | null;
    roomId: string | null;
    meetingLink: string | null;
    demoTopic: string | null;
    interviewNote: string | null;
  }) => void;
  onRescheduleConfirmed: (input: {
    startAt: string;
    endAt: string;
    interviewFormatId: string;
    roomId: string | null;
    meetingLink: string | null;
  }) => void;
  onStatus: (status: InterviewScheduleStatus) => void;
  onAddParticipant: (appUserId: string) => void;
  onRemoveParticipant: (participant: InterviewParticipant) => void;
  onReaddParticipant: (
    participant: InterviewParticipant,
    mode: "RESTORE_OLD_REPORT" | "CREATE_NEW_REPORT",
  ) => void;
  onReorderParticipants: (participants: InterviewParticipant[]) => void;
  onReactivateInterview: () => void;
  onDeleteInterview: () => void;
}

export function InterviewDrawer({
  open,
  application,
  round,
  formats,
  rooms,
  users,
  permissions,
  pending,
  onClose,
  onSave,
  onRescheduleConfirmed,
  onStatus,
  onAddParticipant,
  onRemoveParticipant,
  onReaddParticipant,
  onReorderParticipants,
  onReactivateInterview,
  onDeleteInterview,
}: InterviewDrawerProps) {
  const [startAt, setStartAt] = useState(toLocalInput(round.startAt));
  const [endAt, setEndAt] = useState(toLocalInput(round.endAt));
  const [formatId, setFormatId] = useState(round.interviewFormatId ?? "");
  const [roomId, setRoomId] = useState(round.roomId ?? "");
  const [meetingLink, setMeetingLink] = useState(round.meetingLink ?? "");
  const [demoTopic, setDemoTopic] = useState(round.demoTopic ?? "");
  const [note, setNote] = useState(round.interviewNote ?? "");
  const [participantUserId, setParticipantUserId] = useState("");
  const [participantQuery, setParticipantQuery] = useState("");
  const [normalizationNotice, setNormalizationNotice] = useState<string | null>(
    null,
  );

  const currentParticipants = useMemo(
    () =>
      round.participants
        .filter((participant) => participant.isCurrent)
        .sort((a, b) => a.order - b.order),
    [round.participants],
  );
  const removedParticipants = useMemo(
    () => round.participants.filter((participant) => !participant.isCurrent),
    [round.participants],
  );
  const selectedFormat = formats.find((format) => format.id === formatId);
  const selectableFormats = formats.filter(
    (format) => format.isActive || format.id === round.interviewFormatId,
  );
  const selectableRooms = rooms.filter(
    (room) => room.isActive || room.id === round.roomId,
  );
  const currentUserIds = new Set(
    currentParticipants.map((participant) => participant.appUserId),
  );
  const normalizedParticipantQuery = participantQuery
    .trim()
    .toLocaleLowerCase("vi");
  const selectableUsers = users.filter((user) => {
    if (currentUserIds.has(user.id)) return false;
    if (!normalizedParticipantQuery) return true;
    return `${user.name} ${user.email} ${user.jobTitle ?? ""}`
      .toLocaleLowerCase("vi")
      .includes(normalizedParticipantQuery);
  });

  const moveParticipant = (index: number, direction: -1 | 1) => {
    const target = index + direction;
    if (target < 0 || target >= currentParticipants.length) return;
    const reordered = [...currentParticipants];
    [reordered[index], reordered[target]] = [
      reordered[target],
      reordered[index],
    ];
    onReorderParticipants(reordered);
  };

  const startIso = startAt ? vietnamLocalToIso(startAt) : null;
  const endIso = endAt ? vietnamLocalToIso(endAt) : null;
  const scheduleValid =
    (!startAt && !endAt) ||
    Boolean(startIso && endIso && startIso < endIso && formatId);
  const roundOperational = application.isActive && round.isActive;
  const confirmed = round.scheduleStatus === "CONFIRMED";

  return (
    <Drawer
      open={open}
      title={`${application.candidateName} — Vòng ${round.roundNo}`}
      onClose={onClose}
      footer={
        permissions.canManage && roundOperational ? (
          <div className="interview-drawer-actions">
            <Button
              variant="primary"
              pending={pending}
              disabled={!scheduleValid}
              onClick={() => {
                if (round.scheduleStatus === "CONFIRMED") {
                  if (!startIso || !endIso || !formatId) return;
                  onRescheduleConfirmed({
                    startAt: startIso,
                    endAt: endIso,
                    interviewFormatId: formatId,
                    roomId: selectedFormat?.requiresRoom
                      ? roomId || null
                      : null,
                    meetingLink: selectedFormat?.requiresMeetingLink
                      ? meetingLink.trim() || null
                      : null,
                  });
                  return;
                }
                onSave({
                  startAt: startIso,
                  endAt: endIso,
                  interviewFormatId: formatId || null,
                  roomId: selectedFormat?.requiresRoom ? roomId || null : null,
                  meetingLink: selectedFormat?.requiresMeetingLink
                    ? meetingLink.trim() || null
                    : null,
                  demoTopic: demoTopic.trim() || null,
                  interviewNote: note.trim() || null,
                });
              }}
            >
              {round.scheduleStatus === "CONFIRMED"
                ? "Xếp lại lịch đã xác nhận"
                : "Lưu lịch"}
            </Button>
            <Button
              variant="danger"
              pending={pending}
              onClick={onDeleteInterview}
            >
              Xóa / Ngừng hoạt động
            </Button>
          </div>
        ) : undefined
      }
    >
      <dl className="interview-detail-grid">
        <dt>Họ tên</dt>
        <dd>{application.candidateName}</dd>
        <dt>Email</dt>
        <dd>{application.candidateEmail}</dd>
        <dt>SĐT</dt>
        <dd>{application.candidatePhone}</dd>
        <dt>Application</dt>
        <dd>
          {application.positionName} -{" "}
          {application.departmentTeamName
            ? `${application.departmentTeamName} - `
            : ""}
          {application.unitName}
        </dd>
        <dt>Vòng</dt>
        <dd>
          Vòng {round.roundNo}
          {round.isActive ? "" : " — Không hoạt động"}
        </dd>
        <dt>Thời gian</dt>
        <dd>{formatInterviewTime(round.startAt, round.endAt)}</dd>
        <dt>HR phụ trách</dt>
        <dd>{application.hrOwnerName}</dd>
      </dl>

      <section
        className="interview-drawer-section"
        aria-labelledby="interview-status-heading"
      >
        <h3 id="interview-status-heading">Trạng thái lịch</h3>
        {permissions.canChangeStatus && roundOperational ? (
          <StatusMenu
            label={INTERVIEW_STATUS_LABEL[round.scheduleStatus]}
            currentValue={round.scheduleStatus}
            options={STATUS_OPTIONS}
            onSelect={(status) => onStatus(status as InterviewScheduleStatus)}
          />
        ) : (
          <strong>{INTERVIEW_STATUS_LABEL[round.scheduleStatus]}</strong>
        )}
      </section>

      <InterviewEmailActions
        application={application}
        round={round}
        pending={pending}
      />

      {!round.isActive && application.isActive && permissions.canManage ? (
        <section className="interview-drawer-section">
          <h3>Vòng không hoạt động</h3>
          <p>
            Khôi phục vòng này là thao tác riêng với Kích hoạt lại Application.
          </p>
          <Button pending={pending} onClick={onReactivateInterview}>
            Kích hoạt lại Interview
          </Button>
        </section>
      ) : null}

      <fieldset
        className="interview-form-grid"
        disabled={!permissions.canManage || pending || !roundOperational}
      >
        <legend>Lịch / Logistics</legend>
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
              const next = event.target.value;
              setFormatId(next);
              const format = formats.find((item) => item.id === next);
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
            {selectableFormats.map((format) => (
              <option
                key={format.id}
                value={format.id}
                disabled={!format.isActive}
              >
                {format.name}
                {format.isActive ? "" : " (không hoạt động)"}
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
              {selectableRooms.map((room) => (
                <option key={room.id} value={room.id} disabled={!room.isActive}>
                  {room.name}
                  {room.building ? ` — ${room.building}` : ""}
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
          Demo Topic
          <textarea
            value={demoTopic}
            onChange={(event) => setDemoTopic(event.target.value)}
            rows={2}
            disabled={confirmed}
          />
        </label>
        <label className="interview-form-span">
          Interview Note
          <textarea
            value={note}
            onChange={(event) => setNote(event.target.value)}
            rows={3}
            disabled={confirmed}
          />
        </label>
        {confirmed ? (
          <p className="interview-field-hint interview-form-span">
            Lịch đã xác nhận chỉ cho phép xếp lại logistics bằng lệnh
            Reschedule. Đổi status khác trước khi sửa Demo Topic hoặc Interview
            Note.
          </p>
        ) : null}
      </fieldset>

      {!application.isActive ? (
        <section className="interview-drawer-section">
          <h3>Application không hoạt động</h3>
          <p>
            Reactivate Application từ dòng Application trước khi thực hiện
            mutation trên Interview.
          </p>
        </section>
      ) : null}

      <section
        className="interview-drawer-section"
        aria-labelledby="participants-heading"
      >
        <h3 id="participants-heading">Người tham dự / Participants</h3>
        {currentParticipants.length ? (
          <ol className="interview-participant-list">
            {currentParticipants.map((participant, index) => (
              <li key={participant.interviewParticipantId}>
                <div>
                  <strong>
                    {index + 1}. {participant.name}
                  </strong>
                  <span>
                    {participant.email}
                    {participant.jobTitle ? ` · ${participant.jobTitle}` : ""}
                  </span>
                </div>
                {permissions.canManageParticipants && roundOperational ? (
                  <div className="interview-participant-actions">
                    <Button
                      variant="ghost"
                      disabled={pending || index === 0}
                      aria-label={`Đưa ${participant.name} lên`}
                      onClick={() => moveParticipant(index, -1)}
                    >
                      ↑
                    </Button>
                    <Button
                      variant="ghost"
                      disabled={
                        pending || index === currentParticipants.length - 1
                      }
                      aria-label={`Đưa ${participant.name} xuống`}
                      onClick={() => moveParticipant(index, 1)}
                    >
                      ↓
                    </Button>
                    <Button
                      variant="danger"
                      disabled={pending}
                      onClick={() => onRemoveParticipant(participant)}
                    >
                      Xóa
                    </Button>
                  </div>
                ) : null}
              </li>
            ))}
          </ol>
        ) : (
          <p>Chưa có người tham dự.</p>
        )}
        {permissions.canManageParticipants && roundOperational ? (
          <div className="interview-add-participant">
            <label>
              Tìm người tham dự
              <input
                type="search"
                value={participantQuery}
                onChange={(event) => setParticipantQuery(event.target.value)}
                autoComplete="off"
              />
            </label>
            <label>
              Thêm người đang hoạt động
              <select
                value={participantUserId}
                onChange={(event) => setParticipantUserId(event.target.value)}
              >
                <option value="">Chọn người dùng</option>
                {selectableUsers.map((user) => (
                  <option key={user.id} value={user.id}>
                    {user.name} — {user.email}
                  </option>
                ))}
              </select>
            </label>
            <Button
              pending={pending}
              disabled={!participantUserId}
              onClick={() => {
                if (!participantUserId) return;
                onAddParticipant(participantUserId);
                setParticipantUserId("");
              }}
            >
              Thêm
            </Button>
          </div>
        ) : null}
        {removedParticipants.length &&
        permissions.canManageParticipants &&
        roundOperational ? (
          <div className="interview-removed-participants">
            <h4>Đã gỡ khỏi vòng</h4>
            {removedParticipants.map((participant) => (
              <div
                key={participant.interviewParticipantId}
                className="interview-removed-row"
              >
                <div>
                  <strong>{participant.name}</strong>
                  <span>
                    {participant.hasReportHistory
                      ? "Có lịch sử report — chọn cách khôi phục."
                      : "Đã gỡ khỏi danh sách hiện tại."}
                  </span>
                </div>
                <div>
                  <Button
                    pending={pending}
                    onClick={() =>
                      onReaddParticipant(participant, "RESTORE_OLD_REPORT")
                    }
                  >
                    Restore old report
                  </Button>
                  <Button
                    pending={pending}
                    onClick={() =>
                      onReaddParticipant(participant, "CREATE_NEW_REPORT")
                    }
                  >
                    Create new report
                  </Button>
                </div>
              </div>
            ))}
          </div>
        ) : null}
      </section>
    </Drawer>
  );
}
