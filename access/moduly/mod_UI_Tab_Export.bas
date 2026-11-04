Attribute VB_Name = "mod_UI_Tab_Export"
'@Verzia 2.11.1
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_UI_Tab_Export
' POPIS: Sub-modul pre záložku 5 - Exporty JSON konfigurácií pre Lovable Cloud.
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - IsAvailable()                     : Kontroluje dostupnosť záložky v UI.
' - GetTabCaption()                   : Vrací názov záložky pre exporty.
' - BuildUI(strFrmName, strPageName)  : Generuje prvky UI pre export JSON dát.
' - InitDefaults(frm)                 : Inicializuje predvolené parametre exportu.
' - VyberExportFolder_Click()         : Otvára dialóg pre výber cieľového adresára.
' - SpustiExportLovableUI()           : Spúšťa export konfigurácie a testovacích dát.
'===============================================================================

'-------------------------------------------------------------------------------
' Kontroluje dostupnosť záložky 5 (Exporty & Lovable Cloud).
'-------------------------------------------------------------------------------
Public Function IsAvailable() As Boolean
    IsAvailable = True
End Function

'-------------------------------------------------------------------------------
' Vrací názov záložky pre exporty dát a konfigurácie.
'-------------------------------------------------------------------------------
Public Function GetTabCaption() As String
    GetTabCaption = "7. Exporty & Lovable Cloud"
End Function

'-------------------------------------------------------------------------------
' Generuje formulárové prvky a filtre pre export JSON konfigurácie a testovacích dát.
'-------------------------------------------------------------------------------
Public Sub BuildUI(ByVal strFrmName As String, ByVal strPageName As String)
    On Error GoTo ChybaHandler
    Dim ctl As Control, btn As Control

    ' Nadpis sekcie
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 1100, 9500, 300)
    ctl.Caption = "Export konfigurácie a testovacích dát pre Lovable Cloud / AI Agenta"
    ctl.FontBold = True: ctl.FontSize = 10: ctl.ForeColor = RGB(15, 30, 90)

    ' Popisný text
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 1500, 9500, 600)
    ctl.Caption = "Generuje produkčný súbor dochs_config.json (pravidlá, fondy, číselníky) " & _
                  "a testovací súbor dochs_test_sample.json (surové razenia a očakávané výsledky na overenie logiky)."
    ctl.ForeColor = RGB(80, 80, 80)

    ' --- FILTRE A CESTA ---
    ' Cesta pre export
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 2300, 2000, 300)
    ctl.Caption = "Cesta pre export súborov:"

    Set ctl = CreateControl(strFrmName, acTextBox, acDetail, strPageName, "", 2600, 2300, 5800, 300)
    ctl.Name = "txtCestaExportFolder"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 8500, 2300, 1500, 300)
    btn.Name = "btnVyberExportFolder"
    btn.Caption = "Prehľadávať..."
    btn.OnClick = "=VyberExportFolder_Click()"

    ' Obdobie (mesiac zo zoznamu)
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 2700, 2000, 300)
    ctl.Caption = "Mesiac:"
    Call mod_UI_Spolocne.VytvorVyberMesiaca(strFrmName, strPageName, "cboExportObdobie", 2600, 2680, 2400)

    ' Filter Osobných čísel
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 3100, 2000, 300)
    ctl.Caption = "Osobné čísla:"

    Set ctl = CreateControl(strFrmName, acTextBox, acDetail, strPageName, "", 2600, 3100, 5800, 300)
    ctl.Name = "txtExportOSC"
    ctl.ControlTipText = "Prázdne = všetci. Oddeľovač sa rozpozná sám (čiarka, bodkočiarka, medzera, nový riadok), rozsah 1001-1010."

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 8500, 3100, 1500, 300)
    ctl.Caption = "(prázdne = všetci)"
    ctl.ForeColor = RGB(120, 120, 120)

    ' --- HLAVNÉ TLAČIDLO ---
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 3800, 9500, 600)
    btn.Name = "btnSpustitExportLovable"
    btn.Caption = "EXPORTOVAŤ KONFIGURÁCIU A TESTOVACIE DÁTA (JSON)"
    btn.FontBold = True: btn.FontSize = 10: btn.ForeColor = RGB(0, 100, 0)
    btn.OnClick = "=SpustiExportLovableUI()"

    ' --- PRÍPRAVA KOMUNIKÁCIE S TERMINÁLOM (zatiaľ len súbor / inbox, bez API) ---
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 4600, 9500, 500)
    btn.Name = "btnExportKonfigTerminal"
    btn.Caption = "Vytvoriť verziu konfigurácie prerušení pre terminál (JSON bez osobných údajov)"
    btn.OnClick = "=SpustiExportKonfigTerminalUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 5250, 9500, 500)
    btn.Name = "btnSpracujInboxTerminal"
    btn.Caption = "Spracovať prijaté pípnutia z terminálu (TerminalInbox -> DochadzkaImport)"
    btn.OnClick = "=SpustiSpracujInboxUI()"

    ' --- IMPORT SÚBORU Z TERMINÁLA (kontrakt v1) A SAMOČINNÝ TEST ---
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 5900, 9500, 500)
    btn.Name = "btnImportSuboruTerminal"
    btn.Caption = "Importovať súbor z terminála (punches_*.csv alebo voids_*.csv)..."
    btn.OnClick = "=SpustiImportSuboruTerminaluUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 6550, 9500, 500)
    btn.Name = "btnSamoTestTerminal"
    btn.Caption = "Samočinný test terminála (zapíše terminal_test_report.txt)"
    btn.OnClick = "=SpustiSamoTestTerminaluUI()"

    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Export.BuildUI", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Inicializuje predvolené parametre exportu (cieľový adresár, mesiac, rok).
'-------------------------------------------------------------------------------
Public Sub InitDefaults(ByRef frm As Form)
    On Error Resume Next
    frm!txtCestaExportFolder = CurrentProject.Path & "\"
    Dim d As Date: d = DateAdd("m", -1, Date)
    Call mod_UI_Spolocne.NastavVyberMesiaca(frm!cboExportObdobie, Year(d), Month(d))
    frm!txtExportOSC = Null
End Sub

'-------------------------------------------------------------------------------
' Otvára dialóg pre výber cieľového adresára pre exportované súbory.
'-------------------------------------------------------------------------------
Public Function VyberExportFolder_Click() As Boolean
    On Error Resume Next
    Dim adr As String
    ' vlastný dialóg (VyberAdresarDBF má titulok pre DBF a prepisoval by uloženú cestu k DBF súborom)
    Dim fd As Object
    Set fd = Application.FileDialog(4)
    fd.Title = "Vyberte priečinok pre exportované súbory (JSON)"
    fd.InitialFileName = Nz(Forms!frmHlavnaKonzola!txtCestaExportFolder, CurrentProject.Path & "\")
    If fd.Show = -1 Then adr = fd.SelectedItems(1)
    If Len(adr) > 0 Then
        If Right$(adr, 1) <> "\" Then adr = adr & "\"
        Forms!frmHlavnaKonzola!txtCestaExportFolder = adr
    End If
    VyberExportFolder_Click = True
End Function

'-------------------------------------------------------------------------------
' Spúšťa export konfigurácie a testovacích vzoriek pre Lovable Cloud v JSON formáte.
'-------------------------------------------------------------------------------
Public Function SpustiExportLovableUI() As Boolean
    On Error GoTo ChybaHandler
    Dim frm As Form: Set frm = Forms!frmHlavnaKonzola
    Dim lRok As Long, lMes As Long, strNez As String, lPocet As Long
    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboExportObdobie, lRok, lMes) Then
        MsgBox "Vyberte mesiac zo zoznamu.", vbExclamation, "Export"
        Exit Function
    End If
    Dim iMesiac As Integer: iMesiac = CInt(lMes)
    Dim iRok As Integer: iRok = CInt(lRok)
    Dim strOsc As String: strOsc = Trim(Nz(frm!txtExportOSC, ""))
    Dim strFolder As String: strFolder = Trim(Nz(frm!txtCestaExportFolder, CurrentProject.Path & "\"))

    ' Osobné čísla: ľubovoľný oddeľovač -> SQL zoznam 'a','b'
    If Len(strOsc) > 0 Then
        strOsc = mod_UI_Spolocne.OsobneCislaSql(strOsc, strNez, lPocet)
        If lPocet = 0 Then
            MsgBox "V poli osobných čísel sa nenašlo žiadne číslo.", vbExclamation, "Export"
            Exit Function
        End If
        If Len(strNez) > 0 Then
            If MsgBox("Tieto osobné čísla nie sú v zozname zamestnancov:" & vbCrLf & Left$(strNez, 500) & vbCrLf & vbCrLf & "Pokračovať?", vbQuestion + vbYesNo, "Export") <> vbYes Then Exit Function
        End If
    End If

    Call mod_06_AdminTools.ExportujLovableKonfiguraciu(DateSerial(iRok, iMesiac, 1), DateSerial(iRok, iMesiac + 1, 0), strOsc, strFolder)
    Call mod_UI_Pomocnik.OznacCinnost("EXPORT")
    SpustiExportLovableUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri exporte pre Lovable: " & Err.Description, vbCritical
    SpustiExportLovableUI = False
End Function



'-------------------------------------------------------------------------------
' Vytvorí novú verziu konfigurácie prerušení (KonfiguraciaVerzie) a uloží ju ako JSON do vybraného priečinka.
'-------------------------------------------------------------------------------
Public Function SpustiExportKonfigTerminalUI() As Boolean
    On Error GoTo ChybaHandler
    Dim frm As Form: Set frm = Forms!frmHlavnaKonzola
    Dim strFolder As String: strFolder = Trim(Nz(frm!txtCestaExportFolder, CurrentProject.Path & "\"))
    Dim strCesta As String
    strCesta = mod_12_TerminalPriprava.ExportujKonfiguraciuDoSuboru(strFolder)
    If Len(strCesta) = 0 Then
        MsgBox "Konfiguráciu pre terminál sa nepodarilo zostaviť, súbor sa nezapísal." & vbCrLf & mod_20_KonfiguraciaExport.SpravaExportu(), vbExclamation, "Export konfigurácie"
        Exit Function
    End If
    MsgBox "Konfigurácia pre terminál bola uložená:" & vbCrLf & strCesta & vbCrLf & vbCrLf & mod_20_KonfiguraciaExport.SpravaExportu(), vbInformation, "Export konfigurácie"
    Call mod_UI_Pomocnik.OznacCinnost("EXPORT")
    SpustiExportKonfigTerminalUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri exporte konfigurácie: " & Err.Description, vbCritical
End Function

'-------------------------------------------------------------------------------
' Spracuje nové záznamy z TerminalInbox (idempotentne podľa ExterneID).
'-------------------------------------------------------------------------------
Public Function SpustiSpracujInboxUI() As Boolean
    On Error GoTo ChybaHandler
    MsgBox mod_12_TerminalPriprava.SpracujInbox(), vbInformation, "Inbox terminálu"
    Call mod_UI_Pomocnik.OznacCinnost("EXPORT")
    SpustiSpracujInboxUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri spracovaní inboxu: " & Err.Description, vbCritical
End Function

'-------------------------------------------------------------------------------
' Import súboru z terminála: overenie (pätička, reťaz), mapovanie kódov a zápis do fronty. Najprv sa ponúkne beh nanečisto.
'-------------------------------------------------------------------------------
Public Function SpustiImportSuboruTerminaluUI() As Boolean
    On Error GoTo ChybaHandler
    Dim strCesta As String, odp As VbMsgBoxResult, strRep As String, strSub As String, bVoids As Boolean
    With Application.FileDialog(3)
        .Title = "Vyberte súbor z terminála (punches_*.csv alebo voids_*.csv)"
        .AllowMultiSelect = False
        .Filters.Clear
        .Filters.Add "CSV z terminála", "*.csv"
        If .Show = -1 Then strCesta = .SelectedItems(1)
    End With
    If Len(strCesta) = 0 Then Exit Function
    ' voids_*.csv = zoznam zneplatnených razení (kontrakt v1.1); importuje sa až po súbore s razeniami za ten istý mesiac
    bVoids = mod_19_TerminalImport.JeSuborZneplatneni(strCesta)
    If bVoids Then
        odp = MsgBox("Súbor obsahuje ZNEPLATNENÉ RAZENIA (voids)." & vbCrLf & vbCrLf & "Ako spustiť import?" & vbCrLf & _
                     "Áno = naozaj (razenia sa označia ako neplatné; nič sa nemaže)" & vbCrLf & _
                     "Nie = nanečisto (iba ukáže, čo by sa stalo)" & vbCrLf & vbCrLf & _
                     "Najprv musí byť importovaný súbor s razeniami (punches_*.csv) za ten istý mesiac.", vbQuestion + vbYesNoCancel, "Import zneplatnených razení")
    Else
        odp = MsgBox("Ako spustiť import?" & vbCrLf & vbCrLf & "Áno = naozaj (zapíše razenia do fronty a spracuje ich)" & vbCrLf & _
                     "Nie = nanečisto (iba overí súbor a ukáže, ako sa kódy previedu)", vbQuestion + vbYesNoCancel, "Import z terminála")
    End If
    If odp = vbCancel Then Exit Function
    If bVoids Then
        strRep = mod_19_TerminalImport.ImportujZneplatnenia(strCesta, (odp = vbNo), False)
    Else
        strRep = mod_19_TerminalImport.ImportujSubor(strCesta, (odp = vbNo), True)
    End If
    strSub = CurrentProject.Path & "\terminal_import_report.txt"
    Call mod_00_Common.UlozUTF8Sustor(strSub, strRep)
    MsgBox Left$(strRep, 1800) & vbCrLf & vbCrLf & "Celý report: " & strSub, vbInformation, IIf(bVoids, "Import zneplatnených razení", "Import z terminála")
    Call mod_UI_Pomocnik.OznacCinnost("EXPORT")
    SpustiImportSuboruTerminaluUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri importe z terminála: " & Err.Description, vbCritical
End Function

'-------------------------------------------------------------------------------
' Samočinný test terminála (SHA-256, mapovanie, nanečisto, voliteľne ostrý import testovacích zamestnancov 90000xx).
'-------------------------------------------------------------------------------
Public Function SpustiSamoTestTerminaluUI() As Boolean
    On Error GoTo ChybaHandler
    Dim strRep As String, odp As VbMsgBoxResult
    odp = MsgBox("Čo otestovať?" & vbCrLf & vbCrLf & "Áno = import razení (punches / terminal_test_*.csv)" & vbCrLf & _
                 "Nie = zneplatnenia (voids_*.csv; až po teste razení nad tými istými testovacími údajmi)", vbQuestion + vbYesNoCancel, "Samočinný test terminála")
    If odp = vbCancel Then Exit Function
    If odp = vbYes Then
        strRep = mod_19_TerminalImport.SamoTestTerminalu()
    Else
        strRep = mod_19_TerminalImport.SamoTestZneplatneni()
    End If
    MsgBox Left$(strRep, 1800), vbInformation, "Samočinný test terminála"
    SpustiSamoTestTerminaluUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba samočinného testu: " & Err.Description, vbCritical
End Function
