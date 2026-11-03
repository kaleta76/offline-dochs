Attribute VB_Name = "mod_UI_Tab_Import"
'@Verzia 2.7.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_UI_Tab_Import
' POPIS: Sub-modul pre záložku 1 - Import DBF dát a čiastkových číselníkov.
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - IsAvailable()                     : Kontroluje dostupnosť záložky v UI konzole.
' - GetTabCaption()                   : Vrací názov záložky pre hlavnú konzolu.
' - BuildUI(strFrmName, strPageName)  : Dynamicky generuje prvky užívateľského rozhrania.
' - InitDefaults(frm)                 : Nastavuje predvolené hodnoty polí formulára.
' - VyberAdresarDBF_Click()           : Otvára dialóg pre výber adresára DBF súborov.
' - ImportObdobieTentoRokUI / ImportObdobieMinulyMesiacUI : Rýchla voľba obdobia.
' - PridajZadaneOCUI()                : Pridá osobné čísla zadané textom do tabuľky Zamestnanci.
' - SpustiVsetkyImportyUI()           : Spúšťa kompletný dávkový import DBF tabuliek.
' - SpustiImportZamestnancovUI()      : Spúšťa čiastkový import zamestnancov z DBF.
' - SpustiImportRazeniUI()            : Spúšťa čiastkový import dochádzkových razení z DBF.
' - SpustiImportCSVUI()               : Import zamestnancov z CSV/TXT (zoznam osobných čísel alebo CSV s hlavičkou).
' - SpustiImportStarehoModeluUI()    : Import dát zo staršej verzie databázy (.accdb) cez mod_14_ImportModelu.
' - SpustiKontroluPreruseniUI()       : Vykonáva kontrolu chýbajúcich kódov prerušení.
' - UlozNastaveniaZFormulara()        : Ukladá nastavenú cestu DBF adresára.
'===============================================================================

'-------------------------------------------------------------------------------
' Kontroluje dostupnosť záložky 1 (Import Dát) v UI konzole.
'-------------------------------------------------------------------------------
Public Function IsAvailable() As Boolean
    IsAvailable = True
End Function

'-------------------------------------------------------------------------------
' Vrací názov záložky zobrazovaný v hlavnej konzole.
'-------------------------------------------------------------------------------
Public Function GetTabCaption() As String
    GetTabCaption = "1. Import Dát (DBF/CSV)"
End Function

'-------------------------------------------------------------------------------
' Dynamicky vytvára ovládacie prvky záložky pre import DBF súborov a čiastkové operácie.
'-------------------------------------------------------------------------------
Public Sub BuildUI(ByVal strFrmName As String, ByVal strPageName As String)
    On Error GoTo ChybaHandler
    Dim ctl As Control, btn As Control

    ' --- SEKČNÝ NADPIS ---
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 1100, 9500, 350)
    ctl.Caption = "Nastavenie zdroja DBF a dávkový/čiastkový import"
    ctl.FontBold = True: ctl.FontSize = 10: ctl.ForeColor = RGB(15, 30, 90)

    ' --- 1. SEKCIA: ADRESÁR A OBDOBIE ---
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 1550, 2000, 300)
    ctl.Caption = "Adresár DBF súborov:"

    Set ctl = CreateControl(strFrmName, acTextBox, acDetail, strPageName, "", 2600, 1550, 5800, 320)
    ctl.Name = "txtAdresarDBF"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 8500, 1550, 1500, 320)
    btn.Name = "btnVyberAdresar"
    btn.Caption = "Prehľadávať..."
    btn.OnClick = "=VyberAdresarDBF_Click()"

    ' Obdobie Od - Do (výber mesiaca zo zoznamu, dá sa aj písať názov mesiaca)
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 1970, 2000, 300)
    ctl.Caption = "Obdobie importu:"
    Call mod_UI_Spolocne.VytvorVyberMesiaca(strFrmName, strPageName, "cboImportOd", 2600, 1950, 2000)
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 4700, 1970, 300, 300): ctl.Caption = "až"
    Call mod_UI_Spolocne.VytvorVyberMesiaca(strFrmName, strPageName, "cboImportDo", 5050, 1950, 2000)

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 7200, 1950, 1300, 330)
    btn.Name = "btnImportTentoRok"
    btn.Caption = "Tento rok"
    btn.OnClick = "=ImportObdobieTentoRokUI()"
    btn.ControlTipText = "Nastaví obdobie od januára aktuálneho roka po aktuálny mesiac"
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 8600, 1950, 1400, 330)
    btn.Name = "btnImportMinulyMes"
    btn.Caption = "Minulý mesiac"
    btn.OnClick = "=ImportObdobieMinulyMesiacUI()"
    btn.ControlTipText = "Nastaví Od aj Do na celý predošlý mesiac"

    ' Osobné čísla (filter importu / ručné pridanie zamestnancov)
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 2390, 2000, 300)
    ctl.Caption = "Osobné čísla:"
    Set ctl = CreateControl(strFrmName, acTextBox, acDetail, strPageName, "", 2600, 2370, 5000, 330)
    ctl.Name = "txtImportOC"
    ctl.ControlTipText = "Prázdne = všetci zamestnanci. Oddeľovač sa rozpozná sám (čiarka, bodkočiarka, medzera, nový riadok). Rozsah: 1001-1010."
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 7700, 2370, 2300, 330)
    btn.Name = "btnPridajZadaneOC"
    btn.Caption = "Pridať ako zamestnancov"
    btn.OnClick = "=PridajZadaneOCUI()"
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 2600, 2720, 7400, 260)
    ctl.Caption = "Prázdne = všetci. Ľubovoľný oddeľovač (čiarka, bodkočiarka, medzera, nový riadok), rozsah 1001-1010. Import razení sa obmedzí na tieto čísla."
    ctl.FontSize = 8: ctl.ForeColor = RGB(100, 100, 100)

    ' --- 2. SEKCIA: HLAVNÝ DÁVKOVÝ IMPORT ---
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 3100, 9500, 650)
    btn.Name = "btnImportVsetko"
    btn.Caption = "SPUSTIŤ KOMPLETNÝ DÁVKOVÝ IMPORT (Všetky DBF tabuľky)"
    btn.FontBold = True: btn.FontSize = 10: btn.ForeColor = RGB(0, 100, 0)
    btn.OnClick = "=SpustiVsetkyImportyUI()"

    ' --- 3. SEKCIA: ČIASTKOVÉ IMPORTY ---
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 3950, 9500, 300)
    ctl.Caption = "Čiastkové operácie a ručné doplnenie:"
    ctl.FontBold = True

    ' Riadok 1 čiastkových tlačidiel
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 4350, 4600, 550)
    btn.Name = "btnImportZamestnancov"
    btn.Caption = "1. Importovať iba Zamestnancov (cis_zamestnanec.dbf)"
    btn.OnClick = "=SpustiImportZamestnancovUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 5400, 4350, 4600, 550)
    btn.Name = "btnImportRazeni"
    btn.Caption = "2. Importovať iba Razenia (cis_dochdata.dbf)"
    btn.OnClick = "=SpustiImportRazeniUI()"

    ' Riadok 2 čiastkových tlačidiel
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 5000, 4600, 550)
    btn.Name = "btnImportCSVZam"
    btn.Caption = "3. Načítať zamestnancov z CSV/TXT (osobné čísla, meno, oddelenie, vedúci)"
    btn.OnClick = "=SpustiImportCSVUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 5400, 5000, 4600, 550)
    btn.Name = "btnKontrolaPreruseni"
    btn.Caption = "4. Skontrolovať chýbajúce kódy razení v dochádzke"
    btn.OnClick = "=SpustiKontroluPreruseniUI()"

    ' Riadok 3: import zo staršej verzie databázy (dátový model)
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 5650, 9500, 550)
    btn.Name = "btnImportStarejDB"
    btn.Caption = "5. Importovať dáta zo staršej verzie databázy dochádzky (.accdb)"
    btn.OnClick = "=SpustiImportStarehoModeluUI()"

    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Import.BuildUI", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Nastavuje predvolené hodnoty formulárových polí záložky (adresár, obdobie).
'-------------------------------------------------------------------------------
Public Sub InitDefaults(ByRef frm As Form)
    On Error Resume Next
    Dim adr As String
    adr = mod_00_Common.GetNastavenie("CestaDBFAdresar", CurrentProject.Path & "\")

    frm!txtAdresarDBF = adr
    ' posledné použité obdobie (inak január aktuálneho roka až aktuálny mesiac)
    Dim lOd As Long, lDo As Long
    lOd = CLng(Val(mod_00_Common.GetNastavenie("ImportObdobieOd", CStr(Year(Date) * 100 + 1))))
    lDo = CLng(Val(mod_00_Common.GetNastavenie("ImportObdobieDo", CStr(Year(Date) * 100 + Month(Date)))))
    Call mod_UI_Spolocne.NastavVyberMesiaca(frm!cboImportOd, lOd \ 100, lOd Mod 100)
    Call mod_UI_Spolocne.NastavVyberMesiaca(frm!cboImportDo, lDo \ 100, lDo Mod 100)
    frm!txtImportOC = Null
    ' popisky tlačidiel rýchlej voľby ukazujú, aké obdobie nastavia
    Dim dMin As Date: dMin = DateAdd("m", -1, Date)
    frm!btnImportMinulyMes.ControlTipText = "Nastaví Od aj Do na " & LCase$(mod_UI_Spolocne.NazovMesiaca(Month(dMin))) & " " & Year(dMin) & " (celý predošlý mesiac)"
    frm!btnImportTentoRok.ControlTipText = "Nastaví obdobie od januára " & Year(Date) & " po " & LCase$(mod_UI_Spolocne.NazovMesiaca(Month(Date))) & " " & Year(Date)
End Sub

'-------------------------------------------------------------------------------
' Rýchla voľba obdobia: január aktuálneho roka až aktuálny mesiac.
'-------------------------------------------------------------------------------
Public Function ImportObdobieTentoRokUI() As Boolean
    On Error Resume Next
    Call mod_UI_Spolocne.NastavVyberMesiaca(Forms!frmHlavnaKonzola!cboImportOd, Year(Date), 1)
    Call mod_UI_Spolocne.NastavVyberMesiaca(Forms!frmHlavnaKonzola!cboImportDo, Year(Date), Month(Date))
    Call mod_00_Common.ZapisLog("Import", "INFO", "Obdobie importu: január " & Year(Date) & " až " & LCase$(mod_UI_Spolocne.NazovMesiaca(Month(Date))) & " " & Year(Date))
    ImportObdobieTentoRokUI = True
End Function

'-------------------------------------------------------------------------------
' Rýchla voľba obdobia: iba minulý mesiac.
'-------------------------------------------------------------------------------
Public Function ImportObdobieMinulyMesiacUI() As Boolean
    On Error Resume Next
    Dim d As Date: d = DateAdd("m", -1, Date)
    Call mod_UI_Spolocne.NastavVyberMesiaca(Forms!frmHlavnaKonzola!cboImportOd, Year(d), Month(d))
    Call mod_UI_Spolocne.NastavVyberMesiaca(Forms!frmHlavnaKonzola!cboImportDo, Year(d), Month(d))
    Call mod_00_Common.ZapisLog("Import", "INFO", "Obdobie importu: " & LCase$(mod_UI_Spolocne.NazovMesiaca(Month(d))) & " " & Year(d) & " (minulý mesiac, Od aj Do rovnaký mesiac)")
    ImportObdobieMinulyMesiacUI = True
End Function

'-------------------------------------------------------------------------------
' Pridá osobné čísla zadané v poli "Osobné čísla" do tabuľky Zamestnanci (existujúce sa nemenia).
'-------------------------------------------------------------------------------
Public Function PridajZadaneOCUI() As Boolean
    On Error GoTo ChybaHandler
    Dim strText As String, a As Variant, strNez As String
    strText = Trim$(Nz(Forms!frmHlavnaKonzola!txtImportOC, ""))
    a = mod_UI_Spolocne.OsobneCislaZTextu(strText, strNez, False)
    If UBound(a) < LBound(a) Then
        MsgBox "Do poľa Osobné čísla zadajte aspoň jedno osobné číslo (oddeľovač môže byť čiarka, bodkočiarka, medzera alebo nový riadok).", vbExclamation, "Pridanie zamestnancov"
        Exit Function
    End If
    If MsgBox("Pridať " & (UBound(a) - LBound(a) + 1) & " osobných čísel do zoznamu zamestnancov?" & vbCrLf & _
              Left$(Join(a, ", "), 400) & vbCrLf & vbCrLf & "Existujúci zamestnanci sa nemenia. Mená a oddelenia doplní synchronizácia s AD alebo import CSV.", _
              vbQuestion + vbYesNo, "Pridanie zamestnancov") <> vbYes Then Exit Function
    MsgBox mod_11_ImportZamestnancov.ImportZamestnancovZTextu(Join(a, vbCrLf), True, "MANUAL"), vbInformation, "Pridanie zamestnancov"
    PridajZadaneOCUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri pridávaní zamestnancov: " & Err.Description, vbCritical
End Function

'-------------------------------------------------------------------------------
' Prečíta obdobie a osobné čísla z karty, uloží ich ako posledné použité a dá ich potvrdiť používateľovi.
' bRazenia = TRUE: upozorní, že razenia z DBF v období sa nahradia (ručné úpravy ostanú).
'-------------------------------------------------------------------------------
Private Function PotvrdVolbyImportu(ByVal strCo As String, ByVal bRazenia As Boolean) As Boolean
    On Error GoTo ChybaHandler
    Dim frm As Form, lOdR As Long, lOdM As Long, lDoR As Long, lDoM As Long, a As Variant, strNez As String, strOC As String, strMsg As String
    Set frm = Forms!frmHlavnaKonzola
    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboImportOd, lOdR, lOdM) Or Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboImportDo, lDoR, lDoM) Then
        MsgBox "Vyberte obdobie importu (mesiac od - do).", vbExclamation, "Import"
        Exit Function
    End If
    If lOdR * 100 + lOdM > lDoR * 100 + lDoM Then
        MsgBox "Začiatok obdobia je po jeho konci - opravte výber mesiacov.", vbExclamation, "Import"
        Exit Function
    End If
    Call mod_00_Common.SetNastavenie("ImportObdobieOd", CStr(lOdR * 100 + lOdM), "Posledné obdobie importu - od (yyyymm)")
    Call mod_00_Common.SetNastavenie("ImportObdobieDo", CStr(lDoR * 100 + lDoM), "Posledné obdobie importu - do (yyyymm)")

    a = mod_UI_Spolocne.OsobneCislaZTextu(Nz(frm!txtImportOC, ""), strNez, False)
    If UBound(a) >= LBound(a) Then
        strOC = (UBound(a) - LBound(a) + 1) & " zamestnancov: " & Left$(Join(a, ", "), 300)
    Else
        strOC = "všetci zamestnanci"
    End If
    strMsg = strCo & vbCrLf & vbCrLf & _
             "Obdobie: " & mod_UI_Spolocne.NazovMesiaca(lOdM) & " " & lOdR & " - " & mod_UI_Spolocne.NazovMesiaca(lDoM) & " " & lDoR & vbCrLf & _
             "Osobné čísla: " & strOC
    If bRazenia Then strMsg = strMsg & vbCrLf & vbCrLf & "Razenia z DBF v tomto období sa načítajú znova (nahradia sa); ručné úpravy a záznamy z terminálu ostanú."
    PotvrdVolbyImportu = (MsgBox(strMsg & vbCrLf & vbCrLf & "Pokračovať?", vbQuestion + vbYesNo, "Import") = vbYes)
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri čítaní volieb importu: " & Err.Description, vbCritical
End Function

'-------------------------------------------------------------------------------
' Otvára dialógové okno pre výber adresára s DBF súbormi a ukladá cestu do nastavení.
'-------------------------------------------------------------------------------
Public Function VyberAdresarDBF_Click() As Boolean
    On Error Resume Next
    Dim adr As String
    adr = mod_00_Common.VyberAdresarDBF()
    If Len(adr) > 0 Then
        Forms!frmHlavnaKonzola!txtAdresarDBF = adr
        Call mod_00_Common.SetNastavenie("CestaDBFAdresar", adr, "Adresár pre import DBF")
    End If
    VyberAdresarDBF_Click = True
End Function

'-------------------------------------------------------------------------------
' Spúšťa kompletný dávkový import všetkých DBF tabuliek.
'-------------------------------------------------------------------------------
Public Function SpustiVsetkyImportyUI() As Boolean
    On Error GoTo ChybaHandler
    If mod_00_Common.JeImportZamknuty() Then
        MsgBox "Import je uzamknutý.", vbExclamation, "Upozornenie"
        Exit Function
    End If

    If Not PotvrdVolbyImportu("Spustiť kompletný dávkový import zo všetkých DBF tabuliek?", True) Then Exit Function
    Call UlozNastaveniaZFormulara
    Call mod_02_DBFImport.ImportVsetkychDBFTabuliek
    SpustiVsetkyImportyUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri šaržovom importe: " & Err.Description, vbCritical
    SpustiVsetkyImportyUI = False
End Function

'-------------------------------------------------------------------------------
' Spúšťa čiastkový import zamestnancov z DBF súboru.
'-------------------------------------------------------------------------------
Public Function SpustiImportZamestnancovUI() As Boolean
    On Error GoTo ChybaHandler
    If Len(Trim$(Nz(Forms!frmHlavnaKonzola!txtImportOC, ""))) > 0 Then
        If Not PotvrdVolbyImportu("Importovať zamestnancov z cis_zamestnanec.dbf (iba zadané osobné čísla)?", False) Then Exit Function
    End If
    Call UlozNastaveniaZFormulara
    Call mod_02_DBFImport.ImportZamestnancovDBFPriamo
    MsgBox "Import zamestnancov bol dokončený.", vbInformation, "Hotovo"
    SpustiImportZamestnancovUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri importe zamestnancov: " & Err.Description, vbCritical
    SpustiImportZamestnancovUI = False
End Function

'-------------------------------------------------------------------------------
' Spúšťa čiastkový import dochádzkových razení z DBF súboru.
'-------------------------------------------------------------------------------
Public Function SpustiImportRazeniUI() As Boolean
    On Error GoTo ChybaHandler
    If Not PotvrdVolbyImportu("Importovať dochádzkové razenia z cis_dochdata.dbf?", True) Then Exit Function
    Call UlozNastaveniaZFormulara
    Call mod_02_DBFImport.ImportDochadzkyDBFPriamo
    MsgBox "Import dochádzkových razení bol dokončený.", vbInformation, "Hotovo"
    SpustiImportRazeniUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri importe razení: " & Err.Description, vbCritical
    SpustiImportRazeniUI = False
End Function

'-------------------------------------------------------------------------------
' Spúšťa import osobných čísel zamestnancov z CSV/TXT súboru.
'-------------------------------------------------------------------------------
Public Function SpustiImportCSVUI() As Boolean
    On Error GoTo ChybaHandler
    ' importér zobrazí vlastný report (počty, rozpoznané stĺpce, zamietnuté riadky)
    Call mod_11_ImportZamestnancov.ImportZamestnancovZCSV("", False)
    SpustiImportCSVUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri importe CSV: " & Err.Description, vbCritical
    SpustiImportCSVUI = False
End Function

'-------------------------------------------------------------------------------
' Vykonáva kontrolu a doplnenie chýbajúcich kódov prerušení v dochádzkových razeniach.
'-------------------------------------------------------------------------------
Public Function SpustiKontroluPreruseniUI() As Boolean
    On Error GoTo ChybaHandler
    Dim pocet As Long
    pocet = mod_02_DBFImport.SkontrolujChybajucePrerusenia()
    If pocet > 0 Then
        MsgBox "Bolo nájdených a pridaných " & pocet & " chýbajúcich kódov razení.", vbInformation, "Výsledok kontroly"
    Else
        MsgBox "Všetky razenia majú priradené platné kódovanie prerušenia.", vbInformation, "Všetko v poriadku"
    End If
    SpustiKontroluPreruseniUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri kontrole prerušení: " & Err.Description, vbCritical
    SpustiKontroluPreruseniUI = False
End Function

'-------------------------------------------------------------------------------
' Ukladá zadanú cestu k DBF súborom z formulára do systémových nastavení.
'-------------------------------------------------------------------------------
Private Sub UlozNastaveniaZFormulara()
    On Error Resume Next
    Dim frm As Form: Set frm = Forms!frmHlavnaKonzola
    Dim adr As String: adr = Trim(Nz(frm!txtAdresarDBF, ""))
    If Len(adr) > 0 Then Call mod_00_Common.SetNastavenie("CestaDBFAdresar", adr)
End Sub


'-------------------------------------------------------------------------------
' Vyberie starší súbor databázy dochádzky a doplní z neho dáta do aktuálnej databázy (nič sa nemaže ani neprepisuje).
'-------------------------------------------------------------------------------
Public Function SpustiImportStarehoModeluUI() As Boolean
    On Error GoTo ChybaHandler
    Dim fd As Object, strCesta As String
    Set fd = Application.FileDialog(3)
    With fd
        .Title = "Vyberte staršiu databázu dochádzky (.accdb / .mdb)"
        .AllowMultiSelect = False
        .Filters.Clear
        .Filters.Add "Databázy Access (*.accdb;*.mdb)", "*.accdb;*.mdb"
        If .Show <> -1 Then Exit Function
        strCesta = .SelectedItems(1)
    End With
    If StrComp(strCesta, CurrentDb.Name, vbTextCompare) = 0 Then
        MsgBox "Vybrali ste aktuálne otvorenú databázu. Vyberte staršiu databázu, z ktorej sa majú dáta preniesť.", vbExclamation, "Import zo staršej databázy"
        Exit Function
    End If
    Dim strPredch As String
    strPredch = mod_00_Common.GetNastavenie("ImportStarehoModelu", "")
    If InStr(1, strPredch, strCesta, vbTextCompare) = 1 Then
        If MsgBox("Z tejto databázy už import prebehol:" & vbCrLf & strPredch & vbCrLf & vbCrLf & _
                  "Opakovaný import iba doplní záznamy, ktoré ešte chýbajú (nič sa nezdvojí ani neprepíše), pri veľkej dochádzke môže trvať niekoľko minút." & vbCrLf & vbCrLf & _
                  "Pokračovať?", vbQuestion + vbYesNo + vbDefaultButton2, "Import zo staršej databázy") <> vbYes Then Exit Function
    End If
    If MsgBox("Z databázy:" & vbCrLf & strCesta & vbCrLf & vbCrLf & _
              "sa doplnia zamestnanci, razenia a číselníky, ktoré v aktuálnej databáze ešte nie sú (existujúce záznamy sa nemenia)." & vbCrLf & _
              "Denné výpočty a sumáre sa po importe prepočítajú." & vbCrLf & vbCrLf & "Pokračovať?", vbQuestion + vbYesNo, "Import zo staršej databázy") <> vbYes Then Exit Function
    Dim strSprava As String
    strSprava = mod_14_ImportModelu.ImportZoStarsejDatabazy(strCesta, 1, True)
    MsgBox strSprava, vbInformation, "Import zo staršej databázy"
    SpustiImportStarehoModeluUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri importe zo staršej databázy: " & Err.Description, vbCritical
End Function
