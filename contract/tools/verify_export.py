#!/usr/bin/env python3
"""Overenie exportu razení z terminálu (kontrakt v1).

Použitie:  python3 -I verify_export.py punches_YYYYMM.csv [--prev-state stav.json] [--save-state stav.json] [--strict]

Kontroly:
  1. Pätička  #END;rows=N;sha256=...  zodpovedá obsahu súboru (úplný, nepoškodený prenos).
  2. Hlavička obsahuje všetky povinné stĺpce, contract_version == 1.
  3. record_hash každého riadku sa dá prepočítať (rovnaký vzorec ako trigger punches_chain v databáze).
  4. Reťaz prev_hash -> record_hash: prev_hash je GENESIS, alebo record_hash staršieho záznamu TOHTO používateľa
     (v súbore alebo v stave z minulého importu --prev-state). Odkaz na iného používateľa, na neskorší záznam a
     vetvenie reťaze (dva záznamy s rovnakým predchodcom) sú chyby.
     Mesačný a prírastkový súbor obsahuje len časť reťaze (reťaz ide podľa punch_id, súbor sa filtruje podľa času),
     preto záznam, ktorého predchodca v súbore nie je, je len UPOZORNENIE (s --strict chyba). Úplnú kontrolu
     súvislosti robí Access nad všetkými importovanými razeniami.
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
    with open(path, "rb") as fh:
        raw = fh.read()
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
    state = {}
    if prev_state:
        with open(prev_state, encoding="utf-8") as fh:
            state = json.load(fh)
    # nový formát stavu: {"last": {user: hash}, "hashes": [...]}; starý: {user: hash}
    old_hashes = set(state["hashes"]) if "hashes" in state else set(state.values())
    last = dict(state["last"]) if "last" in state else (dict(state) if "hashes" not in state else {})
    strict = "--strict" in argv
    by_hash = {r["record_hash"]: (r["user_uuid"], int(r["punch_id"])) for r in rows}
    seen, forks, gaps = set(), set(), []
    for r in sorted(rows, key=lambda x: int(x["punch_id"])):
        pid, u, ph = int(r["punch_id"]), r["user_uuid"], r["prev_hash"]
        if r["contract_version"] != "1": errs.append(f"punch {pid}: nepodporovaná verzia {r['contract_version']}")
        if r["external_id"] in seen: errs.append(f"punch {pid}: duplicitné external_id")
        seen.add(r["external_id"])
        if record_hash(r) != r["record_hash"]:
            errs.append(f"punch {pid}: record_hash sa nedá prepočítať (zmenený záznam?)")
        if (u, ph) in forks:
            errs.append(f"punch {pid}: vetvenie reťaze (iný záznam toho istého používateľa má rovnakého predchodcu)")
        forks.add((u, ph))
        if ph == "GENESIS" or ph in old_hashes:
            pass
        elif ph in by_hash:
            owner, ppid = by_hash[ph]
            if owner != u: errs.append(f"punch {pid}: prev_hash ukazuje na záznam iného používateľa")
            elif ppid >= pid: errs.append(f"punch {pid}: prev_hash ukazuje na neskorší záznam {ppid}")
        else:
            gaps.append(pid)
        last[u] = r["record_hash"]
    print(f"Riadkov: {len(rows)}, používateľov: {len({r['user_uuid'] for r in rows})}")
    if gaps:
        txt = (f"{len(gaps)} záznamov nadväzuje na záznam mimo tohto súboru (punch_id: "
               f"{', '.join(map(str, gaps[:10]))}{'…' if len(gaps) > 10 else ''}). Pri mesačnom a prírastkovom "
               f"exporte je to bežné; Access to overí nad všetkými importovanými razeniami.")
        if strict: errs.append(txt)
        else: print("UPOZORNENIE:", txt)
    if errs:
        print("NEZHODY:"); [print(" -", e) for e in errs]; return 1
    if save_state:
        with open(save_state, "w", encoding="utf-8") as fh:
            json.dump({"last": last, "hashes": sorted(old_hashes | set(by_hash))}, fh, indent=1)
    print("OK – súbor je úplný, záznamy nezmenené a odkazy reťaze v súbore sú konzistentné.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
