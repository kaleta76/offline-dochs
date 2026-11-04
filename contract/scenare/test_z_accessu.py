#!/usr/bin/env python3
"""Testy prevodníka z_accessu.py a úprav porovnaj.py (stdlib unittest).
Spustenie: python3 -I contract/scenare/test_z_accessu.py
Údaje sú vymyslené (osobné čísla 5000001 a 5000002)."""
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


za = _load("z_accessu")
pc = _load("porovnaj")


def ev(osc, den, cas, kod, smer):
    return {"osc": osc, "datum": den, "cas_min": cas, "kod": kod, "smer": smer}


def vstup():
    """Dva zamestnanci, október 2026: bežný deň, obed, lekár s návratom, dovolenka, neznáme prerušenie, automatická oprava."""
    a, b = "5000001", "5000002"
    raw = [
        ev(a, "2026-10-01", 420, 1, "Z"), ev(a, "2026-10-01", 930, 1, "K"),  # 7:00 - 15:30
        ev(a, "2026-10-02", 420, 1, "Z"), ev(a, "2026-10-02", 690, 7, "Z"), ev(a, "2026-10-02", 720, 7, "K"), ev(a, "2026-10-02", 930, 1, "K"),
        ev(a, "2026-10-05", 420, 1, "Z"), ev(a, "2026-10-05", 600, 2, "Z"), ev(a, "2026-10-05", 720, 2, "K"), ev(a, "2026-10-05", 930, 1, "K"),
        ev(a, "2026-10-06", 420, 8, "Z"), ev(a, "2026-10-06", 930, 8, "K"),  # dovolenka celý deň
        ev(a, "2026-10-07", 420, 1, "Z"), ev(a, "2026-10-07", 600, 99, "Z"), ev(a, "2026-10-07", 660, 99, "K"), ev(a, "2026-10-07", 930, 1, "K"),
        ev(a, "2026-10-08", 420, 1, "Z"), ev(a, "2026-10-08", 420, 1, "Z"), ev(a, "2026-10-08", 930, 1, "K"),  # duplicita
        ev(b, "2026-10-01", 480, 1, "Z"), ev(b, "2026-10-01", 960, 1, "K"),
        ev(b, "2026-10-02", 480, 1, "Z"),  # chýba odchod, doplní ho Access
    ]
    auto = [{"osc": b, "datum": "2026-10-02", "cas_min": 960, "kod": 1, "smer": "K", "typ": "ODCHOD"}]
    dni = [
        {"osc": a, "datum": "2026-10-01", "typ_dna": "PP", "denny_fond_min": 450, "odpracovane_min": 510, "saldo_min": 60, "detaily": "Prac.dob 7:00-15:30"},
        {"osc": a, "datum": "2026-10-02", "typ_dna": "PP", "denny_fond_min": 450, "odpracovane_min": 480, "saldo_min": 30, "detaily": "x"},
        {"osc": a, "datum": "2026-10-05", "typ_dna": "PP", "denny_fond_min": 450, "odpracovane_min": 510, "saldo_min": 60, "detaily": ""},
        {"osc": a, "datum": "2026-10-06", "typ_dna": "PP", "denny_fond_min": 450, "odpracovane_min": 450, "saldo_min": 0, "detaily": ""},
        {"osc": a, "datum": "2026-10-07", "typ_dna": "PP", "denny_fond_min": 450, "odpracovane_min": 450, "saldo_min": 0, "detaily": ""},
        {"osc": a, "datum": "2026-10-08", "typ_dna": "PP", "denny_fond_min": 450, "odpracovane_min": 510, "saldo_min": 60, "detaily": ""},
        {"osc": a, "datum": "2026-10-03", "typ_dna": "VV", "denny_fond_min": 0, "odpracovane_min": 0, "saldo_min": 0, "detaily": ""},
        {"osc": b, "datum": "2026-10-01", "typ_dna": "PP", "denny_fond_min": 360, "odpracovane_min": 480, "saldo_min": 120, "detaily": ""},
        {"osc": b, "datum": "2026-10-02", "typ_dna": "PP", "denny_fond_min": 450, "odpracovane_min": 480, "saldo_min": 30, "detaily": ""},
    ]
    return {"date_from": "2026-10-01", "date_to": "2026-10-31", "raw_events": raw, "auto_events": auto, "expected_daily_results": dni}


def riadky(v, osc, den):
    return [(c, k, s) for cast in v["casti"] for o, d, c, k, s in cast if o == osc and d == den]


class Prevod(unittest.TestCase):
    def setUp(self):
        self.v = za.vyrob(vstup(), None)

    def test_bezny_den(self):
        self.assertEqual(riadky(self.v, "5000001", "2026-10-01"), [(420, "WORK", "IN"), (930, "WORK", "OUT")])

    def test_obed_je_odchod_a_navrat(self):
        self.assertEqual(riadky(self.v, "5000001", "2026-10-02"),
                         [(420, "WORK", "IN"), (690, "WORK", "OUT"), (720, "WORK", "IN"), (930, "WORK", "OUT")])

    def test_lekar_s_navratom(self):
        self.assertEqual(riadky(self.v, "5000001", "2026-10-05"),
                         [(420, "WORK", "IN"), (600, "DOCTOR", "OUT"), (720, "WORK", "IN"), (930, "WORK", "OUT")])

    def test_dovolenka_cely_den_je_jedno_razenie(self):
        self.assertEqual(riadky(self.v, "5000001", "2026-10-06"), [(420, "LEAVE", "OUT")])
        self.assertIn("vynechal", self.v["popis"][("5000001", "2026-10-06")])

    def test_nezname_prerusenie_den_sa_nepreklada(self):
        self.assertEqual(riadky(self.v, "5000001", "2026-10-07"), [])
        self.assertIn(("5000001", "2026-10-07"), self.v["preskocit"])
        self.assertEqual(self.v["nepreklad"][99], 2)
        self.assertNotIn(("5000001", "2026-10-07"), [(r[0], r[1]) for r in self.v["access"]])

    def test_duplicita_sa_vynecha(self):
        self.assertEqual(riadky(self.v, "5000001", "2026-10-08"), [(420, "WORK", "IN"), (930, "WORK", "OUT")])
        self.assertIn("duplicitné", self.v["popis"][("5000001", "2026-10-08")])

    def test_automaticka_oprava_sa_nepreklada_ale_poznaci(self):
        self.assertEqual(riadky(self.v, "5000002", "2026-10-02"), [(480, "WORK", "IN")])
        self.assertIn("automatickú opravu", self.v["popis"][("5000002", "2026-10-02")])
        self.assertEqual(self.v["pocet_opravy"], 1)

    def test_vysledky_accessu_bez_preskocenych_dni(self):
        dni = {(r[0], r[1]) for r in self.v["access"]}
        self.assertIn(("5000001", "2026-10-03"), dni)  # sobota bez razení ostáva v porovnaní
        self.assertNotIn(("5000001", "2026-10-07"), dni)
        self.assertEqual(len(self.v["access"]), 8)

    def test_fondy_a_odporucanie(self):
        self.assertEqual(self.v["fondy"]["5000001"], [450] * 5)
        self.assertEqual(sorted(set(self.v["fondy"]["5000002"])), [360, 450])
        text = za.sprava(self.v, ["x.csv"])
        self.assertIn("DENNY_FOND_HODIN = 7.5", text)
        self.assertIn("nie (iný alebo premenlivý fond)", text)
        self.assertIn("č. 99: 2", text)

    def test_deliace_na_casti_nedeli_zamestnanca(self):
        v = za.vyrob(vstup(), None, max_riadkov=13)
        self.assertEqual(len(v["casti"]), 2)
        self.assertEqual({o for o, *_ in v["casti"][0]}, {"5000001"})
        self.assertEqual({o for o, *_ in v["casti"][1]}, {"5000002"})
        with self.assertRaises(SystemExit):
            za.vyrob(vstup(), None, max_riadkov=5)

    def test_mapovanie_z_configu(self):
        cfg = {"terminal_code_map": [{"code": "WORK", "interruption": 1}, {"code": "FAMILY", "interruption": 15},
                                      {"code": "DOCTOR", "interruption": 2}]}
        v = za.vyrob(vstup(), cfg)
        self.assertEqual(v["mapa"], {15: "FAMILY", 2: "DOCTOR"})
        # dovolenka (č. 8) už nemá kód, deň sa preskočí
        self.assertIn(("5000001", "2026-10-06"), v["preskocit"])

    def test_cas_mimo_dna_a_chybajuci_smer(self):
        r, _, dovod = za.preved_den([ev("1", "d", 1500, 1, "Z")], za.PREDVOLENE)
        self.assertIsNotNone(dovod)
        r, _, dovod = za.preved_den([ev("1", "d", 100, 1, "")], za.PREDVOLENE)
        self.assertIsNotNone(dovod)

    def test_cudzi_vstup_sa_odmietne(self):
        with self.assertRaises(SystemExit):
            za.vyrob({"raw_events": []}, None)


class Subory(unittest.TestCase):
    def test_zapis_a_cli(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "dochs_test_sample.json")
            with open(src, "w", encoding="utf-8") as f:
                json.dump(vstup(), f)
            out = os.path.join(d, "vystup")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(za.main([src, out]), 0)
            self.assertEqual(sorted(os.listdir(out)), [
                "access_vysledky_2026-10.csv", "import_do_terminalu_2026-10.csv", "popis_2026-10.json", "report_prevodu_2026-10.txt"])
            with open(os.path.join(out, "import_do_terminalu_2026-10.csv"), "rb") as f:
                raw = f.read()
            self.assertTrue(raw.startswith(b"\xef\xbb\xbfosobne_cislo;datum;cas;kod;smer\r\n"))
            self.assertIn(b"5000001;2026-10-05;10:00:00;DOCTOR;OUT\r\n", raw)
            self.assertNotIn(b"2026-10-07", raw)
            with open(os.path.join(out, "popis_2026-10.json"), encoding="utf-8") as f:
                popis = json.load(f)
            self.assertIn({"osc": "5000001", "den": "2026-10-07", "popis": popis[[p["den"] for p in popis].index("2026-10-07")]["popis"], "preskocit": True}, popis)

    def test_porovnanie_preskoci_dni_a_cudzie_osoby(self):
        with tempfile.TemporaryDirectory() as d:
            hl = "osobne_cislo;datum;typ_dna;fond_min;odpracovane_min;saldo_min\r\n"
            term = os.path.join(d, "t.csv")
            acc = os.path.join(d, "a.csv")
            pop = os.path.join(d, "p.json")
            with open(term, "w", encoding="utf-8-sig") as f:
                f.write(hl + "5000001;2026-10-01;PP;450;510;60\r\n5000001;2026-10-07;PP;450;0;-450\r\n9000001;2026-10-01;PP;450;0;-450\r\n")
            with open(acc, "w", encoding="utf-8-sig") as f:
                f.write(hl + "5000001;2026-10-01;PP;450;510;60\r\n")
            with open(pop, "w", encoding="utf-8") as f:
                json.dump([{"osc": "5000001", "den": "2026-10-07", "popis": "x", "preskocit": True}], f)
            def beh(*extra):
                return subprocess.run([sys.executable, "-I", os.path.join(HERE, "porovnaj.py"), "--terminal", term, "--access", acc, "--vystup", d, *extra],
                                      capture_output=True, text=True)
            self.assertEqual(beh().returncode, 1)
            self.assertEqual(beh("--popis", pop).returncode, 1)  # cudzia osoba 9000001 ešte prekáža
            r = beh("--popis", pop, "--iba-osoby-z-accessu")
            self.assertEqual(r.returncode, 0, r.stdout)
            self.assertIn("Preskočené dni", r.stdout)
            self.assertIn("9000001", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
