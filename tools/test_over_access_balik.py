#!/usr/bin/env python3
"""Testy tools/over_access_balik.py (unittest, bez závislostí). Spustenie: python3 -I tools/test_over_access_balik.py"""
import hashlib, json, os, shutil, subprocess, sys, tempfile, unittest

TU = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TU)
import over_access_balik as ob  # noqa: E402

ACCESS = os.path.abspath(os.path.join(TU, "..", "access"))


def kopia():
    """Kópia balíka v dočasnom priečinku (originál sa nikdy nemení)."""
    d = tempfile.mkdtemp(prefix="balik_")
    t = os.path.join(d, "access")
    shutil.copytree(ACCESS, t)
    return d, t


class Skuska(unittest.TestCase):
    def setUp(self):
        self.d, self.t = kopia()
        self.addCleanup(shutil.rmtree, self.d, True)

    def zapis_manifest(self, m):
        with open(os.path.join(self.t, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump(m, f)

    def test_skutocny_balik_je_v_poriadku(self):
        self.assertEqual(ob.kontrola(ACCESS), [])

    def test_upraveny_modul_zmeni_sucet(self):
        m = ob.nacitaj_manifest(self.t)
        nazov = sorted(m["moduly"])[0]
        p = os.path.join(self.t, *m["moduly"][nazov]["subor"].split("/"))
        with open(p, "ab") as f:
            f.write(b"' navyse\n")
        ch = ob.kontrola(self.t)
        self.assertTrue(any(nazov in c and "SHA-256" in c for c in ch), ch)

    def test_chybajuci_modul(self):
        m = ob.nacitaj_manifest(self.t)
        nazov = sorted(m["moduly"])[0]
        os.remove(os.path.join(self.t, *m["moduly"][nazov]["subor"].split("/")))
        self.assertTrue(any(nazov in c and "chýba" in c for c in ob.kontrola(self.t)))

    def test_modul_ske_je_zakazany(self):
        p = os.path.join(self.t, "moduly", "mod_07_SKE.bas")
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write("Attribute VB_Name = \"mod_07_SKE\"\n'@Verzia 1.0.0\n")
        ch = ob.kontrola(self.t)
        self.assertTrue(any("SKE" in c for c in ch), ch)

    def test_modul_ske_v_manifeste(self):
        m = ob.nacitaj_manifest(self.t)
        nazov = sorted(m["moduly"])[0]
        m["moduly"]["mod_07_SKE"] = dict(m["moduly"][nazov])
        self.zapis_manifest(m)
        self.assertTrue(any("mod_07_SKE" in c and "SKE" in c for c in ob.kontrola(self.t)))

    def test_retazec_z_modulu_ske(self):
        with open(os.path.join(self.t, "README.md"), "a", encoding="utf-8") as f:
            f.write("\nPrNastavenieSKE\n")
        self.assertTrue(any("PrNastavenieSKE" in c for c in ob.kontrola(self.t)))

    def test_databaza_a_protokol_nepatria_do_balika(self):
        for n in ("Dochadzka.accdb", "~Dochadzka.laccdb", "instalacia.log", "stary.zip"):
            with open(os.path.join(self.t, n), "wb") as f:
                f.write(b"x")
        ch = ob.kontrola(self.t)
        for n in ("Dochadzka.accdb", "~Dochadzka.laccdb", "instalacia.log", "stary.zip"):
            self.assertTrue(any(n in c for c in ch), (n, ch))

    def test_modul_mimo_manifestu(self):
        with open(os.path.join(self.t, "moduly", "mod_99_Navyse.bas"), "w", encoding="utf-8") as f:
            f.write("Attribute VB_Name = \"mod_99_Navyse\"\n'@Verzia 1.0.0\n")
        self.assertTrue(any("mod_99_Navyse" in c and "manifest" in c for c in ob.kontrola(self.t)))

    def test_verzia_modulu_nesedi(self):
        m = ob.nacitaj_manifest(self.t)
        nazov = sorted(m["moduly"])[0]
        m["moduly"][nazov]["verzia"] = "9.9.9"
        self.zapis_manifest(m)
        self.assertTrue(any(nazov in c and "9.9.9" in c for c in ob.kontrola(self.t)))

    def test_changelog_nesedi_s_manifestom(self):
        m = ob.nacitaj_manifest(self.t)
        m["balik"] = "9.9.9"
        self.zapis_manifest(m)
        self.assertTrue(any("CHANGELOG" in c and "9.9.9" in c for c in ob.kontrola(self.t)))

    def test_neplatna_verzia_balika(self):
        m = ob.nacitaj_manifest(self.t)
        m["balik"] = "dev"
        self.zapis_manifest(m)
        self.assertTrue(any("neplatná verzia" in c for c in ob.kontrola(self.t)))

    def test_poskodeny_manifest(self):
        with open(os.path.join(self.t, "manifest.json"), "w", encoding="utf-8") as f:
            f.write("{nie json")
        self.assertTrue(any("manifest.json" in c for c in ob.kontrola(self.t)))

    def test_poznamky(self):
        t = ob.poznamky(ACCESS)
        ver = ob.nacitaj_manifest(ACCESS)["balik"]
        self.assertIn("balík " + ver, t)
        self.assertIn("Get-FileHash", t)
        self.assertIn("SHA256SUMS.txt", t)
        self.assertIn("Odblokovať", t)
        self.assertNotIn("SKE", t)
        self.assertTrue(ob.horna_sekcia(ACCESS) in t and len(ob.horna_sekcia(ACCESS)) > 20)

    def test_cli(self):
        s = os.path.join(TU, "over_access_balik.py")
        r = subprocess.run([sys.executable, "-I", s, "--verzia"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), ob.nacitaj_manifest(ACCESS)["balik"])
        out = os.path.join(self.d, "poznamky.md")
        r = subprocess.run([sys.executable, "-I", s, "--koren", self.t, "--poznamky", out], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(open(out, encoding="utf-8").read().startswith("Dochádzkový systém"))
        with open(os.path.join(self.t, "Dochadzka.accdb"), "wb") as f:
            f.write(b"x")
        r = subprocess.run([sys.executable, "-I", s, "--koren", self.t], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)
        self.assertIn("CHYBA", r.stderr)

    def test_zip_z_git_archive_sedi(self):
        """ZIP vytvorený z priečinka access/ prejde rovnakou kontrolou (to isté robí vydávací workflow)."""
        if not shutil.which("git") or not os.path.isdir(os.path.join(TU, "..", ".git")):
            self.skipTest("bez gitu")
        z = os.path.join(self.d, "b.zip")
        subprocess.run(["git", "-C", os.path.join(TU, ".."), "archive", "--format=zip", "--prefix=Dochadzka-Instalator/", "-o", z, "HEAD:access"], check=True)
        import zipfile
        with zipfile.ZipFile(z) as zf:
            zf.extractall(os.path.join(self.d, "rozbalene"))
        self.assertEqual(ob.kontrola(os.path.join(self.d, "rozbalene", "Dochadzka-Instalator")), [])


if __name__ == "__main__":
    unittest.main()
