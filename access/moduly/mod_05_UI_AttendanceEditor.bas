Attribute VB_Name = "mod_05_UI_AttendanceEditor"
'@Verzia 2.7.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_05_UI_AttendanceEditor   (verzia 2.0)
' POPIS: Editor dochadzky (Ordata) - rucna oprava razeni a preruseni pred tlacou.
'
'   Zalozka "Editor Dochadzky (Ordata)":
'     - vyber zamestnanca (len s razeniami v mesiaci), roku a mesiaca,
'     - lavy panel: Mes.fond, Spolu, Sviatky, Uzn.nad., NV, Stav, Stav pr.den
'       a rozpis preruseni (PaM) za mesiac,
'     - tabulka dni (Den, Typ, Razeni, Vypoc., Uzn.nad., NV, Nadcas, Stav DF,
'       Spolu, Pozn.). Dvojklik na den / tlacidlo "Upravit den" otvori okno
'       "Prehlad preruseni cez den".
'
'   Okno dna (frmEditaciaDnaAdmin) - ako povodna aplikacia:
'     Ins-Pridaj, Enter-Oprava, Del-Zrus, Medzera-Stav platnosti,
'     Povodny den, Koniec. Vsetky zmeny prepocitaju mesiac (motor
'     modMesaatnaDochadzka) a zapisu sa do DochadzkaAudit.
'
'   Ulozenie ruchnych uprav:
'     - razenia ostavaju v DochadzkaImport (RucneUpravene, ZdrojZapisu,
'       UzivatelZmeny, DatumZmeny),
'     - DochadzkaUpraveneDni  = register upravenych dni,
'     - DochadzkaImportPovodne = snimka povodnych razeni dna (pre "Povodny den"),
'     - DochadzkaAudit        = kto, kedy a co zmenil.
'   Tabulky sa vytvoria automaticky pri prvej uprave.
'
' ZOZNAM VEREJNYCH PROCEDUR A FUNKCII:
' ------------------------------------------------------------------------------
' - IsAvailable(), GetTabCaption(), BuildUI(), InitDefaults()  : rozhranie pre mod_UI_Core
' - NacitajAObnovOrdataView()   : prepocet mesiaca + obnova zalozky
' - OtvorDetailDnaZGridu()      : otvori okno vybraneho dna
' - VytvorFrmEditaciaDnaAdmin() : (znovu)vygeneruje okno dna
' - VytvorSubformOrdataDni()    : zrusi zastaraly podformular subOrdataDni
' - VytvorKompletneUIEditacie() : vygeneruje okno dna a vycisti stare objekty
' - Ed_*                        : obsluzne funkcie tlacidiel a udalosti
' - Ed_JeDenUpraveny(), Ed_SqlVynechUpraveneDni(), Ed_ResetCacheUpravenychDni()
'                               : ochrana upravenych dni pri opakovanom importe (mod_02)
'===============================================================================

Private Const ADMIN_ZDROJ_ZAPISU As String = "MANUAL_ADMIN"
Private Const FRM_HLAVNA As String = "frmHlavnaKonzola"
Private Const FRM_DEN As String = "frmEditaciaDnaAdmin"
Private Const VERZIA_DIALOGU As String = "2.1"
Private Const KLUC_VERZIA_DIALOGU As String = "EditorDlgVerzia"
Private Const CISLO_NV As Long = 14

Private mUpraveneDni As Object

'-------------------------------------------------------------------------------
' STANDARDNE ROZHRANIE PRE CENTRALNU KONZOLU (mod_UI_Core)
'-------------------------------------------------------------------------------

Public Function IsAvailable() As Boolean
    IsAvailable = True
End Function

Public Function GetTabCaption() As String
    GetTabCaption = "4. Editor dochádzky"
End Function

'-------------------------------------------------------------------------------
' Generuje UI na zalozke v hlavnej konzole.
'-------------------------------------------------------------------------------
Public Sub BuildUI(ByVal strFormName As String, ByVal strPageName As String)
    On Error GoTo ChybaHandler
    Dim ctl As Control
    Dim vHlav As Variant, vSirky As Variant
    Dim i As Long, lX As Long, lY As Long

    ' --- Riadok 1: vyber zamestnanca a obdobia ---
    Set ctl = CreateControl(strFormName, acLabel, acDetail, strPageName, "", 500, 1150, 1250, 300)
    ctl.Caption = "Zamestnanec:"
    ctl.FontBold = True

    Set ctl = CreateControl(strFormName, acCommandButton, acDetail, strPageName, "", 1750, 1130, 350, 340)
    ctl.Name = "btnOcPred"
    ctl.Caption = "<"
    ctl.FontBold = True
    ctl.OnClick = "=Ed_ZamestnanecPred()"

    Set ctl = CreateControl(strFormName, acComboBox, acDetail, strPageName, "", 2150, 1150, 3200, 300)
    ctl.Name = "cboEditorOC"
    With ctl
        .RowSourceType = "Table/Query"
        .ColumnCount = 2
        .ColumnWidths = "0;3200"
        .BoundColumn = 1
        .LimitToList = True
        .AfterUpdate = "=NacitajAObnovOrdataView()"
    End With

    Set ctl = CreateControl(strFormName, acCommandButton, acDetail, strPageName, "", 5400, 1130, 350, 340)
    ctl.Name = "btnOcDalsi"
    ctl.Caption = ">"
    ctl.FontBold = True
    ctl.OnClick = "=Ed_ZamestnanecDalsi()"

    Set ctl = CreateControl(strFormName, acLabel, acDetail, strPageName, "", 5950, 1150, 650, 300)
    ctl.Caption = "Mesiac:"
    ctl.FontBold = True

    Call mod_UI_Spolocne.VytvorVyberMesiaca(strFormName, strPageName, "cboEditorObdobie", 6600, 1135, 1950, "=Ed_ZmenaObdobia()")

    Set ctl = CreateControl(strFormName, acCommandButton, acDetail, strPageName, "", 8650, 1130, 350, 340)
    ctl.Name = "btnMesPred"
    ctl.Caption = "<"
    ctl.FontBold = True
    ctl.OnClick = "=Ed_MesiacPred()"

    Set ctl = CreateControl(strFormName, acCommandButton, acDetail, strPageName, "", 9050, 1130, 350, 340)
    ctl.Name = "btnMesDalsi"
    ctl.Caption = ">"
    ctl.FontBold = True
    ctl.OnClick = "=Ed_MesiacDalsi()"

    ' --- Riadok 2: akcie ---
    Set ctl = CreateControl(strFormName, acCommandButton, acDetail, strPageName, "", 500, 1560, 2100, 380)
    ctl.Name = "btnNacitajOrdata"
    ctl.Caption = "Načítať / Prepočítať"
    ctl.FontBold = True
    ctl.OnClick = "=NacitajAObnovOrdataView()"

    Set ctl = CreateControl(strFormName, acCommandButton, acDetail, strPageName, "", 2700, 1560, 2500, 380)
    ctl.Name = "btnUpravDen"
    ctl.Caption = "Upraviť deň (prerušenia)"
    ctl.FontBold = True
    ctl.OnClick = "=OtvorDetailDnaZGridu()"

    Set ctl = CreateControl(strFormName, acCommandButton, acDetail, strPageName, "", 5300, 1560, 1800, 380)
    ctl.Name = "btnTlacZostavy"
    ctl.Caption = "Tlač zostavy"
    ctl.FontBold = True
    ctl.OnClick = "=Ed_TlacZostavy()"

    Set ctl = CreateControl(strFormName, acLabel, acDetail, strPageName, "", 7250, 1580, 4100, 330)
    ctl.Name = "lblEditorInfo"
    ctl.Caption = ""
    ctl.FontSize = 8
    ctl.ForeColor = RGB(90, 90, 90)

    ' --- LAVY PANEL ---
    Set ctl = CreateControl(strFormName, acRectangle, acDetail, strPageName, "", 500, 2050, 2800, 6900)
    ctl.BackColor = RGB(245, 245, 245)

    Set ctl = CreateControl(strFormName, acLabel, acDetail, strPageName, "", 600, 2100, 2600, 300)
    ctl.Caption = "Výsledky výpočtov a PaM"
    ctl.FontBold = True
    ctl.FontSize = 10
    ctl.ForeColor = RGB(15, 30, 90)

    lY = 2450
    Call PridajPaMStitokAHodnotu(strFormName, strPageName, "Mes.fond:", "lblMesFond", lY)
    Call PridajPaMStitokAHodnotu(strFormName, strPageName, "Spolu:", "lblSpolu", lY)
    Call PridajPaMStitokAHodnotu(strFormName, strPageName, "Sviatky:", "lblSviatky", lY)
    Call PridajPaMStitokAHodnotu(strFormName, strPageName, "Uzn.nad.:", "lblUznNad", lY)
    Call PridajPaMStitokAHodnotu(strFormName, strPageName, "NV z m.m.:", "lblNVmm", lY)
    Call PridajPaMStitokAHodnotu(strFormName, strPageName, "NV:", "lblNV", lY)
    Call PridajPaMStitokAHodnotu(strFormName, strPageName, "Prenos NV:", "lblPrenosNV", lY)
    Call PridajPaMStitokAHodnotu(strFormName, strPageName, "Stav:", "lblStav", lY)
    Call PridajPaMStitokAHodnotu(strFormName, strPageName, "Stav pr.deň.:", "lblStavPrDen", lY)

    Set ctl = CreateControl(strFormName, acLabel, acDetail, strPageName, "", 600, 5200, 2600, 250)
    ctl.Caption = "Rozpis prerušení v mesiaci:"
    ctl.FontBold = True
    ctl.ForeColor = RGB(15, 30, 90)

    Set ctl = CreateControl(strFormName, acListBox, acDetail, strPageName, "", 600, 5480, 2600, 3300)
    ctl.Name = "lstPaM"
    With ctl
        .RowSourceType = "Value List"
        .ColumnCount = 2
        .ColumnWidths = "1750;850"
        .ColumnHeads = False
    End With

    ' --- PRAVY PANEL: hlavicka a tabulka dni ---
    vHlav = Array("Deň", "Typ", "Raz.", "Vypoč.", "Uzn.nad.", "NV", "Nadčas", "Stav DF", "Spolu", "Pozn.")
    vSirky = Array(650, 500, 600, 800, 800, 650, 800, 900, 800, 900)
    lX = 3460
    For i = 0 To 9
        Set ctl = CreateControl(strFormName, acLabel, acDetail, strPageName, "", lX, 2050, CLng(vSirky(i)), 260)
        ctl.Caption = CStr(vHlav(i))
        ctl.FontBold = True
        ctl.FontSize = 8
        ctl.BackStyle = 1
        ctl.BackColor = RGB(215, 222, 238)
        lX = lX + CLng(vSirky(i))
    Next i

    Set ctl = CreateControl(strFormName, acListBox, acDetail, strPageName, "", 3400, 2330, 7900, 6550)
    ctl.Name = "lstDni"
    With ctl
        .RowSourceType = "Value List"
        .ColumnCount = 11
        .ColumnWidths = "0;650;500;600;800;800;650;800;900;800;900"
        .ColumnHeads = False
        .OnDblClick = "=OtvorDetailDnaZGridu()"
    End With

    Set ctl = CreateControl(strFormName, acLabel, acDetail, strPageName, "", 3400, 8930, 7900, 250)
    ctl.Caption = "Dvojklik na deň (alebo tlačidlo Upraviť deň) otvorí prehľad prerušení. Pozn.: ! = nezrovnalosť v razeniach, upr. = ručne upravený deň."
    ctl.FontSize = 8
    ctl.ForeColor = RGB(90, 90, 90)

    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("mod_05_UI_AttendanceEditor.BuildUI", "ERROR", Err.Description)
End Sub

Private Sub PridajPaMStitokAHodnotu(ByVal strFormName As String, ByVal strPageName As String, ByVal strCaption As String, ByVal strName As String, ByRef lY As Long)
    Dim ctl As Control
    Set ctl = CreateControl(strFormName, acLabel, acDetail, strPageName, "", 600, lY, 1300, 250)
    ctl.Caption = strCaption
    ctl.FontBold = True
    ctl.ForeColor = RGB(120, 0, 0)

    Set ctl = CreateControl(strFormName, acLabel, acDetail, strPageName, "", 1900, lY, 1350, 250)
    ctl.Name = strName
    ctl.Caption = "00:00"
    ctl.FontBold = True

    lY = lY + 290
End Sub

'-------------------------------------------------------------------------------
' Inicializacia vychodzich hodnot: predchadzajuci mesiac (alebo posledny mesiac
' s razeniami) a prvy zamestnanec, ktory ma v mesiaci razenia.
'-------------------------------------------------------------------------------
Public Sub InitDefaults(ByRef frm As Form)
    On Error GoTo ChybaHandler
    Dim dPred As Date, iRok As Long, iMes As Long
    Dim vMax As Variant

    Call VytvorSubformOrdataDni

    dPred = DateAdd("m", -1, Date)
    iRok = Year(dPred)
    iMes = Month(dPred)

    If DCount("*", "DochadzkaImport", "Datum >= " & Ed_SqlDatum(DateSerial(iRok, iMes, 1)) & " AND Datum < " & Ed_SqlDatum(DateSerial(iRok, iMes + 1, 1))) = 0 Then
        vMax = DMax("Datum", "DochadzkaImport")
        If Not IsNull(vMax) Then
            iRok = Year(CDate(vMax))
            iMes = Month(CDate(vMax))
        End If
    End If

    Call mod_UI_Spolocne.NastavVyberMesiaca(frm!cboEditorObdobie, CLng(iRok), CLng(iMes))

    Call Ed_ObnovZoznamZamestnancov(frm)
    Call Ed_ObnovPohlad(frm, 0)
    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("mod_05_UI_AttendanceEditor.InitDefaults", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Prepocita mesiac zvoleneho zamestnanca motorom a obnovi zalozku.
'-------------------------------------------------------------------------------
Public Function NacitajAObnovOrdataView()
    On Error GoTo ChybaHandler
    Dim frm As Form, strOC As String, iRok As Long, iMes As Long
    If Not mod_00_Common.FormIsOpen(FRM_HLAVNA) Then Exit Function
    Set frm = Forms(FRM_HLAVNA)
    If Not Ed_NacitajVyber(frm, strOC, iRok, iMes, True) Then Exit Function

    Call Ed_Prepocitaj(strOC, iRok, iMes)
    Call Ed_ObnovPohlad(frm, Ed_VybranyDen(frm))
    Exit Function
ChybaHandler:
    DoCmd.Hourglass False
    Call mod_00_Common.ZapisLog("NacitajAObnovOrdataView", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Zmena roku alebo mesiaca: obnovi zoznam zamestnancov a nacita mesiac.
'-------------------------------------------------------------------------------
Public Function Ed_ZmenaObdobia()
    On Error GoTo ChybaHandler
    Dim frm As Form
    If Not mod_00_Common.FormIsOpen(FRM_HLAVNA) Then Exit Function
    Set frm = Forms(FRM_HLAVNA)
    Call Ed_ObnovZoznamZamestnancov(frm)
    Call NacitajAObnovOrdataView
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("Ed_ZmenaObdobia", "ERROR", Err.Description)
End Function

Public Function Ed_MesiacPred()
    Call Ed_PosunMesiac(-1)
End Function

Public Function Ed_MesiacDalsi()
    Call Ed_PosunMesiac(1)
End Function

Private Sub Ed_PosunMesiac(ByVal lDelta As Long)
    On Error GoTo ChybaHandler
    Dim frm As Form, d As Date
    If Not mod_00_Common.FormIsOpen(FRM_HLAVNA) Then Exit Sub
    Set frm = Forms(FRM_HLAVNA)
    Call mod_UI_Spolocne.PosunVyberMesiaca(frm!cboEditorObdobie, lDelta)
    Call Ed_ZmenaObdobia
    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("Ed_PosunMesiac", "ERROR", Err.Description)
End Sub

Public Function Ed_ZamestnanecPred()
    Call Ed_PosunZamestnanca(-1)
End Function

Public Function Ed_ZamestnanecDalsi()
    Call Ed_PosunZamestnanca(1)
End Function

Private Sub Ed_PosunZamestnanca(ByVal lDelta As Long)
    On Error GoTo ChybaHandler
    Dim frm As Form, cbo As Control, i As Long, lIdx As Long, strOC As String
    If Not mod_00_Common.FormIsOpen(FRM_HLAVNA) Then Exit Sub
    Set frm = Forms(FRM_HLAVNA)
    Set cbo = frm!cboEditorOC
    If cbo.ListCount = 0 Then Exit Sub
    strOC = Trim$(CStr(Nz(cbo.Value, "")))
    lIdx = -1
    For i = 0 To cbo.ListCount - 1
        If CStr(Nz(cbo.ItemData(i), "")) = strOC Then lIdx = i: Exit For
    Next i
    lIdx = lIdx + lDelta
    If lIdx < 0 Then lIdx = cbo.ListCount - 1
    If lIdx > cbo.ListCount - 1 Then lIdx = 0
    cbo.Value = cbo.ItemData(lIdx)
    Call NacitajAObnovOrdataView
    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("Ed_PosunZamestnanca", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Naplni zoznam zamestnancov podla zvoleneho obdobia (len s razeniami) a zachova
' vyber, ak je zamestnanec v zozname.
'-------------------------------------------------------------------------------
Private Sub Ed_ObnovZoznamZamestnancov(ByRef frm As Form)
    On Error GoTo ChybaHandler
    Dim iRok As Long, iMes As Long, strOC As String, i As Long, bNaslo As Boolean
    Dim cbo As Control

    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboEditorObdobie, iRok, iMes) Then Exit Sub

    Set cbo = frm!cboEditorOC
    strOC = Trim$(CStr(Nz(cbo.Value, "")))

    cbo.RowSource = mod_00_Common.ZiskajSQLZoznamZamestnancov(DateSerial(iRok, iMes, 1), DateSerial(iRok, iMes + 1, 0))

    For i = 0 To cbo.ListCount - 1
        If CStr(Nz(cbo.ItemData(i), "")) = strOC Then bNaslo = True: Exit For
    Next i

    If bNaslo Then
        cbo.Value = strOC
    ElseIf cbo.ListCount > 0 Then
        cbo.Value = cbo.ItemData(0)
    Else
        cbo.Value = Null
    End If
    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("Ed_ObnovZoznamZamestnancov", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Precita vyber (zamestnanec, rok, mesiac) z hlavnej konzoly.
'-------------------------------------------------------------------------------
Private Function Ed_NacitajVyber(ByVal frm As Form, ByRef strOC As String, ByRef iRok As Long, ByRef iMes As Long, ByVal bHlas As Boolean) As Boolean
    On Error GoTo ChybaHandler
    strOC = Trim$(CStr(Nz(frm!cboEditorOC.Value, "")))
    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboEditorObdobie, iRok, iMes) Then iRok = 0: iMes = 0

    If Len(strOC) = 0 Then
        If bHlas Then MsgBox "Vyberte zamestnanca.", vbExclamation, "Editor dochádzky"
        Exit Function
    End If
    If iRok < 2000 Or iRok > 2100 Or iMes < 1 Or iMes > 12 Then
        If bHlas Then MsgBox "Zadajte platný rok a mesiac.", vbExclamation, "Editor dochádzky"
        Exit Function
    End If
    Ed_NacitajVyber = True
    Exit Function
ChybaHandler:
    Ed_NacitajVyber = False
End Function

Private Function Ed_VybranyDen(ByVal frm As Form) As Long
    On Error Resume Next
    Dim v As Variant
    v = frm!lstDni.Value
    If Not IsNull(v) Then Ed_VybranyDen = CLng(Val(v))
End Function

Private Sub Ed_Prepocitaj(ByVal strOC As String, ByVal iRok As Long, ByVal iMes As Long)
    On Error GoTo ChybaHandler
    DoCmd.Hourglass True
    Call modMesaatnaDochadzka.PrecalculujDochadzkuBezZostavy(strOC, CInt(iRok), CInt(iMes))
    DoCmd.Hourglass False
    Exit Sub
ChybaHandler:
    DoCmd.Hourglass False
    Call mod_00_Common.ZapisLog("Ed_Prepocitaj", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Tlac zostavy: motor znova prepocita mesiac z DochadzkaImport (vratane ruchnych uprav)
' a otvori nahlad zostavy.
'-------------------------------------------------------------------------------
Public Function Ed_TlacZostavy()
    On Error GoTo ChybaHandler
    Dim frm As Form, strOC As String, iRok As Long, iMes As Long
    If Not mod_00_Common.FormIsOpen(FRM_HLAVNA) Then Exit Function
    Set frm = Forms(FRM_HLAVNA)
    If Not Ed_NacitajVyber(frm, strOC, iRok, iMes, True) Then Exit Function
    Call modMesaatnaDochadzka.SpracujAOtvorZostavu(strOC, CInt(iRok), CInt(iMes))
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("Ed_TlacZostavy", "ERROR", Err.Description)
    MsgBox "Zostavu sa nepodarilo otvoriť: " & Err.Description, vbExclamation, "Editor dochádzky"
End Function

'-------------------------------------------------------------------------------
' Obnovi lavy panel, rozpis preruseni a tabulku dni (bez prepoctu).
'-------------------------------------------------------------------------------
Private Sub Ed_ObnovPohlad(ByVal frm As Form, ByVal lVybranyDen As Long)
    On Error GoTo ChybaHandler
    Dim strOC As String, iRok As Long, iMes As Long
    Dim db As DAO.Database, rs As DAO.Recordset, dicSkr As Object
    Dim dOd As Date, dDoNext As Date, lPocDni As Long, d As Long, dDen As Date
    Dim aTyp(1 To 31) As String
    Dim aFond(1 To 31) As Long, aOdpr(1 To 31) As Long, aSaldo(1 To 31) As Long
    Dim aUzn(1 To 31) As Long, aNV(1 To 31) As Long, aKredit(1 To 31) As Long
    Dim aPoc(1 To 31) As Long, aPlat(1 To 31) As Long
    Dim aUpr(1 To 31) As Boolean
    Dim aVar(1 To 31) As String
    Dim aPaM(0 To 99) As Long
    Dim lFondSum As Long, lFondDni As Long, lOdprSum As Long, lOdprDni As Long
    Dim lSviatkyMin As Long, lSviatkyDni As Long, lUznSum As Long, lNVsum As Long, lSaldoSum As Long
    Dim lPriemFond As Long, lRiadkyDni As Long, lPocRazeni As Long, lPocUpr As Long, lPocVar As Long
    Dim bWork As Boolean, bPrer As Boolean, bVrat As Boolean, iPrev As Long
    Dim lCis As Long, sSmer As String
    Dim strRow As String, strPaM As String, strPozn As String, strDen As String
    Dim lSpoluDen As Long, k As Long, lStavPr As Long

    If Not Ed_NacitajVyber(frm, strOC, iRok, iMes, False) Then
        frm!lstDni.RowSource = ""
        frm!lstPaM.RowSource = ""
        Exit Sub
    End If

    Set db = CurrentDb
    dOd = DateSerial(iRok, iMes, 1)
    dDoNext = DateSerial(iRok, iMes + 1, 1)
    lPocDni = Day(DateSerial(iRok, iMes + 1, 0))
    lPriemFond = Ed_PriemernyFond(strOC, iRok, iMes)

    ' --- 1. Denne sumare (DochadzkaDni) ---
    Set rs = db.OpenRecordset("SELECT Datum, TypDna, DennyFondMin, OdpracovaneMin, SaldoMin, UznanyNadcasMin FROM DochadzkaDni " & _
            "WHERE OsobneCislo = " & Ed_SqlText(strOC) & " AND Datum >= " & Ed_SqlDatum(dOd) & " AND Datum < " & Ed_SqlDatum(dDoNext) & ";", dbOpenSnapshot)
    Do While Not rs.EOF
        d = Day(rs!Datum)
        If d >= 1 And d <= 31 Then
            lRiadkyDni = lRiadkyDni + 1
            aTyp(d) = CStr(Nz(rs!TypDna, ""))
            aFond(d) = CLng(Nz(rs!DennyFondMin, 0))
            aOdpr(d) = CLng(Nz(rs!OdpracovaneMin, 0))
            aSaldo(d) = CLng(Nz(rs!SaldoMin, 0))
            aUzn(d) = CLng(Nz(rs!UznanyNadcasMin, 0))
        End If
        rs.MoveNext
    Loop
    rs.Close

    ' --- 2. Razenia dna: pocty a kontrola parovania ---
    Set rs = db.OpenRecordset("SELECT Datum, Cas, CisloPreruseni, Smer, Platnost FROM DochadzkaImport " & _
            "WHERE OsobneCislo = " & Ed_SqlText(strOC) & " AND Datum >= " & Ed_SqlDatum(dOd) & " AND Datum < " & Ed_SqlDatum(dDoNext) & _
            " ORDER BY Datum, Cas, ID;", dbOpenSnapshot)
    iPrev = 0
    Do While Not rs.EOF
        d = Day(rs!Datum)
        If d <> iPrev Then
            If iPrev > 0 Then Call Ed_KonciDen(bWork, bPrer, aVar(iPrev))
            bWork = False
            bPrer = False
            bVrat = False
            iPrev = d
        End If
        aPoc(d) = aPoc(d) + 1
        lPocRazeni = lPocRazeni + 1
        If CBool(Nz(rs!Platnost, True)) Then
            aPlat(d) = aPlat(d) + 1
            lCis = CLng(Nz(rs!CisloPreruseni, 0))
            sSmer = UCase$(Trim$(CStr(Nz(rs!Smer, ""))))
            Call Ed_KrokStavu(lCis, sSmer, bWork, bPrer, bVrat, aVar(d))
        End If
        rs.MoveNext
    Loop
    If iPrev > 0 Then Call Ed_KonciDen(bWork, bPrer, aVar(iPrev))
    rs.Close

    ' --- 3. Intervaly: NV po dnoch a rozpis preruseni za mesiac ---
    Set rs = db.OpenRecordset("SELECT Datum, CisloPreruseni, TrvanieMin FROM DochadzkaIntervaly " & _
            "WHERE OsobneCislo = " & Ed_SqlText(strOC) & " AND Datum >= " & Ed_SqlDatum(dOd) & " AND Datum < " & Ed_SqlDatum(dDoNext) & ";", dbOpenSnapshot)
    Do While Not rs.EOF
        d = Day(rs!Datum)
        lCis = CLng(Nz(rs!CisloPreruseni, 0))
        If lCis >= 0 And lCis <= 99 Then aPaM(lCis) = aPaM(lCis) + CLng(Nz(rs!TrvanieMin, 0))
        If lCis = CISLO_NV And d >= 1 And d <= 31 Then aNV(d) = aNV(d) + CLng(Nz(rs!TrvanieMin, 0))
        rs.MoveNext
    Loop
    rs.Close

    ' --- 4. Upravene dni ---
    If mod_00_Common.TabulkaExistuje("DochadzkaUpraveneDni") Then
        Set rs = db.OpenRecordset("SELECT Datum FROM DochadzkaUpraveneDni WHERE OsobneCislo = " & Ed_SqlText(strOC) & _
                " AND Datum >= " & Ed_SqlDatum(dOd) & " AND Datum < " & Ed_SqlDatum(dDoNext) & ";", dbOpenSnapshot)
        Do While Not rs.EOF
            d = Day(rs!Datum)
            If d >= 1 And d <= 31 Then aUpr(d) = True
            rs.MoveNext
        Loop
        rs.Close
    End If

    ' --- 5. Zostavenie tabulky dni a mesacnych suctov ---
    For d = 1 To lPocDni
        dDen = DateSerial(iRok, iMes, d)
        If Left$(aTyp(d), 1) = "S" And Weekday(dDen, vbMonday) <= 5 Then
            aKredit(d) = lPriemFond
            lSviatkyMin = lSviatkyMin + lPriemFond
            lSviatkyDni = lSviatkyDni + 1
        End If
        lFondSum = lFondSum + aFond(d)
        If aFond(d) > 0 Then lFondDni = lFondDni + 1
        lOdprSum = lOdprSum + aOdpr(d)
        If aOdpr(d) > 0 Then lOdprDni = lOdprDni + 1
        lUznSum = lUznSum + aUzn(d)
        lNVsum = lNVsum + aNV(d)
        lSaldoSum = lSaldoSum + aSaldo(d)
        If Len(aVar(d)) > 0 Then lPocVar = lPocVar + 1
        If aUpr(d) Then lPocUpr = lPocUpr + 1

        strPozn = ""
        If Len(aVar(d)) > 0 Then strPozn = "!"
        If aUpr(d) Then strPozn = Trim$(strPozn & " upr.")

        strDen = Format$(d, "00") & " " & Ed_DenTyzdna(dDen)
        lSpoluDen = aOdpr(d) + aKredit(d)

        strRow = strRow & IIf(Len(strRow) > 0, ";", "") & Ed_Bunka(CStr(d)) & ";" & Ed_Bunka(strDen) & ";" & Ed_Bunka(aTyp(d)) & ";" & _
                 Ed_Bunka(IIf(aPoc(d) = 0, "", IIf(aPoc(d) = aPlat(d), CStr(aPlat(d)), aPlat(d) & "/" & aPoc(d)))) & ";" & _
                 Ed_Bunka(IIf(aOdpr(d) <> 0, Ed_HM(aOdpr(d)), "")) & ";" & _
                 Ed_Bunka(IIf(aUzn(d) > 0, Ed_HM(aUzn(d)), "")) & ";" & _
                 Ed_Bunka(IIf(aNV(d) > 0, Ed_HM(aNV(d)), "")) & ";" & _
                 Ed_Bunka(IIf(aSaldo(d) > 0, Ed_HM(aSaldo(d)), "")) & ";" & _
                 Ed_Bunka(IIf(aSaldo(d) <> 0, Ed_HMZ(aSaldo(d)), "")) & ";" & _
                 Ed_Bunka(IIf(lSpoluDen > 0, Ed_HM(lSpoluDen), "")) & ";" & Ed_Bunka(strPozn)
    Next d

    lFondSum = lFondSum + lSviatkyMin
    lFondDni = lFondDni + lSviatkyDni
    lOdprSum = lOdprSum + lSviatkyMin
    lOdprDni = lOdprDni + lSviatkyDni

    frm!lstDni.RowSource = strRow
    If lVybranyDen >= 1 Then
        On Error Resume Next
        frm!lstDni.Value = CStr(lVybranyDen)
        On Error GoTo ChybaHandler
    End If

    ' --- 6. Lavy panel ---
    frm!lblMesFond.Caption = Ed_HM(lFondSum) & "/" & lFondDni
    frm!lblSpolu.Caption = Ed_HM(lOdprSum) & "/" & lOdprDni
    frm!lblSviatky.Caption = Ed_HM(lSviatkyMin) & "/" & lSviatkyDni
    frm!lblUznNad.Caption = Ed_HM(lUznSum)
    frm!lblNVmm.Caption = "00:00"
    frm!lblNV.Caption = Ed_HM(lNVsum)
    frm!lblPrenosNV.Caption = "00:00"
    frm!lblStav.Caption = Ed_HMZ(lSaldoSum)
    frm!lblStav.ForeColor = IIf(lSaldoSum < 0, RGB(180, 0, 0), RGB(0, 110, 0))
    lStavPr = modMesaatnaDochadzka.ZiskajStavKPredchadzajucemuDnu(strOC, CInt(iRok), CInt(iMes))
    frm!lblStavPrDen.Caption = Ed_HMZ(lStavPr)

    Set dicSkr = Ed_NacitajSkratky(db)
    For k = 0 To 99
        If aPaM(k) <> 0 Then
            If dicSkr.Exists(k) Then
                strPaM = strPaM & IIf(Len(strPaM) > 0, ";", "") & Ed_Bunka(k & "-" & CStr(dicSkr(k))) & ";" & Ed_Bunka(Ed_HM(aPaM(k)))
            Else
                strPaM = strPaM & IIf(Len(strPaM) > 0, ";", "") & Ed_Bunka(k & "-Prer." & k) & ";" & Ed_Bunka(Ed_HM(aPaM(k)))
            End If
        End If
    Next k
    frm!lstPaM.RowSource = strPaM

    If lRiadkyDni = 0 Then
        frm!lblEditorInfo.Caption = "Mesiac nie je prepočítaný - kliknite na Načítať / Prepočítať."
    Else
        frm!lblEditorInfo.Caption = Trim$(Ed_MenoZam(strOC)) & " | razení: " & lPocRazeni & " | upravených dní: " & lPocUpr & " | dní s upozornením: " & lPocVar & _
                                    IIf(mod_18_Uzavierka.JeUzavrety(strOC, iRok, iMes), " | MESIAC JE UZAVRETÝ (iba na čítanie)", "")
    End If
    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("Ed_ObnovPohlad", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Kontrola parovania razeni (rovnaka logika prechodov ako vypoctovy motor).
'-------------------------------------------------------------------------------
Private Sub Ed_KrokStavu(ByVal lCis As Long, ByVal sSmer As String, ByRef bWork As Boolean, ByRef bPrer As Boolean, ByRef bVrat As Boolean, ByRef strVar As String)
    If lCis = 0 Or (sSmer <> "Z" And sSmer <> "K") Then
        Call Ed_Varuj(strVar, "razenie s neznámym kódom")
    ElseIf lCis = 1 Then
        If sSmer = "Z" Then
            If bWork Then Call Ed_Varuj(strVar, "dvojitý príchod")
            bWork = True
        Else
            If bWork Then
                bWork = False
            ElseIf Not bPrer Then
                Call Ed_Varuj(strVar, "odchod bez príchodu")
            End If
        End If
    Else
        If sSmer = "Z" Then
            If bPrer Then
                Call Ed_Varuj(strVar, "prerušenie začaté dvakrát")
            Else
                bVrat = bWork
            End If
            bWork = False
            bPrer = True
        Else
            If bPrer Then
                bPrer = False
                bWork = bVrat
                bVrat = False
            Else
                Call Ed_Varuj(strVar, "koniec prerušenia bez začiatku")
            End If
        End If
    End If
End Sub

Private Sub Ed_KonciDen(ByVal bWork As Boolean, ByVal bPrer As Boolean, ByRef strVar As String)
    If bPrer Then Call Ed_Varuj(strVar, "chýba koniec prerušenia")
    If bWork Then Call Ed_Varuj(strVar, "chýba odchod z práce")
End Sub

Private Sub Ed_Varuj(ByRef strVar As String, ByVal strText As String)
    If InStr(1, strVar, strText, vbTextCompare) = 0 Then
        If Len(strVar) > 0 Then strVar = strVar & "; "
        strVar = strVar & strText
    End If
End Sub

'-------------------------------------------------------------------------------
' OKNO DNA - otvorenie
'-------------------------------------------------------------------------------
Public Function OtvorDetailDnaZGridu()
    On Error GoTo ChybaHandler
    Dim frm As Form, strOC As String, iRok As Long, iMes As Long, lDen As Long
    If Not mod_00_Common.FormIsOpen(FRM_HLAVNA) Then Exit Function
    Set frm = Forms(FRM_HLAVNA)
    If Not Ed_NacitajVyber(frm, strOC, iRok, iMes, True) Then Exit Function

    lDen = Ed_VybranyDen(frm)
    If lDen < 1 Or lDen > 31 Then
        MsgBox "Najprv označte deň v tabuľke.", vbInformation, "Editor dochádzky"
        Exit Function
    End If
    Call Ed_OtvorDen(strOC, DateSerial(iRok, iMes, lDen))
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("OtvorDetailDnaZGridu", "ERROR", Err.Description)
    MsgBox "Okno dňa sa nepodarilo otvoriť: " & Err.Description, vbExclamation, "Editor dochádzky"
End Function

Private Sub Ed_OtvorDen(ByVal strOC As String, ByVal dDen As Date)
    Dim frm As Form
    Call Ed_ZabezpecDialog
    If mod_00_Common.FormIsOpen(FRM_DEN) Then DoCmd.Close acForm, FRM_DEN, acSaveNo
    DoCmd.OpenForm FRM_DEN, acNormal
    Set frm = Forms(FRM_DEN)
    frm!txtDlgOC = strOC
    frm!txtDlgDatum = Format$(dDen, "yyyy\-mm\-dd")
    Call Ed_DenObnov(frm)
End Sub

'-------------------------------------------------------------------------------
' Nacita kontext okna (zamestnanec, datum) z jeho skrytych poli.
'-------------------------------------------------------------------------------
Private Function Ed_DenKontext(ByRef frm As Form, ByRef strOC As String, ByRef dDen As Date) As Boolean
    On Error GoTo ChybaHandler
    Dim s As String
    If Not mod_00_Common.FormIsOpen(FRM_DEN) Then Exit Function
    Set frm = Forms(FRM_DEN)
    strOC = Trim$(CStr(Nz(frm!txtDlgOC, "")))
    s = CStr(Nz(frm!txtDlgDatum, ""))
    If Len(strOC) = 0 Or Len(s) <> 10 Then Exit Function
    dDen = DateSerial(CLng(Val(Left$(s, 4))), CLng(Val(Mid$(s, 6, 2))), CLng(Val(Mid$(s, 9, 2))))
    Ed_DenKontext = True
    Exit Function
ChybaHandler:
    Ed_DenKontext = False
End Function

'-------------------------------------------------------------------------------
' Kontext okna dna pre ZAPIS: ako Ed_DenKontext, ale uzavretý (podpísaný) mesiac sa meniť nesmie.
'-------------------------------------------------------------------------------
Private Function Ed_DenKontextZapis(ByRef frm As Form, ByRef strOC As String, ByRef dDen As Date) As Boolean
    If Not Ed_DenKontext(frm, strOC, dDen) Then Exit Function
    If mod_18_Uzavierka.ZablokovanaUprava(strOC, dDen, True) Then Exit Function
    Ed_DenKontextZapis = True
End Function

'-------------------------------------------------------------------------------
' Obnovi obsah okna dna (zoznam razeni, suhrn, intervaly).
'-------------------------------------------------------------------------------
Private Sub Ed_DenObnov(ByVal frm As Form)
    On Error GoTo ChybaHandler
    Dim strOC As String, dDen As Date, frmCtx As Form
    If Not Ed_DenKontext(frmCtx, strOC, dDen) Then Exit Sub

    frm!lblDatumDna.Caption = "Prehľad prerušení cez deň  -  " & Format$(dDen, "dd.mm.yyyy") & " (" & Ed_DenTyzdnaPlny(dDen) & ")" & _
                              IIf(mod_18_Uzavierka.JeUzavretyDen(strOC, dDen), "  -  MESIAC JE UZAVRETÝ (iba na čítanie)", "")
    Call Ed_DenNaplnZoznam(frm, strOC, dDen)
    Call Ed_DenNaplnSumar(frm, strOC, dDen)
    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("Ed_DenObnov", "ERROR", Err.Description)
End Sub

Private Sub Ed_DenNaplnZoznam(ByVal frm As Form, ByVal strOC As String, ByVal dDen As Date)
    On Error GoTo ChybaHandler
    Dim db As DAO.Database, rs As DAO.Recordset, dicKod As Object
    Dim strRow As String, strVar As String, strNazov As String, strZdroj As String
    Dim bWork As Boolean, bPrer As Boolean, bVrat As Boolean, bPlat As Boolean
    Dim lCis As Long, sSmer As String, lCas As Long, lKod As Long, lPoc As Long, lSel As Long

    Set db = CurrentDb
    Set dicKod = Ed_NacitajKody(db)
    lSel = Ed_VybraneID(frm)

    Set rs = db.OpenRecordset("SELECT * FROM DochadzkaImport WHERE OsobneCislo = " & Ed_SqlText(strOC) & _
            " AND Datum = " & Ed_SqlDatum(dDen) & " ORDER BY Cas, ID;", dbOpenSnapshot)
    Do While Not rs.EOF
        lKod = CLng(Nz(rs!KodPrerusenia, 0))
        lCas = CLng(Nz(rs!Cas, 0))
        bPlat = CBool(Nz(rs!Platnost, True))
        lCis = CLng(Nz(rs!CisloPreruseni, 0))
        sSmer = UCase$(Trim$(CStr(Nz(rs!Smer, ""))))

        If dicKod.Exists(lKod) Then
            strNazov = CStr(dicKod(lKod))
        Else
            strNazov = "Kód " & lKod & " (neznámy)"
        End If
        If bPlat Then Call Ed_KrokStavu(lCis, sSmer, bWork, bPrer, bVrat, strVar)
        strZdroj = Ed_ZdrojText(rs)

        strRow = strRow & IIf(Len(strRow) > 0, ";", "") & Ed_Bunka(CStr(rs!ID)) & ";" & Ed_Bunka(IIf(bPlat, "+", "-")) & ";" & _
                 Ed_Bunka(Ed_HM(lCas)) & ";" & Ed_Bunka(CStr(lKod)) & ";" & Ed_Bunka(strNazov) & ";" & Ed_Bunka(strZdroj) & ";" & _
                 Ed_Bunka(CStr(Nz(rs!Uzivatel, ""))) & ";" & Ed_Bunka(Ed_DatumText(rs!DatumPoc)) & ";" & Ed_Bunka(Ed_CasZapisuText(rs!CasPoc))
        lPoc = lPoc + 1
        rs.MoveNext
    Loop
    rs.Close
    Call Ed_KonciDen(bWork, bPrer, strVar)

    frm!lstRazenia.RowSource = strRow
    If lSel > 0 Then
        On Error Resume Next
        frm!lstRazenia.Value = CStr(lSel)
        On Error GoTo ChybaHandler
    End If

    If Len(strVar) > 0 Then
        frm!lblUpozornenia.Caption = "Pozor: " & strVar
        frm!lblUpozornenia.ForeColor = RGB(180, 0, 0)
    ElseIf lPoc = 0 Then
        frm!lblUpozornenia.Caption = "V tento deň nie sú žiadne razenia. Pridajte razenie alebo prerušenie (pár)."
        frm!lblUpozornenia.ForeColor = RGB(90, 90, 90)
    Else
        frm!lblUpozornenia.Caption = "Razenia sú v poriadku (príchod/odchod aj prerušenia sú spárované)."
        frm!lblUpozornenia.ForeColor = RGB(0, 110, 0)
    End If
    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("Ed_DenNaplnZoznam", "ERROR", Err.Description)
End Sub

Private Sub Ed_DenNaplnSumar(ByVal frm As Form, ByVal strOC As String, ByVal dDen As Date)
    On Error GoTo ChybaHandler
    Dim db As DAO.Database, rs As DAO.Recordset, strInfo As String, strInt As String

    Set db = CurrentDb
    Set rs = db.OpenRecordset("SELECT TOP 1 TypDna, DennyFondMin, OdpracovaneMin, SaldoMin FROM DochadzkaDni " & _
            "WHERE OsobneCislo = " & Ed_SqlText(strOC) & " AND Datum = " & Ed_SqlDatum(dDen) & ";", dbOpenSnapshot)
    If rs.EOF Then
        strInfo = "Deň nie je prepočítaný."
    Else
        strInfo = "Typ dňa: " & CStr(Nz(rs!TypDna, "")) & "     Fond: " & Ed_HM(CLng(Nz(rs!DennyFondMin, 0))) & _
                  "     Vypočítané: " & Ed_HM(CLng(Nz(rs!OdpracovaneMin, 0))) & "     Stav DF: " & Ed_HMZ(CLng(Nz(rs!SaldoMin, 0)))
    End If
    rs.Close
    strInfo = strInfo & "     Osobné číslo: " & strOC & " " & Trim$(Ed_MenoZam(strOC))
    frm!lblDenInfo.Caption = strInfo

    Set rs = db.OpenRecordset("SELECT Poradie, NazovPreruseni, ZaciatokText, KoniecText, TrvanieMin FROM DochadzkaIntervaly " & _
            "WHERE OsobneCislo = " & Ed_SqlText(strOC) & " AND Datum = " & Ed_SqlDatum(dDen) & " ORDER BY Poradie;", dbOpenSnapshot)
    Do While Not rs.EOF
        strInt = strInt & IIf(Len(strInt) > 0, "  |  ", "") & CStr(Nz(rs!ZaciatokText, "")) & "-" & CStr(Nz(rs!KoniecText, "")) & " " & _
                 CStr(Nz(rs!NazovPreruseni, "")) & " (" & CLng(Nz(rs!TrvanieMin, 0)) & " min)"
        rs.MoveNext
    Loop
    rs.Close
    If Len(strInt) = 0 Then strInt = "(žiadne spracované intervaly)"
    If Len(strInt) > 600 Then strInt = Left$(strInt, 600) & "..."
    frm!lblIntervaly.Caption = "Vypočítané intervaly (r = razené):  " & strInt
    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("Ed_DenNaplnSumar", "ERROR", Err.Description)
End Sub

Private Function Ed_VybraneID(ByVal frm As Form) As Long
    On Error Resume Next
    Dim v As Variant
    v = frm!lstRazenia.Value
    If Not IsNull(v) Then Ed_VybraneID = CLng(Val(v))
End Function

Private Function Ed_ZdrojText(ByRef rs As DAO.Recordset) As String
    On Error Resume Next
    Dim strZZ As String
    strZZ = CStr(Nz(rs!ZdrojZapisu, ""))
    If strZZ = ADMIN_ZDROJ_ZAPISU Then
        Ed_ZdrojText = "Ručne (nové)"
    ElseIf CBool(Nz(rs!RucneUpravene, False)) Then
        Ed_ZdrojText = "Upravené"
    Else
        Ed_ZdrojText = "Import"
    End If
End Function

'-------------------------------------------------------------------------------
' Vyber riadku v zozname: prenesie cas a kod do poli na upravu.
'-------------------------------------------------------------------------------
Public Function Ed_DenVyberRiadku()
    On Error Resume Next
    Dim frm As Form
    If Not mod_00_Common.FormIsOpen(FRM_DEN) Then Exit Function
    Set frm = Forms(FRM_DEN)
    If Ed_VybraneID(frm) = 0 Then Exit Function
    frm!txtCas = CStr(frm!lstRazenia.Column(2))
    frm!cboKod = CLng(Val(frm!lstRazenia.Column(3)))
End Function

'-------------------------------------------------------------------------------
' OKNO DNA - operacie
'-------------------------------------------------------------------------------

' Ins - Pridaj: nove razenie z vybraneho kodu a casu.
Public Function Ed_DenPridajRazenie()
    On Error GoTo ChybaHandler
    Dim frm As Form, strOC As String, dDen As Date, lCas As Long, lKod As Long
    Dim db As DAO.Database

    If Not Ed_DenKontextZapis(frm, strOC, dDen) Then Exit Function
    If IsNull(frm!cboKod.Value) Then
        MsgBox "Vyberte kód razenia.", vbExclamation, "Editor dochádzky"
        Exit Function
    End If
    lKod = CLng(frm!cboKod.Value)
    If Not Ed_ParseCas(CStr(Nz(frm!txtCas.Value, "")), lCas) Then
        MsgBox "Zadajte čas v tvare hh:mm (napr. 7:05 alebo 15:30).", vbExclamation, "Editor dochádzky"
        Exit Function
    End If

    Set db = CurrentDb
    If Ed_ExistujeRazenie(db, strOC, dDen, lCas, lKod) Then
        MsgBox "Rovnaké platné razenie (čas a kód) už v tento deň existuje.", vbExclamation, "Editor dochádzky"
        Exit Function
    End If

    Call Ed_ZabezpecUpravu(db, strOC, dDen)
    If Not Ed_VlozRazenie(db, strOC, dDen, lCas, lKod) Then Exit Function
    Call Ed_ZapisAudit(db, strOC, dDen, "PRIDANIE", "kód " & lKod & ", čas " & Ed_HM(lCas))
    Call Ed_PoZmene(frm, strOC, dDen)
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("Ed_DenPridajRazenie", "ERROR", Err.Description)
    MsgBox "Razenie sa nepodarilo pridať: " & Err.Description, vbExclamation, "Editor dochádzky"
End Function

' Enter - Oprava: zmeni cas a/alebo kod oznaceneho razenia.
Public Function Ed_DenOpravRazenie()
    On Error GoTo ChybaHandler
    Dim frm As Form, strOC As String, dDen As Date, lCas As Long, lKod As Long, lID As Long
    Dim lCislo As Long, sSmer As String, strPred As String
    Dim db As DAO.Database, rs As DAO.Recordset

    If Not Ed_DenKontextZapis(frm, strOC, dDen) Then Exit Function
    lID = Ed_VybraneID(frm)
    If lID = 0 Then
        MsgBox "Označte razenie v zozname.", vbExclamation, "Editor dochádzky"
        Exit Function
    End If
    If IsNull(frm!cboKod.Value) Then
        MsgBox "Vyberte kód razenia.", vbExclamation, "Editor dochádzky"
        Exit Function
    End If
    lKod = CLng(frm!cboKod.Value)
    If Not Ed_ParseCas(CStr(Nz(frm!txtCas.Value, "")), lCas) Then
        MsgBox "Zadajte čas v tvare hh:mm (napr. 7:05 alebo 15:30).", vbExclamation, "Editor dochádzky"
        Exit Function
    End If

    Set db = CurrentDb
    If Not Ed_ZistiKod(db, lKod, lCislo, sSmer) Then Exit Function

    Call Ed_ZabezpecUpravu(db, strOC, dDen)
    Set rs = db.OpenRecordset("SELECT * FROM DochadzkaImport WHERE ID = " & lID & " AND OsobneCislo = " & Ed_SqlText(strOC) & _
            " AND Datum = " & Ed_SqlDatum(dDen) & ";", dbOpenDynaset)
    If rs.EOF Then
        rs.Close
        MsgBox "Razenie sa nenašlo (možno bolo medzitým zmenené).", vbExclamation, "Editor dochádzky"
        Exit Function
    End If

    strPred = "kód " & CLng(Nz(rs!KodPrerusenia, 0)) & ", čas " & Ed_HM(CLng(Nz(rs!Cas, 0)))
    ' Oprava = pôvodné razenie sa zneplatní (ostáva v histórii) a vznikne nové razenie prepojené cez PovodneID.
    rs.Edit
    rs!Platnost = False
    rs!DovodNeplatnosti = "RUCNA_OPRAVA"
    rs!RucneUpravene = True
    rs!UzivatelZmeny = Ed_Uzivatel()
    rs!DatumZmeny = Now
    rs.Update
    rs.Close
    If Not Ed_VlozRazenie(db, strOC, dDen, lCas, lKod, lID) Then Exit Function

    Call Ed_ZapisAudit(db, strOC, dDen, "OPRAVA", strPred & "  ->  kód " & lKod & ", čas " & Ed_HM(lCas))
    Call Ed_PoZmene(frm, strOC, dDen)
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("Ed_DenOpravRazenie", "ERROR", Err.Description)
    MsgBox "Razenie sa nepodarilo opraviť: " & Err.Description, vbExclamation, "Editor dochádzky"
End Function

' Del - Zrus: zneplatni oznacene razenie (fyzicky sa nemaze).
Public Function Ed_DenZrusRazenie()
    On Error GoTo ChybaHandler
    Dim frm As Form, strOC As String, dDen As Date, lID As Long
    Dim db As DAO.Database, rs As DAO.Recordset, strPred As String

    If Not Ed_DenKontextZapis(frm, strOC, dDen) Then Exit Function
    lID = Ed_VybraneID(frm)
    If lID = 0 Then
        MsgBox "Označte razenie v zozname.", vbExclamation, "Editor dochádzky"
        Exit Function
    End If
    If MsgBox("Naozaj zrušiť označené razenie " & CStr(frm!lstRazenia.Column(2)) & " (" & CStr(frm!lstRazenia.Column(4)) & ")?" & vbCrLf & _
              "Razenie sa nezmaže, iba zneplatní. Pôvodný stav dňa sa dá obnoviť tlačidlom Pôvodný deň.", vbQuestion + vbYesNo, "Editor dochádzky") <> vbYes Then Exit Function

    Set db = CurrentDb
    Call Ed_ZabezpecUpravu(db, strOC, dDen)
    Set rs = db.OpenRecordset("SELECT Cas, KodPrerusenia FROM DochadzkaImport WHERE ID = " & lID & " AND OsobneCislo = " & Ed_SqlText(strOC) & _
            " AND Datum = " & Ed_SqlDatum(dDen) & ";", dbOpenSnapshot)
    If Not rs.EOF Then strPred = "kód " & CLng(Nz(rs!KodPrerusenia, 0)) & ", čas " & Ed_HM(CLng(Nz(rs!Cas, 0)))
    rs.Close

    ' Razenie sa FYZICKY NEMAZE - zneplatni sa (Platnost = False) a ostane v histórii s dôvodom a autorom.
    db.Execute "UPDATE DochadzkaImport SET Platnost = False, DovodNeplatnosti = 'RUCNE_ZRUSENIE', RucneUpravene = True, UzivatelZmeny = " & Ed_SqlText(Ed_Uzivatel()) & _
               ", DatumZmeny = Now() WHERE ID = " & lID & " AND OsobneCislo = " & Ed_SqlText(strOC) & " AND Datum = " & Ed_SqlDatum(dDen), dbFailOnError
    Call Ed_ZapisAudit(db, strOC, dDen, "ZRUSENIE", strPred)
    Call Ed_PoZmene(frm, strOC, dDen)
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("Ed_DenZrusRazenie", "ERROR", Err.Description)
    MsgBox "Razenie sa nepodarilo zrušiť: " & Err.Description, vbExclamation, "Editor dochádzky"
End Function

' Medzera - Stav platnosti: prepne platnost oznaceneho razenia.
Public Function Ed_DenPlatnost()
    On Error GoTo ChybaHandler
    Dim frm As Form, strOC As String, dDen As Date, lID As Long, bNova As Boolean
    Dim db As DAO.Database, rs As DAO.Recordset, strPred As String

    If Not Ed_DenKontextZapis(frm, strOC, dDen) Then Exit Function
    lID = Ed_VybraneID(frm)
    If lID = 0 Then
        MsgBox "Označte razenie v zozname.", vbExclamation, "Editor dochádzky"
        Exit Function
    End If

    Set db = CurrentDb
    Call Ed_ZabezpecUpravu(db, strOC, dDen)
    Set rs = db.OpenRecordset("SELECT * FROM DochadzkaImport WHERE ID = " & lID & " AND OsobneCislo = " & Ed_SqlText(strOC) & _
            " AND Datum = " & Ed_SqlDatum(dDen) & ";", dbOpenDynaset)
    If rs.EOF Then
        rs.Close
        Exit Function
    End If
    bNova = Not CBool(Nz(rs!Platnost, True))
    strPred = "kód " & CLng(Nz(rs!KodPrerusenia, 0)) & ", čas " & Ed_HM(CLng(Nz(rs!Cas, 0)))
    rs.Edit
    rs!Platnost = bNova
    rs!DovodNeplatnosti = IIf(bNova, Null, "RUCNE_ZNEPLATNENIE")
    rs!RucneUpravene = True
    rs!UzivatelZmeny = Ed_Uzivatel()
    rs!DatumZmeny = Now
    rs.Update
    rs.Close

    Call Ed_ZapisAudit(db, strOC, dDen, IIf(bNova, "PLATNE", "NEPLATNE"), strPred)
    Call Ed_PoZmene(frm, strOC, dDen)
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("Ed_DenPlatnost", "ERROR", Err.Description)
    MsgBox "Platnosť sa nepodarilo zmeniť: " & Err.Description, vbExclamation, "Editor dochádzky"
End Function

' Pridaj par: prerusenie od-do (zaciatok + koniec naraz).
Public Function Ed_DenPridajPar()
    On Error GoTo ChybaHandler
    Dim frm As Form, strOC As String, dDen As Date, lCislo As Long, lOd As Long, lDo As Long
    Dim lKodZ As Long, lKodK As Long
    Dim db As DAO.Database, rs As DAO.Recordset

    If Not Ed_DenKontextZapis(frm, strOC, dDen) Then Exit Function
    If IsNull(frm!cboPrerusenie.Value) Then
        MsgBox "Vyberte prerušenie.", vbExclamation, "Editor dochádzky"
        Exit Function
    End If
    lCislo = CLng(frm!cboPrerusenie.Value)
    If Not Ed_ParseCas(CStr(Nz(frm!txtParOd.Value, "")), lOd) Or Not Ed_ParseCas(CStr(Nz(frm!txtParDo.Value, "")), lDo) Then
        MsgBox "Zadajte čas začiatku aj konca v tvare hh:mm.", vbExclamation, "Editor dochádzky"
        Exit Function
    End If
    If lDo <= lOd Then
        MsgBox "Koniec prerušenia musí byť neskôr ako jeho začiatok.", vbExclamation, "Editor dochádzky"
        Exit Function
    End If

    Set db = CurrentDb
    Set rs = db.OpenRecordset("SELECT KodZaciatok, KodKoniec FROM CiselnikPreruseni WHERE Cislo = " & lCislo & ";", dbOpenSnapshot)
    If rs.EOF Then
        rs.Close
        MsgBox "Prerušenie sa nenašlo v číselníku.", vbExclamation, "Editor dochádzky"
        Exit Function
    End If
    lKodZ = CLng(Nz(rs!KodZaciatok, 0))
    lKodK = CLng(Nz(rs!KodKoniec, 0))
    rs.Close

    If Ed_ExistujeRazenie(db, strOC, dDen, lOd, lKodZ) Or Ed_ExistujeRazenie(db, strOC, dDen, lDo, lKodK) Then
        MsgBox "Niektoré z razení tohto páru už v tento deň existuje.", vbExclamation, "Editor dochádzky"
        Exit Function
    End If

    Call Ed_ZabezpecUpravu(db, strOC, dDen)
    If Not Ed_VlozRazenie(db, strOC, dDen, lOd, lKodZ) Then Exit Function
    If Not Ed_VlozRazenie(db, strOC, dDen, lDo, lKodK) Then Exit Function
    Call Ed_ZapisAudit(db, strOC, dDen, "PRIDANIE PARU", "prerušenie " & lCislo & ", " & Ed_HM(lOd) & " - " & Ed_HM(lDo))
    Call Ed_PoZmene(frm, strOC, dDen)
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("Ed_DenPridajPar", "ERROR", Err.Description)
    MsgBox "Prerušenie sa nepodarilo pridať: " & Err.Description, vbExclamation, "Editor dochádzky"
End Function

' Povodny den: obnovi razenia dna do stavu pred prvou rucnou upravou (bez fyzickeho mazania razeni).
Public Function Ed_DenPovodnyDen()
    On Error GoTo ChybaHandler
    Dim frm As Form, strOC As String, dDen As Date
    Dim db As DAO.Database, ws As DAO.Workspace, bTrans As Boolean
    Dim strKrit As String, strKrit2 As String, rsP As DAO.Recordset, rsD As DAO.Recordset, vPole As Variant

    If Not Ed_DenKontextZapis(frm, strOC, dDen) Then Exit Function
    If Not mod_00_Common.TabulkaExistuje("DochadzkaUpraveneDni") Then
        MsgBox "Tento deň nebol ručne upravovaný.", vbInformation, "Editor dochádzky"
        Exit Function
    End If

    Set db = CurrentDb
    strKrit = "OsobneCislo = " & Ed_SqlText(strOC) & " AND Datum = " & Ed_SqlDatum(dDen)
    If DCount("*", "DochadzkaUpraveneDni", strKrit) = 0 Then
        MsgBox "Tento deň nebol ručne upravovaný - je v pôvodnom stave.", vbInformation, "Editor dochádzky"
        Exit Function
    End If
    If MsgBox("Obnoviť pôvodné razenia dňa " & Format$(dDen, "dd.mm.yyyy") & "?" & vbCrLf & _
              "Všetky ručné úpravy tohto dňa sa zahodia.", vbQuestion + vbYesNo, "Editor dochádzky") <> vbYes Then Exit Function

    strKrit2 = strKrit
    Set ws = DBEngine.Workspaces(0)
    ws.BeginTrans
    bTrans = True

    ' 1) razenia pridané počas ručných úprav (nie sú v snímke) sa ZNEPLATNIA - fyzicky sa nemažú
    db.Execute "UPDATE DochadzkaImport SET Platnost = False, DovodNeplatnosti = 'ZRUSENE_PRI_OBNOVE', UzivatelZmeny = " & Ed_SqlText(Ed_Uzivatel()) & _
               ", DatumZmeny = Now() WHERE " & strKrit & " AND ID NOT IN (SELECT IDRazenia FROM DochadzkaImportPovodne WHERE " & strKrit2 & " AND IDRazenia IS NOT NULL)", dbFailOnError

    ' 2) razenia zo snímky sa vrátia do pôvodných hodnôt (zachováva sa ID); fyzicky zmazané (staršia verzia editora) sa vložia znovu
    Set rsP = db.OpenRecordset("SELECT * FROM DochadzkaImportPovodne WHERE " & strKrit2 & ";", dbOpenSnapshot)
    Do While Not rsP.EOF
        Set rsD = db.OpenRecordset("SELECT * FROM DochadzkaImport WHERE ID = " & CLng(Nz(rsP!IDRazenia, 0)) & ";", dbOpenDynaset)
        If rsD.EOF Then rsD.AddNew Else rsD.Edit
        For Each vPole In Array("Datum", "Cas", "DatumSnim", "CisPam", "DatumPoc", "CasPoc", "OsobneCislo", "KodPrerusenia", "Platnost", "Zdroj", "Uzivatel", _
                                "OdpracDoba", "Poradie", "StavUza", "Poznamka", "CisloPreruseni", "Smer", "RucneUpravene", "ZdrojZapisu", "UzivatelZmeny", "DatumZmeny")
            rsD.Fields(CStr(vPole)).Value = rsP.Fields(CStr(vPole)).Value
        Next vPole
        rsD!DovodNeplatnosti = Null
        rsD!PovodneID = Null
        rsD.Update
        rsD.Close
        rsP.MoveNext
    Loop
    rsP.Close
    db.Execute "DELETE FROM DochadzkaImportPovodne WHERE " & strKrit2, dbFailOnError
    db.Execute "DELETE FROM DochadzkaUpraveneDni WHERE " & strKrit2, dbFailOnError

    ws.CommitTrans
    bTrans = False
    Set mUpraveneDni = Nothing

    Call Ed_ZapisAudit(db, strOC, dDen, "POVODNY DEN", "obnovené pôvodné razenia dňa")
    Call Ed_PoZmene(frm, strOC, dDen)
    Exit Function
ChybaHandler:
    If bTrans Then
        On Error Resume Next
        ws.Rollback
        On Error GoTo 0
    End If
    Call mod_00_Common.ZapisLog("Ed_DenPovodnyDen", "ERROR", Err.Description)
    MsgBox "Pôvodný deň sa nepodarilo obnoviť: " & Err.Description, vbExclamation, "Editor dochádzky"
End Function

' Prepocitaj mesiac a obnov okno.
Public Function Ed_DenPrepocitaj()
    On Error GoTo ChybaHandler
    Dim frm As Form, strOC As String, dDen As Date
    If Not Ed_DenKontext(frm, strOC, dDen) Then Exit Function
    Call Ed_PoZmene(frm, strOC, dDen)
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("Ed_DenPrepocitaj", "ERROR", Err.Description)
End Function

' K - Koniec.
Public Function Ed_DenKoniec()
    On Error Resume Next
    DoCmd.Close acForm, FRM_DEN, acSaveNo
End Function

' Po zatvoreni okna obnov tabulku dni na zalozke.
Public Function Ed_DenPoZatvoreni()
    On Error Resume Next
    Dim frm As Form
    If mod_00_Common.FormIsOpen(FRM_HLAVNA) Then
        Set frm = Forms(FRM_HLAVNA)
        Call Ed_ObnovPohlad(frm, Ed_VybranyDen(frm))
    End If
End Function

'-------------------------------------------------------------------------------
' Po kazdej zmene: oznac den ako upraveny, prepocitaj mesiac, obnov okno aj zalozku.
'-------------------------------------------------------------------------------
Private Sub Ed_PoZmene(ByVal frm As Form, ByVal strOC As String, ByVal dDen As Date)
    On Error GoTo ChybaHandler
    Dim frmH As Form
    On Error Resume Next
    CurrentDb.Execute "UPDATE DochadzkaUpraveneDni SET PoslednaUprava = Now(), Uzivatel = " & Ed_SqlText(Ed_Uzivatel()) & _
                      " WHERE OsobneCislo = " & Ed_SqlText(strOC) & " AND Datum = " & Ed_SqlDatum(dDen), dbFailOnError
    Err.Clear
    On Error GoTo ChybaHandler

    Call Ed_Prepocitaj(strOC, Year(dDen), Month(dDen))
    Call Ed_DenObnov(frm)
    If mod_00_Common.FormIsOpen(FRM_HLAVNA) Then
        Set frmH = Forms(FRM_HLAVNA)
        Call Ed_ObnovPohlad(frmH, Day(dDen))
    End If
    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("Ed_PoZmene", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' ZAPIS RAZENI A EVIDENCIA UPRAV
'-------------------------------------------------------------------------------

Private Function Ed_ZistiKod(ByRef db As DAO.Database, ByVal lKod As Long, ByRef lCislo As Long, ByRef sSmer As String) As Boolean
    Dim rs As DAO.Recordset
    Set rs = db.OpenRecordset("SELECT CisloPreruseni, Smer FROM KodyRazeni WHERE KodRazenia = " & lKod & ";", dbOpenSnapshot)
    If rs.EOF Then
        rs.Close
        MsgBox "Kód razenia " & lKod & " sa nenašiel v číselníku KodyRazeni.", vbExclamation, "Editor dochádzky"
        Exit Function
    End If
    lCislo = CLng(Nz(rs!CisloPreruseni, 0))
    sSmer = UCase$(Trim$(CStr(Nz(rs!Smer, ""))))
    rs.Close
    Ed_ZistiKod = True
End Function

Private Function Ed_ExistujeRazenie(ByRef db As DAO.Database, ByVal strOC As String, ByVal dDen As Date, ByVal lCas As Long, ByVal lKod As Long) As Boolean
    Ed_ExistujeRazenie = (DCount("*", "DochadzkaImport", "OsobneCislo = " & Ed_SqlText(strOC) & " AND Datum = " & Ed_SqlDatum(dDen) & _
                          " AND Cas = " & lCas & " AND KodPrerusenia = " & lKod & " AND (Platnost = True OR Platnost IS NULL)") > 0)
End Function

Private Function Ed_VlozRazenie(ByRef db As DAO.Database, ByVal strOC As String, ByVal dDen As Date, ByVal lCas As Long, ByVal lKod As Long, Optional ByVal lPovodneID As Long = 0) As Boolean
    Dim rs As DAO.Recordset, lCislo As Long, sSmer As String, lPor As Long

    If Not Ed_ZistiKod(db, lKod, lCislo, sSmer) Then Exit Function
    lPor = CLng(Nz(DMax("Poradie", "DochadzkaImport"), 0)) + 1

    Set rs = db.OpenRecordset("DochadzkaImport", dbOpenDynaset)
    rs.AddNew
    rs!Datum = dDen
    rs!Cas = lCas
    rs!OsobneCislo = strOC
    rs!KodPrerusenia = lKod
    rs!CisloPreruseni = lCislo
    rs!Smer = sSmer
    rs!Platnost = True
    rs!Zdroj = 0
    rs!CisPam = 0
    rs!DatumPoc = Date
    rs!CasPoc = Hour(Time) * 60 + Minute(Time)
    rs!Uzivatel = Ed_Uzivatel()
    rs!OdpracDoba = 0
    rs!Poradie = lPor
    rs!StavUza = False
    rs!RucneUpravene = True
    rs!ZdrojZapisu = ADMIN_ZDROJ_ZAPISU
    rs!UzivatelZmeny = Ed_Uzivatel()
    rs!DatumZmeny = Now
    If lPovodneID > 0 Then rs!PovodneID = lPovodneID
    rs.Update
    rs.Close
    Ed_VlozRazenie = True
End Function

Private Sub Ed_ZabezpecTabulky(ByRef db As DAO.Database)
    If Not mod_00_Common.TabulkaExistuje("DochadzkaUpraveneDni") Then
        db.Execute "CREATE TABLE DochadzkaUpraveneDni (ID AUTOINCREMENT PRIMARY KEY, OsobneCislo TEXT(20), Datum DATETIME, " & _
                   "Uzivatel TEXT(50), PrvaUprava DATETIME, PoslednaUprava DATETIME, PocetPovodnych LONG)", dbFailOnError
    End If
    If Not mod_00_Common.TabulkaExistuje("DochadzkaImportPovodne") Then
        db.Execute "CREATE TABLE DochadzkaImportPovodne (IDPovodne AUTOINCREMENT PRIMARY KEY, IDRazenia LONG, Datum DATETIME, Cas LONG, " & _
                   "DatumSnim DATETIME, CisPam LONG, DatumPoc DATETIME, CasPoc LONG, OsobneCislo TEXT(20), KodPrerusenia LONG, Platnost YESNO, " & _
                   "Zdroj LONG, Uzivatel TEXT(50), OdpracDoba LONG, Poradie LONG, StavUza YESNO, Poznamka LONGTEXT, CisloPreruseni LONG, " & _
                   "Smer TEXT(1), RucneUpravene YESNO, ZdrojZapisu TEXT(30), UzivatelZmeny TEXT(50), DatumZmeny DATETIME, SnimkaDatum DATETIME)", dbFailOnError
    End If
    If Not mod_00_Common.TabulkaExistuje("DochadzkaAudit") Then
        db.Execute "CREATE TABLE DochadzkaAudit (ID AUTOINCREMENT PRIMARY KEY, DatumCas DATETIME, Uzivatel TEXT(50), OsobneCislo TEXT(20), " & _
                   "Datum DATETIME, Akcia TEXT(30), Popis TEXT(255))", dbFailOnError
    End If
End Sub

'-------------------------------------------------------------------------------
' Pred PRVOU upravou dna: vytvori snimku povodnych razeni a zapise den do registra.
'-------------------------------------------------------------------------------
Private Sub Ed_ZabezpecUpravu(ByRef db As DAO.Database, ByVal strOC As String, ByVal dDen As Date)
    Dim strKrit As String, lPocet As Long

    Call Ed_ZabezpecTabulky(db)
    strKrit = "OsobneCislo = " & Ed_SqlText(strOC) & " AND Datum = " & Ed_SqlDatum(dDen)
    If DCount("*", "DochadzkaUpraveneDni", strKrit) > 0 Then Exit Sub

    lPocet = DCount("*", "DochadzkaImport", strKrit)
    db.Execute "INSERT INTO DochadzkaImportPovodne (IDRazenia, Datum, Cas, DatumSnim, CisPam, DatumPoc, CasPoc, OsobneCislo, KodPrerusenia, " & _
               "Platnost, Zdroj, Uzivatel, OdpracDoba, Poradie, StavUza, Poznamka, CisloPreruseni, Smer, RucneUpravene, ZdrojZapisu, " & _
               "UzivatelZmeny, DatumZmeny, SnimkaDatum) " & _
               "SELECT ID, Datum, Cas, DatumSnim, CisPam, DatumPoc, CasPoc, OsobneCislo, KodPrerusenia, Platnost, Zdroj, Uzivatel, " & _
               "OdpracDoba, Poradie, StavUza, Poznamka, CisloPreruseni, Smer, RucneUpravene, ZdrojZapisu, UzivatelZmeny, DatumZmeny, Now() " & _
               "FROM DochadzkaImport WHERE " & strKrit, dbFailOnError
    db.Execute "INSERT INTO DochadzkaUpraveneDni (OsobneCislo, Datum, Uzivatel, PrvaUprava, PoslednaUprava, PocetPovodnych) VALUES (" & _
               Ed_SqlText(strOC) & ", " & Ed_SqlDatum(dDen) & ", " & Ed_SqlText(Ed_Uzivatel()) & ", Now(), Now(), " & lPocet & ")", dbFailOnError
    Set mUpraveneDni = Nothing
End Sub

Private Sub Ed_ZapisAudit(ByRef db As DAO.Database, ByVal strOC As String, ByVal dDen As Date, ByVal strAkcia As String, ByVal strPopis As String)
    On Error Resume Next
    Call Ed_ZabezpecTabulky(db)
    db.Execute "INSERT INTO DochadzkaAudit (DatumCas, Uzivatel, OsobneCislo, Datum, Akcia, Popis) VALUES (Now(), " & _
               Ed_SqlText(Ed_Uzivatel()) & ", " & Ed_SqlText(strOC) & ", " & Ed_SqlDatum(dDen) & ", " & Ed_SqlText(Left$(strAkcia, 30)) & ", " & _
               Ed_SqlText(Left$(strPopis, 255)) & ")", dbFailOnError
    Call mod_00_Common.ZapisLog("Editor dochádzky", "INFO", strAkcia & " " & strOC & " " & Format$(dDen, "dd.mm.yyyy") & ": " & strPopis)
End Sub

'-------------------------------------------------------------------------------
' OCHRANA UPRAVENYCH DNI PRI OPAKOVANOM IMPORTE (volane z mod_02_DBFImport)
'-------------------------------------------------------------------------------

Public Sub Ed_ResetCacheUpravenychDni()
    Set mUpraveneDni = Nothing
    Call mod_18_Uzavierka.ResetCache
End Sub

Private Sub Ed_NacitajUpraveneDni()
    On Error Resume Next
    Dim rs As DAO.Recordset, k As String
    Set mUpraveneDni = CreateObject("Scripting.Dictionary")
    If Not mod_00_Common.TabulkaExistuje("DochadzkaUpraveneDni") Then Exit Sub
    Set rs = CurrentDb.OpenRecordset("SELECT OsobneCislo, Datum FROM DochadzkaUpraveneDni;", dbOpenSnapshot)
    Do While Not rs.EOF
        k = CStr(rs!OsobneCislo) & "|" & Format$(rs!Datum, "yyyymmdd")
        If Not mUpraveneDni.Exists(k) Then mUpraveneDni.Add k, True
        rs.MoveNext
    Loop
    rs.Close
End Sub

Public Function Ed_JeDenUpraveny(ByVal strOC As String, ByVal vDatum As Variant) As Boolean
    On Error Resume Next
    If mUpraveneDni Is Nothing Then Call Ed_NacitajUpraveneDni
    If IsDate(vDatum) Then
        Ed_JeDenUpraveny = mUpraveneDni.Exists(strOC & "|" & Format$(CDate(vDatum), "yyyymmdd"))
        ' razenia dňa v uzavretom (podpísanom) mesiaci sa chránia rovnako ako ručne upravené dni
        If Not Ed_JeDenUpraveny Then Ed_JeDenUpraveny = mod_18_Uzavierka.JeUzavretyDen(strOC, vDatum)
    End If
End Function

Public Function Ed_SqlVynechUpraveneDni() As String
    Dim strSql As String
    On Error Resume Next
    If mod_00_Common.TabulkaExistuje("DochadzkaUpraveneDni") Then
        If DCount("*", "DochadzkaUpraveneDni") > 0 Then
            strSql = " AND ID NOT IN (SELECT D.ID FROM DochadzkaImport AS D INNER JOIN DochadzkaUpraveneDni AS U " & _
                     "ON (D.OsobneCislo = U.OsobneCislo) AND (D.Datum = U.Datum))"
        End If
    End If
    ' razenia v uzavretých (podpísaných) mesiacoch sa tiež nikdy nemažú ani neprepisujú
    Ed_SqlVynechUpraveneDni = strSql & mod_18_Uzavierka.SqlVynechUzavrete()
End Function

'-------------------------------------------------------------------------------
' GENEROVANIE OKNA DNA (frmEditaciaDnaAdmin)
'-------------------------------------------------------------------------------

' Vygeneruje okno len ak chyba alebo je stara verzia.
Private Sub Ed_ZabezpecDialog()
    If Not mod_00_Common.FormularExistujeDB(FRM_DEN) Then
        Call VytvorFrmEditaciaDnaAdmin
    ElseIf mod_00_Common.GetNastavenie(KLUC_VERZIA_DIALOGU, "") <> VERZIA_DIALOGU Then
        Call VytvorFrmEditaciaDnaAdmin
    End If
End Sub

Public Sub VytvorFrmEditaciaDnaAdmin()
    On Error GoTo ChybaHandler
    Dim frm As Form, strTmp As String, ctl As Control
    Dim vHlav As Variant, vSirky As Variant, i As Long, lX As Long

    On Error Resume Next
    If mod_00_Common.FormIsOpen(FRM_DEN) Then DoCmd.Close acForm, FRM_DEN, acSaveNo
    DoCmd.DeleteObject acForm, FRM_DEN
    Err.Clear
    On Error GoTo ChybaHandler

    Set frm = CreateForm
    strTmp = frm.Name

    With frm
        .Caption = "Prehľad prerušení cez deň - Editor administrátora"
        .RecordSelectors = False
        .NavigationButtons = False
        .DividingLines = False
        .ScrollBars = 0
        .AutoCenter = True
        .PopUp = True
        .Modal = True
        .BorderStyle = 3
        .Width = 10900
        .Section(acDetail).Height = 7600
        .OnClose = "=Ed_DenPoZatvoreni()"
    End With

    ' --- skryte kontextove polia ---
    Set ctl = CreateControl(strTmp, acTextBox, acDetail, "", "", 9000, 20, 600, 250)
    ctl.Name = "txtDlgOC"
    ctl.Visible = False
    Set ctl = CreateControl(strTmp, acTextBox, acDetail, "", "", 9700, 20, 600, 250)
    ctl.Name = "txtDlgDatum"
    ctl.Visible = False

    ' --- hlavicka ---
    Set ctl = CreateControl(strTmp, acLabel, acDetail, "", "", 300, 120, 10300, 330)
    ctl.Name = "lblDatumDna"
    ctl.Caption = "Prehľad prerušení cez deň"
    ctl.FontSize = 12
    ctl.FontBold = True
    ctl.ForeColor = RGB(15, 30, 90)

    Set ctl = CreateControl(strTmp, acLabel, acDetail, "", "", 300, 470, 10300, 280)
    ctl.Name = "lblDenInfo"
    ctl.Caption = ""
    ctl.FontSize = 9

    ' --- hlavicka zoznamu razeni ---
    vHlav = Array("P", "Čas", "Kód", "Názov prerušenia", "Zdroj zápisu", "Užívateľ", "Dátum zápisu", "Čas zápisu")
    vSirky = Array(450, 750, 650, 2600, 1450, 1550, 1300, 950)
    lX = 360
    For i = 0 To 7
        Set ctl = CreateControl(strTmp, acLabel, acDetail, "", "", lX, 800, CLng(vSirky(i)), 250)
        ctl.Caption = CStr(vHlav(i))
        ctl.FontBold = True
        ctl.FontSize = 8
        ctl.BackStyle = 1
        ctl.BackColor = RGB(215, 222, 238)
        lX = lX + CLng(vSirky(i))
    Next i

    Set ctl = CreateControl(strTmp, acListBox, acDetail, "", "", 300, 1060, 10200, 2600)
    ctl.Name = "lstRazenia"
    With ctl
        .RowSourceType = "Value List"
        .ColumnCount = 9
        .ColumnWidths = "0;450;750;650;2600;1450;1550;1300;950"
        .ColumnHeads = False
        .AfterUpdate = "=Ed_DenVyberRiadku()"
        .OnDblClick = "=Ed_DenVyberRiadku()"
    End With

    Set ctl = CreateControl(strTmp, acLabel, acDetail, "", "", 300, 3720, 10200, 560)
    ctl.Name = "lblIntervaly"
    ctl.Caption = ""
    ctl.FontSize = 8
    ctl.ForeColor = RGB(60, 60, 60)

    Set ctl = CreateControl(strTmp, acLabel, acDetail, "", "", 300, 4330, 10200, 420)
    ctl.Name = "lblUpozornenia"
    ctl.Caption = ""
    ctl.FontBold = True

    ' --- uprava razenia ---
    Set ctl = CreateControl(strTmp, acLabel, acDetail, "", "", 300, 4830, 8000, 250)
    ctl.Caption = "Úprava razenia (pri oprave najprv označte riadok v zozname):"
    ctl.FontBold = True
    ctl.ForeColor = RGB(15, 30, 90)

    Set ctl = CreateControl(strTmp, acLabel, acDetail, "", "", 300, 5130, 1250, 300)
    ctl.Caption = "Kód razenia:"

    Set ctl = CreateControl(strTmp, acComboBox, acDetail, "", "", 1600, 5100, 3600, 300)
    ctl.Name = "cboKod"
    With ctl
        .RowSourceType = "Table/Query"
        .RowSource = "SELECT KodRazenia, KodRazenia & ' - ' & TextRazenia AS Popis FROM KodyRazeni ORDER BY KodRazenia;"
        .ColumnCount = 2
        .ColumnWidths = "0;3600"
        .BoundColumn = 1
        .LimitToList = True
    End With

    Set ctl = CreateControl(strTmp, acLabel, acDetail, "", "", 5400, 5130, 1250, 300)
    ctl.Caption = "Čas (hh:mm):"

    Set ctl = CreateControl(strTmp, acTextBox, acDetail, "", "", 6700, 5100, 900, 300)
    ctl.Name = "txtCas"

    Set ctl = CreateControl(strTmp, acCommandButton, acDetail, "", "", 300, 5500, 1900, 360)
    ctl.Name = "btnPridajRazenie"
    ctl.Caption = "&Pridať razenie"
    ctl.OnClick = "=Ed_DenPridajRazenie()"

    Set ctl = CreateControl(strTmp, acCommandButton, acDetail, "", "", 2300, 5500, 2000, 360)
    ctl.Name = "btnOpravRazenie"
    ctl.Caption = "&Opraviť označené"
    ctl.OnClick = "=Ed_DenOpravRazenie()"

    Set ctl = CreateControl(strTmp, acCommandButton, acDetail, "", "", 4400, 5500, 1900, 360)
    ctl.Name = "btnZrusRazenie"
    ctl.Caption = "&Zrušiť označené"
    ctl.OnClick = "=Ed_DenZrusRazenie()"

    Set ctl = CreateControl(strTmp, acCommandButton, acDetail, "", "", 6400, 5500, 2400, 360)
    ctl.Name = "btnPlatnost"
    ctl.Caption = "Stav pla&tnosti"
    ctl.OnClick = "=Ed_DenPlatnost()"

    ' --- prerusenie (par) ---
    Set ctl = CreateControl(strTmp, acLabel, acDetail, "", "", 300, 6030, 1500, 300)
    ctl.Caption = "Prerušenie (pár):"
    ctl.FontBold = True

    Set ctl = CreateControl(strTmp, acComboBox, acDetail, "", "", 1850, 6000, 3300, 300)
    ctl.Name = "cboPrerusenie"
    With ctl
        .RowSourceType = "Table/Query"
        .RowSource = "SELECT Cislo, Cislo & ' - ' & Nazov AS Popis FROM CiselnikPreruseni ORDER BY Cislo;"
        .ColumnCount = 2
        .ColumnWidths = "0;3300"
        .BoundColumn = 1
        .LimitToList = True
    End With

    Set ctl = CreateControl(strTmp, acLabel, acDetail, "", "", 5300, 6030, 400, 300)
    ctl.Caption = "od:"

    Set ctl = CreateControl(strTmp, acTextBox, acDetail, "", "", 5700, 6000, 800, 300)
    ctl.Name = "txtParOd"

    Set ctl = CreateControl(strTmp, acLabel, acDetail, "", "", 6650, 6030, 400, 300)
    ctl.Caption = "do:"

    Set ctl = CreateControl(strTmp, acTextBox, acDetail, "", "", 7050, 6000, 800, 300)
    ctl.Name = "txtParDo"

    Set ctl = CreateControl(strTmp, acCommandButton, acDetail, "", "", 8000, 5960, 2300, 360)
    ctl.Name = "btnPridajPar"
    ctl.Caption = "Pridať pr&erušenie (pár)"
    ctl.OnClick = "=Ed_DenPridajPar()"

    ' --- spodne tlacidla ---
    Set ctl = CreateControl(strTmp, acCommandButton, acDetail, "", "", 300, 6550, 2200, 380)
    ctl.Name = "btnPovodnyDen"
    ctl.Caption = "Pô&vodný deň"
    ctl.OnClick = "=Ed_DenPovodnyDen()"

    Set ctl = CreateControl(strTmp, acCommandButton, acDetail, "", "", 2600, 6550, 1800, 380)
    ctl.Name = "btnPrepocitaj"
    ctl.Caption = "P&repočítať"
    ctl.OnClick = "=Ed_DenPrepocitaj()"

    Set ctl = CreateControl(strTmp, acCommandButton, acDetail, "", "", 8700, 6550, 1800, 380)
    ctl.Name = "btnKoniec"
    ctl.Caption = "&Koniec"
    ctl.Cancel = True
    ctl.OnClick = "=Ed_DenKoniec()"

    Set ctl = CreateControl(strTmp, acLabel, acDetail, "", "", 300, 7050, 10200, 420)
    ctl.Caption = "P: + platné, - neplatné.  Zdroj zápisu: Import = z terminálu/DBF, Ručne (nové) = pridané tu, Upravené = opravené tu. " & _
                  "Všetky zmeny sa zapisujú do tabuľky DochadzkaAudit; Pôvodný deň vráti stav pred prvou úpravou."
    ctl.FontSize = 8
    ctl.ForeColor = RGB(90, 90, 90)

    ' odstráni pripojené popisky polí a prispôsobí písmo (aby nebol text orezaný)
    Call mod_UI_Spolocne.NormalizujFormular(frm)

    DoCmd.Save acForm, strTmp
    DoCmd.Close acForm, strTmp, acSaveYes
    DoCmd.Rename FRM_DEN, acForm, strTmp

    Call mod_00_Common.SetNastavenie(KLUC_VERZIA_DIALOGU, VERZIA_DIALOGU, "Verzia okna editora dna (frmEditaciaDnaAdmin)")
    Exit Sub
ChybaHandler:
    On Error Resume Next
    If Len(strTmp) > 0 Then DoCmd.Close acForm, strTmp, acSaveNo
    Call mod_00_Common.ZapisLog("VytvorFrmEditaciaDnaAdmin", "ERROR", Err.Description)
    MsgBox "Okno dňa sa nepodarilo vytvoriť: " & Err.Description, vbCritical, "Editor dochádzky"
End Sub

'-------------------------------------------------------------------------------
' Odstrani zastaraly podformular subOrdataDni z predchadzajucej verzie editora.
'-------------------------------------------------------------------------------
Public Sub VytvorSubformOrdataDni()
    On Error Resume Next
    If mod_00_Common.FormIsOpen("subOrdataDni") Then DoCmd.Close acForm, "subOrdataDni", acSaveNo
    If mod_00_Common.FormularExistujeDB("subOrdataDni") Then DoCmd.DeleteObject acForm, "subOrdataDni"
    Err.Clear
End Sub

Public Sub VytvorKompletneUIEditacie()
    On Error GoTo ChybaHandler
    Call VytvorSubformOrdataDni
    Call VytvorFrmEditaciaDnaAdmin
    MsgBox "Okno dňa bolo vygenerované. Záložku editora vytvorí RekonštruujHlavnuKonzolu (mod_UI_Core).", vbInformation, "UI Editácia Dochádzky"
    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("VytvorKompletneUIEditacie", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' POMOCNE FUNKCIE
'-------------------------------------------------------------------------------

' Rozparsuje cas zadany ako 7:05, 07:05, 7.05, 7,05, 705, 0705 alebo 7 (= 07:00).
Public Function Ed_ParseCas(ByVal strVstup As String, ByRef lMin As Long) As Boolean
    Dim t As String, p As Long, sH As String, sM As String, h As Long, m As Long

    t = Trim$(strVstup)
    t = Replace(t, " ", "")
    t = Replace(t, ".", ":")
    t = Replace(t, ",", ":")
    If Len(t) = 0 Then Exit Function

    p = InStr(t, ":")
    If p > 0 Then
        sH = Left$(t, p - 1)
        sM = Mid$(t, p + 1)
        If Len(sM) = 0 Then sM = "0"
    Else
        Select Case Len(t)
            Case 1, 2
                sH = t
                sM = "0"
            Case 3
                sH = Left$(t, 1)
                sM = Mid$(t, 2)
            Case 4
                sH = Left$(t, 2)
                sM = Mid$(t, 3)
            Case Else
                Exit Function
        End Select
    End If

    If Not Ed_SamyCislice(sH) Or Not Ed_SamyCislice(sM) Then Exit Function
    If Len(sH) > 2 Or Len(sM) > 2 Then Exit Function
    h = CLng(sH)
    m = CLng(sM)
    If h < 0 Or h > 23 Or m < 0 Or m > 59 Then Exit Function

    lMin = h * 60 + m
    Ed_ParseCas = True
End Function

Private Function Ed_SamyCislice(ByVal s As String) As Boolean
    Dim i As Long
    If Len(s) = 0 Then Exit Function
    For i = 1 To Len(s)
        If Mid$(s, i, 1) < "0" Or Mid$(s, i, 1) > "9" Then Exit Function
    Next i
    Ed_SamyCislice = True
End Function

' Minuty -> hh:mm (bez znamienka; hodiny aj nad 99).
Public Function Ed_HM(ByVal lMin As Long) As String
    Ed_HM = Format$(Abs(lMin) \ 60, "00") & ":" & Format$(Abs(lMin) Mod 60, "00")
End Function

' Minuty -> hh:mm so znamienkom "- " pre zaporne hodnoty.
Public Function Ed_HMZ(ByVal lMin As Long) As String
    Ed_HMZ = IIf(lMin < 0, "- ", "") & Ed_HM(lMin)
End Function

Private Function Ed_Bunka(ByVal s As String) As String
    Ed_Bunka = Chr$(34) & Replace(Replace(s, Chr$(34), "'"), ";", ",") & Chr$(34)
End Function

Private Function Ed_SqlDatum(ByVal d As Date) As String
    Ed_SqlDatum = mod_00_Common.SqlDatum(d)
End Function

Private Function Ed_SqlText(ByVal s As String) As String
    Ed_SqlText = mod_00_Common.SqlText(s)
End Function

Private Function Ed_Uzivatel() As String
    Ed_Uzivatel = mod_00_Common.Uzivatel()
End Function

Private Function Ed_DenTyzdna(ByVal d As Date) As String
    Ed_DenTyzdna = Choose(Weekday(d, vbMonday), "po", "ut", "st", "št", "pi", "so", "ne")
End Function

Private Function Ed_DenTyzdnaPlny(ByVal d As Date) As String
    Ed_DenTyzdnaPlny = Choose(Weekday(d, vbMonday), "pondelok", "utorok", "streda", "štvrtok", "piatok", "sobota", "nedeľa")
End Function

Private Function Ed_DatumText(ByVal v As Variant) As String
    If IsNull(v) Then Exit Function
    If IsDate(v) Then Ed_DatumText = Format$(CDate(v), "dd.mm.yyyy")
End Function

Private Function Ed_CasZapisuText(ByVal v As Variant) As String
    If IsNull(v) Then Exit Function
    If IsNumeric(v) Then Ed_CasZapisuText = Ed_HM(CLng(v))
End Function

Private Function Ed_MenoZam(ByVal strOC As String) As String
    On Error Resume Next
    Dim vP As Variant, vM As Variant
    vP = DLookup("Priezvisko", "Zamestnanci", "OsobneCislo = " & Ed_SqlText(strOC))
    vM = DLookup("Meno", "Zamestnanci", "OsobneCislo = " & Ed_SqlText(strOC))
    Ed_MenoZam = Trim$(CStr(Nz(vP, "")) & " " & CStr(Nz(vM, "")))
End Function

' Priemerny denny fond (min) zamestnanca v danom mesiaci - na zapocitanie sviatkov (jednotna logika v mod_08).
Private Function Ed_PriemernyFond(ByVal strOC As String, ByVal iRok As Long, ByVal iMes As Long) As Long
    On Error Resume Next
    Ed_PriemernyFond = mod_08_UdalostiDna.FondZamestnanca(CurrentDb, strOC, CInt(iRok), CInt(iMes))
    If Ed_PriemernyFond <= 0 Then Ed_PriemernyFond = 450
End Function

' Slovnik kod razenia -> text (KodyRazeni).
Private Function Ed_NacitajKody(ByRef db As DAO.Database) As Object
    Dim dic As Object, rs As DAO.Recordset
    Set dic = CreateObject("Scripting.Dictionary")
    On Error Resume Next
    Set rs = db.OpenRecordset("SELECT KodRazenia, TextRazenia FROM KodyRazeni;", dbOpenSnapshot)
    Do While Not rs.EOF
        dic(CLng(rs!KodRazenia)) = CStr(Nz(rs!TextRazenia, ""))
        rs.MoveNext
    Loop
    rs.Close
    Set Ed_NacitajKody = dic
End Function

' Slovnik cislo prerusenia -> skratka (CiselnikPreruseni).
Private Function Ed_NacitajSkratky(ByRef db As DAO.Database) As Object
    Dim dic As Object, rs As DAO.Recordset
    Set dic = CreateObject("Scripting.Dictionary")
    On Error Resume Next
    Set rs = db.OpenRecordset("SELECT Cislo, NazovSkratka, Nazov FROM CiselnikPreruseni;", dbOpenSnapshot)
    Do While Not rs.EOF
        dic(CLng(rs!Cislo)) = CStr(Nz(rs!NazovSkratka, Nz(rs!Nazov, "")))
        rs.MoveNext
    Loop
    rs.Close
    Set Ed_NacitajSkratky = dic
End Function
