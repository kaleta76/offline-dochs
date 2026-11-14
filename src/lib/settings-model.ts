// Nastavenia výpočtu ako verzie s platnosťou od mesiaca (etapa 1a, migrácia 0022, docs/VERZIE-NASTAVENI.md, docs/ARCHITEKTURA.md kap. 5).
//
// JEDINÉ miesto, kde aplikácia číta nastavenia výpočtu: `loadSettingsForMonth` (RPC `settings_for_month`, jeden POST dopyt).
// Výpočet (month.ts), tlačidlá terminálu (use-terminal-actions.ts) aj Správa čítajú odtiaľto; nič nečíta organization_settings,
// organization_holidays, calc_settings ani access_config priamo. Model má tvar kontraktu 1.5.0 bez zamestnancov a nenesie osobné údaje.
// Ostatné v tomto súbore sú čisté funkcie (odvodenie vstupov výpočtu z modelu, snímka uzavretého mesiaca, rozdiel verzií).
import { z } from "zod";
import { supabase } from "@/integrations/supabase/client";
import type { DayResult, EngineSettings } from "./engine";
import { isMissingFunction } from "./rpc-helpers";

type LooseRpc = {
  rpc(
    fn: string,
    args?: Record<string, unknown>,
  ): PromiseLike<{ data: unknown; error: { message: string; code?: string | null } | null }>;
};
// Typy klienta vznikajú automaticky z databázy a funkcie migrácie 0022 ešte nepoznajú.
const db = supabase as unknown as LooseRpc;

export const MISSING_MIGRATION_MESSAGE =
  "Databáza ešte nemá verzie nastavení výpočtu. Najprv treba spustiť migráciu 0022 (docs/migracie/0022_verzie_nastaveni.sql).";
export const INVALID_SETTINGS_MESSAGE = "Server vrátil neplatné nastavenia výpočtu.";

const ym = z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/);

const versionSchema = z.object({
  id: z.guid(),
  ord: z.number().int().positive(),
  origin: z.enum(["terminal", "access"]),
  valid_from: ym.nullable(),
  reason: z.string(),
  config_version: z.string().nullable(),
  period_from: ym.nullable().optional(),
  period_to: ym.nullable().optional(),
  created_at: z.string(),
});
export type SettingsVersion = z.infer<typeof versionSchema>;

/** Len to, čo z modelu čítajú čisté funkcie nižšie; zvyšok modelu (režimy, šablóny, fondy…) prejde nedotknutý. */
const modelSchema = z.looseObject({
  rules: z.looseObject({
    auto_lunch_enabled: z.boolean(),
    auto_lunch_trigger_min: z.number(),
    auto_lunch_deduct_min: z.number(),
    default_daily_fund_min: z.number(),
    rounding_in_min: z.number().optional(),
    rounding_out_min: z.number().optional(),
  }),
  interruptions: z.array(z.looseObject({ code: z.number(), name: z.string(), calc: z.string() })),
  holidays: z.array(z.object({ date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/), name: z.string() })),
});
export type SettingsModel = z.infer<typeof modelSchema>;

const closureSchema = z.object({
  closed_at: z.string(),
  pinned: z.boolean(),
  daily_fund: z.number().nullable(),
  punches_count: z.number().int().nullable(),
  last_record_hash: z.string().nullable(),
  result: z.unknown().nullable(),
});

const forMonthSchema = z.object({
  month: ym,
  version: versionSchema,
  config: modelSchema,
  max_drift_min: z.number(),
  closure: closureSchema.nullable(),
});

export interface MonthSettings {
  month: string;
  version: SettingsVersion;
  /** Mesiac patrí Accessu (true) alebo terminálu (false): pôvod verzie platnej pre mesiac. */
  ownedByAccess: boolean;
  config: SettingsModel;
  maxDriftMin: number;
  /** Uzávierka mesiaca zamestnanca (len keď bol zadaný zamestnanec a mesiac má uzavretý). */
  closure: {
    closedAt: string;
    /** false = uzávierka bez snímky (nemalo by nastať po migrácii 0022). */
    pinned: boolean;
    dailyFund: number | null;
    punchesCount: number | null;
    lastRecordHash: string | null;
    result: MonthResult | null;
  } | null;
}

export function parseSettingsForMonth(value: unknown): MonthSettings {
  const parsed = forMonthSchema.safeParse(value);
  if (!parsed.success) throw new Error(INVALID_SETTINGS_MESSAGE);
  const d = parsed.data;
  return {
    month: d.month,
    version: d.version,
    ownedByAccess: d.version.origin === "access",
    config: d.config,
    maxDriftMin: d.max_drift_min,
    closure: d.closure && {
      closedAt: d.closure.closed_at,
      pinned: d.closure.pinned,
      dailyFund: d.closure.daily_fund,
      punchesCount: d.closure.punches_count,
      lastRecordHash: d.closure.last_record_hash,
      result: parseMonthResult(d.closure.result),
    },
  };
}

const monthArg = (year: number, month: number) => `${year}-${String(month).padStart(2, "0")}-01`;

/**
 * PLATNÉ NASTAVENIA PRE MESIAC. Bez mesiaca = aktuálny mesiac (pásmo Europe/Bratislava určí databáza).
 * So zamestnancom: ak má mesiac uzavretý, vráti sa verzia pripnutá pri uzávierke a jej snímka, nie časová os.
 */
export async function loadSettingsForMonth(
  month?: { y: number; m: number } | null,
  userId?: string | null,
): Promise<MonthSettings> {
  const { data, error } = await db.rpc("settings_for_month", {
    _month: month ? monthArg(month.y, month.m) : null,
    _user: userId ?? null,
  });
  if (error) throw new Error(isMissingFunction(error) ? MISSING_MIGRATION_MESSAGE : error.message);
  return parseSettingsForMonth(data);
}

// ---------------------------------------------------------------------------------------------------------------------------------
// Vstupy dnešného výpočtu z modelu (etapa 1a: engine.ts sa nemení, výpočet nad celým modelom je etapa 1b)

export interface EngineInputs extends EngineSettings {
  /** Predvolený denný fond v hodinách (použije sa, keď zamestnanec nemá vlastný). */
  fundHours: number;
  holidays: Map<string, string>;
}

/** Zaokrúhlenia, obed, predvolený fond a sviatky z modelu v tvare kontraktu. */
export function engineInputs(config: SettingsModel): EngineInputs {
  const r = config.rules;
  return {
    roundInMin: r.rounding_in_min ?? 0,
    roundOutMin: r.rounding_out_min ?? 0,
    // vypnutý automatický obed = odpočet 0 (engine pri 0 nič neodpočíta)
    breakMin: r.auto_lunch_enabled ? r.auto_lunch_deduct_min : 0,
    breakAfterHours: r.auto_lunch_trigger_min / 60,
    fundHours: r.default_daily_fund_min / 60,
    holidays: new Map(config.holidays.map((h) => [h.date, h.name])),
  };
}

// ---------------------------------------------------------------------------------------------------------------------------------
// Snímka uzavretého mesiaca: výsledok, ktorý sa uloží pri uzávierke a už sa neprepočítava

const dayResultSchema = z.object({
  d: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  workMin: z.number(),
  creditMin: z.number(),
  privMin: z.number(),
  breakMin: z.number(),
  totalMin: z.number(),
  expectedMin: z.number(),
  balanceMin: z.number(),
  byCode: z.record(z.string(), z.number()),
  open: z.boolean(),
});
const monthResultSchema = z.object({
  engine: z.number().int(),
  /** Počet platných razení, z ktorých sa výsledok počítal; databáza ho pri uzávierke porovná s vlastným počtom. */
  punches: z.number().int().min(0),
  totals: z.object({
    work: z.number(),
    credit: z.number(),
    total: z.number(),
    expected: z.number(),
    balance: z.number(),
  }),
  byCode: z.record(z.string(), z.number()),
  days: z.array(dayResultSchema),
});
export type MonthResult = z.infer<typeof monthResultSchema>;

/** Verzia tvaru uloženého výsledku (nie verzia nastavení). Zmena výpočtu v etape 1b ju zvýši; v tej istej zmene treba upraviť aj databázovú kontrolu `month_result_problem` (0022), ktorá dnes prijíma len `engine` = 1. */
export const RESULT_ENGINE = 1;

/** Uložený výsledok z databázy; neznámy tvar = null (mesiac sa potom dopočíta z pripnutej verzie, nič sa nevymýšľa). */
export function parseMonthResult(value: unknown): MonthResult | null {
  const parsed = monthResultSchema.safeParse(value);
  return parsed.success ? parsed.data : null;
}

interface ComputedMonth {
  days: (DayResult & { key: string; punches: { voided: boolean }[] })[];
  totals: MonthResult["totals"];
  byCode: Record<string, number>;
}

/** Výsledok mesiaca na uloženie pri uzávierke (len čísla, žiadne razenia ani osobné údaje). */
export function monthResult(data: ComputedMonth): MonthResult {
  return {
    engine: RESULT_ENGINE,
    punches: data.days.reduce((n, d) => n + d.punches.filter((p) => !p.voided).length, 0),
    totals: { ...data.totals },
    byCode: { ...data.byCode },
    days: data.days.map((d) => ({
      d: d.key,
      workMin: d.workMin,
      creditMin: d.creditMin,
      privMin: d.privMin,
      breakMin: d.breakMin,
      totalMin: d.totalMin,
      expectedMin: d.expectedMin,
      balanceMin: d.balanceMin,
      byCode: { ...d.byCode },
      open: d.open,
    })),
  };
}

/**
 * Uzavretý mesiac sa NEPREPOČÍTAVA: čísla dní a súčty sa vezmú z uloženého výsledku. Prepočet (z pripnutej verzie a fondu)
 * slúži len na kontrolu; `matches` hovorí, či sedí s uloženým.
 */
export function applyStoredResult<T extends ComputedMonth>(
  computed: T,
  stored: MonthResult | null,
): T & { fromSnapshot: boolean; matches: boolean | null } {
  if (!stored || stored.days.length !== computed.days.length)
    return { ...computed, fromSnapshot: false, matches: null };
  const byDay = new Map(stored.days.map((d) => [d.d, d]));
  if (computed.days.some((d) => !byDay.has(d.key)))
    return { ...computed, fromSnapshot: false, matches: null };
  const matches =
    (Object.keys(stored.totals) as (keyof MonthResult["totals"])[]).every(
      (k) => stored.totals[k] === computed.totals[k],
    ) &&
    computed.days.every((d) => {
      const s = byDay.get(d.key)!;
      return (
        s.balanceMin === d.balanceMin &&
        s.totalMin === d.totalMin &&
        s.expectedMin === d.expectedMin
      );
    });
  return {
    ...computed,
    days: computed.days.map((d) => {
      const { d: _day, ...numbers } = byDay.get(d.key)!;
      return { ...d, ...numbers };
    }),
    totals: { ...stored.totals },
    byCode: { ...stored.byCode },
    fromSnapshot: true,
    matches,
  };
}

/** Uzavretie mesiaca s výsledkom v jednej transakcii (RPC `close_month`; kto smie uzavrieť, rozhodujú politiky databázy ako doteraz). */
export async function closeMonth(
  userId: string,
  year: number,
  month: number,
  result: MonthResult | null,
): Promise<void> {
  const { error } = await db.rpc("close_month", {
    _user: userId,
    _year: year,
    _month: month,
    _result: result,
  });
  if (error) throw new Error(isMissingFunction(error) ? MISSING_MIGRATION_MESSAGE : error.message);
}

// ---------------------------------------------------------------------------------------------------------------------------------
// Správa: časová os verzií, úprava terminálových nastavení, odpárovanie

const openMonthSchema = z.object({ month: ym, open: z.number().int(), closed: z.number().int() });
export type OpenMonth = z.infer<typeof openMonthSchema>;

const timelineSchema = z.object({
  month_now: ym,
  current: versionSchema,
  oldest_open: ym,
  open_months: z.array(openMonthSchema),
  last_access: versionSchema.nullable(),
  last_terminal: versionSchema.nullable(),
  versions: z.array(versionSchema),
});
export type SettingsTimeline = z.infer<typeof timelineSchema>;

export async function loadSettingsTimeline(): Promise<SettingsTimeline> {
  const { data, error } = await db.rpc("settings_timeline");
  if (error) throw new Error(isMissingFunction(error) ? MISSING_MIGRATION_MESSAGE : error.message);
  const parsed = timelineSchema.safeParse(data);
  if (!parsed.success) throw new Error(INVALID_SETTINGS_MESSAGE);
  return parsed.data;
}

export async function loadVersionConfig(id: string): Promise<SettingsModel> {
  const { data, error } = await db.rpc("settings_version_config", { _id: id });
  if (error) throw new Error(error.message);
  const parsed = z.object({ config: modelSchema }).safeParse(data);
  if (!parsed.success) throw new Error(INVALID_SETTINGS_MESSAGE);
  return parsed.data.config;
}

/** Nová terminálová verzia platná od mesiaca (`validFrom` „RRRR-MM“; bez neho aktuálny mesiac). Kontroluje a rozhoduje databáza. */
export async function saveTerminalSettings(
  config: SettingsModel,
  validFrom?: string | null,
): Promise<void> {
  const { error } = await db.rpc("settings_terminal_save", {
    _config: config,
    _valid_from: validFrom ? `${validFrom}-01` : null,
  });
  if (error) throw new Error(error.message);
}

export type UnpairChoice = "access" | "terminal";

export async function unpairSettings(
  validFrom: string | null,
  choice: UnpairChoice,
): Promise<void> {
  const { error } = await db.rpc("settings_unpair", {
    _valid_from: validFrom ? `${validFrom}-01` : null,
    _choice: choice,
    _confirm: true,
  });
  if (error) throw new Error(error.message);
}

/** Mesiace, od ktorých smie nová verzia platiť: od najstaršieho neuzavretého po aktuálny (a ďalšie budúce, ak sú žiadané). */
export function validFromOptions(oldestOpen: string, monthNow: string, future = 0): string[] {
  const idx = (s: string) => Number(s.slice(0, 4)) * 12 + Number(s.slice(5, 7)) - 1;
  const from = Math.min(idx(oldestOpen), idx(monthNow));
  const out: string[] = [];
  for (let i = from; i <= idx(monthNow) + future; i++)
    out.push(`${Math.floor(i / 12)}-${String((i % 12) + 1).padStart(2, "0")}`);
  return out;
}

/** Pravidlá, ktoré dnes upravuje karta „Pravidlá výpočtu“ (úplné editory sú etapy 2 až 4). */
export const EDITABLE_RULES = [
  {
    key: "rounding_in_min",
    label: "Zaokrúhlenie prvého príchodu nahor (min, 0 = vypnuté)",
    min: 0,
    max: 60,
  },
  {
    key: "rounding_out_min",
    label: "Zaokrúhlenie posledného odchodu nadol (min, 0 = vypnuté)",
    min: 0,
    max: 60,
  },
  { key: "auto_lunch_deduct_min", label: "Odpočet prestávky (min)", min: 0, max: 600 },
  {
    key: "auto_lunch_trigger_min",
    label: "Prestávka sa odpočíta pri práci od (min)",
    min: 0,
    max: 1440,
  },
  { key: "default_daily_fund_min", label: "Predvolený denný fond (min)", min: 0, max: 1440 },
] as const;
export type EditableRule = (typeof EDITABLE_RULES)[number]["key"];

/** Kópia modelu so zmeneným pravidlom (model sa nikdy nemení na mieste; uloženie je vždy nová verzia). */
export function withRule(config: SettingsModel, key: EditableRule, value: number): SettingsModel {
  const rules = { ...config.rules, [key]: value };
  if (key === "auto_lunch_deduct_min") rules.auto_lunch_enabled = value > 0;
  return { ...config, rules };
}

/** Kópia modelu so sviatkom navyše (rovnaký deň sa nahradí) alebo bez sviatku. */
export function withHoliday(
  config: SettingsModel,
  date: string,
  name: string | null,
): SettingsModel {
  const rest = config.holidays.filter((h) => h.date !== date);
  const holidays =
    name === null ? rest : [...rest, { date, name }].sort((a, b) => a.date.localeCompare(b.date));
  return { ...config, holidays };
}

const RULE_LABELS: Record<string, string> = {
  work_window_start_min: "začiatok okna práce",
  work_window_end_min: "koniec okna práce",
  full_day_obstacle_min: "hranica celodennej prekážky",
  auto_lunch_enabled: "automatický obed",
  auto_lunch_trigger_min: "obed od odpracovaných minút",
  auto_lunch_deduct_min: "odpočet obeda",
  duplicate_punch_window_min: "okno duplicity razení",
  default_daily_fund_min: "predvolený denný fond",
  auto_repair_mode: "režim automatických opráv",
  lunch_recorded_mode: "razený obed",
  lunch_min_min: "minúty razeného obeda",
  unlabeled_out_is_lunch: "odchod bez dôvodu je obed",
  rounding_in_min: "zaokrúhlenie príchodu",
  rounding_out_min: "zaokrúhlenie odchodu",
  rounding_mode: "smer zaokrúhlenia",
  auto_repair_target: "cieľ automatických opráv",
  auto_repair_cases: "prípady automatických opráv",
  correction_deadline_day: "lehota na opravy (deň)",
  early_return_ends_interruption: "skorší príchod ukončí prerušenie",
  interruption_check_enabled: "kontrola pravidiel prerušení",
};

const show = (v: unknown) =>
  v === undefined ? "—" : v === true ? "áno" : v === false ? "nie" : String(v);

export interface SettingsDiff {
  label: string;
  from: string;
  to: string;
}

/**
 * Rozdiel dvoch modelov pre správcu pred odpárovaním („zaokrúhlenie príchodu 5 → 0“): pravidlá, prerušenia (spôsob výpočtu,
 * hranica celého dňa, základ obeda, pribudnuté a zaniknuté) a počet sviatkov. Bez rozdielu = prázdny zoznam.
 */
export function diffSettings(from: SettingsModel, to: SettingsModel): SettingsDiff[] {
  const out: SettingsDiff[] = [];
  const a = from.rules as Record<string, unknown>;
  const b = to.rules as Record<string, unknown>;
  for (const key of [...new Set([...Object.keys(a), ...Object.keys(b)])].sort()) {
    if (a[key] !== b[key])
      out.push({ label: RULE_LABELS[key] ?? key, from: show(a[key]), to: show(b[key]) });
  }
  const ia = new Map(from.interruptions.map((i) => [i.code, i as Record<string, unknown>]));
  const ib = new Map(to.interruptions.map((i) => [i.code, i as Record<string, unknown>]));
  for (const code of [...new Set([...ia.keys(), ...ib.keys()])].sort((x, y) => x - y)) {
    const x = ia.get(code);
    const y = ib.get(code);
    const name = String((y ?? x)?.["name"] ?? code);
    if (!x || !y) {
      out.push({
        label: `prerušenie ${code} ${name}`,
        from: x ? "je" : "nie je",
        to: y ? "je" : "nie je",
      });
      continue;
    }
    for (const [k, label] of [
      ["calc", "spôsob výpočtu"],
      ["full_day_min", "celý deň od minút"],
      ["counts_to_lunch_base", "počíta sa do základu obeda"],
      ["terminal_button", "tlačidlo v termináli"],
      ["needs_approval", "schvaľuje vedúci"],
      ["full_day_only", "len na celý deň"],
    ] as const) {
      if (x[k] !== y[k])
        out.push({
          label: `prerušenie ${code} ${name}: ${label}`,
          from: show(x[k]),
          to: show(y[k]),
        });
    }
  }
  if (from.holidays.length !== to.holidays.length)
    out.push({
      label: "počet sviatkov",
      from: String(from.holidays.length),
      to: String(to.holidays.length),
    });
  return out;
}

const REASONS: Record<string, string> = {
  registration: "predvolené pri registrácii",
  backfill: "prevzaté z pôvodných nastavení",
  edit: "úprava v termináli",
  import: "import z Accessu",
  unpair_access: "odpárovanie, kópia nastavení z Accessu",
  unpair_terminal: "odpárovanie, pôvodné nastavenia terminálu",
};

/** „11/2026“ z „2026-11“. */
export const monthLabel = (m: string) => `${Number(m.slice(5, 7))}/${m.slice(0, 4)}`;

/** Jeden riadok o verzii pre správcu: pôvod, od kedy platí, verzia a dátum importu. */
export function describeVersion(v: SettingsVersion): string {
  const when = new Date(v.created_at).toLocaleDateString("sk-SK");
  const from = v.valid_from ? `platí od ${monthLabel(v.valid_from)}` : "uložená bez platnosti";
  return v.origin === "access"
    ? `Access, verzia ${v.config_version ?? "?"}, import ${when}, ${from}`
    : `Terminál (${REASONS[v.reason] ?? v.reason}), ${when}, ${from}`;
}
