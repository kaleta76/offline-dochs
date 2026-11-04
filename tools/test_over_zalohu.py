#!/usr/bin/env python3
"""Testy tools/over_zalohu.py (unittest, bez závislostí a bez PostgreSQL). Spustenie: python3 -I tools/test_over_zalohu.py"""
import gzip, hashlib, io, json, os, shutil, sys, tarfile, tempfile, unittest, zipfile
from unittest import mock

TU = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TU)
import over_zalohu as oz  # noqa: E402


def sql_vypis(tabulky=oz.OCAKAVANE):
    # nestlačiteľná výplň, aby aj gzip súbor mal rozumnú veľkosť
    riadky = ["-- PostgreSQL database dump", "SET statement_timeout = 0;"] + ["-- " + hashlib.sha256(str(i).encode()).hexdigest() for i in range(150)]
    for t in tabulky:
        riadky += [f"COPY {t} (id) FROM stdin;", "1", "\\."]
    return ("\n".join(riadky) + "\n").encode("utf-8")


def toc_vypis(tabulky=oz.OCAKAVANE):
    return ";\n; Archive created at 2026-11-04\n" + "\n".join(f"{3000 + i}; 0 {16000 + i} TABLE DATA {t.split('.')[0]} {t.split('.')[1]} postgres" for i, t in enumerate(tabulky)) + "\n"


class Skuska(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="test_zaloha_")
        self.addCleanup(shutil.rmtree, self.d, True)

    def subor(self, nazov, obsah):
        c = os.path.join(self.d, nazov)
        with open(c, "wb") as f:
            f.write(obsah)
        return c

    # --- rozpoznanie formátu a pomocné funkcie ---
    def test_sha256(self):
        c = self.subor("a.bin", b"abc" * 1000)
        self.assertEqual(oz.sha256_suboru(c), hashlib.sha256(b"abc" * 1000).hexdigest())

    def test_rozpoznanie_formatov(self):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w") as tf:
            i = tarfile.TarInfo("toc.dat"); i.size = 3; tf.addfile(i, io.BytesIO(b"abc"))
        self.assertEqual(oz.typ_z_hlavicky(b"PGDMP\x01\x0e\x00"), "pg_custom")
        self.assertEqual(oz.typ_z_hlavicky(b"\x1f\x8b\x08\x00"), "gzip")
        self.assertEqual(oz.typ_z_hlavicky(b"PK\x03\x04rest"), "zip")
        self.assertEqual(oz.typ_z_hlavicky(buf.getvalue()[:512]), "tar")
        self.assertEqual(oz.typ_z_hlavicky(b"--\n-- PostgreSQL database dump\n"), "sql")
        self.assertEqual(oz.typ_z_hlavicky(b"\x00\x01\x02 -- binarne"), "neznamy")
        self.assertEqual(oz.typ_z_hlavicky(b"obycajny text bez SQL"), "neznamy")

    def test_toc_a_copy(self):
        self.assertEqual(oz.tabulky_z_toc(toc_vypis(("public.profiles", "auth.users"))), ["auth.users", "public.profiles"])
        self.assertEqual(oz.tabulky_zo_sql(io.StringIO('COPY public.profiles (id) FROM stdin;\nINSERT INTO auth.users VALUES (1);\nCOPYRIGHT x\n')),
                         ["auth.users", "public.profiles"])

    # --- over(): SQL text ---
    def test_cely_sql_je_v_poriadku(self):
        v = oz.over(self.subor("z.sql", sql_vypis()))
        self.assertEqual(v["problemy"], [])
        self.assertEqual(v["vrstvy"], ["sql"])
        self.assertEqual(v["chybaju"], [])

    def test_chybajuca_tabulka_je_problem(self):
        v = oz.over(self.subor("z.sql", sql_vypis([t for t in oz.OCAKAVANE if t != "public.punches"])))
        self.assertEqual(v["chybaju"], ["public.punches"])
        self.assertTrue(any("public.punches" in p for p in v["problemy"]))

    def test_gzip_sql(self):
        v = oz.over(self.subor("z.sql.gz", gzip.compress(sql_vypis())))
        self.assertEqual(v["problemy"], [])
        self.assertEqual(v["vrstvy"], ["gzip", "sql"])

    def test_useknuty_gzip_je_problem(self):
        data = gzip.compress(sql_vypis())
        v = oz.over(self.subor("z.sql.gz", data[: len(data) * 3 // 4]))
        self.assertTrue(any("gzip" in p for p in v["problemy"]), v["problemy"])

    # --- over(): zlé súbory ---
    def test_zle_subory(self):
        self.assertTrue(oz.over(os.path.join(self.d, "nie_je.dump"))["problemy"])
        self.assertTrue(any("bajtov" in p for p in oz.over(self.subor("m.dump", b"PGDMP"))["problemy"]))
        self.assertTrue(any("rozpoznať" in p for p in oz.over(self.subor("n.bin", bytes(range(256)) * 8))["problemy"]))

    def test_kontrolny_sucet(self):
        c = self.subor("z.sql", sql_vypis())
        sha = hashlib.sha256(sql_vypis()).hexdigest()
        self.assertEqual(oz.over(c, sha.upper())["problemy"], [])
        self.assertTrue(any("SHA-256" in p for p in oz.over(c, "0" * 64)["problemy"]))

    # --- over(): pg_dump custom (pg_restore sa nahradí vzorom) ---
    def test_pg_custom_s_pg_restore(self):
        c = self.subor("e.dump", b"PGDMP" + b"\x00" * 2000)
        with mock.patch.object(oz, "pg_restore_list", return_value=toc_vypis()):
            self.assertEqual(oz.over(c)["problemy"], [])
        with mock.patch.object(oz, "pg_restore_list", return_value=toc_vypis(oz.OCAKAVANE[1:])):
            self.assertTrue(oz.over(c)["problemy"])

    def test_pg_custom_bez_pg_restore_je_len_upozornenie(self):
        c = self.subor("e.dump", b"PGDMP" + b"\x00" * 2000)
        with mock.patch.object(oz, "pg_restore_list", return_value=None):
            v = oz.over(c)
        self.assertEqual(v["problemy"], [])
        self.assertTrue(v["upozornenia"])
        self.assertIsNone(v["tabulky"])

    def test_pg_custom_poskodeny(self):
        c = self.subor("e.dump", b"PGDMP" + b"\x00" * 2000)
        with mock.patch.object(oz, "pg_restore_list", side_effect=ValueError("pg_restore archív nepreberie: chyba")):
            self.assertTrue(any("nepreberie" in p for p in oz.over(c)["problemy"]))

    # --- zip a tar ---
    def test_zip_s_jednym_suborom(self):
        c = os.path.join(self.d, "z.zip")
        with zipfile.ZipFile(c, "w") as z:
            z.writestr("zaloha.sql", sql_vypis())
        v = oz.over(c)
        self.assertEqual(v["problemy"], [])
        self.assertEqual(v["vrstvy"], ["zip", "sql"])

    def test_zip_s_viac_subormi_je_upozornenie(self):
        c = os.path.join(self.d, "z.zip")
        with zipfile.ZipFile(c, "w") as z:
            z.writestr("a.sql", sql_vypis())
            z.writestr("b.sql", sql_vypis())
            z.writestr("pad.txt", "x" * 2000)
        v = oz.over(c)
        self.assertEqual(v["problemy"], [])
        self.assertTrue(v["upozornenia"])

    def test_tar_bez_toc_je_upozornenie(self):
        c = os.path.join(self.d, "t.tar")
        with tarfile.open(c, "w") as tf:
            i = tarfile.TarInfo("nieco.txt"); i.size = 2000; tf.addfile(i, io.BytesIO(b"x" * 2000))
        v = oz.over(c)
        self.assertEqual(v["problemy"], [])
        self.assertTrue(v["upozornenia"])

    def test_rozbalenie_tar_ignoruje_nebezpecne_nazvy(self):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w") as tf:
            for nazov in ("dobry/toc.dat", "../zly.txt", "/abs.txt", "C:/win.txt"):
                i = tarfile.TarInfo(nazov); i.size = 1; tf.addfile(i, io.BytesIO(b"x"))
        buf.seek(0)
        cieľ = os.path.join(self.d, "von")
        os.makedirs(cieľ)
        with tarfile.open(fileobj=buf) as tf:
            oz.bezpecne_rozbal_tar(tf, cieľ)
        self.assertEqual(sorted(os.listdir(cieľ)), ["dobry"])
        self.assertFalse(os.path.exists(os.path.join(self.d, "zly.txt")))

    # --- ukladanie ---
    def test_ulozit_vytvori_kopiu_sucet_a_manifest(self):
        c = self.subor("zaloha.sql", sql_vypis())
        v = oz.over(c)
        koren = os.path.join(self.d, "zalohy")
        p1 = oz.ulozit(c, koren, v)
        p2 = oz.ulozit(c, koren, v)
        self.assertNotEqual(p1, p2)
        self.assertEqual(sorted(os.listdir(p1)), ["manifest.json", "zaloha.sql", "zaloha.sql.sha256"])
        with open(os.path.join(p1, "zaloha.sql.sha256"), encoding="utf-8") as f:
            self.assertEqual(f.read(), f"{v['sha256']}  zaloha.sql\n")
        with open(os.path.join(p1, "manifest.json"), encoding="utf-8") as f:
            m = json.load(f)
        self.assertEqual(m["sha256"], v["sha256"])
        self.assertEqual(m["bajty"], v["bajty"])
        self.assertEqual(oz.sha256_suboru(os.path.join(p1, "zaloha.sql")), v["sha256"])
        if os.name != "nt":
            self.assertEqual(os.stat(os.path.join(p1, "zaloha.sql")).st_mode & 0o222, 0)

    # --- príkazový riadok ---
    def test_hlavna_ok_a_chyba(self):
        c = self.subor("zaloha.sql", sql_vypis())
        koren = os.path.join(self.d, "zalohy")
        out = io.StringIO()
        self.assertEqual(oz.hlavna([c, "--ulozit", koren], out), 0)
        self.assertIn("Kópia je uložená", out.getvalue())
        self.assertEqual(len(os.listdir(koren)), 1)
        out = io.StringIO()
        self.assertEqual(oz.hlavna([c, "--iba-over", "--ulozit", os.path.join(self.d, "iny")], out), 0)
        self.assertFalse(os.path.exists(os.path.join(self.d, "iny")))
        out = io.StringIO()
        zly = self.subor("zly.bin", bytes(range(256)) * 8)
        self.assertEqual(oz.hlavna([zly, "--ulozit", koren], out), 1)
        self.assertIn("NEPOUŽÍVAJTE", out.getvalue())
        self.assertEqual(len(os.listdir(koren)), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
