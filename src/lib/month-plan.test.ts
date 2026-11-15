import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc: mocks.rpc } }));

import { computeDay } from "./engine";
import { dayPlanInput, loadMonthPlan, parseMonthPlan, type MonthPlan } from "./month-plan";
import { engineInputs } from "./settings-model";
import { accessConfig } from "./__fixtures__/settings-fixtures";
import type { SettingsModel } from "./settings-model";

const NOV = { y: 2026, m: 11 };
const VID = "22222222-2222-4222-8222-222222222222";

/** Odpoveď `month_plan` pre november 2026 (30 dní): 225 minút v pracovné dni, víkendy a sviatok 0. */
function response(over: Record<string, unknown> = {}) {
  const dayTypes: string[] = [];
  const expected: number[] = [];
  for (let d = 1; d <= 30; d++) {
    const wd = new Date(2026, 10, d).getDay();
    const holiday = d === 1 || d === 17;
    dayTypes.push(holiday ? (wd === 0 ? "SN" : "SP") : wd === 0 ? "VN" : wd === 6 ? "VV" : "PP");
    expected.push(!holiday && wd !== 0 && wd !== 6 ? 225 : 0);
  }
  return {
    month: "2026-11",
    version_id: VID,
    employment_pct: 50,
    fund_id: 1,
    day_types: dayTypes,
    expected_min: expected,
    regime_ids: null,
    window_start_min: null,
    window_end_min: null,
    ...over,
  };
}

const plan = (over: Record<string, unknown> = {}): MonthPlan =>
  parseMonthPlan(response(over), NOV)!;
const regimes = () => engineInputs(accessConfig() as SettingsModel).regimes;

beforeEach(() => vi.clearAllMocks());

describe("odpoveď month_plan ako plán mesiaca", () => {
  it("platná odpoveď sa prevezme celá", () => {
    const p = plan();
    expect(p.month).toBe("2026-11");
    expect(p.versionId).toBe(VID);
    expect(p.employmentPct).toBe(50);
    expect(p.fundId).toBe(1);
    expect(p.expectedMin).toHaveLength(30);
    expect(p.expectedMin[1]).toBe(225);
    expect(p.dayTypes[0]).toBe("SN");
    expect(p.regimeIds).toBeNull();
    expect(p.windowStartMin).toBeNull();
  });
  it("okno a režimy po dňoch prejdú", () => {
    const ids = Array.from({ length: 30 }, (_, i) => (i === 3 ? 1 : 0));
    const p = plan({ regime_ids: ids, window_start_min: 360, window_end_min: 1020 });
    expect(p.regimeIds).toEqual(ids);
    expect([p.windowStartMin, p.windowEndMin]).toEqual([360, 1020]);
  });
  it("plán nie je (null) → null", () => {
    expect(parseMonthPlan(null, NOV)).toBeNull();
    expect(parseMonthPlan(undefined, NOV)).toBeNull();
  });
  it("čo nesedí, je „plán nie je“, nie plán, ktorému sa nedá veriť", () => {
    const bad: Record<string, unknown>[] = [
      { month: "2026-10" }, // iný mesiac, než sa žiadal
      { expected_min: response().expected_min.slice(1) }, // 29 dní
      { day_types: response().day_types.slice(1) },
      { regime_ids: [0, 0, 0] },
      { expected_min: response().expected_min.map(() => 1441) },
      { expected_min: response().expected_min.map(() => -1) },
      { expected_min: response().expected_min.map(() => 7.5) },
      { window_start_min: 360 }, // okno len z jednej strany
      { window_end_min: 1020 },
      { window_start_min: 1020, window_end_min: 360 }, // obrátené
      { window_start_min: 600, window_end_min: 600 },
      { version_id: "nie-je-guid" },
      { employment_pct: "50" },
    ];
    for (const o of bad)
      expect(parseMonthPlan(response(o), NOV), JSON.stringify(o).slice(0, 60)).toBeNull();
    for (const v of ["x", 5, [], {}, { month: "2026-11" }])
      expect(parseMonthPlan(v, NOV)).toBeNull();
  });
  it("počet dní sa porovnáva s mesiacom (február, priestupný rok)", () => {
    const feb = (n: number) => ({
      ...response(),
      month: "2028-02",
      day_types: Array(n).fill("PP"),
      expected_min: Array(n).fill(450),
    });
    expect(parseMonthPlan(feb(29), { y: 2028, m: 2 })).not.toBeNull();
    expect(parseMonthPlan(feb(28), { y: 2028, m: 2 })).toBeNull();
    expect(parseMonthPlan(feb(29), { y: 2027, m: 2 })).toBeNull();
  });
});

describe("plán a režim jedného dňa", () => {
  it("fond dňa podľa indexu (1. deň = prvý prvok)", () => {
    const p = plan({ expected_min: Array.from({ length: 30 }, (_, i) => i + 1) });
    expect(dayPlanInput(p, 1, regimes())?.plan.expectedMin).toBe(1);
    expect(dayPlanInput(p, 30, regimes())?.plan.expectedMin).toBe(30);
    expect(dayPlanInput(p, 0, regimes())).toBeNull();
    expect(dayPlanInput(p, 31, regimes())).toBeNull();
  });
  it("okno práce sa pridá len keď je celé; inak plán okno nenesie", () => {
    const w = dayPlanInput(plan({ window_start_min: 360, window_end_min: 1020 }), 2, regimes())!;
    expect(w.plan).toEqual({ expectedMin: 225, windowStartMin: 360, windowEndMin: 1020 });
    const n = dayPlanInput(plan(), 2, regimes())!;
    expect(n.plan).toEqual({ expectedMin: 225 });
    expect("windowStartMin" in n.plan).toBe(false);
  });
  it("režim: 0 a mesiac bez režimov = bez režimu; číslo = režim z modelu", () => {
    const ids = Array.from({ length: 30 }, (_, i) => (i === 3 ? 1 : 0));
    const p = plan({ regime_ids: ids });
    expect(dayPlanInput(p, 3, regimes())?.regime).toBeNull();
    expect(dayPlanInput(p, 4, regimes())?.regime).toEqual(regimes().get(1));
    expect(regimes().get(1)).toBeDefined();
    expect(dayPlanInput(plan(), 4, regimes())?.regime).toBeNull();
  });
  it("režim, ktorý model nepozná, sa nevynechá ticho: deň sa nedá spočítať (null)", () => {
    const ids = Array.from({ length: 30 }, (_, i) => (i === 4 ? 7 : 0));
    const p = plan({ regime_ids: ids });
    expect(dayPlanInput(p, 5, regimes())).toBeNull();
    expect(dayPlanInput(p, 4, regimes())).not.toBeNull();
  });
});

describe("plán v výpočte dňa (skutočný computeDay a model z Accessu)", () => {
  const s = engineInputs(accessConfig() as SettingsModel);
  const at = (d: number, h: number, mi: number) => new Date(2026, 10, d, h, mi);
  const punches = (d: number, h1: number, m1: number, h2: number, m2: number) => [
    { code: "WORK", direction: "IN" as const, time: at(d, h1, m1) },
    { code: "WORK", direction: "OUT" as const, time: at(d, h2, m2) },
  ];
  it("fond dňa je z plánu, nie z fondu zamestnanca: 3 h 45 min pri fonde 225 min je saldo nula", () => {
    const i = dayPlanInput(plan(), 2, s.regimes)!;
    const r = computeDay(
      {
        punches: punches(2, 8, 0, 11, 45),
        fundHours: 7.5,
        isWorkday: true,
        plan: i.plan,
        regime: i.regime,
      },
      s,
    );
    expect([r.expectedMin, r.balanceMin, r.unconfirmed]).toEqual([225, 0, null]);
    const bez = computeDay(
      { punches: punches(2, 8, 0, 11, 45), fundHours: 7.5, isWorkday: true },
      s,
    );
    expect(bez.balanceMin).toBe(-225);
  });
  it("deň, ktorý je v kalendári víkend, ale plán mu dáva fond (pracovná sobota), má fond z plánu", () => {
    const p = plan({ expected_min: response().expected_min.map((v, i) => (i === 6 ? 450 : v)) });
    const i = dayPlanInput(p, 7, s.regimes)!;
    const r = computeDay(
      { punches: [], fundHours: 7.5, isWorkday: false, plan: i.plan, regime: i.regime },
      s,
    );
    expect(r.expectedMin).toBe(450);
  });
  it("okno práce z plánu zrezáva prácu mimo okna", () => {
    const p = plan({ window_start_min: 600, window_end_min: 1020 });
    const i = dayPlanInput(p, 3, s.regimes)!;
    const r = computeDay(
      {
        punches: punches(3, 8, 0, 12, 0),
        fundHours: 7.5,
        isWorkday: true,
        plan: i.plan,
        regime: i.regime,
      },
      s,
    );
    expect(r.workMin).toBe(120);
    const bez = computeDay(
      {
        punches: punches(3, 8, 0, 12, 0),
        fundHours: 7.5,
        isWorkday: true,
        plan: { expectedMin: 225 },
      },
      s,
    );
    expect(bez.workMin).toBe(240);
  });
  it("režim dňa zmení pravidlá: krízový režim zruší okno 6:00 až 17:00", () => {
    const ids = Array.from({ length: 30 }, (_, i) => (i === 3 ? 1 : 0));
    const p = plan({ regime_ids: ids });
    const inRegime = dayPlanInput(p, 4, s.regimes)!;
    const bezRezimu = dayPlanInput(p, 5, s.regimes)!;
    const a = computeDay(
      {
        punches: punches(4, 5, 0, 10, 0),
        fundHours: 7.5,
        isWorkday: true,
        plan: inRegime.plan,
        regime: inRegime.regime,
      },
      s,
    );
    const b = computeDay(
      {
        punches: punches(5, 5, 0, 10, 0),
        fundHours: 7.5,
        isWorkday: true,
        plan: bezRezimu.plan,
        regime: bezRezimu.regime,
      },
      s,
    );
    expect(a.workMin).toBe(300);
    expect(b.workMin).toBe(240);
  });
});

describe("čítanie plánu z databázy", () => {
  it("jedno RPC s mesiacom a zamestnancom; bez zamestnanca ide null", async () => {
    mocks.rpc.mockResolvedValue({ data: response(), error: null });
    const p = await loadMonthPlan(NOV, "u1");
    expect(mocks.rpc).toHaveBeenCalledWith("month_plan", { _month: "2026-11-01", _user: "u1" });
    expect(p?.versionId).toBe(VID);
    await loadMonthPlan({ y: 2026, m: 3 });
    expect(mocks.rpc).toHaveBeenLastCalledWith("month_plan", { _month: "2026-03-01", _user: null });
  });
  it("databáza plán nemá (NULL) → null", async () => {
    mocks.rpc.mockResolvedValue({ data: null, error: null });
    expect(await loadMonthPlan(NOV, "u1")).toBeNull();
  });
  it("chyba (chýbajúca funkcia pred 0024, oprávnenie, sieť) → null, stránka sa nezrúti", async () => {
    mocks.rpc.mockResolvedValue({
      data: null,
      error: { message: "Could not find the function", code: "PGRST202" },
    });
    expect(await loadMonthPlan(NOV, "u1")).toBeNull();
    mocks.rpc.mockResolvedValue({ data: null, error: { message: "Nemáte oprávnenie" } });
    expect(await loadMonthPlan(NOV, "u1")).toBeNull();
    mocks.rpc.mockRejectedValue(new Error("Failed to fetch"));
    expect(await loadMonthPlan(NOV, "u1")).toBeNull();
  });
  it("neplatná odpoveď → null", async () => {
    mocks.rpc.mockResolvedValue({ data: { ...response(), expected_min: [1, 2, 3] }, error: null });
    expect(await loadMonthPlan(NOV, "u1")).toBeNull();
  });
});
