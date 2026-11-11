// Dopyty testu spojenia (karta Servis v Správe a stránka /diagnostika pre každého prihláseného). Sú to tie isté tvary dopytov, ktoré aplikácia posiela (a na ktoré firemný proxy
// v minulosti zatváral spojenie), spustené cez skutočného klienta databázy. Nič nemenia a výsledok sa nezobrazuje:
// ukladá sa len stav, čas a počet riadkov, nie obsah (osobné čísla, pozývací kód).
import { supabase } from "@/integrations/supabase/client";
import type { ProbeDef, ProbeResponse } from "./net-log";

interface PgResult {
  error: { message: string; code?: string | undefined } | null;
  status: number;
  data?: unknown;
}

interface AuthResult {
  error: { message: string; status?: number | undefined; code?: string | undefined } | null;
}

/** Odpoveď klienta databázy: len stav, kód chyby a počet riadkov. */
function fromPostgrest(res: PgResult): ProbeResponse {
  const note = !res.error && Array.isArray(res.data) ? `riadkov: ${res.data.length}` : undefined;
  return {
    status: res.status,
    code: res.error?.code ?? null,
    message: res.error?.message ?? null,
    // klient databázy hlási zlyhanie spojenia ako stav 0
    thrown: res.status === 0,
    ...(note ? { note } : {}),
  };
}

function fromAuth(res: AuthResult): ProbeResponse {
  if (!res.error) return { status: 200 };
  const status = res.error.status ?? 0;
  return { status, code: res.error.code ?? null, message: res.error.message, thrown: status === 0 };
}

const two = (n: number) => String(n).padStart(2, "0");
const ymd = (d: Date) => `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())}`;

/**
 * Dopyty testu; `userId` a mesiac určujú rovnaký tvar dopytu na razenia ako pri načítaní mesiaca.
 * Dopyty, ktoré smie robiť len správca (zoznam zamestnancov, pozývací kód), sa pre ostatných nezaradia: zamestnanec by inak videl
 * zlyhanie, ktoré nie je chyba spojenia.
 */
export function buildProbes(userId: string, today: Date, opts: { admin?: boolean } = {}): ProbeDef[] {
  const admin = opts.admin ?? true;
  const from = new Date(today.getFullYear(), today.getMonth(), 1);
  const to = new Date(today.getFullYear(), today.getMonth() + 1, 1);
  const all: (ProbeDef & { adminOnly?: boolean })[] = [
    {
      id: "auth-user",
      label: "Overenie prihlásenia",
      method: "GET",
      request: "/auth/v1/user",
      run: async () => fromAuth(await supabase.auth.getUser()),
    },
    {
      id: "rpc-my-profile",
      label: "Účet po prihlásení (RPC)",
      method: "POST",
      request: "/rest/v1/rpc/get_my_profile",
      run: async () => fromPostgrest(await supabase.rpc("get_my_profile")),
    },
    {
      id: "rpc-admin-overview",
      adminOnly: true,
      label: "Správa: zoznam zamestnancov (RPC)",
      method: "POST",
      request: "/rest/v1/rpc/get_admin_overview",
      run: async () => fromPostgrest(await supabase.rpc("get_admin_overview")),
    },
    {
      id: "rpc-calc-settings",
      label: "Pravidlá výpočtu (RPC)",
      method: "POST",
      request: "/rest/v1/rpc/calc_settings",
      run: async () => fromPostgrest(await supabase.rpc("calc_settings")),
    },
    {
      id: "get-user-roles",
      label: "Roly (staré čítanie)",
      method: "GET",
      request: "/rest/v1/user_roles?select=user_id,role",
      run: async () => fromPostgrest(await supabase.from("user_roles").select("user_id, role")),
    },
    {
      id: "get-profiles",
      label: "Zamestnanci (staré čítanie)",
      method: "GET",
      request: "/rest/v1/profiles?select=id,sap_id,department,manager_id,daily_fund,organization_id&order=sap_id",
      run: async () =>
        fromPostgrest(
          await supabase.from("profiles").select("id, sap_id, department, manager_id, daily_fund, organization_id").order("sap_id"),
        ),
    },
    {
      id: "get-invites",
      adminOnly: true,
      label: "Pozývací kód (staré čítanie)",
      method: "GET",
      request: "/rest/v1/organization_invites?select=code",
      // obsah (kód) sa nikde nezobrazuje ani neukladá
      run: async () => fromPostgrest(await supabase.from("organization_invites").select("code").maybeSingle()),
    },
    {
      id: "get-holidays",
      label: "Sviatky mesiaca",
      method: "GET",
      request: "/rest/v1/organization_holidays?select=day,name&day=gte.*&day=lt.*",
      run: async () =>
        fromPostgrest(await supabase.from("organization_holidays").select("day, name").gte("day", ymd(from)).lt("day", ymd(to))),
    },
    {
      id: "get-punches",
      label: "Vlastné razenia mesiaca",
      method: "GET",
      request: "/rest/v1/punches?select=id,code,direction,client_time,…&user_id=eq.*&client_time=gte.*&client_time=lt.*&order=client_time",
      run: async () =>
        fromPostgrest(
          await supabase
            .from("punches")
            .select("id, code, direction, client_time, drift_minutes, source, voided_at, device_verification")
            .eq("user_id", userId)
            .gte("client_time", from.toISOString())
            .lt("client_time", to.toISOString())
            .order("client_time"),
        ),
    },
  ];
  return all.filter((p) => admin || !p.adminOnly).map(({ adminOnly: _adminOnly, ...probe }) => probe);
}
