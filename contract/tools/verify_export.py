#!/usr/bin/env python3
"""Overenie exportu razení z terminálu (kontrakt v1).

Použitie:  python3 -I verify_export.py punches_YYYYMM.csv [--prev-state stav.json] [--save-state stav.json]

Kontroly:
  1. Pätička  #END;rows=N;sha256=...  zodpovedá obsahu súboru (úplný, nepoškodený prenos).
  2. Hlavička obsahuje všetky povinné stĺpce, contract_version == 1.
  3. record_hash každého riadku sa dá prepočítať (rovnaký vzorec ako trigger punches_chain v databáze).
  4. Reťaz prev_hash -> record_hash je pre každého používateľa súvislá (podľa punch_id), prípadne nadväzuje
     na posledný známy hash z minulého importu (--prev-state).
Výstup: kód 0 = v poriadku, 1 = chyba. Nič nemení, len číta.
Používa len štandardnú knižnicu Pythonu.
"""
import csv, hashlib, io, json, sys

REQ = ["contract_version", "organization_id", "punch_id", "external_id", "personnel_number", "code", "direction",
       "client_time_local", "client_time_utc", "server_time_utc", "drift_minutes", "source", "device_verification",
       "device_id", "user_uuid", "prev_hash", "record_hash"]


def record_hash(r):
    # presne podľa drizzle/migrations/0003_device_verification.sql (funkcia punches_chain)
    s = "|".join([r["prev_hash"], r["user_uuid"], r["code"], r["direction"],
                  r["client_time_utc"].rstrip("Z")[:19], r["server_time_utc"].rstrip("Z")[:19], r["external_id"]])
    if r["device_id"]:
        s += "|" + r["device_id"]
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def main(argv):
    if not argv or argv[0].startswith("-"):
        print(__doc__); return 1
    path = argv[0]
    prev_state = save_state = None
    if "--prev-state" in argv: prev_state = argv[argv.index("--prev-state") + 1]
    if "--save-state" in argv: save_state = argv[argv.index("--save-state") + 1]
    raw = open(path, "rb").read()
    if raw.startswith(b"\xef\xbb\xbf"): raw = raw[3:]
    text = raw.decode("utf-8")
    errs = []
    idx = text.rfind("#END;")
    if idx < 0:
        print("CHYBA: chýba pätička #END (súbor je neúplný)"); return 1
    body, footer = text[:idx], text[idx:].strip()
    kv = dict(p.split("=", 1) for p in footer.split(";")[1:])
    if hashlib.sha256(body.encode("utf-8")).hexdigest() != kv.get("sha256"):
        errs.append("kontrolný súčet súboru nesedí s pätičkou")
    rows = list(csv.DictReader(io.StringIO(body), delimiter=";", quotechar='"'))
    if int(kv.get("rows", -1)) != len(rows):
        errs.append(f"počet riadkov {len(rows)} != pätička {kv.get('rows')}")
    if not rows:
        print("Prázdny export (0 riadkov)."); return 0 if not errs else 1
    miss = [c for c in REQ if c not in rows[0]]
    if miss:
        print("CHYBA: chýbajú stĺpce:", ", ".join(miss)); return 1
    last = json.load(open(prev_state)) if prev_state else {}
    seen = set()
    for r in sorted(rows, key=lambda x: int(x["punch_id"])):
        if r["contract_version"] != "1": errs.append(f"punch {r['punch_id']}: nepodporovaná verzia {r['contract_version']}")
        if r["external_id"] in seen: errs.append(f"punch {r['punch_id']}: duplicitné external_id")
        seen.add(r["external_id"])
        if record_hash(r) != r["record_hash"]:
            errs.append(f"punch {r['punch_id']}: record_hash sa nedá prepočítať (zmenený záznam?)")
        u = r["user_uuid"]
        exp = last.get(u, "GENESIS" if u not in last and not prev_state else None)
        if exp is not None and r["prev_hash"] != exp:
            errs.append(f"punch {r['punch_id']}: reťaz sa preruší (očakávaný prev_hash {exp[:12]}…, je {r['prev_hash'][:12]}…)")
        last[u] = r["record_hash"]
    print(f"Riadkov: {len(rows)}, používateľov: {len(last)}")
    if errs:
        print("NEZHODY:"); [print(" -", e) for e in errs]; return 1
    if save_state: json.dump(last, open(save_state, "w"), indent=1)
    print("OK – export je úplný a reťaz je súvislá.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
