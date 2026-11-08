import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import { resolveInternalNavItems } from "@/components/shell/navigation";
import {
  createAssignHrRoleCommand,
  createCreateInternalUserCommand,
  createGrantHrPermissionCommand,
  createRevokeHrPermissionCommand,
  createRevokeHrRoleCommand,
  createSetInternalUserActiveCommand,
  createUpdateInternalUserDirectoryCommand,
} from "@/lib/commands/internal-users";
import { CommandErrorCode } from "@/lib/commands/types";

test("createInternalUser command authorizes users.directory_manage or ROOT_ADMIN and validates EIU email", async () => {
  const mockSupabase = {} as SupabaseClient;
  const cmd = createCreateInternalUserCommand(mockSupabase);

  // Unauthorized actor (interviewer without directory permissions)
  const deniedAuth = await cmd.authorize({
    authUserId: "user-1",
    email: "interviewer@eiu.edu.vn",
    isActive: true,
    roles: ["INTERVIEWER"],
    permissions: ["interviews.view"],
  });
  assert.equal(deniedAuth.authorized, false);
  if (!deniedAuth.authorized) {
    assert.equal(deniedAuth.code, CommandErrorCode.FORBIDDEN);
  }

  // Authorized HR with users.directory_manage
  const hrAuth = await cmd.authorize({
    authUserId: "user-2",
    email: "hr@eiu.edu.vn",
    isActive: true,
    roles: ["HR"],
    permissions: ["users.directory_manage"],
  });
  assert.equal(hrAuth.authorized, true);

  // Authorized ROOT_ADMIN
  const rootAuth = await cmd.authorize({
    authUserId: "user-root",
    email: "root@eiu.edu.vn",
    isActive: true,
    roles: ["ROOT_ADMIN"],
    permissions: [],
  });
  assert.equal(rootAuth.authorized, true);

  // Validation: non-EIU email
  assert.equal(
    cmd.validate({
      email: "attacker@gmail.com",
      fullName: "Attacker",
    }).success,
    false,
  );

  // Validation: empty full name
  assert.equal(
    cmd.validate({
      email: "valid.user@eiu.edu.vn",
      fullName: "   ",
    }).success,
    false,
  );

  // Validation: valid input
  assert.equal(
    cmd.validate({
      email: "valid.user@eiu.edu.vn",
      fullName: "Nguyễn Văn A",
    }).success,
    true,
  );
});

test("updateInternalUserDirectory command validates inputs and authorizes directory managers", async () => {
  const mockSupabase = {} as SupabaseClient;
  const cmd = createUpdateInternalUserDirectoryCommand(mockSupabase);

  // Denied without directory permission
  assert.equal(
    (
      await cmd.authorize({
        authUserId: "u1",
        email: "staff@eiu.edu.vn",
        isActive: true,
        roles: ["STAFF"],
        permissions: ["submissions.view"],
      })
    ).authorized,
    false,
  );

  // Authorized with users.directory_manage
  assert.equal(
    (
      await cmd.authorize({
        authUserId: "u2",
        email: "hr@eiu.edu.vn",
        isActive: true,
        roles: ["HR"],
        permissions: ["users.directory_manage"],
      })
    ).authorized,
    true,
  );

  // Invalid target UUID
  assert.equal(
    cmd.validate({
      targetUserId: "not-a-uuid",
      expectedVersionNo: 1,
    }).success,
    false,
  );

  // Invalid expectedVersionNo
  assert.equal(
    cmd.validate({
      targetUserId: "00000000-0000-0000-0000-000000000001",
      expectedVersionNo: 0,
    }).success,
    false,
  );

  // Valid
  assert.equal(
    cmd.validate({
      targetUserId: "00000000-0000-0000-0000-000000000001",
      expectedVersionNo: 1,
      fullName: "Tên Đã Đổi",
    }).success,
    true,
  );
});

test("setInternalUserActive command validates version and authorizes directory managers", async () => {
  const mockSupabase = {} as SupabaseClient;
  const cmd = createSetInternalUserActiveCommand(mockSupabase);

  // Authorized
  assert.equal(
    (
      await cmd.authorize({
        authUserId: "u1",
        email: "hr@eiu.edu.vn",
        isActive: true,
        roles: ["HR"],
        permissions: ["users.directory_manage"],
      })
    ).authorized,
    true,
  );

  // Valid input
  assert.equal(
    cmd.validate({
      targetUserId: "00000000-0000-0000-0000-000000000001",
      active: false,
      expectedVersionNo: 2,
    }).success,
    true,
  );
});

test("assignHrRoleWithDefaults and revokeHrRole require ROOT_ADMIN strictly", async () => {
  const mockSupabase = {} as SupabaseClient;
  const assignCmd = createAssignHrRoleCommand(mockSupabase);
  const revokeCmd = createRevokeHrRoleCommand(mockSupabase);

  // HR directory manager cannot assign or revoke HR role
  const hrActor = {
    authUserId: "hr-id",
    email: "hr@eiu.edu.vn",
    isActive: true,
    roles: ["HR"],
    permissions: ["users.directory_manage", "users.directory_read"],
  };
  assert.equal((await assignCmd.authorize(hrActor)).authorized, false);
  assert.equal((await revokeCmd.authorize(hrActor)).authorized, false);

  // Root Admin can assign and revoke HR role
  const rootActor = {
    authUserId: "root-id",
    email: "root@eiu.edu.vn",
    isActive: true,
    roles: ["ROOT_ADMIN"],
    permissions: [],
  };
  assert.equal((await assignCmd.authorize(rootActor)).authorized, true);
  assert.equal((await revokeCmd.authorize(rootActor)).authorized, true);
});

test("grantHrPermission and revokeHrPermission require ROOT_ADMIN strictly", async () => {
  const mockSupabase = {} as SupabaseClient;
  const grantCmd = createGrantHrPermissionCommand(mockSupabase);
  const revokeCmd = createRevokeHrPermissionCommand(mockSupabase);

  // Non-root denied
  const nonRoot = {
    authUserId: "u1",
    email: "user@eiu.edu.vn",
    isActive: true,
    roles: ["HR"],
    permissions: ["users.directory_manage"],
  };
  assert.equal((await grantCmd.authorize(nonRoot)).authorized, false);
  assert.equal((await revokeCmd.authorize(nonRoot)).authorized, false);

  // Root authorized
  const root = {
    authUserId: "root-id",
    email: "root@eiu.edu.vn",
    isActive: true,
    roles: ["ROOT_ADMIN"],
    permissions: [],
  };
  assert.equal((await grantCmd.authorize(root)).authorized, true);
  assert.equal((await revokeCmd.authorize(root)).authorized, true);

  // Validate empty permission code
  assert.equal(
    grantCmd.validate({
      targetUserId: "00000000-0000-0000-0000-000000000001",
      permissionCode: "   ",
      expectedVersionNo: 1,
    }).success,
    false,
  );
});

test("resolveInternalNavItems exposes /users to ROOT_ADMIN and users with directory permissions", () => {
  // Interviewer only -> no /users
  assert.ok(
    !resolveInternalNavItems({ roles: ["INTERVIEWER"], permissions: [] })
      .map((i) => i.href)
      .includes("/users"),
  );

  // HR with only submissions.view -> no /users
  assert.ok(
    !resolveInternalNavItems({
      roles: ["HR"],
      permissions: ["submissions.view"],
    })
      .map((i) => i.href)
      .includes("/users"),
  );

  // HR with users.directory_read -> has /users
  assert.ok(
    resolveInternalNavItems({
      roles: ["HR"],
      permissions: ["users.directory_read"],
    })
      .map((i) => i.href)
      .includes("/users"),
  );

  // HR with users.directory_manage -> has /users
  assert.ok(
    resolveInternalNavItems({
      roles: ["HR"],
      permissions: ["users.directory_manage"],
    })
      .map((i) => i.href)
      .includes("/users"),
  );

  // ROOT_ADMIN -> has /users
  assert.ok(
    resolveInternalNavItems({ roles: ["ROOT_ADMIN"], permissions: [] })
      .map((i) => i.href)
      .includes("/users"),
  );
});
