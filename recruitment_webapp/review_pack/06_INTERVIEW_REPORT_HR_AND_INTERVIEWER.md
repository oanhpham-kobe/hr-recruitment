# 06. Báo cáo phỏng vấn – HR & Interviewer

## 1. Nguyên tắc nhiều vòng

Page Báo cáo phỏng vấn hiển thị **mỗi Application một dòng**.

Dòng đó lấy dữ liệu của:
> `Current Active Latest Interview Round`

Vòng cũ không hiển thị thành dòng chính riêng nhưng vẫn giữ lịch sử và có thể xem từ Application/Interview history.

Preview/PDF hiện hành **chỉ dùng Current Round**.

## 2. HR table

| Tickbox | Họ và tên | Vị trí | Thời gian phỏng vấn | Địa điểm | Trạng thái | Ghi chú |
|---|---|---|---|---|---|---|

Chỉ Application có ít nhất một Interview Session mới xuất hiện.

## 3. Report Status thuộc Interview Session

| Code | VI | English |
|---|---|---|
| `INTERVIEW_SCHEDULING` | Chờ xếp lịch | Interview Scheduling |
| `AWAITING_INTERVIEW` | Chờ phỏng vấn | Awaiting Interview |
| `WAITING_FOR_REPORT` | Chờ báo report | Waiting for Report |
| `REPORT_SUBMITTED` | Đã gửi Báo cáo | Report Submitted |
| `FOLLOW_UP` | Theo dõi thêm | Follow-up |
| `ON_HOLD` | Hoãn | On Hold |
| `HIRED` | Tuyển dụng | Hired |
| `REJECTED` | Từ chối | Rejected |

- HR đổi thủ công.
- Không ép thứ tự.
- Page Báo cáo dùng status của Current Round.

### Khi tạo vòng mới
Vòng mới trở thành Current Round và khởi tạo:
`INTERVIEW_SCHEDULING`.

Vì vậy report/status/PDF vòng cũ không còn là report hiện hành, nhưng dữ liệu cũ không bị xóa.

## 4. Application outcome

Application outcome không cần HR nhập riêng.

Derive từ Current Round:
- Current Report Status = `HIRED` → Application outcome `HIRED`.
- Current Report Status = `REJECTED` → Application outcome `REJECTED`.
- Còn lại → `IN_PROGRESS`.

Tạo vòng mới làm Application trở lại `IN_PROGRESS` vì Current Round mới chưa có kết quả final.

## 5. Interviewer-facing status

| HR Current Round | Interviewer thấy |
|---|---|
| Chờ xếp lịch | Chờ xếp lịch |
| Chờ phỏng vấn | Chờ phỏng vấn |
| Chờ báo report | Chờ báo report |
| Đã gửi Báo cáo | Đã gửi Báo cáo |
| Theo dõi thêm | Đã gửi Báo cáo |
| Hoãn | Đã gửi Báo cáo |
| Tuyển dụng | Đã gửi Báo cáo |
| Từ chối | Từ chối |

## 6. HR Drawer

**Chỉ hiển thị Report data, không lặp Interview data.**

Nút đầu:
- Edit HR Note / quản lý Report theo quyền.
- Ẩn/Hiện Interviewer.
- Xem.
- Tải PDF.

Không có nút `Xóa` ở aggregate drawer. Delete/Inactive chỉ nằm cạnh một `interview_report_id` cụ thể.

Nội dung:
- Report Status Current Round.
- HR phụ trách (Application-owned; changed via `applications.manage`).
- HR Report Note.
- Visibility.
- Danh sách interviewer reports.
- Nguồn decision block hiện hành – chỉ HR.
- Cập nhật gần nhất.
- Link `Xem thông tin phỏng vấn`.

Nếu HR có permission `reports.edit_interviewer`, ở từng interviewer report có action Edit.

## 7. Visibility

`visible_to_interviewers` thuộc Current Interview Session.

- Ẩn: tất cả participant của Current Round không thấy row.
- Không xóa participant/report/PDF.
- Hiện lại: dữ liệu cũ xuất hiện lại.
- HR filter: Tất cả / Đang hiển thị / Đang ẩn.

## 8. Interviewer View (Owner Decision I — Historical Access & Write Authorization)

### Quyền READ (Xem lịch sử)
- Interviewer được phép **READ các Interview round lịch sử mà họ đã trực tiếp tham gia** (yêu cầu: active internal user, có row `interview_participants.is_current=true` tại đúng Interview đó, parent Application và Interview đang `access_active`, và session `visible_to_interviewers=true`).
- Việc Application có Current Round mới **không tước quyền đọc** các round trước mà interviewer đã tham gia.
- Participant bị gỡ khỏi round sẽ mất quyền truy cập round đó.
- Không có quyền xem bắc cầu sang các vòng hoặc Candidate mà interviewer không tham gia.

### Quyền WRITE (Ghi / Sửa Report)
- Ghi/sửa báo cáo yêu cầu đồng thời:
  1. Target Interview phải là **Current Round của Application**;
  2. Caller sở hữu report gắn với current participant row của mình;
  3. Caller là active internal user;
  4. Session visible và `access_active`;
  5. `report_status_code` của **chính Interview đó đang ở trạng thái non-final / writable** (không phải `HIRED` hoặc `REJECTED`). Không dùng report status của vòng khác để kiểm tra.

Drawer Interviewer = **Interview info + Report info**.

### Nút
Chưa có report:
`Báo cáo PV | Xem | Tải PDF`

Đã có:
`Edit | Xem | Tải PDF`

Nếu Report Status của target Interview = `HIRED` hoặc `REJECTED`:
- Interviewer không được Edit.
- Muốn Edit lại → HR đổi status về non-final.
## 9. Form report cá nhân

**Hard rule:** Báo cáo phỏng vấn **không có chấm điểm/scoring/rating/star/thang điểm**. Không developer/AI nào được tự bổ sung cơ chế điểm nếu chưa có Change Request nghiệp vụ mới.

Các field không bắt buộc:

### Evaluation and Comment
1. Kiến thức chuyên môn / Professional Knowledge
2. Kỹ năng cần thiết / Necessary Skills
3. Phẩm chất, tính cách / Qualities and Personality
4. Điểm mạnh và hạn chế / Strengths and Limitations
5. Khác / Other

### Decision block & Blank Conclusion (Owner Decision F)
- Kết luận / Conclusion
- Dự kiến công việc cụ thể được phân công / Expected Specific Job Assigned
- Thời gian dự kiến tuyển dụng / Expected Recruitment Time

**Quy tắc để trống:** HR **được phép set `HIRED` hoặc `REJECTED` ngay cả khi Conclusion, Expected Job và Expected Recruitment Time để trống**. Không tạo invariant bắt buộc phải có Conclusion mới được chốt kết quả.

Thứ tự xác định Final Decision Source trong production: timestamp quyết định hợp lệ mới nhất (`decision_updated_at DESC`), sau đó tie-break bằng Report UUID xác định.

### Field-Aware Report Merge
Khi lưu/cập nhật report:
- Request gửi kèm `expected_version_no` và giá trị gốc `base_values` cho từng field được patch;
- Server lock row report và so sánh giá trị hiện tại trong DB với `base_values`:
  - `current == base`: patch an toàn;
  - `current != base`: conflict trên cùng field.
- Với HR: conflict trên cùng field → từ chối với `STALE_VERSION` để reload; các field khác nhau (disjoint) được merge tự động.
- Với Interviewer sửa report của chính mình: áp dụng owner-wins cho eligible conflict cùng field; các field khác nhau được merge.
- Chỉ khi có thay đổi thực tế ở 3 final decision fields thì metadata quyết định mới được cập nhật.
## 10. Preview/PDF

### Evaluation
Render tất cả participant hiện hành theo `participant_order`.

Tên + chức vụ:
- auto lấy từ User HR đã chọn ở Page Interview;
- dùng snapshot tại thời điểm chọn.

Field trống vẫn render đúng template.

Nếu participant bị remove:
- block của họ biến mất khỏi Preview/PDF hiện hành;
- thứ tự còn lại được đánh lại.

### Final Decision Source

Hội đồng phải trao đổi và thống nhất; **không yêu cầu mọi Interviewer cùng nhập 3 field final decision**. Thông thường chỉ 01 Interviewer đại diện điền. Nếu Interviewer khác sửa một trong 3 field sau đó, hệ thống hiểu đó là bản điều chỉnh mới sau trao đổi của hội đồng.

Trong **Current Round**, eligible report là report active/current có ít nhất một field decision block có nội dung. Final source = eligible report có `decision_updated_at` mới nhất.

- `decision_updated_at` / `decision_updated_by` **chỉ cập nhật khi một trong 3 field final decision thay đổi**.
- Sửa `Professional Knowledge`, `Necessary Skills`, `Qualities and Personality`, `Strengths and Limitations`, `Other` không làm đổi Final Decision Source.
- Cả 3 final fields luôn lấy từ cùng một report; không merge field từ nhiều Interviewer.
- Nếu source hiện hành xóa hết 3 decision fields → source fallback về eligible report có `decision_updated_at` gần nhất trước đó.

HR thấy:
- nguồn kết luận hiện hành;
- `decision_updated_by`;
- `decision_updated_at`;
- `updated_at` tổng thể của report có thể hiển thị riêng nếu cần audit.

Interviewer không thấy metadata kỹ thuật về source.

## 11. Concurrency khi HR sửa Interviewer Report

HR chỉ sửa được khi có `reports.edit_interviewer`.

- HR stale vs Interviewer newer → HR Save bị block, yêu cầu reload.
- Interviewer vs HR trên cùng report → dùng **field-aware patch/merge**; nếu sửa khác field thì giữ cả hai thay đổi; nếu cùng field thì Interviewer wins. Không whole-row overwrite từ stale form.
- HR vs HR → stale Save bị block.
- Interviewer same-user nhiều tab → stale Save bị block.

## 12. PDF nhiều vòng

- PDF hiện hành chỉ của Current Round.
- Report/PDF vòng cũ vẫn có dữ liệu lịch sử để truy xuất nội bộ nếu cần.
- Không merge nhiều vòng thành một PDF trong Phase 1.

## Report delete semantics and pagination
- HR Report page remains one row per Application using Current Round and paginates by **Application**.
- Remove ambiguous aggregate-level `Xóa` action. Aggregate drawer actions are: Edit HR Note, Change Report Status, Hide/Show Interviewer, Xem, Tải PDF.
- Delete/Inactive is only attached to a concrete `interview_report_id` for a specific participant report. Deleting/inactivating an Interview Session belongs to the Interview module.
- System email from Report has **no attachments in Phase 1**.

## Trusted mutation split
HR Report Status and HR Report Note are separate mutations. `change_report_status` is the only trusted writer of Report Status and always recalculates the parent Submission in the same transaction. `update_hr_report_note` edits only the HR-only note and never changes status or derived outcome.
