// Žiadosť o opravu (Môj mesiac): RPC `request_correction` (migrácia 0013, dôvod čakania od 0014) s kľúčom zariadenia zamestnanca.
//
// Server porovná kľúč s aktívnym alebo záložným zariadením zamestnanca (kľúč neukladá). Ak vedúci zamestnancovi zapol automatické
// schvaľovanie a žiadosť spĺňa limity a zapadá do poradia razení dňa, schváli sa sama a vznikne z nej razenie; inak čaká na vedúceho
// ako doteraz. Od 0014 odpoveď obsahuje aj `manual_reason`: prečo sa žiadosť neschválila sama (len ak má zamestnanec voľbu zapnutú).
// Klient nikdy nenastavuje `device_verified` ani `auto_approved`: o tom rozhoduje len databáza.
//
// Pôvodný priamy zápis do `corrections` ostáva len ako záloha pre prípad, že funkcia v databáze ešte nie je (PGRST202); taká
// žiadosť vždy čaká na ručné schválenie. Iné chyby (uzavretý mesiac, neplatný vstup, spojenie) sa nezakrývajú zálohou.
import { z } from "zod";
import type { supabase } from "@/integrations/supabase/client";
import { AUTO_APPROVAL_DAYS, AUTO_APPROVAL_PER_DAY } from "./auto-approval";
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

/** Prečo sa žiadosť neschválila sama (migrácia 0014). Neznámy alebo chýbajúci dôvod sa berie ako `null`. */
export type ManualReason =
  "device" | "type" | "future" | "too_old" | "limit" | "duplicate" | "sequence";

export interface CorrectionResult {
  outcome: CorrectionOutcome;
  /** `null` pri automatickom schválení, bez zapnutej voľby, pri starej databáze (0013) a pri neznámom dôvode. */
  reason: ManualReason | null;
}

const MANUAL_REASON_TEXT: Record<ManualReason, string> = {
  device: "automatické schvaľovanie platí len zo zariadenia, ktoré je u vás overené",
  type: "tento typ opravy sa vždy schvaľuje ručne",
  future: "čas opravy je v budúcnosti",
  too_old: `oprava je staršia ako ${AUTO_APPROVAL_DAYS} dní`,
  limit: `dosiahli ste denný limit ${AUTO_APPROVAL_PER_DAY} automatických opráv`,
  duplicate: "rovnaká žiadosť už existuje",
  sequence: "nezapadá do poradia príchodov a odchodov v ten deň",
};

function isManualReason(value: unknown): value is ManualReason {
  return typeof value === "string" && Object.hasOwn(MANUAL_REASON_TEXT, value);
}

export const CORRECTION_SENT_MESSAGE = "Žiadosť odoslaná manažérovi.";
export const CORRECTION_AUTO_APPROVED_MESSAGE = "Oprava bola schválená automaticky.";
export const CLOSED_MONTH_MESSAGE = "Mesiac je uzavretý.";

// Tvar odpovede RPC. Neznámy alebo poškodený tvar sa berie ako čakajúca žiadosť (nikdy nehlásime schválenie, ktorým si nie sme istí).
// `manual_reason` je zámerne voľný text: neznámy dôvod (novšia databáza) nesmie pokaziť rozpoznanie schválenia.
const resultSchema = z.object({
  status: z.enum(["pending", "approved"]),
  auto_approved: z.boolean(),
  manual_reason: z.string().nullish(),
});

export function parseCorrectionResult(data: unknown): CorrectionResult {
  const parsed = resultSchema.safeParse(data);
  if (!parsed.success) return { outcome: "pending", reason: null };
  const { status, auto_approved, manual_reason } = parsed.data;
  if (status === "approved" && auto_approved) return { outcome: "approved", reason: null };
  return { outcome: "pending", reason: isManualReason(manual_reason) ? manual_reason : null };
}

export function parseCorrectionOutcome(data: unknown): CorrectionOutcome {
  return parseCorrectionResult(data).outcome;
}

/** Odošle žiadosť o opravu. Pri chybe vyhodí chybu databázy (správa je zrozumiteľná, pozri `correctionErrorMessage`). */
export async function submitCorrection(
  client: Client,
  input: CorrectionInput,
  deviceToken: string | null,
): Promise<CorrectionResult> {
  const reason = input.reason.trim();
  const atTime = input.at.toISOString();
  const res = await client.rpc("request_correction", {
    _code: input.code,
    _direction: input.direction,
    _at_time: atTime,
    _reason: reason,
    ...(deviceToken ? { _device_token: deviceToken } : {}),
  });
  if (!res.error) return parseCorrectionResult(res.data);
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
  return { outcome: "pending", reason: null };
}

/** Správa pre zamestnanca: chyba pravidla riadkov (starý priamy zápis) znamená uzavretý mesiac. */
export function correctionErrorMessage(error: { message?: string | null }): string {
  const message = error.message ?? "";
  return message.includes("row-level") ? CLOSED_MONTH_MESSAGE : message;
}

/** Text pre zamestnanca. Dôvod čakania sa pripojí len keď ho databáza poslala (zamestnanec má voľbu zapnutú). */
export function correctionSuccessMessage(
  outcome: CorrectionOutcome,
  reason: ManualReason | null = null,
): string {
  if (outcome === "approved") return CORRECTION_AUTO_APPROVED_MESSAGE;
  return reason
    ? `${CORRECTION_SENT_MESSAGE} Automaticky sa neschválila: ${MANUAL_REASON_TEXT[reason]}.`
    : CORRECTION_SENT_MESSAGE;
}
