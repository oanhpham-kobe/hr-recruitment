# App Tuyển dụng EIU — Full Handover v1.18

**Ngày cập nhật:** 06/09/2026  
**Business Logic Core:** v1.2 **FROZEN**  
**Design System:** v1.8 **CURRENT** — included in combined review bundle and supplied separately  
**Technical Architecture:** v1.18 **TECHNICAL SPECIFICATION FROZEN**  
**Production Ready:** **NO**

## Owner-authorized additive feature — 05/11/2026

`101_INTERNAL_INTERVIEW_FEEDBACK.md` governs the local-first questionnaire and
consolidated-report extension (CR-INTERVIEW-FEEDBACK-20261105). Owner selected the
existing five qualitative questions for the trial. Legacy report/decision rules,
official PDF layout deferral and production gates remain unchanged.

## 1. Mục đích của v1.18
v1.18 giữ nguyên Business Logic Core v1.2, four-gate implementation model và executable Responsive Prototype v1.10; tích hợp toàn diện các quyết định Owner Decisions A–K và hoàn thiện chuẩn hóa source trước thềm Slice 04. Technical Architecture v1.18 vẫn là TECHNICAL SPECIFICATION FROZEN; Implementation Gate = READY TO IMPLEMENT; Production Ready = NO.

## 2. Business đã chốt
- `Candidate → Submission → Application → Interview Session (1..N) → Participant → Report`.
- Application cố định theo `Submission + Khoa/Phòng + Ngành/Tổ + Vị trí`; tổ hợp khác = Application khác.
- Application selector luôn xác định **Submission cụ thể**, backend không tự chọn latest.
- Current Round = `access_active` Interview có `round_no` lớn nhất; chỉ dùng cho Report/Outcome/PDF, không giới hạn resource blocking.
- Page Báo cáo/Preview dùng Current Round; vòng cũ giữ lịch sử.
- Demo Topic thuộc Interview Session; vòng mới để trống.
- Không scoring/rating.
- Candidate chỉ edit khi `NEW`; HR mặc định mở `NEW → READ`. View-only HR không mutation.
- Candidate conflict / Room conflict / Interviewer conflict = **BLOCK**.
- Candidate Auth = **Email OTP**; Internal User = Google Workspace OAuth `@eiu.edu.vn`.
- Root Admin duy nhất. HR mặc định nhận **Full HR Permission Set**, Root có thể revoke granular rights.
- Delete unused → hard delete; used → inactive. Empty auto-created Round 1 chưa được coi là business history.
- Upload: PDF, DOC/DOCX, PPT/PPTX, PNG/JPG/JPEG; max 5 files/Submission or Interview; max 5 MB/file.
- Current retention business policy: no automatic purge; cảnh báo dung lượng, sau đó EIU chọn tăng dung lượng hoặc export/archive local + explicit purge.
- Official PDF pixel template intentionally deferred until owner provides approved source.

## 3. Final Decision
Thông thường 01 Interviewer đại diện nhập 3 final fields sau khi hội đồng thống nhất. Nếu người khác sửa một trong 3 field, đó là revision mới sau trao đổi.

`decision_updated_at/by` chỉ thay đổi khi một trong 3 final fields thay đổi. Sửa 5 qualitative fields không làm đổi Final Decision Source. Cả 3 final fields luôn lấy từ cùng một report.

## 4. Technical architecture hardening
- Application derive Candidate through Submission; no duplicate `candidate_id`.
- Null-safe Unit/Team/Position invariant.
- Interview Report belongs to Participant.
- Separate `interview_note` and HR-only `hr_report_note`.
- `access_active` Interview = active Application AND active Interview; `resource_blocking` thêm non-CANCELLED + interval.
- Mandatory transaction resource locks + conflict recheck for all schedule-activating mutations.
- Candidate first-login atomic provisioning/safe Auth rebind.
- Candidate/HR separate writable DTOs.
- Physical Phase-1 master data tables/FKs.
- Logical document versioning + private two-phase upload.
- Email outbox with leased worker and at-least-once/best-effort dedup semantics.
- Privacy notice acknowledgement versioning.
- RLS + explicit grants + private/security-invoker view rules.
- Root-only bound identity rebind; directory manager may only correct unbound email typo.
- Measurable NFR baseline and search/indexing strategy.
- Fail-closed consistency validation.

## 5. Design System v1.8 + Responsive Prototype v1.10
Current visual/interaction source-of-truth is the separate **EIU Recruitment Design System v1.8** ZIP. It preserves the v1.5 table/accessibility/security rules and adds explicit Candidate EDIT Privacy semantics plus measurable zoom/reflow/release evidence requirements.

Responsive Prototype v1.10 is bundled for desktop/tablet/mobile visual UAT against Design System v1.8. Responsive UI remains NOT FROZEN until owner visual UAT; Candidate Portal mobile remains a go-live requirement.

## 6. Cách đọc
### Reviewer tổng quát
1. `FINAL_REVIEW_GUIDE.md`
2. `99_INDEPENDENT_REVIEW_IMPLEMENTATION_ALIGNMENT_V1_18.md`
3. `73_DOMAIN_GLOSSARY_AND_CANONICAL_PREDICATES.md`
4. `78_PRIVACY_NOTICE_PUBLICATION_RUNBOOK.md`
5. `70_SEMANTIC_VALIDATION_GATE.md`
6. `100_TECHNICAL_PRECODE_GATE_V1_18.md`
7. `75_RELEASE_EVIDENCE_MATRIX.md`
8. `81_RESPONSIVE_PROTOTYPE_INTEGRATION.md`
8. `15_ALL_IN_ONE_SPEC.md` — generated from CURRENT normative sources only
9. Design System v1.8 ZIP

### Architect / Developer
Đọc thêm all CURRENT/NORMATIVE technical entries theo `source_registry.yaml`, cùng `database_schema.sql`, `app_spec.yaml`, `command_registry.yaml`, `validation_contract.yaml`.

## 7. Owner decisions status
`50_OWNER_DECISIONS_PENDING.md` is retained for continuity but now records **RESOLVED / DEFERRED**, not five unresolved items. Only official PDF pixel layout is deferred. Legal/privacy confirmation remains a go-live responsibility, not an unresolved HR workflow decision.

## 8. Machine-readable / starter artifacts
- `database_schema.sql` — implementation starter, not production migration bundle.
- `app_spec.yaml` — structured current spec.
- `seed_master_data.json`.
- `permissions_matrix.csv`, `status_mapping.csv`, `technical_review_matrix.csv`.
- `PACKAGE_VALIDATION.txt` — fail-closed consistency results.
- `tools/validate_package.py` — inspectable/re-runnable package validator; Design ZIP includes its own `tools/validate_design.py`.

## 9. Gate status
See `52_TECHNICAL_GATE_STATUS.md` and `100_TECHNICAL_PRECODE_GATE_V1_18.md`.

Business/Technical Specification Freeze does not mean Implementation Validation or Production Ready. Real migration/RLS/RPC/race/storage/performance/backup/deployment evidence is a post-coding gate.


## Historical review notes
Prior v1.5/v1.6 review/gate documents are retained as HISTORICAL/SUPERSEDED in `source_registry.yaml` and are not current source-of-truth.

> `LEGACY_LAYOUT_REFERENCE_ONLY_interview_report_excerpt.png` is layout inspiration only. Its field labels are legacy and must not override current report fields.




## Current review path — v1.18
Use `source_registry.yaml` as the authority. Current alignment = `99_INDEPENDENT_REVIEW_IMPLEMENTATION_ALIGNMENT_V1_18.md`; current gate = `100_TECHNICAL_PRECODE_GATE_V1_18.md`. Historical review/gate files never override current behavior. Responsive Prototype v1.10 remains the executable visual-UAT reference for Design System v1.8.

Current numbered technical/review modules extend through doc 96. `source_registry.yaml` remains the authority; do not infer current status from numeric range alone.

Current alignment resolution: `99_INDEPENDENT_REVIEW_IMPLEMENTATION_ALIGNMENT_V1_18.md`; current pre-code/implementation gate: `100_TECHNICAL_PRECODE_GATE_V1_18.md`. Independent Review v1.18 is the latest source-readiness evidence; doc 99 records its alignment.
