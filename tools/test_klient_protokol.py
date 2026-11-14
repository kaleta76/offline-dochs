#!/usr/bin/env python3
"""Testy tools/klient_protokol.py (unittest, bez závislostí). Spustenie: python3 -I tools/test_klient_protokol.py"""
import contextlib
import datetime
import io
import os
import re
import sys
import tempfile
import unittest

TU = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TU)
import klient_protokol as kp  # noqa: E402

ID = "3F2A9C1E-7B64-4D0A-9E85-1C2D3E4F5A6B"
LOK = datetime.datetime(2026, 11, 12, 14, 23, 5)
UTC = datetime.datetime(2026, 11, 12, 13, 23, 5)


def dobry(**zmena):
    parametre = dict(id_razenia=ID, oc="4002012", login="jnovak", pc="PC-0123", kod="WORK", smer="IN",
                     cas_lokalny=LOK, cas_utc=UTC, odlozene=False, klient="1.0.0")
    parametre.update(zmena)
    return kp.zostav(**parametre)


def chyba(text, nazov=None):
    """Vráti výnimku, ktorú kontrola vyhodí (ak nevyhodí žiadnu, test padne)."""
    try:
        kp.rozober(text, nazov)
    except kp.ChybaRazenia as e:
        return e
    raise AssertionError("kontrola súbor prijala, hoci mala vyhodiť ChybaRazenia")


class Zapis(unittest.TestCase):
    def test_tvar_suboru_je_presne_ako_v_dokumentacii(self):
        self.assertEqual(
            dobry(),
            "DOCHSRZN;1\r\nid=" + ID + "\r\noc=4002012\r\nlogin=jnovak\r\npc=PC-0123\r\nkod=WORK\r\nsmer=IN\r\n"
            "cas=2026-11-12T14:23:05\r\nutc=2026-11-12T13:23:05\r\nodlozene=0\r\nklient=1.0.0\r\n#END\r\n",
        )

    def test_nazov_suboru(self):
        self.assertEqual(kp.nazov_suboru(LOK, ID), "20261112-142305_" + ID + ".rzn")

    def test_zapis_a_citanie_dava_rovnake_hodnoty(self):
        v = kp.rozober(dobry(odlozene=True).encode("ascii"), kp.nazov_suboru(LOK, ID))
        self.assertEqual((v["id"], v["oc"], v["login"], v["pc"], v["kod"], v["smer"]), (ID, "4002012", "jnovak", "PC-0123", "WORK", "IN"))
        self.assertEqual((v["cas"], v["utc"], v["odlozene"], v["klient"]), (LOK, UTC, True, "1.0.0"))

    def test_nove_id_ma_tvar_guid(self):
        self.assertRegex(kp.nove_id(), kp.RE_ID.pattern)

    def test_zapisovac_nepusti_zle_hodnoty(self):
        with self.assertRaises(kp.ChybaRazenia):
            dobry(kod="NIECO")
        with self.assertRaises(kp.ChybaRazenia):
            dobry(oc="12 34")
        with self.assertRaises(kp.ChybaRazenia):
            dobry(cas_utc=UTC - datetime.timedelta(hours=3))


class Kontrola(unittest.TestCase):
    def test_lf_aj_crlf_a_bom(self):
        t = dobry()
        kp.rozober(t.replace("\r\n", "\n").encode("ascii"))
        kp.rozober(b"\xef\xbb\xbf" + t.encode("ascii"))

    def test_prazdne_riadky_na_konci_su_v_poriadku(self):
        kp.rozober((dobry() + "\r\n\r\n").encode("ascii"))

    def test_chyba_koniec(self):
        self.assertEqual(chyba(dobry().replace("#END\r\n", "").encode("ascii")).kod, "KONIEC")
        self.assertEqual(chyba(dobry().replace("klient=1.0.0\r\n#END\r\n", "klient=1.0.").encode("ascii")).kod, "KONIEC")

    def test_za_koncom_nesmie_nic_byt(self):
        self.assertEqual(chyba((dobry() + "pc=INY\r\n").encode("ascii")).kod, "KONIEC")

    def test_koniec_pred_koncom(self):
        self.assertEqual(chyba(dobry().replace("pc=PC-0123", "#END").encode("ascii")).kod, "KONIEC")

    def test_hlavicka(self):
        self.assertEqual(chyba(dobry().replace("DOCHSRZN;1", "DOCHSRZN;2").encode("ascii")).kod, "HLAVICKA")
        self.assertEqual(chyba(b"").kod, "HLAVICKA")

    def test_povinne_kluce_a_duplicity(self):
        self.assertEqual(chyba(dobry().replace("pc=PC-0123\r\n", "").encode("ascii")).kod, "KLUC")
        self.assertEqual(chyba(dobry().replace("pc=PC-0123", "pc=PC-0123\r\npc=X").encode("ascii")).kod, "KLUC")
        self.assertEqual(chyba(dobry().replace("pc=PC-0123", "bez rovnasa").encode("ascii")).kod, "KLUC")
        self.assertEqual(chyba(dobry().replace("pc=PC-0123", "PC=PC-0123").encode("ascii")).kod, "KLUC")

    def test_neznamy_kluc_sa_ignoruje(self):
        v = kp.rozober(dobry().replace("klient=1.0.0", "klient=1.0.0\r\nbudnuce=1").encode("ascii"))
        self.assertNotIn("budnuce", v)

    def test_hodnoty(self):
        for stary, novy in (
            ("id=" + ID, "id=" + ID.lower()),
            ("id=" + ID, "id=ABC"),
            ("oc=4002012", "oc="),
            ("oc=4002012", "oc=" + "1" * 21),
            ("oc=4002012", "oc=40;02"),
            ("login=jnovak", "login=j novak"),
            ("login=jnovak", "login=" + "a" * 65),
            ("pc=PC-0123", "pc=PC\\0123"),
            ("kod=WORK", "kod=work"),
            ("smer=IN", "smer=in"),
            ("odlozene=0", "odlozene=2"),
            ("klient=1.0.0", "klient=x"),
        ):
            with self.subTest(novy=novy):
                self.assertEqual(chyba(dobry().replace(stary, novy).encode("ascii")).kod, "HODNOTA")

    def test_kody_a_smery_zo_zoznamu(self):
        for kod in kp.KODY:
            for smer in kp.SMERY:
                kp.rozober(dobry(kod=kod, smer=smer).encode("ascii"))

    def test_casy(self):
        self.assertEqual(chyba(dobry().replace("cas=2026-11-12T14:23:05", "cas=2026-13-12T14:23:05").encode("ascii")).kod, "CAS")
        self.assertEqual(chyba(dobry().replace("cas=2026-11-12T14:23:05", "cas=2026-11-12 14:23:05").encode("ascii")).kod, "CAS")
        self.assertEqual(chyba(dobry().replace("utc=2026-11-12T13:23:05", "utc=2026-11-12T11:23:05").encode("ascii")).kod, "CAS")

    def test_letny_cas_ma_posun_dve_hodiny(self):
        lok = datetime.datetime(2026, 7, 1, 8, 0, 0)
        kp.rozober(dobry(cas_lokalny=lok, cas_utc=lok - datetime.timedelta(hours=2)).encode("ascii"))
        with self.assertRaises(kp.ChybaRazenia):
            dobry(cas_lokalny=lok, cas_utc=lok - datetime.timedelta(hours=3))

    def test_znaky(self):
        self.assertEqual(chyba(dobry().replace("jnovak", "jánovak").encode("utf-8")).kod, "ZNAKY")
        self.assertEqual(chyba(dobry().replace("jnovak", "j\x00novak").encode("ascii")).kod, "ZNAKY")
        self.assertEqual(chyba(dobry().replace("\r\n", "\r").encode("ascii")).kod, "ZNAKY")

    def test_velkost(self):
        self.assertEqual(chyba(dobry().replace("klient=1.0.0", "klient=1.0.0\r\n" + "x=" + "a" * 3000).encode("ascii")).kod, "VELKOST")

    def test_nazov_suboru(self):
        ok = kp.nazov_suboru(LOK, ID)
        kp.rozober(dobry().encode("ascii"), ok)
        self.assertEqual(chyba(dobry().encode("ascii"), "razenie.rzn").kod, "NAZOV")
        self.assertEqual(chyba(dobry().encode("ascii"), ok.replace("1423", "1424", 1)).kod, "NAZOV")
        self.assertEqual(chyba(dobry().encode("ascii"), ok.replace("3F2A", "3F2B")).kod, "NAZOV")
        self.assertEqual(chyba(dobry().encode("ascii"), ok.replace(".rzn", ".txt")).kod, "NAZOV")


class Vzorky(unittest.TestCase):
    def test_skusobny_den_je_platny_a_v_poradi(self):
        subory = kp.skusobne_razenia(datetime.date(2026, 11, 12))
        self.assertEqual(len(subory), len(kp.SKUSOBNY_DEN))
        casy = []
        for nazov, text in subory:
            v = kp.rozober(text.encode("ascii"), nazov)
            self.assertEqual((v["oc"], v["login"]), ("9000001", "test.zam1"))
            casy.append(v["cas"])
        self.assertEqual(casy, sorted(casy))
        self.assertEqual(len({n for n, _ in subory}), len(subory))

    def test_skusobny_den_v_lete_ma_posun_dve_hodiny(self):
        nazov, text = kp.skusobne_razenia(datetime.date(2026, 7, 1))[0]
        v = kp.rozober(text.encode("ascii"), nazov)
        self.assertEqual(v["cas"] - v["utc"], datetime.timedelta(hours=2))

    def test_zmena_casu_v_marci_a_v_oktobri(self):
        self.assertFalse(kp._je_letny_cas(datetime.date(2026, 3, 28)))
        self.assertTrue(kp._je_letny_cas(datetime.date(2026, 3, 29)))
        self.assertTrue(kp._je_letny_cas(datetime.date(2026, 10, 24)))
        self.assertFalse(kp._je_letny_cas(datetime.date(2026, 10, 25)))

    def test_zle_vzory_odmietne_kontrola(self):
        zle = kp.zle_vzory()
        self.assertGreaterEqual(len(zle), 8)
        for nazov, obsah in zle:
            with self.subTest(nazov=nazov):
                m = re.search(r"[0-9]{8}-[0-9]{6}_[0-9A-F-]{36}\.rzn$", nazov)
                with self.assertRaises(kp.ChybaRazenia):
                    kp.rozober(obsah, m.group(0) if m else nazov)

    def test_prikazy_vzor_a_over(self):
        with tempfile.TemporaryDirectory() as d, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(kp.main(["vzor", d, "--den", "2026-11-12", "--zle"]), 0)
            dobre = sorted(os.path.join(d, n) for n in os.listdir(d) if n.endswith(".rzn"))
            self.assertEqual(len(dobre), 6)
            self.assertEqual(kp.main(["over"] + dobre), 0)
            zle = sorted(os.path.join(d, "zle", n) for n in os.listdir(os.path.join(d, "zle")))
            self.assertEqual(kp.main(["over", zle[0]]), 1)
            self.assertEqual(kp.main(["over", os.path.join(d, "neexistuje.rzn")]), 1)


if __name__ == "__main__":
    unittest.main()
