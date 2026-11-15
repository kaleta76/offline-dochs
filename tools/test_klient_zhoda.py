#!/usr/bin/env python3
"""Zhoda klienta v Accesse (access/klient/moduly/*.bas) s referenciou v Pythone (tools/klient_protokol.py).

VBA sa mimo Accessu nedá spustiť. Samotest klienta (kl_08_Samotest.bas) preto nesie zlaté vektory v tvare, ktorý vie prečítať
aj tento test: vstupy a očakávaný výsledok sú argumenty volaní `Call OverXxx(...)` (len reťazce v úvodzovkách a celé čísla).
Test tie isté vstupy spracuje referenciou v Pythone a výsledok porovná. Zlyhá, ak sa vektor vo VBA zmení bez zmeny pravidla
v Pythone, aj naopak. Neoveruje, že VBA kód počíta správne (to robí samotest v skutočnom Accesse), len že obe strany tvrdia to isté.

Spustenie (z koreňa repozitára): python3 -I tools/test_klient_zhoda.py
"""
import datetime
import os
import re
import sys
import unittest

TU = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TU)
import klient_protokol as kp  # noqa: E402

MODULY = os.path.join(TU, "..", "access", "klient", "moduly")
FORMAT = "%Y-%m-%dT%H:%M:%S"
RE_ARG = re.compile(r'"((?:[^"]|"")*)"|(-?[0-9]+)')


def citaj_modul(nazov):
    with open(os.path.join(MODULY, nazov), "rb") as f:
        return f.read().decode("utf-8")


def logicke_riadky(text):
    """Riadky VBA so spojenými pokračovaniami ( _ na konci riadka)."""
    return re.sub(r"[ \t]_\r?\n", " ", text).replace("\r\n", "\n").split("\n")


def argumenty(cast):
    """Zoznam argumentov z textu volania: reťazce (bez úvodzoviek) a celé čísla. Iné výrazy sa nepripúšťajú."""
    zvysok = RE_ARG.sub("", cast)
    if re.sub(r"[\s,()]|Array", "", zvysok):
        raise ValueError("volanie obsahuje iné než reťazce a čísla: " + cast.strip()[:120])
    return [m.group(1).replace('""', '"') if m.group(2) is None else int(m.group(2)) for m in RE_ARG.finditer(cast)]


def volania(text, meno):
    """Argumenty všetkých volaní `Call <meno>(...)` v module (v poradí)."""
    vysledok = []
    for r in logicke_riadky(text):
        r = r.strip()
        if r.startswith("Call " + meno + "("):
            if not r.endswith(")"):
                raise ValueError("volanie nie je na jednom logickom riadku: " + r[:120])
            vysledok.append(argumenty(r[len("Call " + meno + "("):-1]))
    return vysledok


def zlate_vektory(text):
    """Zoznam slovníkov: vstupy vektora a očakávaný text súboru (riadky spojené a ukončené CRLF)."""
    vektory = []
    for r in logicke_riadky(text):
        r = r.strip()
        if not r.startswith("Call OverVektor("):
            continue
        m = re.match(r"^Call OverVektor\((.*),\s*Array\((.*)\)\)$", r)
        if not m:
            raise ValueError("OverVektor nemá tvar (vstupy, Array(riadky)): " + r[:120])
        a = argumenty(m.group(1))
        riadky = argumenty(m.group(2))
        if len(a) != 11 or not isinstance(a[9], int) or any(not isinstance(x, str) for x in a[:9] + [a[10]] + riadky):
            raise ValueError("OverVektor má neočakávané argumenty: " + r[:120])
        vektory.append(dict(meno=a[0], id=a[1], oc=a[2], login=a[3], pc=a[4], kod=a[5], smer=a[6], cas=a[7], utc=a[8],
                            odlozene=a[9], klient=a[10], text="".join(x + "\r\n" for x in riadky)))
    return vektory


def python_text(v):
    return kp.zostav(v["id"], v["oc"], v["login"], v["pc"], v["kod"], v["smer"], datetime.datetime.strptime(v["cas"], FORMAT),
                     datetime.datetime.strptime(v["utc"], FORMAT), bool(v["odlozene"]), v["klient"])


def nezhody_vektorov(text):
    """Zoznam mien vektorov, ktoré sa nezhodujú s referenciou (prázdny = zhoda)."""
    zle = []
    for v in zlate_vektory(text):
        try:
            if python_text(v).encode("ascii") != v["text"].encode("ascii"):
                zle.append(v["meno"])
        except (kp.ChybaRazenia, ValueError, UnicodeError):
            zle.append(v["meno"])
    return zle


def kod_chyby(obsah, nazov):
    try:
        kp.rozober(obsah, nazov)
    except kp.ChybaRazenia as e:
        return e.kod
    return ""


class ZlateVektory(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = citaj_modul("kl_08_Samotest.bas")
        cls.vektory = zlate_vektory(cls.text)

    def test_pocet_a_pokrytie(self):
        v = self.vektory
        self.assertGreaterEqual(len(v), 4)
        self.assertEqual(len({x["meno"] for x in v}), len(v), "mená vektorov sa opakujú")
        rozdiel = {int((datetime.datetime.strptime(x["cas"], FORMAT) - datetime.datetime.strptime(x["utc"], FORMAT)).total_seconds()) for x in v}
        self.assertEqual(rozdiel, {3600, 7200}, "chýba vektor pre letný alebo zimný čas")
        self.assertTrue(any(x["odlozene"] == 1 for x in v), "chýba vektor s odlozene=1")
        self.assertTrue(any(x["kod"] == "DOCTOR" and x["smer"] == "OUT" for x in v), "chýba vektor prerušenia DOCTOR/OUT")

    def test_zhoda_bajt_po_bajte(self):
        for v in self.vektory:
            with self.subTest(vektor=v["meno"]):
                self.assertEqual(python_text(v).encode("ascii"), v["text"].encode("ascii"))

    def test_kazdy_vektor_prejde_kontrolou(self):
        for v in self.vektory:
            with self.subTest(vektor=v["meno"]):
                cas = datetime.datetime.strptime(v["cas"], FORMAT)
                r = kp.rozober(v["text"].encode("ascii"), kp.nazov_suboru(cas, v["id"]))
                self.assertEqual((r["id"], r["oc"], r["login"], r["pc"], r["kod"], r["smer"], r["klient"]),
                                 (v["id"], v["oc"], v["login"], v["pc"], v["kod"], v["smer"], v["klient"]))
                self.assertEqual(r["cas"], cas)
                self.assertEqual(r["odlozene"], bool(v["odlozene"]))

    def test_len_testovaci_zamestnanec(self):
        for v in self.vektory:
            self.assertEqual((v["oc"], v["login"]), ("9000001", "test.zam1"), v["meno"])

    def test_zmena_vektora_sa_odhali(self):
        self.assertEqual(nezhody_vektorov(self.text), [])
        for stare, nove in (('"smer=IN", "cas=2026-07-01T07:31:12"', '"smer=IN", "cas=2026-07-01T07:31:13"'),
                            ('"odlozene=1", "klient=1.0.0"', '"odlozene=0", "klient=1.0.0"'),
                            ('"pc=PC-TEST", "kod=DOCTOR"', '"kod=DOCTOR", "pc=PC-TEST"'),
                            ('"klient=1.0.0", "#END"))\n    Call OverVektor("zima"', '"klient=1.0.0"))\n    Call OverVektor("zima"')):
            self.assertIn(stare, self.text.replace("\r\n", "\n"))
            self.assertEqual(len(nezhody_vektorov(self.text.replace("\r\n", "\n").replace(stare, nove, 1))), 1, stare)

    def test_iny_vyraz_vo_volani_sa_odmietne(self):
        with self.assertRaises(ValueError):
            argumenty('"a", vbCrLf, 1')


class ZleVzory(unittest.TestCase):
    """OverZlyVzor(meno, hladaj, nahrad, nazov, ocakavany_kod): to isté ako klient_protokol.zle_vzory()."""

    @classmethod
    def setUpClass(cls):
        cls.vba = volania(citaj_modul("kl_08_Samotest.bas"), "OverZlyVzor")
        cls.py = kp.zle_vzory()
        vektory = {v["meno"]: v for v in zlate_vektory(citaj_modul("kl_08_Samotest.bas"))}
        cls.zaklad = vektory["zima"]

    def test_zaklad_je_vzor_z_pythonu(self):
        nazov, text = kp.skusobne_razenia(datetime.date(2026, 11, 3), id_zdroj=lambda: "00000000-0000-0000-0000-00000000000A")[0]
        self.assertEqual(self.zaklad["text"], text)
        self.assertEqual(nazov, kp.nazov_suboru(datetime.datetime.strptime(self.zaklad["cas"], FORMAT), self.zaklad["id"]))

    def test_rovnake_vzory_a_kody(self):
        self.assertEqual(len(self.vba), len(self.py))
        dobry_nazov = kp.nazov_suboru(datetime.datetime.strptime(self.zaklad["cas"], FORMAT), self.zaklad["id"])
        for (meno, hladaj, nahrad, nazov, ocakavany), (py_nazov, py_obsah) in zip(self.vba, self.py):
            with self.subTest(vzor=meno):
                self.assertTrue(py_nazov.startswith("zle_" + meno), py_nazov)
                text = self.zaklad["text"]
                if hladaj:
                    self.assertIn(hladaj.replace("~", "\r\n"), text)
                    text = text.replace(hladaj.replace("~", "\r\n"), nahrad.replace("~", "\r\n"))
                self.assertEqual(text.encode("ascii"), py_obsah, "VBA vzor dáva iný súbor než Python")
                self.assertEqual(kod_chyby(py_obsah, nazov or dobry_nazov), ocakavany)
                self.assertNotEqual(ocakavany, "")
                if nazov:
                    self.assertEqual(nazov, py_nazov)


if __name__ == "__main__":
    unittest.main()
