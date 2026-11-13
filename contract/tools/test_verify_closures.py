#!/usr/bin/env python3
"""Testy overovača uzávierok (kontrakt 1.6.0, stdlib unittest).
Spustenie: python3 -I contract/tools/test_verify_closures.py"""
import copy
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True  # do repozitára nepatria __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN = os.path.join(HERE, "..", "examples", "closures_example.json")
SCHEMA = os.path.join(HERE, "..", "closures-export.schema.json")
SCRIPT = os.path.join(HERE, "verify_closures.py")

_spec = importlib.util.spec_from_file_location("verify_closures", SCRIPT)
vc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vc)


def golden():
    with open(GOLDEN, encoding="utf-8") as fh:
        return json.load(fh)


def errors(doc, strict=False):
    return vc.check(doc, strict=strict)[0]


def warnings(doc):
    return vc.check(doc)[1]


def run_cli(raw, *args):
    with tempfile.NamedTemporaryFile("wb", suffix=".json", delete=False) as fh:
        fh.write(raw)
        path = fh.name
    try:
        p = subprocess.run([sys.executable, "-I", SCRIPT, path, *args], capture_output=True, text=True)
        return p.returncode, p.stdout
    finally:
        os.unlink(path)


class Golden(unittest.TestCase):
    def test_zlaty_subor_je_v_poriadku_aj_v_strict(self):
        self.assertEqual(errors(golden(), strict=True), [])
        self.assertEqual(warnings(golden()), [])

    def test_cli_zlaty_subor_a_bom(self):
        raw = json.dumps(golden()).encode("utf-8")
        self.assertEqual(run_cli(raw, "--strict")[0], 0)
        self.assertEqual(run_cli(b"\xef\xbb\xbf" + raw)[0], 0)

    def test_cli_neplatny_json_a_chybajuci_argument(self):
        self.assertEqual(run_cli(b"{nie json")[0], 1)
        p = subprocess.run([sys.executable, "-I", SCRIPT], capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)

    def test_razenie_mimo_uzavierky_je_v_priklade_zachytitelne(self):
        # príklad zámerne obsahuje razenie 108 zamestnanca 1234567, ktoré Access nezarátal (kontrolný prípad pre terminál)
        counted = {u for c in golden()["closures"] for u in c.get("counted_punches", [])}
        self.assertNotIn("a0000000-0000-4000-8000-000000000108", counted)


class Struktura(unittest.TestCase):
    def test_nie_objekt(self):
        self.assertTrue(errors([]))
        self.assertTrue(errors("x"))

    def test_chybajuci_povinny_kluc(self):
        for k in vc.TOP_REQ:
            d = golden()
            del d[k]
            self.assertTrue(any(k in e for e in errors(d)), k)

    def test_neznamy_kluc_najvyssej_urovne(self):
        d = golden()
        d["meno"] = "x"
        self.assertTrue(any("neznáme kľúče" in e for e in errors(d)))

    def test_schema_version(self):
        for v in (2, 0, True, "1", None):
            d = golden()
            d["schema_version"] = v
            self.assertTrue(any("schema_version" in e for e in errors(d)), v)

    def test_verzia_a_cas(self):
        for k, bad in (("closures_version", "2026-11-20"), ("closures_version", 5), ("generated_at", "2026-11-20 08:30:00"),
                       ("generated_at", "2026-13-45T08:30:00")):
            d = golden()
            d[k] = bad
            self.assertTrue(any(k in e for e in errors(d)), (k, bad))

    def test_organizacia_je_uuid(self):
        for bad in ("abc", "", 5, "0b6f2f0e-5a7e-4b8e-9a43-2c1d5e7a9f0"):
            d = golden()
            d["organization_id"] = bad
            self.assertTrue(any("organization_id" in e for e in errors(d)), bad)

    def test_closures_nie_pole(self):
        d = golden()
        d["closures"] = {}
        self.assertTrue(any("closures musí byť pole" in e for e in errors(d)))

    def test_prazdne_pole_je_platne(self):
        d = golden()
        d["closures"] = []
        d["counts"] = {"closures": 0, "counted_punches": 0}
        self.assertEqual(errors(d, strict=True), [])


class Zaznam(unittest.TestCase):
    def test_osobne_udaje_nie_su_dovolene(self):
        for k in ("name", "meno", "email", "department"):
            d = golden()
            d["closures"][0][k] = "x"
            self.assertTrue(any("neznáme kľúče" in e for e in errors(d)), k)

    def test_chybajuci_povinny_kluc_zaznamu(self):
        for k in vc.ENTRY_REQ:
            d = golden()
            del d["closures"][0][k]
            self.assertTrue(any(k in e for e in errors(d)), k)

    def test_osobne_cislo(self):
        for bad in ("", "a b", "x" * 21, 123, None, "12-34"):
            d = golden()
            d["closures"][0]["personnel_number"] = bad
            self.assertTrue(any("personnel_number" in e for e in errors(d)), bad)

    def test_osobne_cislo_s_veducimi_nulami_je_text(self):
        self.assertEqual(golden()["closures"][0]["personnel_number"], "00123456")

    def test_rok_a_mesiac(self):
        for k, bad in (("year", 1999), ("year", 2101), ("year", "2026"), ("year", True), ("month", 0), ("month", 13), ("month", 1.5)):
            d = golden()
            d["closures"][0][k] = bad
            self.assertTrue(any(k in e for e in errors(d)), (k, bad))

    def test_stav(self):
        for bad in ("closed", "OPEN", "", None, 1):
            d = golden()
            d["closures"][0]["state"] = bad
            self.assertTrue(any("state musí byť" in e for e in errors(d)), bad)

    def test_state_seq_rozsah_a_parita(self):
        for bad in (0, -1, 1000001, "1", True, 1.0):
            d = golden()
            d["closures"][0]["state_seq"] = bad
            self.assertTrue(errors(d), bad)
        d = golden()
        d["closures"][0]["state_seq"] = 2   # CLOSED s párnym číslom
        self.assertTrue(any("nepárne" in e for e in errors(d)))
        d = golden()
        d["closures"][2]["state_seq"] = 3   # REOPENED s nepárnym číslom
        self.assertTrue(any("párne" in e for e in errors(d)))

    def test_vyssie_cisla_zmien_su_platne(self):
        d = golden()
        d["closures"][0]["state_seq"] = 5
        d["closures"][2]["state_seq"] = 4
        self.assertEqual(errors(d, strict=True), [])

    def test_cas_zmeny(self):
        for bad in ("2026-11-20 08:12:40", "2026-02-30T08:12:40", "", 5):
            d = golden()
            d["closures"][0]["changed_at"] = bad
            self.assertTrue(any("changed_at" in e for e in errors(d)), bad)

    def test_duplicita(self):
        d = golden()
        d["closures"].append(copy.deepcopy(d["closures"][0]))
        d["counts"]["closures"] += 1
        d["counts"]["counted_punches"] += len(d["closures"][0]["counted_punches"])
        self.assertTrue(any("duplicitný záznam" in e for e in errors(d)))

    def test_ten_isty_mesiac_inych_zamestnancov_a_iny_mesiac_toho_isteho_su_platne(self):
        d = golden()
        self.assertEqual(len({(c["personnel_number"], c["year"], c["month"]) for c in d["closures"]}), 3)
        self.assertEqual(errors(d), [])

    def test_kod_zostavy(self):
        for bad in ("", "x" * 26, 5):
            d = golden()
            d["closures"][0]["report_code"] = bad
            self.assertTrue(any("report_code" in e for e in errors(d)), bad)


class Uzavrety(unittest.TestCase):
    def test_closed_vyzaduje_totals_a_counted_punches(self):
        for k in ("totals", "counted_punches"):
            d = golden()
            del d["closures"][0][k]
            self.assertTrue(any(f"CLOSED musí mať {k}" in e for e in errors(d)), k)

    def test_totals_kluce_a_rozsahy(self):
        d = golden()
        d["closures"][0]["totals"]["extra"] = 1
        self.assertTrue(any("totals má neznáme kľúče" in e for e in errors(d)))
        for k, bad in (("worked_min", -1), ("worked_min", 44641), ("expected_min", -5), ("balance_min", -44641),
                       ("balance_min", 44641), ("worked_min", 1.5), ("expected_min", "450"), ("balance_min", True)):
            d = golden()
            d["closures"][0]["totals"][k] = bad
            self.assertTrue(any(f"totals.{k}" in e for e in errors(d)), (k, bad))
        d = golden()
        del d["closures"][0]["totals"]["balance_min"]
        self.assertTrue(any("totals nemá povinné kľúče" in e for e in errors(d)))

    def test_zaporne_saldo_je_platne(self):
        d = golden()
        self.assertLess(d["closures"][1]["totals"]["balance_min"], 0)
        self.assertEqual(errors(d, strict=True), [])

    def test_saldo_ine_nez_rozdiel_je_upozornenie_nie_chyba(self):
        d = golden()
        d["closures"][0]["totals"]["balance_min"] = 40
        self.assertEqual(errors(d), [])
        self.assertTrue(any("balance_min" in w for w in warnings(d)))
        self.assertTrue(any("(--strict)" in e for e in errors(d, strict=True)))

    def test_counted_punches(self):
        d = golden()
        d["closures"][0]["counted_punches"][0] = "nie-uuid"
        d["counts"]["counted_punches"] = 7
        self.assertTrue(any("nie sú uuid" in e for e in errors(d)))
        d = golden()
        d["closures"][0]["counted_punches"][1] = d["closures"][0]["counted_punches"][0].upper()
        self.assertTrue(any("duplicity" in e for e in errors(d)))
        d = golden()
        d["closures"][0]["counted_punches"] = "x"
        self.assertTrue(any("counted_punches musí byť pole" in e for e in errors(d)))

    def test_counted_punches_najviac(self):
        d = golden()
        d["closures"][0]["counted_punches"] = [f"a0000000-0000-4000-8000-{i:012d}" for i in range(vc.MAX_COUNTED + 1)]
        d["counts"]["counted_punches"] = len(d["closures"][0]["counted_punches"]) + 3
        self.assertTrue(any("najviac" in e for e in errors(d)))
        d["closures"][0]["counted_punches"] = d["closures"][0]["counted_punches"][: vc.MAX_COUNTED]
        d["counts"]["counted_punches"] = vc.MAX_COUNTED + 3
        self.assertEqual(errors(d), [])

    def test_prazdny_zoznam_razeni_je_platny(self):
        d = golden()
        d["closures"][0]["counted_punches"] = []
        d["counts"]["counted_punches"] = 3
        self.assertEqual(errors(d), [])


class Znovuotvoreny(unittest.TestCase):
    def test_reopened_nesmie_mat_totals_razenia_ani_kod_zostavy(self):
        for k, v in (("totals", {"worked_min": 0, "expected_min": 0, "balance_min": 0}), ("counted_punches", []), ("report_code", "X")):
            d = golden()
            d["closures"][2][k] = v
            self.assertTrue(any(f"REOPENED nesmie mať {k}" in e for e in errors(d)), k)


class Uplnost(unittest.TestCase):
    def test_counts_musia_zodpovedat(self):
        d = golden()
        d["counts"]["closures"] = 2
        self.assertTrue(any("counts.closures" in e for e in errors(d)))
        d = golden()
        d["counts"]["counted_punches"] = 6
        self.assertTrue(any("counts.counted_punches" in e for e in errors(d)))

    def test_counts_tvar(self):
        for bad in ({}, {"closures": 3}, {"closures": 3, "counted_punches": 7, "x": 1}, [], None):
            d = golden()
            d["counts"] = bad
            self.assertTrue(any("counts musí mať presne kľúče" in e for e in errors(d)), bad)

    def test_orezany_subor(self):
        d = golden()
        d["closures"] = d["closures"][:1]
        self.assertTrue(any("counts" in e for e in errors(d)))


class Casy(unittest.TestCase):
    def test_mesiac_neskorsi_nez_cas_zostavenia_je_upozornenie(self):
        d = golden()
        d["closures"][0]["month"] = 12
        self.assertEqual(errors(d), [])
        self.assertTrue(any("neskorší" in w for w in warnings(d)))

    def test_bez_generated_at_sa_to_nekontroluje(self):
        d = golden()
        del d["generated_at"]
        d["closures"][0]["month"] = 12
        self.assertEqual(errors(d, strict=True), [])


class Schema(unittest.TestCase):
    """Súhlas JSON schémy s overovačom. Beží len ak je nainštalovaný balík jsonschema (CI ho nemá, vtedy sa test preskočí)."""

    @classmethod
    def setUpClass(cls):
        try:
            import jsonschema  # noqa: F401
        except ImportError:
            raise unittest.SkipTest("balík jsonschema nie je nainštalovaný")
        with open(SCHEMA, encoding="utf-8") as fh:
            cls.schema = json.load(fh)

    def valid(self, doc):
        import jsonschema
        v = jsonschema.Draft202012Validator(self.schema, format_checker=jsonschema.FormatChecker())
        return not list(v.iter_errors(doc))

    def test_zlaty_subor_podla_schemy(self):
        self.assertTrue(self.valid(golden()))

    def test_schema_a_overovac_sa_zhoduju_na_pokazenych_vstupoch(self):
        def bad(f):
            d = golden()
            f(d)
            return d
        cases = [
            bad(lambda d: d["closures"][0].pop("totals")),
            bad(lambda d: d["closures"][2].update(totals={"worked_min": 1, "expected_min": 1, "balance_min": 0})),
            bad(lambda d: d["closures"][0].update(state="x")),
            bad(lambda d: d["closures"][0].update(meno="x")),
            bad(lambda d: d.update(schema_version=2)),
            bad(lambda d: d.update(organization_id="abc")),
            bad(lambda d: d["closures"][0]["counted_punches"].append(d["closures"][0]["counted_punches"][0])),
            bad(lambda d: d["closures"][0]["totals"].update(worked_min=-1)),
            bad(lambda d: d["closures"][0].update(month=13)),
        ]
        for d in cases:
            self.assertFalse(self.valid(d), d)
            self.assertTrue(errors(d), d)


if __name__ == "__main__":
    unittest.main()
