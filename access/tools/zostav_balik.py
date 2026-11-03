#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Zostavenie balíka Dochádzka (manifest.json + ZIP) s kontrolou verzií modulov.

Pravidlo: každý modul v moduly/*.bas má na 2. riadku  '@Verzia X.Y.Z
Ak sa zmení OBSAH modulu (okrem riadku @Verzia), musí byť verzia VYŠŠIA ako v doterajšom manifest.json,
inak zostavenie skončí chybou. Ak sa zmení iba verzia bez zmeny obsahu, vypíše sa upozornenie.

Použitie (z priečinka balíka):
    python tools/zostav_balik.py                      # prekontroluje a prepíše manifest.json
    python tools/zostav_balik.py --balik 2.6.0        # nastaví verziu balíka
    python tools/zostav_balik.py --zip                # vytvorí aj ZIP vedľa priečinka balíka
    python tools/zostav_balik.py --bump mod_14_ImportModelu   # zvýši patch verziu modulu a zostaví
"""
import argparse, datetime, hashlib, json, os, re, sys, zipfile

KOREN = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
MODULY = os.path.join(KOREN, "moduly")
MANIFEST = os.path.join(KOREN, "manifest.json")
RE_VER = re.compile(r"^'@Verzia\s+(\d+)\.(\d+)\.(\d+)\s*$")
RE_NAME = re.compile(r'^Attribute VB_Name = "([^"]+)"')
ZRUSENE = ["modExportLovableConfig", "mod_UI_Tab_AutoOprava"]


def sha(b):
    return hashlib.sha256(b).hexdigest()


def nacitaj_modul(cesta):
    surove = open(cesta, "rb").read()
    text = surove.decode("utf-8-sig")
    riadky = text.replace("\r\n", "\n").split("\n")
    m = RE_NAME.match(riadky[0]) if riadky else None
    if not m:
        raise SystemExit("CHYBA %s: 1. riadok musí byť  Attribute VB_Name = \"...\"" % cesta)
    nazov = m.group(1)
    if nazov != os.path.splitext(os.path.basename(cesta))[0]:
        raise SystemExit("CHYBA %s: názov modulu (%s) sa nezhoduje s názvom súboru" % (cesta, nazov))
    mv = RE_VER.match(riadky[1]) if len(riadky) > 1 else None
    if not mv:
        raise SystemExit("CHYBA %s: 2. riadok musí byť  '@Verzia X.Y.Z" % cesta)
    verzia = tuple(int(x) for x in mv.groups())
    obsah = "\n".join(riadky[:1] + riadky[2:]).rstrip("\n") + "\n"
    return nazov, verzia, sha(surove), sha(obsah.encode("utf-8"))


def vs(t):
    return ".".join(str(x) for x in t)


def zvys_patch(nazov):
    cesta = os.path.join(MODULY, nazov + ".bas")
    t = open(cesta, encoding="utf-8").read()
    riadky = t.split("\n")
    m = RE_VER.match(riadky[1])
    if not m:
        raise SystemExit("Modul %s nemá riadok '@Verzia" % nazov)
    a, b, c = (int(x) for x in m.groups())
    riadky[1] = "'@Verzia %d.%d.%d" % (a, b, c + 1)
    open(cesta, "w", encoding="utf-8", newline="\n").write("\n".join(riadky))
    print("Modul %s: %d.%d.%d -> %d.%d.%d" % (nazov, a, b, c, a, b, c + 1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--balik", help="verzia balíka (predvolene sa ponechá doterajšia)")
    ap.add_argument("--zip", action="store_true")
    ap.add_argument("--bump", action="append", default=[], help="zvýši patch verziu modulu (opakovateľné)")
    a = ap.parse_args()

    for n in a.bump:
        zvys_patch(n)

    stary = {}
    if os.path.exists(MANIFEST):
        stary = json.load(open(MANIFEST, encoding="utf-8"))
    stare_moduly = stary.get("moduly", {})

    chyby, varovania, zmeny = [], [], []
    moduly = {}
    for f in sorted(os.listdir(MODULY)):
        if not f.lower().endswith(".bas"):
            continue
        nazov, ver, h, ho = nacitaj_modul(os.path.join(MODULY, f))
        moduly[nazov] = {"subor": "moduly/" + f, "verzia": vs(ver), "sha256": h, "obsah_sha256": ho}
        s = stare_moduly.get(nazov)
        if s is None:
            zmeny.append("NOVÝ      %-28s %s" % (nazov, vs(ver)))
            continue
        sv = tuple(int(x) for x in s["verzia"].split("."))
        if ho != s.get("obsah_sha256"):
            if ver <= sv:
                chyby.append("%s: obsah sa zmenil, ale verzia %s nie je vyššia ako %s" % (nazov, vs(ver), s["verzia"]))
            else:
                zmeny.append("ZMENENÝ   %-28s %s -> %s" % (nazov, s["verzia"], vs(ver)))
        elif ver != sv:
            if ver < sv:
                chyby.append("%s: verzia %s je nižšia ako doterajšia %s" % (nazov, vs(ver), s["verzia"]))
            else:
                varovania.append("%s: zvýšená verzia %s -> %s bez zmeny obsahu" % (nazov, s["verzia"], vs(ver)))
    for n in stare_moduly:
        if n not in moduly:
            zmeny.append("ODSTRÁNENÝ %-27s (pridajte do ZRUSENE, ak má inštalátor modul z databázy odstrániť)" % n)

    if chyby:
        print("ZOSTAVENIE ZLYHALO:")
        for c in chyby:
            print("  - " + c)
        sys.exit(1)

    balik = a.balik or stary.get("balik") or "0.0.0"
    manifest = {
        "balik": balik,
        "vytvorene": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "poznamka": "Verzie modulov: pri každej zmene obsahu modulu zvýšte '@Verzia (tools/zostav_balik.py to vynúti).",
        "zrusene": ZRUSENE,
        "moduly": moduly,
    }
    json.dump(manifest, open(MANIFEST, "w", encoding="utf-8", newline="\n"), ensure_ascii=False, indent=2)
    print("manifest.json zapísaný: balík %s, modulov %d" % (balik, len(moduly)))
    for z in zmeny:
        print("  " + z)
    for v in varovania:
        print("  UPOZORNENIE: " + v)

    if a.zip:
        meno = os.path.basename(KOREN)
        cielzip = os.path.join(os.path.dirname(KOREN), "%s-%s.zip" % (meno, balik))
        with zipfile.ZipFile(cielzip, "w", zipfile.ZIP_DEFLATED) as z:
            for dp, dn, fn in os.walk(KOREN):
                dn[:] = [d for d in dn if d != "__pycache__"]
                for x in fn:
                    p = os.path.join(dp, x)
                    z.write(p, os.path.join(meno, os.path.relpath(p, KOREN)))
        print("ZIP: " + cielzip)


if __name__ == "__main__":
    main()
