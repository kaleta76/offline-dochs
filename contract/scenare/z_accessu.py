#!/usr/bin/env python3
"""Skutočné dáta z Accessu do testu terminálu: prevod dochs_test_sample.json na vstupy pre terminál a na porovnanie.

Access (karta 7 Exporty, tlačidlo „Exportovať konfiguráciu a testovacie dáta (JSON)“, vyplnený mesiac a osobné čísla)
zapíše okrem dochs_config.json aj dochs_test_sample.json: platné razenia (raw_events), schválené automatické opravy
(auto_events) a výsledok výpočtu po dňoch (expected_daily_results). Tento skript z nich pripraví:

  import_do_terminalu_RRRR-MM.csv   vstup pre „Testovací import“ v administrácii terminála (osobne_cislo;datum;cas;kod;smer);
                                    ak má viac než --max-riadkov riadkov, rozdelí sa na časti (zamestnanec sa nikdy nedelí)
  access_vysledky_RRRR-MM.csv       saldá, ktoré Access vypočítal z tých istých razení (formát pre porovnaj.py --access)
  popis_RRRR-MM.json                popis dňa (razenia Accessu a poznámky k prevodu), dni na preskočenie (vstup pre porovnaj.py --popis)
  report_prevodu_RRRR-MM.txt        čo sa previedlo, čo sa nedalo, aký denný fond nastaviť v termináli

Použitie:
  python3 -I z_accessu.py dochs_test_sample.json VYSTUPNY_PRIECINOK [--config dochs_config.json] [--max-riadkov 1400]

  --config   voliteľne dochs_config.json z Accessu: použije sa jeho terminal_code_map (inak predvolené mapovanie z kontraktu)

POZOR: výstupy obsahujú SKUTOČNÉ osobné čísla a skutočné časy razení. Nepatria do repozitára ani do verejného chatu;
priečinok zvoľte mimo klonu repozitára. Skript nič nikam neodosiela. Používa len štandardnú knižnicu Pythonu.

Prevod je zámerne jednoduchý a čestný: čo terminál nevie vyjadriť (prerušenie bez kódu v termináli), sa NEPREVÁDZA,
celý taký deň sa označí na preskočenie v porovnaní a vypíše sa v správe. Nič sa nehádže.
"""
import argparse
import collections
import csv
import datetime as dt
import io
import json
import os
import sys

# Predvolené mapovanie (contract/README.md, tabuľka TerminalMapaKodov v Accesse): číslo prerušenia -> kód terminála.
# 1 (práca) a 7 (obed) sa riešia zvlášť. FAMILY (16) a PRIV (13) sú v Accesse označené „overiť“.
PREDVOLENE = {2: "DOCTOR", 12: "TRIP", 8: "LEAVE", 11: "SICK", 16: "FAMILY", 13: "PRIV"}
MAX_RIADKOV = 1400  # testovací import v termináli prijme najviac 1500 riadkov naraz


def nacitaj_json(cesta):
    try:
        with open(cesta, "rb") as f:
            return json.loads(f.read().decode("utf-8-sig"))
    except (OSError, ValueError) as e:
        raise SystemExit(f"Súbor {cesta} sa nedá prečítať ako JSON: {e}")


def mapovanie_z_configu(cfg):
    """Z dochs_config.json (terminal_code_map) obrátené mapovanie číslo prerušenia -> kód terminála."""
    out = {}
    for m in cfg.get("terminal_code_map", []):
        kod, prer = m.get("code"), m.get("interruption")
        if isinstance(kod, str) and isinstance(prer, int) and kod != "WORK" and prer not in (1, 7):
            out[prer] = kod
    return out


def hhmm(min_):
    return f"{min_ // 60:02d}:{min_ % 60:02d}:00"


def popis_udalosti(ev):
    return f"{hhmm(ev['cas_min'])[:5]} č.{ev['kod']}/{ev['smer']}"


def preved_den(udalosti, mapa):
    """Razenia jedného zamestnanca a dňa -> (riadky [(cas, kod, smer)], poznámky, dôvod nepreložiteľnosti alebo None).
    Pravidlá (rovnaké ako v mod_19_TerminalImport, opačným smerom):
      č.1 Z = WORK/IN, č.1 K = WORK/OUT;  č.7 (obed) Z = WORK/OUT, K = WORK/IN;
      iné prerušenie X Z = KOD/OUT, K = WORK/IN (ak po ňom deň pokračuje; K ako posledné razenie dňa sa vynechá,
      lebo terminál celodennú neprítomnosť vyjadruje jediným razením KOD/OUT)."""
    ev = sorted(udalosti, key=lambda e: (e["cas_min"],))
    riadky, poznamky = [], []
    for i, e in enumerate(ev):
        kod, smer, cas = e["kod"], e["smer"], e["cas_min"]
        if not isinstance(cas, int) or not 0 <= cas < 1440:
            return [], poznamky, f"čas razenia mimo dňa ({cas})"
        if smer not in ("Z", "K"):
            return [], poznamky, f"razenie bez smeru Z/K (prerušenie {kod})"
        if kod == 1:
            riadky.append((cas, "WORK", "IN" if smer == "Z" else "OUT"))
        elif kod == 7:
            riadky.append((cas, "WORK", "OUT" if smer == "Z" else "IN"))
        elif kod in mapa:
            if smer == "Z":
                riadky.append((cas, mapa[kod], "OUT"))
            elif i == len(ev) - 1:
                poznamky.append(f"koniec prerušenia {kod} ako posledné razenie dňa sa vynechal")
            else:
                riadky.append((cas, "WORK", "IN"))
        else:
            return [], poznamky, f"prerušenie č. {kod} nemá v termináli kód"
    # rovnaké razenie dvakrát (rovnaký čas, kód, smer) terminál v súbore aj tak zahodí
    videne, bez = set(), []
    for r in riadky:
        if r in videne:
            poznamky.append(f"duplicitné razenie {hhmm(r[0])[:5]} {r[1]}/{r[2]} vynechané")
            continue
        videne.add(r)
        bez.append(r)
    return bez, poznamky, None


def najcastejsi(zoznam):
    return collections.Counter(zoznam).most_common(1)[0][0] if zoznam else None


def vyrob(vstup, cfg, max_riadkov=MAX_RIADKOV):
    """Hlavná logika (čistá funkcia, aby sa dala testovať). Vráti slovník s obsahom výstupov."""
    mapa = dict(PREDVOLENE)
    if cfg:
        mapa = mapovanie_z_configu(cfg) or mapa
    raw = vstup.get("raw_events") or []
    auto = vstup.get("auto_events") or []
    dni = vstup.get("expected_daily_results") or []
    od, do = vstup.get("date_from"), vstup.get("date_to")
    if not od or not do:
        raise SystemExit("Vstup nie je dochs_test_sample.json z Accessu (chýba date_from / date_to).")

    po_dnoch = collections.defaultdict(list)
    for e in raw:
        po_dnoch[(str(e["osc"]), e["datum"])].append(e)
    s_opravami = collections.defaultdict(list)
    for e in auto:
        s_opravami[(str(e["osc"]), e["datum"])].append(e)

    riadky_osoby = collections.defaultdict(list)  # osc -> [(datum, cas, kod, smer)]
    popis, preskocit = {}, {}
    nepreklad = collections.Counter()
    for (osc, den), ev in sorted(po_dnoch.items()):
        riadky, poznamky, dovod = preved_den(ev, mapa)
        p = [popis_udalosti(e) for e in sorted(ev, key=lambda e: e["cas_min"])]
        if (osc, den) in s_opravami:
            poznamky.append("Access doplnil schválenú automatickú opravu (" + ", ".join(
                f"{popis_udalosti(a)} {a.get('typ', '')}".strip() for a in s_opravami[(osc, den)]) + "); terminál ju nemá")
        if dovod:
            preskocit[(osc, den)] = dovod
            for e in ev:
                if e["kod"] not in (1, 7) and e["kod"] not in mapa:
                    nepreklad[e["kod"]] += 1
            poznamky.append("DEŇ SA NEPREVÁDZA: " + dovod)
        else:
            for cas, kod, smer in riadky:
                riadky_osoby[osc].append((den, cas, kod, smer))
        popis[(osc, den)] = ("Access: " + ", ".join(p)) + (" | " + "; ".join(poznamky) if poznamky else "")
    for (osc, den), a in s_opravami.items():
        if (osc, den) not in po_dnoch:
            popis[(osc, den)] = "Access má len automatickú opravu: " + ", ".join(popis_udalosti(x) for x in a)
            preskocit[(osc, den)] = "deň má len virtuálne razenia z automatickej opravy"

    # --- výsledky Accessu po dňoch (bez preskočených dní)
    access = []
    for d in dni:
        k = (str(d["osc"]), d["datum"])
        if k in preskocit:
            continue
        access.append([k[0], k[1], d.get("typ_dna", ""), d.get("denny_fond_min", 0), d.get("odpracovane_min", 0),
                       d.get("saldo_min", 0), d.get("detaily", "") or ""])
        popis.setdefault(k, "")
    # dni s razeniami, ku ktorým Access nemá riadok výsledku: porovnanie ukáže „chýba v Access“
    # --- denný fond podľa osoby (z pracovných dní s výsledkom)
    fondy = collections.defaultdict(list)
    for d in dni:
        k = (str(d["osc"]), d["datum"])
        if k in preskocit:
            continue
        if str(d.get("typ_dna", "P"))[:1] == "P" and isinstance(d.get("denny_fond_min"), int) and d["denny_fond_min"] > 0:
            fondy[str(d["osc"])].append(d["denny_fond_min"])

    # --- rozdelenie importu na časti (zamestnanec sa nedelí)
    casti, aktualna, n = [], [], 0
    for osc in sorted(riadky_osoby):
        zaznamy = sorted(riadky_osoby[osc])
        if len(zaznamy) > max_riadkov:
            raise SystemExit(f"Zamestnanec {osc} má {len(zaznamy)} razení, viac než --max-riadkov {max_riadkov}. Zúžte mesiac.")
        if n + len(zaznamy) > max_riadkov and aktualna:
            casti.append(aktualna)
            aktualna, n = [], 0
        aktualna.extend((osc,) + z for z in zaznamy)
        n += len(zaznamy)
    if aktualna:
        casti.append(aktualna)

    return {
        "od": od, "do": do, "mapa": mapa, "casti": casti, "access": access, "popis": popis, "preskocit": preskocit,
        "nepreklad": nepreklad, "fondy": fondy, "osoby": sorted({o for o, _ in po_dnoch} | {str(d['osc']) for d in dni}),
        "pocet_razeni": sum(len(c) for c in casti), "pocet_opravy": sum(len(v) for v in s_opravami.values()),
    }


def csv_text(hlavicka, riadky):
    buf = io.StringIO()
    w = csv.writer(buf, delimiter=";", lineterminator="\r\n")
    w.writerow(hlavicka)
    w.writerows(riadky)
    return "﻿" + buf.getvalue()


def sprava(v, nazvy_importu):
    r = [f"PREVOD Z ACCESSU DO TESTU TERMINÁLA ({v['od']} až {v['do']})", ""]
    r.append(f"Zamestnancov vo vstupe: {len(v['osoby'])}")
    r.append(f"Razení v súboroch pre terminál: {v['pocet_razeni']} (súbory: {', '.join(nazvy_importu) or 'žiadny'})")
    r.append(f"Dní s výsledkom z Accessu na porovnanie: {len(v['access'])}")
    r.append(f"Schválených automatických opráv v Accesse (terminál ich nemá, deň sa môže líšiť): {v['pocet_opravy']}")
    r.append("Mapovanie prerušení na kódy terminála: " + ", ".join(f"{k}->{c}" for k, c in sorted(v["mapa"].items())) + ", 1->WORK, 7->WORK (obed)")
    r.append("")
    if v["preskocit"]:
        r.append(f"DNI, KTORÉ SA NEPREVIEDLI ({len(v['preskocit'])}); v porovnaní sa preskočia (popis_*.json, kľúč preskocit):")
        for (osc, den), dovod in sorted(v["preskocit"].items()):
            r.append(f"  {osc} {den}: {dovod}")
        if v["nepreklad"]:
            r.append("  Prerušenia bez kódu v termináli (počet razení): " + ", ".join(f"č. {k}: {n}" for k, n in sorted(v["nepreklad"].items())))
        r.append("")
    r.append("DENNÝ FOND (z výsledkov Accessu za pracovné dni): terminál má v tejto verzii JEDEN denný fond pre celú organizáciu (DENNY_FOND_HODIN).")
    r.append(f"{'osobné číslo':<14}{'pracovných dní':>15}{'najčastejší fond':>20}{'rôznych fondov':>16}  porovnateľné teraz")
    vsetky = [x for f in v["fondy"].values() for x in f]
    cielovy = najcastejsi(vsetky)
    for osc in sorted(v["fondy"]):
        f = v["fondy"][osc]
        n_rozne = len(set(f))
        ok = n_rozne == 1 and f[0] == cielovy
        r.append(f"{osc:<14}{len(f):>15}{najcastejsi(f):>20}{n_rozne:>16}  {'áno' if ok else 'nie (iný alebo premenlivý fond)'}")
    if cielovy:
        r.append("")
        r.append(f"ODPORÚČANIE: v termináli nastavte DENNY_FOND_HODIN = {cielovy / 60:g} (administrácia > Pravidlá výpočtu) a ZAOKRUHLENIE_PRICHOD aj ZAOKRUHLENIE_ODCHOD = 0.")
        r.append("Zamestnanci s iným alebo premenlivým fondom budú v termináli ukazovať iné saldo, kým terminál nepočíta podľa plánu z Accessu (etapa 2). To nie je chyba prevodu.")
    return "\n".join(r) + "\n"


def zapis(vystup, v):
    os.makedirs(vystup, exist_ok=True)
    mesiac = v["od"][:7] + ("" if v["do"][:7] == v["od"][:7] else "_" + v["do"][:7])
    nazvy = []
    for i, cast in enumerate(v["casti"], 1):
        nazov = f"import_do_terminalu_{mesiac}" + (f"_cast{i}" if len(v["casti"]) > 1 else "") + ".csv"
        with open(os.path.join(vystup, nazov), "w", encoding="utf-8", newline="") as f:
            f.write(csv_text(["osobne_cislo", "datum", "cas", "kod", "smer"], [(o, d, hhmm(c), k, s) for o, d, c, k, s in cast]))
        nazvy.append(nazov)
    with open(os.path.join(vystup, f"access_vysledky_{mesiac}.csv"), "w", encoding="utf-8", newline="") as f:
        f.write(csv_text(["osobne_cislo", "datum", "typ_dna", "fond_min", "odpracovane_min", "saldo_min", "intervaly"], sorted(v["access"])))
    popis = []
    for (osc, den), t in sorted(v["popis"].items()):
        z = {"osc": osc, "den": den, "popis": t}
        if (osc, den) in v["preskocit"]:
            z["preskocit"] = True
        popis.append(z)
    with open(os.path.join(vystup, f"popis_{mesiac}.json"), "w", encoding="utf-8") as f:
        json.dump(popis, f, ensure_ascii=False, indent=1)
    text = sprava(v, nazvy)
    with open(os.path.join(vystup, f"report_prevodu_{mesiac}.txt"), "w", encoding="utf-8") as f:
        f.write(text)
    return text


def main(argv=None):
    ap = argparse.ArgumentParser(description="Prevod dochs_test_sample.json z Accessu na vstupy pre test terminála")
    ap.add_argument("vstup")
    ap.add_argument("vystup")
    ap.add_argument("--config")
    ap.add_argument("--max-riadkov", type=int, default=MAX_RIADKOV)
    a = ap.parse_args(argv)
    cfg = nacitaj_json(a.config) if a.config else None
    v = vyrob(nacitaj_json(a.vstup), cfg, a.max_riadkov)
    print(zapis(a.vystup, v))
    return 0


if __name__ == "__main__":
    sys.exit(main())
