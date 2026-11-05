#!/usr/bin/env python3
"""Overenie súboru dochs_config.json (konfigurácia a výpočtový plán z Accessu, kontrakt 1.2.0 až 1.4.0, schema_version 2).

Použitie:  python3 -I verify_config.py dochs_config.json [--strict]

Kontroly (chyby ukončia program kódom 1; --strict zmení aj upozornenia na chyby):
  1. Platný JSON (UTF-8, môže mať BOM), schema_version == 2, všetky povinné kľúče, žiadne neznáme kľúče.
  2. Žiadne osobné údaje: zamestnanec má len kľúče personnel_number a months, mesiac len povolené kľúče.
  3. Číselníky: prerušenia (jedinečné čísla, calc WORK iba pre č. 1, LUNCH iba pre č. 7), kódy razení (odkazujú na existujúce
     prerušenie, smer Z/K zodpovedá začiatku/koncu prerušenia), mapovanie kódov terminála, sviatky (platné dátumy, bez duplicít).
     Tlačidlá terminála (1.3.0, voliteľné): terminal_button / terminal_label / terminal_order, pozri README.md.
     Voliteľné kľúče 1.4.0: v rules lunch_*, rounding_*, auto_repair_*, correction_deadline_day, early_return_ends_interruption,
     unlabeled_out_is_lunch; v prerušeniach calc UNPAID, terminal_icon, terminal_request, needs_approval, full_day_only.
  4. Plán: každý mesiac zamestnanca leží v okne period, dni majú správny počet (28 až 31 podľa kalendára),
     2. písmeno typu dňa zodpovedá skutočnému dňu v týždni, sviatok z číselníka má 1. písmeno S,
     fond je 0 v dňoch, ktoré nie sú pracovné (V, S), a nepresahuje 1440 minút.
     Voliteľné okno práce v mesiaci (1.4.0): window_start_min a window_end_min vždy spolu, koniec po začiatku.
  5. Odkazy: fund_id, template_id existujú; pravidlá šablón odkazujú na existujúce prerušenia; pravidlá len pre mesiace okna.
  6. Úplnosť: counts.employees a counts.employee_months zodpovedajú obsahu (zachytí orezaný alebo poškodený súbor).
Výstup: kód 0 = v poriadku, 1 = chyba. Nič nemení, len číta. Používa len štandardnú knižnicu Pythonu.
"""
import calendar
import datetime
import json
import re
import sys

TOP_REQ = ["schema_version", "config_version", "rok", "rules", "interruptions", "punch_codes", "holidays",
           "period", "terminal_code_map", "funds", "templates", "employees", "counts"]
TOP_OPT = ["generated_at"]
RULES_REQ = ["work_window_start_min", "work_window_end_min", "full_day_obstacle_min", "auto_lunch_trigger_min",
             "auto_lunch_deduct_min", "auto_lunch_enabled", "duplicate_punch_window_min", "default_daily_fund_min",
             "auto_repair_mode"]
INT_REQ = ["code", "name", "short_name", "start_punch_code", "end_punch_code", "is_work", "is_lunch", "auto_end_of_shift", "calc"]
INT_OPT = ["counts_to_fund", "counts_to_work", "deducts_leave", "terminal_button", "terminal_label", "terminal_order",
           "terminal_icon", "terminal_request", "needs_approval", "full_day_only"]
INT_FLAGS_NOT_FOR_WORK = ("terminal_request", "needs_approval", "full_day_only")   # 1.4.0, patria k č. 1 nie
MAX_BUTTONS = 12
MAX_LABEL = 24
CALC = {"WORK", "LUNCH", "COUNTED", "UNPAID"}
# kontrakt 1.4.0: voliteľné kľúče rules. Celé čísla (rozsah) alebo true/false; chýbajúci kľúč = predvolená hodnota (dnešné správanie).
RULES_OPT_INT = {"lunch_recorded_mode": (0, 2), "lunch_min_min": (0, 600), "rounding_in_min": (0, 60), "rounding_out_min": (0, 60),
                 "rounding_mode": (0, 3), "auto_repair_target": (0, 1), "auto_repair_cases": (1, 3), "correction_deadline_day": (0, 31)}
RULES_OPT_BOOL = ["interruption_check_enabled", "unlabeled_out_is_lunch", "early_return_ends_interruption"]
ICON_RE = re.compile(r"^[a-z][a-z0-9_]{0,19}$")
ICONS = {"doctor", "family", "trip", "errand", "private", "lunch", "home", "other"}   # zatvorený zoznam, pozri README.md
EMP_KEYS = {"personnel_number", "months"}
MON_KEYS = {"month", "employment_pct", "fund_id", "template_id", "calendar_id", "day_types", "expected_min"}
MON_OPT = {"window_start_min", "window_end_min"}   # kontrakt 1.4.0
RULE_KEYS = {"interruption", "disabled", "allowed_from_min", "allowed_to_min", "max_duration_min", "min_duration_min",
             "min_worked_before_min"}
MAX_MONTHS = 14
RE_MONTH = re.compile(r"^(\d{4})-(0[1-9]|1[0-2])$")
RE_VERSION = re.compile(r"^\d{4}\.\d{2}\.\d{2}\.\d{4}$")
RE_DAYTYPE = re.compile(r"^[PVS][PVN]$")
RE_PN = re.compile(r"^[0-9A-Za-z]{1,20}$")


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def parse_month(s):
    m = RE_MONTH.match(s) if isinstance(s, str) else None
    return (int(m.group(1)), int(m.group(2))) if m else None


def months_between(a, b):
    out, (y, m) = [], a
    while (y, m) <= b:
        out.append((y, m))
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)
    return out


def check(doc, strict=False):
    """Vráti (chyby, upozornenia) ako zoznamy textov."""
    errs, warns = [], []
    E, W = errs.append, warns.append

    if not isinstance(doc, dict):
        return ["koreň súboru nie je objekt"], warns
    if doc.get("schema_version") != 2:
        return [f"schema_version musí byť 2 (je {doc.get('schema_version')!r}); súbor verzie 1 neobsahuje plán"], warns
    for k in TOP_REQ:
        if k not in doc:
            E(f"chýba kľúč '{k}'")
    for k in doc:
        if k not in TOP_REQ and k not in TOP_OPT:
            E(f"neznámy kľúč najvyššej úrovne '{k}'")
    if errs:
        return errs, warns

    if not (isinstance(doc["config_version"], str) and RE_VERSION.match(doc["config_version"])):
        E("config_version musí mať tvar rrrr.mm.dd.hhmm")
    if not is_int(doc["rok"]):
        E("rok nie je celé číslo")

    # --- pravidlá
    rules = doc["rules"]
    if not isinstance(rules, dict):
        E("rules nie je objekt")
    else:
        for k in RULES_REQ:
            if k not in rules:
                E(f"rules: chýba '{k}'")
            elif k == "auto_lunch_enabled":
                if not isinstance(rules[k], bool):
                    E("rules.auto_lunch_enabled nie je true/false")
            elif not is_int(rules[k]) or rules[k] < 0:
                E(f"rules.{k} nie je nezáporné celé číslo")
        if all(is_int(rules.get(k)) for k in ("work_window_start_min", "work_window_end_min")):
            if rules["work_window_end_min"] <= rules["work_window_start_min"]:
                E("rules: koniec okna práce nie je po začiatku")
        if is_int(rules.get("full_day_obstacle_min")) and not 1 <= rules["full_day_obstacle_min"] <= 1440:
            E("rules.full_day_obstacle_min mimo 1 až 1440")
        # kontrakt 1.4.0: voliteľné kľúče (chýbajúci kľúč = predvolená hodnota, dnešné správanie)
        for k, (lo, hi) in RULES_OPT_INT.items():
            if k in rules and not (is_int(rules[k]) and lo <= rules[k] <= hi):
                E(f"rules.{k} musí byť celé číslo {lo} až {hi}")
        for k in RULES_OPT_BOOL:
            if k in rules and not isinstance(rules[k], bool):
                E(f"rules.{k} nie je true/false")
        mode = rules.get("lunch_recorded_mode", 0)
        if is_int(rules.get("lunch_min_min")) and is_int(mode) and mode == 0:
            W("rules.lunch_min_min sa nepoužije, kým lunch_recorded_mode nie je 1 alebo 2")
        known = set(RULES_REQ) | set(RULES_OPT_INT) | set(RULES_OPT_BOOL)
        for k in rules:
            if k not in known:
                W(f"rules: neznámy kľúč '{k}' (terminál ho ignoruje)")

    # --- prerušenia
    ints = {}
    if not isinstance(doc["interruptions"], list):
        E("interruptions nie je pole")
    else:
        for i, it in enumerate(doc["interruptions"]):
            if not isinstance(it, dict):
                E(f"interruptions[{i}] nie je objekt")
                continue
            for k in INT_REQ:
                if k not in it:
                    E(f"interruptions[{i}]: chýba '{k}'")
            for k in it:
                if k not in INT_REQ and k not in INT_OPT:
                    E(f"interruptions[{i}]: neznámy kľúč '{k}'")
            c = it.get("code")
            if not is_int(c) or c < 1:
                E(f"interruptions[{i}]: code nie je kladné celé číslo")
                continue
            if c in ints:
                E(f"prerušenie {c} je v zozname dvakrát")
            ints[c] = it
            calc = it.get("calc")
            if calc not in CALC:
                E(f"prerušenie {c}: calc '{calc}' nepoznáme (povolené {sorted(CALC)})")
            if (calc == "WORK") != (c == 1):
                E(f"prerušenie {c}: calc WORK patrí práve prerušeniu č. 1")
            if (calc == "LUNCH") != (c == 7):
                E(f"prerušenie {c}: calc LUNCH patrí práve prerušeniu č. 7")
            if it.get("is_work") != (c == 1) or it.get("is_lunch") != (c == 7):
                E(f"prerušenie {c}: is_work/is_lunch nesedí s číslom prerušenia")
            if "terminal_button" in it and not isinstance(it["terminal_button"], bool):
                E(f"prerušenie {c}: terminal_button nie je true/false")
            if "terminal_label" in it:
                lab = it["terminal_label"]
                if not (isinstance(lab, str) and 1 <= len(lab) <= MAX_LABEL and lab == lab.strip()
                        and all(ord(ch) >= 32 for ch in lab)):
                    E(f"prerušenie {c}: terminal_label musí byť text 1 až {MAX_LABEL} znakov bez medzier na kraji")
            if "terminal_order" in it and not (is_int(it["terminal_order"]) and 1 <= it["terminal_order"] <= 99):
                E(f"prerušenie {c}: terminal_order musí byť celé číslo 1 až 99")
            if it.get("terminal_button") is not True and ("terminal_label" in it or "terminal_order" in it):
                E(f"prerušenie {c}: terminal_label a terminal_order patria len prerušeniu s terminal_button = true")
            # kontrakt 1.4.0
            if "terminal_icon" in it:
                ic = it["terminal_icon"]
                if not (isinstance(ic, str) and ICON_RE.fullmatch(ic)):
                    E(f"prerušenie {c}: terminal_icon musí byť názov z malých písmen, číslic a podčiarkovníka (najviac 20 znakov)")
                elif ic not in ICONS:
                    W(f"prerušenie {c}: neznáma ikona '{ic}', terminál ukáže všeobecnú")
                if it.get("terminal_button") is not True:
                    E(f"prerušenie {c}: terminal_icon patrí len prerušeniu s terminal_button = true")
            for k in INT_FLAGS_NOT_FOR_WORK:
                if k in it and not isinstance(it[k], bool):
                    E(f"prerušenie {c}: {k} nie je true/false")
                elif it.get(k) is True and c == 1:
                    E(f"prerušenie 1: práca (č. 1) nemá kľúč {k} (patrí ostatným prerušeniam)")
            if it.get("full_day_only") is True and it.get("terminal_button") is True:
                E(f"prerušenie {c}: full_day_only a terminal_button sa vylučujú (tlačidlo zapisuje odchod a návrat, nie celý deň)")
        if 1 not in ints:
            E("v zozname prerušení chýba č. 1 (pracovná doba)")

    # --- kódy razení
    pcodes = {}
    if not isinstance(doc["punch_codes"], list):
        E("punch_codes nie je pole")
    else:
        for i, pc in enumerate(doc["punch_codes"]):
            c = pc.get("code") if isinstance(pc, dict) else None
            if not is_int(c):
                E(f"punch_codes[{i}]: code nie je celé číslo")
                continue
            if c in pcodes:
                E(f"kód razenia {c} je v zozname dvakrát")
            pcodes[c] = pc
            n = pc.get("interruption")
            if not is_int(n) or n < 0:
                E(f"kód razenia {c}: interruption nie je celé číslo")
            elif n > 0 and n not in ints:
                E(f"kód razenia {c} odkazuje na neexistujúce prerušenie {n}")
            elif n > 0:
                want = ints[n]["start_punch_code"] if pc.get("direction") == "Z" else ints[n]["end_punch_code"] if pc.get("direction") == "K" else None
                if want is not None and want != c:
                    W(f"kód razenia {c}: smer {pc.get('direction')} nezodpovedá kódu {want} v prerušení {n}")
        for c, it in ints.items():
            for k in ("start_punch_code", "end_punch_code"):
                v = it.get(k)
                if is_int(v) and v != 0 and v not in pcodes:
                    W(f"prerušenie {c}: {k} {v} nie je v zozname kódov razení")

    # --- mapovanie kódov terminála
    seen_codes = set()
    if not isinstance(doc["terminal_code_map"], list):
        E("terminal_code_map nie je pole")
    else:
        for i, m in enumerate(doc["terminal_code_map"]):
            if not isinstance(m, dict) or set(m) != {"code", "interruption"}:
                E(f"terminal_code_map[{i}]: musí mať práve kľúče code a interruption")
                continue
            if m["code"] in seen_codes:
                E(f"terminal_code_map: kód '{m['code']}' je dvakrát")
            seen_codes.add(m["code"])
            if not (is_int(m["interruption"]) and m["interruption"] in ints):
                E(f"terminal_code_map: kód '{m['code']}' odkazuje na neexistujúce prerušenie {m['interruption']!r}")
        if "WORK" not in seen_codes:
            W("terminal_code_map: chýba kód WORK")

    # --- tlačidlá terminála (1.3.0): príznak patrí prerušeniu, ktoré má práve jeden kód terminála
    codes_of = {}
    if isinstance(doc["terminal_code_map"], list):
        for m in doc["terminal_code_map"]:
            if isinstance(m, dict) and is_int(m.get("interruption")):
                codes_of.setdefault(m["interruption"], []).append(m.get("code"))
    buttons, seen_text = [], {}
    for c, it in ints.items():
        if it.get("terminal_button") is not True:
            continue
        buttons.append(c)
        if c == 1:
            E("prerušenie 1: práca (č. 1) nemá vlastné tlačidlo, terminál má Príchod a Odchod")
        n = len(codes_of.get(c, []))
        if n != 1:
            E(f"prerušenie {c}: tlačidlo potrebuje práve jeden kód v terminal_code_map (je ich {n})")
        text = it.get("terminal_label") if isinstance(it.get("terminal_label"), str) else it.get("name")
        if isinstance(text, str):
            key = text.casefold()
            if key in seen_text:
                E(f"prerušenia {seen_text[key]} a {c} majú tlačidlo s rovnakým textom '{text}'")
            seen_text.setdefault(key, c)
    if len(buttons) > MAX_BUTTONS:
        E(f"tlačidiel pre terminál je {len(buttons)}, najviac {MAX_BUTTONS}")

    # --- sviatky
    hol = set()
    if not isinstance(doc["holidays"], list):
        E("holidays nie je pole")
    else:
        for i, h in enumerate(doc["holidays"]):
            try:
                d = datetime.date.fromisoformat(h["date"])
            except Exception:
                E(f"holidays[{i}]: neplatný dátum")
                continue
            if d in hol:
                E(f"sviatok {d} je v zozname dvakrát")
            hol.add(d)

    # --- okno
    per = doc["period"]
    pf = parse_month(per.get("from_month")) if isinstance(per, dict) else None
    pt = parse_month(per.get("to_month")) if isinstance(per, dict) else None
    if not pf or not pt:
        E("period.from_month / to_month musia mať tvar rrrr-mm")
        return errs, warns
    if pt < pf:
        E("period: koniec je pred začiatkom")
        return errs, warns
    window = months_between(pf, pt)
    if len(window) > MAX_MONTHS:
        E(f"okno period má {len(window)} mesiacov, najviac {MAX_MONTHS}")
    wset = set(window)

    # --- fondy a šablóny
    fund_ids = set()
    if not isinstance(doc["funds"], list):
        E("funds nie je pole")
    else:
        for f in doc["funds"]:
            if isinstance(f, dict) and is_int(f.get("id")):
                if f["id"] in fund_ids:
                    E(f"fond {f['id']} je v zozname dvakrát")
                fund_ids.add(f["id"])
            else:
                E("funds: položka bez celočíselného id")
    tmpl_ids = set()
    if not isinstance(doc["templates"], list):
        E("templates nie je pole")
    else:
        for t in doc["templates"]:
            if not (isinstance(t, dict) and is_int(t.get("id"))):
                E("templates: položka bez celočíselného id")
                continue
            if t["id"] in tmpl_ids:
                E(f"šablóna {t['id']} je v zozname dvakrát")
            tmpl_ids.add(t["id"])
            seen_m = set()
            for mo in t.get("months", []):
                pm = parse_month(mo.get("month")) if isinstance(mo, dict) else None
                if not pm:
                    E(f"šablóna {t['id']}: neplatný mesiac")
                    continue
                if pm not in wset:
                    E(f"šablóna {t['id']}: mesiac {mo['month']} je mimo okna period")
                if pm in seen_m:
                    E(f"šablóna {t['id']}: mesiac {mo['month']} je dvakrát")
                seen_m.add(pm)
                seen_r = set()
                for r in mo.get("rules", []):
                    if not isinstance(r, dict) or set(r) != RULE_KEYS:
                        E(f"šablóna {t['id']} {mo['month']}: pravidlo musí mať práve kľúče {sorted(RULE_KEYS)}")
                        continue
                    if r["interruption"] not in ints:
                        E(f"šablóna {t['id']} {mo['month']}: pravidlo pre neexistujúce prerušenie {r['interruption']!r}")
                    if r["interruption"] in seen_r:
                        E(f"šablóna {t['id']} {mo['month']}: prerušenie {r['interruption']} má dve pravidlá")
                    seen_r.add(r["interruption"])
                    for k in ("allowed_from_min", "allowed_to_min", "max_duration_min"):
                        v = r[k]
                        if not (isinstance(v, list) and len(v) == 7 and all(is_int(x) and 0 <= x <= 1440 for x in v)):
                            E(f"šablóna {t['id']} {mo['month']} prerušenie {r['interruption']}: {k} musí mať 7 čísel 0 až 1440")

    # --- zamestnanci
    n_emp = n_mon = 0
    seen_pn = set()
    if not isinstance(doc["employees"], list):
        E("employees nie je pole")
    else:
        for e in doc["employees"]:
            n_emp += 1
            if not isinstance(e, dict):
                E("employees: položka nie je objekt")
                continue
            extra = set(e) - EMP_KEYS
            if extra:
                E(f"zamestnanec obsahuje nepovolené kľúče {sorted(extra)} (súbor nesmie niesť osobné údaje)")
            pn = e.get("personnel_number")
            if not (isinstance(pn, str) and RE_PN.match(pn)):
                E(f"neplatné osobné číslo {pn!r}")
                continue
            if pn in seen_pn:
                E(f"osobné číslo {pn} je v zozname dvakrát")
            seen_pn.add(pn)
            seen_mon = set()
            for mo in e.get("months", []):
                n_mon += 1
                lab = f"{pn} {mo.get('month') if isinstance(mo, dict) else '?'}"
                if not isinstance(mo, dict):
                    E(f"{pn}: mesiac nie je objekt")
                    continue
                miss = MON_KEYS - set(mo)
                extra = set(mo) - MON_KEYS - MON_OPT
                if miss:
                    E(f"{lab}: chýbajú kľúče {sorted(miss)}")
                    continue
                if extra:
                    E(f"{lab}: nepovolené kľúče {sorted(extra)}")
                pm = parse_month(mo["month"])
                if not pm:
                    E(f"{lab}: neplatný mesiac")
                    continue
                if pm not in wset:
                    E(f"{lab}: mesiac je mimo okna period")
                if pm in seen_mon:
                    E(f"{lab}: mesiac je v zozname dvakrát")
                seen_mon.add(pm)
                if not (is_int(mo["employment_pct"]) and 1 <= mo["employment_pct"] <= 200):
                    E(f"{lab}: employment_pct mimo 1 až 200")
                # kontrakt 1.4.0: okno práce zamestnanca v mesiaci (podľa fondu), vždy obe hodnoty spolu
                if ("window_start_min" in mo) != ("window_end_min" in mo):
                    E(f"{lab}: window_start_min a window_end_min musia byť spolu")
                elif "window_start_min" in mo:
                    ws, we = mo["window_start_min"], mo["window_end_min"]
                    if not (is_int(ws) and is_int(we) and 0 <= ws <= 1440 and 0 <= we <= 1440):
                        E(f"{lab}: window_start_min a window_end_min musia byť celé čísla 0 až 1440")
                    elif we <= ws:
                        E(f"{lab}: koniec okna práce nie je po začiatku")
                if mo["fund_id"] not in fund_ids:
                    E(f"{lab}: neexistujúci fond {mo['fund_id']!r}")
                if mo["template_id"] not in tmpl_ids:
                    E(f"{lab}: neexistujúca šablóna {mo['template_id']!r}")
                ndays = calendar.monthrange(*pm)[1]
                dt, ex = mo["day_types"], mo["expected_min"]
                if not (isinstance(dt, list) and len(dt) == ndays):
                    E(f"{lab}: day_types musí mať {ndays} dní")
                    continue
                if not (isinstance(ex, list) and len(ex) == ndays):
                    E(f"{lab}: expected_min musí mať {ndays} dní")
                    continue
                for d in range(1, ndays + 1):
                    t, f = dt[d - 1], ex[d - 1]
                    if not (isinstance(t, str) and RE_DAYTYPE.match(t)):
                        E(f"{lab} deň {d}: neplatný typ dňa {t!r}")
                        continue
                    if not (is_int(f) and 0 <= f <= 1440):
                        E(f"{lab} deň {d}: fond {f!r} mimo 0 až 1440")
                        continue
                    wd = datetime.date(pm[0], pm[1], d).isoweekday()
                    want2 = "N" if wd == 7 else "V" if wd == 6 else "P"
                    if t[1] != want2:
                        E(f"{lab} deň {d}: typ dňa {t} nesedí s dňom v týždni (má byť ...{want2})")
                    if datetime.date(pm[0], pm[1], d) in hol and t[0] != "S":
                        E(f"{lab} deň {d}: je sviatok z číselníka, ale typ dňa je {t}")
                    if t[0] != "P" and f != 0:
                        E(f"{lab} deň {d}: typ {t} nie je pracovný, ale fond je {f}")
                    if t[0] == "P" and f == 0:
                        W(f"{lab} deň {d}: pracovný deň s nulovým fondom")

    # --- úplnosť
    cnt = doc["counts"]
    if not (isinstance(cnt, dict) and set(cnt) == {"employees", "employee_months"}):
        E("counts musí mať práve kľúče employees a employee_months")
    else:
        if cnt["employees"] != n_emp:
            E(f"counts.employees = {cnt['employees']}, v súbore je {n_emp} zamestnancov (neúplný prenos?)")
        if cnt["employee_months"] != n_mon:
            E(f"counts.employee_months = {cnt['employee_months']}, v súbore je {n_mon} mesačných plánov (neúplný prenos?)")
    if not doc["employees"]:
        W("súbor neobsahuje žiadneho zamestnanca")

    if strict:
        errs.extend("(upozornenie ako chyba) " + w for w in warns)
        warns = []
    return errs, warns


def load(path):
    with open(path, "rb") as fh:
        raw = fh.read()
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    return json.loads(raw.decode("utf-8"))


def main(argv):
    if not argv or argv[0].startswith("-"):
        print(__doc__)
        return 1
    try:
        doc = load(argv[0])
    except (OSError, UnicodeDecodeError, ValueError) as ex:
        print(f"CHYBA: súbor sa nedá prečítať ako JSON: {ex}")
        return 1
    errs, warns = check(doc, strict="--strict" in argv)
    for w in warns:
        print("UPOZORNENIE:", w)
    for e in errs:
        print("CHYBA:", e)
    if errs:
        print(f"Nevyhovuje: {len(errs)} chýb, {len(warns)} upozornení.")
        return 1
    emp = len(doc["employees"])
    print(f"V poriadku: {emp} zamestnancov, {doc['counts']['employee_months']} mesačných plánov, "
          f"okno {doc['period']['from_month']} až {doc['period']['to_month']}, verzia {doc['config_version']}"
          + (f", {len(warns)} upozornení." if warns else "."))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
