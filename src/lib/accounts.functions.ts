import { createServerFn } from "@tanstack/react-start";
import { createClient } from "@supabase/supabase-js";
import type { User } from "@supabase/supabase-js";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import {
  enrollCore,
  fail,
  loginCore,
  provisionCore,
  recoverCore,
  registerCore,
  type AccountsPort,
  type CoreUser,
  type Meta,
} from "./accounts-core";
import { formatCode, orgCodeOf } from "./credentials";
import {
  enrollSchema,
  loginSchema,
  provisionSchema,
  recoverSchema,
  registerSchema,
} from "./onboarding-rules";
import { REGISTRATION_CODE_SHA256 } from "./registration-code";

// Registrácia firiem a zamestnancov bez e-mailu (docs/REGISTRACIA.md). Logika je v accounts-core.ts,
// tu je len napojenie na Supabase a overenie vstupov.

function publicClient() {
  const url = process.env["SUPABASE_URL"];
  const key = process.env["SUPABASE_PUBLISHABLE_KEY"];
  if (!url || !key) throw new Error("Služba nie je dostupná.");
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

async function makePort(): Promise<AccountsPort> {
  const { supabaseAdmin: admin } = await import("@/integrations/supabase/client.server");
  const toUser = (u: User): CoreUser => ({
    id: u.id,
    email: u.email ?? null,
    meta: { ...(u.app_metadata as Meta) },
  });
  return {
    async organizationsInRange(lo, hi) {
      const { data } = await admin
        .from("organizations")
        .select("id")
        .gte("id", lo)
        .lte("id", hi)
        .limit(2);
      return (data ?? []).map((row) => row.id);
    },
    async profileId(org, number) {
      const { data } = await admin
        .from("profiles")
        .select("id")
        .eq("organization_id", org)
        .eq("sap_id", number)
        .maybeSingle();
      return data?.id ?? null;
    },
    async organizationOfUser(userId) {
      const { data } = await admin
        .from("profiles")
        .select("organization_id")
        .eq("id", userId)
        .maybeSingle();
      return data?.organization_id ?? null;
    },
    async isAdmin(userId) {
      const { data } = await admin
        .from("user_roles")
        .select("role")
        .eq("user_id", userId)
        .eq("role", "admin")
        .maybeSingle();
      return Boolean(data);
    },
    async getUser(id) {
      const { data } = await admin.auth.admin.getUserById(id);
      return data.user ? toUser(data.user) : null;
    },
    async createUser(attrs) {
      const { data, error } = await admin.auth.admin.createUser(attrs);
      return error || !data.user ? null : { id: data.user.id };
    },
    async updateUser(id, attrs) {
      const { error } = await admin.auth.admin.updateUserById(id, attrs);
      return !error;
    },
    async deleteUser(id) {
      await admin.auth.admin.deleteUser(id);
    },
    async signIn(email, password) {
      const { data, error } = await publicClient().auth.signInWithPassword({ email, password });
      return error || !data.session
        ? null
        : { access_token: data.session.access_token, refresh_token: data.session.refresh_token };
    },
    async signOutAll(accessToken) {
      const { error } = await admin.auth.admin.signOut(accessToken, "global");
      return !error;
    },
    async audit(actor, action, target, details) {
      const { error } = await admin
        .from("audit_log")
        .insert({ actor, action, target, ...(details ? { details } : {}) });
      return !error;
    },
  };
}

// Verejné funkcie (bez prihlásenia). Chránia ich kód, PIN, heslo a zámky po omyloch.

/** Registrácia novej organizácie a jej prvého správcu. Chránená stálym registračným kódom. */
export const registerOrganization = createServerFn({ method: "POST" })
  .inputValidator((v: unknown) => registerSchema.parse(v))
  .handler(async ({ data }) => registerCore(await makePort(), data, REGISTRATION_CODE_SHA256));

/** Prihlásenie kódom organizácie, osobným číslom a heslom. */
export const employeeLogin = createServerFn({ method: "POST" })
  .inputValidator((v: unknown) => loginSchema.parse(v))
  .handler(async ({ data }) => loginCore(await makePort(), data, Date.now()));

/** Prvé prihlásenie zamestnanca: PIN od správcu a vlastné heslo. */
export const enrollEmployee = createServerFn({ method: "POST" })
  .inputValidator((v: unknown) => enrollSchema.parse(v))
  .handler(async ({ data }) => enrollCore(await makePort(), data, Date.now()));

/** Obnova hesla správcu obnovovacím kódom z registrácie. */
export const recoverAdmin = createServerFn({ method: "POST" })
  .inputValidator((v: unknown) => recoverSchema.parse(v))
  .handler(async ({ data }) => recoverCore(await makePort(), data, Date.now()));

/** Funkcia pre správcu organizácie: vydá účty a jednorazové PIN-y pre zadané osobné čísla. */
export const provisionEmployees = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((v: unknown) => provisionSchema.parse(v))
  .handler(async ({ data, context }) => {
    const { data: allowed, error: roleError } = await context.supabase.rpc("has_role", {
      _user_id: context.userId,
      _role: "admin",
    });
    if (roleError || !allowed) return fail("Iba správca môže pridávať zamestnancov.");
    const { data: org, error: orgError } = await context.supabase.rpc("my_organization");
    if (orgError || !org) return fail("Organizácia nie je dostupná.");
    const { data: invite } = await context.supabase
      .from("organization_invites")
      .select("code")
      .eq("organization_id", org)
      .single();
    if (!invite) return fail("Interné pozvanie organizácie nie je dostupné.");

    const rows = await provisionCore(
      await makePort(),
      { adminUserId: context.userId, org, inviteCode: invite.code },
      data,
      Date.now(),
    );
    return { ok: true as const, rows, organizationCode: formatCode(orgCodeOf(org)) };
  });
