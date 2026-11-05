#!/usr/bin/env python3
"""Testy kontroly VBA modulov (tools/kontrola_vba.py). Spustenie: python3 -I tools/test_kontrola_vba.py"""
import importlib.util
import os
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("kontrola_vba", os.path.join(HERE, "kontrola_vba.py"))
kv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kv)

HLAVICKA = 'Attribute VB_Name = "%s"\n\'@Verzia 1.0.0\nOption Compare Database\nOption Explicit\n'


def kontrola(**moduly):
    """moduly: nazov -> telo (bez hlavičky). Vráti zoznam textov nálezov."""
    with tempfile.TemporaryDirectory() as d:
        for nazov, telo in moduly.items():
            with open(os.path.join(d, nazov + ".bas"), "w", encoding="utf-8", newline="\n") as f:
                f.write(HLAVICKA % nazov + telo)
        chyby, _ = kv.skontroluj(d)
        return ["%s:%s %s" % (c.modul, c.riadok, c.text) for c in chyby]


class Kontrola(unittest.TestCase):
    def test_zatienenie_funkcie_premennou_je_chyba(self):
        # presne chyba z balíka 2.12.0: premenná j (Long) zatieni funkciu J
        r = kontrola(m1="""
Private Function J(ByVal s As String) As String
    J = """ + '"x"' + """ & s
End Function
Public Function Spoj(ByVal n As Long) As String
    Dim j As Long, s As String
    For j = 1 To n
        s = s & J(CStr(j))
    Next j
    Spoj = s
End Function
""")
        self.assertEqual(len(r), 1, r)
        self.assertIn("zatieňuje funkciu J", r[0])

    def test_pole_s_rovnakym_menom_ako_funkcia_je_v_poriadku(self):
        r = kontrola(m1="""
Private Function A(ByVal s As String) As String
    A = s
End Function
Public Sub Pouzi()
    Dim a() As Long, x As String
    ReDim a(1 To 2)
    a(1) = 5
    x = A("k")
End Sub
""")
        self.assertEqual(r, [])

    def test_funkcia_bez_volania_nie_je_zatienena(self):
        r = kontrola(m1="""
Private Function J(ByVal s As String) As String
    J = s
End Function
Public Sub Cyklus()
    Dim j As Long
    For j = 1 To 3
    Next j
End Sub
""")
        self.assertEqual(r, [])

    def test_nedeklarovana_premenna(self):
        r = kontrola(m1="""
Public Sub X()
    Dim a As Long
    a = 1
    b = a + 1
End Sub
""")
        self.assertEqual(len(r), 1, r)
        self.assertIn("'b'", r[0])

    def test_chyba_option_explicit(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "m1.bas"), "w", encoding="utf-8") as f:
                f.write('Attribute VB_Name = "m1"\n\'@Verzia 1.0.0\nPublic Sub X()\nEnd Sub\n')
            chyby, _ = kv.skontroluj(d)
        self.assertTrue(any("Option Explicit" in c.text for c in chyby))

    def test_clen_ineho_modulu(self):
        r = kontrola(m2="""
Public Function Verejna(ByVal a As Long) As Long
    Verejna = a
End Function
Private Function Sukroma() As Long
    Sukroma = 1
End Function
""", m1="""
Public Sub X()
    Dim n As Long
    n = m2.Verejna(1)
    n = m2.Sukroma()
    n = m2.Nic(1)
End Sub
""")
        self.assertEqual(len(r), 2, r)
        self.assertTrue(any("súkromný" in x for x in r))
        self.assertTrue(any("taký člen nemá" in x for x in r))

    def test_pocet_argumentov(self):
        r = kontrola(m2="""
Public Function F(ByVal a As Long, Optional ByVal b As Long = 0) As Long
    F = a + b
End Function
""", m1="""
Public Sub X()
    Dim n As Long
    n = m2.F(1)
    n = m2.F(1, 2)
    n = m2.F(1, 2, 3)
    n = m2.F()
End Sub
""")
        self.assertEqual(len(r), 2, r)

    def test_byref_nezhoda_typu(self):
        r = kontrola(m2="""
Public Sub Napln(ByRef n As Long, ByVal i As Long, ByRef v As Variant)
    n = i
End Sub
""", m1="""
Public Sub X()
    Dim a As Integer, b As Long, c As Variant, d As String
    Call m2.Napln(b, a, a)
    Call m2.Napln(a, a, d)
    Call m2.Napln(c, b, b)
End Sub
""")
        self.assertEqual(len(r), 2, r)
        self.assertTrue(any("'a'" in x for x in r))
        self.assertTrue(any("'c'" in x for x in r))

    def test_bloky(self):
        dobre = """
Public Sub X(ByVal n As Long)
    Dim i As Long, s As String
    If n > 1 Then s = "a" Else s = "b"
    If n = 1 Then
        s = "c"
    ElseIf n = 2 Then
        s = "d"
    Else
        s = "e"
    End If
    For i = 1 To n
        Do While n > 0
            n = n - 1
        Loop
    Next i
    Select Case n
        Case 1: s = "x"
        Case Else: s = "y"
    End Select
End Sub
"""
        self.assertEqual(kontrola(m1=dobre), [])
        zle = """
Public Sub X(ByVal n As Long)
    Dim i As Long, j As Long
    If n = 1 Then
        n = 2
    For i = 1 To n
        For j = 1 To n
        Next i
    Next j
End Sub
"""
        r = kontrola(m1=zle)
        self.assertTrue(any("If" in x or "if" in x for x in r), r)
        self.assertTrue(any("Next" in x for x in r), r)

    def test_vstavane_a_pokracovania_nie_su_chyby(self):
        r = kontrola(m1="""
Public Function Pis(ByVal s As String) As String
    Dim db As DAO.Database, rs As DAO.Recordset, k As Long
    Set db = CurrentDb
    On Error GoTo Chyba
    Set rs = db.OpenRecordset("SELECT 1", dbOpenSnapshot)
    k = &HFF + Len(s) + _
        Val("2")
    Pis = IIf(k > 1, Format$(Now, "yyyy"), vbNullString) & vbCrLf
    rs.Close
    Exit Function
Chyba:
    Pis = Err.Description
End Function
""")
        self.assertEqual(r, [])


class Kodovanie(unittest.TestCase):
    def test_znak_mimo_cp1250_je_chyba(self):
        r = kontrola(m1="""
Public Sub A()
    MsgBox "a \u2192 b"
End Sub
""")
        self.assertEqual(len(r), 1, r)
        self.assertIn("1250", r[0])

    def test_slovenske_znaky_a_uvodzovky_su_v_poriadku(self):
        r = kontrola(m1="""
Public Sub A()
    MsgBox "Služobná cesta „x“ ľščťžýáíéúäôň"
End Sub
""")
        self.assertEqual(r, [])


class Balik(unittest.TestCase):
    def test_moduly_balika_prechadzaju_bez_nalezu(self):
        chyby, _ = kv.skontroluj(os.path.join(os.path.dirname(HERE), "access", "moduly"))
        self.assertEqual([str(c) for c in chyby], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
