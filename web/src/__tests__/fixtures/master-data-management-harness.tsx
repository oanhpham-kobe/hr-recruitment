import { createRoot } from "react-dom/client";
import "@/app/globals.css";
import type { MasterDataItemRecord } from "@/app/master-data/actions";
import { MasterDataManagementPage } from "@/components/master-data/MasterDataManagementPage";
import { AppShell } from "@/components/shell/AppShell";
import { resolveInternalNavItems } from "@/components/shell/navigation";
import "@/styles/master-data.css";

declare global {
  interface Window {
    __HARNESS_PROPS__?: {
      identity?: {
        roles: string[];
        permissions: string[];
      };
      items?: MasterDataItemRecord[];
      dependencies?: {
        units: Array<{ unit_id: string; code: string; name_vi: string }>;
        teams: Array<{
          department_team_id: string;
          unit_id: string;
          code: string;
          name_vi: string;
        }>;
        positionGroups: Array<{
          position_group_id: string;
          code: string;
          name_vi: string;
        }>;
      };
    };
  }
}

const container = document.getElementById("root");
if (container) {
  const props = window.__HARNESS_PROPS__ || {};
  const identity = props.identity ?? {
    roles: ["HR"],
    permissions: ["master_data.manage"],
  };
  const root = createRoot(container);
  root.render(
    <AppShell
      currentPath="/master-data"
      navItems={resolveInternalNavItems(identity)}
    >
      <MasterDataManagementPage
        identity={identity}
        initialCatalog="organizational_units"
        initialItems={
          props.items ?? [
            {
              id: "u-001",
              code: "CNTT",
              nameVi: "Khoa Công nghệ thông tin",
              nameEn: "Faculty of Information Technology",
              isActive: true,
              versionNo: 1,
            },
            {
              id: "u-002",
              code: "QTKD",
              nameVi: "Khoa Quản trị kinh doanh",
              nameEn: "Faculty of Business Administration",
              isActive: false,
              versionNo: 2,
            },
          ]
        }
        initialDependencies={
          props.dependencies ?? {
            units: [
              {
                unit_id: "u-001",
                code: "CNTT",
                name_vi: "Khoa Công nghệ thông tin",
              },
            ],
            teams: [
              {
                department_team_id: "t-001",
                unit_id: "u-001",
                code: "KHMT",
                name_vi: "Khoa học máy tính",
              },
            ],
            positionGroups: [
              {
                position_group_id: "g-001",
                code: "GIANG_VIEN",
                name_vi: "Giảng viên",
              },
            ],
          }
        }
      />
    </AppShell>,
  );
}
