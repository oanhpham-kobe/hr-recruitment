import { createRoot } from "react-dom/client";
import "@/app/globals.css";
import type { InternalUserDirectoryRecord } from "@/app/users/actions";
import { AppShell } from "@/components/shell/AppShell";
import { resolveInternalNavItems } from "@/components/shell/navigation";
import { UsersManagementPage } from "@/components/users/UsersManagementPage";
import "@/styles/users.css";

declare global {
  interface Window {
    __USERS_HARNESS_PROPS__?: {
      identity?: {
        roles: string[];
        permissions: string[];
      };
      users?: InternalUserDirectoryRecord[];
      dependencies?: {
        units: Array<{ unit_id: string; code: string; name_vi: string }>;
      };
    };
  }
}

const container = document.getElementById("root");
if (container) {
  const props = window.__USERS_HARNESS_PROPS__ || {};
  const identity = props.identity ?? {
    roles: ["ROOT_ADMIN"],
    permissions: [],
  };
  const root = createRoot(container);
  root.render(
    <AppShell currentPath="/users" navItems={resolveInternalNavItems(identity)}>
      <UsersManagementPage
        identity={identity}
        initialUsers={
          props.users ?? [
            {
              appUserId: "user-root-001",
              email: "root@eiu.edu.vn",
              fullName: "Root Administrator",
              jobTitle: "System Owner",
              unitId: null,
              isActive: true,
              isRootAdmin: true,
              isHr: true,
              identityBound: true,
              versionNo: 1,
            },
            {
              appUserId: "user-hr-001",
              email: "hr.manager@eiu.edu.vn",
              fullName: "Lê Thị Nhân Sự",
              jobTitle: "HR Lead",
              unitId: "unit-001",
              isActive: true,
              isRootAdmin: false,
              isHr: true,
              identityBound: true,
              versionNo: 2,
            },
            {
              appUserId: "user-staff-001",
              email: "staff.lecturer@eiu.edu.vn",
              fullName: "Trần Giảng Viên",
              jobTitle: "Lecturer",
              unitId: "unit-001",
              isActive: false,
              isRootAdmin: false,
              isHr: false,
              identityBound: false,
              versionNo: 1,
            },
          ]
        }
        initialDependencies={
          props.dependencies ?? {
            units: [
              {
                unit_id: "unit-001",
                code: "CNTT",
                name_vi: "Khoa Công nghệ thông tin",
              },
            ],
          }
        }
      />
    </AppShell>,
  );
}
