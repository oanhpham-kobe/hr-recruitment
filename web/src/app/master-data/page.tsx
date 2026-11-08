import {
  getMasterDataDependenciesAction,
  getMasterDataItemsAction,
  type MasterDataItemRecord,
} from "@/app/master-data/actions";
import { MasterDataManagementPage } from "@/components/master-data/MasterDataManagementPage";
import { getServerSession } from "@/lib/auth/session";
import "@/styles/master-data.css";

export const dynamic = "force-dynamic";

export default async function MasterDataPage() {
  const session = await getServerSession();

  const isInternal = Boolean(session.user?.isInternal);
  const roles = session.user?.roles || [];
  const permissions = session.user?.permissions || [];

  const identity = session.user
    ? {
        roles,
        permissions,
      }
    : null;

  const canManage =
    isInternal &&
    (roles.includes("ROOT_ADMIN") ||
      permissions.includes("master_data.manage"));

  let initialItems: MasterDataItemRecord[] = [];
  let initialDependencies = {
    units: [] as Array<{ unit_id: string; code: string; name_vi: string }>,
    teams: [] as Array<{
      department_team_id: string;
      unit_id: string;
      code: string;
      name_vi: string;
    }>,
    positionGroups: [] as Array<{
      position_group_id: string;
      code: string;
      name_vi: string;
    }>,
  };

  if (canManage) {
    const [itemsRes, deps] = await Promise.all([
      getMasterDataItemsAction("organizational_units", true),
      getMasterDataDependenciesAction(),
    ]);

    if (itemsRes.success) {
      initialItems = itemsRes.data;
    }
    initialDependencies = deps;
  }

  return (
    <MasterDataManagementPage
      identity={identity}
      initialCatalog="organizational_units"
      initialItems={initialItems}
      initialDependencies={initialDependencies}
    />
  );
}
