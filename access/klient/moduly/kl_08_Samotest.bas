Attribute VB_Name = "kl_08_Samotest"
'@Verzia 1.0.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: kl_08_Samotest
' POPIS: Samotest klienta. Spúšťa ho zostavovač (Instaluj-Klienta.ps1) po zostavení a dá sa spustiť aj ručne z okna priamych
'        príkazov:  ? kl_08_Samotest.SamoTestKlienta()
'        Výsledok "OK n, ZLE m" vypíše do okna priamych príkazov. Samotest NIKDY nezapisuje do priečinka prijem na serveri.
'
'        ZLATÉ VEKTORY: volania OverVektor nižšie obsahujú vstupy a očakávaný súbor .rzn (každý riadok súboru jedna položka Array
'        v poradí). Ten istý zoznam číta tools/test_klient_zhoda.py a porovnáva ho bajt po bajte s tools/klient_protokol.py
'        (zostav). Tvar volaní OverVektor a OverZlyVzor preto NEMEŇ (jedno volanie = jeden logický riadok, len reťazce
'        v úvodzovkách a čísla); ak sa zmení pravidlo protokolu, zmeň vektor tu aj pravidlo v Pythone naraz.
' ZOZNAM VEREJNÝCH PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - SamoTestKlienta()   : Spustí všetky kontroly; vráti počet ZLE (0 = v poriadku).
' - VypisSamotestu()    : Text posledného samotestu.
'===============================================================================

Private mOk As Long
Private mZle As Long
Private mVypis As String

Private Sub Pis(ByVal s As String)
    mVypis = mVypis & s & vbCrLf
    Debug.Print s
End Sub

Private Sub Zaznam(ByVal bOk As Boolean, ByVal strCo As String)
    If bOk Then
        mOk = mOk + 1
        Call Pis("OK    " & strCo)
    Else
        mZle = mZle + 1
        Call Pis("ZLE   " & strCo)
    End If
End Sub

Public Function VypisSamotestu() As String
    VypisSamotestu = mVypis
End Function

'===============================================================================
' Zlatý vektor: zo vstupov zostaví text a porovná ho s očakávanými riadkami; potom ho skontroluje a overí, že kontrola vrátila
' tie isté hodnoty (zostav -> rozober).
'===============================================================================
Private Sub OverVektor(ByVal strMeno As String, ByVal strId As String, ByVal strOc As String, ByVal strLogin As String, ByVal strPc As String, _
                       ByVal strKod As String, ByVal strSmer As String, ByVal strCas As String, ByVal strUtc As String, _
                       ByVal lOdlozene As Long, ByVal strKlient As String, ByVal vRiadky As Variant)
    Dim dCas As Date, dUtc As Date, strText As String, strOcak As String, i As Long
    Dim strKodChyby As String, strDovod As String, r As TRazenie, bRovnake As Boolean

    If Not kl_02_Protokol.CasZTextu(strCas, dCas) Or Not kl_02_Protokol.CasZTextu(strUtc, dUtc) Then
        Call Zaznam(False, "vektor " & strMeno & ": neplatný čas vo vstupe")
        Exit Sub
    End If
    For i = LBound(vRiadky) To UBound(vRiadky)
        strOcak = strOcak & CStr(vRiadky(i)) & vbCrLf
    Next i
    strText = kl_02_Protokol.ZostavRazenie(strId, strOc, strLogin, strPc, strKod, strSmer, dCas, dUtc, (lOdlozene <> 0), strKlient)
    Call Zaznam(StrComp(strText, strOcak, vbBinaryCompare) = 0, "vektor " & strMeno & ": zostavený text sa zhoduje (" & Len(strText) & " bajtov)")

    strDovod = kl_02_Protokol.RozoberRazenie(strText, kl_02_Protokol.NazovSuboru(dCas, strId), strKodChyby, r)
    Call Zaznam(Len(strDovod) = 0, "vektor " & strMeno & ": kontrola prijala text" & IIf(Len(strDovod) > 0, " (" & strKodChyby & ": " & strDovod & ")", ""))
    bRovnake = (StrComp(r.Id, strId, vbBinaryCompare) = 0) And (StrComp(r.Oc, strOc, vbBinaryCompare) = 0) And (StrComp(r.Login, strLogin, vbBinaryCompare) = 0)
    bRovnake = bRovnake And (StrComp(r.Pc, strPc, vbBinaryCompare) = 0) And (StrComp(r.Kod, strKod, vbBinaryCompare) = 0) And (StrComp(r.Smer, strSmer, vbBinaryCompare) = 0)
    bRovnake = bRovnake And (r.Cas = dCas) And (r.Utc = dUtc) And (r.Odlozene = (lOdlozene <> 0)) And (StrComp(r.Klient, strKlient, vbBinaryCompare) = 0)
    Call Zaznam(bRovnake, "vektor " & strMeno & ": zostav -> rozober vráti tie isté hodnoty")
End Sub

'===============================================================================
' Zlý vzor (zrkadlo klient_protokol.zle_vzory): v dobrom súbore (vektor "zima") sa nahradí strHladaj za strNahrad (znak ~ znamená
' koniec riadka CRLF) a kontrola ho musí odmietnuť s kódom strOcakavany. Pri neprázdnom strNazov sa použije tento názov súboru.
'===============================================================================
Private Sub OverZlyVzor(ByVal strMeno As String, ByVal strHladaj As String, ByVal strNahrad As String, ByVal strNazov As String, ByVal strOcakavany As String)
    Dim dCas As Date, dUtc As Date, strText As String, strKodChyby As String, strDovod As String, r As TRazenie
    Const ID_VZORU As String = "00000000-0000-0000-0000-00000000000A"

    Call kl_02_Protokol.CasZTextu("2026-11-03T07:31:12", dCas)
    Call kl_02_Protokol.CasZTextu("2026-11-03T06:31:12", dUtc)
    strText = kl_02_Protokol.ZostavRazenie(ID_VZORU, "9000001", "test.zam1", "PC-TEST", "WORK", "IN", dCas, dUtc, False, "1.0.0")
    If Len(strHladaj) > 0 Then
        If InStr(1, strText, Replace(strHladaj, "~", vbCrLf), vbBinaryCompare) = 0 Then
            Call Zaznam(False, "zlý vzor " & strMeno & ": hľadaný text vo vzore nie je")
            Exit Sub
        End If
        strText = Replace(strText, Replace(strHladaj, "~", vbCrLf), Replace(strNahrad, "~", vbCrLf), 1, -1, vbBinaryCompare)
    End If
    If Len(strNazov) = 0 Then strNazov = kl_02_Protokol.NazovSuboru(dCas, ID_VZORU)
    strDovod = kl_02_Protokol.RozoberRazenie(strText, strNazov, strKodChyby, r)
    Call Zaznam(Len(strDovod) > 0 And StrComp(strKodChyby, strOcakavany, vbBinaryCompare) = 0, _
                "zlý vzor " & strMeno & ": odmietnutý s kódom " & strOcakavany & IIf(strKodChyby <> strOcakavany, " (vrátil '" & strKodChyby & "')", ""))
End Sub

Private Sub TestProtokolu()
    Dim strKodChyby As String, r As TRazenie

    Call Pis("--- protokol: zlaté vektory")
    Call OverVektor("leto", "3F2A9C1E-7B64-4D0A-9E85-1C2D3E4F5A6B", "9000001", "test.zam1", "PC-TEST", "WORK", "IN", "2026-07-01T07:31:12", "2026-07-01T05:31:12", 0, "1.0.0", _
        Array("DOCHSRZN;1", "id=3F2A9C1E-7B64-4D0A-9E85-1C2D3E4F5A6B", "oc=9000001", "login=test.zam1", "pc=PC-TEST", "kod=WORK", _
              "smer=IN", "cas=2026-07-01T07:31:12", "utc=2026-07-01T05:31:12", "odlozene=0", "klient=1.0.0", "#END"))
    Call OverVektor("zima", "00000000-0000-0000-0000-00000000000A", "9000001", "test.zam1", "PC-TEST", "WORK", "IN", "2026-11-03T07:31:12", "2026-11-03T06:31:12", 0, "1.0.0", _
        Array("DOCHSRZN;1", "id=00000000-0000-0000-0000-00000000000A", "oc=9000001", "login=test.zam1", "pc=PC-TEST", "kod=WORK", _
              "smer=IN", "cas=2026-11-03T07:31:12", "utc=2026-11-03T06:31:12", "odlozene=0", "klient=1.0.0", "#END"))
    Call OverVektor("odlozene", "A1B2C3D4-0001-4000-8000-0123456789AB", "9000001", "test.zam1", "PC-TEST", "WORK", "OUT", "2026-11-03T15:36:02", "2026-11-03T14:36:02", 1, "1.0.0", _
        Array("DOCHSRZN;1", "id=A1B2C3D4-0001-4000-8000-0123456789AB", "oc=9000001", "login=test.zam1", "pc=PC-TEST", "kod=WORK", _
              "smer=OUT", "cas=2026-11-03T15:36:02", "utc=2026-11-03T14:36:02", "odlozene=1", "klient=1.0.0", "#END"))
    Call OverVektor("prerusenie", "FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF", "9000001", "test.zam1", "PC-TEST", "DOCTOR", "OUT", "2026-11-03T13:15:00", "2026-11-03T12:15:00", 0, "1.0.0", _
        Array("DOCHSRZN;1", "id=FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF", "oc=9000001", "login=test.zam1", "pc=PC-TEST", "kod=DOCTOR", _
              "smer=OUT", "cas=2026-11-03T13:15:00", "utc=2026-11-03T12:15:00", "odlozene=0", "klient=1.0.0", "#END"))
    Call OverVektor("polnoc", "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9", "9000001", "test.zam1", "PC-TEST", "WORK", "OUT", "2026-01-01T00:30:00", "2025-12-31T23:30:00", 0, "1.0.0", _
        Array("DOCHSRZN;1", "id=0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9", "oc=9000001", "login=test.zam1", "pc=PC-TEST", "kod=WORK", _
              "smer=OUT", "cas=2026-01-01T00:30:00", "utc=2025-12-31T23:30:00", "odlozene=0", "klient=1.0.0", "#END"))

    Call Pis("--- protokol: zlé vzory (kontrola ich musí odmietnuť)")
    Call OverZlyVzor("bez_konca", "#END~", "", "", "KONIEC")
    Call OverZlyVzor("hlavicka", "DOCHSRZN;1", "DOCHSRZN;2", "", "HLAVICKA")
    Call OverZlyVzor("kod", "kod=WORK", "kod=NIECO", "", "HODNOTA")
    Call OverZlyVzor("smer", "smer=IN", "smer=VON", "", "HODNOTA")
    Call OverZlyVzor("cas", "cas=2026-11-03T07:31:12", "cas=2026-13-03T07:31:12", "", "CAS")
    Call OverZlyVzor("utc_posun", "utc=2026-11-03T06:31:12", "utc=2026-11-03T04:31:12", "", "CAS")
    Call OverZlyVzor("dvojity_kluc", "pc=PC-TEST", "pc=PC-TEST~pc=PC-INY", "", "KLUC")
    Call OverZlyVzor("nazov_inak", "", "", "zle_nazov_inak.rzn", "NAZOV")

    Call Pis("--- protokol: ďalšie hranice")
    Call Zaznam(Len(kl_02_Protokol.RozoberRazenie(String$(2049, "A"), "", strKodChyby, r)) > 0 And strKodChyby = "VELKOST", "text dlhší než 2048 bajtov je odmietnutý (VELKOST)")
    Call Zaznam(Len(kl_02_Protokol.RozoberRazenie("DOCHSRZN;1" & vbCrLf & "oc=" & ChrW$(225) & vbCrLf & "#END" & vbCrLf, "", strKodChyby, r)) > 0 And strKodChyby = "ZNAKY", "znak mimo ASCII je odmietnutý (ZNAKY)")
    Call Zaznam(kl_02_Protokol.NazovSuboru(DateSerial(2026, 11, 3) + TimeSerial(7, 31, 12), "00000000-0000-0000-0000-00000000000A") = "20261103-073112_00000000-0000-0000-0000-00000000000A.rzn", "názov súboru má tvar RRRRMMDD-HHMMSS_<id>.rzn")
End Sub

'===============================================================================
' Hlavný vstup. Vráti počet ZLE.
'===============================================================================
Public Function SamoTestKlienta() As Long
    mOk = 0
    mZle = 0
    mVypis = ""
    Call Pis("SAMOTEST KLIENTA " & Format$(Now, "yyyy\-mm\-dd hh:nn:ss"))
    On Error GoTo Chyba
    Call TestProtokolu
Koniec:
    Call Pis("SÚHRN: OK " & mOk & ", ZLE " & mZle)
    SamoTestKlienta = mZle
    Exit Function
Chyba:
    mZle = mZle + 1
    Call Pis("ZLE   samotest skončil chybou " & Err.Number & ": " & Err.Description)
    Resume Koniec
End Function
