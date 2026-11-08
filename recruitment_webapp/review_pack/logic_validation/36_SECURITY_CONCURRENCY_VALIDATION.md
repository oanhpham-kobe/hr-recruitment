# 36. Security & Concurrency Validation

## 1. Root Admin uniqueness
**PASS_SPEC**
- Partial unique DB constraint bảo đảm tối đa 1 root.
- Root không Delete/Inactive.
- Permission assignment Root-only.

## 2. HR granular permission
**PASS_SPEC**
- HR role chỉ đánh dấu loại user/HR owner eligibility.
- Mỗi action nhạy cảm check permission code.
- Sidebar/action visibility theo permission, nhưng RLS/backend vẫn là lớp quyết định.

## 3. Interviewer contextual access
**PASS_SPEC**
- Chỉ current participant + visible + active session + active user.
- Không thấy HR note/final-source metadata.
- Không sửa report người khác.

## 4. Candidate isolation
**PASS_SPEC**
- auth.uid map candidate.
- email immutable.
- inactive blocks Portal.
- update chỉ khi status NEW và version còn hợp lệ.

## 5. Duplicate Application race
**TECH_GUARD REQUIRED**
- Cần DB unique index cho identity, xử lý NULL Ngành/Tổ.
- Warning UI không đủ nếu 2 HR submit cùng lúc.

## 6. Round number race
**TECH_GUARD REQUIRED**
- Transaction lock Application khi allocate round_no.
- unique(application_id, round_no).

## 7. Schedule conflict race
**TECH_GUARD REQUIRED**
- Mandatory transaction-level advisory/resource locks theo Candidate/Room/Interviewer, deterministic order.
- Sau khi lock phải re-check overlap trước commit.
- Frontend check chỉ là UX.

## 8. HR vs HR edit
**PASS_SPEC / TECH optimistic lock**
- stale version → block/reload.

## 9. HR vs Interviewer report
**PASS_SPEC**
- HR stale after Interviewer update → block HR + reload.
- HR vs Interviewer trên cùng report dùng field-aware patch/merge: khác field thì giữ cả hai thay đổi; cùng field thì Interviewer wins.
- Không cho stale whole-row overwrite.
- Same Interviewer multiple tabs → stale block.

## 10. Internal User email update
**TECH_GUARD REQUIRED**
- Unbound user email typo có thể sửa bởi Directory Manager.
- Bound Auth identity rebinding là Root-only Phase 1; Root identity dùng recovery procedure.
- unique normalized email + historical snapshots.

## 11. RLS conclusion
Không phát hiện permission leak theo logic hiện tại nếu RLS được triển khai đúng.  
Không chấp nhận “ẩn nút ở frontend” thay cho backend enforcement.
