#!/usr/bin/env python3
"""Testy tools/over_zalohu.py (unittest, bez závislostí a bez PostgreSQL). Spustenie: python3 -I tools/test_over_zalohu.py"""
import gzip, hashlib, io, json, os, shutil, sys, tarfile, tempfile, unittest, zipfile, zlib
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


# Skutočný prázdny rámec zstd, ktorý pg_dump 16 aj 18 zapíše pre tabuľku bez riadkov (obsah je iba koncovka COPY).
PRAZDNY_ZSTD = bytes.fromhex("28b52ffd00582900005c2e0a0a0a")
KONIEC = b"\\.\n\n\n"


def _ci(v, isz=4):
    return (b"\x01" if v < 0 else b"\x00") + abs(v).to_bytes(isz, "little")


def _cs(s):
    if s is None:
        return _ci(-1)
    b = s.encode("utf-8")
    return _ci(len(b)) + b


def postav_custom(tabulky, vmin=16, komp=1, polohy=True, pokazit=None, bez_koncovky=None, kusy=4096, bez_konca_gzip=None):
    """Archív pg_dump -Fc zložený bajt po bajte (bez PostgreSQL). tabulky: {"schema.tabulka": [riadky COPY]}.
    komp: 0 bez kompresie, 1 gzip, 3 zstd (údaje zstd sa nerozbaľujú, preto sa zapíše pravý prázdny rámec alebo nič neznamenajúci rámec)."""
    isz, osz = 4, 8
    hlava = b"PGDMP" + bytes([1, vmin, 0, isz, osz, 1])
    hlava += bytes([komp]) if vmin >= 15 else _ci(0 if komp == 0 else -1)
    hlava += b"".join(_ci(x) for x in (10, 35, 8, 4, 10, 126, 0))
    hlava += _cs("postgres") + _cs("17.11") + _cs("pg_dump (PostgreSQL) 18.6")

    def polozka(dump_id, tag, popis, schema, copy, priznak, posun):
        b = _ci(dump_id) + _ci(1) + _cs("0") + _cs("0") + _cs(tag) + _cs(popis) + _ci(2) + _cs("") + _cs("") + _cs(copy) + _cs(schema) + _cs("") + _cs("")
        if vmin >= 16:
            b += _ci(0)
        b += _cs("postgres") + _cs("false") + _cs("1") + _ci(-1)
        return b + bytes([priznak]) + posun.to_bytes(osz, "little")

    bloky, meta = [], []
    for i, (nazov, riadky) in enumerate(tabulky.items()):
        schema, tag = nazov.split(".")
        dump_id = 100 + i
        obsah = "".join(r + "\n" for r in riadky).encode("utf-8") + (b"" if nazov == bez_koncovky else KONIEC)
        if komp == 3:
            casti = [PRAZDNY_ZSTD if not riadky else b"\x28\xb5\x2f\xfd" + bytes(range(40))]
        elif komp == 1:
            z = bytearray(zlib.compress(obsah))
            if nazov == pokazit:
                z[len(z) // 2] ^= 0x55
            if nazov == bez_konca_gzip:
                del z[-4:]  # chýba kontrolný súčet na konci prúdu, štruktúra blokov ostáva v poriadku
            casti = [bytes(z[j:j + kusy]) for j in range(0, len(z), kusy)]
        else:
            casti = [obsah]
        bloky.append(b"\x01" + _ci(dump_id) + b"".join(_ci(len(c)) + c for c in casti) + _ci(0))
        meta.append((dump_id, tag, schema, f"COPY {nazov} (id) FROM stdin;\n"))
    pocet = 1 + len(meta)
    nulove = [polozka(1, "tab", "TABLE", "public", "", 3, 0)] + [polozka(d, t, "TABLE DATA", sch, c, 2, 0) for d, t, sch, c in meta]
    zaciatok = len(hlava) + len(_ci(pocet)) + sum(len(e) for e in nulove)
    polohy_dat, kde = [], zaciatok
    for b in bloky:
        polohy_dat.append(kde)
        kde += len(b)
    polozky = [nulove[0]] + [
        polozka(d, t, "TABLE DATA", sch, c, 2 if polohy else 1, polohy_dat[i] if polohy else 0) for i, (d, t, sch, c) in enumerate(meta)
    ]
    return hlava + _ci(pocet) + b"".join(polozky) + b"".join(bloky)


class ZakladSuboru(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="test_zaloha_")
        self.addCleanup(shutil.rmtree, self.d, True)

    def subor(self, nazov, obsah):
        c = os.path.join(self.d, nazov)
        with open(c, "wb") as f:
            f.write(obsah)
        return c


class Skuska(ZakladSuboru):

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


class SkuskaArchiv(ZakladSuboru):
    """Vlastné čítanie archívu pg_dump (custom), ktoré nepotrebuje pg_restore (export z Lovable je PostgreSQL 17/18, verzia archívu 1.16)."""

    NEPREBERA = ValueError("pg_restore archív nepreberie: pg_restore: error: unsupported version (1.16) in file header")

    def vsetky(self, **zmeny):
        t = {n: ["1\ta", "2\tb"] for n in oz.OCAKAVANE}
        t.update(zmeny)
        return t

    def over(self, obsah, nazov="e.backup", pg_restore=NEPREBERA):
        c = self.subor(nazov, obsah)
        with mock.patch.object(oz, "pg_restore_list", **({"side_effect": pg_restore} if isinstance(pg_restore, Exception) else {"return_value": pg_restore})):
            return oz.over(c)

    def test_zstd_prazdny(self):
        self.assertTrue(oz.zstd_prazdny(PRAZDNY_ZSTD))
        self.assertTrue(oz.zstd_prazdny(bytes.fromhex("28b52ffd2005") + bytes.fromhex("290000") + KONIEC))  # jeden segment, veľkosť obsahu v hlavičke
        self.assertTrue(oz.zstd_prazdny(bytes.fromhex("28b52ffd0458") + bytes.fromhex("290000") + KONIEC + b"\x00\x00\x00\x00"))  # s kontrolným súčtom
        self.assertFalse(oz.zstd_prazdny(bytes.fromhex("28b52ffd0058290000") + b"abcde"))  # rovnako veľký obsah, ale nie koncovka COPY
        self.assertFalse(oz.zstd_prazdny(bytes.fromhex("28b52ffd0058280000") + KONIEC))  # správny obsah, ale nie je to posledný blok
        self.assertFalse(oz.zstd_prazdny(PRAZDNY_ZSTD + b"\x00"))
        self.assertFalse(oz.zstd_prazdny(PRAZDNY_ZSTD[:-1]))
        self.assertFalse(oz.zstd_prazdny(b"\x28\xb5\x2f\xfd" + bytes(range(40))))
        self.assertFalse(oz.zstd_prazdny(b"nie je zstd" * 3))
        self.assertFalse(oz.zstd_prazdny(b""))

    def test_verzie_a_kompresie_s_presnymi_poctami(self):
        for vmin in (14, 15, 16):
            for komp in (0, 1):
                with self.subTest(verzia=f"1.{vmin}", kompresia=komp):
                    c = self.subor("a.dump", postav_custom({"public.organizations": ["1\ta", "2\tb", "3\tc"], "public.nic": [], "auth.users": ["1\tx"]}, vmin, komp))
                    i = oz.precitaj_custom(c)
                    self.assertEqual(i["verzia"], f"1.{vmin}.0")
                    self.assertEqual(i["kompresia"], "gzip" if komp else "žiadna")
                    t = i["tabulky"]
                    self.assertEqual(sorted(t), ["auth.users", "public.nic", "public.organizations"])
                    self.assertEqual((t["public.organizations"]["riadky"], t["public.organizations"]["prazdna"]), (3, False))
                    self.assertEqual((t["public.nic"]["riadky"], t["public.nic"]["prazdna"]), (0, True))
                    self.assertEqual(t["auth.users"]["riadky"], 1)
                    self.assertEqual(i["upozornenia"], [])

    def test_velka_tabulka_vo_viacerych_blokoch(self):
        riadky = [f"{n}\t" + hashlib.sha256(str(n).encode()).hexdigest() for n in range(5000)]
        i = oz.precitaj_custom(self.subor("v.dump", postav_custom({"public.punches": riadky}, 16, 1, kusy=512)))
        self.assertEqual(i["tabulky"]["public.punches"]["riadky"], 5000)

    def test_metadata_archivu(self):
        i = oz.precitaj_custom(self.subor("m.dump", postav_custom({"public.organizations": ["1\ta"]}, 16, 3)))
        self.assertEqual((i["verzia"], i["kompresia"], i["databaza"], i["server"]), ("1.16.0", "zstd", "postgres", "17.11"))
        self.assertIn("18.6", i["pg_dump"])
        self.assertEqual(i["vytvorene"], "2026-11-04 08:35:10")

    def test_zstd_pozna_prazdnu_tabulku_ale_nepocita_riadky(self):
        i = oz.precitaj_custom(self.subor("z.dump", postav_custom({"public.organizations": ["1\ta"], "public.nic": []}, 16, 3)))
        self.assertEqual(i["tabulky"]["public.organizations"], {"stlacene": 44, "riadky": None, "prazdna": False})
        self.assertEqual(i["tabulky"]["public.nic"], {"stlacene": 14, "riadky": 0, "prazdna": True})

    def test_nepodporovana_verzia_ide_na_pg_restore(self):
        for vmin in (13, 17, 99):
            c = self.subor("n.dump", postav_custom({"public.organizations": ["1"]}, 16, 1)[:6] + bytes([vmin]) + b"\x00" * 2000)
            with self.assertRaises(oz.NepodporovanaVerzia):
                oz.precitaj_custom(c)
            with mock.patch.object(oz, "pg_restore_list", return_value=toc_vypis()):
                self.assertEqual(oz.over(c)["problemy"], [])

    def test_useknuty_archiv_je_vzdy_chyba(self):
        cely = postav_custom(self.vsetky(), 16, 1)
        for rez in list(range(6, len(cely) - 1, 37)) + [len(cely) - 1]:
            with self.subTest(rez=rez):
                c = self.subor("u.dump", cely[:rez])
                with self.assertRaises(ValueError) as r:
                    oz.precitaj_custom(c)
                self.assertNotIsInstance(r.exception, oz.NepodporovanaVerzia)
        self.assertEqual(oz.precitaj_custom(self.subor("ok.dump", cely))["upozornenia"], [])

    def test_useknuty_gzip_prud_v_neporusenej_strukture_je_chyba(self):
        c = self.subor("g.dump", postav_custom(self.vsetky(), 16, 1, bez_konca_gzip="public.audit_log"))
        with self.assertRaisesRegex(ValueError, "public.audit_log"):
            oz.precitaj_custom(c)

    def test_useknutie_bez_ohladu_na_kompresiu(self):
        for komp in (0, 3):
            cely = postav_custom(self.vsetky(), 16, komp)
            for rez in list(range(6, len(cely) - 1, 53)) + [len(cely) - 1]:
                with self.subTest(kompresia=komp, rez=rez):
                    with self.assertRaises(ValueError):
                        oz.precitaj_custom(self.subor("u.dump", cely[:rez]))

    def test_poskodeny_gzip_blok_je_chyba(self):
        c = self.subor("p.dump", postav_custom(self.vsetky(), 16, 1, pokazit="public.punches"))
        with self.assertRaisesRegex(ValueError, "public.punches"):
            oz.precitaj_custom(c)
        v = oz.over(c)
        self.assertTrue(any("public.punches" in p for p in v["problemy"]), v["problemy"])

    def test_chybajuca_koncovka_je_chyba(self):
        c = self.subor("k.dump", postav_custom(self.vsetky(), 16, 0, bez_koncovky="public.devices"))
        with self.assertRaisesRegex(ValueError, "public.devices"):
            oz.precitaj_custom(c)

    def test_nie_je_pg_dump_a_neplatna_hlavicka(self):
        with self.assertRaises(ValueError):
            oz.precitaj_custom(self.subor("a.dump", b"PGDMX" + b"\x00" * 2000))
        with self.assertRaises(ValueError):
            oz.precitaj_custom(self.subor("b.dump", b"PGDMP\x01\x10\x00\x00\x00\x01" + b"\x00" * 2000))
        with self.assertRaises(ValueError):  # neprimerane veľký počet položiek obsahu
            oz.precitaj_custom(self.subor("c.dump", postav_custom({"public.organizations": ["1"]})[:60] + b"\x00" + (2**31 - 1).to_bytes(4, "little") + b"\x00" * 100))

    def test_archiv_bez_poloh_je_upozornenie(self):
        i = oz.precitaj_custom(self.subor("r.dump", postav_custom(self.vsetky(), 16, 1, polohy=False)))
        self.assertEqual(len(i["tabulky"]), len(oz.OCAKAVANE))
        self.assertTrue(all(t["riadky"] is None and t["prazdna"] is None for t in i["tabulky"].values()))
        self.assertTrue(any("polohy" in u for u in i["upozornenia"]))

    # --- over() ---
    def test_cely_archiv_1_16_je_v_poriadku_aj_ked_pg_restore_je_stary(self):
        for komp in (0, 1, 3):
            with self.subTest(kompresia=komp):
                v = self.over(postav_custom(self.vsetky(**{"public.punches": [], "public.month_closures": []}), 16, komp))
                self.assertEqual(v["problemy"], [])
                self.assertEqual(v["chybaju"], [])
                self.assertEqual(v["archiv"]["verzia"], "1.16.0")
                self.assertTrue(any("PostgreSQL 17" in u and "unsupported version" in u for u in v["upozornenia"]), v["upozornenia"])

    def test_chyba_tabulka_je_problem(self):
        t = self.vsetky()
        del t["public.punches"]
        v = self.over(postav_custom(t, 16, 1))
        self.assertEqual(v["chybaju"], ["public.punches"])
        self.assertTrue(any("public.punches" in p for p in v["problemy"]))

    def test_prazdna_povinna_tabulka_je_problem_ale_prazdne_razenia_nie(self):
        for komp in (0, 1, 3):
            with self.subTest(kompresia=komp):
                v = self.over(postav_custom(self.vsetky(**{"public.punches": [], "public.profiles": []}), 16, komp))
                self.assertEqual(len(v["problemy"]), 1, v["problemy"])
                self.assertIn("public.profiles", v["problemy"][0])
                self.assertNotIn("public.punches", v["problemy"][0])

    def test_pg_restore_ktory_archiv_cita_sa_porovna(self):
        obsah = postav_custom(self.vsetky(), 16, 1)
        v = self.over(obsah, pg_restore=toc_vypis())
        self.assertEqual((v["problemy"], v["upozornenia"]), ([], []))
        v = self.over(obsah, pg_restore=toc_vypis(oz.OCAKAVANE[:-2]))
        self.assertEqual(v["problemy"], [])
        self.assertTrue(any("líši" in u for u in v["upozornenia"]))
        v = self.over(obsah, pg_restore=None)  # pg_restore nie je nainštalovaný
        self.assertEqual((v["problemy"], v["upozornenia"]), ([], []))

    def test_zip_s_archivom(self):
        c = os.path.join(self.d, "export.backup.zip")
        with zipfile.ZipFile(c, "w") as z:
            z.writestr("export.backup", postav_custom(self.vsetky(), 16, 3))
        with mock.patch.object(oz, "pg_restore_list", side_effect=self.NEPREBERA):
            v = oz.over(c)
        self.assertEqual(v["problemy"], [])
        self.assertEqual(v["vrstvy"], ["zip", "pg_custom"])
        self.assertEqual(v["archiv"]["kompresia"], "zstd")

    # --- výpis a manifest ---
    def test_popis_tabulky(self):
        self.assertEqual(oz.popis_tabulky({"riadky": 1, "prazdna": False}), "1 riadok")
        self.assertEqual(oz.popis_tabulky({"riadky": 3, "prazdna": False}), "3 riadky")
        self.assertEqual(oz.popis_tabulky({"riadky": 60000, "prazdna": False}), "60000 riadkov")
        self.assertEqual(oz.popis_tabulky({"riadky": 0, "prazdna": True}), "prázdna")
        self.assertIn("obsahuje údaje", oz.popis_tabulky({"riadky": None, "prazdna": False}))
        self.assertIn("nie sú overené", oz.popis_tabulky({"riadky": None, "prazdna": None}))

    def test_hlavna_a_manifest_obsahuju_podrobnosti_archivu(self):
        c = self.subor("export.backup", postav_custom(self.vsetky(**{"public.month_closures": []}), 16, 1))
        koren = os.path.join(self.d, "zalohy")
        out = io.StringIO()
        with mock.patch.object(oz, "pg_restore_list", side_effect=self.NEPREBERA):
            self.assertEqual(oz.hlavna([c, "--ulozit", koren], out), 0)
        text = out.getvalue()
        self.assertIn("Archív pg_dump 1.16.0: server PostgreSQL 17.11", text)
        self.assertIn("public.month_closures", text)
        self.assertRegex(text, r"public\.month_closures\s+prázdna")
        self.assertRegex(text, r"public\.organizations\s+2 riadky")
        with open(os.path.join(koren, os.listdir(koren)[0], "manifest.json"), encoding="utf-8") as f:
            m = json.load(f)
        self.assertEqual(m["archiv"]["verzia"], "1.16.0")
        self.assertEqual(m["archiv"]["ocakavane_tabulky"]["public.month_closures"]["prazdna"], True)
        self.assertEqual(sorted(m["archiv"]["ocakavane_tabulky"]), sorted(oz.OCAKAVANE))

    def test_hlavna_odmietne_archiv_s_prazdnymi_uctami(self):
        c = self.subor("export.backup", postav_custom(self.vsetky(**{"auth.users": []}), 16, 3))
        out = io.StringIO()
        with mock.patch.object(oz, "pg_restore_list", side_effect=self.NEPREBERA):
            self.assertEqual(oz.hlavna([c, "--iba-over"], out), 1)
        self.assertIn("NEPOUŽÍVAJTE", out.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
