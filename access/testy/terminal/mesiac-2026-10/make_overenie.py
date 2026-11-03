#!/usr/bin/env python3
"""Malý test overenia zariadení (balík 2.11.1): tri vymyslení zamestnanci 9000001 až 9000003, október 2026.
overenie_test_2026-10.csv           9000001 len overené zariadenie A, 9000002 overené A a potom overené B (zmena zariadenia) + jedno neoverené,
                                    9000003 dve neoverené razenia
overenie_test_potvrdene_2026-10.csv to isté, ale neoverené razenia vedúci potvrdil (device_verification = confirmed; hash sa nemení)
"""
import datetime as dt, hashlib, sys, zoneinfo
TZ = zoneinfo.ZoneInfo("Europe/Bratislava"); UTC = dt.timezone.utc
ORG = "0b6f2f0e-5a7e-4b8e-9a43-2c1d5e7a9f01"
USERS = {"9000001": "6d1c3b84-0001-4a2e-8c11-000000000001", "9000002": "6d1c3b84-0002-4a2e-8c11-000000000002", "9000003": "6d1c3b84-0003-4a2e-8c11-000000000003"}
DEV_A = "d0000000-0000-4000-8000-00000000000a"
DEV_B = "d0000000-0000-4000-8000-00000000000b"
# (osc, deň, čas miestny, kód, smer, zariadenie, pôvodné overenie)
EV = [
 ("9000001", "2026-10-05", "07:55:00", "WORK", "IN",  DEV_A, "verified"),
 ("9000001", "2026-10-05", "16:05:00", "WORK", "OUT", DEV_A, "verified"),
 ("9000002", "2026-10-05", "08:00:00", "WORK", "IN",  DEV_A, "verified"),
 ("9000002", "2026-10-05", "16:00:00", "WORK", "OUT", DEV_A, "verified"),
 ("9000002", "2026-10-06", "08:02:00", "WORK", "IN",  DEV_B, "verified"),
 ("9000002", "2026-10-06", "16:03:00", "WORK", "OUT", "",    "unverified"),
 ("9000003", "2026-10-05", "07:50:00", "WORK", "IN",  "",    "unverified"),
 ("9000003", "2026-10-05", "15:55:00", "WORK", "OUT", "",    "unverified"),
]
HEAD = ["contract_version","organization_id","punch_id","external_id","personnel_number","code","direction","client_time_local","client_time_utc","server_time_utc","drift_minutes","source","device_verification","device_id","user_uuid","prev_hash","record_hash"]
NUM = {"contract_version","punch_id","drift_minutes"}
iso = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
q = lambda v: '"' + str(v).replace('"','""') + '"'
def build(potvrdene):
    rows, last = [], {}
    evs = sorted(EV, key=lambda e: (e[0], e[1], e[2]))
    for n, (osc, den, cas, kod, sm, dev, ov) in enumerate(evs):
        pid = 401 + n; uid = USERS[osc]; cu = "e0000000-0000-4000-8000-%012d" % pid
        loc = dt.datetime.strptime(den + " " + cas, "%Y-%m-%d %H:%M:%S"); utc = loc.replace(tzinfo=TZ).astimezone(UTC).replace(tzinfo=None)
        srv = utc + dt.timedelta(seconds=30 + n)   # server o pár sekúnd po razení (online)
        prev = last.get(uid, "GENESIS")
        parts = [prev, uid, kod, sm, iso(utc)[:-1], iso(srv)[:-1], cu] + ([dev] if dev else [])
        h = hashlib.sha256("|".join(parts).encode()).hexdigest(); last[uid] = h
        drift = round((srv - utc).total_seconds() / 60)
        ver = "confirmed" if (potvrdene and ov == "unverified") else ov
        rows.append([1, ORG, pid, cu, osc, kod, sm, loc.strftime("%Y-%m-%d %H:%M:%S"), iso(utc), iso(srv), drift, "terminal", ver, dev, uid, prev, h])
    lines = [";".join(HEAD)] + [";".join(str(v) if HEAD[i] in NUM else q(v) for i, v in enumerate(r)) for r in rows]
    body = "\r\n".join(lines) + "\r\n"
    dig = hashlib.sha256(body.encode()).hexdigest()
    return b"\xef\xbb\xbf" + (body + "#END;rows=%d;sha256=%s\r\n" % (len(rows), dig)).encode()
out = sys.argv[1]
open(out + "/overenie_test_2026-10.csv", "wb").write(build(False))
open(out + "/overenie_test_potvrdene_2026-10.csv", "wb").write(build(True))
print("ok")
