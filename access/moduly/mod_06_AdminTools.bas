Attribute VB_Name = "mod_06_AdminTools"
'@Verzia 2.6.1
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_06_AdminTools
' POPIS: Správa vývojárskych a diagnostických nástrojov, čistení pomocných tabuliek,
'        anonymizácie Access tabuliek, dávkových exportov pre AI analýzu,
'        exportu metadát tabuliek (JSON schema), indexu VBA architektúry,
'        produkčnej JSON konfigurácie (dochs_config.json) a testovacej vzorky
'        pípnutí/výpočtu (dochs_test_sample.json) pre Lovable Cloud.
'        Tento modul a jeho okno sú pri štandardnej prevádzke skryté (DevMode=0).
'===============================================================================

Private mStream As Object
Private Const MAX_DLZKA_HODNOTY As Long = 500
Private Const VERZIA_FORMULARA As String = "1.0.4"

'-------------------------------------------------------------------------------
' Kontroluje, či je systém vo vývojárskom / testovacom režime.
'-------------------------------------------------------------------------------
Public Function JeDevMode() As Boolean
    JeDevMode = (mod_00_Common.GetNastavenie("DevMode", "0") = "1")
End Function

'-------------------------------------------------------------------------------
' Zapína alebo vypína vývojársky / testovací režim a zapisuje stav do nastavení.
'-------------------------------------------------------------------------------
Public Function NastavDevMode(ByVal Zapnut As Boolean) As Boolean
    Call mod_00_Common.SetNastavenie("DevMode", IIf(Zapnut, "1", "0"), "Testovací a vývojársky režim (1=Zapnuté, 0=Vypnuté)")
    Call mod_00_Common.ZapisLog("DevMode", "INFO", "Vývojársky režim nastavený na: " & IIf(Zapnut, "ZAPNUTÝ", "VYPNUTÝ"))
    NastavDevMode = Zapnut
End Function

'-------------------------------------------------------------------------------
' Vstupný bod pre otvorenie okna vývojárskych nástrojov. Ak nie je zapnutý Dev Mode, požiada o aktiváciu.
'-------------------------------------------------------------------------------
Public Function OtvorAdminNastroje()
    On Error GoTo ChybaHandler

    If Not JeDevMode() Then
        Dim strOdpoved As VbMsgBoxResult
        strOdpoved = MsgBox("Vývojársky a testovací panel je momentálne SKRYTÝ." & vbCrLf & vbCrLf & _
                            "Chcete zapnúť vývojársky / testovací režim a otvoriť admin nástroje?", _
                            vbQuestion + vbYesNo, "Aktivácia vývojárskeho režimu")
        If strOdpoved = vbYes Then
            Call NastavDevMode(True)
        Else
            Exit Function
        End If
    End If

    Dim jeAktualny As Boolean: jeAktualny = False
    If mod_00_Common.FormularExistujeDB("frmAdminNastroje") Then
        If Not mod_00_Common.FormIsOpen("frmAdminNastroje") Then
            On Error Resume Next
            DoCmd.OpenForm "frmAdminNastroje", acNormal, , , , acHidden
            On Error GoTo ChybaHandler
        End If

        If mod_00_Common.FormIsOpen("frmAdminNastroje") Then
            If Forms!frmAdminNastroje.Tag = VERZIA_FORMULARA Then jeAktualny = True
        End If
    End If

    If jeAktualny Then
        DoCmd.OpenForm "frmAdminNastroje"
        Forms!frmAdminNastroje.Visible = True
        Call AktualizujZoznamZamestnancovGUI
    Else
        Call VytvorFrmAdminNastroje
    End If
    Exit Function

ChybaHandler:
    MsgBox "Nepodarilo sa otvoriť administrátorské nástroje: " & Err.Description, vbCritical, "Chyba"
End Function

'-------------------------------------------------------------------------------
' Generuje a nastavuje kompletný formulár pre vývojársky a testovací panel (frmAdminNastroje).
'-------------------------------------------------------------------------------
Public Sub VytvorFrmAdminNastroje()
    On Error GoTo ChybaHandler
    Dim frm As Form, TmpName As String
    Dim ctl As Control, btn As Control
    Dim strErr As String

    On Error Resume Next
    If mod_00_Common.FormIsOpen("frmAdminNastroje") Then DoCmd.Close acForm, "frmAdminNastroje", acSaveNo
    DoCmd.DeleteObject acForm, "frmAdminNastroje"
    On Error GoTo ChybaHandler

    Set frm = CreateForm
    TmpName = frm.Name

    With frm
        .Caption = "Vývojársky & Testovací Admin Panel [DEV MODE]"
        .Tag = VERZIA_FORMULARA
        .RecordSelectors = False
        .NavigationButtons = False
        .DividingLines = True
        .ScrollBars = 2
        .AutoCenter = True
        .Width = 9800
        .Section(acDetail).Height = 12200
    End With

    Set ctl = CreateControl(TmpName, acLabel, acDetail, , "", 400, 200, 9000, 400)
    ctl.Caption = "Vývojársky & Testovací Panel - Exporty pre AI & Diagnostika"
    ctl.FontSize = 13: ctl.FontBold = True: ctl.ForeColor = RGB(15, 30, 90)

    Set ctl = CreateControl(TmpName, acLabel, acDetail, , "", 400, 700, 4000, 250)
    ctl.Caption = "Adresár DBF (zdroj):": ctl.FontBold = True
    Set ctl = CreateControl(TmpName, acTextBox, acDetail, , "", 400, 950, 7000, 350)
    ctl.Name = "txtCestaImport"
    Set btn = CreateControl(TmpName, acCommandButton, acDetail, , "", 7500, 950, 1900, 350)
    btn.Name = "btnVyberImport": btn.Caption = "Prechádzať...": btn.OnClick = "=VyberAdresarImportGUI()"

    Set ctl = CreateControl(TmpName, acLabel, acDetail, , "", 400, 1350, 5000, 250)
    ctl.Caption = "Cieľový adresár pre výstupné súbory (TXT / JSON):": ctl.FontBold = True
    Set ctl = CreateControl(TmpName, acTextBox, acDetail, , "", 400, 1600, 7000, 350)
    ctl.Name = "txtCestaExport"
    Set btn = CreateControl(TmpName, acCommandButton, acDetail, , "", 7500, 1600, 1900, 350)
    btn.Name = "btnVyberExport": btn.Caption = "Prechádzať...": btn.OnClick = "=VyberAdresarExportGUI()"

    Set ctl = CreateControl(TmpName, acLine, acDetail, , "", 400, 2050, 9000, 0)

    Set ctl = CreateControl(TmpName, acLabel, acDetail, , "", 400, 2150, 7000, 250)
    ctl.Caption = "Filtrácia obdobia pre exporty a vzorku (konkrétny rozsah dátumov):": ctl.FontBold = True: ctl.ForeColor = RGB(120, 30, 0)

    Set ctl = CreateControl(TmpName, acLabel, acDetail, , "", 400, 2450, 1200, 250)
    ctl.Caption = "Dátum od:"
    Set ctl = CreateControl(TmpName, acTextBox, acDetail, , "", 1600, 2400, 2200, 350)
    ctl.Name = "txtDatumOd": ctl.Format = "Short Date"
    On Error Resume Next
    ctl.ShowDatePicker = 1
    On Error GoTo ChybaHandler
    ctl.AfterUpdate = "=AktualizujZoznamZamestnancovGUI()"

    Set ctl = CreateControl(TmpName, acLabel, acDetail, , "", 4100, 2450, 1000, 250)
    ctl.Caption = "Dátum do:"
    Set ctl = CreateControl(TmpName, acTextBox, acDetail, , "", 5200, 2400, 2200, 350)
    ctl.Name = "txtDatumDo": ctl.Format = "Short Date"
    On Error Resume Next
    ctl.ShowDatePicker = 1
    On Error GoTo ChybaHandler
    ctl.AfterUpdate = "=AktualizujZoznamZamestnancovGUI()"

    Set ctl = CreateControl(TmpName, acLabel, acDetail, , "", 7500, 2450, 2000, 250)
    ctl.Caption = "(prázdne = všetky dáta)": ctl.FontSize = 8: ctl.ForeColor = RGB(100, 100, 100)

    Set ctl = CreateControl(TmpName, acLabel, acDetail, , "", 400, 2900, 2700, 250)
    ctl.Caption = "Max. riadkov na tabuľku/súbor:"
    Set ctl = CreateControl(TmpName, acTextBox, acDetail, , "", 3100, 2850, 1200, 350)
    ctl.Name = "txtMaxRiadkov"
    Set ctl = CreateControl(TmpName, acLabel, acDetail, , "", 4500, 2900, 5000, 250)
    ctl.Caption = "(0 = všetky riadky; odporúčané 300 pre úsporu tokenov)": ctl.FontSize = 8: ctl.ForeColor = RGB(100, 100, 100)

    Set ctl = CreateControl(TmpName, acLine, acDetail, , "", 400, 3350, 9000, 0)

    ' TLAČIDLÁ MIGRÁCIE A EXPORTU
    Set btn = CreateControl(TmpName, acCommandButton, acDetail, , "", 400, 3500, 4300, 550)
    btn.Name = "btnExportIndex": btn.Caption = "0. EXPORT INDEXU ARCHITEKTÚRY" & vbCrLf & "(0_INDEX_VBA_STRUKTURA.txt)": btn.FontBold = True: btn.ForeColor = RGB(130, 0, 120): btn.OnClick = "=SpustiExportIndexGUI()"

    Set btn = CreateControl(TmpName, acCommandButton, acDetail, , "", 5100, 3500, 4300, 550)
    btn.Name = "btnExportVBA": btn.Caption = "1. EXPORT IBA VBA KÓDU" & vbCrLf & "(1_VBA_KOD_ANALYZAM.txt)": btn.FontBold = True: btn.ForeColor = RGB(0, 50, 150): btn.OnClick = "=SpustiExportVBAGUI()"

    Set btn = CreateControl(TmpName, acCommandButton, acDetail, , "", 400, 4150, 4300, 550)
    btn.Name = "btnExportAccess": btn.Caption = "2. EXPORT IBA ACCESS TABULIEK" & vbCrLf & "(2_DATA_ACCESS_ANALYZAM.txt)": btn.FontBold = True: btn.ForeColor = RGB(0, 100, 120): btn.OnClick = "=SpustiExportAccessGUI()"

    Set btn = CreateControl(TmpName, acCommandButton, acDetail, , "", 5100, 4150, 4300, 550)
    btn.Name = "btnExportDBF": btn.Caption = "3. EXPORT IBA DBF SÚBOROV" & vbCrLf & "(3_DATA_DBF_ANALYZAM.txt)": btn.FontBold = True: btn.ForeColor = RGB(150, 80, 0): btn.OnClick = "=SpustiExportDbfGUI()"

    Set btn = CreateControl(TmpName, acCommandButton, acDetail, , "", 400, 4800, 4300, 550)
    btn.Name = "btnExportMetadata": btn.Caption = "4. EXPORT METADÁT TABULIEK" & vbCrLf & "(Schema_Metadata_*.json)": btn.FontBold = True: btn.ForeColor = RGB(100, 0, 150): btn.OnClick = "=SpustiExportMetadataGUI()"

    Set btn = CreateControl(TmpName, acCommandButton, acDetail, , "", 5100, 4800, 4300, 550)
    btn.Name = "btnExportData": btn.Caption = "5. EXPORT ACCESS + DBF DÁT" & vbCrLf & "(2_DATA_ACCESS_DBF_ANALYZAM.txt)": btn.FontBold = True: btn.ForeColor = RGB(120, 60, 0): btn.OnClick = "=SpustiExportDataGUI()"

    Set btn = CreateControl(TmpName, acCommandButton, acDetail, , "", 400, 5450, 9000, 550)
    btn.Name = "btnKompletnyExport": btn.Caption = "6. KOMPLETNÝ EXPORT VŠETKÉHO" & vbCrLf & "(VBA Index + Kód + Access + DBF + Metadáta)": btn.FontBold = True: btn.FontSize = 10: btn.ForeColor = RGB(0, 100, 0): btn.OnClick = "=SpustiKompletnyExportGUI()"

    Set ctl = CreateControl(TmpName, acLine, acDetail, , "", 400, 6100, 9000, 0)

    Set btn = CreateControl(TmpName, acCommandButton, acDetail, , "", 400, 6200, 9000, 400)
    btn.Name = "btnVymazPomocneTabulky": btn.Caption = "VYMAZAŤ VŠETKY POMOCNÉ VÝPOČTOVÉ TABUĽKY": btn.FontBold = True: btn.ForeColor = RGB(180, 0, 0): btn.OnClick = "=SpustiVymazPomocnychTabuliekGUI()"

    Set btn = CreateControl(TmpName, acCommandButton, acDetail, , "", 400, 6650, 9000, 400)
    btn.Name = "btnAnonymizujAccess": btn.Caption = "ANONYMIZOVAŤ CITLIVÉ OSOBNÉ DÁTA PRIAMO V ACCESS TABUĽKÁCH": btn.FontBold = True: btn.ForeColor = RGB(180, 80, 0): btn.OnClick = "=SpustiAnonymizaciuAccessGUI()"

    Set ctl = CreateControl(TmpName, acLine, acDetail, , "", 400, 7150, 9000, 0)

    Set ctl = CreateControl(TmpName, acLabel, acDetail, , "", 400, 7250, 7000, 250)
    ctl.Caption = "Export nastavení a testovacej vzorky pre Lovable Cloud (JSON):": ctl.FontBold = True: ctl.ForeColor = RGB(0, 100, 50)

    Set ctl = CreateControl(TmpName, acLabel, acDetail, , "", 400, 7550, 8000, 250)
    ctl.Caption = "Vyberte zamestnancov pre testovaciu vzorku (zakliknite zo zoznamu):": ctl.FontBold = True

    Set ctl = CreateControl(TmpName, acListBox, acDetail, , "", 400, 7850, 9000, 1800)
    ctl.Name = "lstOsobneCisla"
    With ctl
        .MultiSelect = 2
        .ColumnCount = 2
        .ColumnWidths = "1800;4500"
        .ColumnHeads = False
        .RowSourceType = "Table/Query"
    End With

    Set btn = CreateControl(TmpName, acCommandButton, acDetail, , "", 400, 9750, 9000, 450)
    btn.Name = "btnExportLovableJSON": btn.Caption = "EXPORT LOVABLE CONFIG (dochs_config.json) A TEST VZORKY (dochs_test_sample.json)": btn.FontBold = True: btn.ForeColor = RGB(0, 120, 40): btn.OnClick = "=SpustiExportLovableJSONGUI()"

    Set ctl = CreateControl(TmpName, acLine, acDetail, , "", 400, 10300, 9000, 0)

    Set ctl = CreateControl(TmpName, acLabel, acDetail, , "", 400, 10400, 4000, 250)
    ctl.Caption = "Stav operácie:": ctl.FontBold = True
    Set ctl = CreateControl(TmpName, acTextBox, acDetail, , "", 400, 10700, 9000, 800)
    ctl.Name = "txtStatusInfo": ctl.Locked = True: ctl.Enabled = False

    ' SPODNÉ OVLÁDACIE TLAČIDLÁ (OTVORIŤ / UKONČIŤ TESTOVANIE / ZATVORIŤ)
    Set btn = CreateControl(TmpName, acCommandButton, acDetail, , "", 400, 11600, 3000, 450)
    btn.Name = "btnOtvorPriecinok": btn.Caption = "Otvoriť cieľový priečinok": btn.OnClick = "=OtvorPriecinokExports()"

    Set btn = CreateControl(TmpName, acCommandButton, acDetail, , "", 3600, 11600, 3200, 450)
    btn.Name = "btnUkoncitTestovanie": btn.Caption = "UKONČIŤ TESTOVANIE (VYPNÚŤ DEV MODE)": btn.FontBold = True: btn.ForeColor = RGB(180, 0, 0): btn.OnClick = "=SpustiUkoncenieTestovaniaGUI()"

    Set btn = CreateControl(TmpName, acCommandButton, acDetail, , "", 7000, 11600, 2400, 450)
    btn.Name = "btnZavriet": btn.Caption = "Zatvoriť": btn.OnClick = "=ZavriAdminFormular()"

    DoCmd.Save acForm, TmpName
    DoCmd.Close acForm, TmpName, acSaveYes
    DoCmd.Rename "frmAdminNastroje", acForm, TmpName

    DoCmd.OpenForm "frmAdminNastroje"
    Forms!frmAdminNastroje!txtCestaImport = mod_00_Common.GetNastavenie("CestaDBFAdresar", CurrentProject.Path & "\")
    Forms!frmAdminNastroje!txtCestaExport = CurrentProject.Path & "\Export_Access_CSV\"
    Forms!frmAdminNastroje!txtDatumOd = DateSerial(Year(Date), Month(Date) - 1, 1)
    Forms!frmAdminNastroje!txtDatumDo = DateSerial(Year(Date), Month(Date), 0)
    Forms!frmAdminNastroje!txtMaxRiadkov = 300
    Forms!frmAdminNastroje!txtStatusInfo = "Pripravený na spustenie."

    Call AktualizujZoznamZamestnancovGUI
    Exit Sub

ChybaHandler:
    strErr = Err.Description
    On Error Resume Next
    If Len(TmpName) > 0 Then DoCmd.Close acForm, TmpName, acSaveNo
    MsgBox "Chyba pri vytváraní formulára: " & strErr, vbCritical, "Chyba"
End Sub

'-------------------------------------------------------------------------------
' Obnovuje a filtruje zoznam zamestnancov v ListBoxe podľa vybraného obdobia.
'-------------------------------------------------------------------------------
Public Function AktualizujZoznamZamestnancovGUI()
    On Error Resume Next
    If Not mod_00_Common.FormIsOpen("frmAdminNastroje") Then Exit Function

    Dim dtOd As Variant, dtDo As Variant
    Dim strKdeImport As String, strSQL As String
    Dim lst As Access.ListBox, db As DAO.Database, rsCheck As DAO.Recordset

    Set lst = Forms!frmAdminNastroje!lstOsobneCisla
    dtOd = Forms!frmAdminNastroje!txtDatumOd
    dtDo = Forms!frmAdminNastroje!txtDatumDo

    If IsDate(dtOd) Then strKdeImport = "I.Datum >= #" & Format$(CDate(dtOd), "yyyy\-mm\-dd") & "#"
    If IsDate(dtDo) Then
        If Len(strKdeImport) > 0 Then strKdeImport = strKdeImport & " AND "
        strKdeImport = strKdeImport & "I.Datum <= #" & Format$(CDate(dtDo), "yyyy\-mm\-dd") & "#"
    End If

    Set db = CurrentDb
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaImport") Then
        strSQL = "SELECT DISTINCT I.OsobneCislo, Nz(Z.Priezvisko & ' ' & Z.Meno, 'Zamestnanec ' & I.OsobneCislo) AS Meno " & _
                 "FROM DochadzkaImport AS I LEFT JOIN Zamestnanci AS Z ON CStr(I.OsobneCislo) = CStr(Z.OsobneCislo) " & _
                 IIf(Len(strKdeImport) > 0, "WHERE " & strKdeImport & " ", "") & _
                 "ORDER BY I.OsobneCislo;"
        Set rsCheck = db.OpenRecordset(strSQL, dbOpenSnapshot)
    End If

    If rsCheck Is Nothing Or rsCheck.EOF Then
        If Not rsCheck Is Nothing Then rsCheck.Close
        strSQL = "SELECT OsobneCislo, Nz(Priezvisko & ' ' & Meno, Nz(CeleMeno, 'Zamestnanec ' & OsobneCislo)) AS Meno " & _
                 "FROM Zamestnanci ORDER BY OsobneCislo;"
    End If

    If Not rsCheck Is Nothing Then rsCheck.Close: Set rsCheck = Nothing
    lst.RowSource = strSQL
    lst.Requery
    Set db = Nothing
End Function

'-------------------------------------------------------------------------------
' Vrací čiarkou oddelené osobné čísla vybrané používateľom v ListBoxe.
'-------------------------------------------------------------------------------
Private Function ZiskajVybraneOsobneCislaListBox() As String
    On Error Resume Next
    ZiskajVybraneOsobneCislaListBox = mod_00_Common.ZiskajVybraneOsobneCislaListBox(Forms!frmAdminNastroje!lstOsobneCisla)
End Function

'-------------------------------------------------------------------------------
' Spúšťa generovanie indexu architektúry (0_INDEX_VBA_STRUKTURA.txt).
'-------------------------------------------------------------------------------
Public Function SpustiExportIndexGUI()
    On Error GoTo ChybaHandler
    Dim expFolder As String
    expFolder = Trim(Nz(Forms!frmAdminNastroje!txtCestaExport, ""))
    If Len(expFolder) = 0 Then expFolder = CurrentProject.Path & "\Export_Access_CSV\"

    NastavStatus "Spúšťam export indexu VBA architektúry (0_INDEX_VBA_STRUKTURA.txt)..."
    Call ExportujIndexProcedur(expFolder)
    NastavStatus "DOKONČENÉ: Index zložky vygenerovaný do: " & expFolder
    MsgBox "Export indexu VBA architektúry bol úspešne dokončený." & vbCrLf & vbCrLf & "Súbor: " & expFolder & "0_INDEX_VBA_STRUKTURA.txt", vbInformation, "Export indexu úspešný"
    Exit Function

ChybaHandler:
    NastavStatus "CHYBA pri exporte indexu: " & Err.Description
    MsgBox "Chyba pri exporte indexu: " & Err.Description, vbCritical, "Chyba"
End Function

'-------------------------------------------------------------------------------
' Spúšťa export JSON schémy metadát databázových tabuliek.
'-------------------------------------------------------------------------------
Public Function SpustiExportMetadataGUI()
    On Error GoTo ChybaHandler
    Dim expFolder As String, outPath As String
    expFolder = Trim(Nz(Forms!frmAdminNastroje!txtCestaExport, ""))
    If Len(expFolder) = 0 Then expFolder = CurrentProject.Path & "\Export_Access_CSV\"

    NastavStatus "Spúšťam export metadát databázových tabuliek (JSON schema)..."
    outPath = mod_00_Common.ExportovatMetadataTabuliek(expFolder & "Schema_Metadata_" & Format(Now, "yyyy-mm-dd_hhnnss") & ".json")
    
    If Len(outPath) > 0 Then
        NastavStatus "DOKONČENÉ: Schéma metadát vygenerovaná do: " & outPath
        MsgBox "Export metadát tabuliek bol úspešne dokončený." & vbCrLf & vbCrLf & "Súbor: " & outPath, vbInformation, "Export metadát úspešný"
    Else
        NastavStatus "CHYBA pri exporte metadát."
    End If
    Exit Function

ChybaHandler:
    NastavStatus "CHYBA pri exporte metadát: " & Err.Description
    MsgBox "Chyba pri exporte metadát: " & Err.Description, vbCritical, "Chyba"
End Function

'-------------------------------------------------------------------------------
' Spúšťa export JSON konfigurácie a testovacej vzorky pre Lovable Cloud.
'-------------------------------------------------------------------------------
Public Function SpustiExportLovableJSONGUI()
    On Error GoTo ChybaHandler
    Dim expFolder As String, dtOd As Variant, dtDo As Variant, strOsc As String
    expFolder = Trim(Nz(Forms!frmAdminNastroje!txtCestaExport, ""))
    If Len(expFolder) = 0 Then expFolder = CurrentProject.Path & "\"

    dtOd = Forms!frmAdminNastroje!txtDatumOd
    dtDo = Forms!frmAdminNastroje!txtDatumDo
    strOsc = ZiskajVybraneOsobneCislaListBox()

    NastavStatus "Spúšťam export Lovable JSON konfigurácie a testovacej vzorky..."
    Call ExportujLovableKonfiguraciu(dtOd, dtDo, strOsc, expFolder)
    NastavStatus "DOKONČENÉ: dochs_config.json aj dochs_test_sample.json vygenerované v: " & expFolder
    Exit Function

ChybaHandler:
    NastavStatus "CHYBA pri exporte pre Lovable: " & Err.Description
    MsgBox "Chyba pri exporte pre Lovable: " & Err.Description, vbCritical, "Chyba"
End Function

'-------------------------------------------------------------------------------
' Generuje súbory dochs_config.json a dochs_test_sample.json pre Lovable Cloud.
'-------------------------------------------------------------------------------
Public Sub ExportujLovableKonfiguraciu(Optional ByVal dtOd As Variant = Null, Optional ByVal dtDo As Variant = Null, _
                                        Optional ByVal strOsobneCisla As String = "", Optional ByVal CestaExportFolder As String = "")
    On Error GoTo Err_Handler
    Dim dStart As Date, dEnd As Date
    If IsDate(dtOd) Then dStart = CDate(dtOd) Else dStart = DateSerial(Year(Date), Month(Date) - 1, 1)
    If IsDate(dtDo) Then dEnd = CDate(dtDo) Else dEnd = DateSerial(Year(Date), Month(Date), 0)

    Dim iRok As Integer: iRok = Year(dStart)
    Dim iMesiac As Integer: iMesiac = Month(dStart)
    Dim outFolder As String: outFolder = mod_00_Common.PripravAdresarExportu(CestaExportFolder)
    Dim db As DAO.Database: Set db = CurrentDb

    Dim jsonConfig As String
    ' Konfigurácia pre terminál sa generuje na jednom mieste (bez osobných údajov) - viď mod_12_TerminalPriprava
    ' Od balíka 2.12.0 súbor nesie aj výpočtový plán (kontrakt 1.2.0); ak by jeho zostavenie zlyhalo, zapíše sa pôvodná konfigurácia
    jsonConfig = mod_20_KonfiguraciaExport.GenerujKonfiguraciuV2JSON()
    If Len(jsonConfig) = 0 Then jsonConfig = mod_12_TerminalPriprava.GenerujKonfiguraciuJSON(iRok)

    mod_00_Common.UlozUTF8Sustor outFolder & "dochs_config.json", jsonConfig

    Dim jsonTest As String
    jsonTest = "{" & vbCrLf & "  ""description"": ""Testovacia vzorka pípnutí, vypočítaných dní a sumárov pre validáciu v Lovable Cloud.""," & vbCrLf & GenerujSekciuTestData(db, dStart, dEnd, strOsobneCisla) & vbCrLf & "}"
    mod_00_Common.UlozUTF8Sustor outFolder & "dochs_test_sample.json", jsonTest

    MsgBox "Export pre Lovable prebehol úspešne!" & vbCrLf & vbCrLf & "1. Produkčný profil: " & outFolder & "dochs_config.json" & vbCrLf & "2. Testovacia vzorka: " & outFolder & "dochs_test_sample.json", vbInformation, "Export Lovable úspešný"
    Exit Sub

Err_Handler:
    Call ZrusVystup
    MsgBox "Chyba pri exporte pre Lovable: " & Err.Description, vbCritical
End Sub

'-------------------------------------------------------------------------------
' Prepočíta dochádzku pre vybraných zamestnancov a obdobie pred generovaním testovacej vzorky.
'-------------------------------------------------------------------------------
Private Sub PrecalculujMesiaceAEmployees(ByRef db As DAO.Database, ByVal dStart As Date, ByVal dEnd As Date, ByVal strOsobneCisla As String)
    On Error Resume Next
    Dim strSQL As String, rsEmp As DAO.Recordset, osc As String, dIter As Date, iRok As Integer, iMes As Integer

    If Len(Trim$(strOsobneCisla)) > 0 Then
        strSQL = "SELECT DISTINCT OsobneCislo FROM Zamestnanci WHERE CStr(OsobneCislo) IN (" & strOsobneCisla & ");"
    Else
        strSQL = "SELECT DISTINCT OsobneCislo FROM DochadzkaImport WHERE Datum >= #" & Format$(dStart, "yyyy\-mm\-dd") & "# AND Datum <= #" & Format$(dEnd, "yyyy\-mm\-dd") & "#;"
    End If

    Set rsEmp = db.OpenRecordset(strSQL, dbOpenSnapshot)
    If rsEmp Is Nothing Or rsEmp.EOF Then
        If Not rsEmp Is Nothing Then rsEmp.Close
        strSQL = "SELECT DISTINCT OsobneCislo FROM Zamestnanci;"
        Set rsEmp = db.OpenRecordset(strSQL, dbOpenSnapshot)
    End If
    If rsEmp Is Nothing Or rsEmp.EOF Then Exit Sub

    dIter = DateSerial(Year(dStart), Month(dStart), 1)
    Do While dIter <= DateSerial(Year(dEnd), Month(dEnd), 1)
        iRok = Year(dIter): iMes = Month(dIter)
        rsEmp.MoveFirst
        Do While Not rsEmp.EOF
            osc = CStr(Nz(rsEmp!OsobneCislo, ""))
            If Len(osc) > 0 Then Call modMesaatnaDochadzka.PrecalculujDochadzkuBezZostavy(osc, iRok, iMes)
            rsEmp.MoveNext
        Loop
        dIter = DateAdd("m", 1, dIter)
    Loop
    rsEmp.Close: Set rsEmp = Nothing
End Sub

'-------------------------------------------------------------------------------
' Sostavuje sekciu raw udalostí, výsledkových dní a mesačných sumárov pre JSON testovaciu vzorku.
'-------------------------------------------------------------------------------
Private Function GenerujSekciuTestData(ByRef db As DAO.Database, ByVal dStart As Date, ByVal dEnd As Date, ByVal strOsobneCisla As String) As String
    Dim json As String
    Call PrecalculujMesiaceAEmployees(db, dStart, dEnd, strOsobneCisla)

    json = "  ""date_from"": """ & Format$(dStart, "yyyy-mm-dd") & """," & vbCrLf & "  ""date_to"": """ & Format$(dEnd, "yyyy-mm-dd") & """," & vbCrLf
    Dim strWhereEvents As String, strWhereDni As String
    If Len(Trim$(strOsobneCisla)) > 0 Then
        strWhereEvents = " AND CStr(OsobneCislo) IN (" & strOsobneCisla & ") "
        strWhereDni = " AND CStr(OsobneCislo) IN (" & strOsobneCisla & ") "
    End If

    json = json & "  ""raw_events"": [" & vbCrLf
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaImport") Then
        Dim strSQLEvents As String
        strSQLEvents = "SELECT D.OsobneCislo, D.Datum, D.Cas, Nz(D.CisloPreruseni, K.CisloPreruseni) AS CisloPreruseni, Nz(D.Smer, K.Smer) AS Smer FROM DochadzkaImport AS D LEFT JOIN KodyRazeni AS K ON D.KodPrerusenia = K.KodRazenia WHERE " & mod_00_Common.SqlPlatne("D") & " AND D.Datum >= #" & Format$(dStart, "yyyy\-mm\-dd") & "# AND D.Datum <= #" & Format$(dEnd, "yyyy\-mm\-dd") & "# " & Replace(strWhereEvents, "CStr(OsobneCislo)", "CStr(D.OsobneCislo)") & " ORDER BY D.OsobneCislo, D.Datum, D.Cas;"
        Dim rsE As DAO.Recordset
        On Error Resume Next
        Set rsE = db.OpenRecordset(strSQLEvents, dbOpenSnapshot)
        On Error GoTo 0
        If Not rsE Is Nothing Then
            Dim bFirst As Boolean: bFirst = True
            Do While Not rsE.EOF
                If Not bFirst Then json = json & "," & vbCrLf
                bFirst = False
                json = json & "    { ""osc"": """ & rsE!OsobneCislo & """, ""datum"": """ & Format$(rsE!Datum, "yyyy-mm-dd") & """, ""cas_min"": " & Nz(rsE!Cas, 0) & ", ""kod"": " & Nz(rsE!CisloPreruseni, 1) & ", ""smer"": """ & Nz(rsE!smer, "") & """ }"
                rsE.MoveNext
            Loop
            rsE.Close: Set rsE = Nothing
        End If
    End If
    json = json & vbCrLf & "  ]," & vbCrLf

    ' schválené automatické opravy (virtuálne razenia) - vstupujú do výpočtu spolu s raw_events
    json = json & "  ""auto_events"": [" & vbCrLf
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaAutoOpravy") Then
        Dim rsA As DAO.Recordset, bFirstA As Boolean
        On Error Resume Next
        Set rsA = db.OpenRecordset("SELECT OsobneCislo, Datum, Cas, CisloPreruseni, Smer, Typ FROM DochadzkaAutoOpravy WHERE Stav = 'UPLATNENE' AND Datum >= #" & _
                  Format$(dStart, "yyyy\-mm\-dd") & "# AND Datum <= #" & Format$(dEnd, "yyyy\-mm\-dd") & "# " & strWhereEvents & " ORDER BY OsobneCislo, Datum, Cas;", dbOpenSnapshot)
        On Error GoTo 0
        If Not rsA Is Nothing Then
            bFirstA = True
            Do While Not rsA.EOF
                If Not bFirstA Then json = json & "," & vbCrLf
                bFirstA = False
                json = json & "    { ""osc"": """ & rsA!OsobneCislo & """, ""datum"": """ & Format$(rsA!Datum, "yyyy-mm-dd") & """, ""cas_min"": " & Nz(rsA!Cas, 0) & ", ""kod"": " & Nz(rsA!CisloPreruseni, 1) & ", ""smer"": """ & Nz(rsA!smer, "") & """, ""typ"": """ & Nz(rsA!Typ, "") & """ }"
                rsA.MoveNext
            Loop
            rsA.Close: Set rsA = Nothing
        End If
    End If
    json = json & vbCrLf & "  ]," & vbCrLf

    json = json & "  ""expected_daily_results"": [" & vbCrLf
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaDni") Then
        Dim strSQLDni As String
        strSQLDni = "SELECT OsobneCislo, Datum, TypDna, DennyFondMin, OdpracovaneMin, SaldoMin FROM DochadzkaDni WHERE Datum >= #" & Format$(dStart, "yyyy\-mm\-dd") & "# AND Datum <= #" & Format$(dEnd, "yyyy\-mm\-dd") & "# " & strWhereDni & " ORDER BY Datum, OsobneCislo;"
        Dim rsD As DAO.Recordset
        On Error Resume Next
        Set rsD = db.OpenRecordset(strSQLDni, dbOpenSnapshot)
        On Error GoTo 0
        If Not rsD Is Nothing Then
            Dim bFirstD As Boolean: bFirstD = True
            Do While Not rsD.EOF
                If Not bFirstD Then json = json & "," & vbCrLf
                bFirstD = False
                Dim sOsc As String, dDat As Date, sTypDna As String, lFond As Long, lOdpr As Long, lSaldo As Long, sDetaily As String
                sOsc = CStr(Nz(rsD!OsobneCislo, "")): dDat = CDate(Nz(rsD!Datum, dStart)): sTypDna = CStr(Nz(rsD!TypDna, "PP"))
                lFond = CLng(Val(Nz(rsD!DennyFondMin, 0))): lOdpr = CLng(Val(Nz(rsD!OdpracovaneMin, 0))): lSaldo = CLng(Val(Nz(rsD!SaldoMin, 0)))
                sDetaily = modMesaatnaDochadzka.ZiskajDetailyDna(sOsc, dDat)
                json = json & "    {""osc"": """ & sOsc & """, ""datum"": """ & Format$(dDat, "yyyy-mm-dd") & """, ""typ_dna"": """ & sTypDna & """, ""denny_fond_min"": " & lFond & ", ""odpracovane_min"": " & lOdpr & ", ""saldo_min"": " & lSaldo & ", ""detaily_dna"": """ & mod_00_Common.OsetriJSONText(sDetaily) & """}"
                rsD.MoveNext
            Loop
            rsD.Close: Set rsD = Nothing
        End If
    End If
    json = json & vbCrLf & "  ]," & vbCrLf

    json = json & "  ""expected_monthly_summaries"": [" & vbCrLf
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaMesiacSumar") Then
        Dim strSQLSum As String
        strSQLSum = "SELECT OsobneCislo, Rok, Mesiac, OdpracovaneDni, OdpracovaneMin, StavMesiacaMin FROM DochadzkaMesiacSumar WHERE " & IIf(Len(Trim$(strOsobneCisla)) > 0, "CStr(OsobneCislo) IN (" & strOsobneCisla & ")", "1=1") & " ORDER BY Rok, Mesiac, OsobneCislo;"
        Dim rsS As DAO.Recordset
        On Error Resume Next
        Set rsS = db.OpenRecordset(strSQLSum, dbOpenSnapshot)
        On Error GoTo 0
        If Not rsS Is Nothing Then
            Dim bFirstS As Boolean: bFirstS = True
            Do While Not rsS.EOF
                If Not bFirstS Then json = json & "," & vbCrLf
                bFirstS = False
                Dim sOscS As String, iR As Integer, iM As Integer, lOdprDni As Long, lOdprMin As Long, lStavMin As Long, lStavPrDen As Long, sCerpanieText As String
                sOscS = CStr(Nz(rsS!OsobneCislo, "")): iR = CInt(Val(Nz(rsS!rok, Year(dStart)))): iM = CInt(Val(Nz(rsS!Mesiac, Month(dStart))))
                lOdprDni = CLng(Val(Nz(rsS!OdpracovaneDni, 0))): lOdprMin = CLng(Val(Nz(rsS!OdpracovaneMin, 0))): lStavMin = CLng(Val(Nz(rsS!StavMesiacaMin, 0)))
                lStavPrDen = modMesaatnaDochadzka.ZiskajStavKPredchadzajucemuDnu(sOscS, iR, iM)
                sCerpanieText = modMesaatnaDochadzka.ZiskajTextCerpaniaPreruseni(sOscS, iR, iM)
                json = json & "    {""osc"": """ & sOscS & """, ""rok"": " & iR & ", ""mesiac"": " & iM & ", ""odpracovane_dni"": " & lOdprDni & ", ""odpracovane_min"": " & lOdprMin & ", ""stav_mesiaca_min"": " & lStavMin & ", ""stav_predchadzajuci_den_min"": " & lStavPrDen & ", ""cerpanie_preruseni_text"": """ & mod_00_Common.OsetriJSONText(sCerpanieText) & """}"
                rsS.MoveNext
            Loop
            rsS.Close: Set rsS = Nothing
        End If
    End If
    json = json & vbCrLf & "  ]"
    GenerujSekciuTestData = json
End Function

'-------------------------------------------------------------------------------
' Zobrazuje potvrdzovací dialóg a spúšťa anonymizáciu dát v Access tabuľkách.
'-------------------------------------------------------------------------------
Public Function SpustiAnonymizaciuAccessGUI()
    On Error GoTo ChybaHandler
    Dim strSprava As String
    strSprava = "Naozaj chcete ANONYMIZOVAŤ citlivé osobné dáta priamo v databáze Access?" & vbCrLf & vbCrLf & "• Nahradí mená, priezviská, tituly, kontakty, adresy a užívateľov textom 'Anonym_1', 'Anonym_2'..." & vbCrLf & "• Osobné čísla, dátumy, časy a kódy prerušení zostanú nedotknuté pre zachovanie logiky výpočtu." & vbCrLf & vbCrLf & "UPOZORNENIE: Táto operácia priamo upraví dáta v databáze!"

    If MsgBox(strSprava, vbQuestion + vbYesNo + vbDefaultButton2, "Potvrdenie anonymizácie dát") = vbYes Then
        NastavStatus "Spúšťam anonymizáciu Access tabuliek..."
        Call AnonymizujTabulkyVAccessDB
        NastavStatus "DOKONČENÉ: Citlivé dáta v Access tabuľkách boli anonymizované."
        MsgBox "Anonymizácia Access tabuliek bola úspešne dokončená.", vbInformation, "Anonymizácia dokončená"
    End If
    Exit Function

ChybaHandler:
    NastavStatus "CHYBA pri anonymizácii Access tabuliek: " & Err.Description
    MsgBox "Chyba pri anonymizácii: " & Err.Description, vbCritical, "Chyba"
End Function

'-------------------------------------------------------------------------------
' Prechádza všetky používateľské tabuľky v databáze a anonymizuje citlivé stĺpce.
'-------------------------------------------------------------------------------
Public Sub AnonymizujTabulkyVAccessDB()
    On Error GoTo ChybaHandler
    Dim db As DAO.Database, tdf As DAO.TableDef, pocetTab As Long, idx As Long
    Set db = CurrentDb

    For Each tdf In db.TableDefs
        If mod_00_Common.JeUzivatelskaTabulka(tdf) Then pocetTab = pocetTab + 1
    Next tdf

    Call mod_00_Common.PripravProgressForm
    For Each tdf In db.TableDefs
        If mod_00_Common.JeUzivatelskaTabulka(tdf) Then
            idx = idx + 1
            Call AnonymizujJednuAccessTabulku(db, tdf, idx, pocetTab)
        End If
    Next tdf

    Call mod_00_Common.ZavriProgressForm
    Set db = Nothing
    Exit Sub

ChybaHandler:
    Dim errDesc As String: errDesc = Err.Description
    Call mod_00_Common.ZavriProgressForm
    Set db = Nothing
    Err.Raise Err.Number, "AnonymizujTabulkyVAccessDB", errDesc
End Sub

'-------------------------------------------------------------------------------
' Anonymizuje citlivé polia v jednej konkrétnej Access tabuľke.
'-------------------------------------------------------------------------------
Private Sub AnonymizujJednuAccessTabulku(ByRef db As DAO.Database, ByVal tdf As DAO.TableDef, ByVal idxTab As Long, ByVal celkovoTab As Long)
    On Error GoTo ChybaHandler
    Dim rs As DAO.Recordset, i As Long, n As Long, totalRecs As Long
    Dim sens() As Boolean, maCitlivePole As Boolean

    ReDim sens(0 To tdf.Fields.Count - 1)
    For i = 0 To tdf.Fields.Count - 1
        sens(i) = mod_00_Common.JeCitlivePole(tdf.Fields(i).Name)
        If sens(i) Then maCitlivePole = True
    Next i
    If Not maCitlivePole Then Exit Sub

    Set rs = db.OpenRecordset("SELECT * FROM [" & tdf.Name & "];", dbOpenDynaset)
    If Not rs.EOF Then
        rs.MoveLast
        totalRecs = rs.RecordCount
        rs.MoveFirst
    End If

    Call mod_00_Common.AktualizujProgressGUI("[ANONYMIZÁCIA] Anonymizujem tabuľku: " & tdf.Name, idxTab, celkovoTab, tdf.Name, "Záznamov: 0 / " & Format$(totalRecs, "#,##0"))
    Do While Not rs.EOF
        n = n + 1
        rs.Edit
        For i = 0 To rs.Fields.Count - 1
            If sens(i) And Not IsNull(rs.Fields(i).Value) Then
                If Len(Trim$(CStr(rs.Fields(i).Value))) > 0 Then
                    If rs.Fields(i).Type = 10 Or rs.Fields(i).Type = 12 Then rs.Fields(i).Value = "Anonym_" & n
                End If
            End If
        Next i
        rs.Update
        If (n Mod 100) = 0 Or n = 1 Or n = totalRecs Then
            Call mod_00_Common.AktualizujProgressGUI("[ANONYMIZÁCIA] Tabuľka: " & tdf.Name, idxTab, celkovoTab, tdf.Name, "Riadky: " & Format$(n, "#,##0") & " / " & Format$(totalRecs, "#,##0"))
        End If
        rs.MoveNext
    Loop
    rs.Close: Set rs = Nothing
    Exit Sub

ChybaHandler:
    On Error Resume Next
    If Not rs Is Nothing Then rs.Close
End Sub

'-------------------------------------------------------------------------------
' Zobrazuje potvrdzovací dialóg a spúšťa vyčistenie výpočtových pomocných tabuliek.
'-------------------------------------------------------------------------------
Public Function SpustiVymazPomocnychTabuliekGUI()
    On Error GoTo ChybaHandler
    Dim strSprava As String
    strSprava = "Naozaj chcete kompletne vyprázdniť všetky pomocné výpočtové tabuľky?" & vbCrLf & vbCrLf & "• DochadzkaIntervaly" & vbCrLf & "• DochadzkaDni" & vbCrLf & "• DochadzkaMesiacSumar" & vbCrLf & vbCrLf & "Tento krok zmaže všetky doteraz vypočítané intervaly a sumáre pre všetkých zamestnancov."

    If MsgBox(strSprava, vbQuestion + vbYesNo + vbDefaultButton2, "Potvrdenie vymazania pomocných tabuliek") = vbYes Then
        NastavStatus "Spúšťam kompletne vyčistenie pomocných tabuliek..."
        Call VymazVsetkyPomocneTabulky
        NastavStatus "DOKONČENÉ: Všetky pomocné výpočtové tabuľky boli vyprázdnené."
        MsgBox "Pomocné tabuľky dochádzky boli úspešne vyčistené.", vbInformation, "Vymazanie dokončené"
    End If
    Exit Function

ChybaHandler:
    NastavStatus "CHYBA pri vymazávaní pomocných tabuliek: " & Err.Description
    MsgBox "Chyba pri vymazávaní tabuliek: " & Err.Description, vbCritical, "Chyba"
End Function

'-------------------------------------------------------------------------------
' Zmaže záznamy z pomocných tabuliek DochadzkaIntervaly, DochadzkaDni a DochadzkaMesiacSumar (okrem uzavretých mesiacov).
'-------------------------------------------------------------------------------
Public Sub VymazVsetkyPomocneTabulky()
    On Error GoTo ChybaHandler
    Dim db As DAO.Database: Set db = CurrentDb
    ' výpočty uzavretých (podpísaných) mesiacov sa nemažú - zostava sa z nich dá znova vytlačiť
    Dim strUz As String
    If mod_18_Uzavierka.ExistujeUzavrety() Then
        strUz = " WHERE NOT EXISTS (SELECT 1 FROM DochadzkaUzavierka AS U7 WHERE U7.Stav = 'UZAVRETY' AND U7.OsobneCislo = DochadzkaIntervaly.OsobneCislo " & _
                "AND U7.Rok = Year(DochadzkaIntervaly.Datum) AND U7.Mesiac = Month(DochadzkaIntervaly.Datum))"
        db.Execute "DELETE FROM DochadzkaIntervaly" & strUz & ";", dbFailOnError
        db.Execute "DELETE FROM DochadzkaDni WHERE NOT EXISTS (SELECT 1 FROM DochadzkaUzavierka AS U7 WHERE U7.Stav = 'UZAVRETY' AND U7.OsobneCislo = DochadzkaDni.OsobneCislo " & _
                   "AND U7.Rok = Year(DochadzkaDni.Datum) AND U7.Mesiac = Month(DochadzkaDni.Datum));", dbFailOnError
        db.Execute "DELETE FROM DochadzkaMesiacSumar WHERE NOT EXISTS (SELECT 1 FROM DochadzkaUzavierka AS U7 WHERE U7.Stav = 'UZAVRETY' AND U7.OsobneCislo = DochadzkaMesiacSumar.OsobneCislo " & _
                   "AND U7.Rok = DochadzkaMesiacSumar.Rok AND U7.Mesiac = DochadzkaMesiacSumar.Mesiac);", dbFailOnError
    Else
        db.Execute "DELETE FROM DochadzkaIntervaly;", dbFailOnError
        db.Execute "DELETE FROM DochadzkaDni;", dbFailOnError
        db.Execute "DELETE FROM DochadzkaMesiacSumar;", dbFailOnError
    End If
    Set db = Nothing
    Exit Sub

ChybaHandler:
    Dim errDesc As String: errDesc = Err.Description
    Set db = Nothing
    Err.Raise Err.Number, "VymazVsetkyPomocneTabulky", errDesc
End Sub

'-------------------------------------------------------------------------------
' Spúšťa dialóg na výber zdrojového adresára pre DBF súbory.
'-------------------------------------------------------------------------------
Public Function VyberAdresarImportGUI()
    On Error GoTo ChybaHandler
    Dim fd As Object, adr As String
    Set fd = Application.FileDialog(4)
    With fd
        .Title = "Vyberte adresár so súbormi DBF"
        .InitialFileName = CurrentProject.Path & "\"
        If .Show = -1 Then
            adr = .SelectedItems(1)
            If Right$(adr, 1) <> "\" Then adr = adr & "\"
            Forms!frmAdminNastroje!txtCestaImport = adr
            Call mod_00_Common.SetNastavenie("CestaDBFAdresar", adr, "Adresár pre import DBF")
            NastavStatus "Adresár DBF bol nastavený na: " & adr
        End If
    End With
    Exit Function
ChybaHandler:
    NastavStatus "Chyba pri výbere adresára: " & Err.Description
End Function

'-------------------------------------------------------------------------------
' Spúšťa dialóg na výber cieľového adresára pre exporty.
'-------------------------------------------------------------------------------
Public Function VyberAdresarExportGUI()
    On Error GoTo ChybaHandler
    Dim fd As Object, adr As String
    Set fd = Application.FileDialog(4)
    With fd
        .Title = "Vyberte cieľový adresár pre exporty"
        .InitialFileName = CurrentProject.Path & "\"
        If .Show = -1 Then
            adr = .SelectedItems(1)
            If Right$(adr, 1) <> "\" Then adr = adr & "\"
            Forms!frmAdminNastroje!txtCestaExport = adr
            NastavStatus "Cieľový adresár bol nastavený na: " & adr
        End If
    End With
    Exit Function
ChybaHandler:
    NastavStatus "Chyba pri výbere adresára: " & Err.Description
End Function

'-------------------------------------------------------------------------------
' Načíta nastavený maximálny limit riadkov na tabuľku z políčka na formulári.
'-------------------------------------------------------------------------------
Private Function CitajMaxRiadkov() As Long
    Dim v As Long
    On Error Resume Next
    v = CLng(Val(Nz(Forms!frmAdminNastroje!txtMaxRiadkov, 300)))
    If Err.Number <> 0 Or v < 0 Then v = 300
    CitajMaxRiadkov = v
End Function

'-------------------------------------------------------------------------------
' Spúšťa samostatný export zdrojového VBA kódu (1_VBA_KOD_ANALYZAM.txt).
'-------------------------------------------------------------------------------
Public Function SpustiExportVBAGUI()
    On Error GoTo ChybaHandler
    Dim expFolder As String: expFolder = Trim(Nz(Forms!frmAdminNastroje!txtCestaExport, ""))
    NastavStatus "Spúšťam export VBA kódu..."
    Call ExportujIbaVBAKod(expFolder)
    NastavStatus "DOKONČENÉ: 1_VBA_KOD_ANALYZAM.txt v zložke: " & expFolder
    Exit Function
ChybaHandler:
    NastavStatus "CHYBA pri exporte VBA: " & Err.Description
End Function

'-------------------------------------------------------------------------------
' Spúšťa samostatný export Access tabuliek (2_DATA_ACCESS_ANALYZAM.txt).
'-------------------------------------------------------------------------------
Public Function SpustiExportAccessGUI()
    On Error GoTo ChybaHandler
    Dim expFolder As String, dtOd As Variant, dtDo As Variant
    expFolder = Trim(Nz(Forms!frmAdminNastroje!txtCestaExport, ""))
    dtOd = Forms!frmAdminNastroje!txtDatumOd: dtDo = Forms!frmAdminNastroje!txtDatumDo
    NastavStatus "Spúšťam export Access tabuliek..."
    Call ExportujIbaAccessTabulky(expFolder, dtOd, dtDo, CitajMaxRiadkov())
    NastavStatus "DOKONČENÉ: 2_DATA_ACCESS_ANALYZAM.txt v zložke: " & expFolder
    Exit Function
ChybaHandler:
    NastavStatus "CHYBA pri exporte Access tabuliek: " & Err.Description
End Function

'-------------------------------------------------------------------------------
' Spúšťa samostatný export pôvodných DBF súborov (3_DATA_DBF_ANALYZAM.txt).
'-------------------------------------------------------------------------------
Public Function SpustiExportDbfGUI()
    On Error GoTo ChybaHandler
    Dim impFolder As String, expFolder As String, dtOd As Variant, dtDo As Variant
    impFolder = Trim(Nz(Forms!frmAdminNastroje!txtCestaImport, ""))
    expFolder = Trim(Nz(Forms!frmAdminNastroje!txtCestaExport, ""))
    dtOd = Forms!frmAdminNastroje!txtDatumOd: dtDo = Forms!frmAdminNastroje!txtDatumDo

    If Len(impFolder) = 0 Or Dir(impFolder, vbDirectory) = "" Then
        MsgBox "Vyberte platný adresár, v ktorom sa nachádzajú DBF súbory!", vbExclamation
        Exit Function
    End If

    NastavStatus "Spúšťam export DBF súborov..."
    Call ExportujIbaDbfSubory(impFolder, expFolder, dtOd, dtDo, CitajMaxRiadkov())
    NastavStatus "DOKONČENÉ: 3_DATA_DBF_ANALYZAM.txt v zložke: " & expFolder
    Exit Function
ChybaHandler:
    NastavStatus "CHYBA pri exporte DBF súborov: " & Err.Description
End Function

'-------------------------------------------------------------------------------
' Spúšťa kombinovaný export dát (Access + DBF) do súboru (2_DATA_ACCESS_DBF_ANALYZAM.txt).
'-------------------------------------------------------------------------------
Public Function SpustiExportDataGUI()
    On Error GoTo ChybaHandler
    Dim impFolder As String, expFolder As String, dtOd As Variant, dtDo As Variant
    impFolder = Trim(Nz(Forms!frmAdminNastroje!txtCestaImport, ""))
    expFolder = Trim(Nz(Forms!frmAdminNastroje!txtCestaExport, ""))
    dtOd = Forms!frmAdminNastroje!txtDatumOd: dtDo = Forms!frmAdminNastroje!txtDatumDo

    If Len(impFolder) = 0 Or Dir(impFolder, vbDirectory) = "" Then
        MsgBox "Vyberte platný adresár, v ktorom sa nachádzajú DBF súbory!", vbExclamation
        Exit Function
    End If

    NastavStatus "Spúšťam kombinovaný export dát (Access + DBF)..."
    Call ExportujIbaData(impFolder, expFolder, dtOd, dtDo, CitajMaxRiadkov())
    NastavStatus "DOKONČENÉ: 2_DATA_ACCESS_DBF_ANALYZAM.txt v zložke: " & expFolder
    Exit Function
ChybaHandler:
    NastavStatus "CHYBA pri exporte dát: " & Err.Description
End Function

'-------------------------------------------------------------------------------
' Spúšťa kompletný dávkový export (VBA index, VBA kód, Access dáta, DBF dáta a JSON schéma metadát).
'-------------------------------------------------------------------------------
Public Function SpustiKompletnyExportGUI()
    On Error GoTo ChybaHandler
    Dim impFolder As String, expFolder As String, dtOd As Variant, dtDo As Variant
    impFolder = Trim(Nz(Forms!frmAdminNastroje!txtCestaImport, ""))
    expFolder = Trim(Nz(Forms!frmAdminNastroje!txtCestaExport, ""))
    dtOd = Forms!frmAdminNastroje!txtDatumOd: dtDo = Forms!frmAdminNastroje!txtDatumDo

    If Len(impFolder) = 0 Or Dir(impFolder, vbDirectory) = "" Then
        MsgBox "Vyberte platný adresár, v ktorom sa nachádzajú DBF súbory!", vbExclamation
        Exit Function
    End If

    NastavStatus "Spúšťam kompletný export (VBA Index + Kód + Access + DBF + Metadáta)..."
    Call ExportujIndexProcedur(expFolder)
    Call ExportujIbaVBAKod(expFolder)
    Call ExportujIbaAccessTabulky(expFolder, dtOd, dtDo, CitajMaxRiadkov())
    Call ExportujIbaDbfSubory(impFolder, expFolder, dtOd, dtDo, CitajMaxRiadkov())
    Call mod_00_Common.ExportovatMetadataTabuliek(expFolder & "Schema_Metadata_" & Format(Now, "yyyy-mm-dd_hhnnss") & ".json")

    NastavStatus "DOKONČENÉ: Všetky exportné súbory v zložke: " & expFolder
    MsgBox "Kompletný export dokončený." & vbCrLf & _
           "1. 0_INDEX_VBA_STRUKTURA.txt" & vbCrLf & _
           "2. 1_VBA_KOD_ANALYZAM.txt" & vbCrLf & _
           "3. 2_DATA_ACCESS_ANALYZAM.txt" & vbCrLf & _
           "4. 3_DATA_DBF_ANALYZAM.txt" & vbCrLf & _
           "5. Schema_Metadata_*.json", vbInformation, "Export dokončený"
    Exit Function
ChybaHandler:
    NastavStatus "CHYBA pri kompletnom exporte: " & Err.Description
End Function

'-------------------------------------------------------------------------------
' Tlačidlo vo formulári pre oficiálne ukončenie testovacieho/vývojárskeho režimu.
'-------------------------------------------------------------------------------
Public Function SpustiUkoncenieTestovaniaGUI()
    On Error GoTo ChybaHandler
    Dim strSprava As String
    strSprava = "Naozaj chcete UKONČIŤ testovanie a vypnúť vývojársky režim?" & vbCrLf & vbCrLf & _
                "• Nastaví sa produkčná prevádzka." & vbCrLf & _
                "• Okno vývojárskych nástrojov sa zatvorí a skryje."

    If MsgBox(strSprava, vbQuestion + vbYesNo + vbDefaultButton2, "Ukončenie testovania") = vbYes Then
        Call UkonciTestovaciRezim
    End If
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri ukončovaní testovania: " & Err.Description, vbCritical
End Function

'-------------------------------------------------------------------------------
' Vypne vývojársky režim (DevMode = 0), zatvorí admin okno a obnoví hlavnú konzolu.
'-------------------------------------------------------------------------------
Public Sub UkonciTestovaciRezim()
    On Error GoTo ChybaHandler
    Call NastavDevMode(False)
    
    If mod_00_Common.FormIsOpen("frmAdminNastroje") Then
        DoCmd.Close acForm, "frmAdminNastroje", acSaveNo
    End If

    If mod_00_Common.FormIsOpen("frmHlavnaKonzola") Then
        Forms!frmHlavnaKonzola.Requery
    End If

    MsgBox "Testovací režim bol úspešne UKONČENÝ." & vbCrLf & _
           "Aplikácia je pripravená v štandardnom produkčnom režime.", vbInformation, "Testovanie dokončené"
    Exit Sub
ChybaHandler:
    MsgBox "Chyba v UkonciTestovaciRezim: " & Err.Description, vbCritical
End Sub

'-------------------------------------------------------------------------------
' Otvorí cieľový priečinok exportov vo Windows Prieskumníkovi.
'-------------------------------------------------------------------------------
Public Function OtvorPriecinokExports()
    On Error Resume Next
    Dim adr As String
    adr = Trim(Nz(Forms!frmAdminNastroje!txtCestaExport, ""))
    If Len(adr) = 0 Or Dir(adr, vbDirectory) = "" Then adr = CurrentProject.Path & "\"
    Shell "explorer.exe """ & adr & """", vbNormalFocus
End Function

'-------------------------------------------------------------------------------
' Bezpečne zatvorí formulár vývojárskych nástrojov.
'-------------------------------------------------------------------------------
Public Function ZavriAdminFormular()
    On Error Resume Next
    DoCmd.Close acForm, "frmAdminNastroje", acSaveNo
End Function

'-------------------------------------------------------------------------------
' Aktualizuje stavovú správu vo formulári.
'-------------------------------------------------------------------------------
Private Sub NastavStatus(ByVal Sprava As String)
    On Error Resume Next
    If mod_00_Common.FormIsOpen("frmAdminNastroje") Then
        Forms!frmAdminNastroje!txtStatusInfo = "[" & Format$(Now, "hh:nn:ss") & "] " & Sprava
        Forms!frmAdminNastroje.Repaint
        DoEvents
    End If
End Sub

'-------------------------------------------------------------------------------
' Inicializuje UTF-8 ADODB Stream pre ukladanie textových exportov.
'-------------------------------------------------------------------------------
Private Sub OtvorVystup()
    Set mStream = CreateObject("ADODB.Stream")
    mStream.Type = 2: mStream.Charset = "utf-8": mStream.Open
End Sub

'-------------------------------------------------------------------------------
' Zapíše jeden textový riadok do otvoreného streamu.
'-------------------------------------------------------------------------------
Private Sub ZapisRiadok(ByVal s As String)
    If Not mStream Is Nothing Then mStream.WriteText s, 1
End Sub

'-------------------------------------------------------------------------------
' Uloží otvorený ADODB stream do súboru na disk a uvoľní pamäť.
'-------------------------------------------------------------------------------
Private Sub UlozVystup(ByVal cesta As String)
    mStream.SaveToFile cesta, 2
    mStream.Close: Set mStream = Nothing
End Sub

'-------------------------------------------------------------------------------
' Bezpečne zruší a uvoľní otvorený ADODB stream v prípade chyby.
'-------------------------------------------------------------------------------
Private Sub ZrusVystup()
    On Error Resume Next
    If Not mStream Is Nothing Then mStream.Close
    Set mStream = Nothing
End Sub

'-------------------------------------------------------------------------------
' Skenuje celý VBA projekt a generuje prehľadný index architektúry (0_INDEX_VBA_STRUKTURA.txt).
'-------------------------------------------------------------------------------
Public Sub ExportujIndexProcedur(Optional ByVal CestaExportFolder As String = "")
    On Error GoTo ChybaHandler
    Dim outFolder As String, txtPath As String
    Dim vbeProj As Object, vbComp As Object, codeMod As Object
    Dim i As Long, lineCount As Long, curLine As String
    Dim lastComment As String
    Dim isHeaderBlock As Boolean, cmtText As String

    outFolder = mod_00_Common.PripravAdresarExportu(CestaExportFolder)
    txtPath = outFolder & "0_INDEX_VBA_STRUKTURA.txt"

    Call mod_00_Common.PripravProgressForm
    Call OtvorVystup

    ZapisRiadok "================================================================================"
    ZapisRiadok " INDEX A MAPA VBA ARCHITEKTÚRY (ZOZNAM MODULOV, FUNKCIÍ A POPISOV)"
    ZapisRiadok " DÁTUM EXPORTU: " & Format$(Now, "yyyy-mm-dd hh:nn:ss")
    ZapisRiadok "================================================================================"

    Set vbeProj = Application.VBE.ActiveVBProject
    If vbeProj Is Nothing Then
        ZapisRiadok " [UPOZORNENIE] Nepodarilo sa získať prístup k VBA projektu."
        GoTo Koniec
    End If

    For Each vbComp In vbeProj.VBComponents
        Set codeMod = vbComp.CodeModule
        lineCount = codeMod.CountOfLines
        
        ZapisRiadok ""
        ZapisRiadok "--------------------------------------------------------------------------------"
        ZapisRiadok " MODUL: " & vbComp.Name & " (Typ: " & ZiskajTypComponentu(vbComp.Type) & ", Riadkov: " & lineCount & ")"
        ZapisRiadok "--------------------------------------------------------------------------------"

        lastComment = ""
        isHeaderBlock = True

        For i = 1 To lineCount
            curLine = Trim$(codeMod.Lines(i, 1))

            If Left$(curLine, 1) = "'" Then
                cmtText = Trim$(Mid$(curLine, 2))
                
                If isHeaderBlock And (InStr(1, cmtText, "POPIS:", vbTextCompare) > 0 Or InStr(1, cmtText, "MODUL:", vbTextCompare) > 0) Then
                    ZapisRiadok "  [HLAVIČKA] " & cmtText
                Else
                    If Left$(cmtText, 3) <> "===" And Left$(cmtText, 3) <> "---" Then
                        If Len(lastComment) > 0 Then lastComment = lastComment & " "
                        lastComment = lastComment & cmtText
                    End If
                End If
            Else
                If Len(curLine) > 0 Then isHeaderBlock = False

                If PreverARozoberDeklaraciu(curLine) Then
                    ZapisRiadok "  • " & curLine
                    If Len(lastComment) > 0 Then
                        ZapisRiadok "      Popis: " & lastComment
                        lastComment = ""
                    End If
                Else
                    If Len(curLine) > 0 Then lastComment = ""
                End If
            End If
        Next i
    Next vbComp

Koniec:
    Call UlozVystup(txtPath)
    Call mod_00_Common.ZavriProgressForm
    Exit Sub

ChybaHandler:
    Dim popis As String: popis = Err.Description
    Call ZrusVystup
    Call mod_00_Common.ZavriProgressForm
    Call mod_00_Common.ZapisLog("ExportujIndexProcedur", "ERROR", popis)
    MsgBox "Chyba pri generovaní indexu: " & popis, vbCritical
End Sub

'-------------------------------------------------------------------------------
' Preveruje, či riadok kódu predstavuje platnú deklaráciu funkcie alebo procedúry.
'-------------------------------------------------------------------------------
Private Function PreverARozoberDeklaraciu(ByVal sLine As String) As Boolean
    Dim l As String
    l = LCase$(sLine)
    
    If InStr(l, "declare sub") > 0 Or InStr(l, "declare function") > 0 Or InStr(l, "declare ptrsafe") > 0 Then
        PreverARozoberDeklaraciu = False
        Exit Function
    End If

    If Left$(l, 7) = "public " Or Left$(l, 8) = "private " Or Left$(l, 4) = "sub " Or Left$(l, 9) = "function " Or Left$(l, 9) = "property " Or Left$(l, 7) = "friend " Or Left$(l, 7) = "static " Then
        If InStr(l, "sub ") > 0 Or InStr(l, "function ") > 0 Or InStr(l, "property ") > 0 Then
            PreverARozoberDeklaraciu = True
        End If
    End If
End Function

'-------------------------------------------------------------------------------
' Generuje súbor 1_VBA_KOD_ANALYZAM.txt so všetkými modulmi projektu.
'-------------------------------------------------------------------------------
Public Sub ExportujIbaVBAKod(Optional ByVal CestaExportFolder As String = "")
    On Error GoTo ChybaHandler
    Dim outFolder As String, txtPath As String
    outFolder = mod_00_Common.PripravAdresarExportu(CestaExportFolder)
    txtPath = outFolder & "1_VBA_KOD_ANALYZAM.txt"

    Call mod_00_Common.PripravProgressForm
    Call OtvorVystup
    ZapisRiadok "================================================================================"
    ZapisRiadok " ZDROJOVÝ VBA KÓD DATABÁZY PRE ANALÝZU LOGIKY"
    ZapisRiadok " DÁTUM EXPORTU: " & Format$(Now, "yyyy-mm-dd hh:nn:ss")
    ZapisRiadok "================================================================================"

    Call GenerujVBAKod
    Call UlozVystup(txtPath)
    Call mod_00_Common.ZavriProgressForm
    Exit Sub

ChybaHandler:
    Dim popis As String: popis = Err.Description
    Call ZrusVystup: Call mod_00_Common.ZavriProgressForm
    Call mod_00_Common.ZapisLog("ExportujIbaVBAKod", "ERROR", popis)
    MsgBox "Chyba pri exporte VBA kódu: " & popis, vbCritical
End Sub

'-------------------------------------------------------------------------------
' Prechádza všetky VBA komponenty a zapisuje ich kompletný zdrojový kód do výstupného streamu.
'-------------------------------------------------------------------------------
Private Sub GenerujVBAKod()
    On Error GoTo ChybaVBA
    Dim vbeProj As Object, vbComp As Object, codeMod As Object
    Dim compCount As Long, curIdx As Long, totalLines As Long

    Set vbeProj = Application.VBE.ActiveVBProject
    If vbeProj Is Nothing Then
        ZapisRiadok " [UPOZORNENIE] Nepodarilo sa získať prístup k VBA projektu."
        Exit Sub
    End If

    compCount = vbeProj.VBComponents.Count
    For Each vbComp In vbeProj.VBComponents
        curIdx = curIdx + 1
        Set codeMod = vbComp.CodeModule
        totalLines = codeMod.CountOfLines
        Call mod_00_Common.AktualizujProgressGUI("[VBA 1/2] Exportujem kód modulov...", curIdx, compCount, vbComp.Name, "Riadkov v module: " & Format$(totalLines, "#,##0"))

        ZapisRiadok ""
        ZapisRiadok "--------------------------------------------------------------------------------"
        ZapisRiadok " MODUL / KÓD: " & vbComp.Name & " (Typ: " & ZiskajTypComponentu(vbComp.Type) & ", Riadkov: " & totalLines & ")"
        ZapisRiadok "--------------------------------------------------------------------------------"
        If totalLines > 0 Then ZapisRiadok codeMod.Lines(1, totalLines) Else ZapisRiadok "' (Modul neobsahuje žiadny kód)"
    Next vbComp
    Exit Sub

ChybaVBA:
    ZapisRiadok " [CHYBA pri exporte VBA modulov]: " & Err.Description
End Sub

'-------------------------------------------------------------------------------
' Preváda číselný typ VBA komponentu na slovenské pomenovanie.
'-------------------------------------------------------------------------------
Private Function ZiskajTypComponentu(ByVal compType As Long) As String
    Select Case compType
        Case 1: ZiskajTypComponentu = "Štandardný modul (StdModule)"
        Case 2: ZiskajTypComponentu = "Triedny modul (ClassModule)"
        Case 3: ZiskajTypComponentu = "Formulár (MSForm)"
        Case 100: ZiskajTypComponentu = "Dokument / Formulár / Zostava (Class)"
        Case Else: ZiskajTypComponentu = "Iný typ (" & compType & ")"
    End Select
End Function

'-------------------------------------------------------------------------------
' Generuje textový súbor s obsahom všetkých Access tabuliek (2_DATA_ACCESS_ANALYZAM.txt).
'-------------------------------------------------------------------------------
Public Sub ExportujIbaAccessTabulky(Optional ByVal CestaExportFolder As String = "", _
                                   Optional ByVal FilterDatumOd As Variant = Null, Optional ByVal FilterDatumDo As Variant = Null, _
                                   Optional ByVal MaxRiadkov As Long = 300)
    On Error GoTo ChybaHandler
    Dim outFolder As String, txtPath As String
    outFolder = mod_00_Common.PripravAdresarExportu(CestaExportFolder)
    txtPath = outFolder & "2_DATA_ACCESS_ANALYZAM.txt"

    Call mod_00_Common.PripravProgressForm
    Call OtvorVystup
    ZapisRiadok "================================================================================"
    ZapisRiadok " DÁTOVÝ EXPORT PRE ANALÝZU (IBA ACCESS TABUĽKY)"
    ZapisRiadok " DÁTUM EXPORTU: " & Format$(Now, "yyyy-mm-dd hh:nn:ss")
    If IsDate(FilterDatumOd) Or IsDate(FilterDatumDo) Then
        ZapisRiadok " FILTER OBDOBIA: " & IIf(IsDate(FilterDatumOd), Format$(FilterDatumOd, "yyyy-mm-dd"), "všetko") & " až " & IIf(IsDate(FilterDatumDo), Format$(FilterDatumDo, "yyyy-mm-dd"), "všetko")
    End If
    ZapisRiadok " LIMIT RIADKOV NA TABUĽKU: " & IIf(MaxRiadkov > 0, CStr(MaxRiadkov), "bez limitu")
    ZapisRiadok " ANONYMIZÁCIA: polia s menami, kontaktmi, adresami a DN sú nahradené textom Anonym_n"
    ZapisRiadok "================================================================================"

    ZapisRiadok ""
    ZapisRiadok "################################################################################"
    ZapisRiadok " TABUĽKY V ACCESS DATABÁZE"
    ZapisRiadok "################################################################################"
    Call ExportAccessTabulky(FilterDatumOd, FilterDatumDo, MaxRiadkov)

    Call UlozVystup(txtPath)
    Call mod_00_Common.ZavriProgressForm
    Exit Sub

ChybaHandler:
    Dim popis As String: popis = Err.Description
    Call ZrusVystup: Call mod_00_Common.ZavriProgressForm
    Call mod_00_Common.ZapisLog("ExportujIbaAccessTabulky", "ERROR", popis)
    MsgBox "Chyba pri exporte Access tabuliek: " & popis, vbCritical
End Sub

'-------------------------------------------------------------------------------
' Generuje textový súbor s obsahom všetkých zdrojových DBF súborov (3_DATA_DBF_ANALYZAM.txt).
'-------------------------------------------------------------------------------
Public Sub ExportujIbaDbfSubory(Optional ByVal CestaDBFFolder As String = "", Optional ByVal CestaExportFolder As String = "", _
                                Optional ByVal FilterDatumOd As Variant = Null, Optional ByVal FilterDatumDo As Variant = Null, _
                                Optional ByVal MaxRiadkov As Long = 300)
    On Error GoTo ChybaHandler
    Dim adr As String, outFolder As String, txtPath As String
    If Len(CestaDBFFolder) > 0 Then adr = CestaDBFFolder Else adr = mod_00_Common.GetNastavenie("CestaDBFAdresar", CurrentProject.Path & "\")
    If Right$(adr, 1) <> "\" Then adr = adr & "\"
    outFolder = mod_00_Common.PripravAdresarExportu(CestaExportFolder)
    txtPath = outFolder & "3_DATA_DBF_ANALYZAM.txt"

    Call mod_00_Common.PripravProgressForm
    Call OtvorVystup
    ZapisRiadok "================================================================================"
    ZapisRiadok " DÁTOVÝ EXPORT PRE ANALÝZU (IBA PÔVODNÉ DBF SÚBORY)"
    ZapisRiadok " DÁTUM EXPORTU: " & Format$(Now, "yyyy-mm-dd hh:nn:ss")
    If IsDate(FilterDatumOd) Or IsDate(FilterDatumDo) Then
        ZapisRiadok " FILTER OBDOBIA: " & IIf(IsDate(FilterDatumOd), Format$(FilterDatumOd, "yyyy-mm-dd"), "všetko") & " až " & IIf(IsDate(FilterDatumDo), Format$(FilterDatumDo, "yyyy-mm-dd"), "všetko")
    End If
    ZapisRiadok " LIMIT RIADKOV NA SÚBOR: " & IIf(MaxRiadkov > 0, CStr(MaxRiadkov), "bez limitu")
    ZapisRiadok " ANONYMIZÁCIA: polia s menami, kontaktmi, adresami a DN sú nahradené textom Anonym_n"
    ZapisRiadok "================================================================================"

    ZapisRiadok ""
    ZapisRiadok "################################################################################"
    ZapisRiadok " PÔVODNÉ DBF SÚBORY (binárny čítač, Windows-1250, bez zmazaných záznamov)"
    ZapisRiadok "################################################################################"
    Call ExportDbfSubory(adr, FilterDatumOd, FilterDatumDo, MaxRiadkov)

    Call UlozVystup(txtPath)
    Call mod_00_Common.ZavriProgressForm
    Exit Sub

ChybaHandler:
    Dim popis As String: popis = Err.Description
    Call ZrusVystup: Call mod_00_Common.ZavriProgressForm
    Call mod_00_Common.ZapisLog("ExportujIbaDbfSubory", "ERROR", popis)
    MsgBox "Chyba pri exporte DBF súborov: " & popis, vbCritical
End Sub

'-------------------------------------------------------------------------------
' Generuje kombinovaný export Access aj DBF dát do jedného súboru (2_DATA_ACCESS_DBF_ANALYZAM.txt).
'-------------------------------------------------------------------------------
Public Sub ExportujIbaData(Optional ByVal CestaDBFFolder As String = "", Optional ByVal CestaExportFolder As String = "", _
                           Optional ByVal FilterDatumOd As Variant = Null, Optional ByVal FilterDatumDo As Variant = Null, _
                           Optional ByVal MaxRiadkov As Long = 300)
    On Error GoTo ChybaHandler
    Dim adr As String, outFolder As String, txtPath As String
    If Len(CestaDBFFolder) > 0 Then adr = CestaDBFFolder Else adr = mod_00_Common.GetNastavenie("CestaDBFAdresar", CurrentProject.Path & "\")
    If Right$(adr, 1) <> "\" Then adr = adr & "\"
    outFolder = mod_00_Common.PripravAdresarExportu(CestaExportFolder)
    txtPath = outFolder & "2_DATA_ACCESS_DBF_ANALYZAM.txt"

    Call mod_00_Common.PripravProgressForm
    Call OtvorVystup
    ZapisRiadok "================================================================================"
    ZapisRiadok " DÁTOVÝ EXPORT PRE ANALÝZU IMPORTU (ACCESS TABUĽKY + DBF SÚBORY)"
    ZapisRiadok " DÁTUM EXPORTU: " & Format$(Now, "yyyy-mm-dd hh:nn:ss")
    If IsDate(FilterDatumOd) Or IsDate(FilterDatumDo) Then
        ZapisRiadok " FILTER OBDOBIA: " & IIf(IsDate(FilterDatumOd), Format$(FilterDatumOd, "yyyy-mm-dd"), "všetko") & " až " & IIf(IsDate(FilterDatumDo), Format$(FilterDatumDo, "yyyy-mm-dd"), "všetko")
    End If
    ZapisRiadok " LIMIT RIADKOV NA TABUĽKU/SÚBOR: " & IIf(MaxRiadkov > 0, CStr(MaxRiadkov), "bez limitu")
    ZapisRiadok " ANONYMIZÁCIA: polia s menami, kontaktmi, adresami a DN sú nahradené textom Anonym_n"
    ZapisRiadok "================================================================================"

    ZapisRiadok ""
    ZapisRiadok "################################################################################"
    ZapisRiadok " ČASŤ 1: TABUĽKY V ACCESS DATABÁZE"
    ZapisRiadok "################################################################################"
    Call ExportAccessTabulky(FilterDatumOd, FilterDatumDo, MaxRiadkov)

    ZapisRiadok ""
    ZapisRiadok "################################################################################"
    ZapisRiadok " ČASŤ 2: PÔVODNÉ DBF SÚBORY (binárny čítač, Windows-1250, bez zmazaných záznamov)"
    ZapisRiadok "################################################################################"
    Call ExportDbfSubory(adr, FilterDatumOd, FilterDatumDo, MaxRiadkov)

    Call UlozVystup(txtPath)
    Call mod_00_Common.ZavriProgressForm
    Exit Sub

ChybaHandler:
    Dim popis As String: popis = Err.Description
    Call ZrusVystup: Call mod_00_Common.ZavriProgressForm
    Call mod_00_Common.ZapisLog("ExportujIbaData", "ERROR", popis)
    MsgBox "Chyba pri exporte dát: " & popis, vbCritical
End Sub

'-------------------------------------------------------------------------------
' Čistí reťazec od neplatných znakov a orezáva dĺžku pre CSV export.
'-------------------------------------------------------------------------------
Private Function CisteHodnota(ByVal s As String) As String
    s = Replace(s, """", """""")
    s = Replace(s, vbCr, " ")
    s = Replace(s, vbLf, " ")
    If Len(s) > MAX_DLZKA_HODNOTY Then s = Left$(s, MAX_DLZKA_HODNOTY) & "..."
    CisteHodnota = s
End Function

'-------------------------------------------------------------------------------
' Zisťuje, či sa konkrétne pole nachádza v definícii Access tabuľky.
'-------------------------------------------------------------------------------
Private Function PoleExistujeTdf(ByVal tdf As DAO.TableDef, ByVal pole As String) As Boolean
    Dim f As DAO.Field
    On Error Resume Next
    Set f = tdf.Fields(pole)
    PoleExistujeTdf = (Err.Number = 0)
    Err.Clear
End Function

'-------------------------------------------------------------------------------
' Preváda číselný typ poľa Accessu na skrátený textový popis (TEXT, INT, LONG, DATE...).
'-------------------------------------------------------------------------------
Private Function TypPolaText(ByVal t As Long) As String
    Select Case t
        Case 1: TypPolaText = "BOOL"
        Case 3: TypPolaText = "INT"
        Case 4: TypPolaText = "LONG"
        Case 7: TypPolaText = "DBL"
        Case 8: TypPolaText = "DATE"
        Case 10: TypPolaText = "TEXT"
        Case 12: TypPolaText = "MEMO"
        Case Else: TypPolaText = "T" & t
    End Select
End Function

'-------------------------------------------------------------------------------
' Sostavuje podmienku WHERE pre SQL filter podľa rozsahu dátumov.
'-------------------------------------------------------------------------------
Private Function FiltrObdobiaSQL(ByVal tdf As DAO.TableDef, ByVal dtOd As Variant, ByVal dtDo As Variant) As String
    Dim p As String, w As String
    If Not (IsDate(dtOd) Or IsDate(dtDo)) Then Exit Function
    If PoleExistujeTdf(tdf, "Datum") Then
        p = "Datum"
    ElseIf PoleExistujeTdf(tdf, "DatumCas") Then
        p = "DatumCas"
    Else
        Exit Function
    End If
    If tdf.Fields(p).Type <> 8 Then Exit Function
    If IsDate(dtOd) Then w = "[" & p & "] >= #" & Format$(CDate(dtOd), "yyyy\-mm\-dd") & "#"
    If IsDate(dtDo) Then
        If Len(w) > 0 Then w = w & " AND "
        w = w & "[" & p & "] < #" & Format$(CDate(dtDo) + 1, "yyyy\-mm\-dd") & "#"
    End If
    FiltrObdobiaSQL = w
End Function

'-------------------------------------------------------------------------------
' Prechádza všetky používateľské tabuľky a zapisuje ich dáta do exportu.
'-------------------------------------------------------------------------------
Private Sub ExportAccessTabulky(ByVal dtOd As Variant, ByVal dtDo As Variant, ByVal maxR As Long)
    Dim db As DAO.Database, tdf As DAO.TableDef, pocetTab As Long, idx As Long
    Set db = CurrentDb
    For Each tdf In db.TableDefs
        If mod_00_Common.JeUzivatelskaTabulka(tdf) Then pocetTab = pocetTab + 1
    Next tdf

    For Each tdf In db.TableDefs
        If mod_00_Common.JeUzivatelskaTabulka(tdf) Then
            idx = idx + 1
            Call ExportJednaAccessTabulka(db, tdf, dtOd, dtDo, maxR, idx, pocetTab)
        End If
    Next tdf
End Sub

'-------------------------------------------------------------------------------
' Exportuje dáta z jednej konkrétnej Access tabuľky do textového streamu.
'-------------------------------------------------------------------------------
Private Sub ExportJednaAccessTabulka(ByVal db As DAO.Database, ByVal tdf As DAO.TableDef, ByVal dtOd As Variant, ByVal dtDo As Variant, ByVal maxR As Long, Optional ByVal idxTab As Long = 0, Optional ByVal celkovoTab As Long = 0)
    Dim rs As DAO.Recordset, sql As String, kde As String, i As Long, n As Long, line As String, v As String, sens() As Boolean, totalRecs As Long
    On Error GoTo ChybaHandler

    sql = "SELECT * FROM [" & tdf.Name & "]"
    kde = FiltrObdobiaSQL(tdf, dtOd, dtDo)
    If Len(kde) > 0 Then sql = sql & " WHERE " & kde

    ZapisRiadok ""
    ZapisRiadok "--------------------------------------------------------------------------------"
    ZapisRiadok " TABUĽKA ACCESS: " & tdf.Name & IIf(Len(kde) > 0, "   [filter: " & kde & "]", "")
    ZapisRiadok "--------------------------------------------------------------------------------"

    Set rs = db.OpenRecordset(sql, dbOpenSnapshot)
    If Not rs.EOF Then
        rs.MoveLast
        totalRecs = rs.RecordCount
        rs.MoveFirst
    End If

    Call mod_00_Common.AktualizujProgressGUI("[ACCESS 1/2] Spracovávam tabuľku: " & tdf.Name, idxTab, celkovoTab, tdf.Name, "Záznamov: 0 / " & Format$(totalRecs, "#,##0"))
    ReDim sens(0 To rs.Fields.Count - 1)
    line = ""
    For i = 0 To rs.Fields.Count - 1
        sens(i) = mod_00_Common.JeCitlivePole(rs.Fields(i).Name)
        line = line & IIf(i > 0, ";", "") & """" & rs.Fields(i).Name & ":" & TypPolaText(rs.Fields(i).Type) & """"
    Next i
    ZapisRiadok line

    Do While Not rs.EOF
        n = n + 1
        If maxR <= 0 Or n <= maxR Then
            line = ""
            For i = 0 To rs.Fields.Count - 1
                If sens(i) Then v = "Anonym_" & n Else v = CisteHodnota(CStr(Nz(rs.Fields(i).Value, "")))
                line = line & IIf(i > 0, ";", "") & """" & v & """"
            Next i
            ZapisRiadok line
        End If

        If (n Mod 100) = 0 Or n = 1 Or n = totalRecs Then
            Call mod_00_Common.AktualizujProgressGUI("[ACCESS 1/2] Tabuľka: " & tdf.Name, idxTab, celkovoTab, tdf.Name, "Riadky: " & Format$(n, "#,##0") & " / " & Format$(totalRecs, "#,##0"))
        End If
        rs.MoveNext
    Loop
    rs.Close

    Call mod_00_Common.AktualizujProgressGUI("[ACCESS 1/2] Dokončená tabuľka: " & tdf.Name, idxTab, celkovoTab, tdf.Name, "Spolu spracovaných: " & Format$(n, "#,##0") & " riadkov")
    If maxR > 0 And n > maxR Then ZapisRiadok "# ... vynechaných " & (n - maxR) & " riadkov (celkom " & n & ")"
    If n = 0 Then ZapisRiadok "# (tabuľka je prázdna)"
    Exit Sub

ChybaHandler:
    ZapisRiadok " [CHYBA pri exporte tabuľky " & tdf.Name & "] " & Err.Number & ": " & Err.Description
    On Error Resume Next
    If Not rs Is Nothing Then rs.Close
End Sub

'-------------------------------------------------------------------------------
' Prechádza všetky DBF súbory v zadanom adresári a volá ich spracovanie.
'-------------------------------------------------------------------------------
Private Sub ExportDbfSubory(ByVal adr As String, ByVal dtOd As Variant, ByVal dtDo As Variant, ByVal maxR As Long)
    Dim subory() As String, pocet As Long, nm As String, i As Long
    nm = Dir(adr & "*.dbf")
    Do While Len(nm) > 0
        If LCase$(Right$(nm, 4)) = ".dbf" Then
            pocet = pocet + 1
            ReDim Preserve subory(1 To pocet)
            subory(pocet) = nm
        End If
        nm = Dir()
    Loop

    If pocet = 0 Then
        ZapisRiadok " (V adresári " & adr & " nie sú žiadne súbory DBF.)"
        Exit Sub
    End If

    For i = 1 To pocet
        Call ExportJedenDbf(adr & subory(i), subory(i), i, pocet, dtOd, dtDo, maxR)
    Next i
End Sub

'-------------------------------------------------------------------------------
' Číta binárnu štruktúru jedného DBF súboru a zapisuje jeho dáta do textového streamu.
'-------------------------------------------------------------------------------
Private Sub ExportJedenDbf(ByVal cesta As String, ByVal nazovSuboru As String, ByVal idxSuboru As Long, ByVal pocetSuborov As Long, _
                           ByVal dtOd As Variant, ByVal dtDo As Variant, ByVal maxR As Long)
    Dim t As DbfTab, i As Long, n As Long, line As String, v As String
    Dim sens() As Boolean, struktura As String, jeDoch As Boolean, iDat As Long, ymd As Long, ymdOd As Long, ymdDo As Long, vyhovuje As Boolean, filtruje As Boolean, lastUIUpdate As Single
    On Error GoTo ChybaHandler

    Call mod_00_Common.AktualizujProgressGUI("[DBF 2/2] Otváram súbor: " & nazovSuboru, idxSuboru, pocetSuborov, nazovSuboru, "Otváram DBF...")
    ZapisRiadok ""
    ZapisRiadok "--------------------------------------------------------------------------------"
    If Not DbfOtvor(cesta, t) Then
        ZapisRiadok " SÚBOR DBF: " & nazovSuboru & " - NEPODARILO SA OTVORIŤ (podrobnosti v tabuľke LogImportu)"
        Call mod_00_Common.AktualizujProgressGUI("[DBF 2/2] Chyba otvorenia: " & nazovSuboru, idxSuboru, pocetSuborov, nazovSuboru, "Nepodarilo sa otvoriť súbor")
        Exit Sub
    End If

    For i = 0 To t.PocetPoli - 1
        struktura = struktura & IIf(i > 0, ", ", "") & t.nazov(i) & ":" & t.Typ(i) & t.Dlzka(i)
    Next i
    ZapisRiadok " SÚBOR DBF: " & nazovSuboru & " (formát " & IIf(t.Format7, "dBase 7", "dBase III/IV") & ", kódovanie " & t.CodePage & ", záznamov v súbore: " & t.PocetZaznamov & ")"
    ZapisRiadok " ŠTRUKTÚRA: " & struktura
    ZapisRiadok "--------------------------------------------------------------------------------"

    If UCase$(nazovSuboru) Like "*DOCHDATA*" Or UCase$(nazovSuboru) Like "*DOCH_DATA*" Then jeDoch = True
    iDat = DbfIdx(t, "DATUM")
    If jeDoch And iDat >= 0 And (IsDate(dtOd) Or IsDate(dtDo)) Then
        filtruje = True: ymdOd = 0: ymdDo = 99999999
        If IsDate(dtOd) Then ymdOd = Year(CDate(dtOd)) * 10000 + Month(CDate(dtOd)) * 100 + Day(CDate(dtOd))
        If IsDate(dtDo) Then ymdDo = Year(CDate(dtDo)) * 10000 + Month(CDate(dtDo)) * 100 + Day(CDate(dtDo))
    End If

    ReDim sens(0 To t.PocetPoli - 1)
    line = ""
    For i = 0 To t.PocetPoli - 1
        sens(i) = mod_00_Common.JeCitlivePole(t.nazov(i))
        line = line & IIf(i > 0, ";", "") & """" & t.nazov(i) & """"
    Next i
    ZapisRiadok line

    lastUIUpdate = Timer
    Do While DbfDalsi(t)
        vyhovuje = True
        If filtruje Then
            ymd = DbfYmdI(t, iDat)
            If ymd < ymdOd Or ymd > ymdDo Then vyhovuje = False
        End If

        If vyhovuje Then
            n = n + 1
            If maxR <= 0 Or n <= maxR Then
                line = ""
                For i = 0 To t.PocetPoli - 1
                    If sens(i) Then v = "Anonym_" & n Else v = CisteHodnota(DbfHodnotaStrI(t, i))
                    line = line & IIf(i > 0, ";", "") & """" & v & """"
                Next i
                ZapisRiadok line
            End If
        End If

        If (Timer - lastUIUpdate > 0.2) Or (t.Prejdenych = t.PocetZaznamov) Then
            Call mod_00_Common.AktualizujProgressGUI("[DBF 2/2] Spracovávam: " & nazovSuboru, idxSuboru, pocetSuborov, nazovSuboru, "Prečítané: " & Format$(t.Prejdenych, "#,##0") & " / " & Format$(t.PocetZaznamov, "#,##0") & " (exportované: " & n & ")")
            lastUIUpdate = Timer
        End If
    Loop

    Call mod_00_Common.AktualizujProgressGUI("[DBF 2/2] Dokončený súbor: " & nazovSuboru, idxSuboru, pocetSuborov, nazovSuboru, "Celkom v súbore: " & Format$(t.PocetZaznamov, "#,##0") & " (exportované: " & n & ")")
    If maxR > 0 And n > maxR Then ZapisRiadok "# ... vynechaných " & (n - maxR) & " záznamov (vyhovujúcich celkom " & n & ")"
    If n = 0 Then ZapisRiadok "# (žiadne vyhovujúce nezmazané záznamy)"
    Call DbfZatvor(t)
    Exit Sub

ChybaHandler:
    ZapisRiadok " [CHYBA pri čítaní súboru " & nazovSuboru & "] " & Err.Number & ": " & Err.Description
    On Error Resume Next
    Call DbfZatvor(t)
End Sub


