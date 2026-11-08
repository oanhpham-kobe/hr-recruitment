# TOKENS — EIU Recruitment Design System v1.8

## 1. Brand colors
| Token | Value | Usage |
|---|---|---|
| `--eiu-blue` | `#144069` | primary action, link, focus |
| `--eiu-gold` | `#A78656` | institutional accent |
| `--eiu-cream` | `#F6F1E8` | warm subtle surface |
| `--canvas` | `#F8F6F1` | page canvas |
| `--surface` | `#FFFFFF` | panel/table/drawer |
| `--ink-950` | `#303033` | main text |
| `--ink-600` | `#68686B` | secondary text |
| `--line` | `#E2D9CC` | border |

## 2. Sidebar tokens
| Token | Value |
|---|---|
| `--sidebar-bg-top` | `#0E416F` |
| `--sidebar-bg-bottom` | `#082F52` |
| `--sidebar-text` | `#F7FAFC` |
| `--sidebar-muted` | `#D9E4EE` |
| `--sidebar-heading` | `#E6C88F` |
| `--sidebar-active-bg` | `#FFFFFF` |
| `--sidebar-active-text` | `#144069` |
| `--sidebar-border` | `rgba(255,255,255,.14)` |

Sidebar background: `linear-gradient(180deg, var(--sidebar-bg-top), var(--sidebar-bg-bottom))`.

## 3. Semantic colors
All normal-size status text targets **WCAG 2.2 AA ≥4.5:1** against its badge background. Semantic colors must be regression-tested in CI/design QA; do not lighten foreground below target just for aesthetics.
- Success: `#3B6A2A`; soft `#EAF3E6`
- Warning: `#8A4F00`; soft `#FFF0DE`
- Danger: `#B44425`; soft `#F8E5E0`
- Info/Blue: `#144069`; soft `#E5EDF5`
- Neutral: `#68686B`; soft `#EEF0F1`
- Follow-up/Purple: `#4B479D`; soft `#ECEBFA`

### Interview schedule
| Status | Text | BG |
|---|---|---|
| AVAILABLE / Sẵn sàng | Danger | Danger-soft |
| SCHEDULED / Đã xếp lịch | Info | Info-soft |
| AWAITING / Chờ xác nhận | Warning | Warning-soft |
| CONFIRMED / Đã xác nhận | Success | Success-soft |
| CANCELLED / Hủy | Neutral | Neutral-soft |

## 4. Typography
Font stack: `"Be Vietnam Pro", "Segoe UI", system-ui, sans-serif`

| Role | Size | Weight | Line-height |
|---|---:|---:|---:|
| Page title | 28–32px | 700–800 | 1.2 |
| Drawer title | 22–24px | 700 | 1.25 |
| Section title | 18–20px | 700 | 1.35 |
| Table header | **16px** | **600** | 1.45 |
| Table cell | **16px** | 400–500 | 1.5 |
| Body/value | **16px** | 400 | 1.5 |
| Label | **16px** | 600 | 1.4 |
| Control/button | **16px** | 500–600 | 1.35 |
| Status badge | **16px** | **600** | 1.25 |
| Helper/meta only | 14px | 400–500 | 1.45 |

## 5. Badge sizing
Badge width không global; dùng theo status group.

Initial implementation targets (có thể tinh chỉnh sau khi final translation strings được khóa):
- `--badge-width-submission`: `112px`
- `--badge-width-interview`: `112px`
- `--badge-width-candidate`: `128px`
- `--badge-width-report`: `168px`

Rules:
- `min-height: 32px`;
- padding ngang 10–12px;
- text-align center;
- không truncate status label;
- cùng group → cùng width.

## 6. Spacing
Scale: `4, 8, 12, 16, 20, 24, 32, 40, 48, 64`.
- component gap: 8px
- field gap: 12px
- section gap: 24px
- table cell padding: 14–16px vertical / 16px horizontal
- drawer body: 24–28px

## 7. Radius
- control: 10px
- card/table: 15px
- overlay: 16–20px
- badge: 8–10px; không bắt buộc pill 999px

## 8. Control heights
Với font 16px:
- standard button/input/select: **42–44px**
- compact icon control: 40px
- large login CTA: 50–52px

## 9. Layout
- sidebar: 244px
- header: 72–76px
- action toolbar: ≥56px
- drawer desktop: preferred 820px; actual width = `min(820px, available-content-width)` with safe viewport gutters. Do not combine a 760px minimum with a smaller `55vw` cap. At narrower widths use the responsive sheet rules.
- standard modal: 600–760px
- email preview: 720–840px

## 10. Shadows
- surface: subtle only
- drawer/modal/login: medium
- không shadow mọi control


## Current brand accessibility restriction — v1.8
`--eiu-gold: #A78656` remains the institutional accent. On white/cream light surfaces it is **not** approved for normal 14–16px body text. Use it for decorative accents, icons/borders where contrast is not the sole information carrier, or sufficiently large text after contrast verification. Sidebar gold-on-dark usage must be contrast-tested separately.

## UniCouncil visual trial — 2026-11-05

`CR-UNICOUNCIL-UI-ADAPTATION-20261105`, defined in MASTER.md, permits scoped list/table/card, navigation, filter, pager and badge UI at14px/21px. Identity names remain16px/24px semibold; generic body, Candidate forms, dialog/drawer fields and report narratives remain16px. Mobile inputs/selects remain16px. Base tokens retain16px; scoped styles declare the14px exception explicitly. Header height is64px; controls retain44px targets and the existing semantic contrast/badge widths. This is an Owner-authorized trial pending visual UAT.
