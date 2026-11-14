import { supabase } from "@/integrations/supabase/client";
import { computeDay, type DayResult, type PunchLike } from "./engine";
import { applyStoredResult, engineInputs, loadSettingsForMonth } from "./settings-model";
import { asVerification, countUnverified, type DeviceVerification } from "./device-trace";

export interface DayRow extends DayResult {
  date: Date;
  key: string;
  holiday: string | null;
  weekend: boolean;
  /** všetky razenia dňa vrátane zneplatnených (tie sa do výpočtu nezapočítavajú); `verification` je len príznak, výpočet ho nepoužíva */
  punches: (PunchLike & { id: number; drift: number; source: string; voided: boolean; voidPending: boolean; verification: DeviceVerification })[];
  future: boolean;
}

export const dayKey = (d: Date) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

export async function loadMonth(userId: string, year: number, month: number) {
  const from = new Date(year, month - 1, 1);
  const to = new Date(year, month, 1);
  // Nastavenia výpočtu prídu jedinou cestou (settings-model.ts): verzia platná pre mesiac, pri uzavretom mesiaci zamestnanca verzia
  // pripnutá pri uzávierke a jej snímka. Sviatky, pravidlá aj uzávierka sú v tej istej odpovedi.
  const [punches, settings, profile] = await Promise.all([
    supabase.from("punches").select("id, code, direction, client_time, drift_minutes, source, voided_at, device_verification")
      .eq("user_id", userId).gte("client_time", from.toISOString()).lt("client_time", to.toISOString()).order("client_time"),
    loadSettingsForMonth({ y: year, m: month }, userId),
    supabase.from("profiles").select("id, department, sap_id, daily_fund").eq("id", userId).maybeSingle(),
  ]);
  const err = punches.error ?? profile.error;
  if (err) throw err;
  const s = engineInputs(settings.config);
  const closure = settings.closure;
  // čakajúce žiadosti o zneplatnenie (razenie sa ešte počíta, ale v zozname je označené)
  const pendingVoid = new Set<number>();
  const punchIds = (punches.data ?? []).filter((p) => !p.voided_at).map((p) => p.id);
  if (punchIds.length > 0) {
    const { data: pend, error: pendError } = await supabase
      .from("punch_void_requests").select("punch_id").eq("status", "pending").in("punch_id", punchIds);
    if (pendError) throw pendError;
    for (const r of pend ?? []) pendingVoid.add(r.punch_id);
  }
  // Uzavretý mesiac drží denný fond z uzávierky; neskoršia zmena fondu zamestnanca ho nezmení.
  const fund = Number(closure?.dailyFund ?? profile.data?.daily_fund ?? s.fundHours);
  const hol = s.holidays;
  const now = new Date();
  const days: DayRow[] = [];
  for (let d = new Date(from); d < to; d.setDate(d.getDate() + 1)) {
    const date = new Date(d);
    const key = dayKey(date);
    const ps = (punches.data ?? [])
      .filter((p) => dayKey(new Date(p.client_time)) === key)
      .map((p) => ({ id: p.id, code: p.code, direction: p.direction as "IN" | "OUT", time: new Date(p.client_time), drift: p.drift_minutes, source: p.source, voided: !!p.voided_at, voidPending: pendingVoid.has(p.id), verification: asVerification(p.device_verification) }));
    const weekend = date.getDay() === 0 || date.getDay() === 6;
    const holiday = hol.get(key) ?? null;
    const future = date > now;
    const r = computeDay({ punches: ps.filter((p) => !p.voided), fundHours: fund, isWorkday: !weekend && !holiday }, s);
    days.push({ ...r, ...(future ? { balanceMin: 0, expectedMin: 0 } : {}), date, key, holiday, weekend, punches: ps, future });
  }
  const sum = (k: keyof DayResult) => days.reduce((a, d) => a + (d[k] as number), 0);
  const byCode: Record<string, number> = {};
  days.forEach((d) => Object.entries(d.byCode).forEach(([c, m]) => (byCode[c] = (byCode[c] ?? 0) + m)));
  // Uzavretý mesiac sa neprepočítava: čísla dní a súčty sú z uloženého výsledku (snímky). Prepočet slúži len na kontrolu zhody.
  const month_ = applyStoredResult(
    { days, totals: { work: sum("workMin"), credit: sum("creditMin"), total: sum("totalMin"), expected: sum("expectedMin"), balance: sum("balanceMin") }, byCode },
    closure?.result ?? null,
  );
  const maxDrift = settings.maxDriftMin;
  return {
    profile: profile.data,
    closedAt: closure?.closedAt ?? null,
    maxDrift,
    days: month_.days,
    totals: month_.totals,
    byCode: month_.byCode,
    /** Verzia nastavení, podľa ktorej sa mesiac počíta, a komu mesiac patrí (Access alebo terminál). */
    settings: { version: settings.version, ownedByAccess: settings.ownedByAccess },
    /** Uzavretý mesiac: čísla sú z uloženého výsledku (fromSnapshot) a či s ním sedí kontrolný prepočet (matches; null = nedá sa porovnať). */
    snapshot: closure ? { fromSnapshot: month_.fromSnapshot, matches: month_.matches, punchesCount: closure.punchesCount } : null,
    openDays: month_.days.filter((d) => d.open && !d.future && d.key !== dayKey(now)).length,
    /** razenia z neschválených zariadení (započítavajú sa, kým ich vedúci nepotvrdí) */
    unverifiedCount: days.reduce((a, d) => a + countUnverified(d.punches), 0),
    driftCount: days.reduce((a, d) => a + d.punches.filter((p) => !p.voided && p.source === "terminal" && Math.abs(p.drift) > maxDrift).length, 0),
  };
}
export type MonthData = Awaited<ReturnType<typeof loadMonth>>;

export const PUNCH_LABEL: Record<string, string> = {
  "WORK:IN": "Príchod",
  "WORK:OUT": "Odchod",
  "DOCTOR:OUT": "Lekár",
  "FAMILY:OUT": "Sprievod",
  "TRIP:OUT": "Služobná cesta",
  "PRIV:OUT": "Súkromne",
  "LEAVE:OUT": "Dovolenka",
  "SICK:OUT": "PN",
};
export const labelOf = (code: string, dir: string) => PUNCH_LABEL[`${code}:${dir}`] ?? `${code} ${dir}`;
export const hm = (d: Date) => d.toLocaleTimeString("sk-SK", { hour: "2-digit", minute: "2-digit" });
export const WEEKDAYS = ["Ne", "Po", "Ut", "St", "Št", "Pi", "So"];
export const MONTHS = ["Január", "Február", "Marec", "Apríl", "Máj", "Jún", "Júl", "August", "September", "Október", "November", "December"];
