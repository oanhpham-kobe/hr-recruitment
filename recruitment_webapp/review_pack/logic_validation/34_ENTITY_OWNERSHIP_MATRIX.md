# 34. Final Entity Ownership Matrix

| Dữ liệu | Entity owner | Ghi chú |
|---|---|---|
| Auth email Candidate | Candidate/Auth | Immutable trong hồ sơ |
| Candidate active/inactive | Candidate | Khóa/mở Candidate Portal |
| Thông tin mỗi lần form | Submission | Snapshot từng lần ứng tuyển |
| HR Note của phiếu | Submission | Candidate không thấy |
| Khoa/Phòng | Application | Một phần Application identity |
| Ngành/Tổ | Application | Optional, một phần identity |
| Vị trí | Application | Một phần identity |
| HR phụ trách | Application | Active HR user |
| round_no | Interview Session | Immutable sau create |
| Demo Topic | Interview Session | Vòng mới blank |
| Thời gian/Hình thức/Phòng/Link | Interview Session | Logistics từng vòng |
| Interview Schedule Status | Interview Session | AVAILABLE...CANCELLED |
| Report Status | Interview Session | Interview Scheduling...Hired/Rejected |
| Interview Note | Interview Session | Note logistics |
| Report Note | Interview Session | Note HR ở Page Báo cáo |
| Visibility to interviewer | Interview Session | Ẩn/Hiện Current Round |
| Participants/order | Interview Session | Snapshot User |
| Interview documents | Interview Session | HR optional |
| Email history | Interview Session/Application ref | Có thể xóa test/error |
| Evaluation | Interview Report | 1 interviewer/1 session |
| Conclusion/Expected Job/Time | Interview Report | Final source theo latest eligible |
| Application outcome | Derived | Từ Current Round |
| Submission DONE/CLOSED | Derived | Từ active Applications |
| Root Admin | app_users | Chỉ 1 |
| HR permissions | user_permissions | Root Admin gán |
