Attribute VB_Name = "mod_UI_Pomocnik"
'@Verzia 1.2.1
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_UI_Pomocnik
' POPIS: Kontextové info okná (Pomocník) k jednotlivým kartám konzoly.
'
'   - Texty sú v tabuľkách (dajú sa upraviť): PomocnikKarty (názov, podtitul karty),
'     PomocnikTexty (riadky okna: druh, nadpis, popis), PomocnikStav (nezobrazovať / činnosť vykonaná).
'     Predvolené texty dodáva mod_UI_PomocnikTexty; pri zmene verzie textov (POMOCNIK_VERZIA) sa obnovia
'     všetky riadky, ktoré nemajú v stĺpci Upravene zaškrtnuté.
'   - Okno (frmPomocnik) je tabuľka riadkov Druh | Čo | Popis s hlavičkou (celý postup + vybraná karta)
'     a pätou (Nezobrazovať, Predošlá / Ďalšia, Prejsť na kartu, Zavrieť).
'   - Samo sa ukáže pri otvorení karty, ak používateľ činnosť ešte nerobil (v databáze nie sú príslušné
'     údaje) a nezaškrtol Nezobrazovať; najviac raz za reláciu pre každú kartu. Pri prázdnej databáze sa
'     tak pri štarte zobrazí postup importu z Ordata alebo zadania osobných čísel.
'   - Kedykoľvek ho vyvoláte tlačidlom Pomocník v hlavičke konzoly (klávesová skratka Alt+P).
'   - Ak sa okno nedá vytvoriť, zobrazí sa text v Poznámkovom bloku.
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - ZabezpecPomocnik()                       : Vytvorí tabuľky a (pri novej verzii) naplní predvolené texty.
' - KartaKluc / KartaCislo / KartaKratky     : Kľúče kariet (PROCES, IMPORT, ZAMESTNANCI, KONTROLA, EDITOR, PRERUSENIA, VYPOCET, EXPORT, ADMIN, AD).
' - KartaNazov / KartaPodtitul / TitulKarty  : Texty kariet z tabuľky PomocnikKarty.
' - JePrazdnaDatabaza()                      : True, ak nie sú zamestnanci ani razenia.
' - JeCinnostVykonana(karta)                 : True, ak používateľ činnosť na karte už robil.
' - OznacCinnost(karta)                      : Zapíše, že činnosť na karte bola vykonaná (volajú ju karty po akcii).
' - PomocnikZobraz(karta, auto)              : Otvorí okno pre kartu (prázdne = aktívna karta konzoly).
' - PomocnikAutoZobraz(karta)                : Zobrazí okno len ak má (činnosť nevykonaná, nie je skryté, nebolo v relácii).
' - PomocnikPriStarte()                      : Úvodné okno po otvorení konzoly.
' - VytvorFormularPomocnika()                : Vygeneruje frmPomocnik.
' - Pomocnik*UI()                            : Obsluha tlačidiel okna a administrácie.
'===============================================================================

Public Const POMOCNIK_VERZIA As String = "1.2.0"
Private Const FRM_POM As String = "frmPomocnik"
Private Const FRM_KON As String = "frmHlavnaKonzola"
Private Const VERZIA_FORMULARA As String = "1.2"
Private Const KLUC_VERZIA_FORMULARA As String = "PomocnikFormVerzia"
Private Const POCET_KARIET As Long = 9

'===============================================================================
' KARTY
'===============================================================================

Public Function KartaKluc(ByVal lCislo As Long) As String
    Select Case lCislo
        Case 0: KartaKluc = "PROCES"
        Case 1: KartaKluc = "IMPORT"
        Case 2: KartaKluc = "ZAMESTNANCI"
        Case 3: KartaKluc = "KONTROLA"
        Case 4: KartaKluc = "EDITOR"
        Case 5: KartaKluc = "PRERUSENIA"
        Case 6: KartaKluc = "VYPOCET"
        Case 7: KartaKluc = "EXPORT"
        Case 8: KartaKluc = "ADMIN"
        Case 9: KartaKluc = "AD"
    End Select
End Function

Public Function KartaCislo(ByVal strKluc As String) As Long
    Select Case UCase$(strKluc)
        Case "PROCES": KartaCislo = 0
        Case "IMPORT": KartaCislo = 1
        Case "ZAMESTNANCI": KartaCislo = 2
        Case "KONTROLA": KartaCislo = 3
        Case "EDITOR": KartaCislo = 4
        Case "PRERUSENIA": KartaCislo = 5
        Case "VYPOCET": KartaCislo = 6
        Case "EXPORT": KartaCislo = 7
        Case "ADMIN": KartaCislo = 8
        Case "AD": KartaCislo = 9
        Case Else: KartaCislo = -1
    End Select
End Function

Public Function KartaKratky(ByVal strKluc As String) As String
    Select Case UCase$(strKluc)
        Case "PROCES": KartaKratky = "Postup"
        Case "IMPORT": KartaKratky = "Import"
        Case "ZAMESTNANCI": KartaKratky = "Zamestnanci"
        Case "KONTROLA": KartaKratky = "Kontrola"
        Case "EDITOR": KartaKratky = "Editor"
        Case "PRERUSENIA": KartaKratky = "Prerušenia"
        Case "VYPOCET": KartaKratky = "Výpočet"
        Case "EXPORT": KartaKratky = "Exporty"
        Case "ADMIN": KartaKratky = "Admin"
        Case "AD": KartaKratky = "AD"
    End Select
End Function

Private Function HodnotaKarty(ByVal strKluc As String, ByVal strPole As String, ByVal strPredvolene As String) As String
    Dim v As Variant
    On Error Resume Next
    HodnotaKarty = strPredvolene
    v = DLookup("[" & strPole & "]", "PomocnikKarty", "Karta = " & mod_00_Common.SqlText(strKluc))
    If Not IsNull(v) And Not IsEmpty(v) Then
        If Len(CStr(v)) > 0 Then HodnotaKarty = CStr(v)
    End If
End Function

Public Function KartaNazov(ByVal strKluc As String) As String
    KartaNazov = HodnotaKarty(strKluc, "Nazov", KartaKratky(strKluc))
End Function

Public Function KartaPodtitul(ByVal strKluc As String) As String
    KartaPodtitul = HodnotaKarty(strKluc, "Podtitul", "")
End Function

'-------------------------------------------------------------------------------
' Nadpis okna: "3  ·  Kontrola a automatické opravy" (pre prehľad postupu bez čísla).
'-------------------------------------------------------------------------------
Public Function TitulKarty(ByVal strKluc As String) As String
    Dim lC As Long
    lC = KartaCislo(strKluc)
    If lC >= 1 Then
        TitulKarty = lC & "  " & ChrW(183) & "  " & KartaNazov(strKluc)
    Else
        TitulKarty = KartaNazov(strKluc)
    End If
End Function

Private Function KartaAuto(ByVal strKluc As String) As Boolean
    Dim v As Variant
    On Error Resume Next
    KartaAuto = (KartaCislo(strKluc) >= 1 And UCase$(strKluc) <> "ADMIN")
    v = DLookup("AutoZobraz", "PomocnikKarty", "Karta = " & mod_00_Common.SqlText(strKluc))
    If Not IsNull(v) And Not IsEmpty(v) Then KartaAuto = CBool(v)
End Function

'===============================================================================
' TABUĽKY A TEXTY
'===============================================================================

'-------------------------------------------------------------------------------
' Vytvorí tabuľky Pomocníka (ak chýbajú) a pri zmene verzie textov ich naplní predvolenými textami.
'-------------------------------------------------------------------------------
Public Sub ZabezpecPomocnik()
    On Error GoTo Chyba
    Dim db As DAO.Database
    Set db = CurrentDb
    If Not mod_00_Common.TabulkaExistujeDB(db, "PomocnikKarty") Then
        db.Execute "CREATE TABLE PomocnikKarty (Karta TEXT(20) PRIMARY KEY, Poradie LONG, Cislo TEXT(3), Kratky TEXT(30), " & _
                   "Nazov TEXT(120), Podtitul TEXT(255), AutoZobraz YESNO, Verzia TEXT(12))", dbFailOnError
    End If
    If Not mod_00_Common.TabulkaExistujeDB(db, "PomocnikTexty") Then
        db.Execute "CREATE TABLE PomocnikTexty (ID COUNTER PRIMARY KEY, Karta TEXT(20), Poradie LONG, Typ TEXT(10), " & _
                   "Stitok TEXT(20), Nadpis TEXT(150), Popis LONGTEXT, Upravene YESNO, Verzia TEXT(12))", dbFailOnError
        db.Execute "CREATE INDEX idxPT_Karta ON PomocnikTexty (Karta, Poradie)", dbFailOnError
    End If
    If Not mod_00_Common.TabulkaExistujeDB(db, "PomocnikStav") Then
        db.Execute "CREATE TABLE PomocnikStav (Karta TEXT(20) PRIMARY KEY, Skryt YESNO, Vykonana YESNO, " & _
                   "DatumVykonania DATETIME, DatumSkrytia DATETIME)", dbFailOnError
    End If
    If mod_00_Common.GetNastavenie("PomocnikVerzia", "") <> POMOCNIK_VERZIA Then
        Call mod_UI_PomocnikTexty.NaplnTexty(db, POMOCNIK_VERZIA)
        Call mod_00_Common.SetNastavenie("PomocnikVerzia", POMOCNIK_VERZIA, "Verzia textov Pomocníka (info okná kariet)")
    End If
    Set db = Nothing
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Pomocnik.ZabezpecPomocnik", "ERROR", Err.Description)
End Sub

'===============================================================================
' STAV A DETEKCIA VYKONANEJ ČINNOSTI
'===============================================================================

Private Function StavPole(ByVal strKluc As String, ByVal strPole As String) As Boolean
    Dim v As Variant
    On Error Resume Next
    v = DLookup("[" & strPole & "]", "PomocnikStav", "Karta = " & mod_00_Common.SqlText(strKluc))
    If Not IsNull(v) And Not IsEmpty(v) Then StavPole = CBool(v)
End Function

Private Sub NastavStav(ByVal strKluc As String, ByVal strPole As String, ByVal bHodnota As Boolean)
    On Error GoTo Chyba
    Dim rs As DAO.Recordset
    Set rs = CurrentDb.OpenRecordset("SELECT * FROM PomocnikStav WHERE Karta = " & mod_00_Common.SqlText(strKluc) & ";", dbOpenDynaset)
    If rs.EOF Then
        rs.AddNew
        rs!Karta = strKluc
        rs!Skryt = False
        rs!Vykonana = False
    Else
        rs.Edit
    End If
    rs.Fields(strPole).Value = bHodnota
    If strPole = "Vykonana" Then rs!DatumVykonania = Now
    If strPole = "Skryt" Then rs!DatumSkrytia = Now
    rs.Update
    rs.Close
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Pomocnik.NastavStav", "ERROR", Err.Description)
End Sub

Private Function MaZaznamy(ByVal strTab As String, Optional ByVal strWhere As String = "") As Boolean
    On Error GoTo Chyba
    Dim rs As DAO.Recordset, strSql As String, db As DAO.Database
    Set db = CurrentDb
    If Not mod_00_Common.TabulkaExistujeDB(db, strTab) Then Exit Function
    strSql = "SELECT TOP 1 1 AS X FROM [" & strTab & "]"
    If Len(strWhere) > 0 Then strSql = strSql & " WHERE " & strWhere
    Set rs = db.OpenRecordset(strSql & ";", dbOpenSnapshot)
    MaZaznamy = Not rs.EOF
    rs.Close
    Exit Function
Chyba:
    MaZaznamy = False
End Function

'-------------------------------------------------------------------------------
' True, ak v databáze nie je ani zamestnanec, ani razenie (po inštalácii bez importu).
'-------------------------------------------------------------------------------
Public Function JePrazdnaDatabaza() As Boolean
    JePrazdnaDatabaza = Not (MaZaznamy("Zamestnanci") Or MaZaznamy("DochadzkaImport"))
End Function

'-------------------------------------------------------------------------------
' True, ak používateľ činnosť na karte už robil: v databáze sú príslušné údaje, alebo karta zapísala príznak.
'-------------------------------------------------------------------------------
Public Function JeCinnostVykonana(ByVal strKluc As String) As Boolean
    Dim bData As Boolean
    On Error Resume Next
    Select Case UCase$(strKluc)
        Case "IMPORT"
            bData = Not JePrazdnaDatabaza()
        Case "ZAMESTNANCI"
            bData = False          ' činnosť sa eviduje príznakom (OznacCinnost) po uložení karty, priradení alebo vyradení
        Case "AD"
            bData = MaZaznamy("Zamestnanci", "LoginAD Is Not Null AND LoginAD <> ''")
        Case "KONTROLA"
            bData = MaZaznamy("DochadzkaAutoOpravy") Or MaZaznamy("DochadzkaAnomalie")
        Case "EDITOR"
            bData = MaZaznamy("DochadzkaAudit")
        Case "VYPOCET"
            bData = MaZaznamy("DochadzkaMesiacSumar")
        Case Else
            bData = False
    End Select
    JeCinnostVykonana = bData Or StavPole(UCase$(strKluc), "Vykonana")
End Function

Public Sub OznacCinnost(ByVal strKluc As String)
    On Error Resume Next
    If Not mod_00_Common.TabulkaExistuje("PomocnikStav") Then Exit Sub
    If StavPole(UCase$(strKluc), "Vykonana") Then Exit Sub
    Call NastavStav(UCase$(strKluc), "Vykonana", True)
End Sub

'===============================================================================
' ZOBRAZENIE
'===============================================================================

'-------------------------------------------------------------------------------
' Zobrazí okno Pomocníka len ak je to užitočné: karta nemá vypnuté zobrazovanie, používateľ nezaškrtol
' Nezobrazovať, činnosť na karte ešte nerobil a okno sa pre ňu v tejto relácii ešte neukázalo.
'-------------------------------------------------------------------------------
Public Sub PomocnikAutoZobraz(ByVal strKluc As String)
    On Error GoTo Chyba
    strKluc = UCase$(strKluc)
    If CLng(mod_UI_Spolocne.TVGet("DochTest", 0)) = 1 Then Exit Sub
    If KartaCislo(strKluc) < 1 Then Exit Sub
    If Not mod_00_Common.TabulkaExistuje("PomocnikKarty") Then Exit Sub
    If Not KartaAuto(strKluc) Then Exit Sub
    If StavPole(strKluc, "Skryt") Then Exit Sub
    If CLng(mod_UI_Spolocne.TVGet("PH_Auto_" & strKluc, 0)) = 1 Then Exit Sub
    If JeCinnostVykonana(strKluc) Then Exit Sub
    Call mod_UI_Spolocne.TVSet("PH_Auto_" & strKluc, 1)
    Call PomocnikZobraz(strKluc, True)
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Pomocnik.PomocnikAutoZobraz", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Úvodné okno po otvorení konzoly (aktívna je prvá karta).
'-------------------------------------------------------------------------------
Public Sub PomocnikPriStarte()
    On Error Resume Next
    If CLng(mod_UI_Spolocne.TVGet("DochTest", 0)) = 1 Then Exit Sub
    Call PomocnikAutoZobraz(mod_UI_Core.UI_AktivnaKarta())
End Sub

'-------------------------------------------------------------------------------
' Otvorí okno Pomocníka pre kartu (prázdny kľúč = aktívna karta konzoly).
'-------------------------------------------------------------------------------
Public Sub PomocnikZobraz(Optional ByVal strKluc As String = "", Optional ByVal bAuto As Boolean = False)
    On Error GoTo Chyba
    Dim bHotovo As Boolean
    If Len(strKluc) = 0 Then strKluc = mod_UI_Core.UI_AktivnaKarta()
    strKluc = UCase$(strKluc)
    If KartaCislo(strKluc) < 0 Then strKluc = "PROCES"
    Call ZabezpecPomocnik

    If Not FormularAktualny() Then
        If Not VytvorFormularPomocnika() Then
            Call PomocnikZobrazTextom(strKluc)
            Exit Sub
        End If
    End If
    If Not mod_00_Common.FormIsOpen(FRM_POM) Then
        DoCmd.OpenForm FRM_POM, acNormal, , , , acHidden
    End If
    Call PomocnikNacitaj(strKluc)
    Forms(FRM_POM).Visible = True
    Forms(FRM_POM).SetFocus
    Call UmiestniOkno
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Pomocnik.PomocnikZobraz", "ERROR", Err.Description)
    On Error Resume Next
    Call PomocnikZobrazTextom(strKluc)
End Sub

Private Function FormularAktualny() As Boolean
    FormularAktualny = mod_00_Common.FormularExistujeDB(FRM_POM) And _
                       (mod_00_Common.GetNastavenie(KLUC_VERZIA_FORMULARA, "") = VERZIA_FORMULARA)
End Function

'-------------------------------------------------------------------------------
' Vycentruje okno Pomocníka v okne konzoly a nastaví jeho veľkosť (twipy).
'-------------------------------------------------------------------------------
Private Sub UmiestniOkno()
    Dim lL As Long, lT As Long, lW As Long, lH As Long
    On Error Resume Next
    lW = 12000: lH = 9600
    If mod_00_Common.FormIsOpen(FRM_KON) Then
        lL = (Forms(FRM_KON).WindowWidth - lW) \ 2
        lT = (Forms(FRM_KON).WindowHeight - lH) \ 2
    End If
    If lL < 0 Then lL = 0
    If lT < 0 Then lT = 0
    DoCmd.MoveSize lL, lT, lW, lH
End Sub

'-------------------------------------------------------------------------------
' Naplní okno obsahom karty: nadpis, podtitul, prehľad postupu, riadky tabuľky a stav políčka Nezobrazovať.
'-------------------------------------------------------------------------------
Private Sub PomocnikNacitaj(ByVal strKluc As String)
    Dim frm As Form, i As Long, lCis As Long
    On Error Resume Next
    Set frm = Forms(FRM_POM)
    lCis = KartaCislo(strKluc)
    Call mod_UI_Spolocne.TVSet("PH_Kluc", strKluc)
    If lCis >= 1 Then Call mod_UI_Spolocne.TVSet("PH_Auto_" & strKluc, 1)   ' v tejto relácii už okno videl - samo sa pre kartu neukáže znova
    frm.Controls("lblPhTitul").Caption = TitulKarty(strKluc)
    frm.Controls("lblPhPodtitul").Caption = KartaPodtitul(strKluc)
    frm.Caption = "Pomocník - " & KartaNazov(strKluc)
    For i = 1 To POCET_KARIET
        Call ZvyrazniCip(frm.Controls("lblPhK" & i), (i = lCis))
    Next i
    frm.RecordSource = "SELECT Typ, Stitok, Nadpis, Popis FROM PomocnikTexty WHERE Karta = " & _
                       mod_00_Common.SqlText(strKluc) & " ORDER BY Poradie;"
    frm.Controls("btnPhZavriet").SetFocus   ' prvok s fokusom sa nedá zakázať
    frm.Controls("chkPhNezobrazovat").Value = (lCis >= 1 And StavPole(strKluc, "Skryt"))
    frm.Controls("chkPhNezobrazovat").Enabled = (lCis >= 1)
    frm.Controls("btnPhNaKartu").Enabled = (lCis >= 1 And KartaJeVKonzole(strKluc))
    frm.Controls("btnPhProces").Enabled = (lCis <> 0)
    frm.Controls("btnPhZavriet").SetFocus
End Sub

Private Function KartaJeVKonzole(ByVal strKluc As String) As Boolean
    KartaJeVKonzole = (mod_UI_Core.UI_IndexKarty(strKluc) >= 0)
End Function

Private Sub ZvyrazniCip(ByVal ctl As Control, ByVal bAktivny As Boolean)
    On Error Resume Next
    If bAktivny Then
        ctl.BackColor = RGB(255, 255, 255)
        ctl.ForeColor = RGB(15, 30, 90)
        ctl.FontBold = True
    Else
        ctl.BackColor = RGB(45, 70, 140)
        ctl.ForeColor = RGB(215, 225, 250)
        ctl.FontBold = False
    End If
End Sub

'-------------------------------------------------------------------------------
' Záloha: obsah karty ako text v Poznámkovom bloku (ak sa okno nepodarí vytvoriť).
'-------------------------------------------------------------------------------
Private Sub PomocnikZobrazTextom(ByVal strKluc As String)
    Dim rs As DAO.Recordset, s As String, strCesta As String, f As Integer
    On Error GoTo Chyba
    s = TitulKarty(strKluc) & vbCrLf & KartaPodtitul(strKluc) & vbCrLf & String$(60, "-") & vbCrLf
    Set rs = CurrentDb.OpenRecordset("SELECT Stitok, Nadpis, Popis FROM PomocnikTexty WHERE Karta = " & _
                                     mod_00_Common.SqlText(strKluc) & " ORDER BY Poradie;", dbOpenSnapshot)
    Do While Not rs.EOF
        s = s & vbCrLf & "[" & Nz(rs!Stitok, "") & "] " & Nz(rs!Nadpis, "") & vbCrLf & "    " & Nz(rs!Popis, "") & vbCrLf
        rs.MoveNext
    Loop
    rs.Close
    strCesta = Environ$("TEMP") & "\dochadzka-pomocnik.txt"
    f = FreeFile
    Open strCesta For Output As #f
    Print #f, s
    Close #f
    Shell "notepad.exe """ & strCesta & """", vbNormalFocus
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Pomocnik.PomocnikZobrazTextom", "ERROR", Err.Description)
End Sub

'===============================================================================
' OBSLUHA TLAČIDIEL OKNA
'===============================================================================

Public Function PomocnikZavriUI() As Boolean
    On Error Resume Next
    DoCmd.Close acForm, FRM_POM, acSaveNo
    If mod_00_Common.FormIsOpen(FRM_KON) Then Forms(FRM_KON).SetFocus
    PomocnikZavriUI = True
End Function

Public Function PomocnikNezobrazovatUI() As Boolean
    On Error Resume Next
    Dim strKluc As String, bSkryt As Boolean
    strKluc = CStr(mod_UI_Spolocne.TVGet("PH_Kluc", ""))
    If KartaCislo(strKluc) < 1 Then Exit Function
    bSkryt = CBool(Nz(Forms(FRM_POM).Controls("chkPhNezobrazovat").Value, False))
    Call NastavStav(strKluc, "Skryt", bSkryt)
    Call mod_00_Common.ZapisLog("mod_UI_Pomocnik.PomocnikNezobrazovatUI", "INFO", "Karta " & strKluc & ": Nezobrazovať = " & bSkryt)
    PomocnikNezobrazovatUI = True
End Function

'-------------------------------------------------------------------------------
' Kliknutie na text vedľa políčka Nezobrazovať prepne políčko. Stav sa zapíše do tabuľky ako prvý (nezávisle od
' políčka) a až potom sa premietne do políčka, takže voľba platí aj keby sa políčko nedalo prepísať.
'-------------------------------------------------------------------------------
Public Function PomocnikPrepniNezobrazovatUI() As Boolean
    On Error Resume Next
    Dim strKluc As String, bNovy As Boolean
    strKluc = CStr(mod_UI_Spolocne.TVGet("PH_Kluc", ""))
    If KartaCislo(strKluc) < 1 Then Exit Function
    bNovy = Not StavPole(strKluc, "Skryt")
    Call NastavStav(strKluc, "Skryt", bNovy)
    Forms(FRM_POM).Controls("chkPhNezobrazovat").Value = bNovy
    Call mod_00_Common.ZapisLog("mod_UI_Pomocnik.PomocnikPrepniNezobrazovatUI", "INFO", "Karta " & strKluc & ": Nezobrazovať = " & bNovy)
    PomocnikPrepniNezobrazovatUI = True
End Function

Private Sub PomocnikPosun(ByVal lSmer As Long)
    Dim lCis As Long
    On Error Resume Next
    lCis = KartaCislo(CStr(mod_UI_Spolocne.TVGet("PH_Kluc", "PROCES"))) + lSmer
    If lCis < 0 Then lCis = POCET_KARIET
    If lCis > POCET_KARIET Then lCis = 0
    Call PomocnikNacitaj(KartaKluc(lCis))
End Sub

Public Function PomocnikDalsiaUI() As Boolean
    Call PomocnikPosun(1)
    PomocnikDalsiaUI = True
End Function

Public Function PomocnikPredosleUI() As Boolean
    Call PomocnikPosun(-1)
    PomocnikPredosleUI = True
End Function

Public Function PomocnikProcesUI() As Boolean
    Call PomocnikNacitaj("PROCES")
    PomocnikProcesUI = True
End Function

'-------------------------------------------------------------------------------
' Kliknutie na kartu v prehľade postupu v hlavičke okna (1 - 9).
'-------------------------------------------------------------------------------
Public Function PomocnikSkocUI(ByVal lCislo As Long) As Boolean
    If lCislo >= 1 And lCislo <= POCET_KARIET Then Call PomocnikNacitaj(KartaKluc(lCislo))
    PomocnikSkocUI = True
End Function

'-------------------------------------------------------------------------------
' Zavrie okno a prepne konzolu na kartu, ktorej sa okno týka.
'-------------------------------------------------------------------------------
Public Function PomocnikNaKartuUI() As Boolean
    Dim strKluc As String
    On Error Resume Next
    strKluc = CStr(mod_UI_Spolocne.TVGet("PH_Kluc", ""))
    Call PomocnikZavriUI
    If KartaCislo(strKluc) >= 1 Then Call mod_UI_Core.UI_KartaPrepniKluc(strKluc)
    PomocnikNaKartuUI = True
End Function

'===============================================================================
' ADMINISTRÁCIA POMOCNÍKA (karta Audit & Admin)
'===============================================================================

'-------------------------------------------------------------------------------
' Znovu zapne všetky info okná (zruší Nezobrazovať a príznaky vykonanej činnosti).
'-------------------------------------------------------------------------------
Public Function PomocnikObnovVsetkoUI() As Boolean
    On Error GoTo Chyba
    Dim i As Long
    If mod_00_Common.TabulkaExistuje("PomocnikStav") Then CurrentDb.Execute "DELETE FROM PomocnikStav", dbFailOnError
    For i = 1 To POCET_KARIET
        Call mod_UI_Spolocne.TVSet("PH_Auto_" & KartaKluc(i), 0)
    Next i
    MsgBox "Info okná sa budú znovu zobrazovať pri otvorení kariet, na ktorých ešte nie sú údaje (napr. prázdna databáza na karte Import).", _
           vbInformation, "Pomocník"
    PomocnikObnovVsetkoUI = True
    Exit Function
Chyba:
    MsgBox "Nepodarilo sa obnoviť info okná: " & Err.Description, vbExclamation, "Pomocník"
End Function

'-------------------------------------------------------------------------------
' Obnoví predvolené texty Pomocníka (prepíše riadky, ktoré nemajú v tabuľke PomocnikTexty zaškrtnuté Upravene).
'-------------------------------------------------------------------------------
Public Function PomocnikObnovTextyUI() As Boolean
    On Error GoTo Chyba
    Call mod_00_Common.SetNastavenie("PomocnikVerzia", "0", "Verzia textov Pomocníka (info okná kariet)")
    Call ZabezpecPomocnik
    MsgBox "Predvolené texty Pomocníka boli obnovené.", vbInformation, "Pomocník"
    PomocnikObnovTextyUI = True
    Exit Function
Chyba:
    MsgBox "Nepodarilo sa obnoviť texty: " & Err.Description, vbExclamation, "Pomocník"
End Function

'===============================================================================
' GENEROVANIE FORMULÁRA frmPomocnik
'===============================================================================

Private Function NovyPopisok(ByVal strFrm As String, ByVal lSekcia As Long, ByVal strNazov As String, ByVal lX As Long, ByVal lY As Long, _
                             ByVal lW As Long, ByVal lH As Long, ByVal strCaption As String, ByVal lVelkost As Long, _
                             ByVal bTucne As Boolean, ByVal lFarba As Long) As Control
    Dim ctl As Control
    Set ctl = CreateControl(strFrm, acLabel, lSekcia, "", "", lX, lY, lW, lH)
    ctl.Name = strNazov
    ctl.Caption = strCaption
    ctl.FontName = mod_UI_Spolocne.UI_PISMO
    ctl.FontSize = lVelkost
    ctl.FontBold = bTucne
    ctl.ForeColor = lFarba
    Set NovyPopisok = ctl
End Function

Private Function NoveTlacidlo(ByVal strFrm As String, ByVal strNazov As String, ByVal lX As Long, ByVal lY As Long, ByVal lW As Long, _
                              ByVal strCaption As String, ByVal strAkcia As String) As Control
    Dim ctl As Control
    Set ctl = CreateControl(strFrm, acCommandButton, acFooter, "", "", lX, lY, lW, 380)
    ctl.Name = strNazov
    ctl.Caption = strCaption
    ctl.FontName = mod_UI_Spolocne.UI_PISMO
    ctl.FontSize = 10
    ctl.OnClick = strAkcia
    Set NoveTlacidlo = ctl
End Function

'-------------------------------------------------------------------------------
' Podmienené formátovanie štítku druhu (KROK, MOŽNOSŤ, TIP, POZOR ...) - farebné políčka v prvom stĺpci.
'-------------------------------------------------------------------------------
Private Sub PridajFarbyDruhov(ByVal ctl As Control)
    Dim fc As Object
    On Error Resume Next
    Set fc = ctl.FormatConditions.Add(acExpression, , "[Typ]='KROK'")
    fc.BackColor = RGB(15, 30, 90): fc.ForeColor = RGB(255, 255, 255)
    Set fc = ctl.FormatConditions.Add(acExpression, , "[Typ]='MOZNOST'")
    fc.BackColor = RGB(0, 105, 70): fc.ForeColor = RGB(255, 255, 255)
    Set fc = ctl.FormatConditions.Add(acExpression, , "[Typ]='TIP'")
    fc.BackColor = RGB(255, 232, 160): fc.ForeColor = RGB(95, 65, 0)
    Set fc = ctl.FormatConditions.Add(acExpression, , "[Typ]='POZOR'")
    fc.BackColor = RGB(185, 30, 30): fc.ForeColor = RGB(255, 255, 255)
    Set fc = ctl.FormatConditions.Add(acExpression, , "[Typ]='DALEJ'")
    fc.BackColor = RGB(85, 90, 115): fc.ForeColor = RGB(255, 255, 255)
End Sub

'-------------------------------------------------------------------------------
' Vygeneruje formulár frmPomocnik: spojitý formulár s riadkami Druh | Čo | Popis, hlavičkou a pätou.
' Vráti False, ak sa hlavička/päta formulára nedá zapnúť (vtedy sa obsah zobrazí ako text).
'-------------------------------------------------------------------------------
Public Function VytvorFormularPomocnika() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, strTmp As String, ctl As Control, i As Long, lX As Long, strDiag As String

    If mod_00_Common.FormIsOpen(FRM_POM) Then DoCmd.Close acForm, FRM_POM, acSaveNo
    On Error Resume Next
    DoCmd.DeleteObject acForm, FRM_POM
    Err.Clear
    On Error GoTo Chyba
    Call ZabezpecPomocnik

    Set frm = CreateForm
    strTmp = frm.Name
    With frm
        .RecordSource = "SELECT Typ, Stitok, Nadpis, Popis FROM PomocnikTexty WHERE Karta = 'PROCES' ORDER BY Poradie;"
        .Caption = "Pomocník"
        .DefaultView = 1
        .RecordSelectors = False
        .NavigationButtons = False
        .DividingLines = False
        .ScrollBars = 2
        .AllowAdditions = False
        .AllowDeletions = False
        ' AllowEdits ostáva Áno: v spojitom formulári by Nie zamklo aj políčko Nezobrazovať v päte (nedalo by sa zaškrtnúť).
        ' Texty sú len na čítanie, lebo ich textové polia majú Locked a podklad je snapshot (RecordsetType = 2).
        .AllowEdits = True
        .RecordsetType = 2
        .AutoCenter = True
        .PopUp = True
        .Modal = True
        .BorderStyle = 3
        .Width = 11700
        .Section(acDetail).Height = 1250
    End With
    On Error Resume Next
    frm.AutoResize = False
    frm.Section(acDetail).BackColor = RGB(255, 255, 255)
    frm.Section(acDetail).AlternateBackColor = RGB(243, 246, 252)
    Err.Clear
    On Error GoTo Chyba

    If Not mod_UI_Spolocne.ZapniHlavickuPaticku(frm, 1900, 1150) Then
        Call mod_00_Common.ZapisLog("VytvorFormularPomocnika", "WARN", "Hlavička/päta formulára sa nedá zapnúť - Pomocník sa zobrazí ako text.")
        DoCmd.Close acForm, strTmp, acSaveNo
        VytvorFormularPomocnika = False
        Exit Function
    End If
    On Error Resume Next
    frm.Section(acHeader).BackColor = RGB(15, 30, 90)
    frm.Section(acFooter).BackColor = RGB(236, 240, 250)
    Err.Clear
    On Error GoTo Chyba

    ' --- hlavička: nadpis, podtitul, prehľad postupu (karty 1 - 9), záhlavie stĺpcov ---
    Call NovyPopisok(strTmp, acHeader, "lblPhTitul", 300, 100, 10900, 520, "Pomocník", 18, True, RGB(255, 255, 255))
    Call NovyPopisok(strTmp, acHeader, "lblPhPodtitul", 300, 650, 10900, 340, "", 10, False, RGB(205, 220, 250))
    lX = 300
    For i = 1 To POCET_KARIET
        Set ctl = NovyPopisok(strTmp, acHeader, "lblPhK" & i, lX, 1080, 1190, 380, i & " " & KartaKratky(KartaKluc(i)), 8, True, RGB(215, 225, 250))
        ctl.BackStyle = 1
        ctl.BackColor = RGB(45, 70, 140)
        ctl.TextAlign = 2
        ctl.OnClick = "=PomocnikSkocUI(" & i & ")"
        ctl.ControlTipText = "Zobraziť Pomocníka pre kartu " & i & " - " & KartaNazov(KartaKluc(i))
        lX = lX + 1230
    Next i
    Set ctl = NovyPopisok(strTmp, acHeader, "lblPhH1", 300, 1560, 1300, 300, "Druh", 9, True, RGB(15, 30, 90))
    ctl.BackStyle = 1: ctl.BackColor = RGB(215, 222, 238)
    Set ctl = NovyPopisok(strTmp, acHeader, "lblPhH2", 1600, 1560, 2900, 300, "Čo", 9, True, RGB(15, 30, 90))
    ctl.BackStyle = 1: ctl.BackColor = RGB(215, 222, 238)
    Set ctl = NovyPopisok(strTmp, acHeader, "lblPhH3", 4500, 1560, 6800, 300, "Popis", 9, True, RGB(15, 30, 90))
    ctl.BackStyle = 1: ctl.BackColor = RGB(215, 222, 238)

    ' --- riadok tabuľky (spojitý formulár) ---
    Set ctl = CreateControl(strTmp, acTextBox, acDetail, "", "Stitok", 300, 0, 1300, 1250)
    ctl.Name = "txtPhStitok"
    ctl.TextAlign = 2
    ctl.FontBold = True
    ctl.FontSize = 10
    ctl.BackColor = RGB(230, 236, 250)
    ctl.ForeColor = RGB(15, 30, 90)
    Call PridajFarbyDruhov(ctl)
    Set ctl = CreateControl(strTmp, acTextBox, acDetail, "", "Nadpis", 1600, 0, 2900, 1250)
    ctl.Name = "txtPhNadpis"
    ctl.FontBold = True
    ctl.FontSize = 10
    ctl.ForeColor = RGB(15, 30, 90)
    Set ctl = CreateControl(strTmp, acTextBox, acDetail, "", "Popis", 4500, 0, 6800, 1250)
    ctl.Name = "txtPhPopis"
    ctl.FontSize = 10
    ctl.ForeColor = RGB(30, 30, 30)
    ctl.ScrollBars = 2
    On Error Resume Next
    For Each ctl In frm.Controls
        If ctl.ControlType = acTextBox Then
            ctl.Locked = True
            ctl.TabStop = False
            ctl.BorderStyle = 1
            ctl.BorderColor = RGB(200, 206, 220)
            ctl.SpecialEffect = 0
            If ctl.Name <> "txtPhStitok" Then ctl.BackStyle = 0
            ctl.TopMargin = 70
            ctl.LeftMargin = 90
            ctl.RightMargin = 70
        End If
    Next ctl
    Err.Clear
    On Error GoTo Chyba

    ' --- päta: Nezobrazovať, tlačidlá ---
    Set ctl = CreateControl(strTmp, acCheckBox, acFooter, "", "", 300, 150, 260, 260)
    ctl.Name = "chkPhNezobrazovat"
    ctl.AfterUpdate = "=PomocnikNezobrazovatUI()"
    Set ctl = NovyPopisok(strTmp, acFooter, "lblPhNezobrazovat", 640, 120, 8600, 320, _
        "Nezobrazovať pri otvorení karty (okno vyvoláte tlačidlom Pomocník alebo Alt+P)", 10, False, RGB(15, 30, 90))
    ctl.OnClick = "=PomocnikPrepniNezobrazovatUI()"
    Set ctl = NoveTlacidlo(strTmp, "btnPhZavriet", 9900, 100, 1400, "&Zavrieť", "=PomocnikZavriUI()")
    ctl.Default = True
    ctl.Cancel = True
    ctl.FontBold = True
    Call NoveTlacidlo(strTmp, "btnPhProces", 300, 620, 2300, "Prehľad postupu", "=PomocnikProcesUI()")
    Call NoveTlacidlo(strTmp, "btnPhPredosla", 6300, 620, 1500, "« Predošlá", "=PomocnikPredosleUI()")
    Call NoveTlacidlo(strTmp, "btnPhDalsia", 7900, 620, 1500, "Ďalšia »", "=PomocnikDalsiaUI()")
    Call NoveTlacidlo(strTmp, "btnPhNaKartu", 9500, 620, 1800, "Prejsť na kartu", "=PomocnikNaKartuUI()")

    strDiag = mod_UI_Spolocne.NormalizujFormular(frm)

    DoCmd.Save acForm, strTmp
    DoCmd.Close acForm, strTmp, acSaveYes
    DoCmd.Rename FRM_POM, acForm, strTmp
    Call mod_00_Common.SetNastavenie(KLUC_VERZIA_FORMULARA, VERZIA_FORMULARA, "Verzia okna Pomocníka (frmPomocnik)")
    Call mod_00_Common.ZapisLog("VytvorFormularPomocnika", "INFO", "Okno Pomocníka vytvorené. " & strDiag)
    VytvorFormularPomocnika = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Pomocnik.VytvorFormularPomocnika", "ERROR", Err.Description)
    On Error Resume Next
    If Len(strTmp) > 0 Then DoCmd.Close acForm, strTmp, acSaveNo
    VytvorFormularPomocnika = False
End Function
