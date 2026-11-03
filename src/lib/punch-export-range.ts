// Pomocné funkcie exportu razení pre Access: výber mesiaca podľa Europe/Bratislava, názov súboru a
// prevod riadkov z databázy na tvar kontraktu v1. Čisté funkcie bez Supabase a Reactu (dajú sa testovať).
import { personnelNumberSchema } from "./personnel";
import { localTime, TIME_ZONE, type PunchDbRow } from "./punch-export";

export const EXPORT_PAGE_SIZE = 1000; // PostgREST vracia najviac 1000 riadkov naraz

/** Rozdiel (ms) medzi miestnym časom v pásme a UTC v danom okamihu. */
function zoneOffsetMs(utcMs: number, tz: string): number {
  const sec = Math.floor(utcMs / 1000) * 1000;
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: tz,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date(sec));
  const get = (type: string) => Number(parts.find((p) => p.type === type)?.value);
  const asUtc = Date.UTC(
    get("year"),
    get("month") - 1,
    get("day"),
    get("hour"),
    get("minute"),
    get("second"),
  );
  return asUtc - sec;
}

/** Okamih (UTC), v ktorom je v pásme polnoc 1. dňa mesiaca. */
export function monthStartUtc(year: number, month: number, tz = TIME_ZONE): Date {
  const naive = Date.UTC(year, month - 1, 1);
  const first = naive - zoneOffsetMs(naive, tz);
  return new Date(naive - zoneOffsetMs(first, tz));
}

/** Polootvorený interval [from, to) mesiaca v pásme Europe/Bratislava vyjadrený v UTC. */
export function monthRangeUtc(year: number, month: number): { from: Date; to: Date } {
  const nextYear = month === 12 ? year + 1 : year;
  const nextMonth = month === 12 ? 1 : month + 1;
  return { from: monthStartUtc(year, month), to: monthStartUtc(nextYear, nextMonth) };
}

/** `punches_RRRRMM.csv` pre celý mesiac, `punches_RRRRMMDD_HHMM.csv` pre prírastok. */
export function exportFileName(opts: {
  year: number;
  month: number;
  sinceId?: number | undefined;
  now?: Date | undefined;
}): string {
  if (opts.sinceId === undefined) {
    return `punches_${opts.year}${String(opts.month).padStart(2, "0")}.csv`;
  }
  const local = localTime((opts.now ?? new Date()).toISOString()); // "2026-11-03 09:12:45"
  const stamp = `${local.slice(0, 4)}${local.slice(5, 7)}${local.slice(8, 10)}_${local.slice(11, 13)}${local.slice(14, 16)}`;
  return `punches_${stamp}.csv`;
}

export interface ProfileLite {
  id: string;
  sap_id: string | null;
}

export interface PunchDbShape {
  id: number;
  client_uuid: string;
  code: string;
  direction: string;
  client_time: string;
  server_time: string;
  drift_minutes: number;
  source: string;
  device_verification: string;
  device_id: string | null;
  user_id: string;
  prev_hash: string | null;
  record_hash: string | null;
}

const SOURCES = new Set(["terminal", "correction"]);
const VERIFICATIONS = new Set(["verified", "unverified", "confirmed"]);

/**
 * Prevedie riadky z tabuľky `punches` (+ osobné čísla z `profiles`) na tvar kontraktu v1.
 * Pri chybe vyhodí Error so zrozumiteľným textom; export sa radšej nevydá, než aby obsahoval nesprávne dáta.
 */
export function toExportRows(
  punches: PunchDbShape[],
  profiles: ProfileLite[],
  organizationId: string,
): PunchDbRow[] {
  const sap = new Map<string, string>();
  const missing = new Set<string>();
  for (const p of profiles) {
    const parsed = personnelNumberSchema.safeParse(p.sap_id);
    if (parsed.success) sap.set(p.id, parsed.data);
  }
  const rows: PunchDbRow[] = [];
  for (const r of punches) {
    const sapId = sap.get(r.user_id);
    if (!sapId) {
      missing.add(r.user_id.slice(0, 8));
      continue;
    }
    if (r.direction !== "IN" && r.direction !== "OUT") {
      throw new Error(`Razenie č. ${r.id} má neplatný smer.`);
    }
    if (!SOURCES.has(r.source))
      throw new Error(`Razenie č. ${r.id} má neznámy zdroj „${r.source}“.`);
    if (!VERIFICATIONS.has(r.device_verification)) {
      throw new Error(`Razenie č. ${r.id} má neznámy stav overenia zariadenia.`);
    }
    if (!r.record_hash || !r.prev_hash) {
      throw new Error(`Razenie č. ${r.id} nemá hash reťaze, export sa nevydá.`);
    }
    rows.push({
      id: r.id,
      organization_id: organizationId,
      client_uuid: r.client_uuid,
      sap_id: sapId,
      code: r.code,
      direction: r.direction,
      client_time: r.client_time,
      server_time: r.server_time,
      drift_minutes: r.drift_minutes,
      source: r.source as PunchDbRow["source"],
      device_verification: r.device_verification as PunchDbRow["device_verification"],
      device_id: r.device_id,
      user_id: r.user_id,
      prev_hash: r.prev_hash,
      record_hash: r.record_hash,
    });
  }
  if (missing.size > 0) {
    const list = [...missing].slice(0, 5).join(", ");
    throw new Error(
      `Pred exportom doplňte platné osobné číslo SAP (7 alebo 8 číslic) týmto účtom: ${list}${missing.size > 5 ? " a ďalším" : ""}.`,
    );
  }
  return rows;
}
