Attribute VB_Name = "mod_UI_Tab_Admin"
'@Verzia 2.8.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_UI_Tab_Admin
' POPIS: Sub-modul pre kartu 8 hlavnej konzoly UI (Audit, Anonymizácia,
'        správa zámku importu a prepínanie vývojárskeho/testovacieho režimu).
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - IsAvailable()                   : Kontroluje dostupnosť záložky v hlavnom UI.
' - GetTabCaption()                 : Vracie nadpis záložky pre hlavnú konzolu.
' - BuildUI(strFrmName, strPageName): Vytvára prvky záložky pre správu a admin nástroje.
' - InitDefaults(frm)               : Inicializuje predvolené hodnoty záložky.
' - SpustiAnonymizaciuUI()          : Spúšťa anonymizáciu osobných údajov.
' - SpustiVymazPomocnychUI()        : Vymaže pomocné výpočtové tabuľky dochádzky.
' - OtvorAdminOknoUI()              : Otvára vývojársky panel / spúšťa vývojársky režim.
' - PrepniZamokImportuUI()          : Prepína príznak zámku importu dát.
' - SpustiUkoncenieTestovaniaUI()   : Vypína testovací/vývojársky režim.
' - ObnovPopisMenu(frm)            : Popisok tlačidiel "skrývanie menu pri štarte" a "karta Active Directory".
' - PrepniKartuADUI()              : Prepne zobrazenie karty 9 Active Directory (automaticky / vždy / nikdy).
'===============================================================================

'-------------------------------------------------------------------------------
' Kontroluje dostupnosť záložky v hlavnom používateľskom rozhraní.
'-------------------------------------------------------------------------------
Public Function IsAvailable() As Boolean
    IsAvailable = True
End Function

'-------------------------------------------------------------------------------
' Vracie nadpis záložky zobrazovaný v hlavnej konzole.
'-------------------------------------------------------------------------------
Public Function GetTabCaption() As String
    GetTabCaption = "8. Audit & Admin"
End Function

'-------------------------------------------------------------------------------
' Vytvára prvky záložky pre prevádzkové nástroje a prepínanie vývojárskeho režimu.
'-------------------------------------------------------------------------------
Public Sub BuildUI(ByVal strFrmName As String, ByVal strPageName As String)
    On Error GoTo ChybaHandler
    Dim ctl As Control, btn As Control
    Dim bDevMode As Boolean
    bDevMode = (mod_00_Common.GetNastavenie("DevMode", "0") = "1")

    ' Nadpis sekcie
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 1100, 9500, 300)
    ctl.Caption = "Administrácia systému, anonymizácia dát a údržba databázy"
    ctl.FontBold = True: ctl.FontSize = 10: ctl.ForeColor = RGB(15, 30, 90)

    ' --- 1. SEKCIA: SPRÁVA SÚKROMIA A ANONYMIZÁCIA (PREVÁDZKA) ---
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 1600, 9500, 300)
    ctl.Caption = "1. Anonymizácia osobných údajov (GDPR / Testovanie)"
    ctl.FontBold = True: ctl.ForeColor = RGB(15, 30, 90)

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 1950, 9500, 500)
    ctl.Caption = "Nahradí mená, priezviská, tituly a kontakty anonymnými hodnotami pri zachovaní výpočtovej logiky."
    ctl.ForeColor = RGB(80, 80, 80)

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 2450, 4600, 500)
    btn.Name = "btnAnonymizovat"
    btn.Caption = "ANONYMIZOVAŤ ACCESS TABUĽKY"
    btn.FontBold = True: btn.ForeColor = RGB(180, 80, 0)
    btn.OnClick = "=SpustiAnonymizaciuUI()"

    ' --- 2. SEKCIA: ČISTENIE A ÚDRŽBA DATABÁZY (PREVÁDZKA) ---
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 3150, 9500, 300)
    ctl.Caption = "2. Čistenie pomocných výpočtových tabuliek"
    ctl.FontBold = True: ctl.ForeColor = RGB(15, 30, 90)

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 3500, 9500, 500)
    ctl.Caption = "Vymaže vygenerované denné a mesačné sumáre a intervaly (DochadzkaIntervaly, DochadzkaDni, DochadzkaMesiacSumar)."
    ctl.ForeColor = RGB(80, 80, 80)

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 4000, 4600, 500)
    btn.Name = "btnVymazatPomocne"
    btn.Caption = "VYMAZAŤ POMOCNÉ TABUĽKY"
    btn.FontBold = True: btn.ForeColor = RGB(180, 0, 0)
    btn.OnClick = "=SpustiVymazPomocnychUI()"

    ' --- 3. SEKCIA: SPRAVOVANIE STAVU A VÝVOJÁRSKY PANEL ---
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 4700, 9500, 300)
    ctl.Caption = "3. Správa prevádzkového stavu a vývojárske nástroje"
    ctl.FontBold = True: ctl.ForeColor = RGB(15, 30, 90)

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 5100, 4600, 500)
    btn.Name = "btnPrepnutZamknutie"
    btn.Caption = "PREPNÚŤ ZÁMOK IMPORTU"
    btn.FontBold = True
    btn.OnClick = "=PrepniZamokImportuUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 5200, 5100, 4800, 500)
    btn.Name = "btnOtvoritAdminOkno"
    If bDevMode Then
        btn.Caption = "OTVORIŤ VÝVOJÁRSKY ADMIN PANEL"
        btn.ForeColor = RGB(0, 100, 0)
    Else
        btn.Caption = "ZAPNÚŤ VÝVOJÁRSKY / TESTOVACÍ REŽIM"
        btn.ForeColor = RGB(120, 50, 0)
    End If
    btn.FontBold = True
    btn.OnClick = "=OtvorAdminOknoUI()"

    ' Ak je vývojársky režim aktívny, zobrazí sa aj tlačidlo na jeho ukončenie
    If bDevMode Then
        Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 5200, 5700, 4800, 450)
        btn.Name = "btnUkoncitTestovanieUI"
        btn.Caption = "UKONČIŤ TESTOVANIE (VYPNÚŤ DEV MODE)"
        btn.FontBold = True: btn.ForeColor = RGB(180, 0, 0)
        btn.OnClick = "=SpustiUkoncenieTestovaniaUI()"
    End If

    ' --- 4. SEKCIA: MENU, OKNO KONZOLY A INFO OKNÁ ---
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 6350, 9500, 300)
    ctl.Caption = "4. Menu Accessu, okno konzoly a info okná kariet"
    ctl.FontBold = True: ctl.ForeColor = RGB(15, 30, 90)

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 6700, 9500, 500)
    ctl.Caption = "Pás kariet (Menu) a navigačný panel s objektmi sa pri štarte skrývajú; kedykoľvek ich zobrazíte tlačidlami Menu a Objekty v hlavičke. " & _
                  "Info okná kariet sa ukážu, kým sa činnosť na karte nevykoná; po zaškrtnutí Nezobrazovať sa už neukážu."
    ctl.ForeColor = RGB(80, 80, 80)

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 7300, 4600, 450)
    btn.Name = "btnSkryvatMenu"
    btn.Caption = "Skrývanie menu pri štarte"
    btn.OnClick = "=UI_PrepniSkryvanieMenuUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 5200, 7300, 2350, 450)
    btn.Name = "btnMenuTeraz"
    btn.Caption = "Pás kariet teraz"
    btn.ControlTipText = "Zobraziť alebo skryť pás kariet Accessu (to isté ako tlačidlo Menu v hlavičke)"
    btn.OnClick = "=UI_PrepniMenu()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 7650, 7300, 2350, 450)
    btn.Name = "btnPanelTeraz"
    btn.Caption = "Panel objektov teraz"
    btn.ControlTipText = "Zobraziť alebo skryť navigačný panel s objektmi databázy (to isté ako tlačidlo Objekty v hlavičke)"
    btn.OnClick = "=UI_PrepniPanelObjektov()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 7850, 4600, 450)
    btn.Name = "btnInfoOknaZnovu"
    btn.Caption = "Znovu zapnúť info okná"
    btn.OnClick = "=PomocnikObnovVsetkoUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 5200, 7850, 4800, 450)
    btn.Name = "btnInfoTextyObnov"
    btn.Caption = "Obnoviť predvolené texty info okien"
    btn.OnClick = "=PomocnikObnovTextyUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 8400, 4600, 450)
    btn.Name = "btnKonzolaNova"
    btn.Caption = "Znovu vytvoriť konzolu"
    btn.OnClick = "=UI_ZnovuVytvorKonzoluUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 5200, 8400, 4800, 450)
    btn.Name = "btnKartaAD"
    btn.Caption = "Karta Active Directory: automaticky"
    btn.ControlTipText = "Karta 9 sa predvolene zobrazí len v doméne. Tlačidlo prepína: automaticky / vždy / nikdy."
    btn.OnClick = "=PrepniKartuADUI()"

    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Admin.BuildUI", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Inicializuje predvolené hodnoty prvkov záložky.
'-------------------------------------------------------------------------------
Public Sub InitDefaults(ByRef frm As Form)
    Call ObnovPopisMenu(frm)
End Sub

'-------------------------------------------------------------------------------
' Nastaví popisok tlačidla "skrývanie menu pri štarte" podľa nastavenia (zapnuté / vypnuté).
'-------------------------------------------------------------------------------
Public Sub ObnovPopisMenu(Optional ByVal frm As Form = Nothing)
    On Error Resume Next
    If frm Is Nothing Then Set frm = Forms!frmHlavnaKonzola
    frm!btnSkryvatMenu.Caption = "Skrývanie menu pri štarte: " & IIf(mod_00_Common.GetNastavenie("UIPriStarteSkryMenu", "1") = "1", "ZAPNUTÉ", "VYPNUTÉ")
    frm!btnKartaAD.Caption = "Karta Active Directory: " & PopisVolbyAD()
End Sub

Private Function PopisVolbyAD() As String
    Select Case LCase$(Trim$(mod_00_Common.GetNastavenie("ADKartaZobraz", "auto")))
        Case "1": PopisVolbyAD = "vždy"
        Case "0": PopisVolbyAD = "nikdy"
        Case Else: PopisVolbyAD = "automaticky"
    End Select
End Function

'-------------------------------------------------------------------------------
' Prepne zobrazenie karty 9 Active Directory: automaticky (len v doméne) -> vždy -> nikdy. Zmena sa prejaví
' po opätovnom vytvorení konzoly (tlačidlo vedľa) alebo pri ďalšom štarte.
'-------------------------------------------------------------------------------
Public Function PrepniKartuADUI() As Boolean
    On Error Resume Next
    Dim strNova As String
    Select Case LCase$(Trim$(mod_00_Common.GetNastavenie("ADKartaZobraz", "auto")))
        Case "1": strNova = "0"
        Case "0": strNova = "auto"
        Case Else: strNova = "1"
    End Select
    Call mod_00_Common.SetNastavenie("ADKartaZobraz", strNova, "Karta Active Directory: auto = len v doméne, 1 = vždy, 0 = nikdy")
    Call mod_UI_Core.UI_ZneplatniKonzolu
    Call ObnovPopisMenu
    MsgBox "Karta Active Directory: " & PopisVolbyAD() & "." & vbCrLf & _
           "Zmena sa prejaví po tlačidle Znovu vytvoriť konzolu alebo pri ďalšom štarte.", vbInformation, "Karta Active Directory"
    PrepniKartuADUI = True
End Function

'-------------------------------------------------------------------------------
' Spúšťa anonymizáciu osobných údajov v Access tabuľkách.
'-------------------------------------------------------------------------------
Public Function SpustiAnonymizaciuUI() As Boolean
    On Error GoTo ChybaHandler
    Call mod_06_AdminTools.SpustiAnonymizaciuAccessGUI
    SpustiAnonymizaciuUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri anonymizácii: " & Err.Description, vbCritical
    SpustiAnonymizaciuUI = False
End Function

'-------------------------------------------------------------------------------
' Spúšťa kompletne vyčistenie pomocných výpočtových tabuliek dochádzky.
'-------------------------------------------------------------------------------
Public Function SpustiVymazPomocnychUI() As Boolean
    On Error GoTo ChybaHandler
    Call mod_06_AdminTools.SpustiVymazPomocnychTabuliekGUI
    SpustiVymazPomocnychUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri vymazávaní pomocných tabuliek: " & Err.Description, vbCritical
    SpustiVymazPomocnychUI = False
End Function

'-------------------------------------------------------------------------------
' Otvára samostatný vývojársky panel (frmAdminNastroje). Ak nie je zapnutý Dev Mode, vyzve používateľa.
'-------------------------------------------------------------------------------
Public Function OtvorAdminOknoUI() As Boolean
    On Error GoTo ChybaHandler
    Call mod_06_AdminTools.OtvorAdminNastroje
    OtvorAdminOknoUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri otváraní Admin okna: " & Err.Description, vbCritical
    OtvorAdminOknoUI = False
End Function

'-------------------------------------------------------------------------------
' Prepína príznak zámku importu dát v databáze.
'-------------------------------------------------------------------------------
Public Function PrepniZamokImportuUI() As Boolean
    On Error GoTo ChybaHandler
    Dim bZamknute As Boolean
    bZamknute = mod_00_Common.JeImportZamknuty()
    
    If bZamknute Then
        Call mod_00_Common.NastavImportDokonceny(False)
        MsgBox "Import bol ODOMKNUTÝ.", vbInformation, "Zámok importu"
    Else
        Call mod_00_Common.NastavImportDokonceny(True)
        MsgBox "Import bol UZAMKNUTÝ. Databáza je v bežnej prevádzke.", vbInformation, "Zámok importu"
    End If
    PrepniZamokImportuUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri zmene zámku: " & Err.Description, vbCritical
    PrepniZamokImportuUI = False
End Function

'-------------------------------------------------------------------------------
' Spúšťa ukončenie testovacieho režimu z hlavnej konzoly.
'-------------------------------------------------------------------------------
Public Function SpustiUkoncenieTestovaniaUI() As Boolean
    On Error GoTo ChybaHandler
    Call mod_06_AdminTools.SpustiUkoncenieTestovaniaGUI
    SpustiUkoncenieTestovaniaUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri ukončovaní testovania: " & Err.Description, vbCritical
    SpustiUkoncenieTestovaniaUI = False
End Function

