// Pure attendance calculation engine. No I/O — fully unit-testable.
//
// Stage 1b: the day is calculated the way the Access system calculates it (access/moduly/mod_08_UdalostiDna.bas `SpracujDen`,
// `TrvanieIntervalu`, `SumarDna`, `UplatniZaokruhlenie`; terminal punches are paired as in mod_19_TerminalImport.bas `SparujRazenia`),
// with the semantics of contract 1.5.0 (contract/README.md): `calc` WORK / LUNCH / COUNTED / UNPAID, full-day threshold, lunch base,
// recorded lunch modes, rounding with direction, work window, regimes. Differences from Access are listed in docs/VERZIE-NASTAVENI.md.
//
// Settings reach the engine only through `EngineSettings`. The four legacy fields are required so that the old call shape keeps working;
// everything else is optional and, when absent, equals the default terminal version (docs/migracie/0022_verzie_nastaveni.sql).

export type Direction = "IN" | "OUT";
export interface PunchLike {
  code: string;
  direction: Direction;
  time: Date;
}

export type Calc = "WORK" | "LUNCH" | "COUNTED" | "UNPAID";

/** Properties of one interruption (contract 1.5.0), keyed in `EngineSettings.interruptions` by the terminal punch code (WORK, DOCTOR, …). */
export interface InterruptionProps {
  /** Interruption number in the model (1 = work, 7 = lunch are fixed). */
  number: number;
  /** An unknown value is never replaced by a guess: the day is flagged as unconfirmed. */
  calc: string;
  /** From which length of one interval the whole daily fund counts instead of the real duration; null = `fullDayObstacleMin`. */
  fullDayMin?: number | null | undefined;
  /** Real duration of the interval is added to the base for the lunch threshold. */
  countsToLunchBase?: boolean | undefined;
  /** An interruption without a return ends with the shift (the day is topped up to the fund when auto repair is on). */
  autoEndOfShift?: boolean | undefined;
  /** Entered only for a whole day (leave, sickness): the day counts as the daily fund. */
  fullDayOnly?: boolean | undefined;
}

export interface EngineSettings {
  roundInMin: number; // first arrival of the day
  roundOutMin: number; // last departure of the day
  breakMin: number; // automatic lunch deduction (0 = automatic lunch off)
  breakAfterHours: number; // automatic lunch threshold (from this value inclusive)

  /** 0 arrival up / departure down (default), 1 both up, 2 both down, 3 nearest multiple. */
  roundingMode?: number;
  /** Work window in minutes from midnight; work outside it does not count. 0 .. 1440 = no window. */
  windowStartMin?: number;
  windowEndMin?: number;
  /** An interval of an interruption this long (or longer) counts as the whole daily fund. 1440 = off. */
  fullDayObstacleMin?: number;
  /** Recorded lunch: 0 real time, 1 at least `lunchMinMin`, 2 always exactly `lunchMinMin`. */
  lunchRecordedMode?: number;
  lunchMinMin?: number;
  /** A plain departure followed by a later arrival is a lunch (true) or just a departure and a new arrival (false). */
  unlabeledOutIsLunch?: boolean;
  /** The same code and direction within this many minutes is a duplicate and is ignored. */
  duplicateWindowMin?: number;
  /**
   * 0 and 1: an interruption without a return stays an anomaly and nothing is added (1 = Access only proposes the repair, the terminal has no approval step);
   * 2: it is topped up to the daily fund. Absent = 2 (the call shape without a model keeps the behaviour of the engine before 1b).
   */
  autoRepairMode?: number;
  /** Terminal code → interruption properties. Absent = the default terminal version. */
  interruptions?: Map<string, InterruptionProps> | undefined;
}

export interface DayPlan {
  /** Daily fund in minutes for this day (0 = non-working day). */
  expectedMin: number;
  /** Work window of the employee this month (replaces the window from the rules). */
  windowStartMin?: number;
  windowEndMin?: number;
}

/** Regime of a day (contract 1.5.0 `regimes[]`): a set of overridden rules and interruption properties. */
export interface RegimeDef {
  rules?: Record<string, unknown> | undefined;
  interruptions?:
    | {
        code: number;
        calc?: string | undefined;
        full_day_min?: number | undefined;
        counts_to_lunch_base?: boolean | undefined;
      }[]
    | undefined;
}

export interface DayInput {
  punches: PunchLike[];
  fundHours: number;
  isWorkday: boolean; // false on weekend / holiday
  /** Plan of the day (from the model or from Access). Absent = fund from `fundHours` and `isWorkday` (terminal version). */
  plan?: DayPlan;
  /** The month belongs to Access but there is no plan from Access for it: the result is marked unconfirmed, nothing is guessed. */
  planMissing?: boolean;
  /** Regime valid for the day, resolved by the caller. */
  regime?: RegimeDef | null;
}

export type Unconfirmed = "no_plan" | "unknown_calc" | "unknown_code";

export interface DayResult {
  workMin: number;
  creditMin: number;
  privMin: number;
  breakMin: number;
  totalMin: number;
  expectedMin: number;
  balanceMin: number;
  byCode: Record<string, number>;
  /** Unfinished day: an arrival without a departure, or an interruption without a return that was not topped up. */
  open: boolean;
  /** Anomaly codes of the day (as in Access: UNFINISHED_WORK, UNFINISHED_INTERRUPTION, DUPLICATE, …). */
  anomalies?: string[];
  /** The balance cannot be confirmed: no plan from Access, or a `calc` value the engine does not know. */
  unconfirmed?: Unconfirmed | null;
  /** The day was topped up to the fund because an interruption had no return. */
  repaired?: boolean;
}

const WORK_NO = 1;
const LUNCH_NO = 7;

/** Default terminal version (docs/migracie/0022_verzie_nastaveni.sql `settings_default_config`), used when the settings carry no interruptions. */
export const DEFAULT_INTERRUPTIONS: ReadonlyMap<string, InterruptionProps> = new Map<
  string,
  InterruptionProps
>([
  ["WORK", { number: WORK_NO, calc: "WORK" }],
  ["DOCTOR", { number: 2, calc: "COUNTED", autoEndOfShift: true }],
  ["ERRAND", { number: 4, calc: "COUNTED", autoEndOfShift: true }],
  ["LEAVE", { number: 8, calc: "COUNTED", autoEndOfShift: true, fullDayOnly: true }],
  ["SICK", { number: 11, calc: "COUNTED", autoEndOfShift: true, fullDayOnly: true }],
  ["TRIP", { number: 12, calc: "COUNTED", autoEndOfShift: true, countsToLunchBase: true }],
  ["PRIV", { number: 13, calc: "UNPAID" }],
  ["FAMILY", { number: 16, calc: "COUNTED", autoEndOfShift: true }],
]);

interface Resolved {
  roundIn: number;
  roundOut: number;
  roundingMode: number;
  windowStart: number;
  windowEnd: number;
  fullDayObstacle: number;
  lunchOn: boolean;
  lunchMin: number;
  lunchLimit: number;
  lunchRecordedMode: number;
  lunchMinRecorded: number;
  unlabeledOutIsLunch: boolean;
  duplicateWindow: number;
  autoRepairMode: number;
  byCode: Map<string, InterruptionProps>;
  byNumber: Map<number, { code: string; props: InterruptionProps }>;
}

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

/** Regime values override the rules, regime interruption changes override the properties (contract 1.5.0, order of values for a day). */
export function applyRegime(
  s: EngineSettings,
  regime: RegimeDef | null | undefined,
): EngineSettings {
  if (!regime) return s;
  const r = regime.rules ?? {};
  const out: EngineSettings = { ...s };
  const setNum = (key: string, field: keyof EngineSettings) => {
    const v = num(r[key]);
    if (v !== null) (out as unknown as Record<string, unknown>)[field] = v;
  };
  setNum("work_window_start_min", "windowStartMin");
  setNum("work_window_end_min", "windowEndMin");
  setNum("full_day_obstacle_min", "fullDayObstacleMin");
  if (num(r["auto_lunch_trigger_min"]) !== null)
    out.breakAfterHours = (r["auto_lunch_trigger_min"] as number) / 60;
  setNum("lunch_recorded_mode", "lunchRecordedMode");
  setNum("lunch_min_min", "lunchMinMin");
  setNum("rounding_in_min", "roundInMin");
  setNum("rounding_out_min", "roundOutMin");
  setNum("rounding_mode", "roundingMode");
  setNum("auto_repair_mode", "autoRepairMode");
  if (typeof r["unlabeled_out_is_lunch"] === "boolean")
    out.unlabeledOutIsLunch = r["unlabeled_out_is_lunch"];
  if (typeof r["auto_lunch_enabled"] === "boolean") {
    const deduct = num(r["auto_lunch_deduct_min"]) ?? out.breakMin;
    out.breakMin = r["auto_lunch_enabled"] ? deduct : 0;
  } else if (num(r["auto_lunch_deduct_min"]) !== null)
    out.breakMin = r["auto_lunch_deduct_min"] as number;
  if (regime.interruptions?.length) {
    const map = new Map(out.interruptions ?? DEFAULT_INTERRUPTIONS);
    for (const change of regime.interruptions) {
      for (const [code, p] of map) {
        if (p.number !== change.code) continue;
        map.set(code, {
          ...p,
          calc: change.calc ?? p.calc,
          fullDayMin: change.full_day_min ?? p.fullDayMin,
          countsToLunchBase: change.counts_to_lunch_base ?? p.countsToLunchBase,
        });
      }
    }
    out.interruptions = map;
  }
  return out;
}

/**
 * Order of values for a day (contract 1.5.0): rules → work window of the employee in the month → values of the regime of the day.
 * A window value that the regime sets overrides the one from the plan (per value); a regime without a window leaves the plan window.
 */
function planUnderRegime(
  plan: DayPlan | undefined,
  regime: RegimeDef | null | undefined,
): DayPlan | undefined {
  if (!plan || !regime) return plan;
  const r = regime.rules ?? {};
  const { windowStartMin, windowEndMin, ...rest } = plan;
  const out: DayPlan = { ...rest };
  if (windowStartMin !== undefined && num(r["work_window_start_min"]) === null)
    out.windowStartMin = windowStartMin;
  if (windowEndMin !== undefined && num(r["work_window_end_min"]) === null)
    out.windowEndMin = windowEndMin;
  return out;
}

function resolve(s: EngineSettings, plan?: DayPlan): Resolved {
  const byCode = new Map(s.interruptions ?? DEFAULT_INTERRUPTIONS);
  const byNumber = new Map<number, { code: string; props: InterruptionProps }>();
  for (const [code, props] of byCode)
    if (!byNumber.has(props.number)) byNumber.set(props.number, { code, props });
  return {
    roundIn: s.roundInMin,
    roundOut: s.roundOutMin,
    roundingMode: s.roundingMode ?? 0,
    windowStart: plan?.windowStartMin ?? s.windowStartMin ?? 0,
    windowEnd: plan?.windowEndMin ?? s.windowEndMin ?? 1440,
    fullDayObstacle: s.fullDayObstacleMin ?? 1440,
    lunchOn: s.breakMin > 0,
    lunchMin: s.breakMin,
    lunchLimit: Math.round(s.breakAfterHours * 60),
    lunchRecordedMode: s.lunchRecordedMode ?? 0,
    lunchMinRecorded: s.lunchMinMin ?? 30,
    unlabeledOutIsLunch: s.unlabeledOutIsLunch ?? true,
    duplicateWindow: s.duplicateWindowMin ?? 0,
    autoRepairMode: s.autoRepairMode ?? 2,
    byCode,
    byNumber,
  };
}

// ---------------------------------------------------------------------------------------------------------------------------------
// Pairing and the state machine of a day (mod_19 SparujRazenia, mod_08 SpracujDen)

/** Event in the sense of Access: interruption number and direction Z (start) / K (end), minute from midnight. */
interface Ev {
  c: number;
  dir: "Z" | "K";
  at: number;
}
interface Iv {
  c: number;
  from: number;
  to: number;
  /** start is the return from an interruption (not a punched arrival) */
  fromResumed: boolean;
  /** end is a punched departure */
  toDeparture: boolean;
}

const minuteOf = (d: Date) => d.getHours() * 60 + d.getMinutes();

function pair(ps: PunchLike[], R: Resolved, anomalies: string[]): Ev[] {
  const evs: Ev[] = [];
  let lastIn = -1;
  ps.forEach((p, k) => {
    if (p.code === "WORK" && p.direction === "IN") lastIn = k;
  });
  let openNo = 0;
  ps.forEach((p, k) => {
    const at = minuteOf(p.time);
    if (p.code === "WORK") {
      if (p.direction === "IN") {
        if (openNo !== 0) {
          evs.push({ c: openNo, dir: "K", at });
          openNo = 0;
        } else evs.push({ c: WORK_NO, dir: "Z", at });
      } else if (k > lastIn || !R.unlabeledOutIsLunch) {
        evs.push({ c: WORK_NO, dir: "K", at });
        openNo = 0;
      } else {
        evs.push({ c: LUNCH_NO, dir: "Z", at });
        openNo = LUNCH_NO;
      }
      return;
    }
    const props = R.byCode.get(p.code);
    if (!props) {
      anomalies.push(`UNKNOWN_CODE:${p.code}`); // the punch is left out and the day is flagged, nothing is guessed
      return;
    }
    if (p.direction === "OUT") {
      evs.push({ c: props.number, dir: "Z", at });
      openNo = props.number;
    } else {
      evs.push({ c: props.number, dir: "K", at });
      if (openNo === props.number) openNo = 0;
    }
  });
  return evs;
}

interface DayState {
  ivs: Iv[];
  openWork: boolean;
  openInterruption: number | null;
}

function runDay(evs: Ev[], R: Resolved, anomalies: string[]): DayState {
  const ivs: Iv[] = [];
  const last = new Map<number, { dir: "Z" | "K"; at: number }>();
  let working = false,
    wFrom = 0,
    wReturned = false,
    wResumed = false;
  let inter = false,
    iNo = 0,
    iFrom = 0;
  const parallel: number[] = [];

  for (const e of evs) {
    // duplicate: the same code and direction within the limit, no opposite punch in between (the map holds the last one only)
    const prev = last.get(e.c);
    if (prev && prev.dir === e.dir && e.at - prev.at >= 0 && e.at - prev.at <= R.duplicateWindow) {
      anomalies.push("DUPLICATE");
      continue;
    }
    last.set(e.c, { dir: e.dir, at: e.at });

    if (e.c === WORK_NO && e.dir === "Z") {
      if (working && wReturned) {
        wFrom = e.at;
        wReturned = false;
        wResumed = false; // a punched arrival replaces the restored work
      } else if (working) {
        anomalies.push("DOUBLE_ARRIVAL");
      } else {
        if (inter && e.at > iFrom) {
          anomalies.push("ARRIVAL_DURING_INTERRUPTION");
          ivs.push({ c: iNo, from: iFrom, to: e.at, fromResumed: false, toDeparture: false });
          inter = false;
        }
        working = true;
        wFrom = e.at;
        wReturned = false;
        wResumed = false;
      }
    } else if (e.c === WORK_NO && e.dir === "K") {
      if (working) {
        if (!(inter && iFrom === wFrom))
          ivs.push({ c: WORK_NO, from: wFrom, to: e.at, fromResumed: wResumed, toDeparture: true });
        working = false;
        wReturned = false;
      } else if (inter) {
        if (e.at > iFrom) anomalies.push("DEPARTURE_DURING_INTERRUPTION");
        ivs.push({ c: iNo, from: iFrom, to: e.at, fromResumed: false, toDeparture: false });
        inter = false;
      } else anomalies.push("DEPARTURE_WITHOUT_ARRIVAL");
    } else if (e.dir === "Z") {
      if (inter && e.at === iFrom && iNo !== e.c) {
        // a parallel interruption in the same minute is not counted twice
        if (parallel.length < 16) parallel.push(e.c);
        continue;
      }
      if (inter && e.at > iFrom) {
        anomalies.push("OVERLAPPING_INTERRUPTION");
        ivs.push({ c: iNo, from: iFrom, to: e.at, fromResumed: false, toDeparture: false });
        inter = false;
      }
      if (!inter) {
        if (working && e.at > wFrom) {
          ivs.push({
            c: WORK_NO,
            from: wFrom,
            to: e.at,
            fromResumed: wResumed,
            toDeparture: false,
          });
          working = false;
        }
        inter = true;
        iNo = e.c;
        iFrom = e.at;
      }
    } else if (inter && iNo === e.c) {
      ivs.push({ c: e.c, from: iFrom, to: e.at, fromResumed: false, toDeparture: false });
      if (!working) {
        working = true;
        wFrom = e.at;
        wReturned = true;
        wResumed = true;
      } else if (iFrom === wFrom) {
        wFrom = e.at;
        wReturned = true;
        wResumed = true;
      }
      inter = false;
    } else {
      const k = parallel.indexOf(e.c);
      if (k >= 0) parallel.splice(k, 1);
      else anomalies.push("END_WITHOUT_START");
    }
  }
  const openWork = working;
  if (openWork) anomalies.push("UNFINISHED_WORK");
  if (inter) anomalies.push("UNFINISHED_INTERRUPTION");
  return { ivs, openWork, openInterruption: inter ? iNo : null };
}

// ---------------------------------------------------------------------------------------------------------------------------------
// Rounding (mod_08 ZaokruhliCas, UplatniZaokruhlenie)

/** direction > 0 up, < 0 down, 0 to the nearest multiple (half up). A step of 0 or 1 changes nothing. */
export function roundMinutes(at: number, step: number, direction: number): number {
  if (step <= 1) return at;
  const rest = at % step;
  if (rest === 0) return at;
  if (direction > 0) return at - rest + step;
  if (direction < 0) return at - rest;
  return rest * 2 >= step ? at - rest + step : at - rest;
}

function applyRounding(ivs: Iv[], R: Resolved) {
  if (R.roundIn <= 1 && R.roundOut <= 1) return;
  const [dirIn, dirOut]: [number, number] =
    R.roundingMode === 1
      ? [1, 1]
      : R.roundingMode === 2
        ? [-1, -1]
        : R.roundingMode === 3
          ? [0, 0]
          : [1, -1];
  let first = -1,
    lastEnd = -1;
  ivs.forEach((v, i) => {
    if (v.c !== WORK_NO) return;
    if (first < 0 || v.from < ivs[first]!.from) first = i;
    if (lastEnd < 0 || v.to > ivs[lastEnd]!.to) lastEnd = i;
  });
  if (first < 0) return;
  if (R.roundIn > 1 && !ivs[first]!.fromResumed)
    ivs[first]!.from = roundMinutes(ivs[first]!.from, R.roundIn, dirIn);
  if (R.roundOut > 1) {
    const v = ivs[lastEnd]!;
    // only a real last departure of the day: nothing but work may start at or after its end
    if (v.toDeparture && !ivs.some((o) => o.c !== WORK_NO && o.from >= v.to))
      v.to = roundMinutes(v.to, R.roundOut, dirOut);
  }
}

// ---------------------------------------------------------------------------------------------------------------------------------

const ZERO_DAY = (expectedMin: number): DayResult => ({
  workMin: 0,
  creditMin: 0,
  privMin: 0,
  breakMin: 0,
  totalMin: 0,
  expectedMin,
  balanceMin: -expectedMin,
  byCode: {},
  open: false,
  anomalies: [],
  unconfirmed: null,
  repaired: false,
});

export function computeDay(input: DayInput, settings: EngineSettings): DayResult {
  const s = applyRegime(settings, input.regime);
  const R = resolve(s, planUnderRegime(input.plan, input.regime));
  const expectedMin = input.plan
    ? input.plan.expectedMin
    : input.isWorkday
      ? Math.round(input.fundHours * 60)
      : 0;
  const fundMin = expectedMin;
  const ps = input.punches
    .map((p, i) => ({ p, i }))
    .sort((a, b) => a.p.time.getTime() - b.p.time.getTime() || a.i - b.i)
    .map((x) => x.p);
  let unconfirmed: Unconfirmed | null = input.planMissing ? "no_plan" : null;

  // Whole-day codes (leave, sickness): the day counts as the daily fund, the balance is zero.
  const wholeDay = ps.find((p) => R.byCode.get(p.code)?.fullDayOnly);
  if (wholeDay) {
    return {
      ...ZERO_DAY(expectedMin),
      creditMin: expectedMin,
      totalMin: expectedMin,
      balanceMin: 0,
      byCode: expectedMin > 0 ? { [wholeDay.code]: expectedMin } : {},
      unconfirmed,
    };
  }

  const anomalies: string[] = [];
  const state = runDay(pair(ps, R, anomalies), R, anomalies);
  applyRounding(state.ivs, R);

  const props = (c: number): InterruptionProps | undefined => R.byNumber.get(c)?.props;
  const codeOf = (c: number) => R.byNumber.get(c)?.code ?? `#${c}`;
  const threshold = (c: number) => props(c)?.fullDayMin ?? R.fullDayObstacle;

  // Sums of the day (SumarDna): work (clipped by the window), counted interruptions, lunch, unpaid time, lunch base.
  let work = 0,
    credit = 0,
    priv = 0,
    lunchReal = 0,
    base = 0,
    hasLunch = false;
  const byCode: Record<string, number> = {};
  const add = (code: string, m: number) => {
    if (m > 0) byCode[code] = (byCode[code] ?? 0) + m;
  };
  for (const v of state.ivs) {
    if (v.to <= v.from) continue;
    if (v.c === WORK_NO) {
      const a = Math.max(v.from, R.windowStart),
        b = Math.min(v.to, R.windowEnd);
      if (b > a) work += b - a;
    } else if (v.c === LUNCH_NO) {
      hasLunch = true;
      lunchReal += v.to - v.from;
    } else {
      const pr = props(v.c);
      const calc = pr?.calc;
      if (calc === "UNPAID") {
        priv += v.to - v.from;
      } else if (calc === "COUNTED") {
        let t = v.to - v.from;
        if (t >= threshold(v.c)) t = fundMin;
        credit += t;
        add(codeOf(v.c), t);
        if (pr?.countsToLunchBase) base += t;
      } else {
        // unknown calc (or an interruption missing in the model): never replaced by a guess
        unconfirmed = unconfirmed ?? "unknown_calc";
        anomalies.push(`UNKNOWN_CALC:${calc ?? `#${v.c}`}`);
      }
    }
  }
  add("WORK", work);

  // Automatic lunch: from the threshold inclusive, only on a day with a fund, and only when no lunch was punched.
  let breakMin = 0;
  const lunchBase = work + base;
  if (R.lunchOn && fundMin > 0 && lunchBase >= R.lunchLimit && !hasLunch) {
    breakMin = Math.min(R.lunchMin, work); // the deduction comes from work and never makes it negative (Access can go below zero with a threshold of 0)
    work -= breakMin;
    if (byCode["WORK"]) byCode["WORK"] = Math.max(0, byCode["WORK"] - breakMin);
  }
  // Recorded lunch (lunch_recorded_mode): only on a day where work together with the lunch reaches the same threshold.
  if (hasLunch && R.lunchRecordedMode > 0 && lunchBase + lunchReal >= R.lunchLimit) {
    const before = work;
    if (R.lunchRecordedMode === 1) {
      if (lunchReal < R.lunchMinRecorded) work -= R.lunchMinRecorded - lunchReal;
    } else work += lunchReal - R.lunchMinRecorded;
    work = Math.max(0, work);
    if (byCode["WORK"] !== undefined)
      byCode["WORK"] = Math.max(0, byCode["WORK"] + (work - before));
  }

  // An interruption without a return that ends with the shift: topped up to the fund only when the rules say so.
  let repaired = false;
  if (
    state.openInterruption !== null &&
    R.autoRepairMode >= 2 &&
    expectedMin > 0 &&
    props(state.openInterruption)?.autoEndOfShift
  ) {
    const top = Math.max(0, fundMin - work - credit);
    credit += top;
    add(codeOf(state.openInterruption), top);
    repaired = true;
  }

  const totalMin = work + credit;
  return {
    workMin: work,
    creditMin: credit,
    privMin: priv,
    breakMin,
    totalMin,
    expectedMin,
    balanceMin: totalMin - expectedMin,
    byCode,
    open: state.openWork || (state.openInterruption !== null && !repaired),
    anomalies,
    unconfirmed:
      unconfirmed ?? (anomalies.some((a) => a.startsWith("UNKNOWN_CODE")) ? "unknown_code" : null),
    repaired,
  };
}

/** @deprecated Reads the old key/value rows; kept because contract/scenare/referencne_saldo.ts (the contract is not changed here) still calls it. The app reads the model (settings-model.ts `engineInputs`). */
export function settingsFromRows(
  rows: { key: string; value: string }[],
): EngineSettings & { fund: number; maxDrift: number } {
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
