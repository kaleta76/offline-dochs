#!/usr/bin/env python3
"""Súbor razenia .rzn (protokol v1) pre klienta v Accesse: zapisovač, kontrola a skúšobné súbory. Len štandardná knižnica.

Referencia pre VBA (access/moduly/mod_22_KlientRazenia.bas, neskôr klient): VBA sa nedá spustiť mimo Accessu, preto sa tvar súboru a
pravidlá kontroly overujú tu a VBA ich zrkadlí. Popis protokolu: docs/KLIENT-ACCESS.md.

Použitie (z koreňa repozitára; na Windowse `py -3 -I tools\\klient_protokol.py ...`):
    python3 -I tools/klient_protokol.py vzor PRIECINOK [--den RRRR-MM-DD] [--zle]   # skúšobné súbory pre testovacieho zamestnanca 9000001
    python3 -I tools/klient_protokol.py over SUBOR [SUBOR ...]                       # over súbory (kód ukončenia 1 = aspoň jeden zlý)
Skúšobné súbory sú len pre testovacieho zamestnanca 9000001 (prihlasovacie meno test.zam1): v Accesse ho treba mať v tabuľke
Zamestnanci (SamoTestTerminalu ho vytvára) a doplniť mu LoginAD = test.zam1.
"""
import argparse
import datetime
import os
import re
import sys
import uuid

VERZIA_PROTOKOLU = 1
HLAVICKA = "DOCHSRZN;1"
KONIEC = "#END"
PRIPONA = ".rzn"
MAX_BAJTOV = 2048
KODY = ("WORK", "DOCTOR", "TRIP", "FAMILY", "LEAVE", "SICK", "PRIV", "ERRAND")
SMERY = ("IN", "OUT")
POVINNE = ("id", "oc", "login", "pc", "kod", "smer", "cas", "utc", "odlozene", "klient")

RE_ID = re.compile(r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")
RE_OC = re.compile(r"^[0-9A-Za-z]{1,20}$")
RE_LOGIN = re.compile(r"^[0-9A-Za-z._-]{1,64}$")
RE_PC = re.compile(r"^[0-9A-Za-z._-]{1,63}$")
RE_KLIENT = re.compile(r"^[0-9]{1,3}(\.[0-9]{1,3}){0,3}$")
RE_CAS = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$")
RE_KLUC = re.compile(r"^[a-z_]{1,20}$")
RE_NAZOV = re.compile(r"^([0-9]{8})-([0-9]{6})_([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})\.rzn$")
FORMAT_CASU = "%Y-%m-%dT%H:%M:%S"


class ChybaRazenia(ValueError):
    """Súbor nespĺňa protokol. `kod` je stabilný (pre tabuľku KlientRazenia), `text` je dôvod pre človeka."""

    def __init__(self, kod, text):
        super().__init__(f"{kod}: {text}")
        self.kod = kod
        self.text = text


def _cas(text, kluc):
    if not RE_CAS.match(text):
        raise ChybaRazenia("CAS", f"{kluc} nemá tvar RRRR-MM-DDTHH:MM:SS: '{text}'")
    try:
        return datetime.datetime.strptime(text, FORMAT_CASU)
    except ValueError:
        raise ChybaRazenia("CAS", f"{kluc} nie je platný čas: '{text}'")


def nazov_suboru(cas_lokalny, id_razenia):
    """RRRRMMDD-HHMMSS_<ID>.rzn z miestneho času razenia a ID."""
    return cas_lokalny.strftime("%Y%m%d-%H%M%S") + "_" + id_razenia + PRIPONA


def nove_id():
    return str(uuid.uuid4()).upper()


def zostav(id_razenia, oc, login, pc, kod, smer, cas_lokalny, cas_utc, odlozene=False, klient="1.0.0"):
    """Text súboru razenia (ASCII, CRLF, posledný riadok #END). Pred zápisom ho skontroluje rovnako ako príjem."""
    text = "\r\n".join((
        HLAVICKA,
        f"id={id_razenia}",
        f"oc={oc}",
        f"login={login}",
        f"pc={pc}",
        f"kod={kod}",
        f"smer={smer}",
        "cas=" + cas_lokalny.strftime(FORMAT_CASU),
        "utc=" + cas_utc.strftime(FORMAT_CASU),
        f"odlozene={1 if odlozene else 0}",
        f"klient={klient}",
        KONIEC,
    )) + "\r\n"
    rozober(text.encode("ascii"), nazov_suboru(cas_lokalny, id_razenia))
    return text


def rozober(obsah, nazov=None):
    """Skontroluje bajty súboru a vráti slovník s kľúčmi POVINNE (cas a utc ako datetime, odlozene ako bool).

    Hádže ChybaRazenia. Pravidlá (zrkadlí ich VBA):
      - najviac MAX_BAJTOV bajtov, iba ASCII (úvodný UTF-8 BOM sa toleruje), riadky oddelené CRLF alebo LF;
      - prvý riadok presne DOCHSRZN;1, posledný neprázdny riadok presne #END a za ním už nič;
      - riadky tvaru kluc=hodnota, každý povinný kľúč práve raz, neznámy kľúč sa ignoruje (ďalšie verzie môžu pridať polia);
      - hodnoty zodpovedajú vzorom (ID ako GUID veľkými písmenami, kód a smer zo zoznamu, časy RRRR-MM-DDTHH:MM:SS);
      - ak je zadaný názov súboru, musí mať tvar RRRRMMDD-HHMMSS_<ID>.rzn a zhodovať sa s `cas` a `id`.
    """
    if isinstance(obsah, str):
        obsah = obsah.encode("utf-8")
    if len(obsah) > MAX_BAJTOV:
        raise ChybaRazenia("VELKOST", f"súbor má {len(obsah)} bajtov (najviac {MAX_BAJTOV})")
    if obsah.startswith(b"\xef\xbb\xbf"):
        obsah = obsah[3:]
    if any(b > 127 for b in obsah):
        raise ChybaRazenia("ZNAKY", "súbor obsahuje znaky mimo ASCII")
    if any(b < 32 and b not in (10, 13) for b in obsah):
        raise ChybaRazenia("ZNAKY", "súbor obsahuje riadiace znaky")
    text = obsah.decode("ascii")
    riadky = text.replace("\r\n", "\n").replace("\n\r", "\n").split("\n")
    if "\r" in "".join(riadky):
        raise ChybaRazenia("ZNAKY", "samotný znak CR v súbore")
    while riadky and riadky[-1] == "":
        riadky.pop()
    if not riadky or riadky[0] != HLAVICKA:
        raise ChybaRazenia("HLAVICKA", f"prvý riadok musí byť {HLAVICKA}")
    if riadky[-1] != KONIEC:
        raise ChybaRazenia("KONIEC", f"súbor nekončí riadkom {KONIEC} (nedopísaný alebo poškodený)")
    if KONIEC in riadky[:-1]:
        raise ChybaRazenia("KONIEC", f"riadok {KONIEC} sa nachádza pred koncom súboru")
    hodnoty = {}
    for i, r in enumerate(riadky[1:-1], start=2):
        if "=" not in r:
            raise ChybaRazenia("KLUC", f"riadok {i} nemá tvar kluc=hodnota")
        kluc, _, hodnota = r.partition("=")
        if not RE_KLUC.match(kluc):
            raise ChybaRazenia("KLUC", f"riadok {i}: neplatný názov kľúča")
        if kluc in hodnoty:
            raise ChybaRazenia("KLUC", f"kľúč {kluc} je v súbore viackrát")
        hodnoty[kluc] = hodnota
    for k in POVINNE:
        if k not in hodnoty:
            raise ChybaRazenia("KLUC", f"chýba povinný kľúč {k}")
    v = {k: hodnoty[k] for k in POVINNE}
    if not RE_ID.match(v["id"]):
        raise ChybaRazenia("HODNOTA", "id nie je GUID zapísaný veľkými písmenami")
    if not RE_OC.match(v["oc"]):
        raise ChybaRazenia("HODNOTA", "oc má byť 1 až 20 písmen alebo číslic")
    if not RE_LOGIN.match(v["login"]):
        raise ChybaRazenia("HODNOTA", "login má neplatné znaky alebo dĺžku")
    if not RE_PC.match(v["pc"]):
        raise ChybaRazenia("HODNOTA", "pc má neplatné znaky alebo dĺžku")
    if v["kod"] not in KODY:
        raise ChybaRazenia("HODNOTA", f"kód '{v['kod']}' nie je zo zoznamu {', '.join(KODY)}")
    if v["smer"] not in SMERY:
        raise ChybaRazenia("HODNOTA", "smer musí byť IN alebo OUT")
    if v["odlozene"] not in ("0", "1"):
        raise ChybaRazenia("HODNOTA", "odlozene musí byť 0 alebo 1")
    if not RE_KLIENT.match(v["klient"]):
        raise ChybaRazenia("HODNOTA", "klient má neplatnú verziu")
    v["cas"] = _cas(v["cas"], "cas")
    v["utc"] = _cas(v["utc"], "utc")
    v["odlozene"] = v["odlozene"] == "1"
    rozdiel = int((v["cas"] - v["utc"]).total_seconds())
    if rozdiel not in (3600, 7200):
        raise ChybaRazenia("CAS", f"rozdiel cas - utc je {rozdiel} s (v Bratislave je 3600 alebo 7200)")
    if nazov is not None:
        m = RE_NAZOV.match(nazov)
        if not m:
            raise ChybaRazenia("NAZOV", "názov súboru nemá tvar RRRRMMDD-HHMMSS_<ID>.rzn")
        if m.group(3) != v["id"]:
            raise ChybaRazenia("NAZOV", "ID v názve súboru sa nezhoduje s id v súbore")
        if m.group(1) + m.group(2) != v["cas"].strftime("%Y%m%d%H%M%S"):
            raise ChybaRazenia("NAZOV", "čas v názve súboru sa nezhoduje s cas v súbore")
    return v


# Skúšobný deň testovacieho zamestnanca: príchod, obed (odchod a návrat), lekár, odchod. Poradie a typy zodpovedajú párovaniu
# v mod_19_TerminalImport.SparujRazenia pri TerminalOdchodBezDovodu = OBED.
SKUSOBNY_DEN = (
    ("07:31:12", "WORK", "IN"),
    ("11:30:05", "WORK", "OUT"),
    ("12:02:40", "WORK", "IN"),
    ("13:15:00", "DOCTOR", "OUT"),
    ("13:58:30", "DOCTOR", "IN"),
    ("15:36:02", "WORK", "OUT"),
)
POSUN_LETO = {True: 120, False: 60}


def _je_letny_cas(den):
    """Stredoeurópsky letný čas: od poslednej nedele v marci po poslednú nedeľu v októbri (od 01:00 UTC)."""
    def posledna_nedela(rok, mesiac):
        d = datetime.date(rok, mesiac, 31)
        while d.weekday() != 6:
            d -= datetime.timedelta(days=1)
        return d
    return posledna_nedela(den.year, 3) <= den < posledna_nedela(den.year, 10)


def skusobne_razenia(den, oc="9000001", login="test.zam1", pc="PC-TEST", id_zdroj=None):
    """Zoznam (nazov, text) pre jeden skúšobný deň. `id_zdroj` (volateľný) dáva ID, inak sa použije náhodné (pre skúšky pevné)."""
    posun = POSUN_LETO[_je_letny_cas(den)]
    vysledok = []
    for cas_text, kod, smer in SKUSOBNY_DEN:
        h, m, s = (int(x) for x in cas_text.split(":"))
        lokalny = datetime.datetime(den.year, den.month, den.day, h, m, s)
        utc = lokalny - datetime.timedelta(minutes=posun)
        i = id_zdroj() if id_zdroj else nove_id()
        vysledok.append((nazov_suboru(lokalny, i), zostav(i, oc, login, pc, kod, smer, lokalny, utc)))
    return vysledok


def zle_vzory():
    """Skúšobné súbory, ktoré príjem v Accesse musí odmietnuť (dôvod je v názve). Vracia zoznam (nazov, bajty)."""
    ok_nazov, ok_text = skusobne_razenia(datetime.date(2026, 11, 3), id_zdroj=lambda: "00000000-0000-0000-0000-00000000000A")[0]
    z = ok_text
    return [
        ("zle_bez_konca_" + ok_nazov, z.replace("#END\r\n", "").encode("ascii")),
        ("zle_hlavicka_" + ok_nazov, z.replace("DOCHSRZN;1", "DOCHSRZN;2").encode("ascii")),
        ("zle_kod_" + ok_nazov, z.replace("kod=WORK", "kod=NIECO").encode("ascii")),
        ("zle_smer_" + ok_nazov, z.replace("smer=IN", "smer=VON").encode("ascii")),
        ("zle_cas_" + ok_nazov, z.replace("cas=2026-11-03T07:31:12", "cas=2026-13-03T07:31:12").encode("ascii")),
        ("zle_utc_posun_" + ok_nazov, z.replace("utc=2026-11-03T06:31:12", "utc=2026-11-03T04:31:12").encode("ascii")),
        ("zle_dvojity_kluc_" + ok_nazov, z.replace("pc=PC-TEST", "pc=PC-TEST\r\npc=PC-INY").encode("ascii")),
        ("zle_nazov_inak.rzn", z.encode("ascii")),
    ]


def _vypis(text):
    print(text)


def prikaz_vzor(args):
    den = datetime.date.fromisoformat(args.den) if args.den else datetime.date.today()
    os.makedirs(args.priecinok, exist_ok=True)
    n = 0
    for nazov, text in skusobne_razenia(den):
        with open(os.path.join(args.priecinok, nazov), "wb") as f:
            f.write(text.encode("ascii"))
        n += 1
    _vypis(f"Zapísaných {n} skúšobných súborov pre {den.isoformat()} do {args.priecinok} (zamestnanec 9000001, login test.zam1).")
    if args.zle:
        zle = os.path.join(args.priecinok, "zle")
        os.makedirs(zle, exist_ok=True)
        for nazov, obsah in zle_vzory():
            with open(os.path.join(zle, nazov), "wb") as f:
                f.write(obsah)
        _vypis(f"A {len(zle_vzory())} zlých súborov do {zle} (príjem ich musí odmietnuť).")
    return 0


def prikaz_over(args):
    zle = 0
    for cesta in args.subory:
        try:
            with open(cesta, "rb") as f:
                v = rozober(f.read(), os.path.basename(cesta))
            _vypis(f"OK    {cesta}: {v['oc']} {v['kod']}/{v['smer']} {v['cas'].isoformat()}")
        except ChybaRazenia as e:
            zle += 1
            _vypis(f"ZLE   {cesta}: {e.kod} {e.text}")
        except OSError as e:
            zle += 1
            _vypis(f"ZLE   {cesta}: {e}")
    return 1 if zle else 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sp = p.add_subparsers(dest="prikaz", required=True)
    a = sp.add_parser("vzor", help="zapíše skúšobné súbory")
    a.add_argument("priecinok")
    a.add_argument("--den", help="RRRR-MM-DD (predvolene dnes)")
    a.add_argument("--zle", action="store_true", help="pridá podpriečinok zle s neplatnými súbormi")
    a.set_defaults(fn=prikaz_vzor)
    o = sp.add_parser("over", help="over súbory .rzn")
    o.add_argument("subory", nargs="+")
    o.set_defaults(fn=prikaz_over)
    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
