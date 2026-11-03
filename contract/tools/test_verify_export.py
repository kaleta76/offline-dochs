#!/usr/bin/env python3
"""Testy overovača exportu (stdlib unittest). Spustenie: python3 -I contract/tools/test_verify_export.py"""
import csv, hashlib, importlib.util, io, os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN = os.path.join(HERE, "..", "examples", "punches_example.csv")
spec = importlib.util.spec_from_file_location("verify_export", os.path.join(HERE, "verify_export.py"))
ve = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ve)


def load_rows():
    text = open(GOLDEN, "rb").read().decode("utf-8-sig")
    body = text[: text.rfind("#END;")]
    return list(csv.DictReader(io.StringIO(body), delimiter=";", quotechar='"'))


def write(rows, fix_hash=True):
    """Zapíše riadky ako export so správnou pätičkou; pri fix_hash prepočíta record_hash (zmena = nový platný záznam)."""
    if fix_hash:
        for r in rows:
            r["record_hash"] = ve.record_hash(r)
    num = {"contract_version", "punch_id", "drift_minutes"}
    lines = [";".join(ve.REQ)]
    for r in rows:
        lines.append(";".join(r[c] if c in num else '"' + r[c] + '"' for c in ve.REQ))
    body = "\r\n".join(lines) + "\r\n"
    out = "﻿" + body + f"#END;rows={len(rows)};sha256={hashlib.sha256(body.encode()).hexdigest()}\r\n"
    fd, path = tempfile.mkstemp(suffix=".csv")
    with os.fdopen(fd, "wb") as f:
        f.write(out.encode("utf-8"))
    return path


def run(path, *extra):
    old = sys.stdout
    sys.stdout = io.StringIO()
    try:
        rc = ve.main([path, *extra])
        return rc, sys.stdout.getvalue()
    finally:
        sys.stdout = old


class VerifyExport(unittest.TestCase):
    def test_zlaty_subor(self):
        rc, out = run(GOLDEN)
        self.assertEqual(rc, 0, out)

    def test_ciastocny_export_bez_zaciatku_retaze(self):
        rows = load_rows()
        rows.sort(key=lambda r: int(r["punch_id"]))
        rows = rows[2:]  # začiatok reťaze (GENESIS) v súbore nie je
        rc, out = run(write(rows, fix_hash=False))
        self.assertEqual(rc, 0, out)
        self.assertIn("UPOZORNENIE", out)
        rc, out = run(write(load_rows()[2:], fix_hash=False), "--strict")
        self.assertEqual(rc, 1)

    def test_zmeneny_zaznam(self):
        rows = load_rows()
        rows[0]["code"] = "LEAVE"  # hash sa neprepočíta -> musí padnúť
        rc, out = run(write(rows, fix_hash=False))
        self.assertEqual(rc, 1)
        self.assertIn("record_hash", out)

    def test_poskodeny_subor(self):
        path = write(load_rows(), fix_hash=False)
        data = open(path, "rb").read().replace(b'"WORK"', b'"PRIV"', 1)
        open(path, "wb").write(data)
        rc, out = run(path)
        self.assertEqual(rc, 1)
        self.assertIn("kontrolný súčet", out)

    def test_vetvenie_retaze(self):
        rows = load_rows()
        a = next(r for r in rows if r["user_uuid"] == rows[0]["user_uuid"])
        b = dict(a)
        b["punch_id"] = str(int(a["punch_id"]) + 1000)
        b["external_id"] = "ffffffff-0000-4000-8000-00000000ffff"
        rows.append(b)  # rovnaký predchodca ako a
        rc, out = run(write(rows))
        self.assertEqual(rc, 1)
        self.assertIn("vetvenie", out)

    def test_odkaz_na_ineho_pouzivatela(self):
        rows = load_rows()
        users = sorted({r["user_uuid"] for r in rows})
        first = min((r for r in rows if r["user_uuid"] == users[0]), key=lambda r: int(r["punch_id"]))
        other = min((r for r in rows if r["user_uuid"] == users[1]), key=lambda r: int(r["punch_id"]))
        first["prev_hash"] = other["record_hash"]
        rc, out = run(write(rows))
        self.assertEqual(rc, 1)
        self.assertIn("iného používateľa", out)


if __name__ == "__main__":
    unittest.main()
