# 32. Business Logic Freeze – v1.2

## Freeze statement

Từ ngày 02/09/2026, core business logic sau được xem là **FROZEN**:

- Candidate authentication/email identity.
- Candidate Form/Phiếu của tôi.
- Candidate Active/Inactive.
- Submission grouping/status.
- Application identity và duplicate behavior.
- Nhiều Application per Submission.
- Nhiều Interview Round per Application.
- Round sequencing.
- Schedule status/conflict/copy.
- Participants/order/snapshot.
- Email/Documents.
- Báo cáo phỏng vấn HR + Interviewer.
- Current Round / PDF logic.
- Report final-source logic.
- Root Admin + granular HR permission.
- Delete/Inactive.
- Concurrency rules.
- Derived Submission/Application outcomes.

## Change control

Bất kỳ thay đổi nào làm đổi:
- entity ownership;
- status derivation;
- permission;
- delete behavior;
- round logic;
- PDF source;
- Candidate visibility;

được xem là **Change Request** và phải regression lại các flow liên quan.

Visual Design System/token/component không phải Change Request nếu không đổi behavior.

## Remaining non-core items

Không thuộc freeze này:
- Dashboard/KPI chi tiết.
- Recruitment Needs chi tiết.
- Offer/Approval/Onboarding.
- email templates final.
- PDF layout final.
- Design System visual.
