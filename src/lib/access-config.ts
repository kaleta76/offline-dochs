// Konfigurácia a výpočtový plán z Accessu (kontrakt 1.2.0, contract/README.md, docs/KONFIGURACIA-Z-ACCESSU.md).
// Čistá logika obrazovky Správa → Konfigurácia z Accessu: kontrola súboru dochs_config.json a spracovanie odpovedí databázy. Nič sa tu nikam nezapisuje.
//
// Kontrola je prepis contract/tools/verify_config.py (zlatý súbor contract/examples/config_example.json a testy z neho vychádzajú).
// Databáza kontrolu opakuje a je rozhodujúca; kontrola v aplikácii existuje preto, aby správca videl všetky chyby naraz a pochopiteľne.
// Pár pravidiel je v databáze prísnejších než v Pythone (rok, text generated_at, dĺžky textov, verzia z budúcnosti), tu sú zrkadlené.

export const CALC_VALUES = ["WORK", "LUNCH", "COUNTED"] as const;
export const MAX_WINDOW_MONTHS = 14;
export const MAX_FILE_BYTES = 30_000_000;

const TOP_REQ = [
  "schema_version",
  "config_version",
  "rok",
  "rules",
  "interruptions",
  "punch_codes",
  "holidays",
  "period",
  "terminal_code_map",
  "funds",
  "templates",
  "employees",
  "counts",
];
const TOP_OPT = ["generated_at"];
const RULES_REQ = [
  "work_window_start_min",
  "work_window_end_min",
  "full_day_obstacle_min",
  "auto_lunch_trigger_min",
  "auto_lunch_deduct_min",
  "auto_lunch_enabled",
  "duplicate_punch_window_min",
  "default_daily_fund_min",
  "auto_repair_mode",
];
const INT_REQ = [
  "code",
  "name",
  "short_name",
  "start_punch_code",
  "end_punch_code",
  "is_work",
  "is_lunch",
  "auto_end_of_shift",
  "calc",
];
const INT_OPT = [
  "counts_to_fund",
  "counts_to_work",
  "deducts_leave",
  "terminal_button",
  "terminal_label",
  "terminal_order",
];
export const MAX_BUTTONS = 12;
export const MAX_LABEL = 24;
const PUNCH_KEYS = ["code", "interruption", "direction", "label"];
const EMP_KEYS = ["personnel_number", "months"];
const MON_KEYS = [
  "month",
  "employment_pct",
  "fund_id",
  "template_id",
  "calendar_id",
  "day_types",
  "expected_min",
];
const RULE_KEYS = [
  "interruption",
  "disabled",
  "allowed_from_min",
  "allowed_to_min",
  "max_duration_min",
  "min_duration_min",
  "min_worked_before_min",
];
const RE_MONTH = /^(\d{4})-(0[1-9]|1[0-2])$/;
const RE_VERSION = /^\d{4}\.\d{2}\.\d{2}\.\d{4}$/;
const RE_DAYTYPE = /^[PVS][PVN]$/;
const RE_PN = /^[0-9A-Za-z]{1,20}$/;
const RE_DATE = /^(\d{4})-(\d{2})-(\d{2})$/;
const MAX_TEXT = 200;

export interface ConfigSummary {
  configVersion: string;
  periodFrom: string;
  periodTo: string;
  employees: number;
  employeeMonths: number;
}

export interface ConfigCheck {
  errors: string[];
  warnings: string[];
  /** Vyplnené len ak súbor nemá chyby. */
  summary: ConfigSummary | null;
}

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
const isInt = (v: unknown): v is number => typeof v === "number" && Number.isInteger(v);
const isStr = (v: unknown): v is string => typeof v === "string";
const keysOf = (o: Obj) => Object.keys(o);

function parseMonth(s: unknown): [number, number] | null {
  const m = isStr(s) ? RE_MONTH.exec(s) : null;
  return m ? [Number(m[1]), Number(m[2])] : null;
}
const monthKey = (m: [number, number]) => m[0] * 12 + (m[1] - 1);
const daysInMonth = (y: number, m: number) => new Date(Date.UTC(y, m, 0)).getUTCDate();
/** ISO deň v týždni: 1 = pondelok … 7 = nedeľa. */
const isoWeekday = (y: number, m: number, d: number) =>
  new Date(Date.UTC(y, m - 1, d)).getUTCDay() || 7;

function parseDate(s: unknown): string | null {
  const m = isStr(s) ? RE_DATE.exec(s) : null;
  if (!m) return null;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  if (mo < 1 || mo > 12 || d < 1 || d > daysInMonth(y, mo)) return null;
  return s as string;
}

/** Verzia rrrr.mm.dd.hhmm ako miestny čas; null ak to nie je platný dátum a čas. */
function versionTime(v: string): number | null {
  const m = /^(\d{4})\.(\d{2})\.(\d{2})\.(\d{2})(\d{2})$/.exec(v);
  if (!m) return null;
  const [y, mo, d, h, mi] = [1, 2, 3, 4, 5].map((i) => Number(m[i]));
  if (y === undefined || mo === undefined || d === undefined || h === undefined || mi === undefined)
    return null;
  if (mo < 1 || mo > 12 || d < 1 || d > daysInMonth(y, mo) || h > 23 || mi > 59) return null;
  return Date.UTC(y, mo - 1, d, h, mi);
}

/** Kontrola súboru dochs_config.json (schéma 2). Dokument sa nemení. */
export function checkAccessConfig(
  doc: unknown,
  now: Date = new Date(),
  strict = false,
): ConfigCheck {
  const errors: string[] = [];
  const warnings: string[] = [];
  const E = (t: string) => errors.push(t);
  const W = (t: string) => warnings.push(t);
  const done = (): ConfigCheck => {
    if (strict) {
      errors.push(...warnings.map((w) => `(upozornenie ako chyba) ${w}`));
      warnings.length = 0;
    }
    return { errors, warnings, summary: null };
  };

  if (!isObj(doc)) return { errors: ["koreň súboru nie je objekt"], warnings, summary: null };
  if (doc["schema_version"] !== 2) {
    return {
      errors: [
        `schema_version musí byť 2 (je ${JSON.stringify(doc["schema_version"])}); súbor verzie 1 neobsahuje plán`,
      ],
      warnings,
      summary: null,
    };
  }
  for (const k of TOP_REQ) if (!(k in doc)) E(`chýba kľúč '${k}'`);
  for (const k of keysOf(doc))
    if (!TOP_REQ.includes(k) && !TOP_OPT.includes(k)) E(`neznámy kľúč najvyššej úrovne '${k}'`);
  if (errors.length) return done();

  const version = doc["config_version"];
  if (!(isStr(version) && RE_VERSION.test(version))) {
    E("config_version musí mať tvar rrrr.mm.dd.hhmm");
  } else {
    const t = versionTime(version);
    if (t === null || Number(version.slice(0, 4)) < 2020 || Number(version.slice(0, 4)) > 2099) {
      E("config_version nie je platný dátum a čas");
    } else if (t > now.getTime() + 2 * 24 * 3600 * 1000 + 2 * 3600 * 1000) {
      E(
        `config_version ${version} je v budúcnosti, skontrolujte dátum a čas v počítači s Accessom`,
      );
    }
  }
  if (!isInt(doc["rok"]) || doc["rok"] < 2000 || doc["rok"] > 2099)
    E("rok musí byť celé číslo 2000 až 2099");
  if ("generated_at" in doc && !(isStr(doc["generated_at"]) && doc["generated_at"].length <= 40))
    E("generated_at musí byť text najviac 40 znakov");

  // --- pravidlá
  const rules = doc["rules"];
  if (!isObj(rules)) {
    E("rules nie je objekt");
  } else {
    for (const k of RULES_REQ) {
      if (!(k in rules)) E(`rules: chýba '${k}'`);
      else if (k === "auto_lunch_enabled") {
        if (typeof rules[k] !== "boolean") E("rules.auto_lunch_enabled nie je true/false");
      } else if (!isInt(rules[k]) || (rules[k] as number) < 0 || (rules[k] as number) > 1440)
        E(`rules.${k} nie je celé číslo 0 až 1440`);
    }
    for (const [k, v] of Object.entries(rules))
      if (typeof v !== "number" && typeof v !== "boolean")
        E(`rules.${k}: smie obsahovať len čísla a hodnoty true/false`);
    if (
      "interruption_check_enabled" in rules &&
      typeof rules["interruption_check_enabled"] !== "boolean"
    )
      E("rules.interruption_check_enabled nie je true/false");
    if (isInt(rules["auto_lunch_deduct_min"]) && rules["auto_lunch_deduct_min"] > 600)
      E("rules.auto_lunch_deduct_min je najviac 600");
    if (isInt(rules["auto_repair_mode"]) && rules["auto_repair_mode"] > 9)
      E("rules.auto_repair_mode je najviac 9");
    if (
      isInt(rules["work_window_start_min"]) &&
      isInt(rules["work_window_end_min"]) &&
      rules["work_window_end_min"] <= rules["work_window_start_min"]
    ) {
      E("rules: koniec okna práce nie je po začiatku");
    }
    if (
      isInt(rules["full_day_obstacle_min"]) &&
      (rules["full_day_obstacle_min"] < 1 || rules["full_day_obstacle_min"] > 1440)
    )
      E("rules.full_day_obstacle_min mimo 1 až 1440");
  }

  // --- prerušenia
  const ints = new Map<number, Obj>();
  if (!Array.isArray(doc["interruptions"])) {
    E("interruptions nie je pole");
  } else {
    doc["interruptions"].forEach((it, i) => {
      if (!isObj(it)) {
        E(`interruptions[${i}] nie je objekt`);
        return;
      }
      for (const k of INT_REQ) if (!(k in it)) E(`interruptions[${i}]: chýba '${k}'`);
      for (const k of keysOf(it))
        if (!INT_REQ.includes(k) && !INT_OPT.includes(k))
          E(`interruptions[${i}]: neznámy kľúč '${k}'`);
      const c = it["code"];
      if (!isInt(c) || c < 1 || c > 9999) {
        E(`interruptions[${i}]: code nie je celé číslo 1 až 9999`);
        return;
      }
      if (ints.has(c)) E(`prerušenie ${c} je v zozname dvakrát`);
      ints.set(c, it);
      const calc = it["calc"];
      if (!(CALC_VALUES as readonly unknown[]).includes(calc))
        E(`prerušenie ${c}: calc '${String(calc)}' nepoznáme (povolené ${CALC_VALUES.join(", ")})`);
      if ((calc === "WORK") !== (c === 1))
        E(`prerušenie ${c}: calc WORK patrí práve prerušeniu č. 1`);
      if ((calc === "LUNCH") !== (c === 7))
        E(`prerušenie ${c}: calc LUNCH patrí práve prerušeniu č. 7`);
      if (it["is_work"] !== (c === 1) || it["is_lunch"] !== (c === 7))
        E(`prerušenie ${c}: is_work/is_lunch nesedí s číslom prerušenia`);
      for (const k of ["name", "short_name"])
        if (k in it && !(isStr(it[k]) && (it[k] as string).length <= MAX_TEXT))
          E(`prerušenie ${c}: ${k} musí byť text najviac ${MAX_TEXT} znakov`);
      for (const k of ["start_punch_code", "end_punch_code"])
        if (k in it && !(isInt(it[k]) && (it[k] as number) >= 0 && (it[k] as number) <= 999999))
          E(`prerušenie ${c}: ${k} nie je celé číslo 0 až 999999`);
      for (const k of [
        "is_work",
        "is_lunch",
        "auto_end_of_shift",
        "counts_to_fund",
        "counts_to_work",
        "deducts_leave",
        "terminal_button",
      ])
        if (k in it && typeof it[k] !== "boolean") E(`prerušenie ${c}: ${k} nie je true/false`);
      // tlačidlá terminálu (kontrakt 1.3.0)
      if ("terminal_label" in it) {
        const lab = it["terminal_label"];
        // eslint-disable-next-line no-control-regex
        if (!(isStr(lab) && lab.length >= 1 && lab.length <= MAX_LABEL && lab === lab.trim() && !/[\u0000-\u001f]/.test(lab)))
          E(`prerušenie ${c}: terminal_label musí byť text 1 až ${MAX_LABEL} znakov bez medzier na kraji`);
      }
      if (
        "terminal_order" in it &&
        !(isInt(it["terminal_order"]) && it["terminal_order"] >= 1 && it["terminal_order"] <= 99)
      )
        E(`prerušenie ${c}: terminal_order musí byť celé číslo 1 až 99`);
      if (it["terminal_button"] !== true && ("terminal_label" in it || "terminal_order" in it))
        E(`prerušenie ${c}: terminal_label a terminal_order patria len prerušeniu s terminal_button = true`);
    });
    if (!ints.has(1)) E("v zozname prerušení chýba č. 1 (pracovná doba)");
  }

  // --- kódy razení
  const pcodes = new Map<number, Obj>();
  if (!Array.isArray(doc["punch_codes"])) {
    E("punch_codes nie je pole");
  } else {
    doc["punch_codes"].forEach((pc, i) => {
      const c = isObj(pc) ? pc["code"] : undefined;
      if (!isInt(c) || c < 0 || c > 999999) {
        E(`punch_codes[${i}]: code nie je celé číslo`);
        return;
      }
      const o = pc as Obj;
      if (pcodes.has(c)) E(`kód razenia ${c} je v zozname dvakrát`);
      pcodes.set(c, o);
      if (keysOf(o).length !== PUNCH_KEYS.length || !PUNCH_KEYS.every((k) => k in o))
        E(`kód razenia ${c}: musí mať práve kľúče ${PUNCH_KEYS.join(", ")}`);
      if (!(o["direction"] === "Z" || o["direction"] === "K" || o["direction"] === ""))
        E(`kód razenia ${c}: direction musí byť Z, K alebo prázdne`);
      if ("label" in o && !(isStr(o["label"]) && o["label"].length <= MAX_TEXT))
        E(`kód razenia ${c}: label musí byť text najviac ${MAX_TEXT} znakov`);
      const n = o["interruption"];
      if (!isInt(n) || n < 0) {
        E(`kód razenia ${c}: interruption nie je celé číslo`);
      } else if (n > 0 && !ints.has(n)) {
        E(`kód razenia ${c} odkazuje na neexistujúce prerušenie ${n}`);
      } else if (n > 0) {
        const it = ints.get(n) as Obj;
        const want =
          o["direction"] === "Z"
            ? it["start_punch_code"]
            : o["direction"] === "K"
              ? it["end_punch_code"]
              : undefined;
        if (want !== undefined && want !== c)
          W(
            `kód razenia ${c}: smer ${String(o["direction"])} nezodpovedá kódu ${String(want)} v prerušení ${n}`,
          );
      }
    });
    for (const [c, it] of ints) {
      for (const k of ["start_punch_code", "end_punch_code"]) {
        const v = it[k];
        if (isInt(v) && v !== 0 && !pcodes.has(v))
          W(`prerušenie ${c}: ${k} ${v} nie je v zozname kódov razení`);
      }
    }
  }

  // --- mapovanie kódov terminála
  const seenCodes = new Set<string>();
  if (!Array.isArray(doc["terminal_code_map"])) {
    E("terminal_code_map nie je pole");
  } else {
    doc["terminal_code_map"].forEach((m, i) => {
      if (!isObj(m) || keysOf(m).length !== 2 || !("code" in m) || !("interruption" in m)) {
        E(`terminal_code_map[${i}]: musí mať práve kľúče code a interruption`);
        return;
      }
      if (!(isStr(m["code"]) && /^[A-Z][A-Z0-9_]{0,19}$/.test(m["code"])))
        E(`terminal_code_map[${i}]: kód musí byť z veľkých písmen, číslic a podčiarkovníka`);
      if (isStr(m["code"]) && seenCodes.has(m["code"]))
        E(`terminal_code_map: kód '${m["code"]}' je dvakrát`);
      if (isStr(m["code"])) seenCodes.add(m["code"]);
      if (!(isInt(m["interruption"]) && ints.has(m["interruption"])))
        E(
          `terminal_code_map: kód '${String(m["code"])}' odkazuje na neexistujúce prerušenie ${JSON.stringify(m["interruption"])}`,
        );
    });
    if (!seenCodes.has("WORK")) W("terminal_code_map: chýba kód WORK");
  }

  // --- tlačidlá terminálu (kontrakt 1.3.0): príznak patrí prerušeniu, ktoré má práve jeden kód terminálu
  const codesOf = new Map<number, number>();
  if (Array.isArray(doc["terminal_code_map"])) {
    for (const m of doc["terminal_code_map"])
      if (isObj(m) && isInt(m["interruption"]))
        codesOf.set(m["interruption"], (codesOf.get(m["interruption"]) ?? 0) + 1);
  }
  const seenText = new Map<string, number>();
  let buttons = 0;
  for (const [c, it] of ints) {
    if (it["terminal_button"] !== true) continue;
    buttons += 1;
    if (c === 1)
      E("prerušenie 1: práca (č. 1) nemá vlastné tlačidlo, terminál má Príchod a Odchod");
    const n = codesOf.get(c) ?? 0;
    if (n !== 1)
      E(`prerušenie ${c}: tlačidlo potrebuje práve jeden kód v terminal_code_map (je ich ${n})`);
    const text = isStr(it["terminal_label"]) ? it["terminal_label"] : it["name"];
    if (isStr(text)) {
      const key = text.toLowerCase();
      const first = seenText.get(key);
      if (first !== undefined)
        E(`prerušenia ${first} a ${c} majú tlačidlo s rovnakým textom '${text}'`);
      else seenText.set(key, c);
    }
  }
  if (buttons > MAX_BUTTONS) E(`tlačidiel pre terminál je ${buttons}, najviac ${MAX_BUTTONS}`);

  // --- sviatky
  const hol = new Set<string>();
  if (!Array.isArray(doc["holidays"])) {
    E("holidays nie je pole");
  } else {
    doc["holidays"].forEach((h, i) => {
      const d = isObj(h) ? parseDate(h["date"]) : null;
      if (!d) {
        E(`holidays[${i}]: neplatný dátum`);
        return;
      }
      if (
        keysOf(h as Obj).length !== 2 ||
        !isStr((h as Obj)["name"]) ||
        ((h as Obj)["name"] as string).length > MAX_TEXT
      )
        E(`holidays[${i}]: musí mať práve kľúče date a name (text najviac ${MAX_TEXT} znakov)`);
      if (hol.has(d)) E(`sviatok ${d} je v zozname dvakrát`);
      hol.add(d);
    });
  }

  // --- okno
  const per = doc["period"];
  const pf = isObj(per) ? parseMonth(per["from_month"]) : null;
  const pt = isObj(per) ? parseMonth(per["to_month"]) : null;
  if (!pf || !pt) {
    E("period.from_month / to_month musia mať tvar rrrr-mm");
    return done();
  }
  if (monthKey(pt) < monthKey(pf)) {
    E("period: koniec je pred začiatkom");
    return done();
  }
  const windowLen = monthKey(pt) - monthKey(pf) + 1;
  if (windowLen > MAX_WINDOW_MONTHS)
    E(`okno period má ${windowLen} mesiacov, najviac ${MAX_WINDOW_MONTHS}`);
  const inWindow = (m: [number, number]) =>
    monthKey(m) >= monthKey(pf) && monthKey(m) <= monthKey(pt);

  // --- fondy a šablóny
  const fundIds = new Set<number>();
  if (!Array.isArray(doc["funds"])) {
    E("funds nie je pole");
  } else {
    for (const f of doc["funds"]) {
      if (isObj(f) && isInt(f["id"]) && f["id"] >= 1) {
        if (fundIds.has(f["id"])) E(`fond ${f["id"]} je v zozname dvakrát`);
        fundIds.add(f["id"]);
        if (
          keysOf(f).length !== 3 ||
          !isStr(f["name"]) ||
          f["name"].length > MAX_TEXT ||
          !(isInt(f["type"]) && f["type"] >= 0 && f["type"] <= 9)
        )
          E(`fond ${f["id"]}: musí mať práve kľúče id, name (text) a type (0 až 9)`);
      } else {
        E("funds: položka bez celočíselného id");
      }
    }
  }
  const tmplIds = new Set<number>();
  if (!Array.isArray(doc["templates"])) {
    E("templates nie je pole");
  } else {
    for (const t of doc["templates"]) {
      if (!(isObj(t) && isInt(t["id"]) && t["id"] >= 1)) {
        E("templates: položka bez celočíselného id");
        continue;
      }
      if (tmplIds.has(t["id"])) E(`šablóna ${t["id"]} je v zozname dvakrát`);
      tmplIds.add(t["id"]);
      if (
        keysOf(t).length !== 3 ||
        !isStr(t["name"]) ||
        t["name"].length > MAX_TEXT ||
        !Array.isArray(t["months"])
      ) {
        E(`šablóna ${t["id"]}: musí mať práve kľúče id, name (text) a months (pole)`);
        continue;
      }
      const seenM = new Set<number>();
      for (const mo of t["months"]) {
        const pm = isObj(mo) ? parseMonth(mo["month"]) : null;
        if (!pm) {
          E(`šablóna ${t["id"]}: neplatný mesiac`);
          continue;
        }
        const mon = mo as Obj;
        if (!inWindow(pm))
          E(`šablóna ${t["id"]}: mesiac ${String(mon["month"])} je mimo okna period`);
        if (seenM.has(monthKey(pm)))
          E(`šablóna ${t["id"]}: mesiac ${String(mon["month"])} je dvakrát`);
        seenM.add(monthKey(pm));
        if (!Array.isArray(mon["rules"]) || keysOf(mon).length !== 2) {
          E(
            `šablóna ${t["id"]} ${String(mon["month"])}: musí mať práve kľúče month a rules (pole)`,
          );
          continue;
        }
        const seenR = new Set<number>();
        for (const r of mon["rules"]) {
          if (
            !isObj(r) ||
            keysOf(r).length !== RULE_KEYS.length ||
            !RULE_KEYS.every((k) => k in r)
          ) {
            E(
              `šablóna ${t["id"]} ${String(mon["month"])}: pravidlo musí mať práve kľúče ${[...RULE_KEYS].sort().join(", ")}`,
            );
            continue;
          }
          const ri = r["interruption"];
          if (!(isInt(ri) && ints.has(ri)))
            E(
              `šablóna ${t["id"]} ${String(mon["month"])}: pravidlo pre neexistujúce prerušenie ${JSON.stringify(ri)}`,
            );
          if (isInt(ri)) {
            if (seenR.has(ri))
              E(`šablóna ${t["id"]} ${String(mon["month"])}: prerušenie ${ri} má dve pravidlá`);
            seenR.add(ri);
          }
          if (typeof r["disabled"] !== "boolean")
            E(`šablóna ${t["id"]} ${String(mon["month"])}: disabled nie je true/false`);
          for (const k of ["min_duration_min", "min_worked_before_min"]) {
            if (!(isInt(r[k]) && (r[k] as number) >= 0 && (r[k] as number) <= 1440))
              E(`šablóna ${t["id"]} ${String(mon["month"])}: ${k} musí byť celé číslo 0 až 1440`);
          }
          for (const k of ["allowed_from_min", "allowed_to_min", "max_duration_min"]) {
            const v = r[k];
            if (
              !(
                Array.isArray(v) &&
                v.length === 7 &&
                v.every((x) => isInt(x) && x >= 0 && x <= 1440)
              )
            ) {
              E(
                `šablóna ${t["id"]} ${String(mon["month"])} prerušenie ${JSON.stringify(ri)}: ${k} musí mať 7 čísel 0 až 1440`,
              );
            }
          }
        }
      }
    }
  }

  // --- zamestnanci
  let nEmp = 0;
  let nMon = 0;
  const seenPn = new Set<string>();
  if (!Array.isArray(doc["employees"])) {
    E("employees nie je pole");
  } else {
    for (const e of doc["employees"]) {
      nEmp += 1;
      if (!isObj(e)) {
        E("employees: položka nie je objekt");
        continue;
      }
      const extra = keysOf(e).filter((k) => !EMP_KEYS.includes(k));
      if (extra.length)
        E(
          `zamestnanec obsahuje nepovolené kľúče ${JSON.stringify(extra.sort())} (súbor nesmie niesť osobné údaje)`,
        );
      const pn = e["personnel_number"];
      if (!(isStr(pn) && RE_PN.test(pn))) {
        E(`neplatné osobné číslo ${JSON.stringify(pn)}`);
        continue;
      }
      if (seenPn.has(pn)) E(`osobné číslo ${pn} je v zozname dvakrát`);
      seenPn.add(pn);
      if (!Array.isArray(e["months"])) {
        E(`${pn}: months nie je pole`);
        continue;
      }
      const seenMon = new Set<number>();
      for (const mo of e["months"]) {
        nMon += 1;
        if (!isObj(mo)) {
          E(`${pn}: mesiac nie je objekt`);
          continue;
        }
        const lab = `${pn} ${String(mo["month"])}`;
        const miss = MON_KEYS.filter((k) => !(k in mo));
        if (miss.length) {
          E(`${lab}: chýbajú kľúče ${JSON.stringify(miss)}`);
          continue;
        }
        const extraM = keysOf(mo).filter((k) => !MON_KEYS.includes(k));
        if (extraM.length) {
          E(
            `${lab}: nepovolené kľúče ${JSON.stringify(extraM.sort())} (súbor nesmie niesť osobné údaje)`,
          );
          continue;
        }
        const pm = parseMonth(mo["month"]);
        if (!pm) {
          E(`${lab}: neplatný mesiac`);
          continue;
        }
        if (!inWindow(pm)) E(`${lab}: mesiac je mimo okna period`);
        if (seenMon.has(monthKey(pm))) E(`${lab}: mesiac je v zozname dvakrát`);
        seenMon.add(monthKey(pm));
        if (
          !(isInt(mo["employment_pct"]) && mo["employment_pct"] >= 1 && mo["employment_pct"] <= 200)
        )
          E(`${lab}: employment_pct mimo 1 až 200`);
        if (!(isInt(mo["fund_id"]) && fundIds.has(mo["fund_id"])))
          E(`${lab}: neexistujúci fond ${JSON.stringify(mo["fund_id"])}`);
        if (!(isInt(mo["template_id"]) && tmplIds.has(mo["template_id"])))
          E(`${lab}: neexistujúca šablóna ${JSON.stringify(mo["template_id"])}`);
        if (!(isInt(mo["calendar_id"]) && mo["calendar_id"] >= 1))
          E(`${lab}: calendar_id nie je kladné celé číslo`);
        const nd = daysInMonth(pm[0], pm[1]);
        const dt = mo["day_types"];
        const ex = mo["expected_min"];
        if (!(Array.isArray(dt) && dt.length === nd)) {
          E(`${lab}: day_types musí mať ${nd} dní`);
          continue;
        }
        if (!(Array.isArray(ex) && ex.length === nd)) {
          E(`${lab}: expected_min musí mať ${nd} dní`);
          continue;
        }
        for (let d = 1; d <= nd; d++) {
          const t = dt[d - 1];
          const f = ex[d - 1];
          if (!(isStr(t) && RE_DAYTYPE.test(t))) {
            E(`${lab} deň ${d}: neplatný typ dňa ${JSON.stringify(t)}`);
            continue;
          }
          if (!(isInt(f) && f >= 0 && f <= 1440)) {
            E(`${lab} deň ${d}: fond ${JSON.stringify(f)} mimo 0 až 1440`);
            continue;
          }
          const wd = isoWeekday(pm[0], pm[1], d);
          const want2 = wd === 7 ? "N" : wd === 6 ? "V" : "P";
          if (t[1] !== want2)
            E(`${lab} deň ${d}: typ dňa ${t} nesedí s dňom v týždni (má byť ...${want2})`);
          const iso = `${pm[0]}-${String(pm[1]).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
          if (hol.has(iso) && t[0] !== "S")
            E(`${lab} deň ${d}: je sviatok z číselníka, ale typ dňa je ${t}`);
          if (t[0] !== "P" && f !== 0)
            E(`${lab} deň ${d}: typ ${t} nie je pracovný, ale fond je ${f}`);
          if (t[0] === "P" && f === 0) W(`${lab} deň ${d}: pracovný deň s nulovým fondom`);
        }
      }
    }
  }

  // --- úplnosť
  const cnt = doc["counts"];
  if (!(isObj(cnt) && keysOf(cnt).length === 2 && "employees" in cnt && "employee_months" in cnt)) {
    E("counts musí mať práve kľúče employees a employee_months");
  } else {
    if (cnt["employees"] !== nEmp)
      E(
        `counts.employees = ${JSON.stringify(cnt["employees"])}, v súbore je ${nEmp} zamestnancov (neúplný prenos?)`,
      );
    if (cnt["employee_months"] !== nMon)
      E(
        `counts.employee_months = ${JSON.stringify(cnt["employee_months"])}, v súbore je ${nMon} mesačných plánov (neúplný prenos?)`,
      );
  }
  if (Array.isArray(doc["employees"]) && doc["employees"].length === 0)
    W("súbor neobsahuje žiadneho zamestnanca");

  const result = done();
  if (result.errors.length === 0 && isStr(version)) {
    result.summary = {
      configVersion: version,
      periodFrom: `${pf[0]}-${String(pf[1]).padStart(2, "0")}`,
      periodTo: `${pt[0]}-${String(pt[1]).padStart(2, "0")}`,
      employees: nEmp,
      employeeMonths: nMon,
    };
  }
  return result;
}

/** Text súboru na dokument: odstráni BOM a chybu JSON povie po slovensky. Dokument sa nekontroluje (to robí checkAccessConfig). */
export function parseConfigText(text: string): { doc: unknown } | { error: string } {
  const t = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  try {
    return { doc: JSON.parse(t) as unknown };
  } catch (e) {
    return {
      error: `Súbor nie je platný JSON: ${e instanceof Error ? e.message : "neznáma chyba"}`,
    };
  }
}

// ---------------------------------------------------------------------------------------------------------------------------------
// Odpovede databázy

export interface ImportResult {
  /** preview = náhľad novej verzie, imported = zapísané, unchanged = táto verzia je už prijatá. */
  status: "preview" | "imported" | "unchanged";
  dryRun: boolean;
  configVersion: string;
  previousVersion: string | null;
  periodFrom: string;
  periodTo: string;
  employees: number;
  employeeMonths: number;
  removedMonths: number;
  withoutAccountCount: number;
  /** Prvých najviac 50 osobných čísel, ktoré nemajú účet v termináli. */
  withoutAccount: string[];
}

const nat = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : 0);

/** Odpoveď databázovej funkcie na bezpečný tvar; neznámy tvar = null (nikdy nevymýšľame čísla). */
export function parseImportResult(value: unknown): ImportResult | null {
  if (!isObj(value)) return null;
  const status = value["status"];
  if (status !== "preview" && status !== "imported" && status !== "unchanged") return null;
  if (!isStr(value["config_version"])) return null;
  const list = Array.isArray(value["without_account"])
    ? value["without_account"].filter(isStr)
    : [];
  return {
    status,
    dryRun: value["dry_run"] === true,
    configVersion: value["config_version"],
    previousVersion: isStr(value["previous_version"]) ? value["previous_version"] : null,
    periodFrom: isStr(value["period_from"]) ? value["period_from"].slice(0, 7) : "",
    periodTo: isStr(value["period_to"]) ? value["period_to"].slice(0, 7) : "",
    employees: nat(value["employees"]),
    employeeMonths: nat(value["employee_months"]),
    removedMonths: nat(value["removed_months"]),
    withoutAccountCount: nat(value["without_account_count"]),
    withoutAccount: list,
  };
}

export interface CurrentConfig {
  configVersion: string;
  periodFrom: string;
  periodTo: string;
  employees: number;
  employeeMonths: number;
  importedAt: string;
}

/** Riadok z tabuľky s prijatou konfiguráciou organizácie. */
export function parseCurrentConfig(row: unknown): CurrentConfig | null {
  if (!isObj(row) || !isStr(row["config_version"]) || !isStr(row["imported_at"])) return null;
  return {
    configVersion: row["config_version"],
    periodFrom: isStr(row["period_from"]) ? row["period_from"].slice(0, 7) : "",
    periodTo: isStr(row["period_to"]) ? row["period_to"].slice(0, 7) : "",
    employees: nat(row["employees_count"]),
    employeeMonths: nat(row["employee_months_count"]),
    importedAt: row["imported_at"],
  };
}

/** „2026.11.04.1200“ → „4. 11. 2026 12:00“ (neplatný tvar sa vráti nezmenený). */
export function formatConfigVersion(v: string): string {
  const m = /^(\d{4})\.(\d{2})\.(\d{2})\.(\d{2})(\d{2})$/.exec(v);
  return m ? `${Number(m[3])}. ${Number(m[2])}. ${m[1]} ${m[4]}:${m[5]}` : v;
}

/** „2026-10“ → „10/2026“. */
export function formatMonth(ym: string): string {
  const m = RE_MONTH.exec(ym);
  return m ? `${Number(m[2])}/${m[1]}` : ym;
}

function plural(n: number, one: string, few: string, many: string): string {
  if (n === 1) return one;
  if (n >= 2 && n <= 4) return few;
  return many;
}

export const countEmployees = (n: number) =>
  `${n} ${plural(n, "zamestnanec", "zamestnanci", "zamestnancov")}`;
export const countMonths = (n: number) =>
  `${n} ${plural(n, "mesačný plán", "mesačné plány", "mesačných plánov")}`;

/** Jedna veta o výsledku náhľadu alebo importu pre správcu. */
export function describeImportResult(r: ImportResult): string {
  if (r.status === "unchanged")
    return `Verzia ${formatConfigVersion(r.configVersion)} je už prijatá, nič sa nezmení.`;
  const body = `${countEmployees(r.employees)}, ${countMonths(r.employeeMonths)}, okno ${formatMonth(r.periodFrom)} až ${formatMonth(r.periodTo)}`;
  const removed =
    r.removedMonths > 0
      ? `; nahradí sa plán v okne a ${countMonths(r.removedMonths)} sa odstráni (zamestnanec, ktorého Access už neposlal)`
      : "";
  return r.status === "preview"
    ? `Nová verzia ${formatConfigVersion(r.configVersion)}: ${body}${removed}. Zatiaľ sa nič nezapísalo.`
    : `Prijatá verzia ${formatConfigVersion(r.configVersion)}: ${body}${removed}.`;
}
