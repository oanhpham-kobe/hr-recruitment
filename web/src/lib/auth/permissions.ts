export interface PermissionDefinition {
  code: string;
  labelVi: string;
  labelEn: string;
  category: string;
}

export const DELEGABLE_PERMISSIONS: readonly PermissionDefinition[] = [
  // Hồ sơ ứng tuyển
  {
    code: "submissions.view",
    labelVi: "Xem danh sách và chi tiết hồ sơ",
    labelEn: "View Submissions",
    category: "Hồ sơ (Submissions)",
  },
  {
    code: "submissions.edit",
    labelVi: "Chỉnh sửa thông tin hồ sơ",
    labelEn: "Edit Submissions",
    category: "Hồ sơ (Submissions)",
  },
  {
    code: "submissions.status",
    labelVi: "Cập nhật trạng thái thủ công hồ sơ",
    labelEn: "Update Submission Status",
    category: "Hồ sơ (Submissions)",
  },
  // Ứng viên
  {
    code: "candidates.active_manage",
    labelVi: "Khóa / Mở khóa ứng viên",
    labelEn: "Manage Candidate Active Status",
    category: "Ứng viên (Candidates)",
  },
  {
    code: "candidates.delete_unused",
    labelVi: "Xóa ứng viên chưa có hồ sơ",
    labelEn: "Delete Unused Candidates",
    category: "Ứng viên (Candidates)",
  },
  {
    code: "candidates.identity_manage",
    labelVi: "Liên kết lại danh tính ứng viên",
    labelEn: "Manage Candidate Identity",
    category: "Ứng viên (Candidates)",
  },
  // Ứng tuyển
  {
    code: "applications.view",
    labelVi: "Xem hồ sơ phân công tuyển dụng",
    labelEn: "View Applications",
    category: "Ứng tuyển (Applications)",
  },
  {
    code: "applications.manage",
    labelVi: "Tạo và quản lý phân công tuyển dụng",
    labelEn: "Manage Applications",
    category: "Ứng tuyển (Applications)",
  },
  // Phỏng vấn
  {
    code: "interviews.view",
    labelVi: "Xem lịch phỏng vấn",
    labelEn: "View Interviews",
    category: "Phỏng vấn (Interviews)",
  },
  {
    code: "interviews.manage",
    labelVi: "Lên lịch và điều chỉnh phỏng vấn",
    labelEn: "Manage Interviews",
    category: "Phỏng vấn (Interviews)",
  },
  {
    code: "interviews.status",
    labelVi: "Cập nhật trạng thái vòng phỏng vấn",
    labelEn: "Update Interview Status",
    category: "Phỏng vấn (Interviews)",
  },
  {
    code: "interviews.participants",
    labelVi: "Quản lý hội đồng phỏng vấn",
    labelEn: "Manage Interview Participants",
    category: "Phỏng vấn (Interviews)",
  },
  {
    code: "interviews.documents",
    labelVi: "Tải tài liệu phỏng vấn",
    labelEn: "Upload Interview Documents",
    category: "Phỏng vấn (Interviews)",
  },
  {
    code: "interviews.email",
    labelVi: "Gửi email phỏng vấn",
    labelEn: "Send Interview Emails",
    category: "Phỏng vấn (Interviews)",
  },
  // Email
  {
    code: "emails.history_view",
    labelVi: "Xem lịch sử gửi email",
    labelEn: "View Email History",
    category: "Email",
  },
  {
    code: "emails.history_delete",
    labelVi: "Xóa nhật ký email thử nghiệm",
    labelEn: "Delete Email History",
    category: "Email",
  },
  // Báo cáo
  {
    code: "reports.view",
    labelVi: "Xem báo cáo phỏng vấn HR",
    labelEn: "View HR Reports",
    category: "Báo cáo (Reports)",
  },
  {
    code: "reports.manage_status",
    labelVi: "Duyệt / Từ chối kết quả báo cáo",
    labelEn: "Manage Report Decision",
    category: "Báo cáo (Reports)",
  },
  {
    code: "reports.visibility",
    labelVi: "Đóng / Mở quyền xem của hội đồng",
    labelEn: "Toggle Report Visibility",
    category: "Báo cáo (Reports)",
  },
  {
    code: "reports.edit_interviewer",
    labelVi: "Sửa nội dung báo cáo hội đồng",
    labelEn: "Edit Interviewer Report",
    category: "Báo cáo (Reports)",
  },
  {
    code: "reports.delete",
    labelVi: "Xóa báo cáo phỏng vấn",
    labelEn: "Delete Reports",
    category: "Báo cáo (Reports)",
  },
  // Danh mục
  {
    code: "master_data.manage",
    labelVi: "Quản lý danh mục nghiệp vụ",
    labelEn: "Manage Master Data",
    category: "Danh mục (Master Data)",
  },
  // Nhân sự
  {
    code: "users.directory_read",
    labelVi: "Xem danh bạ nhân sự nội bộ",
    labelEn: "Read Internal Directory",
    category: "Người dùng (Users)",
  },
  {
    code: "users.directory_manage",
    labelVi: "Quản lý danh bạ nhân sự",
    labelEn: "Manage Internal Directory",
    category: "Người dùng (Users)",
  },
];
