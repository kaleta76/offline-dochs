// Karta Správa: pozývací kód a zoznam zamestnancov s rolami.
//
// Hlavná cesta je jeden POST dopyt na RPC `get_admin_overview` (migrácia 0011). Firemný proxy (Fortinet so SSL inšpekciou)
// zatvára GET dopyty `/rest/v1/*?select=…`, na ktorých stálo pôvodné načítanie (organization_invites, profiles, user_roles).
// RPC je SECURITY INVOKER, takže platia rovnaké RLS politiky ako pri pôvodných čítaniach (zamestnanec dostane len seba a kód null).
// Pôvodné čítania ostávajú len ako záloha pre prípad, že funkcia v databáze ešte nie je (PGRST202). Pri chybe spojenia sa záloha
// zámerne NEPOUŽIJE: zlyhala by rovnako a pridala by len ďalšiu blokovanú prevádzku.
import { z } from "zod";
import type { supabase } from "@/integrations/supabase/client";
import { isAppRole, isMissingFunction, type AppRole } from "./rpc-helpers";

type Client = typeof supabase;

export interface AdminPerson {
  id: string;
  sap_id: string | null;
  department: string | null;
  manager_id: string | null;
  daily_fund: number;
  organization_id: string | null;
  roles: AppRole[];
}

export interface AdminOverview {
  inviteCode: string | undefined;
  people: AdminPerson[];
}

export const AUTH_REQUIRED_MESSAGE = "Prihlásenie je potrebné.";
export const INVALID_OVERVIEW_MESSAGE = "Server vrátil neplatnú odpoveď pri načítaní zoznamu zamestnancov.";

const overviewSchema = z.object({
  invite_code: z.string().nullable(),
  people: z.array(
    z.object({
      id: z.string(),
      sap_id: z.string().nullable(),
      department: z.string().nullable(),
      manager_id: z.string().nullable(),
      daily_fund: z.number(),
      organization_id: z.string().nullable(),
      roles: z.array(z.string()),
    }),
  ),
});

/** Overí odpoveď RPC. Neplatný tvar je chyba (nie ticho prázdny zoznam); neznáma rola sa vynechá. */
export function parseAdminOverview(value: unknown): AdminOverview {
  const parsed = overviewSchema.safeParse(value);
  if (!parsed.success) throw new Error(INVALID_OVERVIEW_MESSAGE);
  return {
    inviteCode: parsed.data.invite_code ?? undefined,
    people: parsed.data.people.map((p) => ({ ...p, roles: p.roles.filter(isAppRole) })),
  };
}

// Ak funkcia v databáze chýba, zapamätáme si to len v pamäti stránky, aby sa pri každom obnovení neopakoval zbytočný dopyt.
let rpcMissing = false;

/** Len pre testy. */
export function resetAdminOverviewStateForTests(): void {
  rpcMissing = false;
}

// Pôvodné tri čítania (bez zmeny správania: chyba pri čítaní pozývacieho kódu zoznam ľudí neblokuje).
async function loadAdminOverviewLegacy(client: Client): Promise<AdminOverview> {
  const [inv, p, r] = await Promise.all([
    client.from("organization_invites").select("code").maybeSingle(),
    client
      .from("profiles")
      .select("id, sap_id, department, manager_id, daily_fund, organization_id")
      .order("sap_id"),
    client.from("user_roles").select("user_id, role"),
  ]);
  if (p.error || r.error) throw p.error ?? r.error;
  return {
    inviteCode: inv.error ? undefined : (inv.data?.code ?? undefined),
    people: (p.data ?? []).map((x) => ({
      ...x,
      roles: (r.data ?? []).filter((y) => y.user_id === x.id).map((y) => y.role as AppRole),
    })),
  };
}

/** Pozývací kód a zamestnanci s rolami: jedným POST dopytom (RPC get_admin_overview). */
export async function loadAdminOverview(client: Client): Promise<AdminOverview> {
  if (rpcMissing) return loadAdminOverviewLegacy(client);
  const res = await client.rpc("get_admin_overview");
  if (res.error) {
    if (isMissingFunction(res.error)) {
      rpcMissing = true;
      return loadAdminOverviewLegacy(client);
    }
    // Chyba spojenia, certifikát, 401, 500…: bez zálohy, chybu spracuje volajúci.
    throw res.error;
  }
  if (res.data == null) throw new Error(AUTH_REQUIRED_MESSAGE);
  return parseAdminOverview(res.data);
}
