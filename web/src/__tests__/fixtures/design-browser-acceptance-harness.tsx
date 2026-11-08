import { useState } from "react";
import { createRoot } from "react-dom/client";
import { SubmissionsList } from "@/components/candidate/SubmissionsList";
import { AppShell } from "@/components/shell/AppShell";
import { CandidateShell } from "@/components/shell/CandidateShell";
import { Drawer } from "@/components/ui/Drawer";
import { StatusBadge } from "@/components/ui/StatusBadge";
import "@/app/globals.css";
import "@/styles/candidate-portal.css";

const COLUMNS = [
  "select",
  "name",
  "email",
  "dateOfBirth",
  "gender",
  "phone",
  "status",
  "hrNote",
  "action",
] as const;

function InternalHarness() {
  const [drawerOpen, setDrawerOpen] = useState(false);
  return (
    <div id="app-root" data-harness-ready="internal">
      <AppShell currentPath="/" title="Quản lý Phiếu Ứng tuyển">
        <section
          className="application-inbox"
          aria-label="Application Inbox design fixture"
        >
          <div className="application-inbox__header">
            <h2>Quản lý Phiếu Ứng tuyển</h2>
            <p>Production responsive design acceptance fixture.</p>
          </div>
          <form
            className="application-inbox__toolbar"
            onSubmit={(event) => event.preventDefault()}
          >
            <label className="application-inbox__search">
              Tìm kiếm Candidate
              <input type="search" defaultValue="" />
            </label>
            <label>
              Trạng thái
              <select defaultValue="ALL">
                <option value="ALL">Tất cả</option>
                <option value="READ">Đã đọc</option>
              </select>
            </label>
          </form>
          <div className="application-inbox__bulk-toolbar">
            <span className="application-inbox__selection-count">
              1 Candidate được chọn
            </span>
            <div className="application-inbox__bulk-actions">
              <button
                type="button"
                className="btn-secondary application-inbox__bulk-btn"
              >
                Đánh dấu Đã đọc
              </button>
              <button
                type="button"
                className="btn-secondary application-inbox__bulk-btn"
                data-testid="open-drawer"
                onClick={() => setDrawerOpen(true)}
              >
                Mở chi tiết
              </button>
            </div>
          </div>
          <div
            className="application-inbox__table-scroll"
            data-testid="internal-table-scroll"
          >
            <table className="application-inbox__table">
              <colgroup>
                {COLUMNS.map((key) => (
                  <col key={key} className={`application-inbox__col--${key}`} />
                ))}
              </colgroup>
              <thead>
                <tr>
                  <th scope="col">Chọn</th>
                  <th scope="col">Candidate</th>
                  <th scope="col">Email</th>
                  <th scope="col">Ngày sinh</th>
                  <th scope="col">Giới tính</th>
                  <th scope="col">SĐT</th>
                  <th scope="col">Trạng thái</th>
                  <th scope="col">HR Note</th>
                  <th scope="col">Thao tác</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td data-label="Chọn">
                    <label className="application-inbox__selection-control">
                      <input
                        type="checkbox"
                        defaultChecked
                        aria-label="Chọn Nguyễn Thị An"
                      />
                    </label>
                  </td>
                  <td data-label="Candidate">
                    <button
                      type="button"
                      className="application-inbox__expand-button"
                      aria-expanded="false"
                    >
                      Nguyễn Thị An
                    </button>
                  </td>
                  <td data-label="Email" className="wrap-anywhere">
                    an@example.com
                  </td>
                  <td data-label="Ngày sinh">15/08/1995</td>
                  <td data-label="Giới tính">Nữ</td>
                  <td data-label="SĐT">0901 234 567</td>
                  <td data-label="Trạng thái">
                    <StatusBadge tone="info" operationalInterview>
                      Đã lên lịch / Scheduled
                    </StatusBadge>
                  </td>
                  <td data-label="HR Note">
                    Đã liên hệ và xác nhận thông tin.
                  </td>
                  <td data-label="Thao tác">
                    <button
                      type="button"
                      className="btn-secondary application-inbox__action-btn"
                    >
                      Chi tiết
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
        <Drawer
          open={drawerOpen}
          title="Chi tiết Candidate"
          onClose={() => setDrawerOpen(false)}
          footer={
            <button type="button" className="ui-button ui-button--primary">
              Lưu
            </button>
          }
        >
          <p>Drawer production design acceptance content.</p>
          <label>
            HR Note
            <textarea defaultValue="Ghi chú kiểm thử responsive" />
          </label>
        </Drawer>
      </AppShell>
    </div>
  );
}

function CandidateHarness() {
  return (
    <div id="app-root" data-harness-ready="candidate">
      <CandidateShell>
        <div className="portal-container">
          <header className="portal-header">
            <div>
              <h1>Ứng tuyển EIU</h1>
              <p>Candidate responsive production fixture.</p>
            </div>
          </header>
          <main id="main-content" className="portal-main">
            <SubmissionsList
              submissions={[
                {
                  submissionId: "submission-1",
                  submittedAt: "2026-09-02T09:00:00.000Z",
                  statusCode: "NEW",
                  versionNo: 1,
                },
                {
                  submissionId: "submission-2",
                  submittedAt: "2026-08-15T09:00:00.000Z",
                  statusCode: "DONE",
                  versionNo: 2,
                },
              ]}
              onEditSubmission={() => undefined}
              onViewSubmission={() => undefined}
              onNewApplication={() => undefined}
            />
          </main>
        </div>
      </CandidateShell>
    </div>
  );
}

function LoginHarness() {
  return (
    <div id="app-root" data-harness-ready="login">
      <div className="login-page">
        <aside className="login-brand-panel">
          <div className="brand-panel-header">
            <div className="brand-panel-logo">
              <span className="brand-logo-text">EIU</span>
            </div>
            <div className="brand-panel-institution">
              Eastern International University
            </div>
          </div>
          <div className="brand-panel-body">
            <span className="brand-panel-badge">Recruitment</span>
            <h1 className="brand-panel-title">Hệ thống Tuyển dụng EIU</h1>
            <p className="brand-panel-desc">Đăng nhập để tiếp tục.</p>
          </div>
        </aside>
        <main className="login-main-panel">
          <section className="login-card" aria-label="Login design fixture">
            <header className="login-card-header">
              <h2 className="login-card-title">Đăng nhập / Sign in</h2>
              <p className="login-card-subtitle">Chọn tài khoản phù hợp.</p>
            </header>
            <div className="login-form-group">
              <label className="login-label" htmlFor="login-email">
                Email
              </label>
              <input
                id="login-email"
                className="login-input"
                type="email"
                defaultValue="hr@eiu.edu.vn"
              />
            </div>
            <button type="button" className="btn-login-primary">
              Tiếp tục / Continue
            </button>
            <button type="button" className="btn-login-link">
              Đặt lại / Reset
            </button>
          </section>
        </main>
      </div>
    </div>
  );
}

const mode = document.body.dataset.harness;
const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Design browser acceptance root element is missing");
}
const root = createRoot(rootElement);
if (mode === "candidate") root.render(<CandidateHarness />);
else if (mode === "login") root.render(<LoginHarness />);
else root.render(<InternalHarness />);
