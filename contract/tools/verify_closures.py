#!/usr/bin/env python3
"""Overenie súboru dochs_closures.json (uzávierky mesiacov z Accessu pre terminál, kontrakt 1.6.0, schema_version 1).

Použitie:  python3 -I verify_closures.py dochs_closures.json [--strict]

Kontroly (chyby ukončia program kódom 1; --strict zmení aj upozornenia na chyby):
  1. Platný JSON (UTF-8, môže mať BOM), schema_version == 1, všetky povinné kľúče, žiadne neznáme kľúče
     (zamestnanec je len osobné číslo, žiadne mená ani e-maily).
  2. Záznam uzávierky: osobné číslo, rok, platný mesiac, stav CLOSED alebo REOPENED, state_seq, platný čas zmeny.
     state_seq je počítadlo zmien stavu mesiaca zamestnanca (uzavretie = 1, otvorenie = 2, uzavretie = 3 …),
     preto CLOSED má nepárne a REOPENED párne číslo.
  3. CLOSED nesie totals (worked_min, expected_min, balance_min) a counted_punches (jedinečné uuid); REOPENED žiadne z nich
     ani report_code.
  4. Jedinečnosť: jeden záznam na zamestnanca a mesiac.
  5. Úplnosť: counts.closures a counts.counted_punches zodpovedajú obsahu (zachytí orezaný alebo poškodený súbor).
Upozornenie: balance_min sa líši od worked_min − expected_min (Access smie uznávať nadčas inak, preto to nie je chyba);
mesiac neskorší než čas zostavenia súboru.
Výstup: kód 0 = v poriadku, 1 = chyba. Nič nemení, len číta. Používa len štandardnú knižnicu Pythonu.
"""
import datetime
import json
import re
import sys

TOP_REQ = ["schema_version", "closures_version", "organization_id", "closures", "counts"]
TOP_OPT = ["generated_at"]
ENTRY_REQ = ["personnel_number", "year", "month", "state", "state_seq", "changed_at"]
ENTRY_OPT = ["report_code", "totals", "counted_punches"]
TOTALS_KEYS = ["worked_min", "expected_min", "balance_min"]
STATES = {"CLOSED", "REOPENED"}
MAX_COUNTED = 5000
MAX_MIN = 44640   # 31 dní po 1440 minút

VERSION_RE = re.compile(r"^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{4}$")
LOCAL_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
PN_RE = re.compile(r"^[0-9A-Za-z]{1,20}$")


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def parse_local(s):
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%S")
    except (TypeError, ValueError):
        return None


def check_totals(t, where, errs):
    if not isinstance(t, dict):
        errs.append(f"{where}: totals musí byť objekt")
        return None
    extra = sorted(set(t) - set(TOTALS_KEYS))
    missing = [k for k in TOTALS_KEYS if k not in t]
    if extra:
        errs.append(f"{where}: totals má neznáme kľúče {extra}")
    if missing:
        errs.append(f"{where}: totals nemá povinné kľúče {missing}")
        return None
    ok = True
    for k in TOTALS_KEYS:
        v = t[k]
        lo = -MAX_MIN if k == "balance_min" else 0
        if not is_int(v) or not (lo <= v <= MAX_MIN):
            errs.append(f"{where}: totals.{k} musí byť celé číslo {lo} až {MAX_MIN}")
            ok = False
    return t if ok else None


def check(doc, strict=False):
    errs, warns = [], []
    if not isinstance(doc, dict):
        return ["súbor musí byť JSON objekt"], warns
    extra = sorted(set(doc) - set(TOP_REQ) - set(TOP_OPT))
    if extra:
        errs.append(f"neznáme kľúče najvyššej úrovne: {extra}")
    for k in TOP_REQ:
        if k not in doc:
            errs.append(f"chýba povinný kľúč {k}")
    if errs:
        return errs, warns

    if doc["schema_version"] != 1 or not is_int(doc["schema_version"]):
        errs.append("schema_version musí byť 1")
    if not isinstance(doc["closures_version"], str) or not VERSION_RE.match(doc["closures_version"]):
        errs.append("closures_version musí mať tvar rrrr.mm.dd.hhmm")
    gen = None
    if "generated_at" in doc:
        gen = parse_local(doc["generated_at"]) if isinstance(doc["generated_at"], str) and LOCAL_RE.match(doc["generated_at"]) else None
        if gen is None:
            errs.append("generated_at musí mať tvar RRRR-MM-DDTHH:MM:SS a platný čas")
    if not isinstance(doc["organization_id"], str) or not UUID_RE.match(doc["organization_id"]):
        errs.append("organization_id musí byť uuid")

    closures = doc["closures"]
    if not isinstance(closures, list):
        errs.append("closures musí byť pole")
        return errs, warns

    seen = set()
    total_counted = 0
    for i, c in enumerate(closures):
        where = f"closures[{i}]"
        if not isinstance(c, dict):
            errs.append(f"{where}: musí byť objekt")
            continue
        extra = sorted(set(c) - set(ENTRY_REQ) - set(ENTRY_OPT))
        if extra:
            errs.append(f"{where}: neznáme kľúče {extra}")
        missing = [k for k in ENTRY_REQ if k not in c]
        if missing:
            errs.append(f"{where}: chýbajú povinné kľúče {missing}")
            continue

        pn, year, month = c["personnel_number"], c["year"], c["month"]
        if not isinstance(pn, str) or not PN_RE.match(pn):
            errs.append(f"{where}: personnel_number musí byť text z 1 až 20 znakov 0-9 a písmen")
        if not is_int(year) or not (2000 <= year <= 2100):
            errs.append(f"{where}: year musí byť celé číslo 2000 až 2100")
        if not is_int(month) or not (1 <= month <= 12):
            errs.append(f"{where}: month musí byť celé číslo 1 až 12")
        key = (pn, year, month)
        if key in seen:
            errs.append(f"{where}: duplicitný záznam pre osobné číslo {pn} a mesiac {year}-{month}")
        seen.add(key)

        state, seq = c["state"], c["state_seq"]
        if state not in STATES:
            errs.append(f"{where}: state musí byť CLOSED alebo REOPENED")
        if not is_int(seq) or not (1 <= seq <= 1000000):
            errs.append(f"{where}: state_seq musí byť celé číslo 1 až 1000000")
        elif state == "CLOSED" and seq % 2 == 0:
            errs.append(f"{where}: CLOSED musí mať nepárne state_seq (uzavretie je 1., 3., … zmena stavu), má {seq}")
        elif state == "REOPENED" and seq % 2 == 1:
            errs.append(f"{where}: REOPENED musí mať párne state_seq (otvorenie je 2., 4., … zmena stavu), má {seq}")

        if not isinstance(c["changed_at"], str) or not LOCAL_RE.match(c["changed_at"]) or parse_local(c["changed_at"]) is None:
            errs.append(f"{where}: changed_at musí mať tvar RRRR-MM-DDTHH:MM:SS a platný čas")

        if "report_code" in c:
            rc = c["report_code"]
            if not isinstance(rc, str) or not (1 <= len(rc) <= 25):
                errs.append(f"{where}: report_code musí byť text z 1 až 25 znakov")

        if state == "CLOSED":
            for k in ("totals", "counted_punches"):
                if k not in c:
                    errs.append(f"{where}: CLOSED musí mať {k}")
            totals = check_totals(c["totals"], where, errs) if "totals" in c else None
            if totals and totals["balance_min"] != totals["worked_min"] - totals["expected_min"]:
                warns.append(f"{where}: balance_min ({totals['balance_min']}) sa líši od worked_min − expected_min "
                             f"({totals['worked_min'] - totals['expected_min']})")
            if "counted_punches" in c:
                cp = c["counted_punches"]
                if not isinstance(cp, list):
                    errs.append(f"{where}: counted_punches musí byť pole")
                else:
                    if len(cp) > MAX_COUNTED:
                        errs.append(f"{where}: counted_punches má {len(cp)} položiek, najviac {MAX_COUNTED}")
                    bad = [x for x in cp if not isinstance(x, str) or not UUID_RE.match(x)]
                    if bad:
                        errs.append(f"{where}: counted_punches obsahuje {len(bad)} hodnôt, ktoré nie sú uuid")
                    ok = [x.lower() for x in cp if isinstance(x, str) and UUID_RE.match(x)]
                    if len(set(ok)) != len(ok):
                        errs.append(f"{where}: counted_punches obsahuje duplicity")
                    total_counted += len(cp)
        elif state == "REOPENED":
            for k in ENTRY_OPT:
                if k in c:
                    errs.append(f"{where}: REOPENED nesmie mať {k}")

        if gen is not None and is_int(year) and is_int(month) and (year, month) > (gen.year, gen.month):
            warns.append(f"{where}: mesiac {year}-{month:02d} je neskorší než čas zostavenia súboru")

    counts = doc["counts"]
    if not isinstance(counts, dict) or set(counts) != {"closures", "counted_punches"}:
        errs.append("counts musí mať presne kľúče closures a counted_punches")
    else:
        if counts["closures"] != len(closures):
            errs.append(f"counts.closures ({counts['closures']}) nezodpovedá počtu záznamov ({len(closures)})")
        if counts["counted_punches"] != total_counted:
            errs.append(f"counts.counted_punches ({counts['counted_punches']}) nezodpovedá súčtu counted_punches ({total_counted})")

    if strict:
        errs.extend(f"(--strict) {w}" for w in warns)
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
    n_closed = sum(1 for c in doc["closures"] if c["state"] == "CLOSED")
    print(f"V poriadku: {len(doc['closures'])} záznamov ({n_closed} uzavretých, {len(doc['closures']) - n_closed} znova otvorených), "
          f"{doc['counts']['counted_punches']} zarátaných razení, verzia {doc['closures_version']}"
          + (f", {len(warns)} upozornení." if warns else "."))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
