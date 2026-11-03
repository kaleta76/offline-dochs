Attribute VB_Name = "mod_UI_Sablony"
'@Verzia 1.1.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_UI_Sablony
' POPIS: Dialógové okná na úpravu pracovných fondov a pravidiel prerušení (podľa Ordata, rozšírené):
'        - frmFondKarta     : pracovný fond - názov, typ (pevná / pružná / voľná podľa denného fondu / voľná s pevným
'                             mesačným fondom), denný a mesačný fond, rôzna dĺžka podľa dňa v týždni (príchod od, odchod do,
'                             fond a prestávka pre pondelok až nedeľu), nový fond ako kópia, uloženie od zvoleného mesiaca,
'        - frmPravidlaKarta : pravidlá prerušení šablóny - povolený čas (jedna dvojica pre všetky dni alebo pre každý deň
'                             v týždni zvlášť), najdlhšie a najkratšie trvanie, najmenej odpracovať pred začiatkom (napr. obed
'                             najskôr po 3 hodinách práce), zapnutie / vypnutie pravidla, nová šablóna ako kópia.
'        Pri porušení pravidla sa vo výpočte nič nemení - v zozname anomálií (karta Kontrola, editor dňa) pribudne
'        upozornenie (závažnosť VAROVANIE), napr. "Obed 10:40-11:15 mimo povoleného času 11:00-13:30".
'        Okná sa generujú programovo pri prvom použití (a po zmene verzie okna).
'        Od verzie 1.1: skok na zamestnanca (zobrazí fond / šablónu platnú pre neho v zvolenom mesiaci), zoznam verzií
'        (história "platné od mesiaca"), tlačidlo Kto používa, predvolené hodnoty (predvoľby) pre rýchle vyplnenie, nový fond
'        z predvoľby a červené upozornenie, keď by uloženie zasiahlo uzavretý (podpísaný) mesiac.
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - OtvorEditorFondov(fond, rok, mes, [oc])       : Otvorí okno fondov (fond 0 = prvý; oc = zamestnanec, pre ktorého sa zobrazí).
' - OtvorEditorPravidiel(sablona, rok, mes, [oc]) : Otvorí okno pravidiel prerušení (šablóna 0 = prvá).
' - Fk_* : obsluha okna fondov; Pk_* : obsluha okna pravidiel prerušení.
'===============================================================================

Private Const FRM_FOND As String = "frmFondKarta"
Private Const FRM_PRAV As String = "frmPravidlaKarta"
Private Const VERZIA_FOND As String = "1.1"
Private Const VERZIA_PRAV As String = "1.1"
Private Const KLUC_VER_FOND As String = "FondKartaFormVerzia"
Private Const KLUC_VER_PRAV As String = "PravidlaKartaFormVerzia"
Private Const FARBA_NADPIS As Long = 5905935         ' RGB(15, 30, 90)

Private Function DenNazov(ByVal n As Long) As String
    DenNazov = Choose(n, "Pondelok", "Utorok", "Streda", "Štvrtok", "Piatok", "Sobota", "Nedeľa")
End Function

'-------------------------------------------------------------------------------
' Prvá hodnota (kód) zo zoznamu hodnôt "kód;text;kód;text"; 0, ak je zoznam prázdny.
'-------------------------------------------------------------------------------
Private Function PrvyKod(ByVal strVL As String) As Long
    Dim p As Long
    p = InStr(strVL, ";")
    If p > 1 Then PrvyKod = CLng(Val(Left$(strVL, p - 1)))
End Function

Private Function ZoznamHodnota(ByVal ctl As Control) As Long
    On Error Resume Next
    ZoznamHodnota = CLng(Val(CStr(Nz(ctl.Value, 0))))
End Function

'-------------------------------------------------------------------------------
' Trvanie v minútach z textu: "30" alebo "0:30"; prázdne = 0; neplatné = -1.
'-------------------------------------------------------------------------------
Private Function MinutyZVstupu(ByVal strText As String) As Long
    strText = Trim$(strText)
    If Len(strText) = 0 Then MinutyZVstupu = 0: Exit Function
    If InStr(strText, ":") > 0 Then
        MinutyZVstupu = mod_00_Common.CasNaMinuty(strText)
    ElseIf IsNumeric(strText) Then
        MinutyZVstupu = CLng(Val(strText))
        If MinutyZVstupu < 0 Then MinutyZVstupu = -1
    Else
        MinutyZVstupu = -1
    End If
End Function

Private Function MinutyNaTextTrvania(ByVal lMin As Long, ByVal bBezObmedzenia1440 As Boolean) As String
    If lMin <= 0 Then Exit Function
    If bBezObmedzenia1440 And lMin >= 1440 Then Exit Function
    MinutyNaTextTrvania = CStr(lMin)
End Function

Private Sub StitokStlpca(ByVal strFrm As String, ByVal lX As Long, ByVal lY As Long, ByVal lW As Long, ByVal strText As String)
    Dim ctl As Control
    Set ctl = mod_UI_Spolocne.DlgPopisok(strFrm, "", lX, lY, lW, 280, strText, 9, True, FARBA_NADPIS)
    ctl.BackStyle = 1
    ctl.BackColor = RGB(215, 222, 238)
End Sub

'-------------------------------------------------------------------------------
' Zoznam zamestnancov (tabuľka / dopyt) do rozbaľovacieho zoznamu "Zamestnanec".
'-------------------------------------------------------------------------------
Private Sub NastavVyberZamestnanca(ByVal ctl As Control)
    ctl.RowSourceType = "Table/Query"
    ctl.RowSource = mod_17_FondyPravidla.SqlZamestnanciVyber()
    ctl.ColumnCount = 2
    ctl.ColumnWidths = "0;4400"
    ctl.BoundColumn = 1
End Sub

'-------------------------------------------------------------------------------
' Zoznam predvolieb: rozbalený zoznam je širší ako samotné pole.
'-------------------------------------------------------------------------------
Private Sub NastavVyberPredvolby(ByVal ctl As Control, ByVal strZoznam As String)
    ctl.RowSource = strZoznam
    ctl.ColumnWidths = "0;5600"
    ctl.ListWidth = 5600
End Sub

'-------------------------------------------------------------------------------
' Stavový riadok okna: zelený informačný text, alebo červené upozornenie na uzavretý mesiac (a za ním informácia).
'-------------------------------------------------------------------------------
Private Sub StavOkna(ByVal ctl As Control, ByVal strInfo As String, ByVal strZamok As String)
    If Len(strZamok) > 0 Then
        ctl.ForeColor = RGB(180, 0, 0)
        ctl.Caption = Trim$(strZamok & " " & strInfo)
    Else
        ctl.ForeColor = RGB(0, 100, 0)
        ctl.Caption = strInfo
    End If
End Sub

'-------------------------------------------------------------------------------
' Text upozornenia, keď by uloženie od zvoleného mesiaca zasiahlo uzavretý mesiac (strDotknute = "" -> bez upozornenia).
'-------------------------------------------------------------------------------
Private Function TextZamku(ByVal strDotknute As String) As String
    If Len(strDotknute) = 0 Then Exit Function
    TextZamku = "POZOR: uložením od tohto mesiaca by sa zmenil uzavretý (podpísaný) mesiac - " & strDotknute & _
                ". Uloženie bude zablokované; mesiac najprv otvorte (karta Výpočet, Uzávierka mesiaca) alebo zvoľte neskorší mesiac."
End Function

'-------------------------------------------------------------------------------
' Nastaví výber mesiaca podľa hodnoty zo zoznamu verzií "rrrrmm".
'-------------------------------------------------------------------------------
Private Sub MesiacZVerzie(ByVal ctlMesiac As Control, ByVal ctlVerzia As Control)
    Dim v As Long
    v = ZoznamHodnota(ctlVerzia)
    If v < 199001 Then Exit Sub
    Call mod_UI_Spolocne.NastavVyberMesiaca(ctlMesiac, v \ 100, v Mod 100)
End Sub

'===============================================================================
' PRACOVNÉ FONDY
'===============================================================================

Private Sub VytvorFondKartu()
    On Error GoTo Chyba
    Dim frm As Form, strTmp As String, ctl As Control, n As Long, lY As Long, strDiag As String, strE As String
    Const P As Long = 420      ' posun poloziek pod riadkami Zamestnanec a Platné od (oproti verzii 1.0)

    Call mod_UI_Spolocne.DlgZmazFormular(FRM_FOND)
    Set frm = mod_UI_Spolocne.DlgNovyFormular("Pracovné fondy", 10400, 8520, strTmp, "=Fk_PoZatvoreniUI()")

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 100, 9800, 400, "Pracovné fondy", 13, True, FARBA_NADPIS)

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 640, 1100, 300, "Fond:")
    Call mod_UI_Spolocne.DlgVyber(strTmp, "cboFkFond", 1500, 600, 4600, "", "=Fk_FondVybranyUI()")
    Call mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnFkNovy", 6250, 590, 1700, "Nový fond...", "=Fk_NovyUI()")
    Call mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnFkKto", 8100, 590, 2200, "Kto používa", "=Fk_KtoUI()")

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 1060, 1400, 300, "Zamestnanec:")
    Set ctl = mod_UI_Spolocne.DlgVyber(strTmp, "cboFkZam", 1700, 1020, 4400, "", "=Fk_ZamVybranyUI()")
    ctl.ControlTipText = "Vyberte zamestnanca - zobrazí sa fond, ktorý pre neho platí v zvolenom mesiaci"
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "lblFkZam", 6250, 1000, 4050, 420, "", 8, False, RGB(100, 100, 100))

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 1480, 1900, 300, "Platné od mesiaca:")
    Call mod_UI_Spolocne.DlgVyber(strTmp, "cboFkMesiac", 2200, 1440, 2400, mod_UI_Spolocne.ZoznamMesiacovRowSource(), "=Fk_MesiacZmenenyUI()")
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 4750, 1480, 750, 300, "Verzie:")
    Set ctl = mod_UI_Spolocne.DlgVyber(strTmp, "cboFkVerzia", 5500, 1440, 1800, "", "=Fk_VerziaVybranaUI()")
    ctl.ControlTipText = "História fondu: verzie platné od mesiaca. Výber verzie zobrazí jej hodnoty."
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "lblFkVerzia", 7450, 1460, 2850, 420, "", 8, False, RGB(100, 100, 100))

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 1900, 1100, 300, "Názov:")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtFkNazov", 1500, 1860, 4600)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 6250, 1900, 1000, 300, "Predvoľba:")
    Set ctl = mod_UI_Spolocne.DlgVyber(strTmp, "cboFkPredvolba", 7250, 1860, 2250, "")
    ctl.ControlTipText = "Predvolené hodnoty fondu - po výbere stlačte Použiť (nič sa neuloží, kým nestlačíte Uložiť)"
    Call mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnFkPredvolba", 9550, 1850, 750, "Použiť", "=Fk_PredvolbaUI()")

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 1900 + P, 1100, 300, "Typ fondu:")
    Call mod_UI_Spolocne.DlgVyber(strTmp, "cboFkTyp", 1500, 1860 + P, 5300, mod_17_FondyPravidla.ZoznamTypovFonduVL(), "=Fk_PrepniUI()")

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 2340 + P, 2100, 300, "Denný fond (h:mm):")
    Set ctl = mod_UI_Spolocne.DlgPole(strTmp, "txtFkDenny", 2450, 2300 + P, 900)
    ctl.ControlTipText = "Priemerná dĺžka pracovného dňa, napr. 7:30"
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 3700, 2340 + P, 2200, 300, "Mesačný fond (h:mm):")
    Set ctl = mod_UI_Spolocne.DlgPole(strTmp, "txtFkMesacny", 5950, 2300 + P, 1100)
    ctl.ControlTipText = "Len pri type 4: pevný fond spolu za mesiac, napr. 165:00"
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 7200, 2340 + P, 3000, 300, "(len pri type 4)", 8, False, RGB(100, 100, 100))

    Call mod_UI_Spolocne.DlgZaskrtavatko(strTmp, "chkFkPodlaDna", 300, 2780 + P, "=Fk_PrepniUI()")
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 650, 2770 + P, 9500, 300, "Rôzna dĺžka fondu podľa dňa v týždni (inak platí denný fond pre každý pracovný deň)")

    Call StitokStlpca(strTmp, 300, 3220 + P, 1550, "Deň")
    Call StitokStlpca(strTmp, 1900, 3220 + P, 1350, "Príchod od")
    Call StitokStlpca(strTmp, 3300, 3220 + P, 1350, "Odchod do")
    Call StitokStlpca(strTmp, 4700, 3220 + P, 1450, "Fond (h:mm)")
    Call StitokStlpca(strTmp, 6200, 3220 + P, 1550, "Prestávka (min)")
    For n = 1 To 7
        lY = 3550 + P + (n - 1) * 370
        Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, lY + 20, 1550, 300, DenNazov(n))
        Call mod_UI_Spolocne.DlgPole(strTmp, "txtFk" & n & "Od", 1900, lY, 1350)
        Call mod_UI_Spolocne.DlgPole(strTmp, "txtFk" & n & "Do", 3300, lY, 1350)
        Call mod_UI_Spolocne.DlgPole(strTmp, "txtFk" & n & "Fond", 4700, lY, 1450)
        Call mod_UI_Spolocne.DlgPole(strTmp, "txtFk" & n & "Prest", 6200, lY, 1550)
    Next n
    Call mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnFkKopia", 7900, 3550 + P, 2400, "Po-Pi ako pondelok", "=Fk_KopiaPondelokUI()")

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 6250 + P, 9900, 720, _
        "Príchod od a Odchod do určujú časové okno, v ktorom možno pracovať (pri pružnom čase napr. 6:00 - 18:00). Fond je povinný počet " & _
        "hodín v daný deň (napr. 7:30). Prestávka sa pripočíta k fondu (30 = pol hodiny). Zmena platí od zvoleného mesiaca a nekopíruje sa " & _
        "po mesiacoch - platí, kým ju nezmeníte; staršie mesiace ostanú podľa predošlého nastavenia.", 8, False, RGB(90, 90, 90))

    Call mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnFkUloz", 300, 7080 + P, 3600, "&Uložiť od zvoleného mesiaca", "=Fk_UlozUI()", True)
    Set ctl = mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnFkZavri", 8500, 7080 + P, 1800, "&Zavrieť", "=Fk_ZavriUI()")
    ctl.Cancel = True
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "lblFkStav", 300, 7540 + P, 9900, 500, "", 9, False, RGB(0, 100, 0))

    strDiag = mod_UI_Spolocne.DlgUlozFormular(frm, strTmp, FRM_FOND)
    Call mod_00_Common.SetNastavenie(KLUC_VER_FOND, VERZIA_FOND, "Verzia okna pracovných fondov (frmFondKarta)")
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.VytvorFondKartu", "INFO", "Okno fondov vytvorené. " & strDiag)
    Exit Sub
Chyba:
    strE = Err.Description
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.VytvorFondKartu", "ERROR", strE)
    On Error Resume Next
    If Len(strTmp) > 0 Then DoCmd.Close acForm, strTmp, acSaveNo
    On Error GoTo 0
    Err.Raise vbObjectError + 711, "VytvorFondKartu", "Okno fondov sa nepodarilo vytvoriť: " & strE
End Sub

'-------------------------------------------------------------------------------
' Otvorí okno pracovných fondov; lFond = fond, ktorý sa má zobraziť (0 = prvý), iRok / iMes = mesiac platnosti.
'-------------------------------------------------------------------------------
Public Function OtvorEditorFondov(ByVal lFond As Long, ByVal iRok As Integer, ByVal iMes As Integer, Optional ByVal strOC As String = "") As Boolean
    On Error GoTo Chyba
    Dim frm As Form, strVL As String, bZam As Boolean
    If Not (mod_00_Common.FormularExistujeDB(FRM_FOND) And mod_00_Common.GetNastavenie(KLUC_VER_FOND, "") = VERZIA_FOND) Then Call VytvorFondKartu
    If mod_00_Common.FormIsOpen(FRM_FOND) Then DoCmd.Close acForm, FRM_FOND, acSaveNo
    Call mod_15_Zamestnanci.ZabezpecModel(CurrentDb)
    DoCmd.OpenForm FRM_FOND, acNormal
    Set frm = Forms(FRM_FOND)
    strVL = mod_15_Zamestnanci.ZoznamFondovVL(False)
    frm!cboFkFond.RowSource = strVL
    frm!cboFkFond.ColumnWidths = "0;4600"
    Call NastavVyberZamestnanca(frm!cboFkZam)
    frm!cboFkVerzia.ColumnWidths = "0;1800"
    Call NastavVyberPredvolby(frm!cboFkPredvolba, mod_17_FondyPravidla.ZoznamPredvolieFonduVL())
    If lFond <= 0 Then lFond = PrvyKod(strVL)
    frm!cboFkFond = lFond
    If iRok < 1990 Or iMes < 1 Then iRok = Year(Date): iMes = Month(Date)
    Call mod_UI_Spolocne.NastavVyberMesiaca(frm!cboFkMesiac, iRok, iMes)
    strOC = Trim$(strOC)
    If Len(strOC) > 0 Then
        If DCount("*", "Zamestnanci", "OsobneCislo = " & mod_00_Common.SqlText(strOC)) > 0 Then
            frm!cboFkZam = strOC
            bZam = True
        End If
    End If
    If bZam Then Call Fk_ZamVybranyUI Else Call Fk_FondZmenenyUI
    OtvorEditorFondov = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.OtvorEditorFondov", "ERROR", Err.Description)
    MsgBox "Okno fondov sa nepodarilo otvoriť: " & Err.Description, vbExclamation, "Pracovné fondy"
End Function

'-------------------------------------------------------------------------------
' Naplní okno fondu hodnotami zo slovníka d (kľúče ako pri NacitajFond; názov len ak je v slovníku).
'-------------------------------------------------------------------------------
Private Sub FondDoFormulara(ByVal frm As Form, ByVal d As Object)
    Dim n As Long
    If d.Exists("Nazov") Then frm!txtFkNazov = d("Nazov")
    frm!cboFkTyp = d("Typ")
    frm!txtFkDenny = mod_17_FondyPravidla.MinutyNaText(CLng(d("Denny")))
    frm!txtFkMesacny = mod_17_FondyPravidla.MinutyNaText(CLng(d("Mesacny")))
    frm!chkFkPodlaDna = CBool(d("PodlaDna"))
    For n = 1 To 7
        frm.Controls("txtFk" & n & "Od") = mod_17_FondyPravidla.MinutyNaText(CLng(d("D" & n & "Od")))
        frm.Controls("txtFk" & n & "Do") = mod_17_FondyPravidla.MinutyNaText(CLng(d("D" & n & "Do")))
        frm.Controls("txtFk" & n & "Fond") = mod_17_FondyPravidla.MinutyNaText(CLng(d("D" & n & "Fond")))
        frm.Controls("txtFk" & n & "Prest") = MinutyNaTextTrvania(CLng(d("D" & n & "Prest")), False)
    Next n
End Sub

'-------------------------------------------------------------------------------
' Načíta do okna fond a mesiac, ktoré sú vybrané v zoznamoch.
'-------------------------------------------------------------------------------
Public Function Fk_FondZmenenyUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, d As Object, lFond As Long, lRok As Long, lMes As Long, n As Long, nPouz As Long
    If Not mod_00_Common.FormIsOpen(FRM_FOND) Then Exit Function
    Set frm = Forms(FRM_FOND)
    lFond = ZoznamHodnota(frm!cboFkFond)
    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboFkMesiac, lRok, lMes) Then lRok = Year(Date): lMes = Month(Date)
    Set d = CreateObject("Scripting.Dictionary")
    nPouz = mod_17_FondyPravidla.PocetPouzivajucich("F", lFond)
    frm!btnFkKto.Caption = "Kto používa (" & nPouz & ")"
    frm!cboFkVerzia.RowSource = mod_17_FondyPravidla.ZoznamVerziiVL("F", lFond, 0)
    If mod_17_FondyPravidla.NacitajFond(lFond, CInt(lRok), CInt(lMes), d) Then
        Call FondDoFormulara(frm, d)
        frm!lblFkVerzia.Caption = "Zobrazená verzia fondu platná od " & d("VerziaMes") & "/" & d("VerziaRok") & "."
        On Error Resume Next
        frm!cboFkVerzia = CLng(d("VerziaRok")) * 100 + CLng(d("VerziaMes"))
        On Error GoTo Chyba
    Else
        frm!txtFkNazov = "Fond " & lFond
        frm!cboFkTyp = 2
        frm!txtFkDenny = "7:30"
        frm!txtFkMesacny = Null
        frm!chkFkPodlaDna = False
        For n = 1 To 7
            frm.Controls("txtFk" & n & "Od") = Null: frm.Controls("txtFk" & n & "Do") = Null
            frm.Controls("txtFk" & n & "Fond") = Null: frm.Controls("txtFk" & n & "Prest") = Null
        Next n
        frm!cboFkVerzia = Null
        frm!lblFkVerzia.Caption = "Fond nemá v číselníku žiadnu verziu - po uložení vznikne od zvoleného mesiaca."
    End If
    Call StavOkna(frm!lblFkStav, "", TextZamku(mod_18_Uzavierka.DotknutyFond(lFond, lRok, lMes)))
    Call Fk_PrepniUI
    Fk_FondZmenenyUI = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.Fk_FondZmenenyUI", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Povolí mesačný fond len pri type 4 a tabuľku dní len pri zaškrtnutej rôznej dĺžke podľa dňa.
'-------------------------------------------------------------------------------
Public Function Fk_PrepniUI() As Boolean
    On Error Resume Next
    Dim frm As Form, n As Long, bDni As Boolean
    Set frm = Forms(FRM_FOND)
    frm!txtFkMesacny.Enabled = (ZoznamHodnota(frm!cboFkTyp) = 4)
    bDni = CBool(Nz(frm!chkFkPodlaDna.Value, False))
    For n = 1 To 7
        frm.Controls("txtFk" & n & "Od").Enabled = bDni
        frm.Controls("txtFk" & n & "Do").Enabled = bDni
        frm.Controls("txtFk" & n & "Fond").Enabled = bDni
        frm.Controls("txtFk" & n & "Prest").Enabled = bDni
    Next n
    frm!btnFkKopia.Enabled = bDni
    Fk_PrepniUI = True
End Function

Public Function Fk_KopiaPondelokUI() As Boolean
    On Error Resume Next
    Dim frm As Form, n As Long
    Set frm = Forms(FRM_FOND)
    For n = 2 To 5
        frm.Controls("txtFk" & n & "Od") = frm.Controls("txtFk1Od").Value
        frm.Controls("txtFk" & n & "Do") = frm.Controls("txtFk1Do").Value
        frm.Controls("txtFk" & n & "Fond") = frm.Controls("txtFk1Fond").Value
        frm.Controls("txtFk" & n & "Prest") = frm.Controls("txtFk1Prest").Value
    Next n
    Call StavOkna(frm!lblFkStav, "Utorok až piatok vyplnené podľa pondelka (uložíte tlačidlom Uložiť).", "")
    Fk_KopiaPondelokUI = True
End Function

'-------------------------------------------------------------------------------
' Nový fond ako kópia zobrazeného fondu (všetky jeho verzie).
'-------------------------------------------------------------------------------
Public Function Fk_NovyUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, strNazov As String, lZdroj As Long, lNovy As Long, lPred As Long, lRok As Long, lMes As Long, odp As VbMsgBoxResult, strE As String
    Set frm = Forms(FRM_FOND)
    lZdroj = ZoznamHodnota(frm!cboFkFond)
    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboFkMesiac, lRok, lMes) Then lRok = Year(Date): lMes = Month(Date)
    odp = MsgBox("Nový fond vznikne:" & vbCrLf & vbCrLf & _
                 "Áno  = ako kópia zobrazeného fondu " & lZdroj & " (" & mod_15_Zamestnanci.NazovFondu(lZdroj) & ", aj s jeho históriou)" & vbCrLf & _
                 "Nie  = z predvoľby vybranej v zozname Predvoľba (jedna verzia platná od mesiaca " & lMes & "/" & lRok & ")", _
                 vbYesNoCancel + vbQuestion, "Nový pracovný fond")
    If odp = vbCancel Then Exit Function
    If odp = vbNo Then
        lPred = ZoznamHodnota(frm!cboFkPredvolba)
        If lPred <= 0 Then
            MsgBox "Najprv vyberte predvoľbu v zozname Predvoľba a znova stlačte Nový fond.", vbInformation, "Nový pracovný fond"
            Exit Function
        End If
    End If
    strNazov = Trim$(InputBox("Názov nového fondu.", "Nový pracovný fond", "Nový fond"))
    If Len(strNazov) = 0 Then Exit Function
    If odp = vbYes Then
        lNovy = mod_15_Zamestnanci.KopiaFondu(lZdroj, strNazov)
        If lNovy <= 0 Then strE = "Nový fond sa nepodarilo vytvoriť (pozrite protokol)."
    Else
        lNovy = mod_17_FondyPravidla.NovyFondZPredvolby(strNazov, lPred, CInt(lRok), CInt(lMes), strE)
    End If
    If lNovy <= 0 Then
        MsgBox strE, vbExclamation, "Pracovné fondy"
        Exit Function
    End If
    frm!cboFkFond.RowSource = mod_15_Zamestnanci.ZoznamFondovVL(False)
    frm!cboFkFond = lNovy
    frm!cboFkZam = Null
    frm!lblFkZam.Caption = ""
    Call Fk_FondZmenenyUI
    Call StavOkna(frm!lblFkStav, "Vytvorený nový fond č. " & lNovy & ". Upravte ho a priraďte zamestnancom na karte Zamestnanci.", "")
    Fk_NovyUI = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.Fk_NovyUI", "ERROR", Err.Description)
End Function

Public Function Fk_UlozUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, d As Object, lFond As Long, lRok As Long, lMes As Long, n As Long, lV As Long, strErr As String, strPole As String
    Dim bDni As Boolean

    Set frm = Forms(FRM_FOND)
    lFond = ZoznamHodnota(frm!cboFkFond)
    If lFond <= 0 Then MsgBox "Vyberte fond.", vbExclamation, "Pracovné fondy": Exit Function
    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboFkMesiac, lRok, lMes) Then
        MsgBox "Vyberte mesiac, od ktorého zmena platí.", vbExclamation, "Pracovné fondy"
        Exit Function
    End If

    Set d = CreateObject("Scripting.Dictionary")
    d("Nazov") = Trim$(CStr(Nz(frm!txtFkNazov.Value, "")))
    d("Typ") = ZoznamHodnota(frm!cboFkTyp)
    d("PodlaDna") = CBool(Nz(frm!chkFkPodlaDna.Value, False))
    bDni = CBool(d("PodlaDna"))

    lV = mod_17_FondyPravidla.TextNaMinuty(CStr(Nz(frm!txtFkDenny.Value, "")))
    If lV <= 0 Then MsgBox "Denný fond zadajte v tvare h:mm, napr. 7:30.", vbExclamation, "Pracovné fondy": Exit Function
    d("Denny") = lV
    lV = mod_17_FondyPravidla.TextNaMinuty(CStr(Nz(frm!txtFkMesacny.Value, "")))
    If lV < 0 Then MsgBox "Mesačný fond zadajte v tvare h:mm, napr. 165:00.", vbExclamation, "Pracovné fondy": Exit Function
    d("Mesacny") = lV

    For n = 1 To 7
        d("D" & n & "Od") = 0: d("D" & n & "Do") = 0: d("D" & n & "Fond") = 0: d("D" & n & "Prest") = 0
        If bDni Then
            strPole = "Od"
            lV = mod_17_FondyPravidla.TextNaMinuty(CStr(Nz(frm.Controls("txtFk" & n & "Od").Value, "")))
            If lV < 0 Then GoTo ChybaDna
            d("D" & n & "Od") = lV
            strPole = "Do"
            lV = mod_17_FondyPravidla.TextNaMinuty(CStr(Nz(frm.Controls("txtFk" & n & "Do").Value, "")))
            If lV < 0 Then GoTo ChybaDna
            d("D" & n & "Do") = lV
            strPole = "Fond"
            lV = mod_17_FondyPravidla.TextNaMinuty(CStr(Nz(frm.Controls("txtFk" & n & "Fond").Value, "")))
            If lV < 0 Then GoTo ChybaDna
            d("D" & n & "Fond") = lV
            strPole = "Prestávka"
            lV = MinutyZVstupu(CStr(Nz(frm.Controls("txtFk" & n & "Prest").Value, "")))
            If lV < 0 Then GoTo ChybaDna
            d("D" & n & "Prest") = lV
            If CLng(d("D" & n & "Do")) > 0 And CLng(d("D" & n & "Do")) <= CLng(d("D" & n & "Od")) Then
                MsgBox DenNazov(n) & ": Odchod do musí byť neskôr ako Príchod od.", vbExclamation, "Pracovné fondy"
                Exit Function
            End If
        End If
    Next n

    strErr = mod_17_FondyPravidla.UlozFond(lFond, CInt(lRok), CInt(lMes), d)
    If Len(strErr) > 0 Then
        MsgBox strErr, vbExclamation, "Pracovné fondy"
        Exit Function
    End If
    frm!cboFkFond.RowSource = mod_15_Zamestnanci.ZoznamFondovVL(False)
    Call Fk_FondZmenenyUI
    Call StavOkna(frm!lblFkStav, "Fond uložený od " & lMes & "/" & lRok & ". Prepočítajte mesiac na karte Výpočet.", "")
    Call mod_UI_Pomocnik.OznacCinnost("ZAMESTNANCI")
    Fk_UlozUI = True
    Exit Function
ChybaDna:
    MsgBox DenNazov(n) & " - pole " & strPole & ": zadajte čas v tvare h:mm (napr. 7:30), prestávku v minútach (napr. 30)." , vbExclamation, "Pracovné fondy"
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.Fk_UlozUI", "ERROR", Err.Description)
    MsgBox "Fond sa nepodarilo uložiť: " & Err.Description, vbExclamation, "Pracovné fondy"
End Function

'-------------------------------------------------------------------------------
' Zmena fondu v zozname: zamestnanec už nie je určujúci, preto sa jeho výber zruší.
'-------------------------------------------------------------------------------
Public Function Fk_FondVybranyUI() As Boolean
    On Error Resume Next
    Dim frm As Form
    Set frm = Forms(FRM_FOND)
    frm!cboFkZam = Null
    frm!lblFkZam.Caption = ""
    Fk_FondVybranyUI = Fk_FondZmenenyUI()
End Function

'-------------------------------------------------------------------------------
' Skok na zamestnanca: zobrazí sa fond, ktorý platí pre neho v zvolenom mesiaci.
'-------------------------------------------------------------------------------
Public Function Fk_ZamVybranyUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, strOC As String, lRok As Long, lMes As Long, iOdR As Integer, iOdM As Integer
    Dim f As Long, p As Long, k As Long, y As Long, lUv As Long, bVlastne As Boolean, strT As String
    If Not mod_00_Common.FormIsOpen(FRM_FOND) Then Exit Function
    Set frm = Forms(FRM_FOND)
    strOC = Trim$(CStr(Nz(frm!cboFkZam.Value, "")))
    If Len(strOC) = 0 Then
        frm!lblFkZam.Caption = ""
        Fk_ZamVybranyUI = Fk_FondZmenenyUI()
        Exit Function
    End If
    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboFkMesiac, lRok, lMes) Then lRok = Year(Date): lMes = Month(Date)
    bVlastne = mod_15_Zamestnanci.PlatnePriradenie(strOC, CInt(lRok), CInt(lMes), iOdR, iOdM, f, p, k, y, lUv)
    frm!cboFkFond = f
    If bVlastne Then
        strT = "Pre zamestnanca platí od " & iOdM & "/" & iOdR & " fond " & f & " (" & mod_15_Zamestnanci.NazovFondu(f) & ")"
        If lUv > 0 And lUv <> 100 Then strT = strT & ", úväzok " & lUv & " %"
        strT = strT & "."
    Else
        strT = "Zamestnanec nemá vlastné priradenie - platí základný fond 1."
    End If
    frm!lblFkZam.Caption = strT
    Fk_ZamVybranyUI = Fk_FondZmenenyUI()
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.Fk_ZamVybranyUI", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Zmena mesiaca: ak je vybraný zamestnanec, jeho priradenie sa vyhodnotí znova (v inom mesiaci môže platiť iný fond).
'-------------------------------------------------------------------------------
Public Function Fk_MesiacZmenenyUI() As Boolean
    On Error Resume Next
    Dim frm As Form
    Set frm = Forms(FRM_FOND)
    If Len(Trim$(CStr(Nz(frm!cboFkZam.Value, "")))) > 0 Then
        Fk_MesiacZmenenyUI = Fk_ZamVybranyUI()
    Else
        Fk_MesiacZmenenyUI = Fk_FondZmenenyUI()
    End If
End Function

'-------------------------------------------------------------------------------
' Výber verzie zo zoznamu verzií: nastaví sa mesiac verzie a zobrazia sa jej hodnoty.
'-------------------------------------------------------------------------------
Public Function Fk_VerziaVybranaUI() As Boolean
    On Error Resume Next
    Dim frm As Form
    Set frm = Forms(FRM_FOND)
    Call MesiacZVerzie(frm!cboFkMesiac, frm!cboFkVerzia)
    Fk_VerziaVybranaUI = Fk_MesiacZmenenyUI()
End Function

'-------------------------------------------------------------------------------
' Kto používa zobrazený fond (v zvolenom mesiaci a inokedy).
'-------------------------------------------------------------------------------
Public Function Fk_KtoUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, lFond As Long, lRok As Long, lMes As Long
    Set frm = Forms(FRM_FOND)
    lFond = ZoznamHodnota(frm!cboFkFond)
    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboFkMesiac, lRok, lMes) Then lRok = Year(Date): lMes = Month(Date)
    MsgBox mod_17_FondyPravidla.TextPouzivajucich("F", lFond, CInt(lRok), CInt(lMes)), vbInformation, "Kto používa fond " & lFond & " (" & mod_15_Zamestnanci.NazovFondu(lFond) & ")"
    Fk_KtoUI = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.Fk_KtoUI", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Vyplní okno hodnotami vybranej predvoľby (názov a platnosť sa nemenia; nič sa neukladá).
'-------------------------------------------------------------------------------
Public Function Fk_PredvolbaUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, d As Object, lKod As Long, lFond As Long, lRok As Long, lMes As Long
    Set frm = Forms(FRM_FOND)
    lKod = ZoznamHodnota(frm!cboFkPredvolba)
    If lKod <= 0 Then
        MsgBox "Vyberte predvoľbu v zozname Predvoľba.", vbInformation, "Pracovné fondy"
        Exit Function
    End If
    Set d = CreateObject("Scripting.Dictionary")
    If Not mod_17_FondyPravidla.PredvolbaFondu(lKod, d) Then Exit Function
    Call FondDoFormulara(frm, d)
    Call Fk_PrepniUI
    lFond = ZoznamHodnota(frm!cboFkFond)
    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboFkMesiac, lRok, lMes) Then lRok = Year(Date): lMes = Month(Date)
    Call StavOkna(frm!lblFkStav, "Predvoľba vyplnená, zatiaľ neuložená. Skontrolujte hodnoty a stlačte Uložiť od zvoleného mesiaca.", _
                  TextZamku(mod_18_Uzavierka.DotknutyFond(lFond, lRok, lMes)))
    Fk_PredvolbaUI = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.Fk_PredvolbaUI", "ERROR", Err.Description)
End Function

Public Function Fk_ZavriUI() As Boolean
    On Error Resume Next
    DoCmd.Close acForm, FRM_FOND, acSaveNo
    Fk_ZavriUI = True
End Function

Public Function Fk_PoZatvoreniUI() As Boolean
    On Error Resume Next
    Call mod_UI_Tab_Zamestnanci.Zam_ObnovUI
    Fk_PoZatvoreniUI = True
End Function

'===============================================================================
' PRAVIDLÁ PRERUŠENÍ
'===============================================================================

Private Sub VytvorPravidlaKartu()
    On Error GoTo Chyba
    Dim frm As Form, strTmp As String, ctl As Control, n As Long, lY As Long, strDiag As String, strE As String
    Const P As Long = 420      ' posun poloziek pod riadkami Zamestnanec a Platné od (oproti verzii 1.0)

    Call mod_UI_Spolocne.DlgZmazFormular(FRM_PRAV)
    Set frm = mod_UI_Spolocne.DlgNovyFormular("Pravidlá prerušení", 10400, 9920, strTmp, "=Pk_PoZatvoreniUI()")

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 100, 9800, 400, "Pravidlá prerušení (kontrola času prerušení)", 13, True, FARBA_NADPIS)

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 640, 1100, 300, "Šablóna:")
    Call mod_UI_Spolocne.DlgVyber(strTmp, "cboPkSablona", 1500, 600, 4600, "", "=Pk_SablonaVybranaUI()")
    Call mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnPkNova", 6250, 590, 1700, "Nová šablóna...", "=Pk_NovaUI()")
    Call mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnPkKto", 8100, 590, 2200, "Kto používa", "=Pk_KtoUI()")

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 1060, 1400, 300, "Zamestnanec:")
    Set ctl = mod_UI_Spolocne.DlgVyber(strTmp, "cboPkZam", 1700, 1020, 4400, "", "=Pk_ZamVybranyUI()")
    ctl.ControlTipText = "Vyberte zamestnanca - zobrazí sa šablóna pravidiel, ktorá pre neho platí v zvolenom mesiaci"
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "lblPkZam", 6250, 1000, 4050, 420, "", 8, False, RGB(100, 100, 100))

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 1480, 1100, 300, "Prerušenie:")
    Call mod_UI_Spolocne.DlgVyber(strTmp, "cboPkPreruseni", 1500, 1440, 4600, "", "=Pk_NacitajUI()")
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 6250, 1480, 1000, 300, "Predvoľba:")
    Set ctl = mod_UI_Spolocne.DlgVyber(strTmp, "cboPkPredvolba", 7250, 1440, 2250, "")
    ctl.ControlTipText = "Predvolené hodnoty pravidla - po výbere stlačte Použiť (nič sa neuloží, kým nestlačíte Uložiť)"
    Call mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnPkPredvolba", 9550, 1430, 750, "Použiť", "=Pk_PredvolbaUI()")

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 1900, 1900, 300, "Platné od mesiaca:")
    Call mod_UI_Spolocne.DlgVyber(strTmp, "cboPkMesiac", 2200, 1860, 2400, mod_UI_Spolocne.ZoznamMesiacovRowSource(), "=Pk_MesiacZmenenyUI()")
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 4750, 1900, 750, 300, "Verzie:")
    Set ctl = mod_UI_Spolocne.DlgVyber(strTmp, "cboPkVerzia", 5500, 1860, 1800, "", "=Pk_VerziaVybranaUI()")
    ctl.ControlTipText = "História pravidla: verzie platné od mesiaca. Výber verzie zobrazí jej hodnoty."
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "lblPkVerzia", 7450, 1880, 2850, 420, "", 8, False, RGB(100, 100, 100))

    Call mod_UI_Spolocne.DlgZaskrtavatko(strTmp, "chkPkAktivne", 300, 1950 + P)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 650, 1940 + P, 9500, 300, "Kontrolovať toto pravidlo (po vypnutí sa pre toto prerušenie nevytvárajú upozornenia)", 10, True, FARBA_NADPIS)

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 2440 + P, 3300, 300, "Povolený čas prerušenia od:")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtPkOd", 3700, 2400 + P, 900)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 4700, 2440 + P, 450, 300, "do:")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtPkDo", 5200, 2400 + P, 900)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 6250, 2440 + P, 4000, 300, "(h:mm; prázdne = bez obmedzenia)", 8, False, RGB(100, 100, 100))

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 2860 + P, 3300, 300, "Najdlhšie trvanie (min):")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtPkMax", 3700, 2820 + P, 900)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 4800, 2860 + P, 5400, 300, "(prázdne = bez obmedzenia)", 8, False, RGB(100, 100, 100))

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 3280 + P, 3300, 300, "Odpracovať pred začiatkom (min):")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtPkMinO", 3700, 3240 + P, 900)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 4800, 3280 + P, 5400, 300, "(napr. 180 = obed najskôr po 3 hodinách práce)", 8, False, RGB(100, 100, 100))

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 3700 + P, 3300, 300, "Najkratšie trvanie (min):")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtPkMinT", 3700, 3660 + P, 900)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 4800, 3700 + P, 5400, 300, "(prázdne = bez obmedzenia)", 8, False, RGB(100, 100, 100))

    Call mod_UI_Spolocne.DlgZaskrtavatko(strTmp, "chkPkRozne", 300, 4180 + P, "=Pk_PrepniUI()")
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 650, 4170 + P, 9500, 300, "Rôzny povolený čas a trvanie pre každý deň v týždni (inak platí hore uvedené pre všetky dni)")

    Call StitokStlpca(strTmp, 300, 4600 + P, 1550, "Deň")
    Call StitokStlpca(strTmp, 1900, 4600 + P, 1450, "Povolený od")
    Call StitokStlpca(strTmp, 3400, 4600 + P, 1450, "Povolený do")
    Call StitokStlpca(strTmp, 4900, 4600 + P, 1650, "Najdlhšie (min)")
    For n = 1 To 7
        lY = 4920 + P + (n - 1) * 360
        Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, lY + 20, 1550, 300, DenNazov(n))
        Call mod_UI_Spolocne.DlgPole(strTmp, "txtPk" & n & "Od", 1900, lY, 1450)
        Call mod_UI_Spolocne.DlgPole(strTmp, "txtPk" & n & "Do", 3400, lY, 1450)
        Call mod_UI_Spolocne.DlgPole(strTmp, "txtPk" & n & "Max", 4900, lY, 1650)
    Next n

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 7540 + P, 9900, 800, _
        "Príklad - obed: povolený čas 11:00 až 13:30, najdlhšie 30 min, odpracovať pred začiatkom 180 min. Ak zamestnanec odíde na obed " & _
        "o 10:40 alebo sa vráti o 13:50, v zozname anomálií (karta Kontrola, editor dňa) pribudne upozornenie. Výpočet sa tým nemení. " & _
        "Pravidlo platí od zvoleného mesiaca, kým ho nezmeníte (nekopíruje sa po mesiacoch). Celú kontrolu vypnete nastavením " & _
        "KontrolaPravidielPreruseni = 0.", 8, False, RGB(90, 90, 90))

    Call mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnPkUloz", 300, 8420 + P, 3600, "&Uložiť od zvoleného mesiaca", "=Pk_UlozUI()", True)
    Set ctl = mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnPkZavri", 8500, 8420 + P, 1800, "&Zavrieť", "=Pk_ZavriUI()")
    ctl.Cancel = True
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "lblPkStav", 300, 8880 + P, 9900, 500, "", 9, False, RGB(0, 100, 0))

    strDiag = mod_UI_Spolocne.DlgUlozFormular(frm, strTmp, FRM_PRAV)
    Call mod_00_Common.SetNastavenie(KLUC_VER_PRAV, VERZIA_PRAV, "Verzia okna pravidiel prerušení (frmPravidlaKarta)")
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.VytvorPravidlaKartu", "INFO", "Okno pravidiel prerušení vytvorené. " & strDiag)
    Exit Sub
Chyba:
    strE = Err.Description
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.VytvorPravidlaKartu", "ERROR", strE)
    On Error Resume Next
    If Len(strTmp) > 0 Then DoCmd.Close acForm, strTmp, acSaveNo
    On Error GoTo 0
    Err.Raise vbObjectError + 712, "VytvorPravidlaKartu", "Okno pravidiel prerušení sa nepodarilo vytvoriť: " & strE
End Sub

'-------------------------------------------------------------------------------
' Otvorí okno pravidiel prerušení; lSablona = šablóna, ktorá sa má zobraziť (0 = prvá), iRok / iMes = mesiac platnosti.
'-------------------------------------------------------------------------------
Public Function OtvorEditorPravidiel(ByVal lSablona As Long, ByVal iRok As Integer, ByVal iMes As Integer, Optional ByVal strOC As String = "") As Boolean
    On Error GoTo Chyba
    Dim frm As Form, strVL As String, bZam As Boolean
    If Not (mod_00_Common.FormularExistujeDB(FRM_PRAV) And mod_00_Common.GetNastavenie(KLUC_VER_PRAV, "") = VERZIA_PRAV) Then Call VytvorPravidlaKartu
    If mod_00_Common.FormIsOpen(FRM_PRAV) Then DoCmd.Close acForm, FRM_PRAV, acSaveNo
    Call mod_15_Zamestnanci.ZabezpecModel(CurrentDb)
    DoCmd.OpenForm FRM_PRAV, acNormal
    Set frm = Forms(FRM_PRAV)
    strVL = mod_15_Zamestnanci.ZoznamSablonVL(False)
    frm!cboPkSablona.RowSource = strVL
    frm!cboPkSablona.ColumnWidths = "0;4600"
    frm!cboPkPreruseni.ColumnWidths = "0;4600"
    Call NastavVyberZamestnanca(frm!cboPkZam)
    frm!cboPkVerzia.ColumnWidths = "0;1800"
    Call NastavVyberPredvolby(frm!cboPkPredvolba, mod_17_FondyPravidla.ZoznamPredvoliePravidielVL())
    If lSablona <= 0 Then lSablona = PrvyKod(strVL)
    frm!cboPkSablona = lSablona
    If iRok < 1990 Or iMes < 1 Then iRok = Year(Date): iMes = Month(Date)
    Call mod_UI_Spolocne.NastavVyberMesiaca(frm!cboPkMesiac, iRok, iMes)
    frm!cboPkPreruseni = Null
    strOC = Trim$(strOC)
    If Len(strOC) > 0 Then
        If DCount("*", "Zamestnanci", "OsobneCislo = " & mod_00_Common.SqlText(strOC)) > 0 Then
            frm!cboPkZam = strOC
            bZam = True
        End If
    End If
    If bZam Then Call Pk_ZamVybranyUI Else Call Pk_SablonaZmenenaUI
    OtvorEditorPravidiel = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.OtvorEditorPravidiel", "ERROR", Err.Description)
    MsgBox "Okno pravidiel prerušení sa nepodarilo otvoriť: " & Err.Description, vbExclamation, "Pravidlá prerušení"
End Function

'-------------------------------------------------------------------------------
' Po zmene šablóny: ponuka prerušení šablóny a načítanie pravidla (prvé prerušenie, ak žiadne nie je vybrané).
'-------------------------------------------------------------------------------
Public Function Pk_SablonaZmenenaUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, lSab As Long, strVL As String
    If Not mod_00_Common.FormIsOpen(FRM_PRAV) Then Exit Function
    Set frm = Forms(FRM_PRAV)
    lSab = ZoznamHodnota(frm!cboPkSablona)
    strVL = mod_17_FondyPravidla.ZoznamPreruseniSablonyVL(lSab)
    frm!cboPkPreruseni.RowSource = strVL
    frm!cboPkPreruseni.ColumnWidths = "0;4600"
    If ZoznamHodnota(frm!cboPkPreruseni) <= 0 Then frm!cboPkPreruseni = PrvyKod(strVL)
    frm!btnPkKto.Caption = "Kto používa (" & mod_17_FondyPravidla.PocetPouzivajucich("S", lSab) & ")"
    Pk_SablonaZmenenaUI = Pk_NacitajUI()
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.Pk_SablonaZmenenaUI", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Naplní okno pravidla hodnotami zo slovníka d (kľúče ako pri NacitajPravidlo).
'-------------------------------------------------------------------------------
Private Sub PravidloDoFormulara(ByVal frm As Form, ByVal d As Object)
    Dim n As Long
    frm!chkPkAktivne = CBool(d("Aktivne"))
    frm!txtPkOd = mod_17_FondyPravidla.MinutyNaText(CLng(d("IntOd")))
    frm!txtPkDo = mod_17_FondyPravidla.MinutyNaText(CLng(d("IntDo")))
    frm!txtPkMax = MinutyNaTextTrvania(CLng(d("Max")), True)
    frm!txtPkMinO = MinutyNaTextTrvania(CLng(d("MinO")), False)
    frm!txtPkMinT = MinutyNaTextTrvania(CLng(d("MinT")), False)
    frm!chkPkRozne = CBool(d("RozneDni"))
    For n = 1 To 7
        frm.Controls("txtPk" & n & "Od") = mod_17_FondyPravidla.MinutyNaText(CLng(d("D" & n & "Od")))
        frm.Controls("txtPk" & n & "Do") = mod_17_FondyPravidla.MinutyNaText(CLng(d("D" & n & "Do")))
        frm.Controls("txtPk" & n & "Max") = MinutyNaTextTrvania(CLng(d("D" & n & "Max")), True)
    Next n
End Sub

'-------------------------------------------------------------------------------
' Načíta pravidlo vybranej šablóny, prerušenia a mesiaca.
'-------------------------------------------------------------------------------
Public Function Pk_NacitajUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, d As Object, lSab As Long, lCis As Long, lRok As Long, lMes As Long, n As Long
    Dim lC0 As Long, bZaklad As Boolean, strZ As String
    If Not mod_00_Common.FormIsOpen(FRM_PRAV) Then Exit Function
    Set frm = Forms(FRM_PRAV)
    lSab = ZoznamHodnota(frm!cboPkSablona)
    lCis = ZoznamHodnota(frm!cboPkPreruseni)
    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboPkMesiac, lRok, lMes) Then lRok = Year(Date): lMes = Month(Date)
    Set d = CreateObject("Scripting.Dictionary")
    If lCis > 0 Then Call mod_17_FondyPravidla.NacitajPravidlo(lSab, lCis, CInt(lRok), CInt(lMes), d)
    If d.Count = 0 Then
        d("Existuje") = False: d("IntOd") = 0: d("IntDo") = 0: d("RozneDni") = False: d("Max") = 1440
        d("MinO") = 0: d("MinT") = 0: d("Aktivne") = True
        For n = 1 To 7
            d("D" & n & "Od") = 0: d("D" & n & "Do") = 0: d("D" & n & "Max") = 1440
        Next n
    End If
    Call PravidloDoFormulara(frm, d)
    frm!cboPkVerzia.RowSource = mod_17_FondyPravidla.ZoznamVerziiVL("S", lSab, lCis)
    If CBool(d("Existuje")) Then
        frm!lblPkVerzia.Caption = "Zobrazená verzia pravidla platná od " & d("VerziaMes") & "/" & d("VerziaRok") & "."
        On Error Resume Next
        frm!cboPkVerzia = CLng(d("VerziaRok")) * 100 + CLng(d("VerziaMes"))
        On Error GoTo Chyba
    Else
        frm!cboPkVerzia = Null
        frm!lblPkVerzia.Caption = "Pravidlo ešte nie je nastavené - po uložení vznikne od zvoleného mesiaca."
    End If
    strZ = ""
    If lSab > 0 And lCis > 0 Then
        lC0 = mod_18_Uzavierka.NajstarsiUzavretyMesiac("S", lSab)
        bZaklad = (lC0 > 0 And lC0 < CLng(lRok) * 12 + lMes)
        strZ = TextZamku(mod_18_Uzavierka.DotknutaSablona(lSab, lCis, lRok, lMes, bZaklad))
    End If
    Call StavOkna(frm!lblPkStav, "", strZ)
    Call Pk_PrepniUI
    Pk_NacitajUI = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.Pk_NacitajUI", "ERROR", Err.Description)
End Function

Public Function Pk_PrepniUI() As Boolean
    On Error Resume Next
    Dim frm As Form, n As Long, bDni As Boolean
    Set frm = Forms(FRM_PRAV)
    bDni = CBool(Nz(frm!chkPkRozne.Value, False))
    For n = 1 To 7
        frm.Controls("txtPk" & n & "Od").Enabled = bDni
        frm.Controls("txtPk" & n & "Do").Enabled = bDni
        frm.Controls("txtPk" & n & "Max").Enabled = bDni
    Next n
    frm!txtPkOd.Enabled = Not bDni
    frm!txtPkDo.Enabled = Not bDni
    frm!txtPkMax.Enabled = Not bDni
    Pk_PrepniUI = True
End Function

'-------------------------------------------------------------------------------
' Nová šablóna ako kópia zobrazenej šablóny (všetky jej pravidlá a verzie).
'-------------------------------------------------------------------------------
Public Function Pk_NovaUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, strNazov As String, lZdroj As Long, lNova As Long
    Set frm = Forms(FRM_PRAV)
    lZdroj = ZoznamHodnota(frm!cboPkSablona)
    strNazov = InputBox("Názov novej šablóny pravidiel prerušení." & vbCrLf & "Vznikne ako kópia šablóny " & lZdroj & " (" & _
                        mod_15_Zamestnanci.NazovSablony(lZdroj) & ").", "Nová šablóna prerušení", "Nová šablóna")
    strNazov = Trim$(strNazov)
    If Len(strNazov) = 0 Then Exit Function
    lNova = mod_15_Zamestnanci.KopiaSablony(lZdroj, strNazov)
    If lNova <= 0 Then
        MsgBox "Novú šablónu sa nepodarilo vytvoriť (pozrite protokol).", vbExclamation, "Pravidlá prerušení"
        Exit Function
    End If
    frm!cboPkSablona.RowSource = mod_15_Zamestnanci.ZoznamSablonVL(False)
    frm!cboPkSablona = lNova
    frm!cboPkZam = Null
    frm!lblPkZam.Caption = ""
    Call Pk_SablonaZmenenaUI
    Call StavOkna(frm!lblPkStav, "Vytvorená nová šablóna č. " & lNova & ". Upravte pravidlá a priraďte ju zamestnancom na karte Zamestnanci.", "")
    Pk_NovaUI = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.Pk_NovaUI", "ERROR", Err.Description)
End Function

Public Function Pk_UlozUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, d As Object, lSab As Long, lCis As Long, lRok As Long, lMes As Long, n As Long, lV As Long, strErr As String
    Dim strPole As String, bDni As Boolean, strNazPrer As String

    Set frm = Forms(FRM_PRAV)
    lSab = ZoznamHodnota(frm!cboPkSablona)
    lCis = ZoznamHodnota(frm!cboPkPreruseni)
    If lSab <= 0 Or lCis <= 0 Then MsgBox "Vyberte šablónu a prerušenie.", vbExclamation, "Pravidlá prerušení": Exit Function
    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboPkMesiac, lRok, lMes) Then
        MsgBox "Vyberte mesiac, od ktorého zmena platí.", vbExclamation, "Pravidlá prerušení"
        Exit Function
    End If

    Set d = CreateObject("Scripting.Dictionary")
    bDni = CBool(Nz(frm!chkPkRozne.Value, False))
    d("Nazov") = ""
    On Error Resume Next
    strNazPrer = CStr(Nz(frm!cboPkPreruseni.Column(1), ""))
    On Error GoTo Chyba
    If InStr(strNazPrer, " - ") > 0 Then strNazPrer = Mid$(strNazPrer, InStr(strNazPrer, " - ") + 3)
    d("Nazov") = strNazPrer
    d("Aktivne") = CBool(Nz(frm!chkPkAktivne.Value, False))
    d("RozneDni") = bDni

    strPole = "Povolený čas od"
    lV = mod_17_FondyPravidla.TextNaMinuty(CStr(Nz(frm!txtPkOd.Value, ""))): If lV < 0 Then GoTo ChybaPola
    d("IntOd") = lV
    strPole = "Povolený čas do"
    lV = mod_17_FondyPravidla.TextNaMinuty(CStr(Nz(frm!txtPkDo.Value, ""))): If lV < 0 Then GoTo ChybaPola
    d("IntDo") = lV
    strPole = "Najdlhšie trvanie"
    lV = MinutyZVstupu(CStr(Nz(frm!txtPkMax.Value, ""))): If lV < 0 Then GoTo ChybaPola
    d("Max") = IIf(lV = 0, 1440, lV)
    strPole = "Odpracovať pred začiatkom"
    lV = MinutyZVstupu(CStr(Nz(frm!txtPkMinO.Value, ""))): If lV < 0 Then GoTo ChybaPola
    d("MinO") = lV
    strPole = "Najkratšie trvanie"
    lV = MinutyZVstupu(CStr(Nz(frm!txtPkMinT.Value, ""))): If lV < 0 Then GoTo ChybaPola
    d("MinT") = lV

    For n = 1 To 7
        d("D" & n & "Od") = 0: d("D" & n & "Do") = 0: d("D" & n & "Max") = 1440
        If bDni Then
            strPole = DenNazov(n) & " - povolený od"
            lV = mod_17_FondyPravidla.TextNaMinuty(CStr(Nz(frm.Controls("txtPk" & n & "Od").Value, ""))): If lV < 0 Then GoTo ChybaPola
            d("D" & n & "Od") = lV
            strPole = DenNazov(n) & " - povolený do"
            lV = mod_17_FondyPravidla.TextNaMinuty(CStr(Nz(frm.Controls("txtPk" & n & "Do").Value, ""))): If lV < 0 Then GoTo ChybaPola
            d("D" & n & "Do") = lV
            strPole = DenNazov(n) & " - najdlhšie trvanie"
            lV = MinutyZVstupu(CStr(Nz(frm.Controls("txtPk" & n & "Max").Value, ""))): If lV < 0 Then GoTo ChybaPola
            d("D" & n & "Max") = IIf(lV = 0, 1440, lV)
        End If
    Next n

    strErr = mod_17_FondyPravidla.UlozPravidlo(lSab, lCis, CInt(lRok), CInt(lMes), d)
    If Len(strErr) > 0 Then
        MsgBox strErr, vbExclamation, "Pravidlá prerušení"
        Exit Function
    End If
    Call Pk_NacitajUI
    Call StavOkna(frm!lblPkStav, "Pravidlo uložené od " & lMes & "/" & lRok & ". Upozornenia sa vytvoria pri ďalšej analýze mesiaca (karta Kontrola).", "")
    Call mod_UI_Pomocnik.OznacCinnost("ZAMESTNANCI")
    Pk_UlozUI = True
    Exit Function
ChybaPola:
    MsgBox "Pole " & strPole & ": zadajte čas v tvare h:mm (napr. 11:00) alebo trvanie v minútach (napr. 30).", vbExclamation, "Pravidlá prerušení"
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.Pk_UlozUI", "ERROR", Err.Description)
    MsgBox "Pravidlo sa nepodarilo uložiť: " & Err.Description, vbExclamation, "Pravidlá prerušení"
End Function

'-------------------------------------------------------------------------------
' Zmena šablóny v zozname: zamestnanec už nie je určujúci, preto sa jeho výber zruší.
'-------------------------------------------------------------------------------
Public Function Pk_SablonaVybranaUI() As Boolean
    On Error Resume Next
    Dim frm As Form
    Set frm = Forms(FRM_PRAV)
    frm!cboPkZam = Null
    frm!lblPkZam.Caption = ""
    Pk_SablonaVybranaUI = Pk_SablonaZmenenaUI()
End Function

'-------------------------------------------------------------------------------
' Skok na zamestnanca: zobrazí sa šablóna pravidiel, ktorá platí pre neho v zvolenom mesiaci.
'-------------------------------------------------------------------------------
Public Function Pk_ZamVybranyUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, strOC As String, lRok As Long, lMes As Long, iOdR As Integer, iOdM As Integer
    Dim f As Long, p As Long, k As Long, y As Long, lUv As Long, bVlastne As Boolean, strT As String
    If Not mod_00_Common.FormIsOpen(FRM_PRAV) Then Exit Function
    Set frm = Forms(FRM_PRAV)
    strOC = Trim$(CStr(Nz(frm!cboPkZam.Value, "")))
    If Len(strOC) = 0 Then
        frm!lblPkZam.Caption = ""
        Pk_ZamVybranyUI = Pk_SablonaZmenenaUI()
        Exit Function
    End If
    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboPkMesiac, lRok, lMes) Then lRok = Year(Date): lMes = Month(Date)
    bVlastne = mod_15_Zamestnanci.PlatnePriradenie(strOC, CInt(lRok), CInt(lMes), iOdR, iOdM, f, p, k, y, lUv)
    frm!cboPkSablona = p
    If bVlastne Then
        strT = "Pre zamestnanca platí od " & iOdM & "/" & iOdR & " šablóna " & p & " (" & mod_15_Zamestnanci.NazovSablony(p) & ")."
    Else
        strT = "Zamestnanec nemá vlastné priradenie - platí základná šablóna 1."
    End If
    frm!lblPkZam.Caption = strT
    Pk_ZamVybranyUI = Pk_SablonaZmenenaUI()
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.Pk_ZamVybranyUI", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Zmena mesiaca: ak je vybraný zamestnanec, jeho priradenie sa vyhodnotí znova (v inom mesiaci môže platiť iná šablóna).
'-------------------------------------------------------------------------------
Public Function Pk_MesiacZmenenyUI() As Boolean
    On Error Resume Next
    Dim frm As Form
    Set frm = Forms(FRM_PRAV)
    If Len(Trim$(CStr(Nz(frm!cboPkZam.Value, "")))) > 0 Then
        Pk_MesiacZmenenyUI = Pk_ZamVybranyUI()
    Else
        Pk_MesiacZmenenyUI = Pk_NacitajUI()
    End If
End Function

'-------------------------------------------------------------------------------
' Výber verzie zo zoznamu verzií: nastaví sa mesiac verzie a zobrazia sa jej hodnoty.
'-------------------------------------------------------------------------------
Public Function Pk_VerziaVybranaUI() As Boolean
    On Error Resume Next
    Dim frm As Form
    Set frm = Forms(FRM_PRAV)
    Call MesiacZVerzie(frm!cboPkMesiac, frm!cboPkVerzia)
    Pk_VerziaVybranaUI = Pk_MesiacZmenenyUI()
End Function

'-------------------------------------------------------------------------------
' Kto používa zobrazenú šablónu (v zvolenom mesiaci a inokedy).
'-------------------------------------------------------------------------------
Public Function Pk_KtoUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, lSab As Long, lRok As Long, lMes As Long
    Set frm = Forms(FRM_PRAV)
    lSab = ZoznamHodnota(frm!cboPkSablona)
    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboPkMesiac, lRok, lMes) Then lRok = Year(Date): lMes = Month(Date)
    MsgBox mod_17_FondyPravidla.TextPouzivajucich("S", lSab, CInt(lRok), CInt(lMes)), vbInformation, _
           "Kto používa šablónu " & lSab & " (" & mod_15_Zamestnanci.NazovSablony(lSab) & ")"
    Pk_KtoUI = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.Pk_KtoUI", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Vyplní okno hodnotami vybranej predvoľby pre zobrazené prerušenie (nič sa neukladá).
'-------------------------------------------------------------------------------
Public Function Pk_PredvolbaUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, d As Object, lKod As Long, lSab As Long, lCis As Long, lRok As Long, lMes As Long
    Dim lC0 As Long, bZaklad As Boolean, strZ As String
    Set frm = Forms(FRM_PRAV)
    lKod = ZoznamHodnota(frm!cboPkPredvolba)
    lSab = ZoznamHodnota(frm!cboPkSablona)
    lCis = ZoznamHodnota(frm!cboPkPreruseni)
    If lKod <= 0 Then
        MsgBox "Vyberte predvoľbu v zozname Predvoľba.", vbInformation, "Pravidlá prerušení"
        Exit Function
    End If
    If lCis <= 0 Then
        MsgBox "Najprv vyberte prerušenie, pre ktoré chcete predvoľbu použiť.", vbInformation, "Pravidlá prerušení"
        Exit Function
    End If
    Set d = CreateObject("Scripting.Dictionary")
    If Not mod_17_FondyPravidla.PredvolbaPravidla(lKod, d) Then Exit Function
    Call PravidloDoFormulara(frm, d)
    Call Pk_PrepniUI
    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboPkMesiac, lRok, lMes) Then lRok = Year(Date): lMes = Month(Date)
    lC0 = mod_18_Uzavierka.NajstarsiUzavretyMesiac("S", lSab)
    bZaklad = (lC0 > 0 And lC0 < CLng(lRok) * 12 + lMes)
    strZ = TextZamku(mod_18_Uzavierka.DotknutaSablona(lSab, lCis, lRok, lMes, bZaklad))
    Call StavOkna(frm!lblPkStav, "Predvoľba vyplnená, zatiaľ neuložená. Skontrolujte hodnoty a stlačte Uložiť od zvoleného mesiaca.", strZ)
    Pk_PredvolbaUI = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Sablony.Pk_PredvolbaUI", "ERROR", Err.Description)
End Function

Public Function Pk_ZavriUI() As Boolean
    On Error Resume Next
    DoCmd.Close acForm, FRM_PRAV, acSaveNo
    Pk_ZavriUI = True
End Function

Public Function Pk_PoZatvoreniUI() As Boolean
    On Error Resume Next
    Call mod_UI_Tab_Zamestnanci.Zam_ObnovUI
    Pk_PoZatvoreniUI = True
End Function
