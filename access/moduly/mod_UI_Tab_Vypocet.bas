Attribute VB_Name = "mod_UI_Tab_Vypocet"
'@Verzia 2.9.0
Option Compare Database
Option Explicit

' ==============================================================================
' MODUL: mod_UI_Tab_Vypocet
' POPIS: Sub-modul pre záložku 6 - Výpočet dochádzky a generovanie zostáv.
'        Obdobie sa vyberá zo zoznamu mesiacov (tlačidlá < > posúvajú o mesiac).
'        Zamestnanci: výber v zozname ALEBO zadanie osobných čísel textom (ľubovoľný oddeľovač, rozsahy).
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - IsAvailable / GetTabCaption / BuildUI / InitDefaults : Štandardné rozhranie záložky.
' - ObnovZoznamZamestnancovUI()   : Obnoví zoznam zamestnancov pre zvolený mesiac.
' - VypocetMesiacPredUI / VypocetMesiacDalsiUI : Posun obdobia o mesiac.
' - SpustiVypocetUI()             : Prepočet dochádzky vybraných / zadaných / všetkých zamestnancov.
' - SpustiZostavuUI()             : Tlačová zostava pre vybraných / zadaných / všetkých zamestnancov.
' - ObnovInfoUzavierky()          : Obnoví text o uzavretých mesiacoch (tlačidlo Uzávierka mesiaca otvorí okno z mod_UI_Uzavierka).
' ==============================================================================

Public Function IsAvailable() As Boolean
    IsAvailable = True
End Function

Public Function GetTabCaption() As String
    GetTabCaption = "6. Výpočet & Zostavy"
End Function

Public Sub BuildUI(ByVal strFrmName As String, ByVal strPageName As String)
    On Error GoTo ChybaHandler
    Dim ctl As Control, btn As Control

    ' Nadpis sekcie
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 1100, 9500, 300)
    ctl.Caption = "Prepočet dochádzky zamestnancov a tlač mesačných výkazov"
    ctl.FontBold = True: ctl.FontSize = 10: ctl.ForeColor = RGB(15, 30, 90)

    ' --- 1. SEKCIA: OBDOBIE ---
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 1550, 1800, 300)
    ctl.Caption = "Mesiac:"
    ctl.FontBold = True
    Call mod_UI_Spolocne.VytvorVyberMesiaca(strFrmName, strPageName, "cboVypocetObdobie", 2400, 1520, 2400, "=ObnovZoznamZamestnancovUI()")

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 4900, 1520, 400, 330)
    btn.Name = "btnVypocetMesPred"
    btn.Caption = "<": btn.FontBold = True
    btn.ControlTipText = "Predchádzajúci mesiac"
    btn.OnClick = "=VypocetMesiacPredUI()"
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 5350, 1520, 400, 330)
    btn.Name = "btnVypocetMesDalsi"
    btn.Caption = ">": btn.FontBold = True
    btn.ControlTipText = "Nasledujúci mesiac"
    btn.OnClick = "=VypocetMesiacDalsiUI()"

    ' --- 2. SEKCIA: ZAMESTNANCI ---
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 2000, 9500, 250)
    ctl.Caption = "Zamestnanci s razeniami v mesiaci (označte jedného alebo viacerých - Ctrl/Shift):"
    ctl.FontBold = True

    Set ctl = CreateControl(strFrmName, acListBox, acDetail, strPageName, "", 500, 2300, 9500, 2200)
    ctl.Name = "lstOsobneCisla"
    With ctl
        .MultiSelect = 2 ' Extended multi-select
        .ColumnCount = 2
        .ColumnWidths = "1800;7000"
        .ColumnHeads = False
        .RowSourceType = "Table/Query"
        .RowSource = mod_00_Common.ZiskajSQLZoznamZamestnancov()
    End With

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 4600, 2300, 300)
    ctl.Caption = "alebo osobné čísla:"
    ctl.FontBold = True
    Set ctl = CreateControl(strFrmName, acTextBox, acDetail, strPageName, "", 2800, 4580, 7200, 330)
    ctl.Name = "txtVypocetOC"
    ctl.ControlTipText = "Napr. 1234, 1240; 1301-1310 - oddeľovač sa rozpozná sám. Ak je pole vyplnené, zoznam vyššie sa ignoruje."

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 4950, 9500, 250)
    ctl.Caption = "Poradie: vyplnené osobné čísla > označení v zozname > VŠETCI zamestnanci. Oddeľovač ľubovoľný (čiarka, bodkočiarka, medzera, nový riadok), rozsah 1001-1010."
    ctl.FontSize = 8: ctl.ForeColor = RGB(100, 100, 100)

    ' --- 3. SEKCIA: TLAČIDLÁ PRE AKCIE ---
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 5350, 9500, 600)
    btn.Name = "btnSpustitVypocet"
    btn.Caption = "SPUSTIŤ PREPOČET DOCHÁDZKY A SALDA"
    btn.FontBold = True: btn.FontSize = 10: btn.ForeColor = RGB(0, 100, 0)
    btn.OnClick = "=SpustiVypocetUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 6050, 9500, 600)
    btn.Name = "btnOtvoritZostavu"
    btn.Caption = "ZOBRAZIŤ TLAČOVÚ ZOSTAVU (Záznam o dochádzke)"
    btn.FontBold = True: btn.FontSize = 10: btn.ForeColor = RGB(15, 30, 90)
    btn.OnClick = "=SpustiZostavuUI()"

    ' --- 4. SEKCIA: UZÁVIERKA MESIACA (zámok po vytlačení a podpise zostavy) ---
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 6850, 9500, 280)
    ctl.Caption = "Uzávierka mesiaca - po vytlačení a podpise zostavy mesiac zamknite proti zmenám"
    ctl.FontBold = True: ctl.FontSize = 10: ctl.ForeColor = RGB(15, 30, 90)

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 7180, 9500, 480)
    ctl.Name = "lblUzInfo"
    ctl.Caption = ""
    ctl.FontSize = 8: ctl.ForeColor = RGB(60, 60, 60)

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 7700, 9500, 600)
    btn.Name = "btnUzavierkaMesiaca"
    btn.Caption = "UZÁVIERKA MESIACA (potvrdenie podpísanej zostavy, otvorenie, kontrola)"
    btn.FontBold = True: btn.FontSize = 10: btn.ForeColor = RGB(120, 30, 30)
    btn.OnClick = "=Uz_OtvorOknoUI()"

    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Vypocet.BuildUI", "ERROR", Err.Description)
End Sub

Public Sub InitDefaults(ByRef frm As Form)
    On Error Resume Next
    Dim d As Date
    d = DateAdd("m", -1, Date)
    Call mod_UI_Spolocne.NastavVyberMesiaca(frm!cboVypocetObdobie, Year(d), Month(d))
    frm!txtVypocetOC = Null
    Call ObnovZoznamZamestnancovUI
End Sub

'-------------------------------------------------------------------------------
' Obnoví informáciu o uzavretých mesiacoch (popisok pod zoznamom) pre mesiac zvolený na karte.
'-------------------------------------------------------------------------------
Public Function ObnovInfoUzavierky() As Boolean
    On Error Resume Next
    Dim lRok As Long, lMes As Long
    If Not mod_00_Common.FormIsOpen("frmHlavnaKonzola") Then Exit Function
    Call mod_UI_Spolocne.ObdobieZVyberu(Forms!frmHlavnaKonzola!cboVypocetObdobie, lRok, lMes)
    Forms!frmHlavnaKonzola!lblUzInfo.Caption = mod_UI_Uzavierka.TextInfoUzavierky(lRok, lMes)
    ObnovInfoUzavierky = True
End Function

' ==============================================================================
' EVENT HANDLERY A REQUERY LOGIKA
' ==============================================================================

Public Function VypocetMesiacPredUI()
    On Error Resume Next
    Call mod_UI_Spolocne.PosunVyberMesiaca(Forms!frmHlavnaKonzola!cboVypocetObdobie, -1)
    Call ObnovZoznamZamestnancovUI
End Function

Public Function VypocetMesiacDalsiUI()
    On Error Resume Next
    Call mod_UI_Spolocne.PosunVyberMesiaca(Forms!frmHlavnaKonzola!cboVypocetObdobie, 1)
    Call ObnovZoznamZamestnancovUI
End Function

Public Function ObnovZoznamZamestnancovUI()
    On Error GoTo ChybaHandler
    Dim frm As Form, lRok As Long, lMes As Long
    If Not mod_00_Common.FormIsOpen("frmHlavnaKonzola") Then Exit Function
    Set frm = Forms!frmHlavnaKonzola

    If mod_UI_Spolocne.ObdobieZVyberu(frm!cboVypocetObdobie, lRok, lMes) Then
        frm!lstOsobneCisla.RowSource = mod_00_Common.ZiskajSQLZoznamZamestnancov(DateSerial(lRok, lMes, 1), DateSerial(lRok, lMes + 1, 0))
    Else
        frm!lstOsobneCisla.RowSource = mod_00_Common.ZiskajSQLZoznamZamestnancov()
    End If
    frm!lstOsobneCisla.Requery
    Call ObnovInfoUzavierky
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("ObnovZoznamZamestnancovUI", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Prečíta obdobie a zoznam osobných čísel (SQL zoznam; "" = všetci). Vráti False, ak sa nemá pokračovať.
'-------------------------------------------------------------------------------
Private Function NacitajVolby(ByRef lRok As Long, ByRef lMes As Long, ByRef strOcSQL As String, ByRef strPopis As String) As Boolean
    Dim frm As Form, strText As String, strNez As String, lPocet As Long
    Set frm = Forms!frmHlavnaKonzola

    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboVypocetObdobie, lRok, lMes) Then
        MsgBox "Vyberte mesiac zo zoznamu.", vbExclamation, "Výpočet dochádzky"
        Exit Function
    End If

    strText = Trim$(Nz(frm!txtVypocetOC, ""))
    If Len(strText) > 0 Then
        strOcSQL = mod_UI_Spolocne.OsobneCislaSql(strText, strNez, lPocet)
        If lPocet = 0 Then
            MsgBox "V poli osobných čísel sa nenašlo žiadne číslo.", vbExclamation, "Výpočet dochádzky"
            Exit Function
        End If
        If Len(strNez) > 0 Then
            If MsgBox("Tieto osobné čísla nie sú v zozname zamestnancov:" & vbCrLf & Left$(strNez, 500) & vbCrLf & vbCrLf & _
                      "Pokračovať s ostatnými?", vbQuestion + vbYesNo, "Výpočet dochádzky") <> vbYes Then Exit Function
        End If
        strPopis = lPocet & " zadaných zamestnancov"
    Else
        strOcSQL = mod_00_Common.ZiskajVybraneOsobneCislaListBox(frm!lstOsobneCisla)
        If Len(strOcSQL) > 0 Then
            strPopis = frm!lstOsobneCisla.ItemsSelected.Count & " označených zamestnancov"
        Else
            strPopis = "VŠETCI zamestnanci"
        End If
    End If
    NacitajVolby = True
End Function

Public Function SpustiVypocetUI() As Boolean
    On Error GoTo ChybaHandler
    Dim lRok As Long, lMes As Long, strOcSQL As String, strPopis As String
    Dim db As DAO.Database, rs As DAO.Recordset, pocet As Long, strSQL As String

    If Not NacitajVolby(lRok, lMes, strOcSQL, strPopis) Then Exit Function
    If Len(strOcSQL) = 0 Then
        If MsgBox("Prepočítať dochádzku za " & mod_UI_Spolocne.NazovMesiaca(lMes) & " " & lRok & " pre VŠETKÝCH zamestnancov?", vbQuestion + vbYesNo, "Výpočet dochádzky") <> vbYes Then Exit Function
        strSQL = "SELECT OsobneCislo FROM Zamestnanci WHERE OsobneCislo IS NOT NULL AND " & mod_15_Zamestnanci.SqlAktivny("", DateSerial(lRok, lMes, 1)) & ";"
    Else
        strSQL = "SELECT DISTINCT OsobneCislo FROM Zamestnanci WHERE CStr(OsobneCislo) IN (" & strOcSQL & ");"
    End If

    Set db = CurrentDb
    Set rs = db.OpenRecordset(strSQL, dbOpenSnapshot)
    DoCmd.Hourglass True
    Do While Not rs.EOF
        SysCmd acSysCmdSetStatus, "Prepočet " & mod_UI_Spolocne.NazovMesiaca(lMes) & " " & lRok & ": " & rs!OsobneCislo
        Call modMesaatnaDochadzka.PrecalculujDochadzkuBezZostavy(CStr(rs!OsobneCislo), CInt(lRok), CInt(lMes))
        pocet = pocet + 1
        rs.MoveNext
    Loop
    rs.Close: Set rs = Nothing: Set db = Nothing
    DoCmd.Hourglass False
    SysCmd acSysCmdClearStatus
    MsgBox "Prepočet dochádzky za " & mod_UI_Spolocne.NazovMesiaca(lMes) & " " & lRok & " bol dokončený (" & pocet & " zamestnancov; " & strPopis & ").", vbInformation, "Hotovo"

    SpustiVypocetUI = True
    Exit Function
ChybaHandler:
    DoCmd.Hourglass False
    SysCmd acSysCmdClearStatus
    MsgBox "Chyba pri prepočte dochádzky: " & Err.Description, vbCritical
    SpustiVypocetUI = False
End Function

Public Function SpustiZostavuUI() As Boolean
    On Error GoTo ChybaHandler
    Dim lRok As Long, lMes As Long, strOcSQL As String, strPopis As String

    If Not NacitajVolby(lRok, lMes, strOcSQL, strPopis) Then Exit Function
    Call modMesaatnaDochadzka.SpracujAOtvorZostavuMulti(strOcSQL, CInt(lRok), CInt(lMes), "rptMesaatnaDochadzka")
    SpustiZostavuUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri generovaní tlačovej zostavy: " & Err.Description, vbCritical
    SpustiZostavuUI = False
End Function
