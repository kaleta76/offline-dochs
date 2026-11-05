// Testy kontroly súboru z Accessu. Zlatý súbor contract/examples/config_example.json generuje a overuje strana Access
// (contract/tools/verify_config.py); ak niektorý test padne, kontrakt sa zmenil alebo sa kontrola v aplikácii rozišla s Pythonom.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  checkAccessConfig,
  countEmployees,
  countMonths,
  describeImportResult,
  formatConfigVersion,
  formatMonth,
  parseConfigText,
  parseCurrentConfig,
  parseImportResult,
} from "./access-config";

const goldenText = readFileSync(
  join(
    dirname(fileURLToPath(import.meta.url)),
    "..",
    "..",
    "contract",
    "examples",
    "config_example.json",
  ),
  "utf8",
);
// Pevný „teraz“, aby test nezávisel od dátumu spustenia (zlatý súbor je z 4. 11. 2026).
const NOW = new Date(Date.UTC(2026, 10, 5, 8, 0));

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Doc = any; // zlatý súbor sa v testoch mení bez typovej kontroly
const golden = (): Doc => JSON.parse(goldenText) as Doc;
const check = (d: unknown, strict = false) => checkAccessConfig(d, NOW, strict);
const emp = (d: Doc, pn: string) => d.employees.find((e: Doc) => e.personnel_number === pn);
const mon = (d: Doc, pn: string, m: string) => emp(d, pn).months.find((x: Doc) => x.month === m);

/** Zmení zlatý súbor a vráti text prvej chyby (alebo null, ak chyba nevznikla). */
function firstError(mutate: (d: Doc) => void, strict = false): string | null {
  const d = golden();
  mutate(d);
  const r = check(d, strict);
  return r.errors[0] ?? null;
}
const rejects = (mutate: (d: Doc) => void, part?: string, strict = false) => {
  const e = firstError(mutate, strict);
  expect(e, "očakávala sa chyba").not.toBeNull();
  if (part) expect(e).toContain(part);
};

describe("zlatý súbor", () => {
  it("prejde bez chýb a bez upozornení a vráti súhrn", () => {
    const r = check(golden());
    expect(r.errors).toEqual([]);
    expect(r.warnings).toEqual([]);
    expect(r.summary).toEqual({
      configVersion: "2026.11.04.1200",
      periodFrom: "2026-10",
      periodTo: "2026-11",
      employees: 4,
      employeeMonths: 8,
    });
  });

  it("prejde aj v prísnom režime", () => {
    expect(check(golden(), true).errors).toEqual([]);
  });

  it("kontrola dokument nemení", () => {
    const d = golden();
    const before = JSON.stringify(d);
    check(d);
    expect(JSON.stringify(d)).toBe(before);
  });

  it("súbor s BOM sa dá načítať", () => {
    const r = parseConfigText("﻿" + goldenText);
    expect("doc" in r && check(r.doc).errors).toEqual([]);
  });

  it("pokazený JSON dá zrozumiteľnú chybu", () => {
    const r = parseConfigText(goldenText.slice(0, 200));
    expect("error" in r && r.error).toContain("JSON");
  });
});

describe("hlavička a kľúče", () => {
  it("koreň nie je objekt", () => {
    for (const bad of [null, [], "x", 1, true]) expect(check(bad).errors.length).toBeGreaterThan(0);
  });
  it("starý formát (verzia 1) sa odmietne s vysvetlením", () => {
    rejects((d) => (d.schema_version = 1), "schema_version musí byť 2");
    rejects((d) => (d.schema_version = "2"), "schema_version musí byť 2");
  });
  it("chýbajúci a neznámy kľúč", () => {
    rejects((d) => delete d.rules, "chýba kľúč 'rules'");
    rejects((d) => delete d.counts, "chýba kľúč 'counts'");
    rejects((d) => (d.evil = 1), "neznámy kľúč");
  });
  it("generated_at je nepovinný, ale ak je, musí byť krátky text", () => {
    const d = golden();
    delete d.generated_at;
    expect(check(d).errors).toEqual([]);
    for (const v of [1, null, ["x"], "x".repeat(41)])
      rejects((x) => (x.generated_at = v), "generated_at");
  });
  it("neplatná verzia", () => {
    for (const v of [
      "2026-11-04",
      20261104,
      "2026.13.04.1200",
      "2026.11.32.1200",
      "2026.11.04.2400",
      "2026.11.04.1260",
      "1999.01.01.0000",
      "2026.02.31.1200",
      null,
    ]) {
      rejects((d) => (d.config_version = v), "config_version");
    }
  });
  it("verzia z budúcnosti sa odmietne (zle nastavený čas v počítači s Accessom)", () => {
    rejects((d) => (d.config_version = "2026.11.09.1200"), "v budúcnosti");
    const d = golden();
    d.config_version = "2026.11.06.1200";
    expect(check(d).errors).toEqual([]);
  });
  it("rok", () => {
    for (const v of ["2026", -1, 1.5, 12345678, 1999, 2100, null])
      rejects((d) => (d.rok = v), "rok");
  });
});

describe("pravidlá a prerušenia", () => {
  it("chýbajúce a nesprávne pravidlo", () => {
    rejects((d) => delete d.rules.auto_repair_mode, "auto_repair_mode");
    rejects((d) => (d.rules.auto_lunch_enabled = 1), "auto_lunch_enabled");
    rejects((d) => (d.rules.work_window_start_min = "360"), "work_window_start_min");
    rejects((d) => (d.rules.default_daily_fund_min = 1.5), "default_daily_fund_min");
    rejects((d) => (d.rules.default_daily_fund_min = 1441), "default_daily_fund_min");
    rejects((d) => (d.rules.interruption_check_enabled = 1), "interruption_check_enabled");
    rejects((d) => (d.rules.extra = "x"), "rules.extra");
  });
  it("okno práce musí mať koniec po začiatku", () => {
    rejects((d) => (d.rules.work_window_end_min = d.rules.work_window_start_min), "okna práce");
  });
  it("prerušenie 1 je povinné a calc WORK/LUNCH patrí len 1 a 7", () => {
    rejects((d) => (d.interruptions = d.interruptions.filter((i: Doc) => i.code !== 1)), "č. 1");
    rejects((d) => (d.interruptions.find((i: Doc) => i.code === 2).calc = "WORK"), "WORK patrí");
    rejects((d) => (d.interruptions.find((i: Doc) => i.code === 2).calc = "LUNCH"), "LUNCH patrí");
    rejects((d) => (d.interruptions.find((i: Doc) => i.code === 1).calc = "COUNTED"), "WORK patrí");
    rejects(
      (d) => (d.interruptions.find((i: Doc) => i.code === 7).calc = "COUNTED"),
      "LUNCH patrí",
    );
  });
  it("neznámy spôsob počítania", () => {
    rejects((d) => (d.interruptions.find((i: Doc) => i.code === 2).calc = "PRIV"), "calc 'PRIV'");
    rejects((d) => (d.interruptions.find((i: Doc) => i.code === 2).calc = null), "calc");
  });
  it("duplicitné a nepovolené položky prerušenia", () => {
    rejects((d) => d.interruptions.push({ ...d.interruptions[1] }), "dvakrát");
    rejects((d) => (d.interruptions[1].tajne = 1), "neznámy kľúč");
    rejects((d) => (d.interruptions[1].is_work = true), "is_work");
    rejects((d) => (d.interruptions[1].name = "x".repeat(201)), "name");
  });
});

describe("tlačidlá terminálu (kontrakt 1.3.0)", () => {
  const it_ = (d: Doc, code: number): Doc => d.interruptions.find((i: Doc) => i.code === code);
  /** Niektorá z chýb obsahuje text (pri viacerých chybách nezáleží na poradí). */
  const hasError = (mutate: (d: Doc) => void, part: string) => {
    const d = golden();
    mutate(d);
    const errs = check(d).errors;
    expect(
      errs.some((e) => e.includes(part)),
      `hľadané '${part}' nie je v ${JSON.stringify(errs)}`,
    ).toBe(true);
  };

  it("zlatý súbor má štyri tlačidlá v poradí Lekár, Sprievod, Služobná cesta, Služobné vzdialenie", () => {
    const d = golden();
    expect(check(d, true).errors).toEqual([]);
    const labels = (d.interruptions as Doc[])
      .filter((i) => i.terminal_button)
      .sort((a, b) => a.terminal_order - b.terminal_order)
      .map((i) => i.terminal_label);
    expect(labels).toEqual(["Lekár", "Sprievod", "Služobná cesta", "Služobné vzdialenie"]);
  });
  it("súbor bez tlačidiel je stále platný", () => {
    const d = golden();
    for (const i of d.interruptions as Doc[]) {
      delete i.terminal_button;
      delete i.terminal_label;
      delete i.terminal_order;
      delete i.terminal_icon; // ikona (1.4.0) patrí k tlačidlu, preto sa s ním odoberá
    }
    const r = check(d, true);
    expect(r.errors).toEqual([]);
    expect(r.warnings).toEqual([]);
  });
  it("príznak nie je pravdivostná hodnota", () => {
    hasError((d) => (it_(d, 2).terminal_button = "ano"), "terminal_button nie je true/false");
  });
  it("text tlačidla: prázdny, dlhý, s medzerami na kraji, so zlým typom", () => {
    for (const zly of ["", "x".repeat(25), " Lekár", "Lekár ", "Le\tkár", 5]) {
      hasError((d) => (it_(d, 2).terminal_label = zly), "terminal_label musí byť text 1 až 24 znakov");
    }
  });
  it("poradie mimo rozsahu alebo zlého typu", () => {
    for (const zle of [0, 100, "1", true, 1.5]) {
      hasError((d) => (it_(d, 2).terminal_order = zle), "terminal_order musí byť celé číslo 1 až 99");
    }
  });
  it("text a poradie patria len prerušeniu s tlačidlom", () => {
    hasError((d) => (it_(d, 8).terminal_label = "Dovolenka"), "patria len prerušeniu s terminal_button = true");
    hasError((d) => (it_(d, 8).terminal_order = 5), "patria len prerušeniu s terminal_button = true");
    hasError(
      (d) => {
        it_(d, 2).terminal_button = false;
      },
      "patria len prerušeniu s terminal_button = true",
    );
  });
  it("práca nemá vlastné tlačidlo", () => {
    rejects((d) => (it_(d, 1).terminal_button = true), "práca (č. 1) nemá vlastné tlačidlo");
  });
  it("obed smie mať tlačidlo (odchod s kódom LUNCH)", () => {
    const d = golden();
    d.terminal_code_map.push({ code: "LUNCH", interruption: 7 });
    Object.assign(it_(d, 7), { terminal_button: true, terminal_label: "Obed", terminal_order: 1 });
    expect(check(d).errors).toEqual([]);
  });
  it("obed s tlačidlom potrebuje práve jeden kód terminála", () => {
    rejects(
      (d) => (it_(d, 7).terminal_button = true),
      "prerušenie 7: tlačidlo potrebuje práve jeden kód v terminal_code_map (je ich 0)",
    );
  });
  it("tlačidlo potrebuje práve jeden kód terminála", () => {
    hasError(
      (d) => (d.terminal_code_map = d.terminal_code_map.filter((m: Doc) => m.code !== "ERRAND")),
      "prerušenie 4: tlačidlo potrebuje práve jeden kód v terminal_code_map (je ich 0)",
    );
    hasError(
      (d) => d.terminal_code_map.push({ code: "ERRAND2", interruption: 4 }),
      "prerušenie 4: tlačidlo potrebuje práve jeden kód v terminal_code_map (je ich 2)",
    );
  });
  it("dve tlačidlá s rovnakým textom (bez ohľadu na veľkosť písmen); bez textu platí názov", () => {
    hasError((d) => (it_(d, 4).terminal_label = "LEKÁR"), "majú tlačidlo s rovnakým textom");
    hasError((d) => {
      delete it_(d, 4).terminal_label;
      delete it_(d, 4).terminal_order;
      it_(d, 12).terminal_label = "Služobné vzdialenie";
    }, "majú tlačidlo s rovnakým textom");
    const d = golden();
    delete it_(d, 4).terminal_label; // text tlačidla je potom name „Služobné vzdialenie“
    expect(check(d).errors).toEqual([]);
  });
  it("najviac 12 tlačidiel", () => {
    hasError((d) => {
      for (let n = 20; n < 33; n++) {
        d.interruptions.push({
          code: n,
          name: `Iné ${n}`,
          short_name: `I${n}`,
          start_punch_code: 0,
          end_punch_code: 0,
          is_work: false,
          is_lunch: false,
          auto_end_of_shift: false,
          calc: "COUNTED",
          terminal_button: true,
          terminal_label: `Iné ${n}`,
          terminal_order: 50,
        });
        d.terminal_code_map.push({ code: `X${n}`, interruption: n });
      }
    }, "tlačidiel pre terminál je 17, najviac 12");
  });
});

describe("voliteľné kľúče kontraktu 1.4.0", () => {
  const it_ = (d: Doc, code: number): Doc => d.interruptions.find((i: Doc) => i.code === code);
  const NOVE_PRAVIDLA = [
    "lunch_recorded_mode",
    "lunch_min_min",
    "unlabeled_out_is_lunch",
    "rounding_in_min",
    "rounding_out_min",
    "rounding_mode",
    "auto_repair_target",
    "auto_repair_cases",
    "correction_deadline_day",
    "early_return_ends_interruption",
  ];
  const NOVE_PRIZNAKY = ["terminal_icon", "terminal_request", "needs_approval", "full_day_only"];
  const hasError = (mutate: (d: Doc) => void, part: string, strict = false) => {
    const d = golden();
    mutate(d);
    const errs = check(d, strict).errors;
    expect(
      errs.some((e) => e.includes(part)),
      `hľadané '${part}' nie je v ${JSON.stringify(errs)}`,
    ).toBe(true);
  };

  it("súbor bez nových kľúčov je stále platný (spätná kompatibilita s 1.3.0)", () => {
    const d = golden();
    for (const k of NOVE_PRAVIDLA) delete d.rules[k];
    for (const i of d.interruptions as Doc[]) {
      for (const k of NOVE_PRIZNAKY) delete i[k];
      if (i.calc === "UNPAID") i.calc = "COUNTED";
    }
    for (const e of d.employees as Doc[])
      for (const m of e.months as Doc[]) {
        delete m.window_start_min;
        delete m.window_end_min;
      }
    const r = check(d, true);
    expect(r.errors).toEqual([]);
    expect(r.warnings).toEqual([]);
  });
  it("zlatý súbor používa všetky nové kľúče", () => {
    const d = golden();
    for (const k of NOVE_PRAVIDLA) expect(d.rules).toHaveProperty(k);
    const pouzite = new Set((d.interruptions as Doc[]).flatMap((i) => Object.keys(i)));
    for (const k of NOVE_PRIZNAKY) expect(pouzite.has(k)).toBe(true);
    expect((d.interruptions as Doc[]).some((i) => i.calc === "UNPAID")).toBe(true);
  });

  describe("pravidlá", () => {
    it("mimo rozsahu alebo zlého typu", () => {
      const zle: Record<string, unknown[]> = {
        lunch_recorded_mode: [3, -1, "1", true, 1.5],
        lunch_min_min: [601, -1, "30"],
        rounding_in_min: [61, -1, "5"],
        rounding_out_min: [61, -1, false],
        rounding_mode: [4, -1, "0"],
        auto_repair_target: [2, -1, true],
        auto_repair_cases: [0, 4, "3"],
        correction_deadline_day: [32, -1, "5"],
      };
      for (const [k, hodnoty] of Object.entries(zle))
        for (const v of hodnoty)
          hasError((d) => (d.rules[k] = v), `rules.${k} musí byť celé číslo`);
    });
    it("hranice rozsahov sú platné", () => {
      const horne = {
        lunch_recorded_mode: 2,
        lunch_min_min: 600,
        rounding_in_min: 60,
        rounding_out_min: 60,
        rounding_mode: 3,
        auto_repair_target: 1,
        auto_repair_cases: 1,
        correction_deadline_day: 31,
      };
      const dolne = {
        lunch_recorded_mode: 0,
        rounding_in_min: 0,
        rounding_out_min: 0,
        rounding_mode: 0,
        auto_repair_target: 0,
        auto_repair_cases: 3,
        correction_deadline_day: 0,
      };
      for (const hodnoty of [horne, dolne]) {
        const d = golden();
        if (hodnoty === dolne) delete d.rules.lunch_min_min;
        Object.assign(d.rules, hodnoty);
        const r = check(d, true);
        expect(r.errors).toEqual([]);
      }
    });
    it("pravdivostné pravidlo nie je číslo ani text", () => {
      for (const k of [
        "unlabeled_out_is_lunch",
        "early_return_ends_interruption",
        "interruption_check_enabled",
      ])
        for (const v of ["ano", 1, 0])
          hasError((d) => (d.rules[k] = v), `rules.${k} nie je true/false`);
    });
    it("minúty obeda bez režimu 1 alebo 2 sú upozornenie a v prísnom režime chyba", () => {
      const d = golden();
      d.rules.lunch_recorded_mode = 0;
      const r = check(d);
      expect(r.errors).toEqual([]);
      expect(r.warnings.some((w) => w.includes("lunch_min_min sa nepoužije"))).toBe(true);
      hasError((x) => (x.rules.lunch_recorded_mode = 0), "lunch_min_min sa nepoužije", true);
      delete d.rules.lunch_recorded_mode; // bez kľúča platí predvolené 0
      expect(check(d).warnings.some((w) => w.includes("lunch_min_min sa nepoužije"))).toBe(true);
    });
    it("neznámy kľúč pravidiel (preklep) je upozornenie a v prísnom režime chyba", () => {
      const d = golden();
      d.rules.rounding_in_mn = 5;
      const r = check(d);
      expect(r.errors).toEqual([]);
      expect(r.warnings.some((w) => w.includes("neznámy kľúč 'rounding_in_mn'"))).toBe(true);
      hasError((x) => (x.rules.rounding_in_mn = 5), "neznámy kľúč 'rounding_in_mn'", true);
    });
  });

  describe("prerušenia", () => {
    it("nezapočítaný interval UNPAID je platný, ale nepatrí práci ani obedu", () => {
      expect(it_(golden(), 13).calc).toBe("UNPAID");
      expect(check(golden()).errors).toEqual([]);
      hasError((d) => (it_(d, 1).calc = "UNPAID"), "WORK patrí");
      hasError((d) => (it_(d, 7).calc = "UNPAID"), "LUNCH patrí");
    });
    it("ikony zlatého súboru", () => {
      const d = golden();
      const ikony = Object.fromEntries(
        (d.interruptions as Doc[]).filter((i) => "terminal_icon" in i).map((i) => [i.code, i.terminal_icon]),
      );
      expect(ikony).toEqual({ 2: "doctor", 4: "errand", 12: "trip", 16: "family" });
    });
    it("ikona zlého tvaru", () => {
      for (const zla of ["", "Doctor", "doctor\n", "d-r", "1abc", "x".repeat(21), 5, null])
        hasError(
          (d) => (it_(d, 2).terminal_icon = zla),
          "terminal_icon musí byť názov z malých písmen",
        );
    });
    it("neznáma ikona je upozornenie a v prísnom režime chyba", () => {
      const d = golden();
      it_(d, 2).terminal_icon = "rocket";
      const r = check(d);
      expect(r.errors).toEqual([]);
      expect(r.warnings.some((w) => w.includes("neznáma ikona 'rocket'"))).toBe(true);
      hasError((x) => (it_(x, 2).terminal_icon = "rocket"), "neznáma ikona 'rocket'", true);
    });
    it("ikona patrí len prerušeniu s tlačidlom", () => {
      hasError(
        (d) => (it_(d, 8).terminal_icon = "home"),
        "terminal_icon patrí len prerušeniu s terminal_button = true",
      );
    });
    it("príznaky nie sú pravdivostné hodnoty", () => {
      for (const k of ["terminal_request", "needs_approval", "full_day_only"])
        hasError((d) => (it_(d, 8)[k] = "ano"), `prerušenie 8: ${k} nie je true/false`);
    });
    it("práca (č. 1) nemá príznaky; false je neškodné", () => {
      for (const k of ["terminal_request", "needs_approval", "full_day_only"]) {
        hasError((d) => (it_(d, 1)[k] = true), `práca (č. 1) nemá kľúč ${k}`);
        const d = golden();
        it_(d, 1)[k] = false;
        expect(check(d).errors).toEqual([]);
      }
    });
    it("celodenné prerušenie nemá tlačidlo", () => {
      hasError(
        (d) => (it_(d, 2).full_day_only = true),
        "prerušenie 2: full_day_only a terminal_button sa vylučujú",
      );
    });
    it("žiadosť a schvaľovanie nezávisia od tlačidla", () => {
      const d = golden();
      expect(it_(d, 12)).toMatchObject({
        terminal_button: true,
        terminal_request: true,
        needs_approval: true,
      });
      expect(it_(d, 8).terminal_button).toBeUndefined();
      expect(check(d).errors).toEqual([]);
    });
  });

  describe("okno práce v mesiaci", () => {
    const mon_ = (d: Doc, pn: string, m: string): Doc =>
      d.employees
        .find((e: Doc) => e.personnel_number === pn)
        .months.find((x: Doc) => x.month === m);

    it("okno má len zamestnanec s fondom, ktorý okno určuje", () => {
      const d = golden();
      for (const [pn, ma] of [
        ["9000004", true],
        ["9000001", false],
        ["9000002", false],
        ["9000003", false],
      ] as const)
        for (const m of ["2026-10", "2026-11"]) {
          const x = mon_(d, pn, m);
          expect("window_start_min" in x, `${pn} ${m}`).toBe(ma);
          expect("window_end_min" in x, `${pn} ${m}`).toBe(ma);
        }
      expect(mon_(d, "9000004", "2026-11")).toMatchObject({
        window_start_min: 420,
        window_end_min: 960,
      });
    });
    it("vždy obe hodnoty spolu", () => {
      hasError(
        (d) => delete mon_(d, "9000004", "2026-10").window_end_min,
        "window_start_min a window_end_min musia byť spolu",
      );
      hasError(
        (d) => (mon_(d, "9000001", "2026-10").window_end_min = 1020),
        "window_start_min a window_end_min musia byť spolu",
      );
    });
    it("mimo rozsahu alebo zlého typu", () => {
      for (const zle of [-1, 1441, "420", true, 420.5, null])
        hasError(
          (d) => (mon_(d, "9000004", "2026-10").window_start_min = zle),
          "musia byť celé čísla 0 až 1440",
        );
    });
    it("koniec okna nie je po začiatku", () => {
      for (const [a, b] of [
        [960, 960],
        [960, 420],
      ])
        hasError((d) => {
          const m = mon_(d, "9000004", "2026-10");
          m.window_start_min = a;
          m.window_end_min = b;
        }, "koniec okna práce nie je po začiatku");
    });
    it("okno na celý deň (0 až 1440) je platné", () => {
      const d = golden();
      const m = mon_(d, "9000001", "2026-10");
      m.window_start_min = 0;
      m.window_end_min = 1440;
      expect(check(d).errors).toEqual([]);
    });
    it("iný kľúč v mesiaci ostáva zakázaný", () => {
      hasError((d) => (mon_(d, "9000001", "2026-10").window_start = 420), "nepovolené kľúče");
    });
  });
});

describe("kódy razení, mapovanie, sviatky", () => {
  it("kód razenia odkazuje na neexistujúce prerušenie", () => {
    rejects((d) => (d.punch_codes[0].interruption = 99), "neexistujúce prerušenie 99");
  });
  it("duplicitný kód razenia a zlý smer", () => {
    rejects((d) => d.punch_codes.push({ ...d.punch_codes[0] }), "dvakrát");
    rejects((d) => (d.punch_codes[0].direction = "X"), "direction");
  });
  it("mapovanie kódov terminála", () => {
    rejects((d) => (d.terminal_code_map[1].interruption = 99), "neexistujúce prerušenie");
    rejects((d) => d.terminal_code_map.push({ ...d.terminal_code_map[0] }), "dvakrát");
    rejects((d) => (d.terminal_code_map[0].code = "work"), "kód musí byť");
  });
  it("neplatný a duplicitný sviatok", () => {
    rejects((d) => (d.holidays[0].date = "2026-02-30"), "neplatný dátum");
    rejects((d) => (d.holidays[0].date = "26-1-1"), "neplatný dátum");
    rejects((d) => d.holidays.push({ ...d.holidays[0] }), "dvakrát");
  });
});

describe("okno, fondy, šablóny", () => {
  it("okno period", () => {
    rejects((d) => (d.period.from_month = "2026-13"), "rrrr-mm");
    rejects((d) => (d.period.to_month = "2026-09"), "koniec je pred začiatkom");
    rejects((d) => (d.period.to_month = "2027-12"), "najviac 14");
  });
  it("fond a šablóna", () => {
    rejects((d) => d.funds.push({ ...d.funds[0] }), "dvakrát");
    rejects((d) => (d.funds[0].type = 10), "fond");
    rejects((d) => d.templates.push({ ...d.templates[0] }), "dvakrát");
  });
  it("pravidlá v šablóne", () => {
    rejects(
      (d) => (d.templates[0].months[0].rules[0].interruption = 99),
      "neexistujúce prerušenie",
    );
    rejects((d) => (d.templates[0].months[0].rules[0].max_duration_min = [1, 2, 3]), "7 čísel");
    rejects((d) => (d.templates[0].months[0].rules[0].allowed_to_min[0] = 1441), "7 čísel");
    rejects((d) => (d.templates[0].months[0].rules[0].disabled = 0), "disabled");
    rejects((d) => (d.templates[0].months[0].rules[0].min_duration_min = -1), "min_duration_min");
    rejects((d) => (d.templates[0].months[0].rules[0].extra = 1), "pravidlo musí mať");
    rejects(
      (d) => d.templates[0].months[0].rules.push({ ...d.templates[0].months[0].rules[0] }),
      "dve pravidlá",
    );
  });
  it("mesiac šablóny mimo okna alebo dvakrát", () => {
    rejects((d) => (d.templates[0].months[0].month = "2027-01"), "mimo okna");
    rejects((d) => d.templates[0].months.push({ ...d.templates[0].months[0] }), "dvakrát");
  });
});

describe("zamestnanci a mesačné plány", () => {
  const pn = "9000001";
  it("osobné údaje v súbore sa odmietnu", () => {
    rejects((d) => (emp(d, pn).name = "Ján Novák"), "osobné údaje");
    rejects((d) => (emp(d, pn).email = "x@y.sk"), "osobné údaje");
    rejects((d) => (mon(d, pn, "2026-10").poznamka = "x"), "osobné údaje");
  });
  it("neplatné a duplicitné osobné číslo", () => {
    for (const v of ["", "a b", "x".repeat(21), 123, null, "9000001;"])
      rejects((d) => (emp(d, pn).personnel_number = v), "osobné číslo");
    rejects((d) => (d.employees[1].personnel_number = pn), "dvakrát");
  });
  it("neúplné počty (useknutý prenos)", () => {
    rejects((d) => (d.counts.employees = 3), "counts.employees");
    rejects((d) => (d.counts.employee_months = 7), "counts.employee_months");
    rejects((d) => d.employees.pop(), "counts.employees");
  });
  it("zlý počet dní", () => {
    rejects((d) => mon(d, pn, "2026-10").day_types.pop(), "31 dní");
    rejects((d) => mon(d, pn, "2026-11").expected_min.push(0), "30 dní");
  });
  it("typ dňa nesedí s dňom v týždni", () => {
    // 3. 10. 2026 je sobota
    rejects((d) => (mon(d, pn, "2026-10").day_types[2] = "PP"), "nesedí s dňom v týždni");
    // 4. 10. 2026 je nedeľa
    rejects((d) => (mon(d, pn, "2026-10").day_types[3] = "VV"), "nesedí s dňom v týždni");
    rejects((d) => (mon(d, pn, "2026-10").day_types[0] = "PN"), "nesedí s dňom v týždni");
  });
  it("neplatný typ dňa", () => {
    for (const v of ["XP", "PX", "P", "PPP", "", null, 5])
      rejects((d) => (mon(d, pn, "2026-10").day_types[0] = v), "typ dňa");
  });
  it("sviatok z číselníka musí mať typ dňa začínajúci S", () => {
    // 17. 11. 2026 (utorok) je sviatok
    rejects((d) => {
      const m = mon(d, pn, "2026-11");
      m.day_types[16] = "PP";
    }, "sviatok");
  });
  it("fond v nepracovný deň a chybný fond", () => {
    // 3. 10. 2026 (sobota, typ VV)
    rejects((d) => (mon(d, pn, "2026-10").expected_min[2] = 60), "nie je pracovný");
    rejects((d) => (mon(d, pn, "2026-10").expected_min[0] = 1441), "mimo 0 až 1440");
    rejects((d) => (mon(d, pn, "2026-10").expected_min[0] = 450.5), "mimo 0 až 1440");
    rejects((d) => (mon(d, pn, "2026-10").expected_min[0] = "450"), "mimo 0 až 1440");
  });
  it("pracovný deň s nulovým fondom je upozornenie, v prísnom režime chyba", () => {
    const d = golden();
    mon(d, pn, "2026-10").expected_min[0] = 0; // 1. 10. 2026 (štvrtok)
    const r = check(d);
    expect(r.errors).toEqual([]);
    expect(r.warnings.some((w) => w.includes("nulovým fondom"))).toBe(true);
    expect(r.summary).not.toBeNull();
    const s = check(d, true);
    expect(s.errors.some((e) => e.includes("nulovým fondom"))).toBe(true);
    expect(s.summary).toBeNull();
  });
  it("mesiac mimo okna a duplicitný mesiac", () => {
    rejects((d) => (mon(d, pn, "2026-10").month = "2027-05"), "mimo okna");
    rejects((d) => emp(d, pn).months.push({ ...mon(d, pn, "2026-10") }), "dvakrát");
  });
  it("neexistujúci fond a šablóna, rozsah úväzku", () => {
    rejects((d) => (mon(d, pn, "2026-10").fund_id = 99), "neexistujúci fond");
    rejects((d) => (mon(d, pn, "2026-10").template_id = 99), "neexistujúca šablóna");
    for (const v of [0, 201, 50.5, "100", null])
      rejects((d) => (mon(d, pn, "2026-10").employment_pct = v), "employment_pct");
    rejects((d) => (mon(d, pn, "2026-10").calendar_id = 0), "calendar_id");
  });
  it("chýbajúci kľúč v mesiaci", () => {
    rejects((d) => delete mon(d, pn, "2026-10").fund_id, "chýbajú kľúče");
  });
  it("súbor bez zamestnancov je upozornenie", () => {
    const d = golden();
    d.employees = [];
    d.counts = { employees: 0, employee_months: 0 };
    const r = check(d);
    expect(r.errors).toEqual([]);
    expect(r.warnings.length).toBeGreaterThan(0);
  });
});

describe("odpovede databázy", () => {
  const raw = {
    status: "preview",
    dry_run: true,
    config_version: "2026.11.04.1200",
    previous_version: null,
    period_from: "2026-10-01",
    period_to: "2026-11-01",
    employees: 4,
    employee_months: 8,
    removed_months: 0,
    without_account_count: 3,
    without_account: ["9000001", "9000002", 5],
  };
  it("rozparsuje náhľad", () => {
    expect(parseImportResult(raw)).toEqual({
      status: "preview",
      dryRun: true,
      configVersion: "2026.11.04.1200",
      previousVersion: null,
      periodFrom: "2026-10",
      periodTo: "2026-11",
      employees: 4,
      employeeMonths: 8,
      removedMonths: 0,
      withoutAccountCount: 3,
      withoutAccount: ["9000001", "9000002"],
    });
  });
  it("neznámy tvar je null, nikdy vymyslené čísla", () => {
    for (const v of [
      null,
      "x",
      [],
      {},
      { status: "ok", config_version: "x" },
      { status: "preview" },
    ])
      expect(parseImportResult(v)).toBeNull();
  });
  it("záporné a nečíselné počty sa berú ako 0", () => {
    const r = parseImportResult({
      ...raw,
      employees: -5,
      employee_months: "8",
      removed_months: NaN,
    });
    expect(r?.employees).toBe(0);
    expect(r?.employeeMonths).toBe(0);
    expect(r?.removedMonths).toBe(0);
  });
  it("aktuálna konfigurácia z tabuľky", () => {
    expect(
      parseCurrentConfig({
        config_version: "2026.11.04.1200",
        period_from: "2026-10-01",
        period_to: "2026-11-01",
        employees_count: 4,
        employee_months_count: 8,
        imported_at: "2026-11-04T12:05:00+00:00",
      }),
    ).toEqual({
      configVersion: "2026.11.04.1200",
      periodFrom: "2026-10",
      periodTo: "2026-11",
      employees: 4,
      employeeMonths: 8,
      importedAt: "2026-11-04T12:05:00+00:00",
    });
    expect(parseCurrentConfig(null)).toBeNull();
    expect(parseCurrentConfig({ config_version: "x" })).toBeNull();
  });
  it("texty pre správcu", () => {
    expect(formatConfigVersion("2026.11.04.1200")).toBe("4. 11. 2026 12:00");
    expect(formatConfigVersion("zle")).toBe("zle");
    expect(formatMonth("2026-10")).toBe("10/2026");
    expect(countEmployees(1)).toBe("1 zamestnanec");
    expect(countEmployees(3)).toBe("3 zamestnanci");
    expect(countEmployees(5)).toBe("5 zamestnancov");
    expect(countMonths(2)).toBe("2 mesačné plány");
    const r = parseImportResult(raw)!;
    expect(describeImportResult(r)).toContain("Zatiaľ sa nič nezapísalo");
    expect(describeImportResult({ ...r, status: "imported", dryRun: false })).toContain(
      "Prijatá verzia 4. 11. 2026 12:00",
    );
    expect(describeImportResult({ ...r, status: "unchanged" })).toContain("už prijatá");
    expect(describeImportResult({ ...r, removedMonths: 2 })).toContain("2 mesačné plány");
  });
});
