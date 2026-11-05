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

    # --- tlačidlá terminála (kontrakt 1.3.0)
    def _it(self, code):
        return next(i for i in self.doc["interruptions"] if i["code"] == code)

    def test_tlacidla_zlateho_suboru_su_v_poriadku(self):
        podla_poradia = sorted((i for i in self.doc["interruptions"] if i.get("terminal_button")),
                               key=lambda i: i["terminal_order"])
        self.assertEqual([i["terminal_label"] for i in podla_poradia],
                         ["Lekár", "Sprievod", "Služobná cesta", "Služobné vzdialenie"])

    def test_tlacidlo_nie_je_pravdivostna_hodnota(self):
        self._it(2)["terminal_button"] = "ano"
        self.assertHas(self.doc, "terminal_button nie je true/false")

    def test_text_tlacidla_prazdny_dlhy_alebo_s_medzerami(self):
        for zly in ("", "x" * 25, " Lekár", "Lekár ", "Le\tkár", 5):
            self.doc = golden()
            self._it(2)["terminal_label"] = zly
            self.assertHas(self.doc, "terminal_label musí byť text 1 až 24 znakov")

    def test_poradie_mimo_rozsahu(self):
        for zle in (0, 100, "1", True):
            self.doc = golden()
            self._it(2)["terminal_order"] = zle
            self.assertHas(self.doc, "terminal_order musí byť celé číslo 1 až 99")

    def test_text_a_poradie_bez_tlacidla(self):
        self._it(8)["terminal_label"] = "Dovolenka"
        self.assertHas(self.doc, "patria len prerušeniu s terminal_button = true")
        self.doc = golden()
        self._it(8)["terminal_order"] = 5
        self.assertHas(self.doc, "patria len prerušeniu s terminal_button = true")

    def test_praca_nema_tlacidlo(self):
        self._it(1)["terminal_button"] = True
        self.assertHas(self.doc, "práca (č. 1) nemá vlastné tlačidlo")

    def test_obed_smie_mat_tlacidlo(self):
        # rozhodnutie vlastníka: Obed môže byť samostatné tlačidlo (odchod s kódom LUNCH, návrat je Príchod)
        self.doc["terminal_code_map"].append({"code": "LUNCH", "interruption": 7})
        self._it(7)["terminal_button"] = True
        self._it(7)["terminal_label"] = "Obed"
        self._it(7)["terminal_order"] = 1
        self.assertEqual(errors(self.doc), [])

    def test_obed_s_tlacidlom_potrebuje_kod(self):
        self._it(7)["terminal_button"] = True
        self.assertHas(self.doc, "prerušenie 7: tlačidlo potrebuje práve jeden kód v terminal_code_map (je ich 0)")

    def test_tlacidlo_bez_kodu_v_mapovani(self):
        self.doc["terminal_code_map"] = [m for m in self.doc["terminal_code_map"] if m["code"] != "ERRAND"]
        self.assertHas(self.doc, "prerušenie 4: tlačidlo potrebuje práve jeden kód v terminal_code_map (je ich 0)")

    def test_tlacidlo_s_dvoma_kodmi_v_mapovani(self):
        self.doc["terminal_code_map"].append({"code": "ERRAND2", "interruption": 4})
        self.assertHas(self.doc, "prerušenie 4: tlačidlo potrebuje práve jeden kód v terminal_code_map (je ich 2)")

    def test_dve_tlacidla_s_rovnakym_textom(self):
        self._it(4)["terminal_label"] = "LEKÁR"
        self.assertHas(self.doc, "majú tlačidlo s rovnakým textom")

    def test_bez_textu_sa_pouzije_nazov_a_ten_sa_porovnava(self):
        del self._it(4)["terminal_label"]          # text tlačidla = name "Služobné vzdialenie"
        errs, _ = vc.check(self.doc)
        self.assertEqual(errs, [])
        self._it(12)["terminal_label"] = "Služobné vzdialenie"
        self.assertHas(self.doc, "majú tlačidlo s rovnakým textom")

    def test_prilis_vela_tlacidiel(self):
        for n in range(20, 33):
            self.doc["interruptions"].append({
                "code": n, "name": f"Iné {n}", "short_name": f"I{n}", "start_punch_code": 0, "end_punch_code": 0,
                "is_work": False, "is_lunch": False, "auto_end_of_shift": False, "calc": "COUNTED",
                "terminal_button": True, "terminal_label": f"Iné {n}", "terminal_order": 50})
            self.doc["terminal_code_map"].append({"code": f"X{n}", "interruption": n})
        self.assertHas(self.doc, "tlačidiel pre terminál je 17, najviac 12")

    def test_subor_bez_tlacidiel_je_stale_platny(self):
        for it in self.doc["interruptions"]:
            # terminal_icon (1.4.0) patrí k tlačidlu, preto sa s ním odoberá
            for k in ("terminal_button", "terminal_label", "terminal_order", "terminal_icon"):
                it.pop(k, None)
        errs, warns = vc.check(self.doc)
        self.assertEqual((errs, warns), ([], []))

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


NOVE_PRAVIDLA = ("lunch_recorded_mode", "lunch_min_min", "unlabeled_out_is_lunch", "rounding_in_min", "rounding_out_min",
                 "rounding_mode", "auto_repair_target", "auto_repair_cases", "correction_deadline_day",
                 "early_return_ends_interruption")
NOVE_PRIZNAKY = ("terminal_icon", "terminal_request", "needs_approval", "full_day_only")


class Kontrakt140(unittest.TestCase):
    """Voliteľné kľúče kontraktu 1.4.0: pravidlá, príznaky prerušení, okno práce v mesiaci."""

    def setUp(self):
        self.doc = golden()

    def assertHas(self, doc, text, strict=False):
        errs = errors(doc, strict)
        self.assertTrue(any(text in e for e in errs), f"hľadané '{text}' nie je v {errs}")

    def _it(self, code):
        return next(i for i in self.doc["interruptions"] if i["code"] == code)

    # --- súbor bez nových kľúčov ostáva platný (spätná kompatibilita s 1.3.0)
    def test_subor_bez_novych_klucov_je_stale_platny(self):
        for k in NOVE_PRAVIDLA:
            self.doc["rules"].pop(k, None)
        for it in self.doc["interruptions"]:
            for k in NOVE_PRIZNAKY:
                it.pop(k, None)
            if it["calc"] == "UNPAID":
                it["calc"] = "COUNTED"
        for e in self.doc["employees"]:
            for m in e["months"]:
                m.pop("window_start_min", None)
                m.pop("window_end_min", None)
        self.assertEqual(vc.check(self.doc), ([], []))

    def test_zlaty_subor_ma_vsetky_nove_kluce(self):
        for k in NOVE_PRAVIDLA:
            self.assertIn(k, self.doc["rules"])
        pouzite = {k for it in self.doc["interruptions"] for k in it}
        for k in NOVE_PRIZNAKY:
            self.assertIn(k, pouzite)
        self.assertIn("UNPAID", {it["calc"] for it in self.doc["interruptions"]})

    # --- pravidlá
    def test_pravidla_mimo_rozsahu_alebo_zleho_typu(self):
        zle = {"lunch_recorded_mode": (3, -1, "1", True, 1.5), "lunch_min_min": (601, -1, "30"),
               "rounding_in_min": (61, -1, "5"), "rounding_out_min": (61, -1, False), "rounding_mode": (4, -1, "0"),
               "auto_repair_target": (2, -1, True), "auto_repair_cases": (0, 4, "3"),
               "correction_deadline_day": (32, -1, "5")}
        for k, hodnoty in zle.items():
            for v in hodnoty:
                self.doc = golden()
                self.doc["rules"][k] = v
                self.assertHas(self.doc, f"rules.{k} musí byť celé číslo")

    def test_hranice_pravidiel_su_platne(self):
        horne = {"lunch_recorded_mode": 2, "lunch_min_min": 600, "rounding_in_min": 60, "rounding_out_min": 60,
                 "rounding_mode": 3, "auto_repair_target": 1, "auto_repair_cases": 1, "correction_deadline_day": 31}
        dolne = {"lunch_recorded_mode": 0, "lunch_min_min": 0, "rounding_in_min": 0, "rounding_out_min": 0,
                 "rounding_mode": 0, "auto_repair_target": 0, "auto_repair_cases": 3, "correction_deadline_day": 0}
        for hodnoty in (horne, dolne):
            self.doc = golden()
            self.doc["rules"].update(hodnoty)
            if hodnoty["lunch_recorded_mode"] == 0:
                del self.doc["rules"]["lunch_min_min"]
            self.assertEqual(vc.check(self.doc), ([], []))

    def test_pravdivostne_pravidla(self):
        for k in ("unlabeled_out_is_lunch", "early_return_ends_interruption", "interruption_check_enabled"):
            for v in ("ano", 1, 0, None):
                self.doc = golden()
                self.doc["rules"][k] = v
                self.assertHas(self.doc, f"rules.{k} nie je true/false")

    def test_minuty_obeda_bez_rezimu_su_upozornenie_a_v_strict_chyba(self):
        self.doc["rules"]["lunch_recorded_mode"] = 0
        errs, warns = vc.check(self.doc)
        self.assertEqual(errs, [])
        self.assertTrue(any("lunch_min_min sa nepoužije" in w for w in warns))
        self.assertHas(self.doc, "lunch_min_min sa nepoužije", strict=True)
        del self.doc["rules"]["lunch_recorded_mode"]            # bez kľúča platí predvolené 0
        self.assertTrue(any("lunch_min_min sa nepoužije" in w for w in vc.check(self.doc)[1]))

    def test_neznamy_kluc_pravidiel_je_upozornenie_a_v_strict_chyba(self):
        self.doc["rules"]["rounding_in_mn"] = 5                 # preklep
        errs, warns = vc.check(self.doc)
        self.assertEqual(errs, [])
        self.assertTrue(any("neznámy kľúč 'rounding_in_mn'" in w for w in warns))
        self.assertHas(self.doc, "neznámy kľúč 'rounding_in_mn'", strict=True)

    # --- prerušenia
    def test_nezapocitany_interval_unpaid(self):
        self.assertEqual(self._it(13)["calc"], "UNPAID")
        self.assertEqual(errors(self.doc), [])

    def test_unpaid_nepatri_praci_ani_obedu(self):
        self._it(1)["calc"] = "UNPAID"
        self.assertHas(self.doc, "calc WORK patrí práve prerušeniu č. 1")
        self.doc = golden()
        self._it(7)["calc"] = "UNPAID"
        self.assertHas(self.doc, "calc LUNCH patrí práve prerušeniu č. 7")

    def test_ikony_zlateho_suboru(self):
        self.assertEqual({it["code"]: it["terminal_icon"] for it in self.doc["interruptions"] if "terminal_icon" in it},
                         {2: "doctor", 4: "errand", 12: "trip", 16: "family"})

    def test_ikona_zleho_tvaru(self):
        for zla in ("", "Doctor", "doctor\n", "d-r", "1abc", "x" * 21, 5, None):
            self.doc = golden()
            self._it(2)["terminal_icon"] = zla
            self.assertHas(self.doc, "terminal_icon musí byť názov z malých písmen")

    def test_neznama_ikona_je_upozornenie_a_v_strict_chyba(self):
        self._it(2)["terminal_icon"] = "rocket"
        errs, warns = vc.check(self.doc)
        self.assertEqual(errs, [])
        self.assertTrue(any("neznáma ikona 'rocket'" in w for w in warns))
        self.assertHas(self.doc, "neznáma ikona 'rocket'", strict=True)

    def test_ikona_bez_tlacidla(self):
        self._it(8)["terminal_icon"] = "home"
        self.assertHas(self.doc, "terminal_icon patrí len prerušeniu s terminal_button = true")

    def test_priznaky_nie_su_pravdivostne_hodnoty(self):
        for k in ("terminal_request", "needs_approval", "full_day_only"):
            self.doc = golden()
            self._it(8)[k] = "ano"
            self.assertHas(self.doc, f"prerušenie 8: {k} nie je true/false")

    def test_praca_nema_priznaky_1_4_0(self):
        for k in ("terminal_request", "needs_approval", "full_day_only"):
            self.doc = golden()
            self._it(1)[k] = True
            self.assertHas(self.doc, f"práca (č. 1) nemá kľúč {k}")
            self.doc = golden()
            self._it(1)[k] = False                              # false je neškodné
            self.assertEqual(errors(self.doc), [])

    def test_celodenne_prerusenie_nema_tlacidlo(self):
        self._it(2)["full_day_only"] = True                     # prerušenie 2 má tlačidlo
        self.assertHas(self.doc, "prerušenie 2: full_day_only a terminal_button sa vylučujú")

    def test_zadost_a_schvalovanie_su_nezavisle_od_tlacidla(self):
        self.assertTrue(self._it(12)["terminal_button"] and self._it(12)["terminal_request"] and self._it(12)["needs_approval"])
        self.assertFalse(self._it(8).get("terminal_button", False))
        self.assertEqual(errors(self.doc), [])

    # --- okno práce v mesiaci
    def test_okno_je_len_pri_fonde_s_oknom(self):
        for pn, ma in (("9000004", True), ("9000001", False), ("9000002", False), ("9000003", False)):
            for m in emp(self.doc, pn)["months"]:
                self.assertEqual("window_start_min" in m, ma, (pn, m["month"]))
                self.assertEqual("window_end_min" in m, ma, (pn, m["month"]))
        m = month(self.doc, "9000004", "2026-11")
        self.assertEqual((m["window_start_min"], m["window_end_min"]), (420, 960))

    def test_okno_len_jedna_hodnota(self):
        del month(self.doc, "9000004", "2026-10")["window_end_min"]
        self.assertHas(self.doc, "window_start_min a window_end_min musia byť spolu")
        self.doc = golden()
        m = month(self.doc, "9000001", "2026-10")
        m["window_end_min"] = 1020
        self.assertHas(self.doc, "window_start_min a window_end_min musia byť spolu")

    def test_okno_mimo_rozsahu_alebo_zleho_typu(self):
        for zle in (-1, 1441, "420", True, 420.5, None):
            self.doc = golden()
            month(self.doc, "9000004", "2026-10")["window_start_min"] = zle
            self.assertHas(self.doc, "musia byť celé čísla 0 až 1440")

    def test_okno_koniec_nie_je_po_zaciatku(self):
        for start, koniec in ((960, 960), (960, 420)):
            self.doc = golden()
            m = month(self.doc, "9000004", "2026-10")
            m["window_start_min"], m["window_end_min"] = start, koniec
            self.assertHas(self.doc, "koniec okna práce nie je po začiatku")

    def test_okno_cely_den_je_platne(self):
        m = month(self.doc, "9000001", "2026-10")
        m["window_start_min"], m["window_end_min"] = 0, 1440     # „okno sa nepoužíva“
        self.assertEqual(errors(self.doc), [])

    def test_ina_polozka_v_mesiaci_ostava_zakazana(self):
        month(self.doc, "9000001", "2026-10")["window_start"] = 420
        self.assertHas(self.doc, "nepovolené kľúče")

    # --- referenčný výpočet plánu
    def test_vypocet_plan_okno_podla_platnej_verzie_fondu(self):
        inp = json.loads(read(os.path.join(HERE, "..", "examples", "config_example.input.json")))
        f3 = next(f for f in inp["funds"] if f["id"] == 3)
        f3["versions"] = [{"from": "2025-01", "avg_day_min": 450, "monthly_min": 0, "by_weekday": None},
                          {"from": "2026-11", "avg_day_min": 450, "monthly_min": 0, "by_weekday": None, "window": [480, 1080]}]
        doc = bc.build(inp)
        self.assertNotIn("window_start_min", month(doc, "9000004", "2026-10"))      # staršia verzia okno nemá
        m = month(doc, "9000004", "2026-11")
        self.assertEqual((m["window_start_min"], m["window_end_min"]), (480, 1080))
        self.assertEqual(errors(doc), [])


class Kontrakt150(unittest.TestCase):
    """Voliteľné kľúče kontraktu 1.5.0: vlastnosti prerušení (full_day_min, counts_to_lunch_base) a režimy výpočtu na obdobie."""

    def setUp(self):
        self.doc = golden()

    def assertHas(self, doc, text, strict=False):
        errs = errors(doc, strict)
        self.assertTrue(any(text in e for e in errs), f"hľadané '{text}' nie je v {errs}")

    def _it(self, code):
        return next(i for i in self.doc["interruptions"] if i["code"] == code)

    def _reg(self):
        return self.doc["regimes"][0]

    # --- spätná kompatibilita a zlatý súbor
    def test_subor_bez_klucov_1_5_0_je_stale_platny(self):
        self.doc.pop("regimes")
        for it in self.doc["interruptions"]:
            it.pop("full_day_min", None)
            it.pop("counts_to_lunch_base", None)
        for e in self.doc["employees"]:
            for m in e["months"]:
                m.pop("regime_ids", None)
        self.assertEqual(vc.check(self.doc), ([], []))

    def test_zlaty_subor_ma_vsetky_kluce_1_5_0(self):
        pouzite = {k for it in self.doc["interruptions"] for k in it}
        self.assertIn("full_day_min", pouzite)
        self.assertIn("counts_to_lunch_base", pouzite)
        self.assertEqual([r["id"] for r in self.doc["regimes"]], [1])
        self.assertTrue(any("regime_ids" in m for e in self.doc["employees"] for m in e["months"]))
        self.assertEqual(vc.check(self.doc, strict=True), ([], []))

    # --- vlastnosti prerušení
    def test_full_day_min_mimo_rozsahu_alebo_zleho_typu(self):
        for zle in (0, 1441, -1, "300", True, 300.5, None):
            self.doc = golden()
            self._it(2)["full_day_min"] = zle
            self.assertHas(self.doc, "full_day_min musí byť celé číslo 1 až 1440")

    def test_hranice_full_day_min_su_platne(self):
        for ok in (1, 1440):
            self._it(2)["full_day_min"] = ok
            self.assertEqual(errors(self.doc, strict=True), [])

    def test_full_day_min_len_pre_calc_counted(self):
        for code in (1, 7, 13):      # práca, obed, nezapočítané (UNPAID)
            self.doc = golden()
            self._it(code)["full_day_min"] = 300
            self.assertHas(self.doc, "full_day_min patrí len prerušeniu s calc COUNTED")

    def test_counts_to_lunch_base_nie_je_pravdivostna_hodnota(self):
        for zle in ("true", 1, 0, None):
            self.doc = golden()
            self._it(12)["counts_to_lunch_base"] = zle
            self.assertHas(self.doc, "counts_to_lunch_base nie je true/false")

    def test_counts_to_lunch_base_true_len_pre_calc_counted(self):
        for code in (1, 7, 13):
            self.doc = golden()
            self._it(code)["counts_to_lunch_base"] = True
            self.assertHas(self.doc, "counts_to_lunch_base = true patrí len prerušeniu s calc COUNTED")

    def test_counts_to_lunch_base_false_je_neskodne_aj_pri_praci(self):
        self._it(1)["counts_to_lunch_base"] = False
        self._it(13)["counts_to_lunch_base"] = False
        self.assertEqual(errors(self.doc, strict=True), [])

    # --- režimy výpočtu
    def test_regimes_nie_je_pole(self):
        self.doc["regimes"] = {}
        self.assertHas(self.doc, "regimes nie je pole")

    def test_prilis_vela_rezimov(self):
        self.doc["regimes"] = [{"id": i, "name": f"R{i}", "rules": {"auto_lunch_enabled": False}} for i in range(1, 22)]
        self.assertHas(self.doc, "režimov je 21, najviac 20")

    def test_id_rezimu(self):
        for zle in (0, 100, -1, "1", True, 1.5, None):
            self.doc = golden()
            self._reg()["id"] = zle
            self.assertHas(self.doc, "id musí byť celé číslo 1 až 99")

    def test_dva_rezimy_s_rovnakym_id(self):
        self.doc["regimes"].append({"id": 1, "name": "Iný", "rules": {"auto_lunch_enabled": False}})
        self.assertHas(self.doc, "režim 1 je v zozname dvakrát")

    def test_nazov_rezimu(self):
        for zly in ("", " Krízový", "Krízový ", "x" * 41, "a\nb", 5, None):
            self.doc = golden()
            self._reg()["name"] = zly
            self.assertHas(self.doc, "name musí byť text 1 až 40 znakov")
        self.doc = golden()
        self._reg()["name"] = "x" * 40
        self.assertEqual(errors(self.doc), [])

    def test_dva_rezimy_s_rovnakym_nazvom(self):
        self.doc["regimes"].append({"id": 2, "name": "KRÍZOVÝ REŽIM", "rules": {"auto_lunch_enabled": False}})
        self.assertHas(self.doc, "majú rovnaký názov")

    def test_neznamy_kluc_rezimu_je_chyba(self):
        self._reg()["employee"] = "Ján"
        self.assertHas(self.doc, "regimes[0]: neznáme kľúče")

    def test_rezim_neprepisuje_nepovolene_pravidla(self):
        for k in ("duplicate_punch_window_min", "default_daily_fund_min", "interruption_check_enabled",
                  "correction_deadline_day", "early_return_ends_interruption", "rounding_in_mn"):
            self.doc = golden()
            self._reg()["rules"][k] = 1
            self.assertHas(self.doc, f"rules.{k} režim nemení")

    def test_pravidla_rezimu_mimo_rozsahu(self):
        zle = {"full_day_obstacle_min": (0, 1441), "auto_lunch_trigger_min": (-1, 1441), "auto_lunch_deduct_min": (-1, 601),
               "lunch_recorded_mode": (3, -1), "lunch_min_min": (601, -1), "rounding_in_min": (61, -1), "rounding_out_min": (61, -1),
               "rounding_mode": (4, -1), "auto_repair_mode": (10, -1), "auto_repair_target": (2, -1), "auto_repair_cases": (0, 4)}
        for k, hodnoty in zle.items():
            for v in hodnoty + ("5", True, 1.5, None):
                self.doc = golden()
                self._reg()["rules"][k] = v
                self.assertHas(self.doc, f"rules.{k} musí byť celé číslo")

    def test_pravdivostne_pravidla_rezimu(self):
        for k in ("auto_lunch_enabled", "unlabeled_out_is_lunch"):
            for v in ("ano", 1, 0, None):
                self.doc = golden()
                self._reg()["rules"][k] = v
                self.assertHas(self.doc, f"rules.{k} nie je true/false")

    def test_okno_rezimu_len_spolu_a_koniec_po_zaciatku(self):
        del self._reg()["rules"]["work_window_end_min"]
        self.assertHas(self.doc, "work_window_start_min a work_window_end_min musia byť spolu")
        for a, b in ((600, 600), (600, 300)):
            self.doc = golden()
            self._reg()["rules"]["work_window_start_min"], self._reg()["rules"]["work_window_end_min"] = a, b
            self.assertHas(self.doc, "koniec okna práce nie je po začiatku")
        self.doc = golden()
        self._reg()["rules"]["work_window_start_min"], self._reg()["rules"]["work_window_end_min"] = 0, 1440
        self.assertEqual(errors(self.doc), [])

    def test_rules_rezimu_nie_je_objekt(self):
        self._reg()["rules"] = []
        self.assertHas(self.doc, "rules nie je objekt")

    def test_uprava_neexistujuceho_prerusenia(self):
        self._reg()["interruptions"].append({"code": 99, "counts_to_lunch_base": True})
        self.assertHas(self.doc, "úprava neexistujúceho prerušenia 99")

    def test_praca_a_obed_sa_v_rezime_nemenia(self):
        for code in (1, 7):
            self.doc = golden()
            self._reg()["interruptions"].append({"code": code, "calc": "UNPAID"})
            self.assertHas(self.doc, "práca (č. 1) a obed (č. 7) sa v režime nemenia")

    def test_prerusenie_v_rezime_dvakrat(self):
        self._reg()["interruptions"].append({"code": 4, "counts_to_lunch_base": False})
        self.assertHas(self.doc, "prerušenie 4 je upravené dvakrát")

    def test_uprava_bez_vlastnosti_nic_nemeni(self):
        self._reg()["interruptions"].append({"code": 2})
        self.assertHas(self.doc, "prerušenie 2 nič nemení")

    def test_calc_v_rezime_je_len_counted_alebo_unpaid(self):
        for zle in ("WORK", "LUNCH", "work", "", None):
            self.doc = golden()
            self._reg()["interruptions"][1]["calc"] = zle
            self.assertHas(self.doc, "calc musí byť COUNTED alebo UNPAID")

    def test_vlastnosti_v_rezime_podla_vyslednej_hodnoty_calc(self):
        # č. 13 je v základe UNPAID, režim ho robí COUNTED: full_day_min je platné
        self.assertEqual(errors(self.doc), [])
        # keď režim calc nemení a prerušenie je UNPAID, full_day_min je chyba
        del self._reg()["interruptions"][1]["calc"]
        self.assertHas(self.doc, "full_day_min patrí len prerušeniu s calc COUNTED")
        # a naopak: režim robí z COUNTED prerušenia UNPAID, counts_to_lunch_base = true je chyba
        self.doc = golden()
        self._reg()["interruptions"][0]["calc"] = "UNPAID"
        self.assertHas(self.doc, "counts_to_lunch_base = true patrí len prerušeniu s calc COUNTED")

    def test_vlastnosti_v_rezime_mimo_rozsahu(self):
        for zle in (0, 1441, "480", True, None):
            self.doc = golden()
            self._reg()["interruptions"][1]["full_day_min"] = zle
            self.assertHas(self.doc, "full_day_min musí byť celé číslo 1 až 1440")
        for zle in ("true", 1, None):
            self.doc = golden()
            self._reg()["interruptions"][0]["counts_to_lunch_base"] = zle
            self.assertHas(self.doc, "counts_to_lunch_base nie je true/false")

    def test_neznamy_kluc_v_uprave_prerusenia(self):
        self._reg()["interruptions"][0]["terminal_button"] = True
        self.assertHas(self.doc, "má neznáme kľúče")

    def test_prazdny_rezim_je_upozornenie_a_v_strict_chyba(self):
        self.doc["regimes"].append({"id": 2, "name": "Prázdny"})
        errs, warns = vc.check(self.doc)
        self.assertEqual(errs, [])
        self.assertTrue(any("režim 2 nič nemení" in w for w in warns), warns)
        self.assertHas(self.doc, "režim 2 nič nemení", strict=True)

    # --- režim v mesiaci zamestnanca
    def test_regime_ids_zly_pocet_dni_alebo_hodnoty(self):
        m = month(self.doc, "9000003", "2026-11")
        m["regime_ids"] = m["regime_ids"][:-1]
        self.assertHas(self.doc, "regime_ids musí mať 30 celých čísel 0 až 99")
        for zle in (-1, 100, "1", True, 1.5, None):
            self.doc = golden()
            month(self.doc, "9000003", "2026-11")["regime_ids"][3] = zle
            self.assertHas(self.doc, "regime_ids musí mať 30 celých čísel 0 až 99")
        self.doc = golden()
        month(self.doc, "9000003", "2026-11")["regime_ids"] = "1" * 30
        self.assertHas(self.doc, "regime_ids musí mať 30 celých čísel 0 až 99")

    def test_regime_ids_odkaz_na_neexistujuci_rezim(self):
        month(self.doc, "9000003", "2026-11")["regime_ids"][0] = 7
        self.assertHas(self.doc, "regime_ids odkazuje na neexistujúci režim 7")

    def test_regime_ids_bez_regimes(self):
        del self.doc["regimes"]
        self.assertHas(self.doc, "regime_ids odkazuje na neexistujúci režim 1")

    def test_regime_ids_bez_rezimu_je_upozornenie_a_v_strict_chyba(self):
        m = month(self.doc, "9000003", "2026-11")
        m["regime_ids"] = [0] * 30
        errs, warns = vc.check(self.doc)
        self.assertEqual(errs, [])
        self.assertTrue(any("neobsahuje žiaden režim" in w for w in warns), warns)
        self.assertHas(self.doc, "neobsahuje žiaden režim", strict=True)

    def test_regime_ids_su_len_v_mesiacoch_s_rezimom(self):
        for e in self.doc["employees"]:
            for m in e["months"]:
                self.assertEqual("regime_ids" in m, e["personnel_number"] == "9000003", (e["personnel_number"], m["month"]))

    # --- referenčný výpočet plánu
    def _input(self):
        return json.loads(read(os.path.join(HERE, "..", "examples", "config_example.input.json")))

    def test_obdobie_rezimu_cez_hranicu_mesiaca(self):
        m10 = month(self.doc, "9000003", "2026-10")["regime_ids"]
        m11 = month(self.doc, "9000003", "2026-11")["regime_ids"]
        self.assertEqual(m10, [0] * 25 + [1] * 6)       # 26. až 31. 10.
        self.assertEqual(m11, [1] * 6 + [0] * 24)       # 1. až 6. 11. (vrátane oboch krajných dní)

    def test_vypocet_obdobie_jeden_den_a_dve_obdobia(self):
        inp = self._input()
        e = next(x for x in inp["employees"] if x["personnel_number"] == "9000003")
        e["regime_periods"] = [{"regime": 1, "from": "2026-11-09", "to": "2026-11-09"},
                               {"regime": 1, "from": "2026-11-12", "to": "2026-11-13"}]
        doc = bc.build(inp)
        self.assertNotIn("regime_ids", month(doc, "9000003", "2026-10"))
        ids = month(doc, "9000003", "2026-11")["regime_ids"]
        self.assertEqual([d + 1 for d, v in enumerate(ids) if v], [9, 12, 13])
        self.assertEqual(errors(doc), [])

    def test_vypocet_bez_obdobi_kluc_vynecha(self):
        inp = self._input()
        for e in inp["employees"]:
            e.pop("regime_periods", None)
        doc = bc.build(inp)
        self.assertFalse(any("regime_ids" in m for e in doc["employees"] for m in e["months"]))
        self.assertEqual(vc.check(doc), ([], []))

    def test_vypocet_bez_rezimov_kluc_regimes_vynecha(self):
        inp = self._input()
        inp.pop("regimes")
        for e in inp["employees"]:
            e.pop("regime_periods", None)
        self.assertNotIn("regimes", bc.build(inp))

    def test_vypocet_prekryvajuce_sa_obdobia_su_chyba(self):
        inp = self._input()
        e = next(x for x in inp["employees"] if x["personnel_number"] == "9000003")
        e["regime_periods"].append({"regime": 1, "from": "2026-11-06", "to": "2026-11-08"})
        with self.assertRaisesRegex(ValueError, "prekrývajú"):
            bc.build(inp)

    def test_vypocet_susediace_obdobia_nie_su_prekrytie(self):
        inp = self._input()
        e = next(x for x in inp["employees"] if x["personnel_number"] == "9000003")
        e["regime_periods"].append({"regime": 1, "from": "2026-11-07", "to": "2026-11-08"})
        ids = month(bc.build(inp), "9000003", "2026-11")["regime_ids"]
        self.assertEqual([d + 1 for d, v in enumerate(ids) if v], [1, 2, 3, 4, 5, 6, 7, 8])

    def test_vypocet_obdobie_konci_pred_zaciatkom(self):
        inp = self._input()
        e = next(x for x in inp["employees"] if x["personnel_number"] == "9000003")
        e["regime_periods"] = [{"regime": 1, "from": "2026-11-08", "to": "2026-11-07"}]
        with self.assertRaisesRegex(ValueError, "končí pred začiatkom"):
            bc.build(inp)

    def test_vypocet_obdobie_s_neexistujucim_rezimom(self):
        inp = self._input()
        e = next(x for x in inp["employees"] if x["personnel_number"] == "9000003")
        e["regime_periods"][0]["regime"] = 5
        with self.assertRaisesRegex(ValueError, "neexistujúci režim 5"):
            bc.build(inp)

    def test_cez_hranice_okna_period_sa_obdobie_orezava(self):
        inp = self._input()
        e = next(x for x in inp["employees"] if x["personnel_number"] == "9000003")
        e["regime_periods"] = [{"regime": 1, "from": "2026-09-20", "to": "2026-10-02"}]
        doc = bc.build(inp)
        self.assertEqual(month(doc, "9000003", "2026-10")["regime_ids"], [1, 1] + [0] * 29)
        self.assertNotIn("regime_ids", month(doc, "9000003", "2026-11"))


class Nezmenene(unittest.TestCase):
    def test_overovanie_nemeni_dokument(self):
        doc = golden()
        before = copy.deepcopy(doc)
        vc.check(doc)
        self.assertEqual(doc, before)


if __name__ == "__main__":
    unittest.main()
