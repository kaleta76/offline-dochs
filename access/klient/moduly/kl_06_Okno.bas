Attribute VB_Name = "kl_06_Okno"
'@Verzia 1.0.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: kl_06_Okno
' POPIS: Okno klienta frmKlient. Formulár vytvára zostavovač raz (VytvorFormular, volá ho kl_07_Spustenie.PripravKlienta), udalosti
'        sú výrazy "=Funkcia()" na verejné funkcie štandardných modulov (bez triedy formulára, takže nie je čo rozbiť pri importe).
'        Okno ukazuje: identitu (osobné číslo a účet, nikdy meno), stav dňa, čas, tlačidlá Príchod a Odchod, až 12 tlačidiel
'        prerušení (popisky podľa konfigurácie), zoznam "Dnes" z lokálneho záznamu, počet čakajúcich razení a upozornenia.
'
'        Správanie tlačidla (KlientTlacidlo): zablokuje tlačidlá, kl_05_Razenie.ZapisRazenie zapíše razenie do lokálnej fronty,
'        okno sa prekreslí (stav "Zapísané hh:mm (odosielam...)") a až potom kl_05_Razenie.DorucRazenie urobí jeden pokus o server.
'        Tlačidlá sa po 5 sekundách odblokujú krátkym tikom časovača.
'        Časovač (KlientTik, 60 s): odošle čakajúce razenia s odlozene=1, každý 10. tik obnoví konfiguráciu, prekreslí okno.
'
'        Čisté funkcie (texty pre okno) overuje kl_08_Samotest.
' ZOZNAM VEREJNÝCH PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - VytvorFormular()                 : Vytvorí a uloží formulár frmKlient; vráti "" alebo text chyby.
' - OtvorOkno()                      : Otvorí okno a naplní ho (identita, konfigurácia, stav).
' - ObnovOkno(), ObnovKonfiguraciuOkna(), ObnovIdentituOkna(), PokazSpravu(sprava) : Prekreslenie častí okna.
' - KlientTlacidlo(akcia)            : Udalosť tlačidiel (PRICHOD, ODCHOD, P0 až P11).
' - KlientTik()                      : Udalosť časovača okna.
' - KlientKoniec(), KlientZatvorene() : Udalosť tlačidla Koniec a zatvorenia okna (ukončia klienta).
' - TextTlacidlaPreOkno(s), RiadokDnes(cas, nazov, odoslane), TextCakajucich(pocet, serverNedostupny),
'   TextUpozornenia(problemPrava, dniCakania), PomocnyTextOdchodu(odchod), DruhSpravy(sprava), RiadokIdentity(oc, login, zdroj),
'   NazovPrichodu(vPreruseni), TextPriKonci(pocet) : ČISTÉ texty pre okno.
'===============================================================================

Public Const FRM_KLIENT As String = "frmKlient"
Public Const MAX_PRERUSENI As Long = 12
Private Const PERIODA_TIKU_MS As Long = 60000
Private Const KONFIG_KAZDYCH_TIKOV As Long = 10
Private Const SIRKA_FORMULARA As Long = 9000
Private Const PISMO As String = "Segoe UI"

Private mKratkyTik As Boolean       ' najbližší tik časovača len odblokuje tlačidlá
Private mTikov As Long
Private mAktivne As Boolean         ' okno bolo otvorené cez OtvorOkno (zatvorenie pri zostavovaní klienta nesmie ukončiť Access)
Private mKoncim As Boolean          ' ukončenie ide cez tlačidlo Koniec
Private mVRazeni As Boolean        ' práve prebieha razenie z tlačidla: časovač nesmie odoslať práve zapísané razenie ako odložené

'===============================================================================
' Čisté funkcie: texty
'===============================================================================
' Znak & v texte tlačidla by sa zobrazil ako podčiarknutie nasledujúceho písmena (klávesová skratka).
Public Function TextTlacidlaPreOkno(ByVal strText As String) As String
    TextTlacidlaPreOkno = Replace(strText, "&", "&&")
End Function

Public Function RiadokDnes(ByVal strCas As String, ByVal strNazov As String, ByVal bOdoslane As Boolean) As String
    RiadokDnes = strCas & "   " & strNazov & Space$(IIf(Len(strNazov) < 30, 30 - Len(strNazov), 1)) & IIf(bOdoslane, "odoslané", "čaká na odoslanie")
End Function

Public Function TextCakajucich(ByVal lPocet As Long, ByVal bServerNedostupny As Boolean) As String
    TextCakajucich = "Čaká na odoslanie: " & lPocet & IIf(lPocet > 0 And bServerNedostupny, " (server nedostupný)", "")
End Function

' Upozornenie nad pätkou: "" = nič. Problém s právami má prednosť; čakanie od 2 dní je len upozornenie (HR prijíma razenia
' odložené najviac KlientMaxOdlozenieDni dní, predvolene 3).
Public Function TextUpozornenia(ByVal bProblemPrava As Boolean, ByVal lDniCakania As Long) As String
    If bProblemPrava Then
        TextUpozornenia = "Problém s právami na odoslanie, obráťte sa na HR."
    ElseIf lDniCakania >= 2 Then
        TextUpozornenia = "Razenie čaká už " & lDniCakania & IIf(lDniCakania <= 4, " dni", " dní") & ", HR ho nemusí prijať."
    End If
End Function

Public Function PomocnyTextOdchodu(ByVal strOdchod As String) As String
    If StrComp(strOdchod, "ODCHOD", vbBinaryCompare) = 0 Then
        PomocnyTextOdchodu = "Odchod počas dňa sa berie ako odchod z práce"
    Else
        PomocnyTextOdchodu = "Odchod počas dňa sa berie ako obed"
    End If
End Function

' Druh správy pre farbu: OK (zapísané a odoslané), CAKA (zapísané, ešte neodoslané), CHYBA (nič sa nezapísalo), "" (prázdna).
Public Function DruhSpravy(ByVal strSprava As String) As String
    If Len(strSprava) = 0 Then Exit Function
    If Left$(strSprava, 19) = "Zapísané a odoslané" Then
        DruhSpravy = "OK"
    ElseIf Left$(strSprava, 8) = "Zapísané" Then
        DruhSpravy = "CAKA"
    Else
        DruhSpravy = "CHYBA"
    End If
End Function

Public Function RiadokIdentity(ByVal strOc As String, ByVal strLogin As String, ByVal strZdroj As String) As String
    If Len(strOc) = 0 Then
        RiadokIdentity = "Osobné číslo: nezistené"
        Exit Function
    End If
    RiadokIdentity = "Osobné číslo " & strOc & " · účet " & strLogin
    If strZdroj = "CACHE" Then RiadokIdentity = RiadokIdentity & " · z vyrovnávacej pamäte, Active Directory je nedostupné"
End Function

' Upozornenie pri ukončení klienta s neprázdnou frontou ("" = nič).
Public Function TextPriKonci(ByVal lPocet As Long) As String
    If lPocet <= 0 Then Exit Function
    If lPocet = 1 Then
        TextPriKonci = "1 razenie čaká na odoslanie, odošle sa pri ďalšom spustení."
    ElseIf lPocet <= 4 Then
        TextPriKonci = lPocet & " razenia čakajú na odoslanie, odošlú sa pri ďalšom spustení."
    Else
        TextPriKonci = lPocet & " razení čaká na odoslanie, odošlú sa pri ďalšom spustení."
    End If
End Function

Public Function NazovPrichodu(ByVal bVPreruseni As Boolean) As String
    NazovPrichodu = IIf(bVPreruseni, "Návrat do práce", "Príchod")
End Function

'===============================================================================
' Vytvorenie formulára (raz, pri zostavení klienta)
'===============================================================================
Private Function NovaPopiska(ByVal strFrm As String, ByVal strMeno As String, ByVal strText As String, ByVal x As Long, ByVal y As Long, _
                             ByVal w As Long, ByVal h As Long, ByVal lVelkost As Long, ByVal bTucne As Boolean, ByVal lFarba As Long) As Control
    Dim ctl As Control
    Set ctl = CreateControl(strFrm, acLabel, acDetail, "", "", x, y, w, h)
    ctl.Name = strMeno
    ctl.Caption = strText
    ctl.FontName = PISMO
    ctl.FontSize = lVelkost
    ctl.FontBold = bTucne
    ctl.ForeColor = lFarba
    ctl.BackStyle = 0
    Set NovaPopiska = ctl
End Function

Private Function NoveTlacidlo(ByVal strFrm As String, ByVal strMeno As String, ByVal strText As String, ByVal x As Long, ByVal y As Long, _
                              ByVal w As Long, ByVal h As Long, ByVal lVelkost As Long, ByVal strUdalost As String) As Control
    Dim ctl As Control
    Set ctl = CreateControl(strFrm, acCommandButton, acDetail, "", "", x, y, w, h)
    ctl.Name = strMeno
    ctl.Caption = strText
    ctl.FontName = PISMO
    ctl.FontSize = lVelkost
    ctl.FontBold = True
    ctl.OnClick = strUdalost
    Set NoveTlacidlo = ctl
End Function

Public Function VytvorFormular() As String
    Dim frm As Form, strTmp As String, ctl As Control, i As Long, x As Long, y As Long, lKopia As Long, v As Variant, colDel As Collection

    On Error Resume Next
    DoCmd.Close acForm, FRM_KLIENT, acSaveNo
    DoCmd.DeleteObject acForm, FRM_KLIENT
    Err.Clear
    On Error GoTo Chyba

    Set frm = CreateForm
    strTmp = frm.Name
    With frm
        .Caption = "Dochádzka – razenie"
        .RecordSelectors = False
        .NavigationButtons = False
        .DividingLines = False
        .ScrollBars = 0
        .AutoCenter = True
        .PopUp = True
        .Modal = False
        .BorderStyle = 3
        .Width = SIRKA_FORMULARA
        .Section(acDetail).Height = 8900
        .Section(acDetail).BackColor = RGB(246, 248, 252)
        .TimerInterval = PERIODA_TIKU_MS
        .OnTimer = "=KlientTik()"
        .OnClose = "=KlientZatvorene()"
    End With
    On Error Resume Next
    frm.CloseButton = False          ' ukončenie len tlačidlom Koniec (zámok a upozornenie na čakajúce razenia)
    frm.MinMaxButtons = 0
    Err.Clear
    On Error GoTo Chyba

    Call NovaPopiska(strTmp, "lblNadpis", "Dochádzka – razenie", 300, 120, 6000, 460, 18, True, RGB(15, 30, 90))
    Call NovaPopiska(strTmp, "lblVerzia", "klient v" & kl_00_Spolocne.VERZIA_KLIENTA, 6600, 220, 2100, 300, 9, False, RGB(110, 120, 140)).TextAlign = 3

    Set ctl = NovaPopiska(strTmp, "lblTest", "TESTOVACÍ REŽIM", 300, 650, 8400, 330, 11, True, RGB(255, 255, 255))
    ctl.BackStyle = 1
    ctl.BackColor = RGB(230, 126, 34)
    ctl.TextAlign = 2
    ctl.Visible = False

    Call NovaPopiska(strTmp, "lblIdentita", "", 300, 1030, 8400, 320, 10, False, RGB(60, 70, 95))
    Call NovaPopiska(strTmp, "lblStav", "", 300, 1420, 8400, 600, 20, True, RGB(15, 30, 90))
    Call NovaPopiska(strTmp, "lblSprava", "", 300, 2080, 6800, 330, 11, True, RGB(15, 30, 90))
    Call NovaPopiska(strTmp, "lblCas", "", 7300, 2080, 1400, 330, 11, False, RGB(60, 70, 95)).TextAlign = 3

    Call NoveTlacidlo(strTmp, "btnPrichod", "Príchod", 300, 2500, 4100, 900, 20, "=KlientTlacidlo(""PRICHOD"")")
    Call NoveTlacidlo(strTmp, "btnOdchod", "Odchod", 4600, 2500, 4100, 900, 20, "=KlientTlacidlo(""ODCHOD"")")
    Call NovaPopiska(strTmp, "lblOdchodPomoc", "", 4600, 3430, 4100, 280, 9, False, RGB(110, 120, 140))

    For i = 0 To MAX_PRERUSENI - 1
        x = 300 + (i Mod 3) * 2850
        y = 3800 + (i \ 3) * 560
        Set ctl = NoveTlacidlo(strTmp, "btnPrer" & i, "Prerušenie " & (i + 1), x, y, 2700, 480, 12, "=KlientTlacidlo(""P" & i & """)")
        ctl.Visible = False
    Next i

    Call NovaPopiska(strTmp, "lblDnesNadpis", "Dnes", 300, 6130, 3000, 280, 10, True, RGB(60, 70, 95))
    Set ctl = CreateControl(strTmp, acTextBox, acDetail, "", "", 300, 6420, 8400, 1450)
    ctl.Name = "txtDnes"
    ctl.Locked = True
    ctl.TabStop = False
    ctl.EnterKeyBehavior = True
    ctl.ScrollBars = 2
    ctl.FontName = "Courier New"
    ctl.FontSize = 10
    ctl.ForeColor = RGB(15, 30, 90)
    ctl.BackColor = RGB(255, 255, 255)
    ctl.BorderColor = RGB(180, 190, 215)

    Set ctl = NovaPopiska(strTmp, "lblUpozornenie", "", 300, 7950, 8400, 330, 10, True, RGB(255, 255, 255))
    ctl.BackStyle = 1
    ctl.Visible = False
    Call NovaPopiska(strTmp, "lblCakaju", "", 300, 8330, 6600, 300, 10, True, RGB(15, 30, 90))
    Call NovaPopiska(strTmp, "lblKonfig", "", 300, 8610, 6600, 260, 8, False, RGB(110, 120, 140))
    Call NoveTlacidlo(strTmp, "btnKoniec", "Koniec", 7200, 8360, 1500, 450, 11, "=KlientKoniec()")

    ' pripojené popisky textových polí nepotrebujeme (rovnako ako v konzole HR)
    Set colDel = New Collection
    For Each ctl In frm.Controls
        If ctl.ControlType = acTextBox Then
            If ctl.Controls.Count > 0 Then colDel.Add ctl.Controls(0).Name
        End If
    Next ctl
    On Error Resume Next
    For Each v In colDel
        DeleteControl strTmp, CStr(v)
        Err.Clear
    Next v
    On Error GoTo Chyba

    DoCmd.Save acForm, strTmp
    DoCmd.Close acForm, strTmp, acSaveYes
    DoCmd.Rename FRM_KLIENT, acForm, strTmp
    VytvorFormular = ""
    Exit Function
Chyba:
    VytvorFormular = "Formulár " & FRM_KLIENT & " sa nepodarilo vytvoriť (chyba " & Err.Number & ": " & Err.Description & ")."
    On Error Resume Next
    If Len(strTmp) > 0 Then DoCmd.Close acForm, strTmp, acSaveNo
End Function

'===============================================================================
' Okno za behu
'===============================================================================
Private Function JeOtvorene() As Boolean
    On Error Resume Next
    JeOtvorene = ((SysCmd(acSysCmdGetObjectState, acForm, FRM_KLIENT) And acObjStateOpen) <> 0)
    If Err.Number <> 0 Then JeOtvorene = False: Err.Clear
End Function

' Povolí alebo zablokuje tlačidlá razenia. Pri vypnutom razení ostanú zablokované vždy. Tlačidlo Koniec sa nikdy nevypína.
Private Sub NastavTlacidla(ByVal bPovolit As Boolean)
    Dim frm As Form, i As Long
    On Error Resume Next
    If Not JeOtvorene() Then Exit Sub
    Set frm = Forms(FRM_KLIENT)
    frm.Controls("btnKoniec").SetFocus          ' zablokovať sa nedá ovládač, ktorý má fokus
    bPovolit = bPovolit And kl_05_Razenie.RazenieZapnute()
    frm.Controls("btnPrichod").Enabled = bPovolit
    frm.Controls("btnOdchod").Enabled = bPovolit
    For i = 0 To MAX_PRERUSENI - 1
        frm.Controls("btnPrer" & i).Enabled = bPovolit
    Next i
    Err.Clear
End Sub

' Zablokuje tlačidlá do konca ochrany pred dvojklikom a nastaví krátky tik časovača, ktorý ich odblokuje.
Private Sub PlanujOdblokovanie()
    Dim lMs As Long
    On Error Resume Next
    lMs = CLng((kl_05_Razenie.BlokovaneDo() - Now) * 86400# * 1000#) + 300
    If lMs < 500 Then
        Call NastavTlacidla(True)
        Exit Sub
    End If
    If lMs > 7000 Then lMs = 7000
    Call NastavTlacidla(False)
    mKratkyTik = True
    Forms(FRM_KLIENT).TimerInterval = lMs
    Err.Clear
End Sub

Public Sub PokazSpravu(ByVal strSprava As String)
    Dim ctl As Control, lFarba As Long
    On Error Resume Next
    If Not JeOtvorene() Then Exit Sub
    Select Case DruhSpravy(strSprava)
        Case "OK"
            lFarba = RGB(20, 120, 50)
        Case "CAKA"
            lFarba = RGB(190, 100, 0)
        Case "CHYBA"
            lFarba = RGB(190, 30, 30)
        Case Else
            lFarba = RGB(15, 30, 90)
    End Select
    Set ctl = Forms(FRM_KLIENT).Controls("lblSprava")
    ctl.Caption = strSprava
    ctl.ForeColor = lFarba
    Err.Clear
End Sub

Public Sub ObnovIdentituOkna()
    Dim frm As Form
    On Error Resume Next
    If Not JeOtvorene() Then Exit Sub
    Set frm = Forms(FRM_KLIENT)
    frm.Controls("lblIdentita").Caption = RiadokIdentity(kl_05_Razenie.OsobneCislo(), kl_05_Razenie.Ucet(), kl_05_Razenie.ZdrojIdentity())
    frm.Controls("lblTest").Visible = (kl_05_Razenie.ZdrojIdentity() = kl_01_Identita.ZDROJ_TEST)
    Err.Clear
End Sub

Public Sub ObnovKonfiguraciuOkna()
    Dim frm As Form, i As Long, n As Long, ctl As Control
    On Error Resume Next
    If Not JeOtvorene() Then Exit Sub
    Set frm = Forms(FRM_KLIENT)
    n = kl_04_Konfig.PocetTlacidiel()
    For i = 0 To MAX_PRERUSENI - 1
        Set ctl = frm.Controls("btnPrer" & i)
        If i < n Then
            ctl.Caption = TextTlacidlaPreOkno(kl_04_Konfig.TextTlacidla(i))
            ctl.Visible = True
        Else
            ctl.Visible = False
        End If
    Next i
    frm.Controls("lblOdchodPomoc").Caption = PomocnyTextOdchodu(kl_04_Konfig.OdchodBezDovodu())
    frm.Controls("lblKonfig").Caption = kl_04_Konfig.PopisZdrojaKonfigu()
    Err.Clear
End Sub

' Prekreslí stav dňa, čas, zoznam "Dnes", počet čakajúcich a upozornenia. Neprepisuje správu o poslednom razení.
Public Sub ObnovOkno()
    Dim frm As Form, r() As TRazenie, bOdosl() As Boolean, n As Long, i As Long, s As String, lPocet As Long, strUpoz As String, bProblem As Boolean
    Dim ctl As Control
    On Error GoTo Chyba
    If Not JeOtvorene() Then Exit Sub
    Set frm = Forms(FRM_KLIENT)
    frm.Controls("lblStav").Caption = kl_05_Razenie.StavDnaTeraz()
    frm.Controls("lblCas").Caption = Format$(Now, "hh:nn")
    frm.Controls("btnPrichod").Caption = NazovPrichodu(kl_05_Razenie.JeVPreruseni())

    n = kl_03_Fronta.RazeniaDna(Date, r, bOdosl)
    For i = 0 To n - 1
        s = s & IIf(i > 0, vbCrLf, "") & RiadokDnes(Format$(r(i).Cas, "hh:nn"), kl_05_Razenie.NazovRazenia(r(i).Kod, r(i).Smer, kl_04_Konfig.NazovKodu(r(i).Kod)), bOdosl(i))
    Next i
    frm.Controls("txtDnes").Value = s

    lPocet = kl_03_Fronta.PocetVoFronte()
    bProblem = kl_03_Fronta.ProblemSOdoslanim()
    Set ctl = frm.Controls("lblCakaju")
    ctl.Caption = TextCakajucich(lPocet, kl_03_Fronta.ServerNedostupny())
    ctl.ForeColor = IIf(bProblem, RGB(190, 30, 30), IIf(lPocet > 0, RGB(190, 100, 0), RGB(15, 30, 90)))

    strUpoz = TextUpozornenia(bProblem, kl_03_Fronta.NajstarsieCakanieDni(Now))
    Set ctl = frm.Controls("lblUpozornenie")
    ctl.Visible = (Len(strUpoz) > 0)
    ctl.Caption = strUpoz
    If bProblem Then
        ctl.BackColor = RGB(190, 30, 30)
        ctl.ForeColor = RGB(255, 255, 255)
    Else
        ctl.BackColor = RGB(250, 215, 90)
        ctl.ForeColor = RGB(60, 40, 0)
    End If
    Exit Sub
Chyba:
    Call kl_00_Spolocne.ZapisLog("ERROR", "Prekreslenie okna skončilo chybou " & Err.Number & ": " & Err.Description)
End Sub

' Otvorí okno a naplní ho. Vráti False, ak sa okno nepodarilo otvoriť.
Public Function OtvorOkno() As Boolean
    On Error GoTo Chyba
    mKratkyTik = False
    mTikov = 0
    mKoncim = False
    mVRazeni = False
    DoCmd.OpenForm FRM_KLIENT
    mAktivne = True
    Call ObnovKonfiguraciuOkna
    Call ObnovIdentituOkna
    Call ObnovOkno
    If Not kl_05_Razenie.RazenieZapnute() Then Call PokazSpravu(kl_05_Razenie.DovodVypnutia())
    Call NastavTlacidla(True)
    OtvorOkno = True
    Exit Function
Chyba:
    Call kl_00_Spolocne.ZapisLog("ERROR", "Okno " & FRM_KLIENT & " sa nepodarilo otvoriť (chyba " & Err.Number & ": " & Err.Description & ").")
    MsgBox "Okno klienta sa nepodarilo otvoriť (chyba " & Err.Number & "). Obráťte sa na IT.", vbCritical, "Dochádzka"
    OtvorOkno = False
End Function

'===============================================================================
' Udalosti (výrazy =Funkcia() na vlastnostiach ovládačov)
'===============================================================================
' Tlačidlá: PRICHOD (WORK/IN), ODCHOD (WORK/OUT), P0 až P11 (prerušenie z konfigurácie: KOD/OUT).
Public Function KlientTlacidlo(ByVal strAkcia As String) As Boolean
    Dim strKod As String, strSmer As String, strNazov As String, strSprava As String, lIdx As Long

    On Error GoTo Chyba
    Select Case strAkcia
        Case "PRICHOD"
            strKod = "WORK"
            strSmer = "IN"
        Case "ODCHOD"
            strKod = "WORK"
            strSmer = "OUT"
        Case Else
            If Left$(strAkcia, 1) <> "P" Or Not IsNumeric(Mid$(strAkcia, 2)) Then Exit Function
            lIdx = CLng(Mid$(strAkcia, 2))
            strKod = kl_04_Konfig.KodTlacidla(lIdx)
            If Len(strKod) = 0 Then Exit Function
            strSmer = "OUT"
    End Select

    If mVRazeni Then Exit Function
    mVRazeni = True
    Call NastavTlacidla(False)
    If kl_05_Razenie.ZapisRazenie(strKod, strSmer, strNazov, strSprava) Then
        Call PokazSpravu(strSprava)
        Call ObnovOkno
        DoEvents
        Call PokazSpravu(kl_05_Razenie.DorucRazenie(strNazov))
        Call ObnovOkno
    ElseIf Len(strSprava) > 0 Then
        Call PokazSpravu(strSprava)
    End If
    mVRazeni = False
    Call PlanujOdblokovanie
    KlientTlacidlo = True
    Exit Function
Chyba:
    mVRazeni = False
    Call kl_00_Spolocne.ZapisLog("ERROR", "Tlačidlo " & strAkcia & " skončilo chybou " & Err.Number & ": " & Err.Description)
    Call PokazSpravu("Razenie sa nepodarilo spracovať (chyba " & Err.Number & "). Skontrolujte zoznam Dnes.")
    Call PlanujOdblokovanie
End Function

' Časovač okna. Krátky tik (po razení) len odblokuje tlačidlá; riadny tik (60 s) odošle čakajúce razenia, každý 10. obnoví
' konfiguráciu a prekreslí okno (aj pri prechode cez polnoc).
Public Function KlientTik() As Boolean
    Dim frm As Form
    On Error GoTo Chyba
    If Not JeOtvorene() Then Exit Function
    If mVRazeni Then Exit Function
    Set frm = Forms(FRM_KLIENT)
    If mKratkyTik Then
        mKratkyTik = False
        frm.TimerInterval = PERIODA_TIKU_MS
        Call PlanujOdblokovanie
        Call ObnovOkno
        KlientTik = True
        Exit Function
    End If
    mTikov = mTikov + 1
    If Len(kl_03_Fronta.CestaPrijmu()) > 0 Then Call kl_03_Fronta.OdosliCakajuce(True)
    If mTikov Mod KONFIG_KAZDYCH_TIKOV = 0 Then
        Call kl_04_Konfig.NacitajKonfig
        Call ObnovKonfiguraciuOkna
    End If
    Call ObnovOkno
    KlientTik = True
    Exit Function
Chyba:
    Call kl_00_Spolocne.ZapisLog("ERROR", "Časovač okna skončil chybou " & Err.Number & ": " & Err.Description)
End Function

' Tlačidlo Koniec: posledný pokus o odoslanie, upozornenie na čakajúce razenia, ukončenie klienta (uvoľní zámok inštancie).
Public Function KlientKoniec() As Boolean
    Dim lPocet As Long
    On Error Resume Next
    mKoncim = True
    If Len(kl_03_Fronta.CestaPrijmu()) > 0 Then Call kl_03_Fronta.OdosliCakajuce(True)
    lPocet = kl_03_Fronta.PocetVoFronte()
    If lPocet > 0 Then MsgBox TextPriKonci(lPocet), vbInformation, "Dochádzka"
    Err.Clear
    Call kl_07_Spustenie.Ukonci
    KlientKoniec = True
End Function

' Zatvorenie okna inak než tlačidlom Koniec (napr. Ctrl+F4) ukončí klienta, aby neostal bežať bez okna so zámkom inštancie.
Public Function KlientZatvorene() As Boolean
    If Not mAktivne Or mKoncim Then Exit Function
    mAktivne = False
    Call kl_00_Spolocne.ZapisLog("WARN", "Okno bolo zatvorené inak než tlačidlom Koniec, klient sa ukončuje.")
    Call kl_07_Spustenie.Ukonci
    KlientZatvorene = True
End Function
