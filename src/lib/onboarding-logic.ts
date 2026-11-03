// Čistá logika registrácie zamestnancov: stav PIN-u, zámky po omyloch, spracovanie zoznamu čísel.
// Bez závislostí, aby sa dala testovať samostatne.

type Meta = Record<string, unknown>;

export const PIN_TTL_MS = 24 * 60 * 60 * 1000;
export const PIN_MAX_ATTEMPTS = 5;
export const LOGIN_LIMIT = 8;
export const LOGIN_WINDOW_MS = 15 * 60 * 1000;
export const RECOVERY_LIMIT = 5;
export const RECOVERY_WINDOW_MS = 60 * 60 * 1000;

const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : 0);

export type PinStatus = "missing" | "expired" | "locked" | "ready";

/** Stav jednorazového PIN-u uloženého v app_metadata účtu. */
export function pinStatus(meta: Meta, now: number): PinStatus {
  if (
    !meta["onboarding_pending"] ||
    typeof meta["pin_hash"] !== "string" ||
    typeof meta["pin_salt"] !== "string"
  ) {
    return "missing";
  }
  if (num(meta["pin_expires"]) < now) return "expired";
  if (num(meta["pin_attempts"]) >= PIN_MAX_ATTEMPTS) return "locked";
  return "ready";
}

/** Je účet dočasne zamknutý po príliš veľa omyloch? Zámok skončí `windowMs` po poslednom omyle. */
export function isThrottled(
  meta: Meta,
  key: string,
  limit: number,
  windowMs: number,
  now: number,
): boolean {
  return num(meta[`${key}_fail`]) >= limit && now - num(meta[`${key}_fail_at`]) < windowMs;
}

/** Zmena metadát po omyle: počítadlo sa po uplynutí okna začína odznova. */
export function failurePatch(meta: Meta, key: string, windowMs: number, now: number): Meta {
  const stale = now - num(meta[`${key}_fail_at`]) >= windowMs;
  return { [`${key}_fail`]: (stale ? 0 : num(meta[`${key}_fail`])) + 1, [`${key}_fail_at`]: now };
}

export function clearPatch(key: string): Meta {
  return { [`${key}_fail`]: null, [`${key}_fail_at`]: null };
}

export function hasFailures(meta: Meta, key: string): boolean {
  return num(meta[`${key}_fail`]) > 0;
}

export type NumberList = { valid: string[]; invalid: string[]; duplicates: number };

/**
 * Zo vloženého textu alebo CSV vyberie osobné čísla (7 alebo 8 číslic, zachová počiatočné nuly).
 * Slová bez číslic (hlavičky stĺpcov, prípadné mená) ignoruje; ostatné neplatné položky vráti.
 */
export function parseNumberList(text: string): NumberList {
  const tokens = text
    .replace(/^\uFEFF/, "")
    .split(/[\s;,]+/)
    .map((t) => t.replace(/^["']+|["']+$/g, ""))
    .filter((t) => t.length > 0 && /\d/.test(t));
  const seen = new Set<string>();
  const valid: string[] = [];
  const invalid: string[] = [];
  let duplicates = 0;
  for (const t of tokens) {
    if (!/^[0-9]{7,8}$/.test(t)) {
      invalid.push(t);
    } else if (seen.has(t)) {
      duplicates++;
    } else {
      seen.add(t);
      valid.push(t);
    }
  }
  return { valid, invalid, duplicates };
}
