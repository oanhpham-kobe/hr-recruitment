# SIDEBAR & NAVIGATION — v1.8

## 1. Visual direction
Sidebar desktop theo hướng MedLabs mà wireframe đã được duyệt:
- nền EIU blue đậm/gradient;
- logo EIU ở đầu, dễ nhận diện;
- product title ngay dưới logo;
- menu chia nhóm rõ;
- group heading gold;
- item active nền trắng/light nổi bật;
- icon + text trắng ở trạng thái thường;
- user card cố định cuối sidebar.

## 2. Dimensions
- width: 244px;
- full viewport height;
- nav area scroll độc lập khi menu dài;
- logo/product block không bị cuộn mất nếu viewport đủ cao;
- user card ở bottom region.

## 3. Menu hierarchy
Menu chỉ render theo permission.

Suggested HR/Admin grouping:
### TỔNG QUAN
- Dashboard

### QUẢN LÝ TUYỂN DỤNG
- Phiếu ứng tuyển
- Interview
- Báo cáo phỏng vấn

### QUẢN TRỊ HỆ THỐNG
- Danh mục
- Người dùng & Phân quyền (nếu có quyền)

Không tự thêm module chưa có business scope chỉ để lấp sidebar.

## 4. Item anatomy
- min height: 44–48px;
- icon 18–20px;
- text 16px / 500–600;
- horizontal gap: 12px;
- active item: white/light background, EIU blue text/icon;
- hover: subtle white overlay;
- focus-visible: rõ, không chỉ dựa background.

## 5. Group heading
- 16px / 600–700;
- uppercase hoặc title case nhất quán;
- gold accent;
- margin top lớn hơn item gap để tạo hierarchy.

## 6. User card
- avatar/initials;
- name 16px semibold;
- active role 14px secondary;
- menu/logout affordance;
- border/surface đủ tách khỏi nav.

## 7. Collapse
Desktop v1.8 ưu tiên full sidebar. Collapse behavior sẽ được khóa trong iPad/mobile responsive phase.


## 8. Navigation scope state
A menu entry must have one explicit scope state:
- `PHASE1_RENDERED`
- `FUTURE_HIDDEN`
- `PROTOTYPE_ONLY`

Current default:
- Phiếu ứng tuyển — PHASE1_RENDERED
- Interview — PHASE1_RENDERED
- Báo cáo phỏng vấn — PHASE1_RENDERED
- Danh mục — PHASE1_RENDERED when authorized
- Người dùng & Phân quyền — PHASE1_RENDERED when authorized
- Dashboard — FUTURE_HIDDEN
- Nhu cầu tuyển dụng — FUTURE_HIDDEN
- Candidate Database — FUTURE_HIDDEN
- KPI & Reports — FUTURE_HIDDEN

Do not render disabled/empty future destinations in production Phase 1.
