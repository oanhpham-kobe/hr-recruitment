# Prototype Demo Persona Switcher

## Scope
**Prototype / local development / demo only. Never production.**

Purpose: allow owner/reviewer to exercise role-specific UI without maintaining several real accounts.

## Personas
- Root Admin
- Chuyên viên HR — Full permissions
- Chuyên viên HR — Limited permissions
- Interviewer / Giảng viên
- Candidate

## Behavior
Switching Persona must change actual prototype behavior, not just a label:
- sidebar/menu visibility;
- enabled/disabled/hidden actions;
- clickable vs read-only status badge;
- Report edit rights;
- Users/Permissions access;
- contextual Interviewer/Candidate data scope.

Example HR Limited fixture should explicitly lack at least:
- `reports.edit_interviewer`;
- `permissions.manage` / Root-only permission assignment;
- selected administrative operations.

## Placement
Desktop prototype: top-right utility region near `VI | EN`, visually marked as **Demo**.

## Production exclusion
- guard by environment flag;
- exclude from production build/render path;
- never allow query string/localStorage Persona value to grant server/database permissions;
- production Auth/RBAC remains authoritative.
