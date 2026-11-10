// Načítanie údajov o účte po prihlásení (roly, profil, organizácia).
//
// Hlavná cesta je jeden POST dopyt na RPC `get_my_profile` (migrácia 0010). Firemný proxy (Fortinet so SSL inšpekciou)
// zatvára niektoré GET dopyty `/rest/v1/*?select=…`, na ktorých stálo pôvodné načítanie (štyri samostatné čítania).
// Pôvodné čítania ostávajú len ako záloha pre prípad, že funkcia v databáze ešte nie je (PGRST202). Pri chybe spojenia
// sa záloha zámerne NEPOUŽIJE: zlyhala by rovnako a pridala by len ďalšiu blokovanú prevádzku; chyba ide do volajúceho
// (auth.tsx), ktorý ponechá údaje z lokálnej vyrovnávacej pamäte `me-cache:<uid>`.
import { z } from "zod";
import type { supabase } from "@/integrations/supabase/client";
import { isAppRole, isMissingFunction, type AppRole } from "./rpc-helpers";

type Client = typeof supabase;

export type MeRole = AppRole;

export interface MeData {
  roles: MeRole[];
  profile: {
    id: string;
    sap_id: string | null;
    department: string | null;
    daily_fund: number;
    organization_id: string | null;
  } | null;
  organization: { id: string; name: string; is_test?: boolean | undefined } | null;
}

export const AUTH_REQUIRED_MESSAGE = "Prihlásenie je potrebné.";
export const INVALID_ME_RESPONSE_MESSAGE = "Server vrátil neplatnú odpoveď pri načítaní účtu.";

// Tvar odpovede RPC get_my_profile. Neznáme kľúče sa ignorujú; chýbajúci alebo zlý typ známeho kľúča je chyba.
const meResponseSchema = z.object({
  roles: z.array(z.string()),
  profile: z
    .object({
      id: z.string(),
      sap_id: z.string().nullable(),
      department: z.string().nullable(),
      daily_fund: z.number(),
      organization_id: z.string().nullable(),
    })
    .nullable(),
  organization: z.object({ id: z.string(), name: z.string(), is_test: z.boolean() }).nullable(),
});

/** Overí odpoveď RPC. Neplatný tvar je chyba (nie ticho prázdne dáta); neznáma rola sa vynechá, aby novú rolu v databáze
 *  nepremenila na odmietnuté prihlásenie. */
export function parseMeResponse(value: unknown): MeData {
  const parsed = meResponseSchema.safeParse(value);
  if (!parsed.success) throw new Error(INVALID_ME_RESPONSE_MESSAGE);
  return {
    roles: parsed.data.roles.filter(isAppRole),
    profile: parsed.data.profile,
    organization: parsed.data.organization,
  };
}

// Ak funkcia v databáze chýba, zapamätáme si to len v pamäti stránky, aby sa pri každom obnovení neopakoval zbytočný dopyt.
let rpcMissing = false;

/** Len pre testy. */
export function resetMeRpcStateForTests(): void {
  rpcMissing = false;
}

// Pôvodné štyri čítania (bez zmeny správania; príznak is_test je nepovinný, ak stĺpec v databáze ešte nie je).
async function loadMeLegacy(client: Client, uid: string): Promise<MeData> {
  const [r, p] = await Promise.all([
    client.from("user_roles").select("role").eq("user_id", uid),
    client
      .from("profiles")
      .select("id, sap_id, department, daily_fund, organization_id")
      .eq("id", uid)
      .maybeSingle(),
  ]);
  if (r.error || p.error) throw r.error ?? p.error;
  const org = await client.from("organizations").select("id, name").maybeSingle();
  if (org.error) throw org.error;
  const flag = org.data ? await client.from("organizations").select("is_test").maybeSingle() : null;
  const organization = org.data
    ? { ...org.data, ...(flag && !flag.error && flag.data ? { is_test: flag.data.is_test } : {}) }
    : null;
  return { roles: (r.data ?? []).map((x) => x.role as MeRole), profile: p.data, organization };
}

/** Roly, profil a organizácia prihláseného používateľa: jedným POST dopytom (RPC get_my_profile). */
export async function loadMe(client: Client, uid: string | undefined): Promise<MeData> {
  if (!uid) throw new Error(AUTH_REQUIRED_MESSAGE);
  if (rpcMissing) return loadMeLegacy(client, uid);
  const res = await client.rpc("get_my_profile");
  if (res.error) {
    if (isMissingFunction(res.error)) {
      rpcMissing = true;
      return loadMeLegacy(client, uid);
    }
    // Chyba spojenia, certifikát, 401, 500…: bez zálohy, chybu spracuje volajúci (vyrovnávacia pamäť me-cache).
    throw res.error;
  }
  if (res.data == null) throw new Error(AUTH_REQUIRED_MESSAGE);
  return parseMeResponse(res.data);
}
