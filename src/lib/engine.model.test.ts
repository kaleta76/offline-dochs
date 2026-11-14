import { describe, expect, it, vi } from "vitest";

vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc: vi.fn() } }));

import {
  applyRegime,
  computeDay,
  DEFAULT_INTERRUPTIONS,
  roundMinutes,
  type DayInput,
  type EngineSettings,
  type InterruptionProps,
  type PunchLike,
} from "./engine";
import { engineInputs, parseSettingsForMonth } from "./settings-model";
import { forMonthResponse } from "./__fixtures__/settings-fixtures";

// Výpočet nad modelom nastavení (etapa 1b). Každý výsledok je odvodený ručne z pravidiel Accessu (mod_19 SparujRazenia, mod_08 SpracujDen,
// TrvanieIntervalu, SumarDna), nie z výstupu enginu. Časy sú v minútach od polnoci, vteriny sa zahadzujú.

/** Pravidlá predvolenej terminálovej verzie (migrácia 0022): bez okna, bez zaokrúhlenia, automatická oprava vypnutá. */
const M: EngineSettings = {
  roundInMin: 0,
  roundOutMin: 0,
  breakMin: 30,
  breakAfterHours: 6,
  roundingMode: 0,
  windowStartMin: 0,
  windowEndMin: 1440,
  fullDayObstacleMin: 1440,
  lunchRecordedMode: 0,
  lunchMinMin: 30,
  unlabeledOutIsLunch: true,
  duplicateWindowMin: 0,
  autoRepairMode: 0,
};

const at = (hm: string) => new Date(`2026-10-21T${hm.length === 5 ? `${hm}:00` : hm}`);
const p = (code: string, direction: "IN" | "OUT", hm: string): PunchLike => ({
  code,
  direction,
  time: at(hm),
});
const IN = (hm: string) => p("WORK", "IN", hm);
const OUT = (hm: string) => p("WORK", "OUT", hm);
const day = (punches: PunchLike[], extra: Partial<DayInput> = {}): DayInput => ({
  punches,
  fundHours: 7.5,
  isWorkday: true,
  ...extra,
});

/** Predvolené prerušenia s prepísanými vlastnosťami podľa kódu terminála. */
const withInterruptions = (
  over: Record<string, Partial<InterruptionProps>>,
  base: EngineSettings = M,
): EngineSettings => ({
  ...base,
  interruptions: new Map(
    [...DEFAULT_INTERRUPTIONS].map(([code, v]) => [code, { ...v, ...(over[code] ?? {}) }]),
  ),
});

describe("minúty a vteriny", () => {
  it("vteriny sa zahadzujú pri každom razení (7:04:51 je 7:04, 15:56:34 je 15:56)", () => {
    const r = computeDay(day([IN("07:04:51"), OUT("15:56:04")]), M);
    // 424 .. 956 = 532 minút (nie 425 .. 956), automatický obed 30
    expect(r.workMin).toBe(502);
    expect(r.breakMin).toBe(30);
  });
});

describe("razenie odchodu bez označenia (unlabeled_out_is_lunch)", () => {
  const punches = [IN("07:00"), OUT("12:00"), IN("12:30"), OUT("15:30")];
  it("zapnuté: odchod pred posledným príchodom je obed, automatický odpočet sa nerobí", () => {
    const r = computeDay(day(punches), M);
    expect(r.workMin).toBe(300 + 180);
    expect(r.breakMin).toBe(0);
  });
  it("vypnuté: je to len odchod a nový príchod, pauza medzi nimi nie je obed, a tak sa odpočíta automatický", () => {
    const r = computeDay(day(punches), { ...M, unlabeledOutIsLunch: false });
    expect(r.workMin).toBe(300 + 180 - 30);
    expect(r.breakMin).toBe(30);
  });
});

describe("okno práce", () => {
  it("práca mimo okna sa nepočíta (5:30–17:30 v okne 6:00–17:00 je 660 minút, po obede 630)", () => {
    const r = computeDay(day([IN("05:30"), OUT("17:30")]), {
      ...M,
      windowStartMin: 360,
      windowEndMin: 1020,
    });
    expect(r.workMin).toBe(630);
    expect(r.balanceMin).toBe(630 - 450);
  });
  it("okno zamestnanca z plánu nahrádza okno z pravidiel", () => {
    const r = computeDay(
      day([IN("06:00"), OUT("16:00")], {
        plan: { expectedMin: 360, windowStartMin: 420, windowEndMin: 900 },
      }),
      { ...M, windowStartMin: 0, windowEndMin: 1440 },
    );
    // 7:00 .. 15:00 = 480, obed 30; fond z plánu 360
    expect(r.workMin).toBe(450);
    expect(r.expectedMin).toBe(360);
    expect(r.balanceMin).toBe(90);
  });
});

describe("odpočet obedu nikdy nezníži prácu pod nulu", () => {
  it("pri prahu 0 a práci 20 minút sa odpočíta len 20 (Access by tu išiel do mínusu)", () => {
    const r = computeDay(day([IN("07:00"), OUT("07:20")]), { ...M, breakAfterHours: 0 });
    expect(r.breakMin).toBe(20);
    expect(r.workMin).toBe(0);
  });
});

describe("plán dňa", () => {
  it("deň bez fondu (plán 0) nemá automatický obed a celá práca je plus", () => {
    const r = computeDay(day([IN("07:00"), OUT("15:00")], { plan: { expectedMin: 0 } }), M);
    expect(r.breakMin).toBe(0);
    expect(r.workMin).toBe(480);
    expect(r.balanceMin).toBe(480);
  });
  it("víkend alebo sviatok bez plánu: fond 0, žiadny odpočet obeda", () => {
    const r = computeDay(day([IN("07:00"), OUT("15:00")], { isWorkday: false }), M);
    expect(r.expectedMin).toBe(0);
    expect(r.breakMin).toBe(0);
    expect(r.balanceMin).toBe(480);
  });
});

describe("prerušenie s dĺžkou, od ktorej platí celý fond (full_day_min)", () => {
  const S = withInterruptions({ DOCTOR: { fullDayMin: 300 } });
  it("od 300 minút (vrátane) sa počíta celý denný fond, nie skutočný čas", () => {
    const r = computeDay(
      day([IN("07:00"), p("DOCTOR", "OUT", "09:00"), IN("14:00"), OUT("15:00")]),
      S,
    );
    expect(r.workMin).toBe(120 + 60);
    expect(r.creditMin).toBe(450);
    expect(r.byCode["DOCTOR"]).toBe(450);
  });
  it("o minútu menej sa počíta skutočný čas", () => {
    const r = computeDay(
      day([IN("07:00"), p("DOCTOR", "OUT", "09:00"), IN("13:59"), OUT("15:00")]),
      S,
    );
    expect(r.creditMin).toBe(299);
  });
  it("bez vlastného prahu platí full_day_obstacle_min z pravidiel", () => {
    const r = computeDay(
      day([IN("07:00"), p("DOCTOR", "OUT", "09:00"), IN("11:00"), OUT("15:00")]),
      { ...M, fullDayObstacleMin: 120 },
    );
    expect(r.creditMin).toBe(450);
  });
});

describe("základ pre automatický obed (counts_to_lunch_base)", () => {
  // práca 7:00–8:00 a 12:00–14:00 = 180, prerušenie 8:00–12:00 = 240
  const punches = (code: string) => [
    IN("07:00"),
    p(code, "OUT", "08:00"),
    IN("12:00"),
    OUT("14:00"),
  ];
  it("služobná cesta sa do základu počíta: 180 + 240 ≥ 360, obed sa odpočíta z práce", () => {
    const r = computeDay(day(punches("TRIP")), M);
    expect(r.breakMin).toBe(30);
    expect(r.workMin).toBe(150);
    expect(r.creditMin).toBe(240);
    expect(r.totalMin).toBe(390);
  });
  it("tá istá služobná cesta bez príznaku do základu nejde: 180 < 360, bez odpočtu", () => {
    const r = computeDay(
      day(punches("TRIP")),
      withInterruptions({ TRIP: { countsToLunchBase: false } }),
    );
    expect(r.breakMin).toBe(0);
    expect(r.workMin).toBe(180);
    expect(r.totalMin).toBe(420);
  });
  it("lekár príznak nemá: základ je len práca 180, bez odpočtu", () => {
    const r = computeDay(day(punches("DOCTOR")), M);
    expect(r.breakMin).toBe(0);
    expect(r.totalMin).toBe(420);
  });
});

describe("spôsob výpočtu prerušenia", () => {
  it("služobné vzdialenie sa započíta skutočným časom (9:00–9:30 je 30 minút)", () => {
    const r = computeDay(
      day([IN("07:00"), p("ERRAND", "OUT", "09:00"), IN("09:30"), OUT("15:30")]),
      M,
    );
    expect(r.creditMin).toBe(30);
    expect(r.byCode["ERRAND"]).toBe(30);
    expect(r.workMin).toBe(120 + 360 - 30); // obed z práce, základ je len práca (480)
    expect(r.totalMin).toBe(480);
    expect(r.balanceMin).toBe(30);
  });
  it("režim môže zmeniť súkromné prerušenie na započítané a zrušiť automatický obed", () => {
    const punches = [IN("07:00"), p("PRIV", "OUT", "10:00"), IN("11:00"), OUT("15:30")];
    const plain = computeDay(day(punches), M);
    expect(plain.privMin).toBe(60);
    expect(plain.balanceMin).toBe(-30);
    const S = applyRegime(M, {
      rules: { auto_lunch_enabled: false },
      interruptions: [{ code: 13, calc: "COUNTED", full_day_min: 480 }],
    });
    const r = computeDay(day(punches), S);
    // práca 180 + 270 = 450 bez odpočtu obeda, započítaných 60
    expect(r.workMin).toBe(450);
    expect(r.creditMin).toBe(60);
    expect(r.privMin).toBe(0);
    expect(r.balanceMin).toBe(510 - 450);
  });
  it("paralelné prerušenie sa v tej istej minúte aj ukončí bez chyby a nepočíta sa", () => {
    const r = computeDay(
      day([
        IN("07:00"),
        p("DOCTOR", "OUT", "10:00"),
        p("ERRAND", "OUT", "10:00"),
        p("ERRAND", "IN", "10:30"),
        p("DOCTOR", "IN", "11:00"),
        OUT("15:00"),
      ]),
      M,
    );
    expect(r.anomalies).not.toContain("END_WITHOUT_START");
    expect(r.byCode["DOCTOR"]).toBe(60);
    expect(r.byCode["ERRAND"]).toBeUndefined();
  });
  it("dve prerušenia v tej istej minúte sa nepočítajú dvakrát", () => {
    const r = computeDay(
      day([
        IN("07:00"),
        p("DOCTOR", "OUT", "10:00"),
        p("ERRAND", "OUT", "10:00"),
        p("DOCTOR", "IN", "11:00"),
        OUT("15:00"),
      ]),
      M,
    );
    expect(r.byCode["DOCTOR"]).toBe(60);
    expect(r.byCode["ERRAND"]).toBeUndefined();
    expect(r.creditMin).toBe(60);
    // práca 7:00–10:00 a 11:00–15:00 = 420 ≥ 360, obed 30
    expect(r.workMin).toBe(390);
  });
});

describe("celodenné prerušenia", () => {
  it("dovolenka a PN dajú celý fond a nulové saldo", () => {
    for (const code of ["LEAVE", "SICK"]) {
      const r = computeDay(day([p(code, "OUT", "07:00")]), M);
      expect(r.creditMin).toBe(450);
      expect(r.totalMin).toBe(450);
      expect(r.balanceMin).toBe(0);
      expect(r.byCode[code]).toBe(450);
      expect(r.open).toBe(false);
    }
  });
  it("v dni bez fondu (víkend) nedajú nič", () => {
    const r = computeDay(day([p("LEAVE", "OUT", "07:00")], { isWorkday: false }), M);
    expect(r.totalMin).toBe(0);
    expect(r.balanceMin).toBe(0);
    expect(r.byCode).toEqual({});
  });
});

describe("razený obed (lunch_recorded_mode)", () => {
  // obed 12:00 až `backAt`; deň vždy končí tri hodiny po návrate, takže práca je 300 + 180 = 480 minút a obed trvá 40 alebo 20 minút
  const lunch = (backAt: string) => [
    IN("07:00"),
    OUT("12:00"),
    IN(backAt),
    OUT(backAt === "12:40" ? "15:40" : "15:20"),
  ];
  it("režim 0: obed sa berie skutočný, práca sa nemení", () => {
    expect(computeDay(day(lunch("12:40")), M).workMin).toBe(480);
    expect(computeDay(day(lunch("12:20")), M).workMin).toBe(480);
  });
  it("režim 1: obed kratší ako minimum sa dopočíta na minimum, dlhší ostáva", () => {
    const S = { ...M, lunchRecordedMode: 1 };
    expect(computeDay(day(lunch("12:40")), S).workMin).toBe(480);
    expect(computeDay(day(lunch("12:20")), S).workMin).toBe(480 - 10);
  });
  it("režim 2: obed je vždy presne minimum (dlhší obed pridá, kratší uberie)", () => {
    const S = { ...M, lunchRecordedMode: 2 };
    expect(computeDay(day(lunch("12:40")), S).workMin).toBe(480 + 10);
    expect(computeDay(day(lunch("12:20")), S).workMin).toBe(480 - 10);
  });
  it("razený obed nikdy nespustí automatický odpočet a breakMin ostáva 0", () => {
    const r = computeDay(day(lunch("12:40")), { ...M, lunchRecordedMode: 2 });
    expect(r.breakMin).toBe(0);
  });
  it("režim sa neuplatní, keď práca spolu s obedom nedosiahne prah (krátky deň)", () => {
    const r = computeDay(day([IN("08:00"), OUT("10:00"), IN("10:40"), OUT("12:00")]), {
      ...M,
      lunchRecordedMode: 2,
    });
    expect(r.workMin).toBe(120 + 80);
  });
});

describe("zaokrúhlenie", () => {
  const punches = [IN("07:05"), OUT("15:40")];
  const S = (roundingMode: number): EngineSettings => ({
    ...M,
    roundInMin: 15,
    roundOutMin: 15,
    roundingMode,
  });
  it("režim 0: príchod nahor, odchod nadol (7:15–15:30 = 495, po obede 465)", () => {
    expect(computeDay(day(punches), S(0)).workMin).toBe(465);
  });
  it("režim 1: oboje nahor (7:15–15:45 = 510, po obede 480)", () => {
    expect(computeDay(day(punches), S(1)).workMin).toBe(480);
  });
  it("režim 2: oboje nadol (7:00–15:30 = 510, po obede 480)", () => {
    expect(computeDay(day(punches), S(2)).workMin).toBe(480);
  });
  it("režim 3: na najbližší násobok (7:05 na 7:00, 15:40 na 15:45 = 525, po obede 495)", () => {
    expect(computeDay(day(punches), S(3)).workMin).toBe(495);
  });
  it("návrat z prerušenia sa nezaokrúhľuje ako príchod dňa", () => {
    const r = computeDay(day([p("DOCTOR", "OUT", "07:00"), IN("07:05"), OUT("15:00")]), S(0));
    // 7:05–15:00 = 475, obed 30; keby sa zaokrúhlilo na 7:15, bolo by 465 − 30
    expect(r.workMin).toBe(445);
    expect(r.creditMin).toBe(5);
  });
  it("odchod, po ktorom nasleduje ďalšia práca, sa nezaokrúhľuje (len posledný odchod dňa)", () => {
    const r = computeDay(day([IN("07:00"), OUT("10:07"), IN("10:30"), OUT("15:00")]), S(0));
    // obed 10:07–10:30 je 23 minút; práca 187 + 270 = 457; zaokrúhli sa len posledný odchod (15:00 je násobok) a prvý príchod (7:00)
    expect(r.workMin).toBe(457);
  });
  it("roundMinutes: násobok sa nemení, krok 0 a 1 nič nerobí, najbližší na polovici ide nahor", () => {
    expect(roundMinutes(425, 15, 1)).toBe(435);
    expect(roundMinutes(420, 15, 1)).toBe(420);
    expect(roundMinutes(425, 15, -1)).toBe(420);
    expect(roundMinutes(427, 15, 0)).toBe(420);
    expect(roundMinutes(428, 15, 0)).toBe(435);
    expect(roundMinutes(425, 10, 0)).toBe(430); // presne polovica ide nahor
    expect(roundMinutes(424, 10, 0)).toBe(420);
    expect(roundMinutes(427, 0, 1)).toBe(427);
    expect(roundMinutes(427, 1, -1)).toBe(427);
  });
});

describe("duplicity a poradie razení", () => {
  it("rovnaké razenie v rámci okna je duplicita: ignoruje sa a deň to hlási", () => {
    const r = computeDay(day([IN("07:00"), IN("07:05"), OUT("15:30")]), {
      ...M,
      duplicateWindowMin: 10,
    });
    expect(r.anomalies).toContain("DUPLICATE");
    expect(r.anomalies).not.toContain("DOUBLE_ARRIVAL");
    expect(r.workMin).toBe(510 - 30);
  });
  it("hranica okna patrí duplicite (presne 10 minút), o minútu neskôr už nie", () => {
    const S = { ...M, duplicateWindowMin: 10 };
    expect(computeDay(day([IN("07:00"), IN("07:10"), OUT("15:30")]), S).anomalies).toContain(
      "DUPLICATE",
    );
    expect(computeDay(day([IN("07:00"), IN("07:11"), OUT("15:30")]), S).anomalies).not.toContain(
      "DUPLICATE",
    );
  });
  it("mimo okna ide o dvojitý príchod, výpočet ostane rovnaký, anomália sa líši", () => {
    const r = computeDay(day([IN("07:00"), IN("07:05"), OUT("15:30")]), M);
    expect(r.anomalies).toContain("DOUBLE_ARRIVAL");
    expect(r.workMin).toBe(510 - 30);
  });
  it("razenia v nezoradenom poradí sa zoradia podľa času", () => {
    const r = computeDay(day([OUT("15:30"), IN("07:00")]), M);
    expect(r.workMin).toBe(480);
  });
});

describe("prerušenie bez návratu (auto_repair_mode)", () => {
  const punches = [IN("07:00"), p("DOCTOR", "OUT", "10:00")];
  it("režim 0: nič sa nedopočíta, deň ostáva otvorený s anomáliou", () => {
    const r = computeDay(day(punches), M);
    expect(r.workMin).toBe(180);
    expect(r.creditMin).toBe(0);
    expect(r.open).toBe(true);
    expect(r.repaired).toBe(false);
    expect(r.anomalies).toContain("UNFINISHED_INTERRUPTION");
    expect(r.balanceMin).toBe(180 - 450);
  });
  it("režim 1: Access len navrhne opravu, terminál nič nedopočíta", () => {
    const r = computeDay(day(punches), { ...M, autoRepairMode: 1 });
    expect(r.creditMin).toBe(0);
    expect(r.open).toBe(true);
  });
  it("režim 2: deň sa doplní do fondu (180 + 270 = 450) a nie je otvorený", () => {
    const r = computeDay(day(punches), { ...M, autoRepairMode: 2 });
    expect(r.creditMin).toBe(270);
    expect(r.totalMin).toBe(450);
    expect(r.balanceMin).toBe(0);
    expect(r.byCode["DOCTOR"]).toBe(270);
    expect(r.open).toBe(false);
    expect(r.repaired).toBe(true);
  });
  it("prerušenie bez príznaku konca zmeny (súkromné) sa nedopočíta ani v režime 2", () => {
    const r = computeDay(day([IN("07:00"), p("PRIV", "OUT", "10:00")]), {
      ...M,
      autoRepairMode: 2,
    });
    expect(r.creditMin).toBe(0);
    expect(r.open).toBe(true);
  });
  it("príznak konca zmeny sa dá vypnúť aj pri lekárovi", () => {
    const r = computeDay(
      day(punches),
      withInterruptions({ DOCTOR: { autoEndOfShift: false } }, { ...M, autoRepairMode: 2 }),
    );
    expect(r.creditMin).toBe(0);
    expect(r.open).toBe(true);
  });
  it("v dni bez fondu sa nič nedopočíta", () => {
    const r = computeDay(day(punches, { isWorkday: false }), { ...M, autoRepairMode: 2 });
    expect(r.creditMin).toBe(0);
  });
  it("príchod bez odchodu je otvorený deň vo všetkých režimoch", () => {
    for (const mode of [0, 1, 2]) {
      const r = computeDay(day([IN("07:00")]), { ...M, autoRepairMode: mode });
      expect(r.open).toBe(true);
      expect(r.anomalies).toContain("UNFINISHED_WORK");
    }
  });
});

describe("nepotvrdené dni (nikdy tichý odhad)", () => {
  const base = [IN("07:00"), p("DOCTOR", "OUT", "10:00"), IN("11:00"), OUT("15:00")];
  it("mesiac Accessu bez plánu: číslo sa spočíta, ale deň je označený no_plan", () => {
    const r = computeDay(day([IN("07:00"), OUT("15:30")], { planMissing: true }), M);
    expect(r.unconfirmed).toBe("no_plan");
    expect(r.workMin).toBe(480);
  });
  it("deň s plánom alebo v termináli nie je nepotvrdený", () => {
    expect(computeDay(day([IN("07:00"), OUT("15:30")]), M).unconfirmed).toBeNull();
    expect(
      computeDay(day([IN("07:00"), OUT("15:30")], { plan: { expectedMin: 450 } }), M).unconfirmed,
    ).toBeNull();
  });
  it("neznámy spôsob výpočtu prerušenia sa nepočíta a deň je unknown_calc", () => {
    const r = computeDay(day(base), withInterruptions({ DOCTOR: { calc: "BUDUCI_SPOSOB" } }));
    expect(r.unconfirmed).toBe("unknown_calc");
    expect(r.creditMin).toBe(0);
    expect(r.anomalies).toContain("UNKNOWN_CALC:BUDUCI_SPOSOB");
  });
  it("kód razenia, ktorý model nepozná, sa vynechá a deň je unknown_code", () => {
    const r = computeDay(day([IN("07:00"), p("XYZ", "OUT", "10:00"), OUT("15:30")]), M);
    expect(r.unconfirmed).toBe("unknown_code");
    expect(r.anomalies).toContain("UNKNOWN_CODE:XYZ");
    expect(r.workMin).toBe(510 - 30);
  });
  it("chýbajúci plán má prednosť pred ostatnými dôvodmi", () => {
    const r = computeDay(
      day([IN("07:00"), p("XYZ", "OUT", "10:00"), OUT("15:30")], { planMissing: true }),
      M,
    );
    expect(r.unconfirmed).toBe("no_plan");
  });
});

describe("applyRegime", () => {
  it("bez režimu vráti tie isté nastavenia", () => {
    expect(applyRegime(M, null)).toBe(M);
    expect(applyRegime(M, undefined)).toBe(M);
  });
  it("hodnoty režimu prepíšu pravidlá a pôvodné nastavenia sa nemenia", () => {
    const out = applyRegime(M, {
      rules: {
        work_window_start_min: 400,
        work_window_end_min: 1000,
        full_day_obstacle_min: 300,
        auto_lunch_trigger_min: 240,
        lunch_recorded_mode: 2,
        lunch_min_min: 45,
        rounding_in_min: 10,
        rounding_out_min: 5,
        rounding_mode: 3,
        auto_repair_mode: 2,
        unlabeled_out_is_lunch: false,
      },
    });
    expect(out).toMatchObject({
      windowStartMin: 400,
      windowEndMin: 1000,
      fullDayObstacleMin: 300,
      breakAfterHours: 4,
      lunchRecordedMode: 2,
      lunchMinMin: 45,
      roundInMin: 10,
      roundOutMin: 5,
      roundingMode: 3,
      autoRepairMode: 2,
      unlabeledOutIsLunch: false,
    });
    expect(M.windowStartMin).toBe(0);
    expect(M.breakAfterHours).toBe(6);
  });
  it("vypnutý automatický obed dá odpočet 0, zapnutý s veľkosťou ju nastaví", () => {
    expect(applyRegime(M, { rules: { auto_lunch_enabled: false } }).breakMin).toBe(0);
    expect(
      applyRegime(M, { rules: { auto_lunch_enabled: true, auto_lunch_deduct_min: 20 } }).breakMin,
    ).toBe(20);
  });
  it("hodnota nesprávneho typu sa ignoruje, nenastaví sa nič", () => {
    const out = applyRegime(M, { rules: { rounding_in_min: "15", work_window_end_min: null } });
    expect(out.roundInMin).toBe(0);
    expect(out.windowEndMin).toBe(1440);
  });
  it("zmena prerušenia podľa čísla sa dotkne len jeho a nechá ostatné vlastnosti", () => {
    const out = applyRegime(M, {
      interruptions: [
        { code: 2, counts_to_lunch_base: true },
        { code: 99, calc: "COUNTED" },
      ],
    });
    const doctor = out.interruptions?.get("DOCTOR");
    expect(doctor).toMatchObject({
      number: 2,
      calc: "COUNTED",
      countsToLunchBase: true,
      autoEndOfShift: true,
    });
    expect(out.interruptions?.get("TRIP")).toMatchObject({ countsToLunchBase: true });
    expect(out.interruptions?.get("PRIV")).toMatchObject({ calc: "UNPAID" });
    expect(out.interruptions?.size).toBe(DEFAULT_INTERRUPTIONS.size);
  });
});

describe("engineInputs z modelu nastavení", () => {
  const terminal = engineInputs(parseSettingsForMonth(forMonthResponse("terminal")).config);
  const access = engineInputs(parseSettingsForMonth(forMonthResponse("access")).config);

  it("predvolená terminálová verzia: pravidlá a prerušenia podľa migrácie 0022", () => {
    expect(terminal).toMatchObject({
      roundingMode: 0,
      windowStartMin: 0,
      windowEndMin: 1440,
      fullDayObstacleMin: 1440,
      lunchRecordedMode: 0,
      unlabeledOutIsLunch: true,
      duplicateWindowMin: 0,
      autoRepairMode: 0,
    });
    expect(terminal.interruptions?.get("WORK")).toMatchObject({ number: 1, calc: "WORK" });
    expect(terminal.interruptions?.get("DOCTOR")).toMatchObject({
      number: 2,
      calc: "COUNTED",
      autoEndOfShift: true,
    });
    expect(terminal.interruptions?.get("TRIP")).toMatchObject({
      number: 12,
      countsToLunchBase: true,
    });
    expect(terminal.interruptions?.get("PRIV")).toMatchObject({
      number: 13,
      calc: "UNPAID",
      autoEndOfShift: false,
    });
    expect(terminal.interruptions?.get("LEAVE")).toMatchObject({ number: 8, fullDayOnly: true });
  });
  it("predvolená terminálová verzia počíta ako dnešný terminál (obed, prah, doplnenie sa nerobí)", () => {
    const base = computeDay(day([IN("07:00"), OUT("15:30")]), terminal);
    expect(base.workMin).toBe(480);
    expect(base.balanceMin).toBe(30);
    const doctor = computeDay(day([IN("07:00"), p("DOCTOR", "OUT", "10:00")]), terminal);
    expect(doctor.open).toBe(true); // auto_repair_mode 0: doplnenie do fondu vypnuté
  });
  it("verzia z Accessu: okno, prah celého dňa, duplicita, razený obed a zaokrúhlenie z pravidiel", () => {
    expect(access).toMatchObject({
      windowStartMin: 360,
      windowEndMin: 1020,
      fullDayObstacleMin: 360,
      duplicateWindowMin: 10,
      lunchRecordedMode: 1,
      lunchMinMin: 30,
      roundInMin: 5,
      roundOutMin: 5,
      roundingMode: 0,
    });
    expect(access.interruptions?.get("DOCTOR")).toMatchObject({ number: 2, fullDayMin: 300 });
    expect(access.regimes.get(1)?.rules).toMatchObject({ auto_lunch_enabled: false });
  });
  it("model bez mapy kódov nechá vstavané kódy a režimy prázdne", () => {
    const c = parseSettingsForMonth(forMonthResponse("terminal")).config as Record<string, unknown>;
    const { terminal_code_map: _drop, ...rest } = c;
    const s = engineInputs(rest as unknown as Parameters<typeof engineInputs>[0]);
    expect(s.interruptions).toBeUndefined();
    const r = computeDay(
      day([IN("07:00"), p("DOCTOR", "OUT", "10:00"), IN("11:00"), OUT("15:00")]),
      s,
    );
    expect(r.creditMin).toBe(60);
  });
  it("kód z mapy, ktorého prerušenie model nemá, sa nepočíta a deň je nepotvrdený", () => {
    const c = parseSettingsForMonth(forMonthResponse("terminal")).config as unknown as Record<
      string,
      unknown
    >;
    const map = (c["terminal_code_map"] as { code: string; interruption: number }[]).concat([
      { code: "NOVY", interruption: 77 },
    ]);
    const s = engineInputs({ ...c, terminal_code_map: map } as unknown as Parameters<
      typeof engineInputs
    >[0]);
    const r = computeDay(
      day([IN("07:00"), p("NOVY", "OUT", "10:00"), IN("11:00"), OUT("15:00")]),
      s,
    );
    expect(r.unconfirmed).toBe("unknown_code");
  });
  it("režim Accessu sa dá použiť na deň: krízový režim vypne obed a započíta súkromné prerušenie", () => {
    const regime = access.regimes.get(1);
    const r = computeDay(
      day([IN("07:00"), p("PRIV", "OUT", "10:00"), IN("11:00"), OUT("15:30")], {
        regime: regime ?? null,
      }),
      { ...access, windowStartMin: 0, windowEndMin: 1440, roundInMin: 0, roundOutMin: 0 },
    );
    expect(r.breakMin).toBe(0);
    expect(r.creditMin).toBe(60);
    expect(r.privMin).toBe(0);
  });
});
