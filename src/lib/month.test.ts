// Zapojenie plánu z Accessu do výpočtu mesiaca (etapa 3): loadMonth nad skutočným výpočtom a podvrhnutým klientom databázy.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ rpc: vi.fn(), from: vi.fn() }));
vi.mock("@/integrations/supabase/client", () => ({
  supabase: { rpc: mocks.rpc, from: mocks.from },
}));

import { loadMonth } from "./month";
import { accessVersion, forMonthResponse } from "./__fixtures__/settings-fixtures";

const USER = "00000000-0000-4000-8000-000000000001";
const VID = accessVersion.id;
const iso = (d: number, h: number, m: number) => new Date(2026, 10, d, h, m).toISOString();
const row = (id: number, d: number, h: number, m: number, direction: "IN" | "OUT") => ({
  id,
  code: "WORK",
  direction,
  client_time: iso(d, h, m),
  drift_minutes: 0,
  source: "terminal",
  voided_at: null,
  device_verification: null,
});

/** Odpoveď `month_plan` pre november 2026: 225 minút v pracovné dni, víkendy a sviatky 0. */
function planResponse(over: Record<string, unknown> = {}) {
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

/** Tabuľky klienta: každé volanie reťazca vráti ten istý objekt, ktorý sa po `await` rozhodne na údaje tabuľky. */
function tables(punches: unknown[]) {
  const data: Record<string, unknown> = {
    punches,
    profiles: { id: USER, department: null, sap_id: "9000002", daily_fund: 7.5 },
    punch_void_requests: [],
  };
  mocks.from.mockImplementation((name: string) => {
    const b: Record<string, unknown> = {};
    for (const k of ["select", "eq", "gte", "lt", "order", "in", "maybeSingle"]) b[k] = () => b;
    b["then"] = (res: (v: unknown) => unknown, rej: (e: unknown) => unknown) =>
      Promise.resolve({ data: data[name], error: null }).then(res, rej);
    return b;
  });
}

function rpcs(origin: "terminal" | "access", plan: () => unknown) {
  mocks.rpc.mockImplementation(async (fn: string) => {
    if (fn === "settings_for_month") return { data: forMonthResponse(origin), error: null };
    if (fn === "month_plan") return plan();
    throw new Error(`neočakávané RPC ${fn}`);
  });
}
const planCalls = () => mocks.rpc.mock.calls.filter((c) => c[0] === "month_plan");
const dayOf = (m: Awaited<ReturnType<typeof loadMonth>>, d: number) =>
  m.days.find((x) => x.key === `2026-11-${String(d).padStart(2, "0")}`)!;

// 2. 11. (po) 8:00 až 11:45 = 225 min presne podľa plánu; 3. 11. (ut) 8:00 až 12:00 = 240 min
const PUNCHES = [
  row(1, 2, 8, 0, "IN"),
  row(2, 2, 11, 45, "OUT"),
  row(3, 3, 8, 0, "IN"),
  row(4, 3, 12, 0, "OUT"),
];

beforeEach(() => {
  vi.clearAllMocks();
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date(2026, 11, 1, 12, 0));
  tables(PUNCHES);
});
afterEach(() => vi.useRealTimers());

describe("mesiac z Accessu sa počíta podľa plánu", () => {
  it("fond dňa je z plánu a deň je potvrdený", async () => {
    rpcs("access", async () => ({ data: planResponse(), error: null }));
    const m = await loadMonth(USER, 2026, 11);
    expect(m.settings.ownedByAccess).toBe(true);
    const d2 = dayOf(m, 2);
    expect([d2.expectedMin, d2.balanceMin, d2.unconfirmed]).toEqual([225, 0, null]);
    const d3 = dayOf(m, 3);
    expect([d3.expectedMin, d3.balanceMin]).toEqual([225, 15]);
    expect(m.unconfirmedDays).toBe(0);
    expect(m.totals.expected).toBe(
      planResponse().expected_min.reduce((a: number, b: number) => a + b, 0),
    );
  });
  it("plán sa číta z mesiaca a zamestnanca, ktorého výkaz sa ukazuje (vedúci číta podriadeného)", async () => {
    rpcs("access", async () => ({ data: planResponse(), error: null }));
    await loadMonth(USER, 2026, 11);
    expect(planCalls()).toHaveLength(1);
    expect(planCalls()[0]).toEqual(["month_plan", { _month: "2026-11-01", _user: USER }]);
  });
  it("fond z plánu platí aj pre deň, ktorý je v kalendári sviatok alebo víkend", async () => {
    const exp = planResponse().expected_min;
    exp[16] = 450; // 17. 11. sviatok, v pláne pracovný deň
    exp[6] = 450; // 7. 11. sobota
    rpcs("access", async () => ({ data: planResponse({ expected_min: exp }), error: null }));
    const m = await loadMonth(USER, 2026, 11);
    expect(dayOf(m, 17).expectedMin).toBe(450);
    expect(dayOf(m, 7).expectedMin).toBe(450);
    expect(dayOf(m, 1).expectedMin).toBe(0);
  });
  it("okno práce a režim dňa z plánu sa použijú", async () => {
    const ids = Array.from({ length: 30 }, (_, i) => (i === 2 ? 1 : 0));
    rpcs("access", async () => ({
      data: planResponse({ window_start_min: 600, window_end_min: 1020, regime_ids: ids }),
      error: null,
    }));
    const m = await loadMonth(USER, 2026, 11);
    // 2. 11.: 8:00 až 11:45 s oknom od 10:00 = 105 min práce; 3. 11. má krízový režim (okno 0 až 1440), práca 240 min
    expect(dayOf(m, 2).workMin).toBe(105);
    expect(dayOf(m, 3).workMin).toBe(240);
  });
  it("režim, ktorý model nepozná, označí len ten deň ako nepotvrdený", async () => {
    const ids = Array.from({ length: 30 }, (_, i) => (i === 2 ? 99 : 0));
    rpcs("access", async () => ({ data: planResponse({ regime_ids: ids }), error: null }));
    const m = await loadMonth(USER, 2026, 11);
    expect(dayOf(m, 3).unconfirmed).toBe("no_plan");
    expect(dayOf(m, 2).unconfirmed).toBeNull();
    expect(m.unconfirmedDays).toBe(1);
  });
});

describe("bez plánu sa nič nehádže: dni sú nepotvrdené ako doteraz", () => {
  const sameAsBefore = (m: Awaited<ReturnType<typeof loadMonth>>) => {
    expect(m.unconfirmedDays).toBe(30);
    expect(dayOf(m, 2).unconfirmed).toBe("no_plan");
    expect(dayOf(m, 2).expectedMin).toBe(450); // fond zamestnanca 7,5 h, nie plán
  };
  it("databáza plán nemá (NULL)", async () => {
    rpcs("access", async () => ({ data: null, error: null }));
    sameAsBefore(await loadMonth(USER, 2026, 11));
  });
  it("funkcia v databáze ešte nie je (pred 0024)", async () => {
    rpcs("access", async () => ({
      data: null,
      error: { message: "Could not find the function", code: "PGRST202" },
    }));
    sameAsBefore(await loadMonth(USER, 2026, 11));
  });
  it("volanie zlyhá (sieť)", async () => {
    rpcs("access", async () => {
      throw new Error("Failed to fetch");
    });
    sameAsBefore(await loadMonth(USER, 2026, 11));
  });
  it("odpoveď nesedí (zlý počet dní)", async () => {
    rpcs("access", async () => ({ data: planResponse({ expected_min: [1, 2, 3] }), error: null }));
    sameAsBefore(await loadMonth(USER, 2026, 11));
  });
});

describe("mesiac terminálu plán nepoužíva", () => {
  it("month_plan sa nevolá a dni nie sú nepotvrdené", async () => {
    rpcs("terminal", async () => ({ data: planResponse(), error: null }));
    const m = await loadMonth(USER, 2026, 11);
    expect(planCalls()).toHaveLength(0);
    expect(m.settings.ownedByAccess).toBe(false);
    expect(m.unconfirmedDays).toBe(0);
    expect(dayOf(m, 2).expectedMin).toBe(450);
  });
});
