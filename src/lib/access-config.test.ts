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
