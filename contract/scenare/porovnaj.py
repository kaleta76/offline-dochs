#!/usr/bin/env python3
"""Porovnanie denných sald: terminál (aplikácia) a Access.

Použitie:
  python3 -I porovnaj.py --terminal terminal_saldo_202610.csv --access terminal_test_access_vysledky.csv
                         [--ocakavane ocakavane_saldo_2026-10.csv] [--popis popis_2026-10.json] [--vystup PRIEČINOK]
                         [--iba-osoby-z-accessu]

  --terminal   súbor „Stiahnuť saldá“ z administrácie terminálu (alebo ocakavane_saldo_*.csv ako náhrada)
  --access     terminal_test_access_vysledky.csv zo samočinného testu Accessu (Karta 7 Exporty)
  --ocakavane  voliteľne referenčné saldá z enginu terminálu (kontrola, že terminál spracoval import podľa očakávania)
  --popis      voliteľne popis scenárov po dňoch (vypíše sa pri rozdieloch); dni s kľúčom "preskocit": true sa
               z porovnania vynechajú (napr. dni, ktoré prevodník z_accessu.py nevedel previesť)
  --iba-osoby-z-accessu
               porovná len osoby, ktoré sú v súbore z Accessu (v termináli môžu byť aj ďalšie účty, napr. správca)

Porovnáva sa fond_min a saldo_min (rozhodujúce); odpracovane_min je doplnková informácia, lebo Access a terminál
ju môžu počítať s inou hranicou (napr. započítanie lekára). Deň, ktorý v jednom súbore chýba, sa berie ako deň
s nulami a v správe sa označí. Výstup: správa na obrazovku, porovnanie_report.txt a porovnanie_rozdiely.csv.
Kód ukončenia: 0 = všetky dni sedia (fond aj saldo), 1 = aspoň jeden rozdiel, 2 = chyba vstupu.
Používa len štandardnú knižnicu Pythonu.
"""
import argparse
import csv
import io
import json
import sys


def citaj(path):
    with open(path, "rb") as f:
        text = f.read().decode("utf-8-sig")
    rows = list(csv.DictReader(io.StringIO(text), delimiter=";"))
    if not rows:
        raise SystemExit(f"Súbor {path} neobsahuje žiadne riadky.")
    for need in ("osobne_cislo", "datum", "fond_min", "odpracovane_min", "saldo_min"):
        if need not in rows[0]:
            raise SystemExit(f"V súbore {path} chýba stĺpec {need}.")
    out = {}
    for r in rows:
        key = (r["osobne_cislo"].strip(), r["datum"].strip()[:10])
        out[key] = {
            "fond": int(float(r["fond_min"] or 0)),
            "odpr": int(float(r["odpracovane_min"] or 0)),
            "saldo": int(float(r["saldo_min"] or 0)),
            "typ": r.get("typ_dna", ""),
            "rozpis": r.get("rozpis", ""),
            "intervaly": r.get("intervaly", ""),
            "anomalie": r.get("anomalie", ""),
            "otvoreny": r.get("otvoreny", ""),
        }
    return out


def hm(m):
    sign = "-" if m < 0 else "+"
    a = abs(m)
    return f"{sign}{a // 60}:{a % 60:02d}"


def porovnaj(a, b, nazov_a, nazov_b):
    keys = sorted(set(a) | set(b))
    nula = {"fond": 0, "odpr": 0, "saldo": 0, "typ": "", "rozpis": "", "intervaly": "", "anomalie": "", "otvoreny": ""}
    rozdiely, len_odpr, zhoda = [], [], 0
    for k in keys:
        x, y = a.get(k, nula), b.get(k, nula)
        chyba = []
        if k not in a:
            chyba.append(f"chýba v {nazov_a}")
        if k not in b:
            chyba.append(f"chýba v {nazov_b}")
        if x["fond"] != y["fond"] or x["saldo"] != y["saldo"]:
            rozdiely.append((k, x, y, chyba))
        elif x["odpr"] != y["odpr"]:
            len_odpr.append((k, x, y))
            zhoda += 1
        else:
            zhoda += 1
    return keys, rozdiely, len_odpr, zhoda


def sumy(a):
    s = {}
    for (osc, _), v in a.items():
        t = s.setdefault(osc, {"fond": 0, "odpr": 0, "saldo": 0})
        for f in t:
            t[f] += v[f]
    return s


def vypis_pary(rep, a, b, nazov_a, nazov_b, popis):
    keys, rozdiely, len_odpr, zhoda = porovnaj(a, b, nazov_a, nazov_b)
    rep.append(f"Porovnané dni: {len(keys)}, zhodných (fond aj saldo): {zhoda}, rozdielnych: {len(rozdiely)}, "
               f"len iné odpracované minúty: {len(len_odpr)}")
    sa, sb = sumy(a), sumy(b)
    rep.append("")
    rep.append(f"Súčty za obdobie podľa osoby ({nazov_a} / {nazov_b}):")
    rep.append(f"{'osoba':<10}{'fond':>14}{'odpracované':>20}{'saldo':>20}  výsledok")
    for osc in sorted(set(sa) | set(sb)):
        x = sa.get(osc, {"fond": 0, "odpr": 0, "saldo": 0})
        y = sb.get(osc, {"fond": 0, "odpr": 0, "saldo": 0})
        ok = x["fond"] == y["fond"] and x["saldo"] == y["saldo"]
        rep.append(f"{osc:<10}{x['fond']:>6}/{y['fond']:<7}{x['odpr']:>9}/{y['odpr']:<10}{x['saldo']:>9}/{y['saldo']:<10}  "
                   f"{'SEDÍ' if ok else 'ROZDIEL saldo ' + hm(x['saldo'] - y['saldo'])}")
    if rozdiely:
        rep.append("")
        rep.append("Rozdielne dni:")
        for k, x, y, chyba in rozdiely:
            rep.append(f"  {k[0]} {k[1]}  {nazov_a}: fond {x['fond']} odpr {x['odpr']} saldo {x['saldo']:+d}   "
                       f"{nazov_b}: fond {y['fond']} odpr {y['odpr']} saldo {y['saldo']:+d}   rozdiel salda {hm(x['saldo'] - y['saldo'])}"
                       + (f"   [{'; '.join(chyba)}]" if chyba else ""))
            p = popis.get(k)
            if p:
                rep.append(f"      scenár: {p}")
            if x["rozpis"]:
                rep.append(f"      {nazov_a} rozpis: {x['rozpis']}{'  (OTVORENÝ DEŇ)' if x['otvoreny'] == '1' else ''}")
            if y["intervaly"] or y["anomalie"]:
                rep.append(f"      {nazov_b} intervaly: {y['intervaly'] or '-'}   anomálie: {y['anomalie'] or '-'}")
    return rozdiely


def main():
    ap = argparse.ArgumentParser(description="Porovnanie sald terminál / Access")
    ap.add_argument("--terminal", required=True)
    ap.add_argument("--access", required=True)
    ap.add_argument("--ocakavane")
    ap.add_argument("--popis")
    ap.add_argument("--vystup", default=".")
    ap.add_argument("--iba-osoby-z-accessu", action="store_true")
    arg = ap.parse_args()

    term, acc = citaj(arg.terminal), citaj(arg.access)
    popis, preskocit = {}, set()
    if arg.popis:
        for s in json.load(open(arg.popis, encoding="utf-8")):
            popis[(s["osc"], s["den"])] = s["popis"]
            if s.get("preskocit"):
                preskocit.add((s["osc"], s["den"]))
    osoby = {o for o, _ in acc} if arg.iba_osoby_z_accessu else None
    vyradene_osoby = sorted({o for o, _ in term} - osoby) if osoby is not None else []

    def zuz(d):
        return {k: v for k, v in d.items() if k not in preskocit and (osoby is None or k[0] in osoby)}

    term, acc = zuz(term), zuz(acc)
    rep = ["POROVNANIE SALDÁ: terminál a Access", ""]
    rep.append(f"Terminál: {arg.terminal}  ({len(term)} riadkov)")
    rep.append(f"Access:   {arg.access}  ({len(acc)} riadkov)")
    if preskocit:
        rep.append(f"Preskočené dni (nepreviedli sa do terminála): {len(preskocit)}")
    if vyradene_osoby:
        rep.append(f"Osoby len v termináli (vynechané z porovnania): {', '.join(vyradene_osoby)}")
    rep.append("")
    stav = 0
    if arg.ocakavane:
        exp = zuz(citaj(arg.ocakavane))
        rep.append("A. Terminál voči očakávanému výsledku enginu (kontrola importu a výpočtu v termináli)")
        r1 = vypis_pary(rep, term, exp, "terminál", "očakávané", popis)
        rep.append("")
        if r1:
            stav = 1
    rep.append("B. Terminál voči Accessu (hlavné porovnanie)")
    r2 = vypis_pary(rep, term, acc, "terminál", "Access", popis)
    if r2:
        stav = 1
    rep.append("")
    rep.append("VÝSLEDOK: " + ("všetky dni sedia (fond aj saldo)" if stav == 0 else "NAŠLI SA ROZDIELY - pozri vyššie"))
    text = "\n".join(rep)
    print(text)
    with open(f"{arg.vystup}/porovnanie_report.txt", "w", encoding="utf-8") as f:
        f.write(text + "\n")
    with open(f"{arg.vystup}/porovnanie_rozdiely.csv", "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f, delimiter=";")
        w.writerow(["osobne_cislo", "datum", "t_fond", "t_odpracovane", "t_saldo", "a_fond", "a_odpracovane", "a_saldo", "rozdiel_saldo", "scenar", "a_intervaly", "a_anomalie"])
        for k, x, y, _ in r2:
            w.writerow([k[0], k[1], x["fond"], x["odpr"], x["saldo"], y["fond"], y["odpr"], y["saldo"], x["saldo"] - y["saldo"],
                        popis.get(k, ""), y["intervaly"], y["anomalie"]])
    return stav


if __name__ == "__main__":
    sys.exit(main())
