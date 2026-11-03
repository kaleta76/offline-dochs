#!/usr/bin/env python3
"""Generátor testovacieho scenára na celý mesiac (štyria vymyslení zamestnanci 9000001 až 9000004).

Výstup (do zadaného priečinka):
  import_do_terminalu_RRRR-MM.csv   vstup pre testovací import v termináli: osobne_cislo;datum;cas;kod;smer
  terminal_test_RRRR-MM.csv         to isté vo formáte exportu kontraktu v1 (pätička SHA-256, hash reťaz) na samostatný
                                    test Accessu bez terminála (Karta 7 > Samočinný test terminála)
  popis_RRRR-MM.json                popis scenárov po dňoch (vstup pre referenčný výpočet)
  ocakavane_saldo_RRRR-MM.csv       (ak je k dispozícii tsx) referenčné saldá z enginu terminálu

Použitie:  python3 make_mesiac.py VYSTUPNY_PRIECINOK [RRRR MM]      (predvolene október 2026)
Údaje sú vymyslené, deterministické (rovnaký výstup pri každom spustení) a neobsahujú osobné údaje.
Časy sú miestne (Europe/Bratislava), aj s prechodom na zimný čas 25. 10. 2026.
"""
import calendar
import datetime as dt
import hashlib
import json
import random
import sys
import zoneinfo

TZ = zoneinfo.ZoneInfo("Europe/Bratislava")
UTC = dt.timezone.utc
ORG = "0b6f2f0e-5a7e-4b8e-9a43-2c1d5e7a9f01"
USERS = {
    "9000001": "6d1c3b84-0001-4a2e-8c11-000000000001",
    "9000002": "6d1c3b84-0002-4a2e-8c11-000000000002",
    "9000003": "6d1c3b84-0003-4a2e-8c11-000000000003",
    "9000004": "6d1c3b84-0004-4a2e-8c11-000000000004",
}
W, D, T, F, L, S, P = "WORK", "DOCTOR", "TRIP", "FAMILY", "LEAVE", "SICK", "PRIV"
IN, OUT = "IN", "OUT"


def hms(s):
    return s if s.count(":") == 2 else s + ":00"


def normal(rng, t_in, t_out):
    """Bežný deň: príchod a odchod s malou odchýlkou (v minútach a sekundách)."""
    a = dt.datetime.strptime(t_in, "%H:%M") + dt.timedelta(minutes=rng.randint(-10, 25), seconds=rng.randint(0, 59))
    b = dt.datetime.strptime(t_out, "%H:%M") + dt.timedelta(minutes=rng.randint(-15, 40), seconds=rng.randint(0, 59))
    return [(W, IN, a.strftime("%H:%M:%S")), (W, OUT, b.strftime("%H:%M:%S"))]


def with_lunch(p, out="11:30:00", back="12:00:00"):
    return [p[0], (W, OUT, out), (W, IN, back), p[1]]


# zvláštne dni: (osobné číslo, deň v mesiaci) -> (popis, razenia)
SPECIAL = {
    # 9000001: pravidelný zamestnanec 7:00 - 15:30
    ("9000001", 6): ("lekár odchod 10:00 bez návratu (doplnenie do fondu)", [(W, IN, "07:00:00"), (D, OUT, "10:00:00")]),
    ("9000001", 7): ("lekár 10:00-12:00 s návratom", [(W, IN, "07:00:00"), (D, OUT, "10:00:00"), (W, IN, "12:00:00"), (W, OUT, "15:30:00")]),
    ("9000001", 8): ("súkromné prerušenie 10:00-11:00", [(W, IN, "07:00:00"), (P, OUT, "10:00:00"), (W, IN, "11:00:00"), (W, OUT, "15:30:00")]),
    ("9000001", 9): ("DUPLICITA: dvojité razenie príchodu (7:00:02 a 7:00:11)", [(W, IN, "07:00:02"), (W, IN, "07:00:11"), (W, OUT, "15:30:05")]),
    ("9000001", 13): ("DUPLICITA: dvojité razenie odchodu (15:30:00 a 15:30:08)", [(W, IN, "07:00:00"), (W, OUT, "15:30:00"), (W, OUT, "15:30:08")]),
    ("9000001", 14): ("odchod 11:30 a návrat 12:00 (obed)", [(W, IN, "07:00:00"), (W, OUT, "11:30:00"), (W, IN, "12:00:00"), (W, OUT, "15:30:00")]),
    ("9000001", 15): ("PN celý deň", [(S, OUT, "07:00:00")]),
    ("9000001", 16): ("PN celý deň", [(S, OUT, "07:00:00")]),
    ("9000001", 26): ("8:00-13:00, bez prestávky", [(W, IN, "08:00:05"), (W, OUT, "13:00:40")]),
    # 9000002: dovolenky, PN, služobné cesty, 7:30 - 16:00
    ("9000002", 5): ("dovolenka celý deň", [(L, OUT, "07:00:00")]),
    ("9000002", 6): ("dovolenka celý deň", [(L, OUT, "07:00:00")]),
    ("9000002", 7): ("služobná cesta 9:30 bez návratu (doplnenie do fondu)", [(W, IN, "07:30:00"), (T, OUT, "09:30:00")]),
    ("9000002", 8): ("služobná cesta 9:00-13:00 s návratom", [(W, IN, "07:30:00"), (T, OUT, "09:00:00"), (W, IN, "13:00:00"), (W, OUT, "16:00:00")]),
    ("9000002", 12): ("PN celý deň", [(S, OUT, "07:00:00")]),
    ("9000002", 13): ("PN celý deň", [(S, OUT, "07:00:00")]),
    ("9000002", 14): ("PN celý deň", [(S, OUT, "07:00:00")]),
    ("9000002", 20): ("odchod na 1 hodinu bez dôvodu", [(W, IN, "07:30:00"), (W, OUT, "12:00:00"), (W, IN, "13:00:00"), (W, OUT, "16:30:00")]),
    ("9000002", 27): ("dovolenka celý deň", [(L, OUT, "07:00:00")]),
    # 9000003: nepravidelný, otvorený deň, víkend s prechodom na zimný čas
    ("9000003", 2): ("neskorý príchod 9:15-16:45", [(W, IN, "09:15:00"), (W, OUT, "16:45:00")]),
    ("9000003", 9): ("príchod bez odchodu (otvorený deň)", [(W, IN, "07:00:00")]),
    ("9000003", 14): ("sprievod rodinného príslušníka 10:00-11:30", [(W, IN, "07:00:00"), (F, OUT, "10:00:00"), (W, IN, "11:30:00"), (W, OUT, "15:00:00")]),
    ("9000003", 16): ("6:00-13:30 (450 min hrubého času)", [(W, IN, "06:00:00"), (W, OUT, "13:30:00")]),
    ("9000003", 24): ("sobota 8:00-12:00 (fond 0)", [(W, IN, "08:00:00"), (W, OUT, "12:00:00")]),
    ("9000003", 25): ("nedeľa po prechode na zimný čas 8:00-11:00", [(W, IN, "08:00:00"), (W, OUT, "11:00:00")]),
    ("9000003", 30): ("NIČ NEZAZNAMENANÉ (zabudnutý deň)", []),
    # 9000004: prerušenia, 7:30 - 15:30
    ("9000004", 1): ("dlhý deň 6:15-17:45", [(W, IN, "06:15:30"), (W, OUT, "17:45:10")]),
    ("9000004", 5): ("lekár 8:00-8:45 a obed 12:00-12:30", [(W, IN, "07:00:00"), (D, OUT, "08:00:00"), (W, IN, "08:45:00"), (W, OUT, "12:00:00"), (W, IN, "12:30:00"), (W, OUT, "15:30:00")]),
    ("9000004", 6): ("súkromné 15:00 bez návratu", [(W, IN, "07:00:00"), (P, OUT, "15:00:00")]),
    ("9000004", 7): ("dve prerušenia: lekár a súkromné", [(W, IN, "07:00:00"), (D, OUT, "09:00:00"), (W, IN, "10:00:00"), (P, OUT, "11:00:00"), (W, IN, "11:20:00"), (W, OUT, "15:30:00")]),
    ("9000004", 12): ("sprievod rodiny 10:00 bez návratu (doplnenie do fondu)", [(W, IN, "07:30:00"), (F, OUT, "10:00:00")]),
    ("9000004", 21): ("dovolenka celý deň", [(L, OUT, "07:00:00")]),
    ("9000004", 22): ("dovolenka celý deň", [(L, OUT, "07:00:00")]),
}
BASE = {"9000001": ("07:00", "15:30"), "9000002": ("07:30", "16:00"), "9000003": ("07:15", "15:45"), "9000004": ("07:30", "15:30")}


def build(year, month):
    scen = []
    last = calendar.monthrange(year, month)[1]
    for osc in USERS:
        for d in range(1, last + 1):
            day = dt.date(year, month, d)
            key = (osc, d)
            if key in SPECIAL:
                popis, pun = SPECIAL[key]
            elif day.weekday() < 5:
                rng = random.Random(f"{osc}-{year}-{month}-{d}")
                pun = normal(rng, *BASE[osc])
                popis = "bežný deň"
                if rng.random() < 0.3:
                    pun = with_lunch(pun)
                    popis = "bežný deň s obedom mimo pracoviska"
            else:
                continue
            if pun:
                scen.append(dict(osc=osc, den=day.isoformat(), popis=popis, razenia=[list(x) for x in pun]))
            else:
                scen.append(dict(osc=osc, den=day.isoformat(), popis=popis, razenia=[]))
    return scen


def events(scen):
    ev = []
    for s in scen:
        for kod, sm, hm in s["razenia"]:
            naive = dt.datetime.strptime(s["den"] + " " + hms(hm), "%Y-%m-%d %H:%M:%S")
            loc = naive.replace(tzinfo=TZ)
            ev.append(dict(osc=s["osc"], kod=kod, sm=sm, loc=naive, utc=loc.astimezone(UTC).replace(tzinfo=None)))
    ev.sort(key=lambda e: (e["utc"], e["osc"], e["sm"]))
    return ev


def write_import(out, ev, ym):
    lines = ["osobne_cislo;datum;cas;kod;smer"]
    for e in sorted(ev, key=lambda e: (e["osc"], e["loc"], e["sm"])):
        lines.append(f'{e["osc"]};{e["loc"].strftime("%Y-%m-%d")};{e["loc"].strftime("%H:%M:%S")};{e["kod"]};{e["sm"]}')
    open(f"{out}/import_do_terminalu_{ym}.csv", "wb").write(b"\xef\xbb\xbf" + ("\r\n".join(lines) + "\r\n").encode())


def write_contract(out, ev, ym, first_id=301):
    """Súbor v tvare exportu kontraktu v1: zdroj `correction`, zariadenie bez ID (ako po testovacom importe)."""
    # poradie reťaze = poradie zápisu: podľa osoby a času, ako ho zapisuje testovací import
    ordered = sorted(ev, key=lambda e: (e["osc"], e["utc"], e["sm"]))
    now = dt.datetime(2026, 11, 3, 8, 30, 0)
    rows, last = [], {}
    for n, e in enumerate(ordered):
        pid = first_id + n
        uid = USERS[e["osc"]]
        cu = "c0000000-0000-4000-8000-%012d" % pid
        prev = last.get(uid, "GENESIS")
        iso = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
        srv = now + dt.timedelta(seconds=n)
        h = hashlib.sha256("|".join([prev, uid, e["kod"], e["sm"], iso(e["utc"])[:-1], iso(srv)[:-1], cu]).encode()).hexdigest()
        last[uid] = h
        drift = round((srv - e["utc"]).total_seconds() / 60)
        rows.append([1, ORG, pid, cu, e["osc"], e["kod"], e["sm"], e["loc"].strftime("%Y-%m-%d %H:%M:%S"), iso(e["utc"]), iso(srv),
                     drift, "correction", "confirmed", "", uid, prev, h])
    head = ["contract_version", "organization_id", "punch_id", "external_id", "personnel_number", "code", "direction", "client_time_local",
            "client_time_utc", "server_time_utc", "drift_minutes", "source", "device_verification", "device_id", "user_uuid", "prev_hash", "record_hash"]
    num = {"contract_version", "punch_id", "drift_minutes"}
    q = lambda v: '"' + str(v).replace('"', '""') + '"'
    lines = [";".join(head)] + [";".join(str(v) if head[i] in num else q(v) for i, v in enumerate(r)) for r in rows]
    body = "\r\n".join(lines) + "\r\n"
    digest = hashlib.sha256(body.encode()).hexdigest()
    data = b"\xef\xbb\xbf" + (body + "#END;rows=%d;sha256=%s\r\n" % (len(rows), digest)).encode()
    open(f"{out}/terminal_test_{ym}.csv", "wb").write(data)
    return len(rows), digest


def main():
    out = sys.argv[1]
    year = int(sys.argv[2]) if len(sys.argv) > 2 else 2026
    month = int(sys.argv[3]) if len(sys.argv) > 3 else 10
    ym = f"{year}-{month:02d}"
    scen = build(year, month)
    ev = events(scen)
    write_import(out, ev, ym)
    n, digest = write_contract(out, ev, ym)
    json.dump(scen, open(f"{out}/popis_{ym}.json", "w"), ensure_ascii=False, indent=1)
    special = sum(1 for s in scen if s["popis"] not in ("bežný deň", "bežný deň s obedom mimo pracoviska"))
    print(f"mesiac {ym}: dní so scenárom {len(scen)}, razení {n}, zvláštnych dní {special}, sha256 {digest[:16]}")


if __name__ == "__main__":
    main()
