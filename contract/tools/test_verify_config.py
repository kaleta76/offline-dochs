#!/usr/bin/env python3
"""Testy overovača konfigurácie a referenčného výpočtu plánu (stdlib unittest).
Spustenie: python3 -I contract/tools/test_verify_config.py"""
import copy
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True  # do repozitára nepatria __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN = os.path.join(HERE, "..", "examples", "config_example.json")


def _load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


vc = _load("verify_config")
bc = _load("build_config_example")


def read(path, mode="r"):
    with open(path, mode, **({} if "b" in mode else {"encoding": "utf-8"})) as fh:
        return fh.read()


def golden():
    return json.loads(read(GOLDEN))


def emp(doc, pn):
    return next(e for e in doc["employees"] if e["personnel_number"] == pn)


def month(doc, pn, mo):
    return next(m for m in emp(doc, pn)["months"] if m["month"] == mo)


def errors(doc, strict=False):
    return vc.check(doc, strict=strict)[0]


def write_file(raw):
    fd, path = tempfile.mkstemp(suffix=".json")
    with os.fdopen(fd, "wb") as f:
        f.write(raw)
    return path


def run_main(path, *extra):
    old = sys.stdout
    sys.stdout = io.StringIO()
    try:
        rc = vc.main([path, *extra])
        return rc, sys.stdout.getvalue()
    finally:
        sys.stdout = old


class Zlaty(unittest.TestCase):
    def test_zlaty_subor_je_v_poriadku(self):
        errs, warns = vc.check(golden())
        self.assertEqual(errs, [])
        self.assertEqual(warns, [])

    def test_cez_main_aj_s_bom(self):
        raw = read(GOLDEN, "rb")
        rc, out = run_main(write_file(b"\xef\xbb\xbf" + raw))
        self.assertEqual(rc, 0, out)
        self.assertIn("4 zamestnancov", out)

    def test_zlaty_subor_zodpoveda_vstupu(self):
        inp = json.loads(read(os.path.join(HERE, "..", "examples", "config_example.input.json")))
        self.assertEqual(bc.fmt(bc.build(inp)) + "\n", read(GOLDEN))

    def test_nic_osobne_v_subore(self):
        text = read(GOLDEN).lower()
        for slovo in ("priezvisko", "e-mail", "email", "@", "oddelenie", "telefon"):
            self.assertNotIn(slovo, text)


class Plan(unittest.TestCase):
    """Očakávané hodnoty z referenčného algoritmu (musí ich dať aj Access)."""

    def setUp(self):
        self.doc = golden()

    def test_pevny_fond_a_sviatok(self):
        m = month(self.doc, "9000001", "2026-11")
        self.assertEqual(m["day_types"][0], "SN")        # 1. 11. nedeľa a sviatok
        self.assertEqual(m["day_types"][16], "SP")       # 17. 11. utorok, sviatok
        self.assertEqual(m["expected_min"][16], 0)
        self.assertEqual(m["expected_min"][1], 450)      # 2. 11. pondelok
        self.assertEqual(sum(m["expected_min"]), 20 * 450)

    def test_uvazok_a_nova_sablona_od_novembra(self):
        okt = month(self.doc, "9000002", "2026-10")
        nov = month(self.doc, "9000002", "2026-11")
        self.assertEqual((okt["employment_pct"], okt["template_id"], okt["expected_min"][0]), (100, 1, 450))
        self.assertEqual((nov["employment_pct"], nov["template_id"], nov["expected_min"][1]), (50, 2, 225))

    def test_mesacny_fond_deleny_poctom_pracovnych_dni(self):
        okt = month(self.doc, "9000003", "2026-10")
        self.assertEqual(sum(1 for t in okt["day_types"] if t[0] == "P"), 22)
        self.assertEqual(okt["expected_min"][0], 9000 // 22)   # 409
        nov = month(self.doc, "9000003", "2026-11")
        self.assertEqual(nov["expected_min"][1], 9000 // 20)   # 450

    def test_fond_podla_dna_v_tyzdni_a_firemne_volno(self):
        okt = month(self.doc, "9000004", "2026-10")
        self.assertEqual(okt["expected_min"][0:5], [480, 300, 0, 0, 480])   # čt, pi, so, ne, po
        self.assertEqual(okt["day_types"][29], "VP")                        # 30. 10. firemné voľno v kalendári 2
        self.assertEqual(okt["expected_min"][29], 0)

    def test_zaokruhlenie_polovice_na_parne_ako_vba(self):
        fv = {"avg_day_min": 455, "monthly_min": 0, "by_weekday": None}
        _, f = bc.day_plan("2026-11", fv, {"overrides": {}}, set(), 50)
        self.assertEqual(f[1], 228)     # 227,5 -> 228
        fv["avg_day_min"] = 453
        _, f = bc.day_plan("2026-11", fv, {"overrides": {}}, set(), 50)
        self.assertEqual(f[1], 226)     # 226,5 -> 226

    def test_platna_verzia_posledna_nie_novsia_inak_najstaršia(self):
        v = [{"from": "2026-03", "x": 1}, {"from": "2026-09", "x": 2}]
        self.assertEqual(bc.valid_version(v, bc.ym_key("2026-10"))["x"], 2)
        self.assertEqual(bc.valid_version(v, bc.ym_key("2026-05"))["x"], 1)
        self.assertEqual(bc.valid_version(v, bc.ym_key("2025-01"))["x"], 1)

    def test_pravidlo_sablony_nova_verzia_od_novembra(self):
        t1 = next(t for t in self.doc["templates"] if t["id"] == 1)
        r_okt = next(r for r in next(m for m in t1["months"] if m["month"] == "2026-10")["rules"] if r["interruption"] == 2)
        r_nov = next(r for r in next(m for m in t1["months"] if m["month"] == "2026-11")["rules"] if r["interruption"] == 2)
        self.assertEqual(r_okt["max_duration_min"][0], 240)
        self.assertEqual(r_nov["max_duration_min"][0], 180)


class Chyby(unittest.TestCase):
    def setUp(self):
        self.doc = golden()

    def assertHas(self, doc, text, strict=False):
        errs = errors(doc, strict)
        self.assertTrue(any(text in e for e in errs), f"hľadané '{text}' nie je v {errs}")

    def test_verzia_1_nema_plan(self):
        self.doc["schema_version"] = 1
        self.assertHas(self.doc, "schema_version musí byť 2")

    def test_chybajuci_kluc(self):
        del self.doc["employees"]
        self.assertHas(self.doc, "chýba kľúč 'employees'")

    def test_neznamy_kluc_najvyssej_urovne(self):
        self.doc["mena"] = []
        self.assertHas(self.doc, "neznámy kľúč najvyššej úrovne 'mena'")

    def test_osobne_udaje_pri_zamestnancovi(self):
        emp(self.doc, "9000001")["name"] = "Ján Vymyslený"
        self.assertHas(self.doc, "osobné údaje")

    def test_osobne_udaje_pri_mesiaci(self):
        month(self.doc, "9000001", "2026-10")["department"] = "Sklad"
        self.assertHas(self.doc, "nepovolené kľúče")

    def test_nepravdivy_pocet_pri_orezanom_subore(self):
        self.doc["employees"].pop()
        self.assertHas(self.doc, "counts.employees")

    def test_nepravdivy_pocet_mesiacov(self):
        emp(self.doc, "9000001")["months"].pop()
        self.assertHas(self.doc, "counts.employee_months")

    def test_zly_pocet_dni(self):
        m = month(self.doc, "9000001", "2026-10")
        m["day_types"].pop()
        self.assertHas(self.doc, "day_types musí mať 31 dní")

    def test_typ_dna_nesedi_s_dnom_v_tyzdni(self):
        month(self.doc, "9000001", "2026-10")["day_types"][2] = "PP"   # 3. 10. je sobota
        self.assertHas(self.doc, "nesedí s dňom v týždni")

    def test_sviatok_z_ciselnika_musi_byt_S(self):
        month(self.doc, "9000001", "2026-11")["day_types"][16] = "PP"
        self.assertHas(self.doc, "je sviatok z číselníka")

    def test_fond_v_nepracovny_den(self):
        month(self.doc, "9000001", "2026-10")["expected_min"][2] = 450   # sobota
        self.assertHas(self.doc, "nie je pracovný, ale fond je 450")

    def test_nulovy_fond_v_pracovny_den_je_upozornenie_a_v_strict_chyba(self):
        month(self.doc, "9000001", "2026-10")["expected_min"][0] = 0
        errs, warns = vc.check(self.doc)
        self.assertEqual(errs, [])
        self.assertTrue(any("nulovým fondom" in w for w in warns))
        self.assertHas(self.doc, "nulovým fondom", strict=True)

    def test_mesiac_mimo_okna(self):
        month(self.doc, "9000001", "2026-11")["month"] = "2026-12"
        self.assertHas(self.doc, "mimo okna period")

    def test_mesiac_dvakrat(self):
        e = emp(self.doc, "9000001")
        e["months"][1]["month"] = e["months"][0]["month"]
        self.assertHas(self.doc, "v zozname dvakrát")

    def test_osobne_cislo_dvakrat(self):
        emp(self.doc, "9000002")["personnel_number"] = "9000001"
        self.assertHas(self.doc, "osobné číslo 9000001 je v zozname dvakrát")

    def test_neplatne_osobne_cislo(self):
        emp(self.doc, "9000001")["personnel_number"] = "Ján Novák"
        self.assertHas(self.doc, "neplatné osobné číslo")

    def test_neexistujuci_fond(self):
        month(self.doc, "9000001", "2026-10")["fund_id"] = 99
        self.assertHas(self.doc, "neexistujúci fond 99")

    def test_neexistujuca_sablona(self):
        month(self.doc, "9000001", "2026-10")["template_id"] = 99
        self.assertHas(self.doc, "neexistujúca šablóna 99")

    def test_uvazok_mimo_rozsahu(self):
        month(self.doc, "9000001", "2026-10")["employment_pct"] = 250
        self.assertHas(self.doc, "employment_pct")

    def test_neznamy_typ_vypoctu_prerusenia(self):
        next(i for i in self.doc["interruptions"] if i["code"] == 2)["calc"] = "PLATENE"
        self.assertHas(self.doc, "calc 'PLATENE' nepoznáme")

    def test_calc_work_len_pre_jednotku(self):
        next(i for i in self.doc["interruptions"] if i["code"] == 2)["calc"] = "WORK"
        self.assertHas(self.doc, "calc WORK patrí práve prerušeniu č. 1")

    def test_obed_je_cislo_7(self):
        next(i for i in self.doc["interruptions"] if i["code"] == 7)["calc"] = "COUNTED"
        self.assertHas(self.doc, "calc LUNCH patrí práve prerušeniu č. 7")

    def test_kod_razenia_na_neexistujuce_preruseni(self):
        self.doc["punch_codes"][0]["interruption"] = 77
        self.assertHas(self.doc, "neexistujúce prerušenie 77")

    def test_mapovanie_kodu_terminalu_na_neexistujuce_preruseni(self):
        self.doc["terminal_code_map"][1]["interruption"] = 77
        self.assertHas(self.doc, "odkazuje na neexistujúce prerušenie")

    def test_mapovanie_kodu_dvakrat(self):
        self.doc["terminal_code_map"].append({"code": "WORK", "interruption": 1})
        self.assertHas(self.doc, "kód 'WORK' je dvakrát")

    def test_pravidlo_pre_neexistujuce_preruseni(self):
        self.doc["templates"][0]["months"][0]["rules"][0]["interruption"] = 77
        self.assertHas(self.doc, "neexistujúce prerušenie 77")

    def test_pravidlo_so_zlym_poctom_dni(self):
        self.doc["templates"][0]["months"][0]["rules"][0]["max_duration_min"].pop()
        self.assertHas(self.doc, "musí mať 7 čísel")

    def test_neplatny_datum_sviatku(self):
        self.doc["holidays"][0]["date"] = "2026-02-30"
        self.assertHas(self.doc, "neplatný dátum")

    def test_okno_prilis_dlhe(self):
        self.doc["period"] = {"from_month": "2026-01", "to_month": "2027-12"}
        self.assertHas(self.doc, "okno period má 24 mesiacov")

    def test_okno_obratene(self):
        self.doc["period"] = {"from_month": "2026-11", "to_month": "2026-10"}
        self.assertHas(self.doc, "koniec je pred začiatkom")

    def test_poskodeny_json(self):
        rc, out = run_main(write_file(b'{"schema_version": 2, '))
        self.assertEqual(rc, 1)
        self.assertIn("nedá prečítať", out)

    def test_main_vypise_chyby_a_vrati_1(self):
        self.doc["counts"]["employees"] = 99
        rc, out = run_main(write_file(json.dumps(self.doc).encode("utf-8")))
        self.assertEqual(rc, 1)
        self.assertIn("counts.employees", out)


class Nezmenene(unittest.TestCase):
    def test_overovanie_nemeni_dokument(self):
        doc = golden()
        before = copy.deepcopy(doc)
        vc.check(doc)
        self.assertEqual(doc, before)


if __name__ == "__main__":
    unittest.main()
