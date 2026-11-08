import { useState } from "react";
import { createRoot } from "react-dom/client";
import { AppShell } from "@/components/shell/AppShell";
import { Drawer } from "@/components/ui/Drawer";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { StatusMenu } from "@/components/ui/StatusMenu";
import { INTERVIEW_COLUMNS } from "@/lib/interview/model";
import "@/app/globals.css";
import "@/styles/interview.css";

const STATUS_OPTIONS = [
  { value: "AVAILABLE", label: "Có thể sắp lịch / Available" },
  { value: "SCHEDULED", label: "Đã lên lịch / Scheduled" },
  { value: "AWAITING", label: "Chờ xác nhận / Awaiting confirmation" },
  { value: "CONFIRMED", label: "Đã xác nhận / Confirmed" },
] as const;

function InterviewBrowserHarness() {
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [status, setStatus] = useState("AWAITING");

  return (
    <div id="app-root" data-harness-ready="interview">
      <AppShell currentPath="/interviews" title="Lịch phỏng vấn">
        <section
          className="interview-page"
          aria-label="Interview design fixture"
        >
          <div className="interview-page-heading">
            <h1>Lịch phỏng vấn / Interviews</h1>
            <p>Production responsive browser acceptance fixture.</p>
          </div>

          <fieldset className="interview-toolbar">
            <legend className="sr-only">Thao tác Interview</legend>
            <button type="button" className="ui-button ui-button--primary">
              Ứng tuyển
            </button>
            <button
              type="button"
              className="ui-button ui-button--secondary"
              data-testid="open-interview-drawer"
              onClick={() => setDrawerOpen(true)}
            >
              Tạo lịch / Chi tiết
            </button>
          </fieldset>

          <fieldset className="interview-filters">
            <legend className="sr-only">Bộ lọc Interview</legend>
            <label>
              Tìm Tên / Email / SĐT
              <input type="search" defaultValue="" />
            </label>
            <label>
              Trạng thái
              <select defaultValue="AWAITING">
                <option value="AWAITING">Chờ xác nhận</option>
                <option value="CONFIRMED">Đã xác nhận</option>
              </select>
            </label>
          </fieldset>

          <div
            className="interview-table-scroll"
            data-testid="interview-table-scroll"
          >
            <table className="interview-table">
              <colgroup>
                {INTERVIEW_COLUMNS.map((width) => (
                  <col key={width ?? "note"} style={{ width }} />
                ))}
              </colgroup>
              <thead>
                <tr>
                  <th scope="col">Chọn</th>
                  <th scope="col">Ứng viên / Application</th>
                  <th scope="col">Thời gian</th>
                  <th scope="col">Địa điểm</th>
                  <th scope="col">Trạng thái</th>
                  <th scope="col">Ghi chú</th>
                  <th scope="col">Action</th>
                </tr>
              </thead>
              <tbody>
                <tr className="interview-application-row">
                  <td data-label="Chọn">
                    <label className="interview-select-target">
                      <input
                        type="checkbox"
                        defaultChecked
                        aria-label="Chọn Nguyễn Thị An"
                      />
                    </label>
                  </td>
                  <th scope="row" data-label="Ứng viên / Application">
                    <button
                      type="button"
                      className="interview-expand-button"
                      aria-expanded="true"
                    >
                      <span aria-hidden="true">▾</span>
                      <span>
                        Nguyễn Thị An
                        <small>Giảng viên · Khoa Kỹ thuật</small>
                      </span>
                    </button>
                  </th>
                  <td data-label="Thời gian">14:00 – 15:30 · 20/05/2025</td>
                  <td data-label="Địa điểm">Phòng A1.01</td>
                  <td data-label="Trạng thái">
                    <StatusBadge tone="warning" operationalInterview>
                      Chờ xác nhận / Awaiting confirmation
                    </StatusBadge>
                  </td>
                  <td data-label="Ghi chú">
                    Application có nhiều vòng phỏng vấn và lịch sử được giữ lại.
                  </td>
                  <td data-label="Action">
                    <button
                      type="button"
                      className="ui-button ui-button--secondary"
                    >
                      Chi tiết
                    </button>
                  </td>
                </tr>
                <tr className="interview-round-row">
                  <td data-label="Chọn">
                    <label className="interview-select-target">
                      <input type="checkbox" aria-label="Chọn Vòng 1" />
                    </label>
                  </td>
                  <th scope="row" data-label="Ứng viên / Application">
                    Vòng 1<small>Interview round</small>
                  </th>
                  <td data-label="Thời gian">14:00 – 15:30 · 20/05/2025</td>
                  <td data-label="Địa điểm">Phòng A1.01</td>
                  <td data-label="Trạng thái">
                    <div className="interview-status-menu interview-status-menu--awaiting">
                      <StatusMenu
                        label={
                          STATUS_OPTIONS.find((item) => item.value === status)
                            ?.label ?? "Chờ xác nhận / Awaiting confirmation"
                        }
                        currentValue={status}
                        options={[...STATUS_OPTIONS]}
                        onSelect={setStatus}
                      />
                    </div>
                  </td>
                  <td data-label="Ghi chú">
                    Nội dung nghiệp vụ dài phải wrap thay vì ép nhỏ typography.
                  </td>
                  <td data-label="Action">
                    <button
                      type="button"
                      className="ui-button ui-button--secondary"
                    >
                      Mở
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <Drawer
          open={drawerOpen}
          title="Chi tiết Interview"
          onClose={() => setDrawerOpen(false)}
          footer={
            <button type="button" className="ui-button ui-button--primary">
              Lưu
            </button>
          }
        >
          <dl className="interview-detail-grid">
            <dt>Thời gian phỏng vấn</dt>
            <dd>14:00 – 15:30 · 20/05/2025</dd>
            <dt>Địa điểm</dt>
            <dd>Phòng A1.01</dd>
          </dl>
        </Drawer>
      </AppShell>
    </div>
  );
}

const root = document.getElementById("root");
if (!root) throw new Error("Interview browser fixture root missing");
createRoot(root).render(<InterviewBrowserHarness />);
