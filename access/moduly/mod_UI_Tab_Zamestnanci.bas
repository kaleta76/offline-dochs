Attribute VB_Name = "mod_UI_Tab_Zamestnanci"
'@Verzia 1.1.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_UI_Tab_Zamestnanci
' POPIS: Karta 2 konzoly - ručná správa zamestnancov (podľa karty zamestnanca v Ordata):
'        zoznam zamestnancov s úväzkom, pracovným fondom a šablónou pravidiel prerušení platnými pre zvolený mesiac,
'        úprava karty zamestnanca, nový zamestnanec, vyradenie (zamestnanec sa potom nezobrazuje vo výpočtoch ani
'        v zostavách) a vrátenie do evidencie, hromadné priradenie fondu / pravidiel / úväzku vybraným
'        zamestnancom (aj ako nová skupina) a otvorenie editorov pracovných fondov a pravidiel prerušení.
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - IsAvailable() / GetTabCaption() / BuildUI(frm, page) / InitDefaults(frm) : Štandardné rozhranie karty.
' - Zam_PoOtvoreniKarty()          : Obnoví zoznam pri prepnutí na kartu.
' - Zam_ObnovUI()                  : Obnoví zoznam zamestnancov (mesiac, hľadanie, vyradení).
' - Zam_MesPredUI / Zam_MesDalsiUI : Posun mesiaca zobrazených nastavení.
' - Zam_VybraniOC(frm)             : Pole osobných čísel označených v zozname.
' - Zam_OtvorKartuUI()             : Karta označeného zamestnanca.
' - Zam_NovyUI()                   : Karta nového zamestnanca.
' - Zam_VyradUI() / Zam_VratUI()   : Vyradenie a vrátenie označených zamestnancov.
' - Zam_PriradUI()                 : Hromadné priradenie nastavení označeným zamestnancom.
' - Zam_FondyUI() / Zam_PravidlaUI(): Editory pracovných fondov a pravidiel prerušení.
'===============================================================================

Private Const FRM_KONZOLA As String = "frmHlavnaKonzola"

Public Function IsAvailable() As Boolean
    IsAvailable = True
End Function

Public Function GetTabCaption() As String
    GetTabCaption = "2. Zamestnanci"
End Function

Public Sub BuildUI(ByVal strFrmName As String, ByVal strPageName As String)
    On Error GoTo ChybaHandler
    Dim ctl As Control, btn As Control

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 1100, 9500, 300)
    ctl.Caption = "Zamestnanci - karta, úväzok, pracovný fond a pravidlá prerušení"
    ctl.FontBold = True: ctl.FontSize = 10: ctl.ForeColor = RGB(15, 30, 90)

    ' --- mesiac, hľadanie, vyradení ---
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 1500, 800, 300)
    ctl.Caption = "Mesiac:"
    ctl.FontBold = True
    Call mod_UI_Spolocne.VytvorVyberMesiaca(strFrmName, strPageName, "cboZamMesiac", 1350, 1470, 2300, "=Zam_ObnovUI()")
    ctl.ControlTipText = "Mesiac, pre ktorý sa v zozname ukazuje platný pracovný fond a šablóna prerušení"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 3750, 1470, 400, 330)
    btn.Name = "btnZamMesPred"
    btn.Caption = "<": btn.FontBold = True
    btn.ControlTipText = "Predchádzajúci mesiac"
    btn.OnClick = "=Zam_MesPredUI()"
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 4200, 1470, 400, 330)
    btn.Name = "btnZamMesDalsi"
    btn.Caption = ">": btn.FontBold = True
    btn.ControlTipText = "Nasledujúci mesiac"
    btn.OnClick = "=Zam_MesDalsiUI()"

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 4800, 1500, 900, 300)
    ctl.Caption = "Hľadať:"
    ctl.FontBold = True
    Set ctl = CreateControl(strFrmName, acTextBox, acDetail, strPageName, "", 5700, 1470, 2200, 330)
    ctl.Name = "txtZamHladaj"
    ctl.AfterUpdate = "=Zam_ObnovUI()"
    ctl.ControlTipText = "Časť osobného čísla, priezviska alebo mena; potvrďte klávesom Enter"

    Set ctl = CreateControl(strFrmName, acCheckBox, acDetail, strPageName, "", 8050, 1500, 260, 260)
    ctl.Name = "chkZamVyradeni"
    ctl.AfterUpdate = "=Zam_ObnovUI()"
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 8350, 1500, 1650, 300)
    ctl.Caption = "aj vyradení"

    ' --- zoznam ---
    Set ctl = CreateControl(strFrmName, acListBox, acDetail, strPageName, "", 500, 1950, 9500, 2650)
    ctl.Name = "lstZamestnanci"
    With ctl
        .MultiSelect = 2
        .ColumnCount = 6
        .ColumnHeads = True
        .ColumnWidths = "900;2400;700;2100;1900;1400"
        .BoundColumn = 1
        .RowSourceType = "Table/Query"
        .OnDblClick = "=Zam_OtvorKartuUI()"
        .ControlTipText = "Dvojklik otvorí kartu zamestnanca. Ctrl alebo Shift označí viacerých (hromadné priradenie, vyradenie)."
    End With

    ' --- tlačidlá ---
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 4700, 2300, 420)
    btn.Name = "btnZamKarta": btn.Caption = "Karta zamestnanca...": btn.FontBold = True
    btn.OnClick = "=Zam_OtvorKartuUI()"
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 2900, 4700, 2300, 420)
    btn.Name = "btnZamNovy": btn.Caption = "Nový zamestnanec..."
    btn.OnClick = "=Zam_NovyUI()"
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 5300, 4700, 2300, 420)
    btn.Name = "btnZamVyrad": btn.Caption = "Vyradiť označených..."
    btn.ControlTipText = "Vyradený zamestnanec sa nezobrazuje v zoznamoch výpočtu ani v zostavách"
    btn.OnClick = "=Zam_VyradUI()"
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 7700, 4700, 2300, 420)
    btn.Name = "btnZamVrat": btn.Caption = "Vrátiť do evidencie"
    btn.OnClick = "=Zam_VratUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 5250, 4800, 450)
    btn.Name = "btnZamPriradit": btn.Caption = "Priradiť fond, pravidlá a úväzok označeným...": btn.FontBold = True
    btn.ForeColor = RGB(0, 100, 0)
    btn.ControlTipText = "Aj pre skupinu: vlastný pracovný fond a vlastné pravidlá prerušení pre vybraných zamestnancov"
    btn.OnClick = "=Zam_PriradUI()"
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 5400, 5250, 2250, 450)
    btn.Name = "btnZamFondy": btn.Caption = "Pracovné fondy..."
    btn.OnClick = "=Zam_FondyUI()"
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 7750, 5250, 2250, 450)
    btn.Name = "btnZamPravidla": btn.Caption = "Pravidlá prerušení..."
    btn.OnClick = "=Zam_PravidlaUI()"

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 5850, 9500, 300)
    ctl.Name = "lblZamStav": ctl.Caption = "": ctl.ForeColor = RGB(100, 100, 100): ctl.FontSize = 8

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 6250, 9500, 1500)
    ctl.Caption = "Každý zamestnanec má vlastný úväzok (%) a vlastné priradenie pracovného fondu, šablóny pravidiel prerušení a kalendára, " & _
                  "platné od zvoleného mesiaca (staršie mesiace sa nemenia). Zamestnanec s polovičným úväzkom má úväzok 50 %. " & _
                  "Skupinu vytvoríte tak, že označíte viacerých zamestnancov, kliknete na Priradiť... a zvolíte vlastnú kópiu fondu a pravidiel. " & _
                  "Vyradený zamestnanec ostane v databáze a jeho staré razenia sa zachovajú, ale od mesiaca vyradenia sa nezobrazuje " & _
                  "v zoznamoch výpočtu ani v zostavách."
    ctl.ForeColor = RGB(80, 80, 80)

    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Zamestnanci.BuildUI", "ERROR", Err.Description)
End Sub

Public Sub InitDefaults(ByRef frm As Form)
    On Error Resume Next
    Call mod_UI_Spolocne.NastavVyberMesiaca(frm!cboZamMesiac, Year(Date), Month(Date))
    frm!txtZamHladaj = Null
    frm!chkZamVyradeni = False
    Call Zam_ObnovUI
End Sub

Public Sub Zam_PoOtvoreniKarty()
    On Error Resume Next
    Call Zam_ObnovUI
End Sub

'===============================================================================
' ZOZNAM
'===============================================================================

Public Function Zam_MesPredUI() As Boolean
    On Error Resume Next
    Call mod_UI_Spolocne.PosunVyberMesiaca(Forms(FRM_KONZOLA)!cboZamMesiac, -1)
    Zam_MesPredUI = Zam_ObnovUI()
End Function

Public Function Zam_MesDalsiUI() As Boolean
    On Error Resume Next
    Call mod_UI_Spolocne.PosunVyberMesiaca(Forms(FRM_KONZOLA)!cboZamMesiac, 1)
    Zam_MesDalsiUI = Zam_ObnovUI()
End Function

'-------------------------------------------------------------------------------
' Zvolený mesiac zoznamu (rok, mesiac); ak nie je vybraný, aktuálny.
'-------------------------------------------------------------------------------
Public Sub Zam_ZvolenyMesiac(ByRef lRok As Long, ByRef lMes As Long)
    On Error Resume Next
    lRok = Year(Date): lMes = Month(Date)
    If mod_00_Common.FormIsOpen(FRM_KONZOLA) Then
        If Not mod_UI_Spolocne.ObdobieZVyberu(Forms(FRM_KONZOLA)!cboZamMesiac, lRok, lMes) Then
            lRok = Year(Date): lMes = Month(Date)
        End If
    End If
End Sub

Public Function Zam_ObnovUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, lRok As Long, lMes As Long, strSql As String, strW As String, strHl As String, strPat As String
    Dim db As DAO.Database, n As Long, nVyr As Long
    Static bModelOk As Boolean

    If Not mod_00_Common.FormIsOpen(FRM_KONZOLA) Then Exit Function
    Set frm = Forms(FRM_KONZOLA)
    Set db = CurrentDb
    If Not bModelOk Then
        Call mod_15_Zamestnanci.ZabezpecModel(db)
        bModelOk = True
    End If
    If Not mod_00_Common.TabulkaExistujeDB(db, "Zamestnanci") Then
        frm!lblZamStav.Caption = "Tabuľka Zamestnanci ešte neexistuje."
        Exit Function
    End If

    Call Zam_ZvolenyMesiac(lRok, lMes)
    Call mod_15_Zamestnanci.Zam_NastavMesiac(CInt(lRok), CInt(lMes))

    strW = " WHERE Z.OsobneCislo Is Not Null"
    If Not CBool(Nz(frm!chkZamVyradeni.Value, False)) Then strW = strW & " AND " & mod_15_Zamestnanci.SqlAktivny("Z", DateSerial(lRok, lMes, 1))
    strHl = Trim$(CStr(Nz(frm!txtZamHladaj.Value, "")))
    If Len(strHl) > 0 Then
        strPat = mod_00_Common.SqlText("*" & strHl & "*")
        strW = strW & " AND (Z.OsobneCislo LIKE " & strPat & " OR Z.Priezvisko LIKE " & strPat & " OR Z.Meno LIKE " & strPat & " OR Z.CeleMeno LIKE " & strPat & ")"
    End If

    strSql = "SELECT Z.OsobneCislo, " & _
             "IIf(Len(Trim(Nz(Z.Priezvisko, '') & Nz(Z.Meno, ''))) = 0, Nz(Z.CeleMeno, ''), Trim(Nz(Z.Priezvisko, '') & ' ' & Nz(Z.Meno, ''))) AS Zamestnanec, " & _
             "Zam_UvazokText(Z.OsobneCislo) AS Uvazok, " & _
             "Zam_FondText(Z.OsobneCislo) AS PracFond, " & _
             "Zam_PrerText(Z.OsobneCislo) AS Sablona, " & _
             "IIf(Nz(Z.Vyradeny, False), 'vyradený od ' & Format(Z.VyradenyOd, 'd.m.yyyy'), 'aktívny') AS Stav " & _
             "FROM Zamestnanci AS Z" & strW & " ORDER BY Z.Priezvisko, Z.Meno, Z.OsobneCislo;"
    frm!lstZamestnanci.RowSource = strSql
    frm!lstZamestnanci.Requery

    n = frm!lstZamestnanci.ListCount
    If frm!lstZamestnanci.ColumnHeads Then n = n - 1
    If n < 0 Then n = 0
    nVyr = CLng(Nz(DCount("*", "Zamestnanci", "Nz(Vyradeny, False) = True"), 0))
    frm!lblZamStav.Caption = "V zozname: " & n & " zamestnancov; vyradených v databáze: " & nVyr & ". Fond a pravidlá sú zobrazené pre " & _
                             mod_UI_Spolocne.NazovMesiaca(CLng(lMes)) & " " & lRok & "."
    Zam_ObnovUI = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Zamestnanci.Zam_ObnovUI", "ERROR", Err.Description)
    On Error Resume Next
    Forms(FRM_KONZOLA)!lblZamStav.Caption = "Zoznam sa nepodarilo načítať: " & Err.Description
End Function

'-------------------------------------------------------------------------------
' Osobné čísla označené v zozname (pole reťazcov; prázdne pole, ak nie je nič označené).
'-------------------------------------------------------------------------------
Public Function Zam_VybraniOC(ByVal frm As Form) As Variant
    Dim v As Variant, lst As Access.ListBox, a() As String, n As Long
    On Error Resume Next
    Set lst = frm!lstZamestnanci
    If lst.ItemsSelected.Count = 0 Then Zam_VybraniOC = Array(): Exit Function
    ReDim a(0 To lst.ItemsSelected.Count - 1)
    For Each v In lst.ItemsSelected
        a(n) = CStr(lst.ItemData(v))
        n = n + 1
    Next v
    Zam_VybraniOC = a
End Function

Private Function OcDoSql(ByVal vOC As Variant) As String
    Dim v As Variant
    For Each v In vOC
        OcDoSql = OcDoSql & IIf(Len(OcDoSql) > 0, ",", "") & mod_00_Common.SqlText(CStr(v))
    Next v
End Function

'===============================================================================
' AKCIE
'===============================================================================

Public Function Zam_OtvorKartuUI() As Boolean
    On Error GoTo Chyba
    Dim a As Variant
    a = Zam_VybraniOC(Forms(FRM_KONZOLA))
    If UBound(a) < LBound(a) Then
        MsgBox "Označte v zozname zamestnanca, ktorého kartu chcete otvoriť.", vbInformation, "Zamestnanci"
        Exit Function
    End If
    Zam_OtvorKartuUI = mod_UI_ZamKarta.OtvorKartuZamestnanca(CStr(a(LBound(a))), False)
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Zamestnanci.Zam_OtvorKartuUI", "ERROR", Err.Description)
End Function

Public Function Zam_NovyUI() As Boolean
    On Error GoTo Chyba
    Zam_NovyUI = mod_UI_ZamKarta.OtvorKartuZamestnanca("", True)
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Zamestnanci.Zam_NovyUI", "ERROR", Err.Description)
End Function

Public Function Zam_VyradUI() As Boolean
    On Error GoTo Chyba
    Dim a As Variant, strVstup As String, dOd As Date, n As Long, dNavrh As Date
    a = Zam_VybraniOC(Forms(FRM_KONZOLA))
    If UBound(a) < LBound(a) Then
        MsgBox "Označte v zozname zamestnancov, ktorých chcete vyradiť.", vbInformation, "Zamestnanci"
        Exit Function
    End If
    dNavrh = DateSerial(Year(Date), Month(Date) + 1, 1)
    strVstup = InputBox("Označených zamestnancov: " & (UBound(a) - LBound(a) + 1) & vbCrLf & vbCrLf & _
                        "Zadajte deň, od ktorého sa vyradia (napr. 1.12.2026)." & vbCrLf & _
                        "Mesiace, ktoré začínajú v tento deň alebo neskôr, sa už vo výpočtoch a zostavách nezobrazia;" & vbCrLf & _
                        "staršie mesiace aj razenia ostanú.", "Vyradenie zamestnancov", Format$(dNavrh, "d.m.yyyy"))
    If Len(Trim$(strVstup)) = 0 Then Exit Function
    If Not IsDate(strVstup) Then
        MsgBox "Dátum sa nepodarilo rozpoznať. Zadajte ho v tvare 1.12.2026.", vbExclamation, "Vyradenie zamestnancov"
        Exit Function
    End If
    dOd = CDate(strVstup)
    n = mod_15_Zamestnanci.NastavVyradenie(OcDoSql(a), True, dOd)
    If n = -2 Then Exit Function
    If n < 0 Then
        MsgBox "Vyradenie sa nepodarilo (pozrite protokol).", vbExclamation, "Vyradenie zamestnancov"
        Exit Function
    End If
    Call mod_UI_Pomocnik.OznacCinnost("ZAMESTNANCI")
    MsgBox "Vyradených zamestnancov: " & n & " (od " & Format$(dOd, "d.m.yyyy") & ").", vbInformation, "Vyradenie zamestnancov"
    Zam_VyradUI = Zam_ObnovUI()
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Zamestnanci.Zam_VyradUI", "ERROR", Err.Description)
    MsgBox "Vyradenie sa nepodarilo: " & Err.Description, vbExclamation, "Zamestnanci"
End Function

Public Function Zam_VratUI() As Boolean
    On Error GoTo Chyba
    Dim a As Variant, n As Long
    a = Zam_VybraniOC(Forms(FRM_KONZOLA))
    If UBound(a) < LBound(a) Then
        MsgBox "Označte v zozname zamestnancov, ktorých chcete vrátiť do evidencie. Vyradených zobrazíte políčkom aj vyradení.", vbInformation, "Zamestnanci"
        Exit Function
    End If
    If MsgBox("Vrátiť do evidencie označených zamestnancov (" & (UBound(a) - LBound(a) + 1) & ")?", vbQuestion + vbYesNo, "Zamestnanci") <> vbYes Then Exit Function
    n = mod_15_Zamestnanci.NastavVyradenie(OcDoSql(a), False, Date)
    If n = -2 Then Exit Function
    If n < 0 Then
        MsgBox "Zmena sa nepodarila (pozrite protokol).", vbExclamation, "Zamestnanci"
        Exit Function
    End If
    Call mod_UI_Pomocnik.OznacCinnost("ZAMESTNANCI")
    Zam_VratUI = Zam_ObnovUI()
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Zamestnanci.Zam_VratUI", "ERROR", Err.Description)
End Function

Public Function Zam_PriradUI() As Boolean
    On Error GoTo Chyba
    Dim a As Variant
    a = Zam_VybraniOC(Forms(FRM_KONZOLA))
    If UBound(a) < LBound(a) Then
        MsgBox "Označte v zozname zamestnancov (Ctrl alebo Shift pre viacerých), ktorým chcete priradiť nastavenia.", vbInformation, "Zamestnanci"
        Exit Function
    End If
    Zam_PriradUI = mod_UI_ZamKarta.OtvorPriradenie(a)
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Zamestnanci.Zam_PriradUI", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Fond a šablóna označeného zamestnanca pre zvolený mesiac (0, 0, ak nič nie je označené).
'-------------------------------------------------------------------------------
Private Sub FondSablonaOznaceneho(ByRef lFond As Long, ByRef lSablona As Long, Optional ByRef strOC As String)
    Dim a As Variant, lRok As Long, lMes As Long, iOvRok As Integer, iOvMes As Integer, k As Long, y As Long
    On Error Resume Next
    lFond = 0: lSablona = 0: strOC = ""
    a = Zam_VybraniOC(Forms(FRM_KONZOLA))
    If UBound(a) < LBound(a) Then Exit Sub
    strOC = CStr(a(LBound(a)))
    Call Zam_ZvolenyMesiac(lRok, lMes)
    Call mod_15_Zamestnanci.PlatnePriradenie(strOC, CInt(lRok), CInt(lMes), iOvRok, iOvMes, lFond, lSablona, k, y)
End Sub

Public Function Zam_FondyUI() As Boolean
    On Error GoTo Chyba
    Dim lF As Long, lS As Long, lRok As Long, lMes As Long, strOC As String
    Call FondSablonaOznaceneho(lF, lS, strOC)
    Call Zam_ZvolenyMesiac(lRok, lMes)
    Zam_FondyUI = mod_UI_Sablony.OtvorEditorFondov(lF, CInt(lRok), CInt(lMes), strOC)
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Zamestnanci.Zam_FondyUI", "ERROR", Err.Description)
End Function

Public Function Zam_PravidlaUI() As Boolean
    On Error GoTo Chyba
    Dim lF As Long, lS As Long, lRok As Long, lMes As Long, strOC As String
    Call FondSablonaOznaceneho(lF, lS, strOC)
    Call Zam_ZvolenyMesiac(lRok, lMes)
    Zam_PravidlaUI = mod_UI_Sablony.OtvorEditorPravidiel(lS, CInt(lRok), CInt(lMes), strOC)
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Zamestnanci.Zam_PravidlaUI", "ERROR", Err.Description)
End Function
