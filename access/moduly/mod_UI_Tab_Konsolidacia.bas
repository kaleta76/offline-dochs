Attribute VB_Name = "mod_UI_Tab_Konsolidacia"
'@Verzia 2.5.1
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_UI_Tab_Konsolidacia
' POPIS: Záložka 3 UI - Konsolidácia dát, kontrola pípnutí a AUTOMATICKÉ OPRAVY.
'        Sekretárka tu pred tlačou výkazov vidí, čo systém opravil sám, čo navrhuje
'        na schválenie a čo ostalo na ručné posúdenie (potom editor dochádzky).
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - IsAvailable(), GetTabCaption(), BuildUI(...), InitDefaults(frm)
' - SpustiSkontrolovanieStavuUI()   : Stav pripravenosti dát.
' - SpustiKonsolidaciuUI()          : Konsolidácia importovaných dát.
' - AoAnalyzujUI()                  : Analýza mesiaca a generovanie opráv.
' - AoObnovUI()                     : Obnoví zoznamy podľa filtra.
' - AoSchvalVsetkyUI / AoSchvalVybranuUI / AoZamietniVybranuUI / AoVratVybranuUI : Rozhodnutia.
' - AoZmenRezimUI()                 : Uloží zvolený režim automatických opráv.
'===============================================================================

Public Function IsAvailable() As Boolean
    IsAvailable = True
End Function

Public Function GetTabCaption() As String
    GetTabCaption = "3. Kontrola & Auto-oprava"
End Function

Public Sub BuildUI(ByVal strFrmName As String, ByVal strPageName As String)
    On Error GoTo ChybaHandler
    Dim ctl As Control, btn As Control

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 1100, 9500, 300)
    ctl.Caption = "Dátová hygiena, kontrola pípnutí a automatické opravy chýbajúcich záznamov"
    ctl.FontBold = True: ctl.FontSize = 10: ctl.ForeColor = RGB(15, 30, 90)

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 1450, 4600, 450)
    btn.Name = "btnOverPripravenost"
    btn.Caption = "OVERIŤ PRIPRAVENOSŤ DÁT (KONTROLA DB)"
    btn.FontBold = True
    btn.OnClick = "=SpustiSkontrolovanieStavuUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 5200, 1450, 4800, 450)
    btn.Name = "btnSpustiKonsolidaciuTab"
    btn.Caption = "SPUSTIŤ KONSOLIDÁCIU OBDOBIA"
    btn.FontBold = True: btn.ForeColor = RGB(0, 100, 0)
    btn.OnClick = "=SpustiKonsolidaciuUI()"

    ' --- Automatické opravy ---
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 2050, 9500, 300)
    ctl.Caption = "Automatické opravy pípnutí (pôvodné razenia sa nemenia - opravy sú len virtuálne a vždy sa dajú zamietnuť)"
    ctl.FontBold = True: ctl.ForeColor = RGB(15, 30, 90)

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 2450, 700, 300)
    ctl.Caption = "Mesiac:"
    Call mod_UI_Spolocne.VytvorVyberMesiaca(strFrmName, strPageName, "cboAoObdobie", 1200, 2400, 2200, "=AoObnovUI()")

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 3500, 2450, 800, 300)
    ctl.Caption = "Režim:"
    Set ctl = CreateControl(strFrmName, acComboBox, acDetail, strPageName, "", 4300, 2400, 5700, 330)
    ctl.Name = "cboAoRezim"
    ctl.RowSourceType = "Value List"
    ctl.RowSource = "0;Vypnuté (len kontrola);1;Isté opravy automaticky, odhady na schválenie;2;Všetko automaticky (odhady ostanú na kontrole)"
    ctl.ColumnCount = 2
    ctl.ColumnWidths = "0;5600"
    ctl.BoundColumn = 1
    ctl.LimitToList = True
    ctl.AfterUpdate = "=AoZmenRezimUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 2850, 2300, 450)
    btn.Name = "btnAoAnalyzuj"
    btn.Caption = "ANALYZOVAŤ MESIAC"
    btn.FontBold = True: btn.ForeColor = RGB(0, 100, 0)
    btn.OnClick = "=AoAnalyzujUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 2900, 2850, 1800, 450)
    btn.Name = "btnAoSchvalVsetky"
    btn.Caption = "Schváliť všetky"
    btn.OnClick = "=AoSchvalVsetkyUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 4800, 2850, 1800, 450)
    btn.Name = "btnAoSchvalVybranu"
    btn.Caption = "Schváliť vybranú"
    btn.OnClick = "=AoSchvalVybranuUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 6700, 2850, 1800, 450)
    btn.Name = "btnAoZamietni"
    btn.Caption = "Zamietnuť vybranú"
    btn.OnClick = "=AoZamietniVybranuUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 8600, 2850, 1400, 450)
    btn.Name = "btnAoVrat"
    btn.Caption = "Vrátiť na návrh"
    btn.OnClick = "=AoVratVybranuUI()"

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 3450, 1300, 300)
    ctl.Caption = "Zobraziť opravy:"
    Set ctl = CreateControl(strFrmName, acComboBox, acDetail, strPageName, "", 1850, 3400, 2300, 330)
    ctl.Name = "cboAoStav"
    ctl.RowSourceType = "Value List"
    ctl.RowSource = "NAVRH;Návrhy na schválenie;UPLATNENE;Uplatnené;ZAMIETNUTE;Zamietnuté;ZASTARANE;Zastarané;VSETKY;Všetky"
    ctl.ColumnCount = 2
    ctl.ColumnWidths = "0;2300"
    ctl.BoundColumn = 1
    ctl.LimitToList = True
    ctl.AfterUpdate = "=AoObnovUI()"

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 4300, 3450, 5700, 300)
    ctl.Name = "lblAoStav"
    ctl.Caption = ""
    ctl.FontBold = True: ctl.ForeColor = RGB(15, 30, 90)

    Set ctl = CreateControl(strFrmName, acListBox, acDetail, strPageName, "", 500, 3850, 9500, 2400)
    ctl.Name = "lstAoOpravy"
    ctl.ColumnCount = 7
    ctl.ColumnHeads = True
    ctl.ColumnWidths = "0;1100;1100;800;600;1200;4700"
    ctl.BoundColumn = 1

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 6350, 9500, 300)
    ctl.Caption = "Na ručné posúdenie (opraviť v editore dochádzky, záložka 4):"
    ctl.FontBold = True

    Set ctl = CreateControl(strFrmName, acListBox, acDetail, strPageName, "", 500, 6700, 9500, 2400)
    ctl.Name = "lstAoAnomalie"
    ctl.ColumnCount = 4
    ctl.ColumnHeads = True
    ctl.ColumnWidths = "1100;1100;2400;4900"

    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Konsolidacia.BuildUI", "ERROR", Err.Description)
End Sub

Public Sub InitDefaults(ByRef frm As Form)
    On Error Resume Next
    Dim d As Date
    d = DateAdd("m", -1, Date)
    Call mod_UI_Spolocne.NastavVyberMesiaca(frm!cboAoObdobie, Year(d), Month(d))
    frm!cboAoRezim = mod_09_AutoOprava.RezimAutoOpravy()
    frm!cboAoStav = "NAVRH"
    Call mod_09_AutoOprava.AO_Obnov
End Sub

Public Function SpustiSkontrolovanieStavuUI() As Boolean
    On Error GoTo ChybaHandler
    Dim strDetail As String, lStav As Long
    lStav = mod_04_DataConsolidation.ZistiStavPripravenostiData(0, 0, strDetail)
    MsgBox "Stav pripravenosti dát (Kód " & lStav & "):" & vbCrLf & vbCrLf & strDetail, vbInformation, "Kontrola pripravenosti dát"
    SpustiSkontrolovanieStavuUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri kontrole stavu: " & Err.Description, vbCritical
End Function

Public Function SpustiKonsolidaciuUI() As Boolean
    On Error GoTo ChybaHandler
    SpustiKonsolidaciuUI = mod_04_DataConsolidation.SpracujKonsolidaciuObdobia(0, 0)
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri spúšťaní konsolidácie: " & Err.Description, vbCritical
End Function

Public Function AoAnalyzujUI() As Boolean
    AoAnalyzujUI = mod_09_AutoOprava.AO_Analyzuj()
End Function

Public Function AoObnovUI() As Boolean
    AoObnovUI = mod_09_AutoOprava.AO_Obnov()
End Function

Public Function AoSchvalVsetkyUI() As Boolean
    AoSchvalVsetkyUI = mod_09_AutoOprava.AO_SchvalVsetky()
End Function

Public Function AoSchvalVybranuUI() As Boolean
    AoSchvalVybranuUI = mod_09_AutoOprava.AO_SchvalVybranu()
End Function

Public Function AoZamietniVybranuUI() As Boolean
    AoZamietniVybranuUI = mod_09_AutoOprava.AO_ZamietniVybranu()
End Function

Public Function AoVratVybranuUI() As Boolean
    AoVratVybranuUI = mod_09_AutoOprava.AO_VratVybranu()
End Function

Public Function AoZmenRezimUI() As Boolean
    AoZmenRezimUI = mod_09_AutoOprava.AO_ZmenRezim()
End Function
