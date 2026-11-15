// Plán mesiaca zamestnanca z Accessu (etapa 3, migrácia 0024, docs/VERZIE-NASTAVENI.md).
//
// Mesiac, ktorý patrí Accessu (verzia nastavení z Accessu), sa počíta podľa plánu z Accessu: denný fond po dňoch, okno práce a režim
// výpočtu každého dňa. Terminál plán IBA ČÍTA (RPC `month_plan`); nikdy ho nezapisuje ani nevymýšľa. Kde plán nie je (mesiac patrí
// terminálu, zamestnanec nie je v súbore, funkcia v databáze ešte nie je, odpoveď je neplatná alebo odkazuje na neznámy režim),
// deň sa počíta ako doteraz a je označený „nepotvrdené“ (`planMissing`), nie ticho odhadnutý.
import { z } from "zod";
import { supabase } from "@/integrations/supabase/client";
import type { DayPlan, RegimeDef } from "./engine";

type LooseRpc = {
  rpc(
    fn: string,
    args?: Record<string, unknown>,
  ): PromiseLike<{ data: unknown; error: { message: string; code?: string | null } | null }>;
};
// Typy klienta vznikajú automaticky z databázy a funkcia migrácie 0024 ich ešte nepozná.
const db = supabase as unknown as LooseRpc;

const minute = z.number().int().min(0).max(1440);
const planSchema = z.object({
  month: z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/),
  version_id: z.guid(),
  employment_pct: z.number(),
  fund_id: z.number().nullable(),
  day_types: z.array(z.string()),
  expected_min: z.array(minute),
  /** Číslo režimu pre každý deň, 0 = bez režimu; null = mesiac bez režimov. */
  regime_ids: z.array(z.number().int().min(0).max(99)).nullable(),
  window_start_min: minute.nullable(),
  window_end_min: minute.nullable(),
});

export interface MonthPlan {
  /** rrrr-mm */
  month: string;
  /** Verzia nastavení, z ktorej plán pochádza (tá istá, podľa ktorej sa mesiac počíta). */
  versionId: string;
  employmentPct: number;
  fundId: number | null;
  dayTypes: string[];
  /** Fond dňa v minútach, index 0 = 1. deň mesiaca (0 = deň bez fondu). */
  expectedMin: number[];
  regimeIds: number[] | null;
  windowStartMin: number | null;
  windowEndMin: number | null;
}

const monthArg = (year: number, month: number) => `${year}-${String(month).padStart(2, "0")}-01`;
const daysIn = (year: number, month: number) => new Date(year, month, 0).getDate();

/**
 * Odpoveď `month_plan` ako plán mesiaca. Všetko, čo nesedí (iný mesiac, zlý počet dní, okno len z jednej strany alebo obrátené,
 * neznámy tvar), je „plán nie je“ (null): radšej nepotvrdené saldo než plán, ktorému sa nedá veriť.
 */
export function parseMonthPlan(value: unknown, month: { y: number; m: number }): MonthPlan | null {
  if (value === null || value === undefined) return null;
  const parsed = planSchema.safeParse(value);
  if (!parsed.success) return null;
  const d = parsed.data;
  const n = daysIn(month.y, month.m);
  if (d.month !== monthArg(month.y, month.m).slice(0, 7)) return null;
  if (d.day_types.length !== n || d.expected_min.length !== n) return null;
  if (d.regime_ids !== null && d.regime_ids.length !== n) return null;
  const hasStart = d.window_start_min !== null;
  const hasEnd = d.window_end_min !== null;
  if (hasStart !== hasEnd) return null;
  if (
    d.window_start_min !== null &&
    d.window_end_min !== null &&
    d.window_start_min >= d.window_end_min
  )
    return null;
  return {
    month: d.month,
    versionId: d.version_id,
    employmentPct: d.employment_pct,
    fundId: d.fund_id,
    dayTypes: d.day_types,
    expectedMin: d.expected_min,
    regimeIds: d.regime_ids,
    windowStartMin: d.window_start_min,
    windowEndMin: d.window_end_min,
  };
}

/**
 * Plán mesiaca zamestnanca z databázy. Volá sa len pre mesiac, ktorý patrí Accessu. Cudzieho zamestnanca (`userId`) smie čítať len jeho
 * vedúci alebo správca (rozhoduje databáza). Chyba volania (aj chýbajúca funkcia pred 0024) = plán nie je: stránka sa ukáže,
 * dni sú „nepotvrdené“ a pri ďalšom načítaní sa čítanie skúsi znova.
 */
export async function loadMonthPlan(
  month: { y: number; m: number },
  userId?: string | null,
): Promise<MonthPlan | null> {
  try {
    const { data, error } = await db.rpc("month_plan", {
      _month: monthArg(month.y, month.m),
      _user: userId ?? null,
    });
    if (error) return null;
    return parseMonthPlan(data, month);
  } catch {
    return null;
  }
}

export interface DayPlanInput {
  plan: DayPlan;
  regime: RegimeDef | null;
}

/**
 * Plán a režim pre jeden deň mesiaca (`day` = deň v mesiaci od 1). Okno práce je jedno na celý mesiac zamestnanca. Deň s režimom,
 * ktorý model nepozná, sa nedá spoľahlivo spočítať: vráti null (volajúci ho označí ako „nepotvrdený“), režim sa nevynecháva ticho.
 */
export function dayPlanInput(
  plan: MonthPlan,
  day: number,
  regimes: Map<number, RegimeDef>,
): DayPlanInput | null {
  const expectedMin = plan.expectedMin[day - 1];
  if (expectedMin === undefined) return null;
  const id = plan.regimeIds?.[day - 1] ?? 0;
  let regime: RegimeDef | null = null;
  if (id > 0) {
    regime = regimes.get(id) ?? null;
    if (!regime) return null;
  }
  const dayPlan: DayPlan = { expectedMin };
  if (plan.windowStartMin !== null && plan.windowEndMin !== null) {
    dayPlan.windowStartMin = plan.windowStartMin;
    dayPlan.windowEndMin = plan.windowEndMin;
  }
  return { plan: dayPlan, regime };
}
