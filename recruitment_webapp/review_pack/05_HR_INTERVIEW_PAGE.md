# 05. HR – Interview Page

## 1. Mục đích

Page Interview quản lý:
- Application;
- các vòng Interview;
- lịch/logistics;
- participants;
- tài liệu;
- email.

Không quản lý nội dung report cuối; report nằm ở Page Báo cáo phỏng vấn.

## 2. Application identity

Một Application = một Submission được xét cho đúng tổ hợp:

`Khoa/Phòng + Ngành/Tổ + Vị trí`

Nếu tổ hợp khác → Application khác.

Application identity không được rewrite ngay từ khi tạo. Muốn đổi Khoa/Phòng / Ngành/Tổ / Vị trí → tạo/tìm Application khác; exact same identity dùng lại cùng Application ID.

## 3. Bảng

| Tickbox | Họ và tên | Thời gian | Địa điểm | Trạng thái | Ghi chú |
|---|---|---|---|---|---|

Cột tên:

**Nguyễn Văn A**  
`Giảng viên Điện tử – Viễn thông - Khoa Kỹ thuật`

Không dùng dấu `·`.

### Nhiều vòng
Application là dòng cha; các Interview Session bung bên dưới:

```text
Nguyễn Văn A
Giảng viên Điện tử – Viễn thông - Khoa Kỹ thuật
  Vòng 1 | 08:30, Thứ Năm, 07/05/2026 | Confirmed
  Vòng 2 | 14:00, Thứ Sáu, 15/05/2026 | Scheduled
```

Chỉ một Application group mở tại một thời điểm nếu cần giữ UI gọn.

## 4. Interview Schedule Status

| Code | VI | Màu | Edit |
|---|---|---|---|
| `AVAILABLE` | Sẵn sàng | Đỏ | Có |
| `SCHEDULED` | Đã xếp lịch | Xanh dương | Có |
| `AWAITING` | Chờ xác nhận | Cam | Có |
| `CONFIRMED` | Đã xác nhận | Xanh lá | **Không** |
| `CANCELLED` | Hủy | Xám | Có |

- HR đổi thủ công.
- Không ép thứ tự.
- Save lịch không tự đổi status.
- Gửi email không tự đổi status.
- Muốn Edit `CONFIRMED` → đổi status khác trước.

## 5. Nút `Ứng tuyển`

UI label vẫn là **Ứng tuyển**, nhưng entity được chọn thực tế là **Submission cụ thể**, không phải Candidate chung chung.

Searchable multi-select:
- search Tên/Email/SĐT;
- option hiển thị tối thiểu 3 dòng để phân biệt nhiều lần nộp:
  **Nguyễn Văn A**
  `abc@email.com`
  `Phiếu: 01/09/2026 14:35 · Đã đọc`
- backend nhận `submission_id` của option được chọn, không tự suy ra phiếu mới nhất;
- khi điều hướng từ Submission Drawer, `submission_id` được preselect/lock cho thao tác đó;
- `CLOSED` vẫn có thể tạo Application mới theo business rule; khi có Application active, Submission quay lại `PROCESSED`;
- checkbox `Trùng`.

Popup `Update Information`:
1. Khoa/Phòng – required.
2. Ngành/Tổ – optional.
3. Vị trí – required.
4. Demo Topic – chỉ cho single assignment hoặc edit riêng; nếu bulk thì để trống.
5. HR phụ trách – active user role `Chuyên viên HR`.

### Exact duplicate
Nếu đúng cùng Submission + Khoa/Phòng + Ngành/Tổ + Vị trí:
- warning;
- yêu cầu confirm;
- nếu tiếp tục: update Application hiện có, không tạo ID mới.

## 6. Tạo Vòng 1

Khi tạo Application mới, hệ thống tạo Interview Session Vòng 1:
- `round_no = 1`;
- `schedule_status = AVAILABLE`;
- `report_status = INTERVIEW_SCHEDULING`;
- Demo Topic:
  - single assignment có thể nhập ngay;
  - bulk assignment để trống.

## 7. Tạo vòng tiếp theo (Owner Decision A)

- `1 Application → N Interview Sessions`.
- Vòng mới giữ nguyên identity của Application.
- `round_no = max(round_no) + 1`.
- Demo Topic **luôn để trống** ở vòng mới; HR tự điền.
- **Điều kiện tạo vòng mới (Create-next-round gate):**
  1. Record có `round_no` lớn nhất hiện có **bắt buộc đang Active** (`is_active=true`). Nếu round cuối đang Inactive → phải Reactivate hoặc Hard Delete hợp lệ trước; không tạo vòng mới.
  2. Round active cuối cùng **chưa có kết quả `HIRED`** (`report_status_code <> 'HIRED'`). Kết quả `HIRED` là điểm kết thúc tuyển dụng cho Application này, không được tạo thêm vòng sau.
  3. Trạng thái lịch `CANCELLED` (Đã hủy) **không chặn tạo vòng tiếp theo**; chỉ cần round active cuối cùng chưa `HIRED`.
- Schedule Status không có lộ trình chuyển đổi bắt buộc; cho phép nhảy trực tiếp giữa các trạng thái hợp lệ. Mỗi Interview round có đúng một Schedule Status tại một thời điểm.
### Delete/Inactive round
- Chỉ round có `round_no` lớn nhất hiện có mới được Delete/Inactive.
- Không được Delete/Inactive vòng giữa khi còn vòng sau.
- Muốn xử lý vòng giữa → xử lý vòng sau trước.
- Hard Delete round cuối chỉ khi chưa có business usage/reference.
- Nếu đã có usage → Inactive.
- Không renumber round lịch sử.
- Nếu round cuối hard-delete hoàn toàn vì chưa có lịch sử, số round đó có thể được dùng lại khi tạo mới.

## 8. Tạo lịch

Một Session/lần.

Field:
- ngày;
- giờ bắt đầu;
- giờ kết thúc;
- hình thức;
- phòng hoặc Meeting Link;
- Demo Topic;
- participants;
- Interview Note.

### Hình thức
Danh mục:
- Trực tiếp;
- Online;
- có thể mở rộng.

## 9. Participants

Nguồn: `Danh mục → Người dùng`.

- Chỉ User Active.
- Searchable.
- Mỗi dòng một người.
- Có icon Xóa.
- Không duplicate.
- Có drag/drop hoặc ↑ ↓.
- Thứ tự này quyết định Interviewer 1,2,3... trong PDF.
- Snapshot tên/email/chức vụ khi chọn.

Nếu remove người đã có report:
- warning;
- participant không còn current;
- report không render trong PDF hiện hành;
- user không còn thấy record.
Nếu add lại → hỏi Restore old / Create new.

## 10. Copy lịch

Icon `Copy lịch` ở đầu dòng.

Target phải là:
- cùng Application → tạo vòng tiếp theo; hoặc
- một Application khác đã tồn tại.

Không tự tạo Application ngầm.

Copy schedule/logistics phù hợp (ngày, giờ, format, room/location, participant prefill) nhưng:
- Demo Topic để trống;
- HR được đổi time/room/participants;
- `round_no` do target Application quyết định.

## 11. Conflict validation

Trước commit:
- Candidate overlap → **BLOCK**;
- Room overlap nếu dùng phòng → **BLOCK**;
- mọi current Interviewer overlap → **BLOCK**;
- interval semantics `[start_at,end_at)`; `end=start` là adjacent và được phép;
- bỏ qua `CANCELLED`, Interview inactive, parent Application inactive hoặc Interview chưa có interval.

Trước bất kỳ mutation nào làm Interview từ dormant/non-resource-blocking thành operational/resource-blocking, server cũng phải revalidate **mọi current Participant vẫn là Active Internal User**; nếu không, fail `CURRENT_PARTICIPANT_INACTIVE_REASSIGN_REQUIRED` và yêu cầu remove/replace Participant.

Candidate/Room/Interviewer conflict → **block Save**.

Server phải re-check trong transaction để tránh race condition giữa hai HR.

## 12. Drawer HR

Layout `Label | Nội dung`.

- Họ tên.
- Email.
- SĐT.
- Khoa/Phòng.
- Ngành/Tổ.
- Vị trí.
- Vòng.
- Demo Topic.
- Thời gian.
- Hình thức.
- Địa điểm/Meeting Link.
- Schedule Status.
- Participants.
- Interview Note.
- HR phụ trách.
- Cập nhật gần nhất.

Nút đầu:
`Edit | Xóa | Gửi thư ứng viên | Gửi thư người tham dự`

## 13. Toolbar

Sticky dưới page title:
- Ứng tuyển.
- Tạo lịch.
- Xóa.
- Đổi status.
- Gửi thư ứng viên.
- Gửi thư người tham dự.

`Tạo lịch` không bulk.

## 14. Email/Documents

- 2 nút email thủ công.
- Preview trước gửi.
- Không tự đổi status.
- Email History có tickbox + Delete.
- Documents optional cho HR upload.
- Candidate không thấy.
- Interviewer thấy/tải khi còn quyền thấy Session.

## 15. Search/Filter

Search: Tên/Email/SĐT.

Filter:
- Khoa/Phòng;
- Ngành/Tổ;
- Vị trí;
- Schedule Status;
- thời gian;
- địa điểm;
- hình thức;
- participant;
- HR phụ trách.


## Schedule conflict engine
Mọi mutation làm một Interview trở thành operationally active phải dùng cùng conflict engine server-side. Block overlap theo:
- Candidate;
- Room (nếu áp dụng);
- mọi current Interviewer.

Khoảng thời gian dùng semantic `[start_at, end_at)`, vì vậy `08:00–09:00` và `09:00–10:00` không overlap. `CANCELLED`, Interview inactive hoặc parent Application inactive không block resource.

## Reactivation, Copy and inactive-history behavior
- Application has explicit **Reactivate Application** action in Phase 1. Reactivation restores child `access_active` state and revalidates only non-elapsed children that would become `reactivation_conflict_relevant = resource_blocking AND end_at > transaction_now`; fully elapsed past-only overlaps do not block lifecycle recovery. Any still-relevant Candidate/Room/Interviewer conflict blocks the whole reactivation. Current Round remains report/outcome selector only.
- Interview list/filter exposes `Active | Inactive | All`; inactive rounds remain discoverable. A latest inactive round must be visible with `Vòng N — Không hoạt động` and Reactivate action when allowed.
- Copy to another Application: if target auto-created Round 1 is structurally empty **and has no incoming/outgoing Copy provenance**, Save fills Round 1; otherwise Save creates the next legal round. Copy UI itself is only a draft/prefill.
- Format switch normalizes stale resources: format not requiring Room clears `room_id`; format not requiring Meeting Link clears `meeting_link`; HYBRID may retain both when metadata requires both.
- Historical inactive Interview Format remains valid for lifecycle operations on an existing Interview but cannot be selected for a new/change reference.
- Grouped pagination is by **Application**, never raw Interview Session.

## Canonical schedule predicates
- `access_active` controls active/inactive context and Interviewer access.
- `current_round` selects report/outcome/PDF only.
- `resource_blocking` includes every access-active, non-CANCELLED Interview with a real interval; not limited to Current Round.
- Application Reactivate re-checks every **NON-ELAPSED** child that would become `reactivation_conflict_relevant = resource_blocking AND end_at > transaction_now` before commit. Fully elapsed historical intervals do **not** block lifecycle recovery.
