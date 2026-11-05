#!/usr/bin/env python3
"""Referenčný výpočet výpočtového plánu (kontrakt 1.2.0) z vymysleného vstupu.

Slúži na dve veci:
  1. vytvorí zlatý súbor contract/examples/config_example.json z contract/examples/config_example.input.json,
  2. je POHYBLIVÁ ŠPECIFIKÁCIA algoritmu, ktorý musí dodržať Access (access/moduly/mod_20_KonfiguraciaExport.bas
     a mod_08_UdalostiDna.NacitajKontextMesiaca): z priradenia zamestnanca, verzie fondu, kalendára, sviatkov a úväzku
     vznikne pre každý deň typ dňa a denný fond v minútach.

Pravidlá (rovnaké ako v Accesse):
  * Platná verzia (priradenie zamestnanca, verzia fondu, verzia pravidla šablóny) pre mesiac = posledná s platnosťou
    od mesiaca <= mesiac; ak taká nie je, najstaršia.
  * Typ dňa = [kalendár][deň v týždni]. Kalendár: P pracovný, V voľný (predvolene sobota a nedeľa), S sviatok.
    Sviatok z číselníka prebije kalendár. Deň v týždni: P pondelok až piatok, V sobota, N nedeľa.
  * Fond má len deň s typom P (kalendár P a nie sviatok): dĺžka podľa dňa v týždni (by_weekday), inak priemerná dĺžka dňa.
  * Pevný mesačný fond (monthly_min > 0, fond typu 4): denný fond = monthly_min // počet pracovných dní mesiaca
    (celočíselné delenie, pred úväzkom).
  * Úväzok: fond = round(fond * úväzok / 100) – zaokrúhlenie na najbližšie, polovica na párne (ako VBA CLng).
  * Okno práce (kontrakt 1.4.0): ak platná verzia fondu pre mesiac má "window" [začiatok, koniec] v minútach, mesiac zamestnanca
    dostane window_start_min a window_end_min; inak sa kľúče vynechajú a platí okno z rules.
  * Voliteľné kľúče rules a prerušení (1.4.0) sa len prepíšu zo vstupu; ich zmysel a rozsahy hlási tools/verify_config.py.

Použitie:  python3 -I build_config_example.py [vstup.json] [výstup.json]
           python3 -I build_config_example.py --check      (zlatý súbor zodpovedá vstupu; kód 1 ak nie)
"""
import calendar
import datetime
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EX = os.path.join(HERE, "..", "examples")
DEFAULT_IN = os.path.join(EX, "config_example.input.json")
DEFAULT_OUT = os.path.join(EX, "config_example.json")


def ym_key(s):
    y, m = s.split("-")
    return int(y) * 12 + int(m)


def valid_version(versions, ym):
    """Posledná verzia s platnosťou od <= ym, inak najstaršia (ako Access). versions = zoznam s kľúčom 'from'."""
    ordered = sorted(versions, key=lambda v: ym_key(v["from"]))
    best = None
    for v in ordered:
        if ym_key(v["from"]) <= ym:
            best = v
    return best if best is not None else ordered[0]


def window(period):
    y, m = map(int, period["from_month"].split("-"))
    ye, me = map(int, period["to_month"].split("-"))
    out = []
    while (y, m) <= (ye, me):
        out.append(f"{y:04d}-{m:02d}")
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)
    return out


def day_plan(month, fund_ver, cal, holidays, pct):
    """Typy dní a fond v minútach pre jeden mesiac jedného zamestnanca."""
    y, m = map(int, month.split("-"))
    nd = calendar.monthrange(y, m)[1]
    types, fond, n_prac = [], [], 0
    for d in range(1, nd + 1):
        date = datetime.date(y, m, d)
        wd = date.isoweekday()
        iso = date.isoformat()
        kal = cal.get("overrides", {}).get(iso) or ("V" if wd >= 6 else "P")
        pref = "S" if iso in holidays else kal
        suf = "N" if wd == 7 else "V" if wd == 6 else "P"
        types.append(pref + suf)
        if pref == "P":
            by = fund_ver.get("by_weekday")
            fond.append(by[wd - 1] if by else fund_ver["avg_day_min"])
            n_prac += 1
        else:
            fond.append(0)
    monthly = fund_ver.get("monthly_min", 0)
    if monthly > 0 and n_prac > 0:
        fond = [monthly // n_prac if f > 0 else 0 for f in fond]
    if pct != 100:
        fond = [round(f * pct / 100) if f > 0 else 0 for f in fond]
    return types, fond


def resolve_rule(versions, ym):
    v = valid_version(versions, ym)
    if v["interval_days"]:
        frm = [p[0] for p in v["interval_by_day"]]
        to = [p[1] for p in v["interval_by_day"]]
    else:
        frm = [v["interval_all"][0]] * 7
        to = [v["interval_all"][1]] * 7
    mx = list(v["max_by_day"]) if v["max_days"] else [v["max_all"]] * 7
    return {"disabled": bool(v["disabled"]), "allowed_from_min": frm, "allowed_to_min": to, "max_duration_min": mx,
            "min_duration_min": v["min_duration"], "min_worked_before_min": v["min_worked_before"]}


def build(inp):
    months = window(inp["period"])
    holidays = {h["date"] for h in inp["holidays"]}
    cals = {c["id"]: c for c in inp["calendars"]}
    funds = {f["id"]: f for f in inp["funds"]}
    templates = []
    for t in inp["templates"]:
        tm = []
        for mo in months:
            rules = []
            for r in sorted(t["rules"], key=lambda r: r["interruption"]):
                rr = {"interruption": r["interruption"]}
                rr.update(resolve_rule(r["versions"], ym_key(mo)))
                rules.append(rr)
            tm.append({"month": mo, "rules": rules})
        templates.append({"id": t["id"], "name": t["name"], "months": tm})
    employees, n_mon = [], 0
    for e in inp["employees"]:
        em = []
        for mo in months:
            a = valid_version(e["assignments"], ym_key(mo))
            fv = valid_version(funds[a["fund"]]["versions"], ym_key(mo))
            types, fond = day_plan(mo, fv, cals[a["calendar"]], holidays, a["employment_pct"])
            entry = {"month": mo, "employment_pct": a["employment_pct"], "fund_id": a["fund"], "template_id": a["template"],
                     "calendar_id": a["calendar"], "day_types": types, "expected_min": fond}
            if fv.get("window"):
                entry["window_start_min"], entry["window_end_min"] = fv["window"]
            em.append(entry)
            n_mon += 1
        employees.append({"personnel_number": e["personnel_number"], "months": em})
    return {
        "schema_version": 2,
        "config_version": inp["config_version"],
        "generated_at": inp["generated_at"],
        "rok": inp["rok"],
        "rules": inp["rules"],
        "interruptions": inp["interruptions"],
        "punch_codes": inp["punch_codes"],
        "holidays": inp["holidays"],
        "period": inp["period"],
        "terminal_code_map": inp["terminal_code_map"],
        "funds": [{"id": f["id"], "name": f["name"], "type": f["type"]} for f in inp["funds"]],
        "templates": templates,
        "employees": employees,
        "counts": {"employees": len(employees), "employee_months": n_mon},
    }


def fmt(o, lvl=0):
    """JSON s odsadením, polia skalárov a malé objekty skalárov na jednom riadku (čitateľné dlhé polia dní)."""
    pad = " " * (2 * lvl)
    pad1 = " " * (2 * (lvl + 1))
    scalar = lambda v: not isinstance(v, (dict, list))
    if isinstance(o, list):
        if not o:
            return "[]"
        if all(scalar(v) for v in o):
            return "[" + ", ".join(json.dumps(v, ensure_ascii=False) for v in o) + "]"
        return "[\n" + ",\n".join(pad1 + fmt(v, lvl + 1) for v in o) + "\n" + pad + "]"
    if isinstance(o, dict):
        if not o:
            return "{}"
        if lvl >= 2 and all(scalar(v) or (isinstance(v, list) and all(scalar(x) for x in v) and len(v) <= 7) for v in o.values()):
            inline = "{ " + ", ".join(json.dumps(k, ensure_ascii=False) + ": " + fmt(v, lvl + 1) for k, v in o.items()) + " }"
            if len(inline) <= 190:
                return inline
        return "{\n" + ",\n".join(pad1 + json.dumps(k, ensure_ascii=False) + ": " + fmt(v, lvl + 1) for k, v in o.items()) + "\n" + pad + "}"
    return json.dumps(o, ensure_ascii=False)


def main(argv):
    if argv and argv[0] == "--check":
        with open(DEFAULT_IN, encoding="utf-8") as fh:
            inp = json.load(fh)
        want = fmt(build(inp)) + "\n"
        with open(DEFAULT_OUT, encoding="utf-8") as fh:
            have = fh.read()
        if want != have:
            print("CHYBA: examples/config_example.json nezodpovedá vstupu; spustite build_config_example.py a výsledok skontrolujte.")
            return 1
        print("V poriadku: zlatý súbor zodpovedá vstupu.")
        return 0
    src = argv[0] if argv else DEFAULT_IN
    dst = argv[1] if len(argv) > 1 else DEFAULT_OUT
    with open(src, encoding="utf-8") as fh:
        inp = json.load(fh)
    with open(dst, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(fmt(build(inp)) + "\n")
    print("Zapísané:", dst)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
