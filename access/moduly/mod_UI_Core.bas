Attribute VB_Name = "mod_UI_Core"
'@Verzia 2.9.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_UI_Core
' POPIS: Orchestrátor používateľského rozhrania (UI). Generuje dynamickú konzolu (frmHlavnaKonzola)
'        so všetkými kartami v procesnom poradí.
'
'   ROZLOŽENIE KONZOLY:
'   - Pevná hlavička (nemení sa pri posúvaní): názov, tlačidlá Pomocník, Objekty a Menu a tlačidlá kariet
'     (Alt+1 ... Alt+9). Záložky tab-ovládača sú skryté (Style = None), prepína sa tlačidlami v hlavičke,
'     takže navigácia nezmizne ani pri posúvaní dlhej karty.
'   - Čísla kariet sú pevné: 1 Import, 2 Zamestnanci, 3 Kontrola, 4 Editor, 5 Prerušenia, 6 Výpočet, 7 Exporty, 8 Admin,
'     9 Active Directory (karta sa zobrazí len v doméne). Poradie kariet v konzole sa ukladá do nastavenia
'     UIKonzolaKarty; ak sa zmení dostupnosť karty (napr. AD), konzola sa vygeneruje znova.
'   - Stred (Detail) so zvislým aj vodorovným posuvníkom - karta, ktorá sa nevojde, sa dá posúvať.
'   - Pevná päta so stavovým riadkom (txtMainStatus).
'   - Ak sa hlavička/päta formulára nedá zapnúť, použije sa záložné rozloženie (viditeľné záložky, stav pod kartou).
'
'   MENU A OBJEKTY ACCESSU: pri štarte sa skryje pás kariet (tlačidlo Menu, Alt+M) aj navigačný panel s objektmi
'   databázy (tlačidlo Objekty, Alt+O). Nastavenie UIPriStarteSkryMenu (predvolene zapnuté; nevzťahuje sa na
'   vývojársky režim) sa uloží aj ako vlastnosť databázy StartupShowDBWindow, takže panel sa nezobrazí ani na začiatku.
'
'   Uložená konzola sa pri štarte znova použije (nastavenie UIKonzolaVerzia = VERZIA_UI); po inštalácii alebo
'   zmene verzie sa vygeneruje nanovo.
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - OtvorHlavnuKonzolu()           : Otvorí konzolu (uloženú alebo novú).
' - RekonstruujHlavnuKonzolu()     : Vygeneruje formulár frmHlavnaKonzola.
' - UI_KartaPrepni(idx)            : Prepne kartu podľa poradia v konzole (0 = prvá) a zvýrazní ju v hlavičke.
' - UI_KartaPrepniKluc(kluc)       : Prepne kartu podľa kľúča (IMPORT, ZAMESTNANCI, ..., AD).
' - UI_KartaZmenena()              : Obsluha zmeny karty (zvýraznenie, automatické info okno).
' - UI_AktivnaKarta()              : Kľúč aktívnej karty.
' - UI_IndexKarty(kluc)            : Poradie karty v konzole (0 = prvá) alebo -1, ak karta v konzole nie je.
' - UI_PomocnikUI()                : Otvorí info okno aktívnej karty.
' - UI_PrepniMenu() / UI_NastavMenu(zobraz) : Zobrazenie a skrytie pásu kariet.
' - UI_PrepniPanelObjektov() / UI_NastavPanelObjektov(zobraz) : Zobrazenie a skrytie navigačného panela s objektmi.
' - UI_ZobrazPasKariet()           : Zobrazí pás kariet (pre tlač zostáv).
' - UI_SkryMenuPriStarte()         : Skryje pás kariet aj panel objektov pri štarte (podľa nastavenia).
' - UI_PrepniSkryvanieMenuUI()     : Prepne nastavenie "skrývať menu pri štarte".
' - UI_ZneplatniKonzolu()          : Vynúti nové vygenerovanie konzoly pri najbližšom otvorení.
' - UI_ZnovuVytvorKonzoluUI()      : Znovu vytvorí konzolu (po potvrdení).
' - UI_DiagnostikaText()           : Stručná diagnostika rozloženia (pre protokol inštalátora).
'===============================================================================

Public Const VERZIA_UI As String = "2.9.0"

Private Const FRM_KONZOLA As String = "frmHlavnaKonzola"
Private Const TAB_KONZOLA As String = "tabMainKonzola"
Private Const KLUC_UI_VERZIA As String = "UIKonzolaVerzia"
Private Const KLUC_SKRYT_MENU As String = "UIPriStarteSkryMenu"
Private Const KLUC_KARTY As String = "UIKonzolaKarty"
Private Const POCET_KARIET As Long = 9
Private Const SIRKA_FORMULARA As Long = 12000
Private Const FAKTOR_SIRKY As Double = 1.1474      ' karty boli navrhnuté pre šírku 9500 (x 500 až 10000)
Private Const POSUN_Y As Long = 700                ' o koľko sa obsah kariet posunie nahor (záložky sú skryté)
Private Const VYSKA_HLAVICKY As Long = 1180
Private Const VYSKA_PATICKY As Long = 480
Private Const MEDZERA_NAV As Long = 45
Private Const NAV_OD As Long = 300
Private Const NAV_SIRKA_SPOLU As Long = 11400

Private mDiag As String

'===============================================================================
' OTVORENIE A GENEROVANIE KONZOLY
'===============================================================================

'-------------------------------------------------------------------------------
' Otvorí hlavnú konzolu: použije uloženú (ak je aktuálna) alebo spustí jej generovanie.
'-------------------------------------------------------------------------------
Public Function OtvorHlavnuKonzolu() As Boolean
    On Error GoTo ChybaHandler
    Dim frm As Form

    If mod_00_Common.FormIsOpen(FRM_KONZOLA) Then
        If Forms(FRM_KONZOLA).Tag = VERZIA_UI Then
            Forms(FRM_KONZOLA).Visible = True
            Forms(FRM_KONZOLA).SetFocus
            OtvorHlavnuKonzolu = True
            Exit Function
        End If
    ElseIf mod_00_Common.FormularExistujeDB(FRM_KONZOLA) Then
        If mod_00_Common.GetNastavenie(KLUC_UI_VERZIA, "") = VERZIA_UI And mod_00_Common.GetNastavenie(KLUC_KARTY, "") = ZoznamKarietText() Then
            On Error Resume Next
            DoCmd.OpenForm FRM_KONZOLA
            If Err.Number = 0 Then
                Set frm = Forms(FRM_KONZOLA)
                If frm.Tag = VERZIA_UI Then
                    mDiag = "použitá uložená konzola"
                    On Error GoTo ChybaHandler
                    Call NaplnPredvolbyKonzoly(frm)
                    OtvorHlavnuKonzolu = True
                    Exit Function
                End If
            End If
            Err.Clear
            On Error GoTo ChybaHandler
        End If
    End If

    Call RekonstruujHlavnuKonzolu
    OtvorHlavnuKonzolu = mod_00_Common.FormIsOpen(FRM_KONZOLA)
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("OtvorHlavnuKonzolu", "ERROR", Err.Description)
    OtvorHlavnuKonzolu = False
End Function

'-------------------------------------------------------------------------------
' Vynúti nové vygenerovanie konzoly pri najbližšom otvorení (volá inštalátor a administrácia).
'-------------------------------------------------------------------------------
Public Sub UI_ZneplatniKonzolu()
    On Error Resume Next
    Call mod_00_Common.SetNastavenie(KLUC_UI_VERZIA, "0", "Verzia uloženej hlavnej konzoly (formulár frmHlavnaKonzola)")
End Sub

'-------------------------------------------------------------------------------
' KARTY KONZOLY: kľúče v poradí zobrazenia a ich dostupnosť
'-------------------------------------------------------------------------------

Private Function KartaDostupna(ByVal strKluc As String) As Boolean
    On Error Resume Next
    Select Case strKluc
        Case "IMPORT": KartaDostupna = mod_UI_Tab_Import.IsAvailable()
        Case "ZAMESTNANCI": KartaDostupna = mod_UI_Tab_Zamestnanci.IsAvailable()
        Case "KONTROLA": KartaDostupna = mod_UI_Tab_Konsolidacia.IsAvailable()
        Case "EDITOR": KartaDostupna = mod_05_UI_AttendanceEditor.IsAvailable()
        Case "PRERUSENIA": KartaDostupna = mod_UI_Tab_Prerusenia.IsAvailable()
        Case "VYPOCET": KartaDostupna = mod_UI_Tab_Vypocet.IsAvailable()
        Case "EXPORT": KartaDostupna = mod_UI_Tab_Export.IsAvailable()
        Case "ADMIN": KartaDostupna = mod_UI_Tab_Admin.IsAvailable()
        Case "AD": KartaDostupna = mod_UI_Tab_ADSync.IsAvailable()
    End Select
    If Err.Number <> 0 Then KartaDostupna = False: Err.Clear
End Function

Private Function KartaCaption(ByVal strKluc As String) As String
    On Error Resume Next
    Select Case strKluc
        Case "IMPORT": KartaCaption = mod_UI_Tab_Import.GetTabCaption()
        Case "ZAMESTNANCI": KartaCaption = mod_UI_Tab_Zamestnanci.GetTabCaption()
        Case "KONTROLA": KartaCaption = mod_UI_Tab_Konsolidacia.GetTabCaption()
        Case "EDITOR": KartaCaption = mod_05_UI_AttendanceEditor.GetTabCaption()
        Case "PRERUSENIA": KartaCaption = mod_UI_Tab_Prerusenia.GetTabCaption()
        Case "VYPOCET": KartaCaption = mod_UI_Tab_Vypocet.GetTabCaption()
        Case "EXPORT": KartaCaption = mod_UI_Tab_Export.GetTabCaption()
        Case "ADMIN": KartaCaption = mod_UI_Tab_Admin.GetTabCaption()
        Case "AD": KartaCaption = mod_UI_Tab_ADSync.GetTabCaption()
    End Select
    If Len(KartaCaption) = 0 Then KartaCaption = mod_UI_Pomocnik.KartaCislo(strKluc) & ". " & mod_UI_Pomocnik.KartaKratky(strKluc)
End Function

'-------------------------------------------------------------------------------
' Kľúče dostupných kariet v poradí zobrazenia (podľa pevných čísel 1 až 9), oddelené čiarkou.
'-------------------------------------------------------------------------------
Private Function ZoznamKarietText() As String
    Dim i As Long, k As String, s As String
    For i = 1 To POCET_KARIET
        k = mod_UI_Pomocnik.KartaKluc(i)
        If KartaDostupna(k) Then s = s & IIf(Len(s) > 0, ",", "") & k
    Next i
    ZoznamKarietText = s
End Function

'-------------------------------------------------------------------------------
' Kľúč karty na danom mieste konzoly (0 = prvá); poradie sa berie z uloženého nastavenia (platí pre uloženú konzolu).
'-------------------------------------------------------------------------------
Private Function KlucNaIndexe(ByVal lIdx As Long) As String
    Dim a As Variant
    On Error Resume Next
    a = Split(mod_00_Common.GetNastavenie(KLUC_KARTY, ""), ",")
    If lIdx >= LBound(a) And lIdx <= UBound(a) Then KlucNaIndexe = CStr(a(lIdx))
    If Err.Number <> 0 Then KlucNaIndexe = "": Err.Clear
End Function

Private Function PocetKartiVKonzole() As Long
    Dim a As Variant
    On Error Resume Next
    a = Split(mod_00_Common.GetNastavenie(KLUC_KARTY, ""), ",")
    PocetKartiVKonzole = UBound(a) - LBound(a) + 1
    If Err.Number <> 0 Or PocetKartiVKonzole < 0 Then PocetKartiVKonzole = 0: Err.Clear
End Function

'-------------------------------------------------------------------------------
' Vytvorí v hlavičke (alebo pri zálohe v hornej časti) názov a tlačidlá Pomocník, Objekty a Menu.
'-------------------------------------------------------------------------------
Private Sub PostavHorneOvladace(ByVal strFrm As String, ByVal lSekcia As Long, ByVal lY As Long, ByVal bHlavicka As Boolean)
    Dim ctl As Control
    Set ctl = CreateControl(strFrm, acLabel, lSekcia, "", "", 300, lY, 7800, 460)
    ctl.Name = "lblHlavnyNadpis"
    ctl.Caption = "Správa a spracovanie dochádzky zamestnancov"
    ctl.FontName = mod_UI_Spolocne.UI_PISMO
    ctl.FontSize = 14
    ctl.FontBold = True
    If bHlavicka Then
        ctl.ForeColor = RGB(255, 255, 255)
        ctl.BackStyle = 0
    Else
        ctl.ForeColor = RGB(15, 30, 90)
    End If

    Set ctl = CreateControl(strFrm, acCommandButton, lSekcia, "", "", 8200, lY, 1400, 420)
    ctl.Name = "btnPomocnik"
    ctl.Caption = "&Pomocník"
    ctl.FontName = mod_UI_Spolocne.UI_PISMO
    ctl.FontSize = 10
    ctl.FontBold = True
    ctl.OnClick = "=UI_PomocnikUI()"
    ctl.ControlTipText = "Popis postupu a možností aktuálnej karty (Alt+P)"

    Set ctl = CreateControl(strFrm, acCommandButton, lSekcia, "", "", 9700, lY, 1000, 420)
    ctl.Name = "btnPanelObjektov"
    ctl.Caption = "&Objekty"
    ctl.FontName = mod_UI_Spolocne.UI_PISMO
    ctl.FontSize = 10
    ctl.OnClick = "=UI_PrepniPanelObjektov()"
    ctl.ControlTipText = "Zobraziť alebo skryť navigačný panel s objektmi databázy (Alt+O)"

    Set ctl = CreateControl(strFrm, acCommandButton, lSekcia, "", "", 10800, lY, 900, 420)
    ctl.Name = "btnMenuPrepni"
    ctl.Caption = "&Menu"
    ctl.FontName = mod_UI_Spolocne.UI_PISMO
    ctl.FontSize = 10
    ctl.OnClick = "=UI_PrepniMenu()"
    ctl.ControlTipText = "Zobraziť alebo skryť pás kariet Accessu (Alt+M)"
End Sub

'-------------------------------------------------------------------------------
' Tlačidlá kariet v hlavičke (podľa zoznamu strKarty) a ich zvýrazňovacie pásiky. Šírka tlačidiel sa delí rovnomerne.
'-------------------------------------------------------------------------------
Private Sub PostavNavigaciu(ByVal strFrm As String, ByVal strKarty As String)
    Dim ctl As Control, i As Long, lX As Long, lW As Long, aK As Variant, lN As Long, strK As String, lC As Long
    aK = Split(strKarty, ",")
    lN = UBound(aK) + 1
    If lN < 1 Then Exit Sub
    lW = (NAV_SIRKA_SPOLU - (lN - 1) * MEDZERA_NAV) \ lN
    For i = 0 To lN - 1
        strK = CStr(aK(i))
        lC = mod_UI_Pomocnik.KartaCislo(strK)
        lX = NAV_OD + i * (lW + MEDZERA_NAV)
        Set ctl = CreateControl(strFrm, acCommandButton, acHeader, "", "", lX, 640, lW, 440)
        ctl.Name = "btnNav" & i
        ctl.Caption = "&" & lC & " " & mod_UI_Pomocnik.KartaKratky(strK)
        ctl.FontName = mod_UI_Spolocne.UI_PISMO
        ctl.FontSize = IIf(lN > 8, 9, 10)
        ctl.FontBold = False
        ctl.OnClick = "=UI_KartaPrepni(" & i & ")"
        ctl.ControlTipText = "Karta " & lC & ": " & mod_UI_Pomocnik.KartaNazov(strK) & " (Alt+" & lC & ")"
        On Error Resume Next
        ctl.BackColor = RGB(45, 70, 140)
        ctl.ForeColor = RGB(225, 232, 250)
        ctl.HoverColor = RGB(70, 100, 180)
        ctl.HoverForeColor = RGB(255, 255, 255)
        Err.Clear
        On Error GoTo 0

        Set ctl = CreateControl(strFrm, acLabel, acHeader, "", "", lX, 1105, lW, 50)
        ctl.Name = "lblNavUl" & i
        ctl.Caption = ""
        ctl.BackStyle = 1
        ctl.BackColor = RGB(255, 190, 60)
        ctl.Visible = (i = 0)
    Next i
End Sub

'-------------------------------------------------------------------------------
' Pridá kartu do tab-ovládača: stránku, nadpis a kľúč karty (Tag).
'-------------------------------------------------------------------------------
Private Function NovaStrana(ByVal tabCtrl As Object, ByVal lIdx As Long, ByVal strCaption As String, ByVal strKluc As String) As Object
    Dim pg As Object
    If tabCtrl.Pages.Count <= lIdx Then tabCtrl.Pages.Add
    Set pg = tabCtrl.Pages(lIdx)
    pg.Caption = strCaption
    On Error Resume Next
    pg.Tag = strKluc
    On Error GoTo 0
    Set NovaStrana = pg
End Function

'-------------------------------------------------------------------------------
' Po zostavení karty: roztiahne obsah do šírky konzoly a (ak sú záložky skryté) posunie ho nahor.
' Vráti spodný okraj obsahu po posune.
'-------------------------------------------------------------------------------
Private Function DokonciStranu(ByVal pg As Object, ByVal bHlavicka As Boolean, ByVal dFaktor As Double) As Long
    Call mod_UI_Spolocne.RozsirStranu(pg, dFaktor, 500, IIf(bHlavicka, POSUN_Y, 0))
    DokonciStranu = mod_UI_Spolocne.DnoStrany(pg)
End Function

'-------------------------------------------------------------------------------
' Vytvorí jednu kartu (stránku a jej obsah). Vráti True, ak vznikla; lDno = najnižší okraj obsahu kariet.
'-------------------------------------------------------------------------------
Private Function PostavKartu(ByVal strFrm As String, ByVal tabCtrl As Object, ByVal lIdx As Long, ByVal strKluc As String, _
                             ByVal bH As Boolean, ByRef lDno As Long) As Boolean
    On Error GoTo Chyba
    Dim pg As Object, dF As Double, lD As Long
    dF = FAKTOR_SIRKY
    Set pg = NovaStrana(tabCtrl, lIdx, KartaCaption(strKluc), strKluc)
    Select Case strKluc
        Case "IMPORT": Call mod_UI_Tab_Import.BuildUI(strFrm, pg.Name)
        Case "ZAMESTNANCI": Call mod_UI_Tab_Zamestnanci.BuildUI(strFrm, pg.Name)
        Case "KONTROLA": Call mod_UI_Tab_Konsolidacia.BuildUI(strFrm, pg.Name)
        Case "EDITOR"
            Call mod_05_UI_AttendanceEditor.BuildUI(strFrm, pg.Name)
            dF = 1                                  ' karta editora je už navrhnutá na celú šírku konzoly
        Case "PRERUSENIA": Call mod_UI_Tab_Prerusenia.BuildUI(strFrm, pg.Name)
        Case "VYPOCET": Call mod_UI_Tab_Vypocet.BuildUI(strFrm, pg.Name)
        Case "EXPORT": Call mod_UI_Tab_Export.BuildUI(strFrm, pg.Name)
        Case "ADMIN": Call mod_UI_Tab_Admin.BuildUI(strFrm, pg.Name)
        Case "AD": Call mod_UI_Tab_ADSync.BuildUI(strFrm, pg.Name)
    End Select
    lD = DokonciStranu(pg, bH, dF)
    If lD > lDno Then lDno = lD
    PostavKartu = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Core.PostavKartu", "ERROR", "Karta " & strKluc & ": " & Err.Description)
End Function

'-------------------------------------------------------------------------------
' Programovo generuje kompletný formulár frmHlavnaKonzola so všetkými kartami.
'-------------------------------------------------------------------------------
Public Sub RekonstruujHlavnuKonzolu()
    On Error GoTo ChybaHandler
    Dim frm As Form, strTmp As String
    Dim tabCtrl As Object, ctl As Control, strKarty As String, aKarty As Variant, v As Variant
    Dim bH As Boolean, lIdx As Long, lDno As Long, lTabTop As Long, lTabH As Long

    mDiag = ""
    strKarty = ZoznamKarietText()
    On Error Resume Next
    If mod_00_Common.FormIsOpen(FRM_KONZOLA) Then DoCmd.Close acForm, FRM_KONZOLA, acSaveNo
    DoCmd.DeleteObject acForm, FRM_KONZOLA
    Err.Clear
    On Error GoTo ChybaHandler

    Set frm = CreateForm
    strTmp = frm.Name

    With frm
        .Caption = "Centrálna konzola dochádzkového systému (v" & VERZIA_UI & ")"
        .Tag = VERZIA_UI
        .RecordSelectors = False
        .NavigationButtons = False
        .DividingLines = False
        .ScrollBars = 3
        .AutoCenter = True
        .Width = SIRKA_FORMULARA
        .Section(acDetail).Height = 10800
    End With

    ' --- pevná hlavička a päta (ak ich Access v návrhu pustí) ---
    bH = mod_UI_Spolocne.ZapniHlavickuPaticku(frm, VYSKA_HLAVICKY, VYSKA_PATICKY)
    If bH Then
        mDiag = "hlavička: áno"
        On Error Resume Next
        frm.Section(acHeader).BackColor = RGB(15, 30, 90)
        frm.Section(acFooter).BackColor = RGB(236, 240, 250)
        Err.Clear
        On Error GoTo ChybaHandler
        Call PostavHorneOvladace(strTmp, acHeader, 100, True)
        Call PostavNavigaciu(strTmp, strKarty)
        lTabTop = 100
    Else
        mDiag = "hlavička: NIE (záložné rozloženie)"
        Call PostavHorneOvladace(strTmp, acDetail, 200, False)
        lTabTop = 800
    End If

    ' --- tab-ovládač s kartami ---
    Set tabCtrl = CreateControl(strTmp, acTabCtl, acDetail, "", "", 300, lTabTop, 11400, 9500)
    tabCtrl.Name = TAB_KONZOLA
    tabCtrl.OnChange = "=UI_KartaZmenena()"
    On Error Resume Next
    tabCtrl.Style = IIf(bH, 2, 0)
    Err.Clear
    On Error GoTo ChybaHandler

    ' --- karty v poradí 1 až 9 (Import, Zamestnanci, Kontrola, Editor, Prerušenia, Výpočet, Exporty, Admin, AD) ---
    lIdx = 0
    aKarty = Split(strKarty, ",")
    For Each v In aKarty
        If Len(CStr(v)) > 0 Then
            If PostavKartu(strTmp, tabCtrl, lIdx, CStr(v), bH, lDno) Then lIdx = lIdx + 1
        End If
    Next v

    ' --- výška tab-ovládača podľa najdlhšej karty a stavový riadok ---
    If bH Then
        lTabH = lDno + 250 - lTabTop
        tabCtrl.Height = lTabH
        frm.Section(acDetail).Height = lTabTop + lTabH + 120
        Set ctl = CreateControl(strTmp, acTextBox, acFooter, "", "", 300, 70, 11400, 340)
    Else
        lTabH = 9500
        frm.Section(acDetail).Height = lTabTop + lTabH + 700
        Set ctl = CreateControl(strTmp, acTextBox, acDetail, "", "", 300, lTabTop + lTabH + 100, 11400, 400)
    End If
    ctl.Name = "txtMainStatus"
    ctl.Locked = True
    ctl.TabStop = False
    ctl.FontName = mod_UI_Spolocne.UI_PISMO
    ctl.FontSize = 9
    ctl.ForeColor = RGB(15, 30, 90)
    ctl.BackColor = RGB(255, 255, 255)
    ctl.BorderColor = RGB(180, 190, 215)
    mDiag = mDiag & "; kariet: " & lIdx & " (" & strKarty & "); výška obsahu: " & lDno

    mDiag = mDiag & "; " & mod_UI_Spolocne.NormalizujFormular(frm)

    DoCmd.Save acForm, strTmp
    DoCmd.Close acForm, strTmp, acSaveYes
    DoCmd.Rename FRM_KONZOLA, acForm, strTmp
    Call mod_00_Common.SetNastavenie(KLUC_UI_VERZIA, VERZIA_UI, "Verzia uloženej hlavnej konzoly (formulár frmHlavnaKonzola)")
    Call mod_00_Common.SetNastavenie(KLUC_KARTY, strKarty, "Karty uloženej konzoly v poradí zobrazenia (kľúče oddelené čiarkou)")

    DoCmd.OpenForm FRM_KONZOLA
    Call NaplnPredvolbyKonzoly(Forms(FRM_KONZOLA))

    Call mod_00_Common.ZapisLog("RekonstruujHlavnuKonzolu", "INFO", "Konzola bola vygenerovaná (v" & VERZIA_UI & "). " & mDiag)
    Exit Sub
ChybaHandler:
    On Error Resume Next
    If Len(strTmp) > 0 Then DoCmd.Close acForm, strTmp, acSaveNo
    Call mod_00_Common.ZapisLog("RekonstruujHlavnuKonzolu", "ERROR", Err.Description)
    MsgBox "Chyba pri vytváraní konzoly: " & Err.Description, vbCritical
End Sub

'-------------------------------------------------------------------------------
' Po otvorení konzoly: predvolené hodnoty polí každej karty (podľa kariet uložených v konzole)
' a zvýraznenie prvej karty.
'-------------------------------------------------------------------------------
Private Sub NaplnPredvolbyKonzoly(ByVal frm As Form)
    Dim i As Long, n As Long
    On Error Resume Next
    n = PocetKartiVKonzole()
    For i = 0 To n - 1
        Select Case KlucNaIndexe(i)
            Case "IMPORT": Call mod_UI_Tab_Import.InitDefaults(frm)
            Case "ZAMESTNANCI": Call mod_UI_Tab_Zamestnanci.InitDefaults(frm)
            Case "KONTROLA": Call mod_UI_Tab_Konsolidacia.InitDefaults(frm)
            Case "EDITOR": Call mod_05_UI_AttendanceEditor.InitDefaults(frm)
            Case "PRERUSENIA": Call mod_UI_Tab_Prerusenia.InitDefaults(frm)
            Case "VYPOCET": Call mod_UI_Tab_Vypocet.InitDefaults(frm)
            Case "EXPORT": Call mod_UI_Tab_Export.InitDefaults(frm)
            Case "ADMIN": Call mod_UI_Tab_Admin.InitDefaults(frm)
            Case "AD": Call mod_UI_Tab_ADSync.InitDefaults(frm)
        End Select
        Err.Clear
    Next i
    frm.Controls(TAB_KONZOLA).Value = 0
    Call ObnovNavigaciu(frm, 0)
End Sub

'===============================================================================
' NAVIGÁCIA MEDZI KARTAMI
'===============================================================================

'-------------------------------------------------------------------------------
' Zvýrazní tlačidlo aktívnej karty v hlavičke.
'-------------------------------------------------------------------------------
Private Sub ObnovNavigaciu(ByVal frm As Form, ByVal lIdx As Long)
    Dim i As Long, btn As Control, ul As Control
    On Error Resume Next
    For i = 0 To POCET_KARIET - 1
        Set btn = Nothing
        Set ul = Nothing
        Set btn = frm.Controls("btnNav" & i)
        Set ul = frm.Controls("lblNavUl" & i)
        If Not btn Is Nothing Then
            If i = lIdx Then
                btn.BackColor = RGB(255, 255, 255)
                btn.ForeColor = RGB(15, 30, 90)
                btn.FontBold = True
            Else
                btn.BackColor = RGB(45, 70, 140)
                btn.ForeColor = RGB(225, 232, 250)
                btn.FontBold = False
            End If
        End If
        If Not ul Is Nothing Then ul.Visible = (i = lIdx)
        Err.Clear
    Next i
End Sub

'-------------------------------------------------------------------------------
' Prepne na kartu s poradím lIdx (0 = prvá karta konzoly; tlačidlá v hlavičke).
' Klávesy Alt+1 až Alt+9 patria tlačidlám s pevnými číslami kariet.
'-------------------------------------------------------------------------------
Public Function UI_KartaPrepni(ByVal lIdx As Long) As Boolean
    On Error Resume Next
    Dim frm As Form, n As Long
    If Not mod_00_Common.FormIsOpen(FRM_KONZOLA) Then Exit Function
    Set frm = Forms(FRM_KONZOLA)
    n = PocetKartiVKonzole()
    If n < 1 Then n = frm.Controls(TAB_KONZOLA).Pages.Count
    If lIdx < 0 Then lIdx = 0
    If lIdx > n - 1 Then lIdx = n - 1
    frm.Controls(TAB_KONZOLA).Value = lIdx
    Call UI_KartaZmenena
    UI_KartaPrepni = True
End Function

Public Function UI_KartaPrepniKluc(ByVal strKluc As String) As Boolean
    Dim l As Long
    l = UI_IndexKarty(strKluc)
    If l >= 0 Then UI_KartaPrepniKluc = UI_KartaPrepni(l)
End Function

'-------------------------------------------------------------------------------
' Obsluha zmeny karty: zvýraznenie v hlavičke, obnova údajov karty a automatické info okno.
'-------------------------------------------------------------------------------
Public Function UI_KartaZmenena() As Boolean
    On Error Resume Next
    Dim frm As Form, lIdx As Long, strKluc As String
    If Not mod_00_Common.FormIsOpen(FRM_KONZOLA) Then Exit Function
    Set frm = Forms(FRM_KONZOLA)
    lIdx = CLng(Nz(frm.Controls(TAB_KONZOLA).Value, 0))
    strKluc = KlucNaIndexe(lIdx)
    Call ObnovNavigaciu(frm, lIdx)
    frm.Controls(TAB_KONZOLA).SetFocus
    If strKluc = "ZAMESTNANCI" Then Call mod_UI_Tab_Zamestnanci.Zam_PoOtvoreniKarty
    If Len(strKluc) > 0 Then Call mod_UI_Pomocnik.PomocnikAutoZobraz(strKluc)
    UI_KartaZmenena = True
End Function

'-------------------------------------------------------------------------------
' Kľúč aktívnej karty (IMPORT, ZAMESTNANCI, KONTROLA, EDITOR, PRERUSENIA, VYPOCET, EXPORT, ADMIN, AD).
' Ak konzola nie je otvorená, vráti prvú kartu.
'-------------------------------------------------------------------------------
Public Function UI_AktivnaKarta() As String
    On Error Resume Next
    Dim lIdx As Long
    lIdx = 0
    If mod_00_Common.FormIsOpen(FRM_KONZOLA) Then lIdx = CLng(Nz(Forms(FRM_KONZOLA).Controls(TAB_KONZOLA).Value, 0))
    UI_AktivnaKarta = KlucNaIndexe(lIdx)
    If Len(UI_AktivnaKarta) = 0 Then UI_AktivnaKarta = "IMPORT"
End Function

'-------------------------------------------------------------------------------
' Poradie karty v konzole (0 = prvá) alebo -1, ak karta v konzole nie je (napr. AD mimo domény).
'-------------------------------------------------------------------------------
Public Function UI_IndexKarty(ByVal strKluc As String) As Long
    Dim i As Long, n As Long
    UI_IndexKarty = -1
    n = PocetKartiVKonzole()
    For i = 0 To n - 1
        If KlucNaIndexe(i) = UCase$(strKluc) Then UI_IndexKarty = i: Exit Function
    Next i
End Function

'-------------------------------------------------------------------------------
' Otvorí info okno (Pomocníka) pre aktívnu kartu - tlačidlo Pomocník, Alt+P.
'-------------------------------------------------------------------------------
Public Function UI_PomocnikUI() As Boolean
    On Error Resume Next
    Call mod_UI_Pomocnik.PomocnikZobraz(UI_AktivnaKarta(), False)
    UI_PomocnikUI = True
End Function

'===============================================================================
' MENU A OBJEKTY ACCESSU (pás kariet, navigačný panel)
'===============================================================================

'-------------------------------------------------------------------------------
' Zobrazí alebo skryje pás kariet (tlačidlo Menu, Alt+M).
'-------------------------------------------------------------------------------
Public Function UI_NastavMenu(ByVal bZobraz As Boolean) As Boolean
    On Error Resume Next
    DoCmd.ShowToolbar "Ribbon", IIf(bZobraz, acToolbarYes, acToolbarNo)
    Err.Clear
    Call VratFokusKonzole
    Call mod_UI_Spolocne.TVSet("MenuZobrazene", IIf(bZobraz, 1, 0))
    UI_NastavMenu = True
End Function

Public Function UI_PrepniMenu() As Boolean
    UI_PrepniMenu = UI_NastavMenu(CLng(mod_UI_Spolocne.TVGet("MenuZobrazene", 1)) <> 1)
End Function

Private Sub VratFokusKonzole()
    On Error Resume Next
    If mod_00_Common.FormIsOpen(FRM_KONZOLA) Then
        Forms(FRM_KONZOLA).Visible = True        ' záchrana, ak by príkaz skrytia zasiahol okno konzoly
        Forms(FRM_KONZOLA).SetFocus
    End If
    Err.Clear
End Sub

'-------------------------------------------------------------------------------
' Zobrazí alebo skryje navigačný panel s objektmi databázy (tlačidlo Objekty, Alt+O).
'-------------------------------------------------------------------------------
Public Function UI_NastavPanelObjektov(ByVal bZobraz As Boolean) As Boolean
    On Error Resume Next
    If bZobraz Then
        DoCmd.SelectObject acTable, , True
    Else
        Err.Clear
        DoCmd.NavigateTo "acNavigationCategoryObjectType"
        If Err.Number <> 0 Then
            Err.Clear
            DoCmd.SelectObject acTable, , True
        End If
        DoCmd.RunCommand acCmdWindowHide
    End If
    Err.Clear
    Call VratFokusKonzole
    Call mod_UI_Spolocne.TVSet("PanelObjektovZobrazeny", IIf(bZobraz, 1, 0))
    UI_NastavPanelObjektov = True
End Function

Public Function UI_PrepniPanelObjektov() As Boolean
    UI_PrepniPanelObjektov = UI_NastavPanelObjektov(CLng(mod_UI_Spolocne.TVGet("PanelObjektovZobrazeny", 1)) <> 1)
End Function

'-------------------------------------------------------------------------------
' Nastaví vlastnosť databázy (vytvorí ju, ak ešte neexistuje). Vráti True, ak sa to podarilo.
'-------------------------------------------------------------------------------
Private Function NastavVlastnostDB(ByVal strNazov As String, ByVal lTyp As Long, ByVal vHodnota As Variant) As Boolean
    Dim db As DAO.Database, prp As DAO.Property
    On Error Resume Next
    Set db = CurrentDb
    db.Properties(strNazov).Value = vHodnota
    If Err.Number = 0 Then NastavVlastnostDB = True: Exit Function
    Err.Clear
    Set prp = db.CreateProperty(strNazov, lTyp, vHodnota)
    db.Properties.Append prp
    NastavVlastnostDB = (Err.Number = 0)
    Err.Clear
End Function

'-------------------------------------------------------------------------------
' Zobrazí pás kariet (napr. pred zobrazením zostavy, kde je tlač a zatvorenie náhľadu v páse kariet).
'-------------------------------------------------------------------------------
Public Sub UI_ZobrazPasKariet()
    On Error Resume Next
    DoCmd.ShowToolbar "Ribbon", acToolbarYes
End Sub

'-------------------------------------------------------------------------------
' Po štarte skryje pás kariet a navigačný panel (ak to nastavenie dovoľuje) a zapíše do databázy, aby sa panel
' nezobrazil ani pri ďalšom otvorení. Preskočí sa v vývojárskom režime a pri skúšobnom štarte inštalátora.
'-------------------------------------------------------------------------------
Public Sub UI_SkryMenuPriStarte()
    On Error Resume Next
    If CLng(mod_UI_Spolocne.TVGet("DochTest", 0)) = 1 Then Exit Sub
    If mod_00_Common.GetNastavenie("DevMode", "0") = "1" Then Exit Sub
    If mod_00_Common.GetNastavenie(KLUC_SKRYT_MENU, "1") <> "1" Then Exit Sub
    Call NastavVlastnostDB("StartupShowDBWindow", dbBoolean, False)
    Call UI_NastavMenu(False)
    Call UI_NastavPanelObjektov(False)
End Sub

'-------------------------------------------------------------------------------
' Prepne nastavenie "skrývať menu pri štarte" (karta Audit a Admin).
'-------------------------------------------------------------------------------
Public Function UI_PrepniSkryvanieMenuUI() As Boolean
    On Error Resume Next
    Dim bTeraz As Boolean
    bTeraz = (mod_00_Common.GetNastavenie(KLUC_SKRYT_MENU, "1") = "1")
    Call mod_00_Common.SetNastavenie(KLUC_SKRYT_MENU, IIf(bTeraz, "0", "1"), "Skryť pás kariet a navigačný panel Accessu pri štarte (1 = áno, 0 = nie)")
    Call NastavVlastnostDB("StartupShowDBWindow", dbBoolean, bTeraz)
    If bTeraz Then
        MsgBox "Pás kariet a panel objektov sa pri štarte už nebudú skrývať." & vbCrLf & _
               "Zobrazíte ich hneď tlačidlami Menu (Alt+M) a Objekty (Alt+O) v hlavičke.", vbInformation, "Menu pri štarte"
    Else
        MsgBox "Pri ďalšom štarte sa skryje pás kariet aj panel objektov." & vbCrLf & _
               "Kedykoľvek ich zobrazíte tlačidlami Menu (Alt+M) a Objekty (Alt+O).", vbInformation, "Menu pri štarte"
    End If
    Call mod_UI_Tab_Admin.ObnovPopisMenu
    UI_PrepniSkryvanieMenuUI = True
End Function

'-------------------------------------------------------------------------------
' Znovu vytvorí konzolu (po potvrdení) - použite, ak sa niektoré okno zobrazuje chybne.
'-------------------------------------------------------------------------------
Public Function UI_ZnovuVytvorKonzoluUI() As Boolean
    On Error GoTo Chyba
    If MsgBox("Konzola sa znovu vygeneruje a okno sa na chvíľu zavrie. Pokračovať?", vbQuestion + vbYesNo, "Konzola") <> vbYes Then Exit Function
    Call UI_ZneplatniKonzolu
    Call RekonstruujHlavnuKonzolu
    UI_ZnovuVytvorKonzoluUI = True
    Exit Function
Chyba:
    MsgBox "Konzolu sa nepodarilo vytvoriť: " & Err.Description, vbExclamation, "Konzola"
End Function

'-------------------------------------------------------------------------------
' Stručná diagnostika rozloženia konzoly (do protokolu inštalátora).
'-------------------------------------------------------------------------------
Public Function UI_DiagnostikaText() As String
    Dim s As String
    On Error Resume Next
    s = "UI " & VERZIA_UI & ": " & IIf(mod_00_Common.FormIsOpen(FRM_KONZOLA), "konzola otvorená", "konzola zatvorená")
    s = s & "; karty: " & mod_00_Common.GetNastavenie(KLUC_KARTY, "?")
    s = s & "; pás kariet " & IIf(CLng(mod_UI_Spolocne.TVGet("MenuZobrazene", 1)) = 1, "zobrazený", "skrytý")
    s = s & "; panel objektov " & IIf(CLng(mod_UI_Spolocne.TVGet("PanelObjektovZobrazeny", 1)) = 1, "zobrazený", "skrytý")
    If Len(mDiag) > 0 Then s = s & "; " & mDiag
    UI_DiagnostikaText = s
End Function
