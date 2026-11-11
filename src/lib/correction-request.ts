// Žiadosť o opravu (Môj mesiac): RPC `request_correction` (migrácia 0013) s kľúčom zariadenia zamestnanca.
//
// Server porovná kľúč s aktívnym alebo záložným zariadením zamestnanca (kľúč neukladá). Ak vedúci zamestnancovi zapol automatické
// schvaľovanie a žiadosť spĺňa limity, schváli sa sama a vznikne z nej razenie; inak čaká na vedúceho ako doteraz.
// Klient nikdy nenastavuje `device_verified` ani `auto_approved`: o tom rozhoduje len databáza.
//
// Pôvodný priamy zápis do `corrections` ostáva len ako záloha pre prípad, že funkcia v databáze ešte nie je (PGRST202); taká
// žiadosť vždy čaká na ručné schválenie. Iné chyby (uzavretý mesiac, neplatný vstup, spojenie) sa nezakrývajú zálohou.
import { z } from "zod";
import type { supabase } from "@/integrations/supabase/client";
import { isMissingFunction } from "./rpc-helpers";

type Client = typeof supabase;

export interface CorrectionInput {
  userId: string;
  code: string;
  direction: string;
  at: Date;
  reason: string;
}

/** `approved` = schválená automaticky (vzniklo razenie); `pending` = čaká na vedúceho. */
export type CorrectionOutcome = "approved" | "pending";

export const CORRECTION_SENT_MESSAGE = "Žiadosť odoslaná manažérovi.";
export const CORRECTION_AUTO_APPROVED_MESSAGE = "Oprava bola schválená automaticky.";
export const CLOSED_MONTH_MESSAGE = "Mesiac je uzavretý.";

// Tvar odpovede RPC. Neznámy alebo poškodený tvar sa berie ako čakajúca žiadosť (nikdy nehlásime schválenie, ktorým si nie sme istí).
const resultSchema = z.object({
  status: z.enum(["pending", "approved"]),
  auto_approved: z.boolean(),
});

export function parseCorrectionOutcome(data: unknown): CorrectionOutcome {
  const parsed = resultSchema.safeParse(data);
  return parsed.success && parsed.data.status === "approved" && parsed.data.auto_approved
    ? "approved"
    : "pending";
}

/** Odošle žiadosť o opravu. Pri chybe vyhodí chybu databázy (správa je zrozumiteľná, pozri `correctionErrorMessage`). */
export async function submitCorrection(
  client: Client,
  input: CorrectionInput,
  deviceToken: string | null,
): Promise<CorrectionOutcome> {
  const reason = input.reason.trim();
  const atTime = input.at.toISOString();
  const res = await client.rpc("request_correction", {
    _code: input.code,
    _direction: input.direction,
    _at_time: atTime,
    _reason: reason,
    ...(deviceToken ? { _device_token: deviceToken } : {}),
  });
  if (!res.error) return parseCorrectionOutcome(res.data);
  if (!isMissingFunction(res.error)) throw res.error;
  // Databáza ešte nemá migráciu 0013: pôvodný zápis, žiadosť vždy čaká na ručné schválenie.
  const direct = await client.from("corrections").insert({
    user_id: input.userId,
    code: input.code,
    direction: input.direction,
    at_time: atTime,
    reason,
  });
  if (direct.error) throw direct.error;
  return "pending";
}

/** Správa pre zamestnanca: chyba pravidla riadkov (starý priamy zápis) znamená uzavretý mesiac. */
export function correctionErrorMessage(error: { message?: string | null }): string {
  const message = error.message ?? "";
  return message.includes("row-level") ? CLOSED_MONTH_MESSAGE : message;
}

export function correctionSuccessMessage(outcome: CorrectionOutcome): string {
  return outcome === "approved" ? CORRECTION_AUTO_APPROVED_MESSAGE : CORRECTION_SENT_MESSAGE;
}
