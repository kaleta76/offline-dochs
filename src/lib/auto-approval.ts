// Automatické schvaľovanie opráv vedúcim (migrácia 0013): čisté pomocné funkcie pre kartu v Môj tím.
//
// Pravidlá vynucuje databáza (funkcia request_correction); tu sú len hodnoty pre texty a výber riadkov na obrazovke.
// Zmena limitov znamená zmenu migrácie aj týchto konštánt (pozri AGENTS.md).
import { isMissingFunction } from "./rpc-helpers";

/** Najstarší čas opravy, ktorý sa ešte schváli sám, a čas, za ktorý sa zobrazujú automaticky schválené opravy. */
export const AUTO_APPROVAL_DAYS = 14;
/** Najviac automatických opráv na zamestnanca za deň, ktorého sa oprava týka; ďalšie schvaľuje vedúci ručne. */
export const AUTO_APPROVAL_PER_DAY = 5;

export interface AutoApprovalPerson {
  id: string;
  sap_id: string | null;
  department: string | null;
  manager_id: string | null;
}
export interface AutoApprovalPair {
  user_id: string;
  manager_id: string;
  enabled_at: string;
}
export interface AutoApprovalRow {
  person: AutoApprovalPerson;
  enabled: boolean;
  enabledAt: string | null;
  /** Vedúci, ktorý voľbu zapol (zobrazuje sa správcovi, keď to nie je on sám). */
  enabledBy: string | null;
  /** Zapnúť smie len priamy vedúci zamestnanca. */
  canEnable: boolean;
  /** Vypnúť smie priamy vedúci aj správca. */
  canDisable: boolean;
}

/**
 * Riadky karty. Vedúci vidí svojich priamych podriadených; správca navyše každého, komu má niekto voľbu zapnutú (aby ju vedel vypnúť).
 * Seba samého nikto nevidí (voľbu si nikto nezapne sám sebe).
 */
export function autoApprovalRows(
  uid: string,
  isAdmin: boolean,
  people: readonly AutoApprovalPerson[],
  pairs: readonly AutoApprovalPair[],
): AutoApprovalRow[] {
  const pairByUser = new Map(pairs.map((p) => [p.user_id, p]));
  return people
    .filter((p) => p.id !== uid)
    .filter((p) => p.manager_id === uid || (isAdmin && pairByUser.has(p.id)))
    .map((person) => {
      const pair = pairByUser.get(person.id);
      const direct = person.manager_id === uid;
      return {
        person,
        enabled: pair !== undefined,
        enabledAt: pair?.enabled_at ?? null,
        enabledBy: pair?.manager_id ?? null,
        canEnable: direct && pair === undefined,
        canDisable: pair !== undefined && (direct || isAdmin),
      };
    })
    .sort((a, b) => (a.person.sap_id ?? "").localeCompare(b.person.sap_id ?? ""));
}

/** Začiatok okna „posledných 14 dní“ ako ISO čas. */
export function autoApprovalSince(now: Date): string {
  return new Date(now.getTime() - AUTO_APPROVAL_DAYS * 24 * 60 * 60 * 1000).toISOString();
}

interface DbErrorLike {
  code?: string | null;
  message?: string | null;
}

/** Tabuľka alebo stĺpec z migrácie 0013 v databáze ešte nie je: karta sa vtedy neukáže (databáza sa nedá pokaziť, len chýba voľba). */
export function isAutoApprovalUnavailable(error: DbErrorLike): boolean {
  if (isMissingFunction(error)) return true;
  const code = error.code ?? "";
  if (code === "42P01" || code === "42703" || code === "PGRST205") return true;
  return /could not find the (table|column)|does not exist/i.test(error.message ?? "");
}
