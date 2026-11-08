import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { createServerClient } from "@/lib/supabase/server";

export interface AppUserSession {
  authUserId: string;
  email: string;
  isInternal: boolean;
  isCandidate: boolean;
  appUserId?: string;
  candidateId?: string;
  roles: string[];
  permissions: string[];
}

export interface AppSession {
  user: AppUserSession | null;
  isAuthenticated: boolean;
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];
}

type InternalSessionRpcData = {
  appUserId: string;
  isActive: boolean;
  isRootAdmin: boolean;
  roles: string[];
  permissions: string[];
};

function parseInternalSessionRpc(
  payload: unknown,
): InternalSessionRpcData | null {
  if (
    !payload ||
    typeof payload !== "object" ||
    !("success" in payload) ||
    payload.success !== true ||
    !("data" in payload) ||
    !payload.data ||
    typeof payload.data !== "object"
  ) {
    return null;
  }

  const data = payload.data;
  if (
    !("app_user_id" in data) ||
    typeof data.app_user_id !== "string" ||
    !("is_active" in data) ||
    data.is_active !== true
  ) {
    return null;
  }

  return {
    appUserId: data.app_user_id,
    isActive: true,
    isRootAdmin: "is_root_admin" in data && data.is_root_admin === true,
    roles: "roles" in data ? stringArray(data.roles) : [],
    permissions: "permissions" in data ? stringArray(data.permissions) : [],
  };
}

export type CurrentInternalBindingStatus = {
  bound: boolean;
  appUserId?: string;
  isActive: boolean;
  isRootAdmin: boolean;
};

export async function getCurrentInternalBindingStatus(
  client: SupabaseClient,
): Promise<CurrentInternalBindingStatus | null> {
  const { data, error } = await client.rpc(
    "get_current_internal_binding_status",
  );
  if (
    error ||
    !data ||
    typeof data !== "object" ||
    !("success" in data) ||
    data.success !== true ||
    !("data" in data) ||
    !data.data ||
    typeof data.data !== "object"
  ) {
    return null;
  }

  const payload = data.data;
  if (
    !("bound" in payload) ||
    typeof payload.bound !== "boolean" ||
    !("is_active" in payload) ||
    typeof payload.is_active !== "boolean" ||
    !("is_root_admin" in payload) ||
    typeof payload.is_root_admin !== "boolean"
  ) {
    return null;
  }

  const appUserId =
    "app_user_id" in payload && typeof payload.app_user_id === "string"
      ? payload.app_user_id
      : undefined;

  return {
    bound: payload.bound,
    appUserId,
    isActive: payload.is_active,
    isRootAdmin: payload.is_root_admin,
  };
}

function internalSessionFromData(
  authUserId: string,
  email: string,
  data: InternalSessionRpcData,
): AppSession {
  const roles = [...data.roles];
  if (data.isRootAdmin && !roles.includes("ROOT_ADMIN")) {
    roles.push("ROOT_ADMIN");
  }

  return {
    isAuthenticated: true,
    user: {
      authUserId,
      email,
      isInternal: true,
      isCandidate: false,
      appUserId: data.appUserId,
      roles,
      permissions: data.permissions,
    },
  };
}

export async function getServerSession(
  client?: SupabaseClient,
): Promise<AppSession> {
  const supabase = client ?? (await createServerClient());
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser();

  if (error || !user || !user.email) {
    return { user: null, isAuthenticated: false };
  }

  const isInternal = user.email.toLowerCase().endsWith("@eiu.edu.vn");

  if (isInternal) {
    const { data: internalPayload, error: internalError } = await supabase.rpc(
      "get_current_internal_session",
    );
    const internalData = parseInternalSessionRpc(internalPayload);
    if (!internalError && internalData) {
      return internalSessionFromData(user.id, user.email, internalData);
    }

    // S06-002 intentionally fails closed here. Raw app_users.auth_user_id is
    // no longer a request-scoped Data API surface; trusted server consumers
    // must use the dedicated current-session/current-binding RPCs.
    return { user: null, isAuthenticated: false };
  }

  const { data: candidate } = await supabase
    .from("candidates")
    .select("candidate_id, is_active")
    .eq("auth_user_id", user.id)
    .single();

  if (
    !candidate ||
    typeof candidate !== "object" ||
    !("is_active" in candidate) ||
    !candidate.is_active ||
    !("candidate_id" in candidate) ||
    typeof candidate.candidate_id !== "string"
  ) {
    return { user: null, isAuthenticated: false };
  }

  return {
    isAuthenticated: true,
    user: {
      authUserId: user.id,
      email: user.email,
      isInternal: false,
      isCandidate: true,
      candidateId: candidate.candidate_id,
      roles: ["CANDIDATE"],
      permissions: ["candidate.self"],
    },
  };
}
