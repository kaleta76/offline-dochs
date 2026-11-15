Attribute VB_Name = "kl_02_Protokol"
'@Verzia 1.0.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: kl_02_Protokol
' POPIS: Súbor razenia .rzn (protokol v1, docs/KLIENT-ACCESS.md) na strane klienta. ČISTÉ funkcie: žiadne súbory, sieť, okná ani
'        čas počítača. Zostavenie textu zrkadlí tools/klient_protokol.py (zostav), kontrola zrkadlí rozober a je rovnaká ako príjem
'        na strane HR (mod_22_KlientRazenia.RozoberObsah). Zhodu s Pythonom overuje tools/test_klient_zhoda.py na zlatých vektoroch
'        z kl_08_Samotest.
'
'        Tvar súboru: ASCII, riadky ukončené CRLF, najviac 2048 bajtov:
'          DOCHSRZN;1 / id / oc / login / pc / kod / smer / cas / utc / odlozene / klient / #END
'        Rozdiel cas - utc musí byť 3600 alebo 7200 s (Bratislava). Názov súboru RRRRMMDD-HHMMSS_<id>.rzn (miestny čas a id).
'        Pri zápise sa nepridávajú žiadne ďalšie kľúče; pri kontrole sa neznámy kľúč ignoruje.
' ZOZNAM VEREJNÝCH PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - ZostavRazenie(id, oc, login, pc, kod, smer, cas, utc, odlozene, klient) : Text súboru (bez kontroly; volajúci ho overí cez RozoberRazenie).
' - RozoberRazenie(text, nazov, kodChyby, r)  : Kontrola textu; vráti dôvod odmietnutia ("" = v poriadku) a naplní r.
' - NazovSuboru(cas, id)                      : RRRRMMDD-HHMMSS_<id>.rzn.
' - CasNaText(d) / CasZTextu(s, d)            : Prevod času RRRR-MM-DDTHH:MM:SS.
' - JeGuidRazenia(s), PlatnyLogin(s), PlatneOc(s), PlatnyPocitac(s), PlatnyKod(s) : Kontroly jednotlivých hodnôt (vzory z protokolu).
'===============================================================================

Public Const HLAVICKA_RZN As String = "DOCHSRZN;1"
Public Const KONIEC_RZN As String = "#END"
Public Const PRIPONA_RZN As String = ".rzn"
Public Const MAX_BAJTOV_RZN As Long = 2048
Public Const KODY_RZN As String = "|WORK|DOCTOR|TRIP|FAMILY|LEAVE|SICK|PRIV|ERRAND|"

Public Type TRazenie
    Id As String              ' GUID veľkými písmenami
    Oc As String              ' osobné číslo
    Login As String           ' prihlasovacie meno do Windows
    Pc As String              ' názov počítača
    Kod As String             ' WORK, DOCTOR, ...
    Smer As String            ' IN / OUT
    Cas As Date               ' miestny čas razenia
    Utc As Date               ' ten istý okamih v UTC
    Odlozene As Boolean
    Klient As String          ' verzia klienta
End Type

'===============================================================================
' Kontroly hodnôt
'===============================================================================
Private Function JeCislo(ByVal s As String) As Boolean
    Dim i As Long, c As Long
    If Len(s) = 0 Then Exit Function
    For i = 1 To Len(s)
        c = AscW(Mid$(s, i, 1))
        If c < 48 Or c > 57 Then Exit Function
    Next i
    JeCislo = True
End Function

' Písmená a číslice (ASCII) plus povolené znaky z strDalsie; dĺžka lMin až lMax.
Private Function PlatnyText(ByVal s As String, ByVal lMin As Long, ByVal lMax As Long, ByVal strDalsie As String) As Boolean
    Dim i As Long, c As Long
    If Len(s) < lMin Or Len(s) > lMax Then Exit Function
    For i = 1 To Len(s)
        c = AscW(Mid$(s, i, 1))
        If Not ((c >= 48 And c <= 57) Or (c >= 65 And c <= 90) Or (c >= 97 And c <= 122)) Then
            If InStr(1, strDalsie, Mid$(s, i, 1), vbBinaryCompare) = 0 Then Exit Function
        End If
    Next i
    PlatnyText = True
End Function

' GUID zapísaný veľkými písmenami: 8-4-4-4-12.
Public Function JeGuidRazenia(ByVal s As String) As Boolean
    Dim i As Long, c As Long
    If Len(s) <> 36 Then Exit Function
    For i = 1 To 36
        c = AscW(Mid$(s, i, 1))
        Select Case i
            Case 9, 14, 19, 24
                If c <> 45 Then Exit Function
            Case Else
                If Not ((c >= 48 And c <= 57) Or (c >= 65 And c <= 70)) Then Exit Function
        End Select
    Next i
    JeGuidRazenia = True
End Function

Public Function PlatneOc(ByVal s As String) As Boolean
    PlatneOc = PlatnyText(s, 1, 20, "")
End Function

Public Function PlatnyLogin(ByVal s As String) As Boolean
    PlatnyLogin = PlatnyText(s, 1, 64, "._-")
End Function

Public Function PlatnyPocitac(ByVal s As String) As Boolean
    PlatnyPocitac = PlatnyText(s, 1, 63, "._-")
End Function

Public Function PlatnyKod(ByVal s As String) As Boolean
    If Not PlatnyText(s, 1, 20, "") Then Exit Function
    PlatnyKod = (InStr(1, KODY_RZN, "|" & s & "|", vbBinaryCompare) > 0)
End Function

' Názov kľúča: malé písmená a podčiarkovník, 1 až 20 znakov.
Private Function JeKluc(ByVal s As String) As Boolean
    Dim i As Long, c As Long
    If Len(s) < 1 Or Len(s) > 20 Then Exit Function
    For i = 1 To Len(s)
        c = AscW(Mid$(s, i, 1))
        If Not ((c >= 97 And c <= 122) Or c = 95) Then Exit Function
    Next i
    JeKluc = True
End Function

' Verzia klienta: 1 až 4 skupiny po 1 až 3 číslice oddelené bodkou.
Private Function JeVerzia(ByVal s As String) As Boolean
    Dim p() As String, i As Long
    p = Split(s, ".")
    If UBound(p) < 0 Or UBound(p) > 3 Then Exit Function
    For i = 0 To UBound(p)
        If Len(p(i)) > 3 Then Exit Function
        If Not JeCislo(p(i)) Then Exit Function
    Next i
    JeVerzia = True
End Function

'===============================================================================
' Čas
'===============================================================================
' Date -> RRRR-MM-DDTHH:MM:SS (bez ohľadu na miestne nastavenia Windows).
Public Function CasNaText(ByVal d As Date) As String
    CasNaText = Format$(Year(d), "0000") & "-" & Format$(Month(d), "00") & "-" & Format$(Day(d), "00") & "T" & _
                Format$(Hour(d), "00") & ":" & Format$(Minute(d), "00") & ":" & Format$(Second(d), "00")
End Function

' RRRR-MM-DDTHH:MM:SS -> Date; platný kalendárny a časový údaj.
Public Function CasZTextu(ByVal s As String, ByRef d As Date) As Boolean
    Dim y As Long, mo As Long, dd As Long, h As Long, mi As Long, se As Long, t As Date
    If Len(s) <> 19 Then Exit Function
    If Mid$(s, 5, 1) <> "-" Or Mid$(s, 8, 1) <> "-" Or Mid$(s, 14, 1) <> ":" Or Mid$(s, 17, 1) <> ":" Then Exit Function
    If StrComp(Mid$(s, 11, 1), "T", vbBinaryCompare) <> 0 Then Exit Function
    If Not (JeCislo(Mid$(s, 1, 4)) And JeCislo(Mid$(s, 6, 2)) And JeCislo(Mid$(s, 9, 2)) And JeCislo(Mid$(s, 12, 2)) And JeCislo(Mid$(s, 15, 2)) And JeCislo(Mid$(s, 18, 2))) Then Exit Function
    y = CLng(Mid$(s, 1, 4))
    mo = CLng(Mid$(s, 6, 2))
    dd = CLng(Mid$(s, 9, 2))
    h = CLng(Mid$(s, 12, 2))
    mi = CLng(Mid$(s, 15, 2))
    se = CLng(Mid$(s, 18, 2))
    If y < 1900 Or mo < 1 Or mo > 12 Or dd < 1 Or dd > 31 Or h > 23 Or mi > 59 Or se > 59 Then Exit Function
    t = DateSerial(y, mo, dd)
    If Year(t) <> y Or Month(t) <> mo Or Day(t) <> dd Then Exit Function
    d = t + TimeSerial(h, mi, se)
    CasZTextu = True
End Function

' RRRRMMDD-HHMMSS_<ID>.rzn z miestneho času razenia a ID.
Public Function NazovSuboru(ByVal dtCas As Date, ByVal strId As String) As String
    NazovSuboru = Format$(Year(dtCas), "0000") & Format$(Month(dtCas), "00") & Format$(Day(dtCas), "00") & "-" & _
                  Format$(Hour(dtCas), "00") & Format$(Minute(dtCas), "00") & Format$(Second(dtCas), "00") & "_" & strId & PRIPONA_RZN
End Function

'===============================================================================
' Zostavenie textu súboru (zrkadlo klient_protokol.zostav). Text je ASCII s CRLF a končí riadkom #END. Funkcia nič nekontroluje:
' volajúci musí výsledok pred zápisom overiť cez RozoberRazenie spolu s názvom súboru.
'===============================================================================
Public Function ZostavRazenie(ByVal strId As String, ByVal strOc As String, ByVal strLogin As String, ByVal strPc As String, _
                              ByVal strKod As String, ByVal strSmer As String, ByVal dtCas As Date, ByVal dtUtc As Date, _
                              ByVal bOdlozene As Boolean, ByVal strKlient As String) As String
    Dim s As String
    s = HLAVICKA_RZN & vbCrLf
    s = s & "id=" & strId & vbCrLf
    s = s & "oc=" & strOc & vbCrLf
    s = s & "login=" & strLogin & vbCrLf
    s = s & "pc=" & strPc & vbCrLf
    s = s & "kod=" & strKod & vbCrLf
    s = s & "smer=" & strSmer & vbCrLf
    s = s & "cas=" & CasNaText(dtCas) & vbCrLf
    s = s & "utc=" & CasNaText(dtUtc) & vbCrLf
    s = s & "odlozene=" & IIf(bOdlozene, "1", "0") & vbCrLf
    s = s & "klient=" & strKlient & vbCrLf
    s = s & KONIEC_RZN & vbCrLf
    ZostavRazenie = s
End Function

'===============================================================================
' Kontrola textu súboru (zrkadlo klient_protokol.rozober). Vráti dôvod odmietnutia ("" = v poriadku); strKodChyby je stabilný kód
' (VELKOST, ZNAKY, HLAVICKA, KONIEC, KLUC, HODNOTA, CAS, NAZOV). Pri prázdnom strNazov sa názov súboru nekontroluje.
' Text je reťazec, v ktorom jeden znak = jeden bajt súboru (klient píše a číta len ASCII; znak s kódom nad 127 je chyba ZNAKY).
'===============================================================================
Public Function RozoberRazenie(ByVal strText As String, ByVal strNazov As String, ByRef strKodChyby As String, ByRef r As TRazenie) As String
    Dim i As Long, c As Long, riadky() As String, nR As Long, dic As Object
    Dim strKluc As String, strHodn As String, p As Long, v As Variant, dCas As Date, dUtc As Date, lRozdiel As Long

    strKodChyby = ""
    If Len(strText) > MAX_BAJTOV_RZN Then
        strKodChyby = "VELKOST"
        RozoberRazenie = "súbor má " & Len(strText) & " bajtov (najviac " & MAX_BAJTOV_RZN & ")"
        Exit Function
    End If
    If Len(strText) >= 3 Then
        If AscW(Mid$(strText, 1, 1)) = &HEF And AscW(Mid$(strText, 2, 1)) = &HBB And AscW(Mid$(strText, 3, 1)) = &HBF Then strText = Mid$(strText, 4)
    End If
    For i = 1 To Len(strText)
        c = AscW(Mid$(strText, i, 1))
        If c > 127 Or c < 0 Then
            strKodChyby = "ZNAKY"
            RozoberRazenie = "súbor obsahuje znaky mimo ASCII"
            Exit Function
        End If
        If c < 32 And c <> 10 And c <> 13 Then
            strKodChyby = "ZNAKY"
            RozoberRazenie = "súbor obsahuje riadiace znaky"
            Exit Function
        End If
    Next i
    strText = Replace(strText, vbCr & vbLf, vbLf)
    strText = Replace(strText, vbLf & vbCr, vbLf)
    If InStr(1, strText, vbCr, vbBinaryCompare) > 0 Then
        strKodChyby = "ZNAKY"
        RozoberRazenie = "samotný znak CR v súbore"
        Exit Function
    End If
    riadky = Split(strText, vbLf)
    nR = UBound(riadky) + 1
    Do While nR > 0
        If Len(riadky(nR - 1)) > 0 Then Exit Do
        nR = nR - 1
    Loop
    If nR = 0 Then
        strKodChyby = "HLAVICKA"
        RozoberRazenie = "prvý riadok musí byť " & HLAVICKA_RZN
        Exit Function
    End If
    If StrComp(riadky(0), HLAVICKA_RZN, vbBinaryCompare) <> 0 Then
        strKodChyby = "HLAVICKA"
        RozoberRazenie = "prvý riadok musí byť " & HLAVICKA_RZN
        Exit Function
    End If
    If StrComp(riadky(nR - 1), KONIEC_RZN, vbBinaryCompare) <> 0 Then
        strKodChyby = "KONIEC"
        RozoberRazenie = "súbor nekončí riadkom " & KONIEC_RZN & " (nedopísaný alebo poškodený)"
        Exit Function
    End If
    For i = 1 To nR - 2
        If StrComp(riadky(i), KONIEC_RZN, vbBinaryCompare) = 0 Then
            strKodChyby = "KONIEC"
            RozoberRazenie = "riadok " & KONIEC_RZN & " sa nachádza pred koncom súboru"
            Exit Function
        End If
    Next i

    Set dic = CreateObject("Scripting.Dictionary")
    dic.CompareMode = 0
    For i = 1 To nR - 2
        p = InStr(1, riadky(i), "=", vbBinaryCompare)
        If p = 0 Then
            strKodChyby = "KLUC"
            RozoberRazenie = "riadok " & (i + 1) & " nemá tvar kluc=hodnota"
            Exit Function
        End If
        strKluc = Left$(riadky(i), p - 1)
        strHodn = Mid$(riadky(i), p + 1)
        If Not JeKluc(strKluc) Then
            strKodChyby = "KLUC"
            RozoberRazenie = "riadok " & (i + 1) & ": neplatný názov kľúča"
            Exit Function
        End If
        If dic.Exists(strKluc) Then
            strKodChyby = "KLUC"
            RozoberRazenie = "kľúč " & strKluc & " je v súbore viackrát"
            Exit Function
        End If
        dic.Add strKluc, strHodn
    Next i
    For Each v In Array("id", "oc", "login", "pc", "kod", "smer", "cas", "utc", "odlozene", "klient")
        If Not dic.Exists(CStr(v)) Then
            strKodChyby = "KLUC"
            RozoberRazenie = "chýba povinný kľúč " & CStr(v)
            Exit Function
        End If
    Next v

    strKodChyby = "HODNOTA"
    If Not JeGuidRazenia(CStr(dic("id"))) Then RozoberRazenie = "id nie je GUID zapísaný veľkými písmenami": Exit Function
    If Not PlatneOc(CStr(dic("oc"))) Then RozoberRazenie = "oc má byť 1 až 20 písmen alebo číslic": Exit Function
    If Not PlatnyLogin(CStr(dic("login"))) Then RozoberRazenie = "login má neplatné znaky alebo dĺžku": Exit Function
    If Not PlatnyPocitac(CStr(dic("pc"))) Then RozoberRazenie = "pc má neplatné znaky alebo dĺžku": Exit Function
    If Not PlatnyKod(CStr(dic("kod"))) Then RozoberRazenie = "kód '" & CStr(dic("kod")) & "' nie je zo zoznamu WORK, DOCTOR, TRIP, FAMILY, LEAVE, SICK, PRIV, ERRAND": Exit Function
    If StrComp(CStr(dic("smer")), "IN", vbBinaryCompare) <> 0 And StrComp(CStr(dic("smer")), "OUT", vbBinaryCompare) <> 0 Then RozoberRazenie = "smer musí byť IN alebo OUT": Exit Function
    If StrComp(CStr(dic("odlozene")), "0", vbBinaryCompare) <> 0 And StrComp(CStr(dic("odlozene")), "1", vbBinaryCompare) <> 0 Then RozoberRazenie = "odlozene musí byť 0 alebo 1": Exit Function
    If Not JeVerzia(CStr(dic("klient"))) Then RozoberRazenie = "klient má neplatnú verziu": Exit Function
    strKodChyby = "CAS"
    If Not CasZTextu(CStr(dic("cas")), dCas) Then RozoberRazenie = "cas nemá platný tvar RRRR-MM-DDTHH:MM:SS: '" & CStr(dic("cas")) & "'": Exit Function
    If Not CasZTextu(CStr(dic("utc")), dUtc) Then RozoberRazenie = "utc nemá platný tvar RRRR-MM-DDTHH:MM:SS: '" & CStr(dic("utc")) & "'": Exit Function
    lRozdiel = CLng(DateDiff("s", dUtc, dCas))
    If lRozdiel <> 3600 And lRozdiel <> 7200 Then RozoberRazenie = "rozdiel cas - utc je " & lRozdiel & " s (v Bratislave je 3600 alebo 7200)": Exit Function

    ' názov súboru: RRRRMMDD-HHMMSS_<ID>.rzn
    If Len(strNazov) > 0 Then
        strKodChyby = "NAZOV"
        If Len(strNazov) <> 56 Then RozoberRazenie = "názov súboru nemá tvar RRRRMMDD-HHMMSS_<ID>.rzn": Exit Function
        If Not (JeCislo(Left$(strNazov, 8)) And Mid$(strNazov, 9, 1) = "-" And JeCislo(Mid$(strNazov, 10, 6)) And Mid$(strNazov, 16, 1) = "_" And StrComp(Right$(strNazov, 4), PRIPONA_RZN, vbBinaryCompare) = 0) Then
            RozoberRazenie = "názov súboru nemá tvar RRRRMMDD-HHMMSS_<ID>.rzn"
            Exit Function
        End If
        If Not JeGuidRazenia(Mid$(strNazov, 17, 36)) Then RozoberRazenie = "názov súboru nemá tvar RRRRMMDD-HHMMSS_<ID>.rzn": Exit Function
        If StrComp(Mid$(strNazov, 17, 36), CStr(dic("id")), vbBinaryCompare) <> 0 Then RozoberRazenie = "ID v názve súboru sa nezhoduje s id v súbore": Exit Function
        If StrComp(strNazov, NazovSuboru(dCas, CStr(dic("id"))), vbBinaryCompare) <> 0 Then RozoberRazenie = "čas v názve súboru sa nezhoduje s cas v súbore": Exit Function
    End If

    strKodChyby = ""
    r.Id = CStr(dic("id"))
    r.Oc = CStr(dic("oc"))
    r.Login = CStr(dic("login"))
    r.Pc = CStr(dic("pc"))
    r.Kod = CStr(dic("kod"))
    r.Smer = CStr(dic("smer"))
    r.Cas = dCas
    r.Utc = dUtc
    r.Odlozene = (CStr(dic("odlozene")) = "1")
    r.Klient = CStr(dic("klient"))
End Function
