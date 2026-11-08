# 04. HR – Quản lý Phiếu Ứng tuyển

## 1. Mục đích

Đây là Application Inbox của HR – nơi nhận tất cả Submission từ Candidate và là điểm bắt đầu xử lý hồ sơ.

## 2. Bảng danh sách chính

Hiển thị gọn:

| Select | Tên | Email | Ngày sinh | Giới tính | SĐT | Trạng thái | HR Note |
|---|---|---|---|---|---|---|---|

Không hiển thị Ngày ứng tuyển ở dòng chính.

### Trường hợp Candidate có nhiều Submission

Hiển thị badge số phiếu cạnh tên, ví dụ:

`Nguyễn Văn A   [3 phiếu]`

Click dòng Candidate:
- Nếu chỉ có 1 Submission → mở Drawer trực tiếp.
- Nếu >1 Submission → bung danh sách phiếu con phía dưới.
- Chỉ một Candidate group được mở tại một thời điểm.

Phiếu con hiển thị:

```text
01/09/2026 14:35 | Processed | HR Note...
20/03/2026 09:10 | Closed    | HR Note...
15/08/2025 16:20 | Done      | HR Note...
```

Tên cột chính thức: **Ngày ứng tuyển**.

Click phiếu con → mở Drawer đúng Submission đó.

## 3. Search / Filter

Quy tắc tìm kiếm server-side chuẩn hóa:
- **Debounce:** 300 ms trên ô nhập liệu.
- **Tìm kiếm Họ tên (Name broad search):** yêu cầu tối thiểu 2 ký tự (`length >= 2`). Không thực hiện quét broad `%x%` với 1 ký tự duy nhất.
- **Email & Số điện thoại:** tìm kiếm exact/prefix có thể kích hoạt ngay (email lower-case exact/prefix; SĐT chuẩn hóa số exact/prefix).
- **Phân trang:** mặc định 25 records/trang; hỗ trợ các tùy chọn 25, 50, 100.
- **Bảo vệ PII trong URL:** chuỗi tìm kiếm PII (họ tên, email, SĐT) chỉ nằm trong request/client state, **không serialize vào browser URL, query string, browser history hay telemetry**.

Filter nghiệp vụ:
- Trạng thái.
- Ngày ứng tuyển.
- Active / Inactive.
- Mới / đã đọc.
- Có/Chưa có Application.
## 4. Submission status

Business status của Submission:
- `NEW` – Mới.
- `READ` – Đã đọc.
- `PROCESSED` – Đang xử lý / đã có Application.
- `DONE` – Hoàn tất thành công theo kết quả Application.
- `CLOSED` – Các Application kết thúc không tuyển.

### New / Read (Pure Detail Read vs. Explicit Open)
- Submit mới → `NEW`.
- **Pure detail read (`get_submission_detail`):** chỉ đọc dữ liệu chi tiết phiếu, **tuyệt đối không làm thay đổi trạng thái từ NEW sang READ**. Các tác vụ passive server render, data fetch, prefetch, refresh danh sách hay background preview bắt buộc chỉ gọi `get_submission_detail`.
- **Explicit open (`open_submission`):** là lệnh ghi nhận chủ ý của người dùng khi HR click mở chi tiết phiếu `NEW`. Khi caller có đủ quyền (`submissions.view + submissions.status`), lệnh chuyển trạng thái `NEW → READ`. Nếu caller chỉ có `submissions.view`, lệnh là read-only và không mutation.
- Candidate chỉ được edit khi Submission còn `NEW`. Sau khi phiếu sang `READ`, Candidate muốn sửa phải liên hệ HR để HR chủ động Mark as New.
### Processed → New
Không cho chuyển trực tiếp nếu còn Application liên quan.

Phải xóa thông tin/Application gán tại page Interview trước, sau đó mới cho phép đưa Submission về New.

### Inactive (effective status từ Candidate account)
`Inactive` không phải Submission business status riêng. Đây là manual override ở **cấp Candidate/account**, được thao tác từ Page Quản lý phiếu.
- Không xóa Candidate, Submission hoặc Application.
- HR vẫn xem/filter được toàn bộ dữ liệu.
- Khi Candidate inactive, UI HR có thể hiển thị `INACTIVE` như effective status cho các phiếu thuộc Candidate đó, trong khi trạng thái workflow nền vẫn được bảo toàn để tính lại khi Active.
- Candidate không đăng nhập được vào Candidate Portal bằng email đó cho tới khi HR Active lại.
- Candidate inactive không xuất hiện trong selector `Ứng tuyển` mặc định ở page Interview.
- Application/Interview/Report đã tạo trước đó không bị xóa và vẫn tiếp tục tồn tại ở các page nội bộ.
- Khi Active lại, hệ thống recalculation trạng thái theo Application hiện hành.

## 5. HR Note

- `hr_note` chỉ HR thấy.
- Candidate không có field ghi chú này và không nhìn thấy.
- Hiển thị rút gọn ở table.
- Chỉnh sửa trong Drawer.

## 6. Drawer

Drawer rộng, desktop-first.
Bố cục cố định:

| Label | Nội dung |
|---|---|
| **Họ tên:** | Nguyễn Văn A |
| **Email:** | abc@email.com |
| **Ngày sinh:** | 01/01/1995 |
| **Giới tính:** | Nam |
| **SĐT:** | 090... |
| **Địa chỉ hiện tại:** | ... |

Không dùng bố cục 2x2. Là **1 cột label + 1 cột value**.

### Section trong Drawer
1. Thông tin chung.
2. Education.
3. Working Experiences – HR only.
4. Activities – HR only.
5. Other – HR only.
6. Documents.
7. HR Note / Nguồn tuyển dụng (optional HR metadata).
8. Cập nhật thông tin tuyển dụng.
9. Cập nhật gần nhất.

## 7. Edit Drawer

- Một nút `Edit` cho toàn bộ Drawer.
- Không Edit từng section.
- Khi Edit: toàn bộ field HR được phép sửa chuyển sang editable.
- Footer: `Cancel | Save Changes`.
- Nếu đóng drawer khi có dữ liệu chưa lưu → cảnh báo.

## 8. Documents

HR được:
- Preview.
- Download.
- Upload thêm.
- Replace/Xóa theo quyền.

## 9. Link sang Interview

Dòng gần cuối Drawer:

**Cập nhật thông tin tuyển dụng:**
- `Update` – chưa có Application.
- `Updated` – đã có Application.
- Nếu có nhiều Application có thể hiển thị số lượng, ví dụ `Updated (2)`.

Click → chuyển sang page Interview và mở/filter đúng Candidate/Submission.

## 10. Bulk actions

Checkbox trên bảng cho phép:
- Inactive.
- Active lại.
- Mark as New / Read theo rule.
- Các bulk action khác **OUT OF SCOPE Phase 1** trừ khi được phê duyệt qua Change Request.

## 11. Last updated

Chỉ hiển thị ở cuối Drawer, không hiển thị trong bảng:

`Cập nhật gần nhất: dd/mm/yyyy hh:mm - bởi ...`

## Parent Candidate row and grouped pagination
- Parent Candidate row uses **latest Submission only** for Submission-derived summary fields, ordered `submitted_at DESC, submission_id DESC`.
- This matches owner intent: older Submissions are failed/obsolete for operational summary; they remain historical child records but do not drive the parent summary.
- Parent row fields `Tên / DOB / Gender / Phone / Status / HR Note` therefore come from the latest Submission snapshot; Email remains the Candidate verified identity.
- Grouped pagination is by **Candidate**, never raw Submission row. Children are fetched with the Candidate group or lazy-loaded.
- Stable sort uses requested sort + Candidate ID tie-breaker.
- PII search value (name/email/phone) is not persisted in URL/query string.
