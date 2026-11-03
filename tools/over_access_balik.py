#!/usr/bin/env python3
"""Overenie balíka Access (priečinok access/) pred vydaním a príprava textu vydania. Len štandardná knižnica.

Použitie (z koreňa repozitára):
    python3 -I tools/over_access_balik.py                       # skontroluje balík, chyby vypíše, kód 1 = chyba
    python3 -I tools/over_access_balik.py --verzia              # vypíše verziu balíka z manifest.json
    python3 -I tools/over_access_balik.py --poznamky subor.md   # zapíše text vydania (po úspešnej kontrole)

Kontroluje:
  1. manifest.json: každý modul existuje, jeho SHA-256 a verzia ('@Verzia) sedia, v moduly/ nie je nič navyše.
  2. Do verejného balíka nepatrí nezverejnený modul snímača SKE (mod_07_SKE), databáza (.accdb, .laccdb, .mdb), protokoly (.log) ani ZIP.
  3. Horná sekcia CHANGELOG.md je verzia balíka z manifest.json.
Nič nemení.
"""
import argparse, hashlib, json, os, re, sys

ZAKAZANE_PRIPONY = (".accdb", ".laccdb", ".mdb", ".ldb", ".log", ".zip")
ZAKAZANY_MODUL = re.compile(r"^mod_07_SKE", re.I)
ZAKAZANE_RETAZCE = ("PrNastavenieSKE",)
TEXTOVE = (".bas", ".md", ".txt", ".ps1", ".cmd", ".json", ".py", ".csv", ".gitignore", ".gitattributes")
RE_VERZIA = re.compile(r"^\d+\.\d+\.\d+$")
RE_MOD_VERZIA = re.compile(r"^'@Verzia\s+(\d+\.\d+\.\d+)\s*$")
RE_SEKCIA = re.compile(r"^## Balík (\d+\.\d+\.\d+)\s*$")


def sha(b):
    return hashlib.sha256(b).hexdigest()


def citaj_bajty(cesta):
    with open(cesta, "rb") as f:
        return f.read()


def citaj_text(cesta):
    return citaj_bajty(cesta).decode("utf-8-sig")


def nacitaj_manifest(koren):
    return json.loads(citaj_text(os.path.join(koren, "manifest.json")))


def kontrola(koren):
    """Vráti zoznam chýb (prázdny = v poriadku)."""
    chyby = []
    try:
        m = nacitaj_manifest(koren)
    except (OSError, ValueError) as e:
        return ["manifest.json sa nedá načítať: %s" % e]
    ver = str(m.get("balik", ""))
    if not RE_VERZIA.match(ver):
        chyby.append("manifest.json: neplatná verzia balíka %r" % ver)
    moduly = m.get("moduly", {})
    zoznam = set()
    for nazov, e in sorted(moduly.items()):
        cesta = os.path.join(koren, *e["subor"].split("/"))
        zoznam.add(os.path.normcase(os.path.abspath(cesta)))
        if ZAKAZANY_MODUL.match(nazov):
            chyby.append("%s: modul snímača SKE sa do verejného balíka nesmie dostať" % nazov)
        try:
            surove = citaj_bajty(cesta)
        except OSError:
            chyby.append("%s: súbor %s chýba" % (nazov, e["subor"]))
            continue
        if sha(surove) != e["sha256"]:
            chyby.append("%s: SHA-256 súboru nesedí s manifest.json (súbor sa zmenil, prepočítajte manifest cez access/tools/zostav_balik.py)" % nazov)
        riadky = surove.decode("utf-8-sig").replace("\r\n", "\n").split("\n")
        mv = RE_MOD_VERZIA.match(riadky[1]) if len(riadky) > 1 else None
        if not mv:
            chyby.append("%s: 2. riadok nie je  '@Verzia X.Y.Z" % nazov)
        elif mv.group(1) != e["verzia"]:
            chyby.append("%s: verzia v súbore %s, v manifest.json %s" % (nazov, mv.group(1), e["verzia"]))
    mdir = os.path.join(koren, "moduly")
    for f in sorted(os.listdir(mdir)) if os.path.isdir(mdir) else []:
        p = os.path.normcase(os.path.abspath(os.path.join(mdir, f)))
        if f.lower().endswith(".bas") and p not in zoznam:
            chyby.append("moduly/%s nie je v manifest.json%s" % (f, " (modul snímača SKE nepatrí do verejného balíka)" if ZAKAZANY_MODUL.match(f) else ""))
    for adr, podadr, subory in os.walk(koren):
        podadr[:] = [d for d in podadr if d != ".git"]
        for f in subory:
            rel = os.path.relpath(os.path.join(adr, f), koren).replace(os.sep, "/")
            if f.lower().endswith(ZAKAZANE_PRIPONY):
                chyby.append("%s: do verejného balíka nepatrí (databáza, protokol alebo ZIP)" % rel)
            if f.lower().endswith(TEXTOVE):
                t = citaj_bajty(os.path.join(adr, f)).decode("utf-8", "ignore")
                for r in ZAKAZANE_RETAZCE:
                    if r in t:
                        chyby.append("%s: obsahuje reťazec %r z nezverejneného modulu" % (rel, r))
    try:
        sekcia = hlavicka_changelogu(koren)
        if sekcia != ver:
            chyby.append("CHANGELOG.md: horná sekcia je balík %s, manifest.json má %s" % (sekcia, ver))
    except OSError:
        chyby.append("CHANGELOG.md chýba")
    return chyby


def hlavicka_changelogu(koren):
    for r in citaj_text(os.path.join(koren, "CHANGELOG.md")).splitlines():
        m = RE_SEKCIA.match(r)
        if m:
            return m.group(1)
    return None


def horna_sekcia(koren):
    """Text hornej sekcie CHANGELOG.md bez nadpisu."""
    out, v = [], False
    for r in citaj_text(os.path.join(koren, "CHANGELOG.md")).splitlines():
        if RE_SEKCIA.match(r):
            if v:
                break
            v = True
            continue
        if v:
            out.append(r)
    return "\n".join(out).strip()


def poznamky(koren):
    ver = nacitaj_manifest(koren)["balik"]
    return (
        "Dochádzkový systém (Microsoft Access + VBA), balík %(v)s. Inštalátor: na vašom počítači vytvorí alebo aktualizuje databázu `.accdb`. "
        "Databáza nie je súčasťou tohto vydania, vytvorí ju inštalátor.\n\n"
        "## Zmeny v balíku %(v)s\n\n%(zmeny)s\n\n"
        "## Overenie stiahnutého súboru\n\n"
        "V PowerShelli: `Get-FileHash .\\Dochadzka-Instalator-%(v)s.zip -Algorithm SHA256`. Výsledok musí sedieť s hodnotou v `SHA256SUMS.txt`.\n\n"
        "## Inštalácia\n\n"
        "Rozbaľte ZIP, postupujte podľa `README.txt` v priečinku a spustite `Instaluj.cmd`. Potrebujete Windows a plnú verziu Microsoft Access 2010 alebo novšiu "
        "(Access Runtime nestačí). Ak ZIP stiahnete z internetu, pred rozbalením ho v Prieskumníkovi otvorte cez Vlastnosti a zaškrtnite Odblokovať.\n\n"
        "Prototyp v testovacej prevádzke, bez záruky. Čo je a nie je overené, je v zmenách vyššie a v `README.md` priečinka `access/`.\n"
    ) % {"v": ver, "zmeny": horna_sekcia(koren)}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--koren", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "access"), help="priečinok balíka (predvolene access/)")
    ap.add_argument("--verzia", action="store_true", help="iba vypíše verziu balíka")
    ap.add_argument("--poznamky", metavar="SUBOR", help="zapíše text vydania")
    a = ap.parse_args()
    koren = os.path.abspath(a.koren)
    chyby = kontrola(koren)
    if chyby:
        for c in chyby:
            print("CHYBA: " + c, file=sys.stderr)
        sys.exit(1)
    ver = nacitaj_manifest(koren)["balik"]
    if a.verzia:
        print(ver)
        return
    if a.poznamky:
        with open(a.poznamky, "w", encoding="utf-8", newline="\n") as f:
            f.write(poznamky(koren))
    print("OK: balík %s, modulov %d, kontrolné súčty sedia." % (ver, len(nacitaj_manifest(koren)["moduly"])))


if __name__ == "__main__":
    main()
