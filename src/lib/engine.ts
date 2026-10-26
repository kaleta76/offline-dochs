// Pure attendance calculation engine. No I/O — fully unit-testable.

export type Direction = "IN" | "OUT";
export interface PunchLike {
  code: string;
  direction: Direction;
  time: Date;
}

export interface EngineSettings {
  roundInMin: number; // ceil first arrival
  roundOutMin: number; // floor last departure
  breakMin: number;
  breakAfterHours: number;
}

export interface DayInput {
  punches: PunchLike[];
  fundHours: number;
  isWorkday: boolean; // false on weekend / holiday
}

export interface DayResult {
  workMin: number;
  creditMin: number;
  privMin: number;
  breakMin: number;
  totalMin: number;
  expectedMin: number;
  balanceMin: number;
  byCode: Record<string, number>;
  open: boolean; // arrival without departure
}

// Codes whose time is credited up to the daily fund when the employee does not return.
export const TOPUP_CODES = new Set(["DOCTOR", "FAMILY", "TRIP"]);
const CREDIT_CODES = new Set(["DOCTOR", "FAMILY"]);

const MIN = 60_000;
const ceilTo = (d: Date, m: number) => (m > 0 ? new Date(Math.ceil(d.getTime() / (m * MIN)) * m * MIN) : d);
const floorTo = (d: Date, m: number) => (m > 0 ? new Date(Math.floor(d.getTime() / (m * MIN)) * m * MIN) : d);

export function computeDay(input: DayInput, s: EngineSettings): DayResult {
  const fundMin = Math.round(input.fundHours * 60);
  const ps = [...input.punches].sort((a, b) => a.time.getTime() - b.time.getTime()).map((p) => ({ ...p }));
  const byCode: Record<string, number> = {};
  const add = (code: string, m: number) => {
    if (m > 0) byCode[code] = (byCode[code] ?? 0) + m;
  };

  let expectedMin = input.isWorkday ? fundMin : 0;

  // Whole-day codes
  if (ps.some((p) => p.code === "SICK")) {
    return { workMin: 0, creditMin: 0, privMin: 0, breakMin: 0, totalMin: 0, expectedMin: 0, balanceMin: 0, byCode: { SICK: expectedMin }, open: false };
  }
  if (ps.some((p) => p.code === "LEAVE")) {
    return { workMin: 0, creditMin: expectedMin, privMin: 0, breakMin: 0, totalMin: expectedMin, expectedMin, balanceMin: 0, byCode: { LEAVE: expectedMin }, open: false };
  }

  // Rounding (only applied when enabled in settings)
  const firstIn = ps.find((p) => p.direction === "IN");
  if (firstIn) firstIn.time = ceilTo(firstIn.time, s.roundInMin);
  const last = ps[ps.length - 1];
  if (last && last.direction === "OUT" && last.code === "WORK") last.time = floorTo(last.time, s.roundOutMin);

  let workMin = 0, creditMin = 0, privMin = 0, open = false;
  for (let i = 0; i < ps.length; i++) {
    const cur = ps[i]!;
    const next = ps[i + 1];
    const dur = next ? Math.max(0, Math.round((next.time.getTime() - cur.time.getTime()) / MIN)) : null;
    if (cur.direction === "IN") {
      if (dur === null) open = true;
      else { workMin += dur; add("WORK", dur); }
    } else if (dur !== null) {
      if (cur.code === "TRIP") { workMin += dur; add("TRIP", dur); }
      else if (CREDIT_CODES.has(cur.code)) { creditMin += dur; add(cur.code, dur); }
      else if (cur.code === "PRIV") privMin += dur;
    }
  }

  // Statutory break: deducted once work exceeds threshold
  let breakMin = 0;
  if (workMin > s.breakAfterHours * 60) {
    breakMin = Math.min(s.breakMin, workMin - s.breakAfterHours * 60);
    workMin -= breakMin;
    if (byCode["WORK"]) byCode["WORK"] = Math.max(0, byCode["WORK"] - breakMin);
  }

  // Top-up to fund when the day ends with doctor / family / business trip
  if (last && last.direction === "OUT" && TOPUP_CODES.has(last.code) && input.isWorkday) {
    const top = Math.max(0, fundMin - workMin - creditMin);
    if (last.code === "TRIP") { workMin += top; add("TRIP", top); }
    else { creditMin += top; add(last.code, top); }
  }

  const totalMin = workMin + creditMin;
  return { workMin, creditMin, privMin, breakMin, totalMin, expectedMin, balanceMin: totalMin - expectedMin, byCode, open };
}

export function settingsFromRows(rows: { key: string; value: string }[]): EngineSettings & { fund: number; maxDrift: number } {
  const m = new Map(rows.map((r) => [r.key, r.value]));
  const n = (k: string, d: number) => {
    const v = parseFloat((m.get(k) ?? "").replace(",", "."));
    return Number.isFinite(v) ? v : d;
  };
  return {
    roundInMin: n("ZAOKRUHLENIE_PRICHOD", 0),
    roundOutMin: n("ZAOKRUHLENIE_ODCHOD", 0),
    breakMin: n("OBED_PAUZA_MIN", 30),
    breakAfterHours: n("OBED_PO_HODINACH", 6),
    fund: n("DENNY_FOND_HODIN", 7.5),
    maxDrift: n("MAX_ODCHYLKA_CASU_MIN", 10),
  };
}

export const fmtMin = (m: number) => {
  const sign = m < 0 ? "−" : "";
  const a = Math.abs(Math.round(m));
  return `${sign}${Math.floor(a / 60)}:${String(a % 60).padStart(2, "0")}`;
};
