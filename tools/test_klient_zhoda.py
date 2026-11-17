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


class Odoslanie(unittest.TestCase):
    """Mapovanie chýb odoslania: vektory samotestu aj samotný Select Case v kl_03_Fronta proti klient_protokol.vysledok_odoslania."""

    @classmethod
    def setUpClass(cls):
        cls.samotest = citaj_modul("kl_08_Samotest.bas")
        cls.fronta = citaj_modul("kl_03_Fronta.bas")

    def test_vektory_mapovania(self):
        v = volania(self.samotest, "OverOdoslanie")
        self.assertEqual({c for c, _ in v} >= {0, 58, 70} | set(kp.CHYBY_NEDOSTUPNY), True, "vektory nepokrývajú celú tabuľku")
        self.assertTrue(any(kp.vysledok_odoslania(c) == "INA" for c, _ in v))
        for cislo, ocakavany in v:
            with self.subTest(chyba=cislo):
                self.assertEqual(kp.vysledok_odoslania(cislo), ocakavany)

    def test_vektory_pocitadla(self):
        v = volania(self.samotest, "OverNeuspechy")
        self.assertGreaterEqual(len(v), 5)
        for doteraz, vysledok, ocakavany in v:
            with self.subTest(doteraz=doteraz, vysledok=vysledok):
                self.assertEqual(kp.novy_pocet_neuspechov(doteraz, vysledok), ocakavany)

    def test_select_case_vo_vba(self):
        """Vetvy Case funkcie VysledokOdoslania vo VBA dávajú pre čísla 0 až 100 to isté ako Python."""
        m = re.search(r"Public Function VysledokOdoslania\(.*?\n(.*?)End Function", self.fronta.replace("\r\n", "\n"), re.S)
        self.assertIsNotNone(m)
        konst = dict(re.findall(r'Public Const (VYSL_[A-Z]+) As String = "([A-Z]+)"', self.fronta))
        vetvy, ostatne = {}, None
        for cisla, meno in re.findall(r"Case ([0-9, ]+|Else)\s*\n\s*VysledokOdoslania = (VYSL_[A-Z]+)", m.group(1)):
            if cisla == "Else":
                ostatne = konst[meno]
            else:
                for c in cisla.split(","):
                    self.assertNotIn(int(c), vetvy)
                    vetvy[int(c)] = konst[meno]
        self.assertIsNotNone(ostatne)
        self.assertGreaterEqual(len(vetvy), 11)
        for c in range(0, 101):
            self.assertEqual(vetvy.get(c, ostatne), kp.vysledok_odoslania(c), c)

    def test_prah_upozornenia(self):
        self.assertIn("Public Const PRAH_NEUSPECHOV As Long = %d" % kp.PRAH_NEUSPECHOV, self.fronta)

    def test_server_sa_nikdy_neprepisuje(self):
        """Na server sa píše len cez CreateTextFile bez prepísania a jedným Write; nič sa tam nemaže ani nepremenúva."""
        kod = "\n".join(r for r in self.fronta.replace("\r\n", "\n").split("\n") if not r.lstrip().startswith("'"))
        self.assertEqual(re.findall(r"CreateTextFile\(([^)]*)\)", kod), ["strCesta, False, False"])
        self.assertEqual(len(re.findall(r"\bts\.Write\b", kod)), 1)
        for zakazane in ("OpenTextFile", "WriteLine", "DeleteFile", "MoveFile", "CopyFile", "FileCopy"):
            self.assertNotIn(zakazane, kod)
        for m in re.finditer(r"^.*\b(Kill|Name|ZmazSubor|ZapisAsciiNovy)\b.*$", kod, re.M):
            self.assertNotIn("strPrijem", m.group(0), "zásah do priečinka prijem: " + m.group(0).strip())


class Konfiguracia(unittest.TestCase):
    """OverKonfig(meno, obsah, pocet, tlacidla, odchod, vytvorene, preskocene) proti klient_protokol.rozober_konfig."""

    @classmethod
    def setUpClass(cls):
        cls.vba = volania(citaj_modul("kl_08_Samotest.bas"), "OverKonfig")
        cls.konfig = citaj_modul("kl_04_Konfig.bas")

    def test_vektory(self):
        self.assertGreaterEqual(len(self.vba), 8)
        self.assertTrue(any(v[2] == -1 for v in self.vba) and any(v[2] == kp.MAX_TLACIDIEL for v in self.vba))
        for meno, obsah, pocet, tlacidla, odchod, vytvorene, preskocene in self.vba:
            with self.subTest(vektor=meno):
                for konce in ("\r\n", "\n"):
                    k = kp.rozober_konfig(obsah.replace("~", konce))
                    if pocet == -1:
                        self.assertIsNone(k)
                        continue
                    self.assertIsNotNone(k)
                    self.assertEqual(len(k["tlacidla"]), pocet)
                    self.assertEqual("|".join(a + "=" + b for a, b in k["tlacidla"]), tlacidla)
                    self.assertEqual((k["odchod_bez_dovodu"], k["vytvorene"]), (odchod, vytvorene))
                    self.assertEqual(",".join(str(x) for x in k["preskocene"]), preskocene)

    def test_vzor_je_subor_z_balika(self):
        """Vektor "vzor" v samoteste je presne obsah access/klient/testy/klient_konfig_vzor.txt (UTF-8 s BOM, CRLF)."""
        with open(os.path.join(MODULY, "..", "testy", "klient_konfig_vzor.txt"), "rb") as f:
            bajty = f.read()
        self.assertTrue(bajty.startswith(b"\xef\xbb\xbf"))
        vzor = [v for v in self.vba if v[0] == "vzor"]
        self.assertEqual(len(vzor), 1)
        self.assertEqual(vzor[0][1].replace("~", "\r\n").encode("utf-8"), bajty[3:])
        k = kp.rozober_konfig(bajty)
        self.assertEqual(len(k["tlacidla"]), vzor[0][2])
        self.assertTrue(k["preskocene"])

    def test_konstanty(self):
        self.assertIn('Public Const HLAVICKA_KONFIGU As String = "%s"' % kp.HLAVICKA_KONFIGU, self.konfig)
        self.assertIn("Public Const MAX_TLACIDIEL As Long = %d" % kp.MAX_TLACIDIEL, self.konfig)
        self.assertIn("Public Const MAX_TEXT_TLACIDLA As Long = %d" % kp.MAX_TEXT_TLACIDLA, self.konfig)
        self.assertIn('Private Const KODY_TLACIDIEL As String = "|%s|"' % "|".join(kp.KODY_TLACIDIEL), self.konfig)

    def test_konfig_zo_strany_hr(self):
        """Tvar, ktorý píše mod_22_KlientRazenia.GenerujKonfiguraciuKlienta (BOM, CRLF, poradie 1..n, prázdna ikona)."""
        text = "DOCHSKLIENT;1\r\nvytvorene=2026-11-15T08:00:00\r\nodchod_bez_dovodu=OBED\r\ntlacidlo=1;DOCTOR;Lekár;stethoscope\r\ntlacidlo=2;TRIP;Služobne;\r\n#END\r\n"
        k = kp.rozober_konfig(b"\xef\xbb\xbf" + text.encode("utf-8"))
        self.assertEqual(k["tlacidla"], [("DOCTOR", "Lekár"), ("TRIP", "Služobne")])
        self.assertEqual(k["preskocene"], [])
        self.assertEqual(kp.rozober_konfig(text), k)


def _razenia(text):
    return [tuple(p.split(";")) for p in text.split("|")] if text else []


class StavDna(unittest.TestCase):
    """OverStav a OverOtazku proti klient_protokol.stav_dna, popis_stavu a otazka_pred_razenim."""

    @classmethod
    def setUpClass(cls):
        cls.samotest = citaj_modul("kl_08_Samotest.bas")
        cls.razenie = citaj_modul("kl_05_Razenie.bas")

    def test_stav_a_popis(self):
        v = volania(self.samotest, "OverStav")
        self.assertEqual({x[2].split(";")[0] for x in v}, {"ZIADNE", "PRACA", "MIMO", "PRERUSENIE"})
        for meno, razenia, stav, nazov, popis in v:
            with self.subTest(vektor=meno):
                self.assertEqual(kp.stav_dna(_razenia(razenia)), stav)
                self.assertEqual(kp.popis_stavu(stav, nazov), popis)

    def test_otazky(self):
        v = volania(self.samotest, "OverOtazku")
        self.assertEqual({x[5] for x in v}, {"", "OPAKOVANE", "BEZ_PRICHODU"})
        for meno, razenia, kod, smer, utc_teraz, ocakavana in v:
            with self.subTest(vektor=meno):
                self.assertEqual(kp.otazka_pred_razenim(_razenia(razenia), kod, smer, utc_teraz), ocakavana)

    def test_hranica_opakovania(self):
        self.assertIn("Public Const OPAKOVANE_SEK As Long = 120", self.razenie)
        r = [("2026-11-03T06:31:12", "2026-11-03T07:31:12", "WORK", "IN")]
        self.assertEqual(kp.otazka_pred_razenim(r, "WORK", "IN", "2026-11-03T06:33:11"), "OPAKOVANE")
        self.assertEqual(kp.otazka_pred_razenim(r, "WORK", "IN", "2026-11-03T06:33:12"), "")

    def test_texty_stavu_vo_vba(self):
        for text in ("Dnes ešte bez razenia", "V práci od ", "Mimo práce od ", "Prerušenie: "):
            self.assertIn('"' + text + '"', self.razenie)

    def test_klient_nezapisuje_ine_kluce(self):
        """ZostavRazenie píše presne hlavičku, povinné kľúče v poradí protokolu a #END."""
        protokol = citaj_modul("kl_02_Protokol.bas").replace("\r\n", "\n")
        m = re.search(r"Public Function ZostavRazenie\(.*?\n    Dim s As String\n(.*?)    ZostavRazenie = s", protokol, re.S)
        self.assertIsNotNone(m)
        kluce = re.findall(r'^    s = (?:s & )?(?:"([a-z_]+)=" & |(HLAVICKA_RZN|KONIEC_RZN) & )', m.group(1), re.M)
        self.assertEqual([a or b for a, b in kluce], ["HLAVICKA_RZN"] + list(kp.POVINNE) + ["KONIEC_RZN"])
        self.assertEqual(len(m.group(1).strip().split("\n")), len(kp.POVINNE) + 2)


class BezOsobnychUdajov(unittest.TestCase):
    """V moduloch a testovacích súboroch klienta je len testovací zamestnanec 9000001 / test.zam1 a žiadne e-maily."""

    def test_moduly(self):
        koren = os.path.join(MODULY, "..")
        for adresar in (MODULY, os.path.join(koren, "testy")):
            for nazov in sorted(os.listdir(adresar)):
                with open(os.path.join(adresar, nazov), "rb") as f:
                    text = f.read().decode("utf-8")
                self.assertIsNone(re.search(r"[A-Za-z0-9._-]+@[A-Za-z0-9-]+\.[a-z]{2,}", text), nazov)
                for oc in re.findall(r'"oc=([0-9A-Za-z]+)"', text) + re.findall(r'oc[_a-z]*=([0-9]{4,})', text) + re.findall(r'"([0-9]{6,})"', text):
                    self.assertEqual(oc, "9000001", nazov)
                for login in re.findall(r'"login=([^"~]+)', text):
                    self.assertIn(login, ("test.zam1",), nazov)


if __name__ == "__main__":
    unittest.main()
