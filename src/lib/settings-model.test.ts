import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc: mocks.rpc } }));

import { computeDay } from "./engine";
import {
  applyStoredResult,
  closeMonth,
  describeVersion,
  diffSettings,
  engineInputs,
  INVALID_SETTINGS_MESSAGE,
  loadSettingsForMonth,
  loadSettingsTimeline,
  MISSING_MIGRATION_MESSAGE,
  monthResult,
  parseMonthResult,
  parseSettingsForMonth,
  saveTerminalSettings,
  unpairSettings,
  validFromOptions,
  withHoliday,
  withRule,
} from "./settings-model";
import {
  accessVersion,
  forMonthResponse,
  terminalVersion,
  timelineResponse,
} from "./__fixtures__/settings-fixtures";

beforeEach(() => vi.clearAllMocks());

describe("platné nastavenia pre mesiac", () => {
  it("vlastníka mesiaca určuje pôvod platnej verzie", () => {
    expect(parseSettingsForMonth(forMonthResponse("terminal")).ownedByAccess).toBe(false);
    const a = parseSettingsForMonth(forMonthResponse("access"));
    expect(a.ownedByAccess).toBe(true);
    expect(a.version.config_version).toBe("2026.11.04.1200");
    expect(a.closure).toBeNull();
  });
  it("model prejde celý, nielen časť, ktorú číta výpočet (režimy, šablóny, mapa kódov)", () => {
    const a = parseSettingsForMonth(forMonthResponse("access")).config as Record<string, unknown>;
    for (const k of ["regimes", "templates", "terminal_code_map", "funds", "punch_codes"])
      expect(a[k], k).toBeDefined();
    expect(a["employees"]).toBeUndefined();
  });
  it("neplatná odpoveď je chyba, nikdy vymyslené nastavenia", () => {
    for (const v of [
      null,
      {},
      { ...forMonthResponse("terminal"), version: { ...terminalVersion, origin: "sap" } },
      { ...forMonthResponse("terminal"), config: { rules: {} } },
    ])
      expect(() => parseSettingsForMonth(v)).toThrow(INVALID_SETTINGS_MESSAGE);
  });
  it("číta sa jedným RPC s mesiacom a zamestnancom; bez mesiaca rozhodne databáza", async () => {
    mocks.rpc.mockResolvedValue({ data: forMonthResponse("terminal"), error: null });
    await loadSettingsForMonth({ y: 2026, m: 3 }, "u1");
    expect(mocks.rpc).toHaveBeenCalledWith("settings_for_month", {
      _month: "2026-03-01",
      _user: "u1",
    });
    await loadSettingsForMonth();
    expect(mocks.rpc).toHaveBeenLastCalledWith("settings_for_month", { _month: null, _user: null });
  });
  it("databáza bez migrácie 0022 dá zrozumiteľné hlásenie", async () => {
    mocks.rpc.mockResolvedValue({
      data: null,
      error: { message: "Could not find the function", code: "PGRST202" },
    });
    await expect(loadSettingsForMonth()).rejects.toThrow(MISSING_MIGRATION_MESSAGE);
    await expect(loadSettingsTimeline()).rejects.toThrow(MISSING_MIGRATION_MESSAGE);
  });
});

describe("vstupy dnešného výpočtu z modelu", () => {
  it("predvolená terminálová verzia dá dnešné predvolené hodnoty", () => {
    const s = engineInputs(parseSettingsForMonth(forMonthResponse("terminal")).config);
    expect(s).toMatchObject({
      roundInMin: 0,
      roundOutMin: 0,
      breakMin: 30,
      breakAfterHours: 6,
      fundHours: 7.5,
    });
    expect(s.holidays.get("2026-11-17")).toBe("Deň boja za slobodu a demokraciu");
  });
  it("vypnutý automatický obed nič neodpočíta", () => {
    const c = parseSettingsForMonth(forMonthResponse("terminal")).config;
    const off = engineInputs({ ...c, rules: { ...c.rules, auto_lunch_enabled: false } });
    expect(off.breakMin).toBe(0);
    const day = computeDay(
      {
        punches: [
          { code: "WORK", direction: "IN", time: new Date(2026, 10, 5, 7) },
          { code: "WORK", direction: "OUT", time: new Date(2026, 10, 5, 15) },
        ],
        fundHours: 7.5,
        isWorkday: true,
      },
      off,
    );
    expect(day.breakMin).toBe(0);
    expect(day.workMin).toBe(480);
  });
  it("úprava pravidla a sviatku vracia kópiu, pôvodný model sa nemení", () => {
    const c = parseSettingsForMonth(forMonthResponse("terminal")).config;
    const r = withRule(c, "rounding_in_min", 5);
    expect(r.rules.rounding_in_min).toBe(5);
    expect(c.rules.rounding_in_min).toBe(0);
    expect(withRule(c, "auto_lunch_deduct_min", 0).rules.auto_lunch_enabled).toBe(false);
    expect(withRule(c, "auto_lunch_deduct_min", 45).rules.auto_lunch_enabled).toBe(true);
    const h = withHoliday(c, "2026-12-31", "Silvester");
    expect(h.holidays).toHaveLength(c.holidays.length + 1);
    expect(h.holidays.map((x) => x.date)).toEqual([...h.holidays.map((x) => x.date)].sort());
    expect(withHoliday(h, "2026-12-31", null).holidays).toEqual(c.holidays);
    expect(withHoliday(c, c.holidays[0]!.date, "Iný názov").holidays).toHaveLength(
      c.holidays.length,
    );
  });
});

const day = (key: string, balanceMin: number, voided = false) => ({
  key,
  workMin: 450 + balanceMin,
  creditMin: 0,
  privMin: 0,
  breakMin: 30,
  totalMin: 450 + balanceMin,
  expectedMin: 450,
  balanceMin,
  byCode: { WORK: 450 + balanceMin },
  open: false,
  punches: [{ voided: false }, { voided }],
});
const month = (balances: number[]) => {
  const days = balances.map((b, i) => day(`2026-10-${String(i + 1).padStart(2, "0")}`, b));
  const sum = (k: "workMin" | "creditMin" | "totalMin" | "expectedMin" | "balanceMin") =>
    days.reduce((a, d) => a + d[k], 0);
  return {
    days,
    totals: {
      work: sum("workMin"),
      credit: sum("creditMin"),
      total: sum("totalMin"),
      expected: sum("expectedMin"),
      balance: sum("balanceMin"),
    },
    byCode: { WORK: sum("workMin") },
  };
};

describe("snímka uzavretého mesiaca", () => {
  it("výsledok nesie súčty, dni a počet platných razení, nič osobné", () => {
    const m = month([10, -20]);
    m.days[1] = day("2026-10-02", -20, true);
    const r = monthResult(m);
    expect(r.punches).toBe(3);
    expect(r.totals.balance).toBe(-10);
    expect(r.days.map((d) => d.d)).toEqual(["2026-10-01", "2026-10-02"]);
    expect(Object.keys(r.days[0]!).sort()).toEqual([
      "balanceMin",
      "breakMin",
      "byCode",
      "creditMin",
      "d",
      "expectedMin",
      "open",
      "privMin",
      "totalMin",
      "workMin",
    ]);
    expect(parseMonthResult(JSON.parse(JSON.stringify(r)))).toEqual(r);
  });
  it("uzavretý mesiac ukáže uložené čísla, aj keď by prepočet dnes vyšiel inak", () => {
    const stored = monthResult(month([10, -20]));
    // po uzávierke sa zmenil fond alebo výpočet: prepočet dáva iné saldo
    const out = applyStoredResult(month([40, 5]), stored);
    expect(out.fromSnapshot).toBe(true);
    expect(out.matches).toBe(false);
    expect(out.totals.balance).toBe(-10);
    expect(out.days.map((d) => d.balanceMin)).toEqual([10, -20]);
    // razenia dňa ostávajú z čítania (zoznam), menia sa len čísla
    expect(out.days[0]!.punches).toHaveLength(2);
    expect(out.days[0]!.key).toBe("2026-10-01");
  });
  it("zhodný prepočet potvrdí snímku", () => {
    const out = applyStoredResult(month([10, -20]), monthResult(month([10, -20])));
    expect(out).toMatchObject({ fromSnapshot: true, matches: true });
  });
  it("bez uloženého výsledku alebo pri inom počte dní sa nič nevymýšľa: platí prepočet z pripnutej verzie", () => {
    expect(applyStoredResult(month([10]), null)).toMatchObject({
      fromSnapshot: false,
      matches: null,
    });
    const other = applyStoredResult(month([10]), monthResult(month([10, 5])));
    expect(other.fromSnapshot).toBe(false);
    expect(other.totals.balance).toBe(10);
  });
  it("neznámy tvar uloženého výsledku je null", () => {
    for (const v of [null, {}, { engine: 1, punches: -1, totals: {}, byCode: {}, days: [] }, "x"])
      expect(parseMonthResult(v)).toBeNull();
  });
  it("uzávierka s výsledkom ide jedným RPC", async () => {
    mocks.rpc.mockResolvedValue({ data: null, error: null });
    const r = monthResult(month([0]));
    await closeMonth("u1", 2026, 10, r);
    expect(mocks.rpc).toHaveBeenCalledWith("close_month", {
      _user: "u1",
      _year: 2026,
      _month: 10,
      _result: r,
    });
    mocks.rpc.mockResolvedValue({ data: null, error: { message: "Mesiac je už uzavretý" } });
    await expect(closeMonth("u1", 2026, 10, r)).rejects.toThrow("Mesiac je už uzavretý");
  });
  it("odpoveď s uzávierkou nesie pripnutý fond, odtlačok razení a výsledok", () => {
    const r = monthResult(month([10]));
    const s = parseSettingsForMonth(
      forMonthResponse("terminal", {
        closed_at: "2026-11-02T10:00:00Z",
        pinned: true,
        daily_fund: 7.5,
        punches_count: 2,
        last_record_hash: "ab",
        result: r,
      }),
    );
    expect(s.closure).toMatchObject({
      pinned: true,
      dailyFund: 7.5,
      punchesCount: 2,
      lastRecordHash: "ab",
    });
    expect(s.closure?.result).toEqual(r);
  });
});

describe("Správa: časová os, platnosť, odpárovanie", () => {
  it("časová os sa načíta a overí", async () => {
    mocks.rpc.mockResolvedValue({ data: timelineResponse("access"), error: null });
    const t = await loadSettingsTimeline();
    expect(t.versions).toHaveLength(2);
    expect(t.current.origin).toBe("access");
    mocks.rpc.mockResolvedValue({
      data: { ...timelineResponse("access"), month_now: "november" },
      error: null,
    });
    await expect(loadSettingsTimeline()).rejects.toThrow(INVALID_SETTINGS_MESSAGE);
  });
  it("platnosť sa ponúka od najstaršieho neuzavretého mesiaca po aktuálny, aj cez rok", () => {
    expect(validFromOptions("2026-10", "2026-11")).toEqual(["2026-10", "2026-11"]);
    expect(validFromOptions("2026-11", "2027-02")).toEqual([
      "2026-11",
      "2026-12",
      "2027-01",
      "2027-02",
    ]);
    // všetko uzavreté až po budúcnosť: ponúkne sa len aktuálny mesiac
    expect(validFromOptions("2026-12", "2026-11")).toEqual(["2026-11"]);
    expect(validFromOptions("2026-11", "2026-11", 1)).toEqual(["2026-11", "2026-12"]);
  });
  it("uloženie a odpárovanie posielajú prvý deň mesiaca; odpárovanie vždy s potvrdením", async () => {
    mocks.rpc.mockResolvedValue({ data: null, error: null });
    const c = parseSettingsForMonth(forMonthResponse("terminal")).config;
    await saveTerminalSettings(c, "2026-10");
    expect(mocks.rpc).toHaveBeenLastCalledWith("settings_terminal_save", {
      _config: c,
      _valid_from: "2026-10-01",
    });
    await unpairSettings("2027-03", "terminal");
    expect(mocks.rpc).toHaveBeenLastCalledWith("settings_unpair", {
      _valid_from: "2027-03-01",
      _choice: "terminal",
      _confirm: true,
    });
    mocks.rpc.mockResolvedValue({ data: null, error: { message: "Mesiac 11/2026 patrí Accessu" } });
    await expect(saveTerminalSettings(c)).rejects.toThrow("patrí Accessu");
  });
  it("rozdiel pred odpárovaním pomenuje zmenené pravidlá a prerušenia", () => {
    const a = parseSettingsForMonth(forMonthResponse("access")).config;
    expect(diffSettings(a, a)).toEqual([]);
    const b = withRule(withRule(a, "rounding_in_min", 0), "auto_lunch_deduct_min", 45);
    const d = diffSettings(a, b);
    expect(d).toContainEqual({
      label: "odpočet obeda",
      from: String(a.rules.auto_lunch_deduct_min),
      to: "45",
    });
    if ((a.rules.rounding_in_min ?? 0) !== 0)
      expect(d).toContainEqual({
        label: "zaokrúhlenie príchodu",
        from: String(a.rules.rounding_in_min),
        to: "0",
      });
    const t = parseSettingsForMonth(forMonthResponse("terminal")).config;
    const cross = diffSettings(a, t);
    expect(cross.length).toBeGreaterThan(0);
    expect(cross.some((x) => x.label.startsWith("prerušenie"))).toBe(true);
    const fewer = { ...a, interruptions: a.interruptions.slice(1) };
    expect(diffSettings(a, fewer)[0]).toMatchObject({ from: "je", to: "nie je" });
  });
  it("popis verzie: verzia a dátum importu pri Accesse, dôvod pri termináli, bez mien", () => {
    expect(describeVersion(accessVersion as never)).toMatch(
      /^Access, verzia 2026\.11\.04\.1200, import .*platí od 11\/2026$/,
    );
    expect(describeVersion(terminalVersion as never)).toMatch(
      /^Terminál \(predvolené pri registrácii\), .*platí od 9\/2026$/,
    );
    expect(describeVersion({ ...accessVersion, valid_from: null } as never)).toMatch(
      /uložená bez platnosti$/,
    );
  });
});
