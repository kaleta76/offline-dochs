Attribute VB_Name = "mod_UI_Tab_Prerusenia"
'@Verzia 2.11.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_UI_Tab_Prerusenia
' POPIS: Záložka 5 - Číselník prerušení (kódy razení terminálu), parametre výpočtu
'        a časový profil strediska. Obsahuje tlačidlo na inicializáciu minimálnej
'        predvolenej konfigurácie pre inštalácie bez importu z Ordata.
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - IsAvailable(), GetTabCaption(), BuildUI(...), InitDefaults(frm)
' - PrerusenieFondyUI()            : Otvorí editor pracovných fondov (priraďujú sa na karte 2 Zamestnanci).
' - PreruseniePravidlaUI()         : Otvorí editor pravidiel prerušení (povolený čas, odpracovať pred začiatkom ...).
' - PrerusenieObnovUI()            : Obnoví zoznam prerušení.
' - PrerusenieVyberUI()            : Načíta vybrané prerušenie do editačných polí.
' - PrerusenieNoveUI()             : Vyčistí polia (navrhne najbližšie voľné číslo a kódy).
' - PrerusenieUlozUI()             : Uloží prerušenie a jeho kódy razení.
' - PrerusenieZmazUI()             : Zmaže nepoužité prerušenie.
' - InicializujKonfiguraciuUI()    : Doplní predvolenú konfiguráciu (iba chýbajúce záznamy).
' - UlozParametreVypoctuUI()       : Uloží okno práce, obed a limit celodennej prekážky.
' - UlozPravidlaVypoctuUI()        : Uloží pravidlá výpočtu (razený obed, odchod bez dôvodu, zaokrúhlenie, doplnenie opráv).
' - PredvolbaPravidielDnesUI() / PredvolbaPravidielOdporucaneUI() : Vyplnia polia pravidiel hotovou predvoľbou (uloží ich správca).
' - SpustiUlozenieOUProfiluUI()    : Uloží časový profil strediska.
'===============================================================================

' Zoznamy volieb pravidiel výpočtu: každá voľba začína číselným kódom, ktorý sa ukladá (Val prečíta kód).
Private Const LIST_RAZ_OBED As String = "0 - skutočný čas;1 - najmenej (minúty obeda);2 - vždy presne (minúty obeda)"
Private Const LIST_ODCHOD_BEZ As String = "obed;odchod"
Private Const LIST_ZAOKR_SMER As String = "0 - príchod nahor, odchod nadol;1 - oba nahor;2 - oba nadol;3 - na najbližší"
Private Const LIST_OPRAVA_CIEL As String = "0 - do denného fondu;1 - do konca okna práce"
Private Const LIST_OPRAVA_PRIPADY As String = "3 - odchod aj návrat z prerušenia;1 - len zabudnutý odchod;2 - len zabudnutý návrat"

Public Function IsAvailable() As Boolean
    IsAvailable = True
End Function

Public Function GetTabCaption() As String
    GetTabCaption = "5. Prerušenia & Nastavenia"
End Function

Private Sub Pole(ByVal f As String, ByVal p As String, ByVal x As Long, ByVal y As Long, ByVal sCap As String, ByVal sName As String, ByVal w As Long)
    Dim ctl As Control
    Set ctl = CreateControl(f, acLabel, acDetail, p, "", x, y + 40, 1300, 280)
    ctl.Caption = sCap
    Set ctl = CreateControl(f, acTextBox, acDetail, p, "", x + 1300, y, w, 320)
    ctl.Name = sName
End Sub

' Pole s dlhším popisom (šírku popisu a poľa určuje volajúci).
Private Sub PoleSir(ByVal f As String, ByVal p As String, ByVal x As Long, ByVal y As Long, ByVal sCap As String, ByVal sName As String, ByVal wLab As Long, ByVal w As Long)
    Dim ctl As Control
    Set ctl = CreateControl(f, acLabel, acDetail, p, "", x, y + 40, wLab, 280)
    ctl.Caption = sCap
    Set ctl = CreateControl(f, acTextBox, acDetail, p, "", x + wLab, y, w, 320)
    ctl.Name = sName
End Sub

' Výber zo zoznamu hodnôt s popisom (zoznam sa nedá obísť vlastným textom).
Private Sub VolbaSir(ByVal f As String, ByVal p As String, ByVal x As Long, ByVal y As Long, ByVal sCap As String, ByVal sName As String, ByVal wLab As Long, ByVal w As Long, ByVal sZoznam As String)
    Dim ctl As Control
    Set ctl = CreateControl(f, acLabel, acDetail, p, "", x, y + 40, wLab, 280)
    ctl.Caption = sCap
    Set ctl = CreateControl(f, acComboBox, acDetail, p, "", x + wLab, y, w, 320)
    ctl.Name = sName
    ctl.RowSourceType = "Value List"
    ctl.RowSource = sZoznam
    ctl.LimitToList = True
End Sub

' Text voľby so zadaným číselným kódom (prvá voľba, ak kód v zozname nie je).
Private Function VolbaPodlaKodu(ByVal strZoznam As String, ByVal lKod As Long) As String
    Dim a() As String, i As Long
    a = Split(strZoznam, ";")
    For i = 0 To UBound(a)
        If CLng(Val(a(i))) = lKod Then VolbaPodlaKodu = a(i): Exit Function
    Next i
    VolbaPodlaKodu = a(0)
End Function

Public Sub BuildUI(ByVal strFrmName As String, ByVal strPageName As String)
    On Error GoTo ChybaHandler
    Dim ctl As Control, btn As Control, lDy As Long
    lDy = 3700      ' o koľko je sekcia 3 posunutá nadol kvôli sekcii 2b (pravidlá výpočtu)

    ' --- 1. SEKCIA: ČÍSELNÍK PRERUŠENÍ ---
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 1100, 9500, 300)
    ctl.Caption = "1. Číselník prerušení a kódy razení terminálu"
    ctl.FontBold = True: ctl.FontSize = 10: ctl.ForeColor = RGB(15, 30, 90)

    Set ctl = CreateControl(strFrmName, acListBox, acDetail, strPageName, "", 500, 1450, 5600, 2500)
    ctl.Name = "lstPrerusenia"
    ctl.ColumnCount = 7
    ctl.ColumnHeads = True
    ctl.ColumnWidths = "560;1400;800;640;640;600;860"
    ctl.BoundColumn = 1
    ctl.RowSourceType = "Table/Query"
    ctl.AfterUpdate = "=PrerusenieVyberUI()"

    Call Pole(strFrmName, strPageName, 6300, 1450, "Číslo:", "txtPrerCislo", 900)
    Call Pole(strFrmName, strPageName, 6300, 1850, "Názov:", "txtPrerNazov", 2400)
    Call Pole(strFrmName, strPageName, 6300, 2250, "Skratka:", "txtPrerSkratka", 1200)
    Call Pole(strFrmName, strPageName, 6300, 2650, "Kód začiatok:", "txtPrerKodZ", 900)
    Call Pole(strFrmName, strPageName, 6300, 3050, "Kód koniec:", "txtPrerKodK", 900)

    Set ctl = CreateControl(strFrmName, acCheckBox, acDetail, strPageName, "", 6300, 3480, 300, 300)
    ctl.Name = "chkPrerAutoKoniec"
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 6650, 3470, 3350, 400)
    ctl.Caption = "Pri chýbajúcom návrate ukončiť do konca smeny (auto-oprava)"
    ctl.FontSize = 8

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 4050, 1100, 420)
    btn.Name = "btnPrerNove": btn.Caption = "Nové": btn.OnClick = "=PrerusenieNoveUI()"
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 1700, 4050, 1300, 420)
    btn.Name = "btnPrerUloz": btn.Caption = "Uložiť": btn.FontBold = True: btn.ForeColor = RGB(0, 100, 0): btn.OnClick = "=PrerusenieUlozUI()"
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 3100, 4050, 1300, 420)
    btn.Name = "btnPrerZmaz": btn.Caption = "Zmazať": btn.OnClick = "=PrerusenieZmazUI()"
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 4600, 4050, 5400, 420)
    btn.Name = "btnInicKonfig": btn.Caption = "INICIALIZOVAŤ PREDVOLENÚ KONFIGURÁCIU (doplní len chýbajúce)": btn.FontBold = True
    btn.OnClick = "=InicializujKonfiguraciuUI()"

    ' --- Pracovné fondy a pravidlá prerušení (úprava číselníkov; priraďuje sa na karte Zamestnanci) ---
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 4550, 2500, 420)
    btn.Name = "btnPrerFondy": btn.Caption = "Pracovné fondy...": btn.OnClick = "=PrerusenieFondyUI()"
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 3150, 4550, 2800, 420)
    btn.Name = "btnPrerPravidla": btn.Caption = "Pravidlá prerušení...": btn.OnClick = "=PreruseniePravidlaUI()"
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 6100, 4500, 3900, 480)
    ctl.Caption = "Fond a pravidlá sa priraďujú zamestnancom na karte 2 Zamestnanci (aj skupine vybraných zamestnancov)."
    ctl.FontSize = 8: ctl.ForeColor = RGB(100, 100, 100)

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 5050, 9500, 300)
    ctl.Name = "lblPrerStav": ctl.Caption = "": ctl.ForeColor = RGB(100, 100, 100): ctl.FontSize = 8

    ' --- 1b. TLAČIDLO A PRÍZNAKY PRE TERMINÁL (pre prerušenie vybrané vyššie; ukladá ich tlačidlo Uložiť) ---
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 5450, 9500, 300)
    ctl.Caption = "Tlačidlo a príznaky pre terminál (platia pre prerušenie vybrané hore; uloží ich tlačidlo Uložiť)"
    ctl.FontBold = True: ctl.FontSize = 9: ctl.ForeColor = RGB(15, 30, 90)

    Set ctl = CreateControl(strFrmName, acCheckBox, acDetail, strPageName, "", 500, 5830, 300, 300)
    ctl.Name = "chkPrerTlacidlo"
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 850, 5820, 4300, 400)
    ctl.Caption = "Tlačidlo v termináli (dôvod odchodu; Príchod a Odchod sú vždy)": ctl.FontSize = 8
    Call Pole(strFrmName, strPageName, 500, 6200, "Text tlačidla:", "txtPrerTlacText", 2400)
    Call Pole(strFrmName, strPageName, 500, 6600, "Poradie 1-99:", "txtPrerTlacPoradie", 700)
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 7040, 1300, 280)
    ctl.Caption = "Ikona:"
    Set ctl = CreateControl(strFrmName, acComboBox, acDetail, strPageName, "", 1800, 7000, 1900, 320)
    ctl.Name = "cboPrerIkona"
    ctl.RowSourceType = "Value List"
    ctl.RowSource = "doctor;family;trip;errand;private;lunch;home;other"

    Set ctl = CreateControl(strFrmName, acCheckBox, acDetail, strPageName, "", 5300, 5830, 300, 300)
    ctl.Name = "chkPrerZiadost"
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 5650, 5820, 4350, 400)
    ctl.Caption = "Zamestnanec môže požiadať vopred (žiadosť v termináli)": ctl.FontSize = 8
    Set ctl = CreateControl(strFrmName, acCheckBox, acDetail, strPageName, "", 5300, 6230, 300, 300)
    ctl.Name = "chkPrerSchvalenie"
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 5650, 6220, 4350, 400)
    ctl.Caption = "Deň s týmto dôvodom schvaľuje vedúci": ctl.FontSize = 8
    Set ctl = CreateControl(strFrmName, acCheckBox, acDetail, strPageName, "", 5300, 6630, 300, 300)
    ctl.Name = "chkPrerCelyDen"
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 5650, 6620, 4350, 400)
    ctl.Caption = "Len na celý deň (dovolenka, PN), bez tlačidla": ctl.FontSize = 8
    Set ctl = CreateControl(strFrmName, acCheckBox, acDetail, strPageName, "", 5300, 7030, 300, 300)
    ctl.Name = "chkPrerNezapocitat"
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 5650, 7020, 4350, 400)
    ctl.Caption = "Interval sa nezapočíta do práce (neplatený odchod)": ctl.FontSize = 8

    ' --- 2. SEKCIA: PARAMETRE VÝPOČTU ---
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 7550, 9500, 300)
    ctl.Caption = "2. Parametre výpočtu odpracovaného času"
    ctl.FontBold = True: ctl.FontSize = 10: ctl.ForeColor = RGB(15, 30, 90)

    Call Pole(strFrmName, strPageName, 500, 7900, "Okno práce od:", "txtOknoOd", 800)
    Call Pole(strFrmName, strPageName, 3000, 7900, "do:", "txtOknoDo", 800)
    Call Pole(strFrmName, strPageName, 5500, 7900, "Obed (min):", "txtParObedMin", 700)
    Call Pole(strFrmName, strPageName, 500, 8300, "Obed od (min):", "txtParObedLimit", 800)
    Call Pole(strFrmName, strPageName, 3000, 8300, "Celodenná:", "txtParCelodenna", 800)

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 5500, 8300, 4500, 300)
    ctl.Caption = "(obed sa odpočíta, ak práca > limit a nebol pípnutý)": ctl.FontSize = 8: ctl.ForeColor = RGB(100, 100, 100)

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 7500, 7850, 2500, 420)
    btn.Name = "btnUlozParametre": btn.Caption = "Uložiť parametre": btn.FontBold = True: btn.ForeColor = RGB(0, 100, 0)
    btn.OnClick = "=UlozParametreVypoctuUI()"

    ' --- 2b. PRAVIDLÁ VÝPOČTU (kontrakt 1.4.0): razený obed, zaokrúhlenie, doplnenie opráv ---
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 8800, 9500, 300)
    ctl.Caption = "2b. Pravidlá výpočtu (razený obed, zaokrúhlenie, doplnenie opráv)"
    ctl.FontBold = True: ctl.FontSize = 10: ctl.ForeColor = RGB(15, 30, 90)
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 9130, 9500, 420)
    ctl.Caption = "Predvolené hodnoty dávajú rovnaký výsledok ako doteraz. Platia pri ďalšom prepočte mesiaca; uzavreté mesiace sa neprepočítajú. Do súboru pre terminál sa dostanú len hodnoty, ktoré sa líšia od predvolených."
    ctl.FontSize = 8: ctl.ForeColor = RGB(100, 100, 100)

    Call VolbaSir(strFrmName, strPageName, 500, 9650, "Razený obed:", "cboRazObed", 1500, 3600, LIST_RAZ_OBED)
    Call PoleSir(strFrmName, strPageName, 5800, 9650, "Minúty obeda:", "txtRazObedMin", 1500, 700)
    Call VolbaSir(strFrmName, strPageName, 500, 10050, "Odchod bez dôvodu:", "cboOdchodBezDovodu", 1900, 1200, LIST_ODCHOD_BEZ)
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 3800, 10090, 6200, 280)
    ctl.Caption = "(odchod z terminálu bez dôvodu a neskorší príchod v ten istý deň)": ctl.FontSize = 8: ctl.ForeColor = RGB(100, 100, 100)
    Call PoleSir(strFrmName, strPageName, 500, 10450, "Zaokrúhliť príchod (min):", "txtZaokrPrichod", 2100, 600)
    Call PoleSir(strFrmName, strPageName, 3500, 10450, "odchod (min):", "txtZaokrOdchod", 1300, 600)
    Call VolbaSir(strFrmName, strPageName, 5800, 10450, "Smer:", "cboZaokrSmer", 600, 3600, LIST_ZAOKR_SMER)
    Call VolbaSir(strFrmName, strPageName, 500, 10850, "Doplniť opravu:", "cboOpravaCiel", 1500, 2700, LIST_OPRAVA_CIEL)
    Call VolbaSir(strFrmName, strPageName, 4900, 10850, "Prípady:", "cboOpravaPripady", 900, 3700, LIST_OPRAVA_PRIPADY)
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 11250, 9500, 420)
    ctl.Caption = "Zaokrúhľuje sa prvý razený príchod a posledný razený odchod dňa (0 = bez zaokrúhlenia). Doplnenie opráv platí, ak je automatická oprava zapnutá, a netýka sa obeda."
    ctl.FontSize = 8: ctl.ForeColor = RGB(100, 100, 100)

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 11750, 2700, 420)
    btn.Name = "btnPravidlaDnes": btn.Caption = "Predvoľba: dnešný stav": btn.OnClick = "=PredvolbaPravidielDnesUI()"
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 3550, 11750, 2900, 420)
    btn.Name = "btnPravidlaOdporucane": btn.Caption = "Predvoľba: odporúčané": btn.OnClick = "=PredvolbaPravidielOdporucaneUI()"
    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 7500, 11750, 2500, 420)
    btn.Name = "btnUlozPravidla": btn.Caption = "Uložiť pravidlá": btn.FontBold = True: btn.ForeColor = RGB(0, 100, 0)
    btn.OnClick = "=UlozPravidlaVypoctuUI()"
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 12250, 9500, 300)
    ctl.Name = "lblPravidlaStav": ctl.Caption = "": ctl.FontSize = 8: ctl.ForeColor = RGB(100, 100, 100)

    ' --- 3. SEKCIA: ČASOVÝ PROFIL STREDISKA ---
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 8900 + lDy, 9500, 300)
    ctl.Caption = "3. Časový profil strediska (pružný čas a obedné okno)"
    ctl.FontBold = True: ctl.FontSize = 10: ctl.ForeColor = RGB(15, 30, 90)

    Call Pole(strFrmName, strPageName, 500, 9250 + lDy, "Základný čas od:", "txtZaklOd", 800)
    Call Pole(strFrmName, strPageName, 3000, 9250 + lDy, "do:", "txtZaklDo", 800)
    Call Pole(strFrmName, strPageName, 500, 9650 + lDy, "Pružný ráno od:", "txtVolRanoOd", 800)
    Call Pole(strFrmName, strPageName, 3000, 9650 + lDy, "do:", "txtVolRanoDo", 800)
    Call Pole(strFrmName, strPageName, 500, 10050 + lDy, "Pružný popol. od:", "txtVolPoobOd", 800)
    Call Pole(strFrmName, strPageName, 3000, 10050 + lDy, "do:", "txtVolPoobDo", 800)
    Call Pole(strFrmName, strPageName, 500, 10450 + lDy, "Služ. cesta od:", "txtSlceOd", 800)
    Call Pole(strFrmName, strPageName, 3000, 10450 + lDy, "do:", "txtSlceDo", 800)
    Call Pole(strFrmName, strPageName, 500, 10850 + lDy, "Obedné okno od:", "txtObedOd", 800)
    Call Pole(strFrmName, strPageName, 3000, 10850 + lDy, "do:", "txtObedDo", 800)
    Call Pole(strFrmName, strPageName, 5500, 10850 + lDy, "Trvanie (min):", "txtObedMin", 700)

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 11450 + lDy, 4600, 450)
    btn.Name = "btnUlozitOU"
    btn.Caption = "Uložiť časový profil strediska"
    btn.FontBold = True: btn.ForeColor = RGB(0, 100, 0)
    btn.OnClick = "=SpustiUlozenieOUProfiluUI()"

    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Prerusenia.BuildUI", "ERROR", Err.Description)
End Sub

Public Sub InitDefaults(ByRef frm As Form)
    On Error Resume Next
    ' parametre výpočtu
    frm!txtOknoOd = mod_00_Common.GetNastavenie("OknoPraceOd", "06:00")
    frm!txtOknoDo = mod_00_Common.GetNastavenie("OknoPraceDo", "17:00")
    frm!txtParObedMin = mod_00_Common.ParamPravidla("AUTO_OBED_NAD_6H", "TrvanieObedaMin", "30")
    frm!txtParObedLimit = mod_00_Common.LimitPravidla("AUTO_OBED_NAD_6H", 360)
    frm!txtParCelodenna = mod_00_Common.GetNastavenie("CelodennaPrekazkaMin", "360")
    Call VyplnPravidla(mod_10_Konfiguracia.PravidlaVypoctuSucasne())

    ' časový profil strediska (posledný uložený alebo predvolený)
    frm!txtZaklOd = "08:00": frm!txtZaklDo = "14:30"
    frm!txtVolRanoOd = "06:00": frm!txtVolRanoDo = "08:00"
    frm!txtVolPoobOd = "14:30": frm!txtVolPoobDo = "18:00"
    frm!txtSlceOd = "07:00": frm!txtSlceDo = "16:00"
    frm!txtObedOd = "11:00": frm!txtObedDo = "13:30": frm!txtObedMin = "30"
    If mod_00_Common.TabulkaExistuje("ProfilOrganizacnaJednotka") Then
        Dim rs As DAO.Recordset
        Set rs = CurrentDb.OpenRecordset("SELECT TOP 1 * FROM ProfilOrganizacnaJednotka ORDER BY ID DESC;", dbOpenSnapshot)
        If Not rs.EOF Then
            frm!txtZaklOd = rs!ZakladnyCasOd: frm!txtZaklDo = rs!ZakladnyCasDo
            frm!txtVolRanoOd = rs!VolitelnyRannyOd: frm!txtVolRanoDo = rs!VolitelnyRannyDo
            frm!txtVolPoobOd = rs!VolitelnyPoobednyOd: frm!txtVolPoobDo = rs!VolitelnyPoobednyDo
            frm!txtSlceOd = rs!SluzobnaCestaAutoOd: frm!txtSlceDo = rs!SluzobnaCestaAutoDo
            frm!txtObedOd = rs!ObedOknoOd: frm!txtObedDo = rs!ObedOknoDo: frm!txtObedMin = rs!ObedTrvanieMinuty
        End If
        rs.Close
    End If
    Call PrerusenieObnovUI
    Call PrerusenieNoveUI
End Sub

'-------------------------------------------------------------------------------
' EDITORY ČÍSELNÍKOV (pracovné fondy, pravidlá prerušení) - otvoria sa pre aktuálny mesiac
'-------------------------------------------------------------------------------
Public Function PrerusenieFondyUI() As Boolean
    On Error GoTo ChybaHandler
    PrerusenieFondyUI = mod_UI_Sablony.OtvorEditorFondov(0, CInt(Year(Date)), CInt(Month(Date)))
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Prerusenia.PrerusenieFondyUI", "ERROR", Err.Description)
End Function

Public Function PreruseniePravidlaUI() As Boolean
    On Error GoTo ChybaHandler
    PreruseniePravidlaUI = mod_UI_Sablony.OtvorEditorPravidiel(0, CInt(Year(Date)), CInt(Month(Date)))
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Prerusenia.PreruseniePravidlaUI", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' ČÍSELNÍK PRERUŠENÍ
'-------------------------------------------------------------------------------
Public Function PrerusenieObnovUI() As Boolean
    On Error GoTo ChybaHandler
    Dim frm As Form
    If Not mod_00_Common.FormIsOpen("frmHlavnaKonzola") Then Exit Function
    Set frm = Forms!frmHlavnaKonzola
    If mod_00_Common.TabulkaExistuje("CiselnikPreruseni") Then
        Call mod_10_Konfiguracia.ZabezpecStlpceKonfiguracie(CurrentDb)
        frm!lstPrerusenia.RowSource = mod_10_Konfiguracia.ZoznamPreruseniSQL()
        frm!lblPrerStav.Caption = "Prerušení: " & DCount("*", "CiselnikPreruseni") & ", kódov razení: " & DCount("*", "KodyRazeni") & _
                                  IIf(DCount("*", "CiselnikPreruseni") = 0, "  -  číselník je prázdny, použite INICIALIZOVAŤ PREDVOLENÚ KONFIGURÁCIU.", "")
    Else
        frm!lstPrerusenia.RowSource = ""
        frm!lblPrerStav.Caption = "Číselník prerušení ešte neexistuje - použite INICIALIZOVAŤ PREDVOLENÚ KONFIGURÁCIU."
    End If
    PrerusenieObnovUI = True
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Prerusenia.PrerusenieObnovUI", "ERROR", Err.Description)
End Function

Public Function PrerusenieVyberUI() As Boolean
    On Error GoTo ChybaHandler
    Dim frm As Form, rs As DAO.Recordset
    Set frm = Forms!frmHlavnaKonzola
    If IsNull(frm!lstPrerusenia.Value) Then Exit Function
    Call mod_10_Konfiguracia.ZabezpecStlpceKonfiguracie(CurrentDb)
    Set rs = CurrentDb.OpenRecordset("SELECT * FROM CiselnikPreruseni WHERE Cislo = " & CLng(frm!lstPrerusenia.Value) & ";", dbOpenSnapshot)
    If Not rs.EOF Then
        frm!txtPrerCislo = rs!Cislo
        frm!txtPrerNazov = rs!Nazov
        frm!txtPrerSkratka = rs!NazovSkratka
        frm!txtPrerKodZ = rs!KodZaciatok
        frm!txtPrerKodK = rs!KodKoniec
        frm!chkPrerAutoKoniec = CBool(Nz(rs!AutoKoniecDoKoncaSmeny, False))
        Call NacitajPriznaky(frm, rs)
    End If
    rs.Close
    PrerusenieVyberUI = True
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Prerusenia.PrerusenieVyberUI", "ERROR", Err.Description)
End Function

Public Function PrerusenieNoveUI() As Boolean
    On Error Resume Next
    Dim frm As Form, lC As Long, lK As Long
    Set frm = Forms!frmHlavnaKonzola
    lC = Nz(DMax("Cislo", "CiselnikPreruseni"), 0) + 1
    lK = Nz(DMax("KodRazenia", "KodyRazeni"), 99) + 1
    If lK < 100 Then lK = 100
    frm!txtPrerCislo = lC
    frm!txtPrerNazov = ""
    frm!txtPrerSkratka = ""
    frm!txtPrerKodZ = lK
    frm!txtPrerKodK = lK + 1
    frm!chkPrerAutoKoniec = False
    Call VycistiPriznaky(frm)
    PrerusenieNoveUI = True
End Function

'-------------------------------------------------------------------------------
' Tlačidlo a príznaky pre terminál (karta 5, blok "Tlačidlo a príznaky pre terminál")
'-------------------------------------------------------------------------------
Private Sub VycistiPriznaky(ByRef frm As Form)
    On Error Resume Next
    frm!chkPrerTlacidlo = False
    frm!txtPrerTlacText = Null
    frm!txtPrerTlacPoradie = Null
    frm!cboPrerIkona = Null
    frm!chkPrerZiadost = False
    frm!chkPrerSchvalenie = False
    frm!chkPrerCelyDen = False
    frm!chkPrerNezapocitat = False
End Sub

Private Sub NacitajPriznaky(ByRef frm As Form, ByRef rs As DAO.Recordset)
    On Error Resume Next
    Dim strIkona As String, strTlacText As String, lPoradie As Long
    strIkona = CStr(Nz(rs!TerminalIkona, ""))
    strTlacText = CStr(Nz(rs!TerminalText, ""))
    lPoradie = CLng(Nz(rs!TerminalPoradie, 0))
    frm!chkPrerTlacidlo = CBool(Nz(rs!TerminalTlacidlo, False))
    If Len(strTlacText) > 0 Then frm!txtPrerTlacText = strTlacText Else frm!txtPrerTlacText = Null
    If lPoradie > 0 Then frm!txtPrerTlacPoradie = lPoradie Else frm!txtPrerTlacPoradie = Null
    If Len(strIkona) > 0 Then frm!cboPrerIkona = strIkona Else frm!cboPrerIkona = Null
    frm!chkPrerZiadost = CBool(Nz(rs!TerminalZiadost, False))
    frm!chkPrerSchvalenie = CBool(Nz(rs!VyzadujeSchvalenie, False))
    frm!chkPrerCelyDen = CBool(Nz(rs!LenCelyDen, False))
    frm!chkPrerNezapocitat = CBool(Nz(rs!NezapocitavatInterval, False))
End Sub

' Skontroluje príznaky z formulára (bez zápisu). Vráti chybovú správu, prázdna = v poriadku.
Private Function KontrolaPriznakovZFormulara(ByRef frm As Form) As String
    KontrolaPriznakovZFormulara = mod_10_Konfiguracia.ChybaPriznakov(CLng(Val(Nz(frm!txtPrerCislo, 0))), CBool(Nz(frm!chkPrerTlacidlo, False)), _
        CStr(Nz(frm!txtPrerTlacText, "")), CLng(Val(Nz(frm!txtPrerTlacPoradie, 0))), CStr(Nz(frm!cboPrerIkona, "")), _
        CBool(Nz(frm!chkPrerZiadost, False)), CBool(Nz(frm!chkPrerSchvalenie, False)), CBool(Nz(frm!chkPrerCelyDen, False)), _
        CBool(Nz(frm!chkPrerNezapocitat, False)))
End Function

' Uloží príznaky z formulára k už uloženému prerušeniu. Vráti chybovú správu, prázdna = OK.
Private Function UlozPriznakyZFormulara(ByRef frm As Form) As String
    UlozPriznakyZFormulara = mod_10_Konfiguracia.UlozPriznakyPrerusenia(CLng(Val(Nz(frm!txtPrerCislo, 0))), CBool(Nz(frm!chkPrerTlacidlo, False)), _
        CStr(Nz(frm!txtPrerTlacText, "")), CLng(Val(Nz(frm!txtPrerTlacPoradie, 0))), CStr(Nz(frm!cboPrerIkona, "")), _
        CBool(Nz(frm!chkPrerZiadost, False)), CBool(Nz(frm!chkPrerSchvalenie, False)), CBool(Nz(frm!chkPrerCelyDen, False)), _
        CBool(Nz(frm!chkPrerNezapocitat, False)))
End Function

Public Function PrerusenieUlozUI() As Boolean
    On Error GoTo ChybaHandler
    Dim frm As Form, strErr As String
    Set frm = Forms!frmHlavnaKonzola
    If Not mod_00_Common.TabulkaExistuje("CiselnikPreruseni") Or Not mod_00_Common.TabulkaExistuje("KodyRazeni") Then
        MsgBox "Číselník ešte neexistuje - najprv použite INICIALIZOVAŤ PREDVOLENÚ KONFIGURÁCIU.", vbExclamation, "Prerušenia"
        Exit Function
    End If
    ' príznaky sa skontrolujú pred zápisom, aby chyba v nich nenechala prerušenie uložené len napoly
    strErr = KontrolaPriznakovZFormulara(frm)
    If Len(strErr) > 0 Then
        MsgBox strErr, vbExclamation, "Prerušenia - tlačidlo a príznaky"
        Exit Function
    End If
    strErr = mod_10_Konfiguracia.UlozPrerusenie(CLng(Val(Nz(frm!txtPrerCislo, 0))), CStr(Nz(frm!txtPrerNazov, "")), CStr(Nz(frm!txtPrerSkratka, "")), _
                                                 CLng(Val(Nz(frm!txtPrerKodZ, 0))), CLng(Val(Nz(frm!txtPrerKodK, 0))), CBool(Nz(frm!chkPrerAutoKoniec, False)))
    If Len(strErr) > 0 Then
        MsgBox strErr, vbExclamation, "Prerušenia"
        Exit Function
    End If
    strErr = UlozPriznakyZFormulara(frm)
    If Len(strErr) > 0 Then
        Call PrerusenieObnovUI
        MsgBox "Prerušenie bolo uložené, ale tlačidlo a príznaky nie:" & vbCrLf & vbCrLf & strErr, vbExclamation, "Prerušenia - tlačidlo a príznaky"
        Exit Function
    End If
    Call PrerusenieObnovUI
    Call mod_UI_Pomocnik.OznacCinnost("PRERUSENIA")
    PrerusenieUlozUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri ukladaní prerušenia: " & Err.Description, vbCritical
End Function

Public Function PrerusenieZmazUI() As Boolean
    On Error GoTo ChybaHandler
    Dim frm As Form, strErr As String, lC As Long
    Set frm = Forms!frmHlavnaKonzola
    lC = CLng(Val(Nz(frm!txtPrerCislo, 0)))
    If lC <= 0 Then Exit Function
    If MsgBox("Zmazať prerušenie " & lC & " (" & Nz(frm!txtPrerNazov, "") & ") a jeho kódy razení?", vbYesNo + vbQuestion, "Prerušenia") <> vbYes Then Exit Function
    strErr = mod_10_Konfiguracia.ZmazPrerusenie(lC)
    If Len(strErr) > 0 Then
        MsgBox strErr, vbExclamation, "Prerušenia"
        Exit Function
    End If
    Call PrerusenieObnovUI
    Call PrerusenieNoveUI
    PrerusenieZmazUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri mazaní prerušenia: " & Err.Description, vbCritical
End Function

Public Function InicializujKonfiguraciuUI() As Boolean
    Dim n As Long, nF As Long, strF As String, strT As String
    If MsgBox("Doplniť predvolenú konfiguráciu?" & vbCrLf & vbCrLf & _
              "- prerušenia a kódy razení, pravidlá anomálií, parametre výpočtu, štátne sviatky SR," & vbCrLf & _
              "- predvolené tlačidlá a príznaky prerušení pre terminál (jednorazovo, len pre prerušenia, ktoré ste ešte nenastavili)," & vbCrLf & _
              "- pracovný fond (denný fond 7:30), šablónu pravidiel bez kontroly a kalendár, ak ešte žiadne nie sú, a ich priradenie zamestnancom, ktorí nemajú žiadne priradenie." & vbCrLf & vbCrLf & _
              "Existujúce záznamy sa NEMENIA, doplnia sa len chýbajúce." & vbCrLf & vbCrLf & _
              "Ak chcete preniesť fondy a priradenia zo staršej databázy (karta 1, tlačidlo 5), urobte to PRED týmto krokom.", _
              vbYesNo + vbQuestion, "Predvolená konfigurácia") <> vbYes Then Exit Function
    n = mod_10_Konfiguracia.InicializujPredvolenuKonfiguraciu(True)
    If n >= 0 Then
        nF = mod_10_Konfiguracia.InicializujPracovneNastavenia(strF)
        If nF < 0 Then
            MsgBox "Prerušenia, kódy a parametre sú pripravené, ale pracovný fond sa nepodarilo doplniť:" & vbCrLf & vbCrLf & strF & vbCrLf & vbCrLf & _
                   "Podrobnosti sú v logu (záložka Audit & Admin).", vbExclamation, "Predvolená konfigurácia"
        Else
            strT = mod_10_Konfiguracia.PoslednaSpravaTlacidiel()
            MsgBox "Konfigurácia je pripravená. Pridaných záznamov: " & (n + nF) & vbCrLf & vbCrLf & strF & vbCrLf & _
                   IIf(Len(strT) > 0, vbCrLf & strT & vbCrLf, "") & vbCrLf & mod_10_Konfiguracia.StavKonfiguracie(), vbInformation, "Predvolená konfigurácia"
        End If
        Call InitDefaults(Forms!frmHlavnaKonzola)
        Call mod_UI_Pomocnik.OznacCinnost("PRERUSENIA")
        InicializujKonfiguraciuUI = (nF >= 0)
    Else
        MsgBox "Inicializácia zlyhala - podrobnosti sú v logu (záložka Audit & Admin).", vbExclamation, "Predvolená konfigurácia"
    End If
End Function

Public Function UlozParametreVypoctuUI() As Boolean
    On Error GoTo ChybaHandler
    Dim frm As Form, strErr As String
    Set frm = Forms!frmHlavnaKonzola
    If Not mod_00_Common.TabulkaExistuje("CiselnikPravidielAnomalii") Then Call mod_01_SystemInit.InicializujPravidlaAnomalii
    strErr = mod_10_Konfiguracia.UlozParametreVypoctu(CStr(Nz(frm!txtOknoOd, "")), CStr(Nz(frm!txtOknoDo, "")), CLng(Val(Nz(frm!txtParObedMin, 0))), _
                                                       CLng(Val(Nz(frm!txtParObedLimit, 0))), CLng(Val(Nz(frm!txtParCelodenna, 0))))
    If Len(strErr) > 0 Then
        MsgBox strErr, vbExclamation, "Parametre výpočtu"
        Exit Function
    End If
    MsgBox "Parametre uložené. Zmeny sa prejavia pri ďalšom prepočte mesiaca.", vbInformation, "Parametre výpočtu"
    Call mod_UI_Pomocnik.OznacCinnost("PRERUSENIA")
    UlozParametreVypoctuUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri ukladaní parametrov: " & Err.Description, vbCritical
End Function

'-------------------------------------------------------------------------------
' PRAVIDLÁ VÝPOČTU (razený obed, zaokrúhlenie, doplnenie opráv)
'-------------------------------------------------------------------------------
' Vyplní polia sekcie 2b z reťazca hodnôt (mod_10_Konfiguracia: obed|minúty|odchod|príchod|odchod|smer|cieľ|prípady).
Private Sub VyplnPravidla(ByVal strHodnoty As String)
    Dim a() As String, frm As Form
    a = Split(strHodnoty, "|")
    If UBound(a) < 7 Then Exit Sub
    Set frm = Forms!frmHlavnaKonzola
    frm!cboRazObed = VolbaPodlaKodu(LIST_RAZ_OBED, CLng(Val(a(0))))
    frm!txtRazObedMin = a(1)
    frm!cboOdchodBezDovodu = LCase$(a(2))
    frm!txtZaokrPrichod = a(3)
    frm!txtZaokrOdchod = a(4)
    frm!cboZaokrSmer = VolbaPodlaKodu(LIST_ZAOKR_SMER, CLng(Val(a(5))))
    frm!cboOpravaCiel = VolbaPodlaKodu(LIST_OPRAVA_CIEL, CLng(Val(a(6))))
    frm!cboOpravaPripady = VolbaPodlaKodu(LIST_OPRAVA_PRIPADY, CLng(Val(a(7))))
End Sub

Private Sub PredvolbaPravidiel(ByVal strNazov As String, ByVal strPopis As String)
    Dim strH As String
    strH = mod_10_Konfiguracia.PredvolbaPravidielVypoctu(strNazov)
    If Len(strH) = 0 Then Exit Sub
    Call VyplnPravidla(strH)
    Forms!frmHlavnaKonzola!lblPravidlaStav.Caption = strPopis & " Hodnoty sú len vyplnené; uložte ich tlačidlom Uložiť pravidlá."
End Sub

Public Function PredvolbaPravidielDnesUI() As Boolean
    On Error GoTo ChybaHandler
    Call PredvolbaPravidiel("DNES", "Dnešný stav: razený obed v skutočnom čase, bez zaokrúhlenia, opravy do denného fondu.")
    PredvolbaPravidielDnesUI = True
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Prerusenia.PredvolbaPravidielDnesUI", "ERROR", Err.Description)
End Function

Public Function PredvolbaPravidielOdporucaneUI() As Boolean
    On Error GoTo ChybaHandler
    Call PredvolbaPravidiel("ODPORUCANE", "Odporúčané: razený obed najmenej 30 minút, inak ako dnes (potvrďte s HR).")
    PredvolbaPravidielOdporucaneUI = True
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_Prerusenia.PredvolbaPravidielOdporucaneUI", "ERROR", Err.Description)
End Function

Public Function UlozPravidlaVypoctuUI() As Boolean
    On Error GoTo ChybaHandler
    Dim frm As Form, strErr As String, strMsg As String
    Set frm = Forms!frmHlavnaKonzola
    strErr = mod_10_Konfiguracia.UlozPravidlaVypoctu(CLng(Val(Nz(frm!cboRazObed, "0"))), CLng(Val(Nz(frm!txtRazObedMin, "30"))), _
                 CStr(Nz(frm!cboOdchodBezDovodu, "obed")), CLng(Val(Nz(frm!txtZaokrPrichod, "0"))), CLng(Val(Nz(frm!txtZaokrOdchod, "0"))), _
                 CLng(Val(Nz(frm!cboZaokrSmer, "0"))), CLng(Val(Nz(frm!cboOpravaCiel, "0"))), CLng(Val(Nz(frm!cboOpravaPripady, "3"))))
    If Len(strErr) > 0 Then
        MsgBox strErr, vbExclamation, "Pravidlá výpočtu"
        Exit Function
    End If
    strMsg = "Pravidlá výpočtu uložené. Platia pri ďalšom prepočte mesiaca; uzavreté mesiace sa neprepočítajú."
    If Len(mod_20_KonfiguraciaExport.VolitelnePravidla()) > 0 Then
        strMsg = strMsg & vbCrLf & vbCrLf & "Nastavili ste hodnoty iné než predvolené, preto ich bude obsahovať aj export konfigurácie pre terminál (karta 7). " & _
                 "Terminál ich zatiaľ len prijme a neuplatní; skôr než taký súbor prijmete v produkčnom termináli, musí byť nasadená databázová časť (krok 5)."
    End If
    MsgBox strMsg, vbInformation, "Pravidlá výpočtu"
    frm!lblPravidlaStav.Caption = "Pravidlá výpočtu uložené " & Format$(Now, "d. m. yyyy hh:nn") & "."
    Call mod_UI_Pomocnik.OznacCinnost("PRERUSENIA")
    UlozPravidlaVypoctuUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri ukladaní pravidiel výpočtu: " & Err.Description, vbCritical
End Function

'-------------------------------------------------------------------------------
' Ukladá nastavenia časového profilu strediska (jeden záznam; opakované uloženie ho aktualizuje).
'-------------------------------------------------------------------------------
Public Function SpustiUlozenieOUProfiluUI() As Boolean
    On Error GoTo ChybaHandler
    Dim frm As Form, db As DAO.Database, rs As DAO.Recordset, v As Variant
    Set frm = Forms!frmHlavnaKonzola
    Set db = CurrentDb

    For Each v In Array("txtZaklOd", "txtZaklDo", "txtVolRanoOd", "txtVolRanoDo", "txtVolPoobOd", "txtVolPoobDo", "txtSlceOd", "txtSlceDo", "txtObedOd", "txtObedDo")
        If mod_00_Common.CasNaMinuty(CStr(Nz(frm.Controls(CStr(v)).Value, ""))) < 0 Then
            MsgBox "Čas v poli '" & CStr(v) & "' nie je v tvare HH:MM.", vbExclamation, "Časový profil"
            Exit Function
        End If
    Next v

    If Not mod_00_Common.TabulkaExistuje("ProfilOrganizacnaJednotka") Then
        db.Execute "CREATE TABLE ProfilOrganizacnaJednotka (" & _
                   "ID AUTOINCREMENT PRIMARY KEY, NazovOU TEXT(100), ZakladnyCasOd TEXT(10), ZakladnyCasDo TEXT(10), " & _
                   "VolitelnyRannyOd TEXT(10), VolitelnyRannyDo TEXT(10), VolitelnyPoobednyOd TEXT(10), VolitelnyPoobednyDo TEXT(10), " & _
                   "SluzobnaCestaAutoOd TEXT(10), SluzobnaCestaAutoDo TEXT(10), ObedOknoOd TEXT(10), ObedOknoDo TEXT(10), ObedTrvanieMinuty LONG);", dbFailOnError
    End If

    Set rs = db.OpenRecordset("SELECT * FROM ProfilOrganizacnaJednotka WHERE NazovOU = 'Hlavné stredisko';", dbOpenDynaset)
    If rs.EOF Then rs.AddNew: rs!NazovOU = "Hlavné stredisko" Else rs.Edit
    rs!ZakladnyCasOd = frm!txtZaklOd: rs!ZakladnyCasDo = frm!txtZaklDo
    rs!VolitelnyRannyOd = frm!txtVolRanoOd: rs!VolitelnyRannyDo = frm!txtVolRanoDo
    rs!VolitelnyPoobednyOd = frm!txtVolPoobOd: rs!VolitelnyPoobednyDo = frm!txtVolPoobDo
    rs!SluzobnaCestaAutoOd = frm!txtSlceOd: rs!SluzobnaCestaAutoDo = frm!txtSlceDo
    rs!ObedOknoOd = frm!txtObedOd: rs!ObedOknoDo = frm!txtObedDo
    rs!ObedTrvanieMinuty = CLng(Val(Nz(frm!txtObedMin, 30)))
    rs.Update
    rs.Close

    MsgBox "Časový profil strediska bol uložený." & vbCrLf & "Zmeny sa prejavia až po novom prepočte v záložke '6. Výpočet & Zostavy'.", vbInformation, "Časový profil"
    Call mod_UI_Pomocnik.OznacCinnost("PRERUSENIA")
    SpustiUlozenieOUProfiluUI = True
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("SpustiUlozenieOUProfiluUI", "ERROR", "Chyba pri ukladaní OU profilu: " & Err.Description)
    MsgBox "Chyba pri ukladaní časového profilu: " & Err.Description, vbCritical
End Function
