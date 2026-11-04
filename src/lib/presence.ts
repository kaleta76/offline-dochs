/**
 * Kto je práve v práci – stav zamestnanca podľa jeho posledného dnešného razenia.
 *
 * Nejde o výpočet času (ten je len v `engine.ts`), iba o určenie stavu v danom okamihu:
 *  - posledné razenie je príchod (IN)                        → „in“   (prítomný)
 *  - posledné razenie je odchod z práce (WORK, OUT)          → „out“  (odišiel; môže ísť o obed aj koniec zmeny)
 *  - posledné razenie je odchod z iného dôvodu (lekár, …)    → „away“ (mimo pracoviska, dôvod je v `code`)
 *  - dnes nemá žiadne platné razenie                         → „none“
 * Zneplatnené razenia sa nepočítajú. Vstup nemusí byť zoradený.
 */
export type PresenceState = "in" | "away" | "out" | "none";

export interface PresencePunch {
  code: string;
  direction: "IN" | "OUT";
  time: Date;
  voided?: boolean;
}

export interface Presence {
  state: PresenceState;
  /** kód posledného razenia (napr. WORK, DOCTOR); pri stave „none“ null */
  code: string | null;
  direction: "IN" | "OUT" | null;
  /** čas posledného razenia; pri stave „none“ null */
  since: Date | null;
}

export const NO_PRESENCE: Presence = { state: "none", code: null, direction: null, since: null };

export function presenceOf(punches: readonly PresencePunch[]): Presence {
  let last: PresencePunch | null = null;
  for (const p of punches) {
    if (p.voided) continue;
    if (!last || p.time.getTime() >= last.time.getTime()) last = p;
  }
  if (!last) return NO_PRESENCE;
  const state: PresenceState = last.direction === "IN" ? "in" : last.code === "WORK" ? "out" : "away";
  return { state, code: last.code, direction: last.direction, since: last.time };
}

export interface PresenceSummary {
  in: number;
  away: number;
  out: number;
  none: number;
  total: number;
}

export function summarizePresence(list: readonly Presence[]): PresenceSummary {
  const s: PresenceSummary = { in: 0, away: 0, out: 0, none: 0, total: list.length };
  for (const p of list) s[p.state] += 1;
  return s;
}
