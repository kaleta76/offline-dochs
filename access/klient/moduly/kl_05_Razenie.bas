Attribute VB_Name = "kl_05_Razenie"
'@Verzia 1.0.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: kl_05_Razenie
' POPIS: Razenie: Príchod (WORK/IN), Odchod (WORK/OUT), začiatok prerušenia (KOD/OUT). Koniec prerušenia je Príchod.
'        Postup (Razit):
'          1. ochrana pred dvojklikom (5 s) a pred súbehom;
'          2. kontroly, ktoré sa LEN PÝTAJÚ (Áno/Nie, predvolene Nie): rovnaké razenie do 2 minút; odchod bez dnešného príchodu.
'             Klient razenie nikdy nezakáže pre "nelogické" poradie, úpravy robí HR v Editore dňa;
'          3. čas: UTC zo systému, miestny čas = UTC + posun; posun musí byť 60 alebo 120 minút (Bratislava), inak sa NIČ nezapíše;
'          4. text súboru sa zostaví, skontroluje rovnakou kontrolou ako príjem a zapíše do lokálnej fronty. Až potom
'          5. jeden pokus o doručenie na server (odlozene=0). Neúspech = razenie čaká vo fronte (odošle ho časovač s odlozene=1).
'        Razenie, ktoré sa nepodarilo zapísať lokálne, sa nikdy netvári ako zapísané.
'
'        Čisté funkcie (zrkadlo v tools/klient_protokol.py: stav_dna, popis_stavu, otazka_pred_razenim; zhodu overuje
'        tools/test_klient_zhoda.py) pracujú s dnešnými razeniami ako textom: položky oddelené |, položka utc;cas;KOD;SMER.
' ZOZNAM VEREJNÝCH PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - StavDna(razenia)                          : ČISTÁ: ZIADNE | PRACA;hh:mm | MIMO;hh:mm | PRERUSENIE;KOD;hh:mm.
' - PopisStavu(stav, nazovPrerusenia)         : ČISTÁ: text stavu pre okno.
' - OtazkaPredRazenim(razenia, kod, smer, utcTeraz) : ČISTÁ: "" | OPAKOVANE | BEZ_PRICHODU.
' - PlatnyPosun(minuty), PovoleneRazenie(kod, smer), NazovRazenia(kod, smer, nazovKodu) : ČISTÉ.
' - RazeniaNaText(r, n)                       : ČISTÁ: razenia dňa ako text pre funkcie vyššie.
' - NastavIdentitu(oc, login, pc, zdroj), VypniRazenie(dovod), RazenieZapnute(), DovodVypnutia()
' - OsobneCislo(), Ucet(), ZdrojIdentity()
' - ZapisRazenie(kod, smer, nazov, sprava, bezOtazok) : Kroky 1 až 4; True = razenie je zapísané v lokálnej fronte.
' - DorucRazenie(nazov)                       : Krok 5; vráti text výsledku pre okno.
' - Razit(kod, smer)                          : Celý postup; vráti text výsledku pre okno.
' - PoslednaSprava(), BlokovaneDo()           : Posledný text výsledku; do kedy sú tlačidlá zablokované.
' - StavDnaTeraz(), JeVPreruseni()            : Stav dňa z lokálneho záznamu.
'===============================================================================

Public Const STAV_ZIADNE As String = "ZIADNE"
Public Const STAV_PRACA As String = "PRACA"
Public Const STAV_MIMO As String = "MIMO"
Public Const STAV_PRERUSENIE As String = "PRERUSENIE"
Public Const OTAZKA_OPAKOVANE As String = "OPAKOVANE"
Public Const OTAZKA_BEZ_PRICHODU As String = "BEZ_PRICHODU"
Public Const OPAKOVANE_SEK As Long = 120
Public Const BLOKOVANIE_SEK As Long = 5
Public Const CHYBA_PASMO As String = "Hodiny počítača nie sú v časovom pásme Bratislava, razenie sa nezapísalo."

Private mOc As String
Private mLogin As String
Private mPc As String
Private mZdroj As String
Private mZapnute As Boolean
Private mDovod As String
Private mSprava As String
Private mBlokovaneDo As Date
Private mRazim As Boolean

'===============================================================================
' Čisté funkcie
'===============================================================================
' Posledné platné razenie z textu (najväčšie utc, pri zhode neskoršie v zozname). False = žiadne platné razenie.
Private Function PosledneRazenie(ByVal strRazenia As String, ByRef strUtc As String, ByRef strCas As String, ByRef strKod As String, _
                                 ByRef strSmer As String, ByRef bBolPrichod As Boolean) As Boolean
    Dim polozky() As String, i As Long, p() As String, d As Date, bMam As Boolean
    bBolPrichod = False
    strUtc = ""
    If Len(strRazenia) = 0 Then Exit Function
    polozky = Split(strRazenia, "|")
    For i = LBound(polozky) To UBound(polozky)
        p = Split(polozky(i), ";")
        If UBound(p) = 3 Then
            If kl_02_Protokol.CasZTextu(p(0), d) And kl_02_Protokol.CasZTextu(p(1), d) And kl_02_Protokol.PlatnyKod(p(2)) And _
               (StrComp(p(3), "IN", vbBinaryCompare) = 0 Or StrComp(p(3), "OUT", vbBinaryCompare) = 0) Then
                If StrComp(p(3), "IN", vbBinaryCompare) = 0 Then bBolPrichod = True
                If Not bMam Or StrComp(p(0), strUtc, vbBinaryCompare) >= 0 Then
                    strUtc = p(0)
                    strCas = p(1)
                    strKod = p(2)
                    strSmer = p(3)
                    bMam = True
                End If
            End If
        End If
    Next i
    PosledneRazenie = bMam
End Function

Public Function StavDna(ByVal strRazenia As String) As String
    Dim strUtc As String, strCas As String, strKod As String, strSmer As String, bPrichod As Boolean
    If Not PosledneRazenie(strRazenia, strUtc, strCas, strKod, strSmer, bPrichod) Then
        StavDna = STAV_ZIADNE
    ElseIf strSmer = "IN" Then
        StavDna = STAV_PRACA & ";" & Mid$(strCas, 12, 5)
    ElseIf strKod = "WORK" Then
        StavDna = STAV_MIMO & ";" & Mid$(strCas, 12, 5)
    Else
        StavDna = STAV_PRERUSENIE & ";" & strKod & ";" & Mid$(strCas, 12, 5)
    End If
End Function

Public Function PopisStavu(ByVal strStav As String, Optional ByVal strNazovPrerusenia As String = "") As String
    Dim p() As String
    PopisStavu = "Dnes ešte bez razenia"
    If Len(strStav) = 0 Then Exit Function
    p = Split(strStav, ";")
    If StrComp(p(0), STAV_PRACA, vbBinaryCompare) = 0 And UBound(p) = 1 Then
        PopisStavu = "V práci od " & p(1)
    ElseIf StrComp(p(0), STAV_MIMO, vbBinaryCompare) = 0 And UBound(p) = 1 Then
        PopisStavu = "Mimo práce od " & p(1)
    ElseIf StrComp(p(0), STAV_PRERUSENIE, vbBinaryCompare) = 0 And UBound(p) = 2 Then
        PopisStavu = "Prerušenie: " & IIf(Len(strNazovPrerusenia) > 0, strNazovPrerusenia, p(1)) & " od " & p(2)
    End If
End Function

Public Function OtazkaPredRazenim(ByVal strRazenia As String, ByVal strKod As String, ByVal strSmer As String, ByVal strUtcTeraz As String) As String
    Dim strUtc As String, strCas As String, strKodP As String, strSmerP As String, bPrichod As Boolean, bMam As Boolean, dTeraz As Date, dPosl As Date
    bMam = PosledneRazenie(strRazenia, strUtc, strCas, strKodP, strSmerP, bPrichod)
    If bMam Then
        If StrComp(strKodP, strKod, vbBinaryCompare) = 0 And StrComp(strSmerP, strSmer, vbBinaryCompare) = 0 Then
            If kl_02_Protokol.CasZTextu(strUtcTeraz, dTeraz) And kl_02_Protokol.CasZTextu(strUtc, dPosl) Then
                If Abs(DateDiff("s", dPosl, dTeraz)) < OPAKOVANE_SEK Then
                    OtazkaPredRazenim = OTAZKA_OPAKOVANE
                    Exit Function
                End If
            End If
        End If
    End If
    If StrComp(strKod, "WORK", vbBinaryCompare) = 0 And StrComp(strSmer, "OUT", vbBinaryCompare) = 0 And Not bPrichod Then OtazkaPredRazenim = OTAZKA_BEZ_PRICHODU
End Function

' Posun miestneho času oproti UTC v minútach, s ktorým sa smie raziť (Bratislava: zimný a letný čas).
Public Function PlatnyPosun(ByVal lMinuty As Long) As Boolean
    PlatnyPosun = (lMinuty = 60 Or lMinuty = 120)
End Function

' Klient zapisuje len: príchod WORK/IN, odchod WORK/OUT a začiatok prerušenia KOD/OUT.
Public Function PovoleneRazenie(ByVal strKod As String, ByVal strSmer As String) As Boolean
    If Not kl_02_Protokol.PlatnyKod(strKod) Then Exit Function
    If StrComp(strSmer, "OUT", vbBinaryCompare) = 0 Then
        PovoleneRazenie = True
    ElseIf StrComp(strSmer, "IN", vbBinaryCompare) = 0 Then
        PovoleneRazenie = (StrComp(strKod, "WORK", vbBinaryCompare) = 0)
    End If
End Function

' Názov razenia pre zoznam "Dnes".
Public Function NazovRazenia(ByVal strKod As String, ByVal strSmer As String, ByVal strNazovKodu As String) As String
    If strKod = "WORK" Then
        NazovRazenia = IIf(strSmer = "IN", "Príchod", "Odchod")
    ElseIf strSmer = "IN" Then
        NazovRazenia = strNazovKodu & " (návrat)"
    Else
        NazovRazenia = strNazovKodu
    End If
End Function

Public Function RazeniaNaText(ByRef r() As TRazenie, ByVal n As Long) As String
    Dim i As Long, s As String
    For i = 0 To n - 1
        s = s & IIf(i > 0, "|", "") & kl_02_Protokol.CasNaText(r(i).Utc) & ";" & kl_02_Protokol.CasNaText(r(i).Cas) & ";" & r(i).Kod & ";" & r(i).Smer
    Next i
    RazeniaNaText = s
End Function

'===============================================================================
' Stav modulu
'===============================================================================
Public Sub NastavIdentitu(ByVal strOc As String, ByVal strLogin As String, ByVal strPc As String, ByVal strZdroj As String)
    mOc = strOc
    mLogin = strLogin
    mPc = strPc
    mZdroj = strZdroj
    mZapnute = (kl_02_Protokol.PlatneOc(strOc) And kl_02_Protokol.PlatnyLogin(strLogin) And kl_02_Protokol.PlatnyPocitac(strPc))
    mDovod = IIf(mZapnute, "", kl_01_Identita.CHYBA_OC)
End Sub

Public Sub VypniRazenie(ByVal strDovod As String)
    mZapnute = False
    mDovod = strDovod
End Sub

Public Function RazenieZapnute() As Boolean
    RazenieZapnute = mZapnute
End Function

Public Function DovodVypnutia() As String
    DovodVypnutia = mDovod
End Function

Public Function OsobneCislo() As String
    OsobneCislo = mOc
End Function

Public Function Ucet() As String
    Ucet = mLogin
End Function

Public Function ZdrojIdentity() As String
    ZdrojIdentity = mZdroj
End Function

Public Function PoslednaSprava() As String
    PoslednaSprava = mSprava
End Function

Public Function BlokovaneDo() As Date
    BlokovaneDo = mBlokovaneDo
End Function

Private Function DnesneRazeniaText(ByVal dtDen As Date) As String
    Dim r() As TRazenie, b() As Boolean, n As Long
    n = kl_03_Fronta.RazeniaDna(dtDen, r, b)
    If n > 0 Then DnesneRazeniaText = RazeniaNaText(r, n)
End Function

Public Function StavDnaTeraz() As String
    Dim strStav As String, p() As String
    strStav = StavDna(DnesneRazeniaText(Date))
    p = Split(strStav, ";")
    If p(0) = STAV_PRERUSENIE And UBound(p) = 2 Then
        StavDnaTeraz = PopisStavu(strStav, kl_04_Konfig.NazovKodu(p(1)))
    Else
        StavDnaTeraz = PopisStavu(strStav)
    End If
End Function

' Podľa stavu dňa je zamestnanec v prerušení (tlačidlo Príchod sa vtedy volá "Návrat do práce").
Public Function JeVPreruseni() As Boolean
    JeVPreruseni = (Left$(StavDna(DnesneRazeniaText(Date)), Len(STAV_PRERUSENIE) + 1) = STAV_PRERUSENIE & ";")
End Function

'===============================================================================
' Razenie
'===============================================================================
' Kroky 1 až 4: kontroly, čas, zostavenie, kontrola a zápis do lokálnej fronty. True = razenie JE zapísané (strNazov je názov
' súboru vo fronte). False = nezapísalo sa nič; strSprava hovorí prečo ("" = používateľ odpovedal Nie alebo dvojklik).
Public Function ZapisRazenie(ByVal strKod As String, ByVal strSmer As String, ByRef strNazov As String, ByRef strSprava As String, _
                             Optional ByVal bBezOtazok As Boolean = False) As Boolean
    Dim dtCas As Date, dtUtc As Date, lPosun As Long, strDnes As String, strOtazka As String, strId As String, strText As String
    Dim strKodChyby As String, strDovod As String, r As TRazenie, lChyba As Long

    strNazov = ""
    strSprava = ""
    If mRazim Then Exit Function
    If Now < mBlokovaneDo Then Exit Function
    mRazim = True
    On Error GoTo Chyba

    If Not mZapnute Then
        strSprava = IIf(Len(mDovod) > 0, mDovod, "Razenie je vypnuté.")
        GoTo Koniec
    End If
    If Not PovoleneRazenie(strKod, strSmer) Then
        strSprava = "Neznáme razenie " & strKod & "/" & strSmer & ", nič sa nezapísalo."
        Call kl_00_Spolocne.ZapisLog("ERROR", "Razenie: nepovolená dvojica " & strKod & "/" & strSmer & ".")
        GoTo Koniec
    End If

    Call kl_00_Spolocne.CasTeraz(dtCas, dtUtc, lPosun)
    If Not PlatnyPosun(lPosun) Then
        strSprava = CHYBA_PASMO
        Call kl_00_Spolocne.ZapisLog("ERROR", "Razenie " & strKod & "/" & strSmer & " sa nezapísalo: posun oproti UTC je " & lPosun & " min.")
        GoTo Koniec
    End If

    If Not bBezOtazok Then
        strDnes = DnesneRazeniaText(DateValue(dtCas))
        strOtazka = OtazkaPredRazenim(strDnes, strKod, strSmer, kl_02_Protokol.CasNaText(dtUtc))
        If strOtazka = OTAZKA_OPAKOVANE Then
            If MsgBox("Rovnaké razenie ste zapísali pred chvíľou. Zapísať ho znova?", vbQuestion + vbYesNo + vbDefaultButton2, "Dochádzka") <> vbYes Then GoTo Koniec
        ElseIf strOtazka = OTAZKA_BEZ_PRICHODU Then
            If MsgBox("Dnes nemáte zapísaný príchod. Zapísať odchod?", vbQuestion + vbYesNo + vbDefaultButton2, "Dochádzka") <> vbYes Then GoTo Koniec
        End If
        If Len(strOtazka) > 0 Then
            ' čas razenia je okamih potvrdenia, nie okamih kliknutia (inak by sa líšil od času vzniku súboru)
            Call kl_00_Spolocne.CasTeraz(dtCas, dtUtc, lPosun)
            If Not PlatnyPosun(lPosun) Then
                strSprava = CHYBA_PASMO
                GoTo Koniec
            End If
        End If
    End If

    strId = kl_00_Spolocne.NoveGuid()
    If Len(strId) = 0 Then
        strSprava = "Nepodarilo sa vytvoriť číslo razenia, razenie sa nezapísalo."
        Call kl_00_Spolocne.ZapisLog("ERROR", "Razenie sa nezapísalo: NoveGuid zlyhalo.")
        GoTo Koniec
    End If
    strText = kl_02_Protokol.ZostavRazenie(strId, mOc, mLogin, mPc, strKod, strSmer, dtCas, dtUtc, False, kl_00_Spolocne.VERZIA_KLIENTA)
    strNazov = kl_02_Protokol.NazovSuboru(dtCas, strId)
    strDovod = kl_02_Protokol.RozoberRazenie(strText, strNazov, strKodChyby, r)
    If Len(strDovod) = 0 Then
        ' časy sa porovnávajú ako text (dve hodnoty Date toho istého okamihu sa môžu líšiť v poslednom bite)
        If StrComp(r.Id, strId, vbBinaryCompare) <> 0 Or kl_02_Protokol.CasNaText(r.Cas) <> kl_02_Protokol.CasNaText(dtCas) Or _
           kl_02_Protokol.CasNaText(r.Utc) <> kl_02_Protokol.CasNaText(dtUtc) Or r.Oc <> mOc Or r.Odlozene Then
            strKodChyby = "HODNOTA"
            strDovod = "kontrola vrátila iné hodnoty, než sa zapisovali"
        End If
    End If
    If Len(strDovod) > 0 Then
        strSprava = "Razenie sa nezapísalo (vnútorná kontrola: " & strKodChyby & "). Obráťte sa na HR."
        Call kl_00_Spolocne.ZapisLog("ERROR", "Razenie " & strKod & "/" & strSmer & " sa nezapísalo, kontrola: " & strKodChyby & " " & strDovod)
        strNazov = ""
        GoTo Koniec
    End If

    lChyba = kl_03_Fronta.UlozDoFronty(strNazov, strText)
    If lChyba <> 0 Then
        strSprava = "Razenie sa NEZAPÍSALO: nedá sa zapísať na disk počítača (chyba " & lChyba & "). Obráťte sa na IT."
        Call kl_00_Spolocne.ZapisLog("ERROR", "Razenie " & strKod & "/" & strSmer & " sa nezapísalo do fronty, chyba " & lChyba & ".")
        strNazov = ""
        GoTo Koniec
    End If

    mBlokovaneDo = DateAdd("s", BLOKOVANIE_SEK, Now)
    Call kl_00_Spolocne.ZapisLog("INFO", "Razenie id=" & strId & " kod=" & strKod & " smer=" & strSmer & " cas=" & kl_02_Protokol.CasNaText(dtCas) & " oc=" & mOc)
    strSprava = "Zapísané " & Mid$(kl_02_Protokol.CasNaText(dtCas), 12, 5) & " (odosielam…)"
    ZapisRazenie = True
Koniec:
    mSprava = strSprava
    mRazim = False
    Exit Function
Chyba:
    strSprava = "Razenie sa nezapísalo (chyba " & Err.Number & ")."
    Call kl_00_Spolocne.ZapisLog("ERROR", "Razenie skončilo chybou " & Err.Number & ": " & Err.Description)
    strNazov = ""
    ZapisRazenie = False
    Resume Koniec
End Function

' Krok 5: jeden pokus o doručenie práve zapísaného razenia (odlozene=0). Vráti text pre okno.
Public Function DorucRazenie(ByVal strNazov As String) As String
    Dim strCas As String, strVysledok As String
    strCas = Mid$(strNazov, 10, 2) & ":" & Mid$(strNazov, 12, 2)
    strVysledok = kl_03_Fronta.OdosliSubor(strNazov, False)
    If kl_03_Fronta.JeDorucene(strVysledok) Then
        mSprava = "Zapísané a odoslané " & strCas
    Else
        mSprava = "Zapísané " & strCas & ", čaká na odoslanie"
    End If
    DorucRazenie = mSprava
End Function

' Celý postup razenia. Vráti text výsledku pre okno ("" = nič sa nestalo: dvojklik alebo odpoveď Nie).
Public Function Razit(ByVal strKod As String, ByVal strSmer As String) As String
    Dim strNazov As String, strSprava As String
    If Not ZapisRazenie(strKod, strSmer, strNazov, strSprava) Then
        Razit = strSprava
        Exit Function
    End If
    DoEvents
    Razit = DorucRazenie(strNazov)
End Function
