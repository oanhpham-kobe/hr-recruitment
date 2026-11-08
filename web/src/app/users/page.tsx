import {
  getUserManagementDependenciesAction,
  type InternalUserDirectoryRecord,
  listInternalUsersAction,
} from "@/app/users/actions";
import { UsersManagementPage } from "@/components/users/UsersManagementPage";
import { getServerSession } from "@/lib/auth/session";
import "@/styles/users.css";

export const dynamic = "force-dynamic";

export default async function UsersPage() {
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

  const canView =
    isInternal &&
    (roles.includes("ROOT_ADMIN") ||
      permissions.includes("users.directory_read") ||
      permissions.includes("users.directory_manage") ||
      permissions.includes("users.permissions_manage"));

  let initialUsers: InternalUserDirectoryRecord[] = [];
  let initialDependencies = {
    units: [] as Array<{ unit_id: string; code: string; name_vi: string }>,
  };

  if (canView) {
    const [usersRes, deps] = await Promise.all([
      listInternalUsersAction(true),
      getUserManagementDependenciesAction(),
    ]);

    if (usersRes.success) {
      initialUsers = usersRes.data;
    }
    initialDependencies = deps;
  }

  return (
    <UsersManagementPage
      identity={identity}
      initialUsers={initialUsers}
      initialDependencies={initialDependencies}
    />
  );
}
