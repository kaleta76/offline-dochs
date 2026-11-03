Attribute VB_Name = "mod_UI_ZamKarta"
'@Verzia 1.1.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_UI_ZamKarta
' POPIS: Dialógové okná ručnej správy zamestnancov:
'        - frmZamestnanec  : karta zamestnanca (podľa Ordata): osobné číslo, meno, karta, organizácia, stredisko, text na
'                            displeji, úväzok v %, vyradenie od dňa, poznámka a nastavenia dochádzky platné od mesiaca
'                            (pracovný fond, šablóna pravidiel prerušení, kalendár),
'        - frmZamPriradenie: hromadné priradenie fondu, pravidiel, kalendára a úväzku viacerým zamestnancom, voliteľne ako
'                            nová skupina (vlastná kópia fondu a pravidiel prerušení).
'        Okná sa generujú programovo pri prvom použití (a po zmene verzie okna).
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - OtvorKartuZamestnanca(oc, novy)  : Otvorí kartu zamestnanca (alebo prázdnu kartu nového).
' - OtvorPriradenie(zoznamOC, skupina) : Otvorí okno hromadného priradenia.
' - Zk_UlozUI / Zk_MesiacZmenenyUI / Zk_VyradenyZmenenyUI / Zk_FondUI / Zk_PravidlaUI / Zk_VlastneUI / Zk_ZavriUI / Zk_PoZatvoreniUI
' - Zp_PouzitUI / Zp_SkupinaZmenenaUI / Zp_ZavriUI / Zp_PoZatvoreniUI
'===============================================================================

Private Const FRM_KARTA As String = "frmZamestnanec"
Private Const FRM_PRIR As String = "frmZamPriradenie"
Private Const VERZIA_KARTY As String = "1.1"
Private Const VERZIA_PRIR As String = "1.0"
Private Const KLUC_VER_KARTY As String = "ZamKartaFormVerzia"
Private Const KLUC_VER_PRIR As String = "ZamPriradenieFormVerzia"
Private Const FRM_KONZOLA As String = "frmHlavnaKonzola"
Private Const FARBA_NADPIS As Long = 5905935         ' RGB(15, 30, 90)

'===============================================================================
' KARTA ZAMESTNANCA
'===============================================================================

Private Sub VytvorKartu()
    On Error GoTo Chyba
    Dim frm As Form, strTmp As String, ctl As Control, strDiag As String, strE As String

    Call mod_UI_Spolocne.DlgZmazFormular(FRM_KARTA)
    Set frm = mod_UI_Spolocne.DlgNovyFormular("Karta zamestnanca", 9900, 7600, strTmp, "=Zk_PoZatvoreniUI()")

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "lblZkTitul", 300, 100, 9300, 400, "Karta zamestnanca", 13, True, FARBA_NADPIS)

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 740, 1800, 300, "Osobné číslo:")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtZkOC", 2150, 700, 1900)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 4900, 740, 1600, 300, "Číslo karty:")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtZkKarta", 6550, 700, 1500)

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 1160, 1800, 300, "Titul:")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtZkTitul", 2150, 1120, 1900)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 4900, 1160, 1600, 300, "Priezvisko:")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtZkPriezvisko", 6550, 1120, 3000)

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 1580, 1800, 300, "Meno:")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtZkMeno", 2150, 1540, 2600)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 4900, 1580, 1600, 300, "Text na displeji:")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtZkDisplej", 6550, 1540, 3000)

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 2000, 1800, 300, "Organizácia:")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtZkOrg", 2150, 1960, 2600)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 4900, 2000, 1600, 300, "Stredisko:")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtZkStred", 6550, 1960, 3000)

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 2420, 1800, 300, "Úväzok (%):")
    Set ctl = mod_UI_Spolocne.DlgPole(strTmp, "txtZkUvazok", 2150, 2380, 900)
    ctl.ControlTipText = "100 = plný úväzok, 50 = polovičný. Denný fond zamestnanca = denný fond x úväzok. Platí od mesiaca zvoleného v časti Nastavenia dochádzky (nemení sa spätne)."
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 3150, 2420, 3350, 300, "(50 = polovičný; platí od mesiaca nižšie)", 8, False, RGB(100, 100, 100))
    Call mod_UI_Spolocne.DlgZaskrtavatko(strTmp, "chkZkBlok", 6550, 2420)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 6900, 2410, 2600, 300, "Karta blokovaná")

    Call mod_UI_Spolocne.DlgZaskrtavatko(strTmp, "chkZkVyradeny", 300, 2850, "=Zk_VyradenyZmenenyUI()")
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 650, 2840, 4200, 300, "Vyradený (mimo výpočtov a zostáv)")
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 4900, 2840, 1600, 300, "Vyradený od:")
    Set ctl = mod_UI_Spolocne.DlgPole(strTmp, "txtZkVyradenyOd", 6550, 2800, 1500)
    ctl.ControlTipText = "Dátum, od ktorého je zamestnanec vyradený (napr. 1.12.2026)"

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 3260, 1800, 300, "Poznámka:")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtZkPozn", 2150, 3220, 7400)

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 3800, 9300, 300, "Nastavenia dochádzky zamestnanca (platné od zvoleného mesiaca): fond, pravidlá, kalendár, úväzok", 10, True, FARBA_NADPIS)

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 4220, 1800, 300, "Platné od mesiaca:")
    Call mod_UI_Spolocne.DlgVyber(strTmp, "cboZkMesiac", 2150, 4180, 2400, mod_UI_Spolocne.ZoznamMesiacovRowSource(), "=Zk_MesiacZmenenyUI()")
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 4640, 1800, 300, "Pracovný fond:")
    Call mod_UI_Spolocne.DlgVyber(strTmp, "cboZkFond", 2150, 4600, 5000, "")
    Call mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnZkFond", 7300, 4590, 2250, "Upraviť fond...", "=Zk_FondUI()")
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 5060, 1800, 300, "Šablóna prerušení:")
    Call mod_UI_Spolocne.DlgVyber(strTmp, "cboZkSablona", 2150, 5020, 5000, "")
    Call mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnZkPravidla", 7300, 5010, 2250, "Upraviť pravidlá...", "=Zk_PravidlaUI()")
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 5480, 1800, 300, "Kalendár:")
    Call mod_UI_Spolocne.DlgVyber(strTmp, "cboZkKalendar", 2150, 5440, 5000, "")

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 5900, 9300, 620, _
        "Nastavenia (fond, pravidlá, kalendár aj úväzok) platia od zvoleného mesiaca až do ďalšej zmeny - nekopírujú sa po mesiacoch; " & _
        "staršie mesiace ostanú podľa predošlého nastavenia a mesiac uzavretý po podpise zostavy sa nezmení. Fond a pravidlá sú spoločné " & _
        "pre všetkých, ktorí ich majú priradené - pre vlastný fond alebo pravidlá len tohto zamestnanca použite Vlastný fond a pravidlá.", 8, False, RGB(90, 90, 90))

    Set ctl = mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnZkUloz", 300, 6650, 1800, "&Uložiť", "=Zk_UlozUI()", True)
    ctl.Default = True
    Call mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnZkVlastne", 2250, 6650, 3400, "&Vlastný fond a pravidlá...", "=Zk_VlastneUI()")
    Set ctl = mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnZkZavri", 7750, 6650, 1800, "&Zavrieť", "=Zk_ZavriUI()")
    ctl.Cancel = True
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "lblZkStav", 300, 7150, 9300, 300, "", 9, False, RGB(0, 100, 0))

    strDiag = mod_UI_Spolocne.DlgUlozFormular(frm, strTmp, FRM_KARTA)
    Call mod_00_Common.SetNastavenie(KLUC_VER_KARTY, VERZIA_KARTY, "Verzia okna karty zamestnanca (frmZamestnanec)")
    Call mod_00_Common.ZapisLog("mod_UI_ZamKarta.VytvorKartu", "INFO", "Okno karty zamestnanca vytvorené. " & strDiag)
    Exit Sub
Chyba:
    strE = Err.Description
    Call mod_00_Common.ZapisLog("mod_UI_ZamKarta.VytvorKartu", "ERROR", strE)
    On Error Resume Next
    If Len(strTmp) > 0 Then DoCmd.Close acForm, strTmp, acSaveNo
    On Error GoTo 0
    Err.Raise vbObjectError + 701, "VytvorKartu", "Okno karty zamestnanca sa nepodarilo vytvoriť: " & strE
End Sub

Private Function KartaAktualna() As Boolean
    KartaAktualna = mod_00_Common.FormularExistujeDB(FRM_KARTA) And (mod_00_Common.GetNastavenie(KLUC_VER_KARTY, "") = VERZIA_KARTY)
End Function

'-------------------------------------------------------------------------------
' Otvorí kartu zamestnanca. strOC = osobné číslo; bNovy = prázdna karta nového zamestnanca.
'-------------------------------------------------------------------------------
Public Function OtvorKartuZamestnanca(ByVal strOC As String, ByVal bNovy As Boolean) As Boolean
    On Error GoTo Chyba
    Dim frm As Form
    If Not KartaAktualna() Then Call VytvorKartu
    If mod_00_Common.FormIsOpen(FRM_KARTA) Then DoCmd.Close acForm, FRM_KARTA, acSaveNo
    Call mod_UI_Spolocne.TVSet("ZK_Novy", IIf(bNovy, 1, 0))
    DoCmd.OpenForm FRM_KARTA, acNormal
    Set frm = Forms(FRM_KARTA)
    Call NaplnKartu(frm, strOC, bNovy)
    OtvorKartuZamestnanca = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_ZamKarta.OtvorKartuZamestnanca", "ERROR", Err.Description)
    MsgBox "Kartu zamestnanca sa nepodarilo otvoriť: " & Err.Description, vbExclamation, "Zamestnanci"
End Function

Private Function PoleText(ByRef rs As DAO.Recordset, ByVal strPole As String) As String
    On Error Resume Next
    PoleText = CStr(Nz(rs.Fields(strPole).Value, ""))
    If Err.Number <> 0 Then PoleText = "": Err.Clear
End Function

Private Sub NaplnKartu(ByVal frm As Form, ByVal strOC As String, ByVal bNovy As Boolean)
    On Error GoTo Chyba
    Dim rs As DAO.Recordset, lRok As Long, lMes As Long, v As Variant

    frm!cboZkFond.RowSource = mod_15_Zamestnanci.ZoznamFondovVL(False)
    frm!cboZkSablona.RowSource = mod_15_Zamestnanci.ZoznamSablonVL(False)
    frm!cboZkKalendar.RowSource = mod_15_Zamestnanci.ZoznamKalendarovVL(False)
    frm!cboZkFond.ColumnWidths = "0;5000"
    frm!cboZkSablona.ColumnWidths = "0;5000"
    frm!cboZkKalendar.ColumnWidths = "0;5000"

    If bNovy Then
        frm!lblZkTitul.Caption = "Nový zamestnanec"
        frm!txtZkOC = Null: frm!txtZkOC.Locked = False
        frm!txtZkKarta = 0
        frm!txtZkTitul = Null: frm!txtZkPriezvisko = Null: frm!txtZkMeno = Null: frm!txtZkDisplej = Null
        frm!txtZkOrg = Null: frm!txtZkStred = Null: frm!txtZkPozn = Null
        frm!txtZkUvazok = 100
        frm!chkZkBlok = False: frm!chkZkVyradeny = False: frm!txtZkVyradenyOd = Null
        frm!btnZkVlastne.Enabled = False
    Else
        Set rs = CurrentDb.OpenRecordset("SELECT * FROM Zamestnanci WHERE OsobneCislo = " & mod_00_Common.SqlText(strOC) & ";", dbOpenSnapshot)
        If rs.EOF Then
            rs.Close
            MsgBox "Zamestnanec " & strOC & " sa nenašiel.", vbExclamation, "Zamestnanci"
            DoCmd.Close acForm, FRM_KARTA, acSaveNo
            Exit Sub
        End If
        frm!lblZkTitul.Caption = "Karta zamestnanca " & strOC
        frm!txtZkOC = strOC: frm!txtZkOC.Locked = True
        frm!txtZkKarta = CLng(Val(PoleText(rs, "CisloKarty")))
        frm!txtZkTitul = PoleText(rs, "Titul")
        frm!txtZkPriezvisko = PoleText(rs, "Priezvisko")
        frm!txtZkMeno = PoleText(rs, "Meno")
        frm!txtZkDisplej = PoleText(rs, "TextDisplej")
        frm!txtZkOrg = PoleText(rs, "Organizacia")
        frm!txtZkStred = PoleText(rs, "StrediskoNazov")
        frm!txtZkPozn = PoleText(rs, "Poznamka")
        v = 100
        On Error Resume Next
        If Not IsNull(rs.Fields("UvazokPercent").Value) Then v = rs.Fields("UvazokPercent").Value
        frm!chkZkBlok = CBool(Nz(rs.Fields("BlokovanyStary").Value, False))
        frm!chkZkVyradeny = CBool(Nz(rs.Fields("Vyradeny").Value, False))
        If IsNull(rs.Fields("VyradenyOd").Value) Then frm!txtZkVyradenyOd = Null Else frm!txtZkVyradenyOd = Format$(rs.Fields("VyradenyOd").Value, "d.m.yyyy")
        Err.Clear
        On Error GoTo Chyba
        frm!txtZkUvazok = v
        frm!btnZkVlastne.Enabled = True
        rs.Close
    End If
    frm!lblZkStav.Caption = ""

    Call mod_UI_Tab_Zamestnanci.Zam_ZvolenyMesiac(lRok, lMes)
    Call mod_UI_Spolocne.NastavVyberMesiaca(frm!cboZkMesiac, lRok, lMes)
    Call Zk_MesiacZmenenyUI
    If bNovy Then
        On Error Resume Next
        frm!cboZkFond = 1: frm!cboZkSablona = 1: frm!cboZkKalendar = 1
        frm!txtZkOC.SetFocus
    End If
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_ZamKarta.NaplnKartu", "ERROR", Err.Description, "OC=" & strOC)
    MsgBox "Údaje zamestnanca sa nepodarilo načítať: " & Err.Description, vbExclamation, "Zamestnanci"
End Sub

'-------------------------------------------------------------------------------
' Po zmene mesiaca platnosti: ukáže fond, šablónu a kalendár platné pre zamestnanca v tomto mesiaci.
'-------------------------------------------------------------------------------
Public Function Zk_MesiacZmenenyUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, lRok As Long, lMes As Long, iOvRok As Integer, iOvMes As Integer, f As Long, p As Long, k As Long, y As Long, strOC As String
    If Not mod_00_Common.FormIsOpen(FRM_KARTA) Then Exit Function
    Set frm = Forms(FRM_KARTA)
    strOC = Trim$(CStr(Nz(frm!txtZkOC.Value, "")))
    If Len(strOC) = 0 Then Exit Function
    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboZkMesiac, lRok, lMes) Then Exit Function
    If mod_15_Zamestnanci.PlatnePriradenie(strOC, CInt(lRok), CInt(lMes), iOvRok, iOvMes, f, p, k, y) Then
        frm!cboZkFond = f: frm!cboZkSablona = p: frm!cboZkKalendar = k
        frm!lblZkStav.Caption = "Platné nastavenie sa začalo " & iOvMes & "/" & iOvRok & "."
    Else
        frm!cboZkFond = 1: frm!cboZkSablona = 1: frm!cboZkKalendar = 1
        frm!lblZkStav.Caption = "Zamestnanec nemá vlastné priradenie - používa sa fond 1, šablóna 1, kalendár 1."
    End If
    ' úväzok platný v zvolenom mesiaci (nový zamestnanec má úväzok, ktorý práve zadáva)
    If CLng(mod_UI_Spolocne.TVGet("ZK_Novy", 0)) = 0 Then
        frm!txtZkUvazok = mod_15_Zamestnanci.UvazokZamestnanca(CurrentDb, strOC, CInt(lRok), CInt(lMes))
    End If
    If mod_18_Uzavierka.JeUzavrety(strOC, CInt(lRok), CInt(lMes)) Then
        frm!lblZkStav.Caption = frm!lblZkStav.Caption & " MESIAC JE UZAVRETÝ (podpísaná zostava) - zmena nastavení by ho zasiahla."
    End If
    Zk_MesiacZmenenyUI = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_ZamKarta.Zk_MesiacZmenenyUI", "ERROR", Err.Description)
End Function

Public Function Zk_VyradenyZmenenyUI() As Boolean
    On Error Resume Next
    Dim frm As Form
    Set frm = Forms(FRM_KARTA)
    If CBool(Nz(frm!chkZkVyradeny.Value, False)) Then
        If Len(Trim$(CStr(Nz(frm!txtZkVyradenyOd.Value, "")))) = 0 Then frm!txtZkVyradenyOd = Format$(DateSerial(Year(Date), Month(Date) + 1, 1), "d.m.yyyy")
    Else
        frm!txtZkVyradenyOd = Null
    End If
    Zk_VyradenyZmenenyUI = True
End Function

Private Function ZoznamHodnota(ByVal ctl As Control) As Long
    On Error Resume Next
    ZoznamHodnota = CLng(Val(CStr(Nz(ctl.Value, 0))))
End Function

Public Function Zk_UlozUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, d As Object, strErr As String, bNovy As Boolean, strOC As String, lRok As Long, lMes As Long
    Dim iOvRok As Integer, iOvMes As Integer, f As Long, p As Long, k As Long, y As Long
    Dim nf As Long, np As Long, nk As Long, bMa As Boolean, strInfo As String, ym As Long
    Dim lUvNovy As Long, lUvStary As Long, bZmenaPrir As Boolean

    If Not mod_00_Common.FormIsOpen(FRM_KARTA) Then Exit Function
    Set frm = Forms(FRM_KARTA)
    bNovy = (CLng(mod_UI_Spolocne.TVGet("ZK_Novy", 0)) = 1)
    strOC = Trim$(CStr(Nz(frm!txtZkOC.Value, "")))
    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboZkMesiac, lRok, lMes) Then
        MsgBox "Vyberte mesiac, od ktorého nastavenia platia.", vbExclamation, "Zamestnanci"
        Exit Function
    End If
    nf = ZoznamHodnota(frm!cboZkFond): np = ZoznamHodnota(frm!cboZkSablona): nk = ZoznamHodnota(frm!cboZkKalendar)

    Set d = CreateObject("Scripting.Dictionary")
    d("OC") = strOC
    d("Titul") = frm!txtZkTitul.Value
    d("Meno") = frm!txtZkMeno.Value
    d("Priezvisko") = frm!txtZkPriezvisko.Value
    d("Karta") = frm!txtZkKarta.Value
    d("Org") = frm!txtZkOrg.Value
    d("Stred") = frm!txtZkStred.Value
    d("Displej") = frm!txtZkDisplej.Value
    d("Blok") = CBool(Nz(frm!chkZkBlok.Value, False))
    d("Vyradeny") = CBool(Nz(frm!chkZkVyradeny.Value, False))
    d("VyradenyOd") = Trim$(CStr(Nz(frm!txtZkVyradenyOd.Value, "")))
    d("Uvazok") = frm!txtZkUvazok.Value
    d("Poznamka") = frm!txtZkPozn.Value

    If Not IsNull(frm!txtZkUvazok.Value) Then
        If Not IsNumeric(frm!txtZkUvazok.Value) Then
            MsgBox "Úväzok zadajte číslom v percentách (napr. 100 alebo 50).", vbExclamation, "Zamestnanci"
            Exit Function
        End If
    End If
    If CBool(d("Vyradeny")) And Not IsDate(d("VyradenyOd")) Then
        MsgBox "Pri vyradení zadajte dátum v tvare 1.12.2026.", vbExclamation, "Zamestnanci"
        Exit Function
    End If
    If nf <= 0 Or np <= 0 Or nk <= 0 Then
        MsgBox "Vyberte pracovný fond, šablónu prerušení aj kalendár.", vbExclamation, "Zamestnanci"
        Exit Function
    End If
    lUvNovy = CLng(Val(CStr(Nz(frm!txtZkUvazok.Value, 100))))
    If lUvNovy < 1 Or lUvNovy > 200 Then
        MsgBox "Úväzok zadajte v percentách (1 až 200), napr. 100 alebo 50.", vbExclamation, "Zamestnanci"
        Exit Function
    End If

    ' Zamestnanec, ktorý už existuje: najprv priradenie (platné od zvoleného mesiaca) - pri zmene úväzku alebo nastavení vznikne
    ' verzia od tohto mesiaca (a pri zamestnancovi bez priradenia aj základná verzia pre staršie mesiace), takže uzavreté
    ' mesiace ostanú nedotknuté. Nový zamestnanec sa najprv založí a priradenie sa zapíše potom.
    bMa = mod_15_Zamestnanci.PlatnePriradenie(strOC, CInt(lRok), CInt(lMes), iOvRok, iOvMes, f, p, k, y)
    lUvStary = mod_15_Zamestnanci.UvazokZamestnanca(CurrentDb, strOC, CInt(lRok), CInt(lMes))
    If bMa Then
        bZmenaPrir = (f <> nf Or p <> np Or k <> nk Or lUvStary <> lUvNovy)
    Else
        bZmenaPrir = (nf <> 1 Or np <> 1 Or nk <> 1 Or lUvStary <> lUvNovy)
    End If
    If bNovy Then bZmenaPrir = True

    If Not bNovy And bZmenaPrir Then
        strErr = mod_15_Zamestnanci.UlozPriradenie(strOC, CInt(lRok), CInt(lMes), nf, np, nk, IIf(bMa, y, 1), lUvNovy)
        If Len(strErr) > 0 Then
            MsgBox strErr, vbExclamation, "Zamestnanci"
            Exit Function
        End If
    End If

    strErr = mod_15_Zamestnanci.UlozZamestnanca(d, bNovy)
    If Len(strErr) > 0 Then
        If Not bNovy And bZmenaPrir Then strErr = strErr & vbCrLf & vbCrLf & "Nastavenia dochádzky (fond, pravidlá, kalendár, úväzok) od mesiaca " & lMes & "/" & lRok & " už boli uložené."
        MsgBox strErr, vbExclamation, "Zamestnanci"
        Exit Function
    End If

    If bNovy And bZmenaPrir Then
        strErr = mod_15_Zamestnanci.UlozPriradenie(strOC, CInt(lRok), CInt(lMes), nf, np, nk, 1, lUvNovy)
        If Len(strErr) > 0 Then
            MsgBox strErr, vbExclamation, "Zamestnanci"
            Exit Function
        End If
    End If
    If bZmenaPrir Then
        ym = lRok * 12 + lMes
        If Nz(DCount("*", "ZamestnanciFondy", "OsobneCislo = " & mod_00_Common.SqlText(strOC) & " AND (Rok * 12 + Mesiac) > " & ym), 0) > 0 Then
            strInfo = " Pozor: existuje aj novšie nastavenie tohto zamestnanca, ktoré platí od neskoršieho mesiaca."
        End If
    End If

    Call mod_UI_Pomocnik.OznacCinnost("ZAMESTNANCI")
    Call mod_UI_Spolocne.TVSet("ZK_Novy", 0)
    frm!txtZkOC.Locked = True
    frm!lblZkTitul.Caption = "Karta zamestnanca " & strOC
    frm!btnZkVlastne.Enabled = True
    frm!lblZkStav.Caption = "Uložené." & strInfo
    Call mod_UI_Tab_Zamestnanci.Zam_ObnovUI
    Zk_UlozUI = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_ZamKarta.Zk_UlozUI", "ERROR", Err.Description)
    MsgBox "Zamestnanca sa nepodarilo uložiť: " & Err.Description, vbExclamation, "Zamestnanci"
End Function

Public Function Zk_FondUI() As Boolean
    On Error GoTo Chyba
    Dim lRok As Long, lMes As Long
    If Not mod_UI_Spolocne.ObdobieZVyberu(Forms(FRM_KARTA)!cboZkMesiac, lRok, lMes) Then lRok = Year(Date): lMes = Month(Date)
    Zk_FondUI = mod_UI_Sablony.OtvorEditorFondov(ZoznamHodnota(Forms(FRM_KARTA)!cboZkFond), CInt(lRok), CInt(lMes))
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_ZamKarta.Zk_FondUI", "ERROR", Err.Description)
End Function

Public Function Zk_PravidlaUI() As Boolean
    On Error GoTo Chyba
    Dim lRok As Long, lMes As Long
    If Not mod_UI_Spolocne.ObdobieZVyberu(Forms(FRM_KARTA)!cboZkMesiac, lRok, lMes) Then lRok = Year(Date): lMes = Month(Date)
    Zk_PravidlaUI = mod_UI_Sablony.OtvorEditorPravidiel(ZoznamHodnota(Forms(FRM_KARTA)!cboZkSablona), CInt(lRok), CInt(lMes))
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_ZamKarta.Zk_PravidlaUI", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Otvorí hromadné priradenie pre tohto zamestnanca s predvolenou voľbou "nová skupina" (vlastný fond a pravidlá).
'-------------------------------------------------------------------------------
Public Function Zk_VlastneUI() As Boolean
    On Error GoTo Chyba
    Dim strOC As String
    strOC = Trim$(CStr(Nz(Forms(FRM_KARTA)!txtZkOC.Value, "")))
    If Len(strOC) = 0 Then Exit Function
    Zk_VlastneUI = OtvorPriradenie(Array(strOC), True)
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_ZamKarta.Zk_VlastneUI", "ERROR", Err.Description)
End Function

Public Function Zk_ZavriUI() As Boolean
    On Error Resume Next
    DoCmd.Close acForm, FRM_KARTA, acSaveNo
    Zk_ZavriUI = True
End Function

Public Function Zk_PoZatvoreniUI() As Boolean
    On Error Resume Next
    Call mod_UI_Tab_Zamestnanci.Zam_ObnovUI
    Zk_PoZatvoreniUI = True
End Function

'===============================================================================
' HROMADNÉ PRIRADENIE
'===============================================================================

Private Sub VytvorPriradenie()
    On Error GoTo Chyba
    Dim frm As Form, strTmp As String, ctl As Control, strDiag As String, strE As String

    Call mod_UI_Spolocne.DlgZmazFormular(FRM_PRIR)
    Set frm = mod_UI_Spolocne.DlgNovyFormular("Priradenie nastavení zamestnancom", 8400, 7000, strTmp, "=Zp_PoZatvoreniUI()")

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 100, 7800, 400, "Priradiť nastavenia označeným zamestnancom", 13, True, FARBA_NADPIS)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "lblZpKto", 300, 560, 7800, 640, "", 9, False, RGB(60, 60, 60))
    Set ctl = mod_UI_Spolocne.DlgPole(strTmp, "txtZpOC", 6500, 20, 1500)
    ctl.Visible = False

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 1340, 2000, 300, "Platné od mesiaca:")
    Call mod_UI_Spolocne.DlgVyber(strTmp, "cboZpMesiac", 2400, 1300, 2400, mod_UI_Spolocne.ZoznamMesiacovRowSource())
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 1760, 2000, 300, "Pracovný fond:")
    Call mod_UI_Spolocne.DlgVyber(strTmp, "cboZpFond", 2400, 1720, 5600, "")
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 2180, 2000, 300, "Šablóna prerušení:")
    Call mod_UI_Spolocne.DlgVyber(strTmp, "cboZpSablona", 2400, 2140, 5600, "")
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 2600, 2000, 300, "Kalendár:")
    Call mod_UI_Spolocne.DlgVyber(strTmp, "cboZpKalendar", 2400, 2560, 5600, "")
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 3020, 2000, 300, "Úväzok (%):")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtZpUvazok", 2400, 2980, 900)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 3450, 3020, 4600, 300, "(prázdne = nemeniť; 50 = polovičný úväzok)", 8, False, RGB(100, 100, 100))

    Call mod_UI_Spolocne.DlgZaskrtavatko(strTmp, "chkZpSkupina", 300, 3640, "=Zp_SkupinaZmenenaUI()")
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 650, 3630, 7400, 300, "Vytvoriť z označených novú skupinu (vlastný fond a pravidlá)", 10, True, FARBA_NADPIS)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 650, 4090, 1700, 300, "Názov skupiny:")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtZpNazov", 2400, 4050, 4300)
    Call mod_UI_Spolocne.DlgZaskrtavatko(strTmp, "chkZpKopiaFondu", 650, 4540)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 1000, 4530, 7000, 300, "vlastná kópia pracovného fondu")
    Call mod_UI_Spolocne.DlgZaskrtavatko(strTmp, "chkZpKopiaSablony", 650, 4940)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 1000, 4930, 7000, 300, "vlastná kópia pravidiel prerušení")

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 5380, 7800, 700, _
        "Kópia vznikne zo zvoleného fondu (šablóny), alebo - ak je zvolené (nemeniť) - z nastavenia prvého označeného zamestnanca. " & _
        "Upravíte ju v okne Pracovné fondy a Pravidlá prerušení; zmena sa potom týka len tejto skupiny.", 8, False, RGB(90, 90, 90))

    Set ctl = mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnZpPouzit", 300, 6150, 2000, "&Použiť", "=Zp_PouzitUI()", True)
    ctl.Default = True
    Set ctl = mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnZpZavri", 6100, 6150, 1900, "&Zavrieť", "=Zp_ZavriUI()")
    ctl.Cancel = True
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "lblZpStav", 300, 6620, 7800, 300, "", 9, False, RGB(0, 100, 0))

    strDiag = mod_UI_Spolocne.DlgUlozFormular(frm, strTmp, FRM_PRIR)
    Call mod_00_Common.SetNastavenie(KLUC_VER_PRIR, VERZIA_PRIR, "Verzia okna hromadného priradenia (frmZamPriradenie)")
    Call mod_00_Common.ZapisLog("mod_UI_ZamKarta.VytvorPriradenie", "INFO", "Okno priradenia vytvorené. " & strDiag)
    Exit Sub
Chyba:
    strE = Err.Description
    Call mod_00_Common.ZapisLog("mod_UI_ZamKarta.VytvorPriradenie", "ERROR", strE)
    On Error Resume Next
    If Len(strTmp) > 0 Then DoCmd.Close acForm, strTmp, acSaveNo
    On Error GoTo 0
    Err.Raise vbObjectError + 702, "VytvorPriradenie", "Okno priradenia sa nepodarilo vytvoriť: " & strE
End Sub

Private Function MenoZamestnanca(ByVal strOC As String) As String
    Dim v As Variant
    On Error Resume Next
    v = DLookup("Priezvisko & ' ' & Meno", "Zamestnanci", "OsobneCislo = " & mod_00_Common.SqlText(strOC))
    If IsNull(v) Then MenoZamestnanca = strOC Else MenoZamestnanca = Trim$(CStr(v)) & " (" & strOC & ")"
End Function

'-------------------------------------------------------------------------------
' Otvorí hromadné priradenie pre zamestnancov z poľa vOC; bSkupina = predvolene vytvoriť novú skupinu.
'-------------------------------------------------------------------------------
Public Function OtvorPriradenie(ByVal vOC As Variant, Optional ByVal bSkupina As Boolean = False) As Boolean
    On Error GoTo Chyba
    Dim frm As Form, v As Variant, strZoznam As String, strMena As String, n As Long, lRok As Long, lMes As Long
    If Not IsArray(vOC) Then Exit Function
    If UBound(vOC) < LBound(vOC) Then Exit Function
    If (mod_00_Common.GetNastavenie(KLUC_VER_PRIR, "") <> VERZIA_PRIR) Or Not mod_00_Common.FormularExistujeDB(FRM_PRIR) Then Call VytvorPriradenie
    If mod_00_Common.FormIsOpen(FRM_PRIR) Then DoCmd.Close acForm, FRM_PRIR, acSaveNo

    For Each v In vOC
        n = n + 1
        strZoznam = strZoznam & IIf(Len(strZoznam) > 0, ",", "") & CStr(v)
        If n <= 4 Then strMena = strMena & IIf(Len(strMena) > 0, "; ", "") & MenoZamestnanca(CStr(v))
    Next v
    If n > 4 Then strMena = strMena & "; ... a ďalších " & (n - 4)

    DoCmd.OpenForm FRM_PRIR, acNormal
    Set frm = Forms(FRM_PRIR)
    frm!txtZpOC = strZoznam
    frm!lblZpKto.Caption = "Označených zamestnancov: " & n & vbCrLf & strMena
    frm!cboZpFond.RowSource = mod_15_Zamestnanci.ZoznamFondovVL(True)
    frm!cboZpSablona.RowSource = mod_15_Zamestnanci.ZoznamSablonVL(True)
    frm!cboZpKalendar.RowSource = mod_15_Zamestnanci.ZoznamKalendarovVL(True)
    frm!cboZpFond.ColumnWidths = "0;5600"
    frm!cboZpSablona.ColumnWidths = "0;5600"
    frm!cboZpKalendar.ColumnWidths = "0;5600"
    frm!cboZpFond = -1: frm!cboZpSablona = -1: frm!cboZpKalendar = -1
    frm!txtZpUvazok = Null
    frm!chkZpSkupina = bSkupina
    frm!chkZpKopiaFondu = True
    frm!chkZpKopiaSablony = True
    If bSkupina And n = 1 Then
        frm!txtZpNazov = Left$(MenoZamestnanca(CStr(vOC(LBound(vOC)))), 50)
    Else
        frm!txtZpNazov = Null
    End If
    frm!lblZpStav.Caption = ""
    Call mod_UI_Tab_Zamestnanci.Zam_ZvolenyMesiac(lRok, lMes)
    Call mod_UI_Spolocne.NastavVyberMesiaca(frm!cboZpMesiac, lRok, lMes)
    Call Zp_SkupinaZmenenaUI
    OtvorPriradenie = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_ZamKarta.OtvorPriradenie", "ERROR", Err.Description)
    MsgBox "Okno priradenia sa nepodarilo otvoriť: " & Err.Description, vbExclamation, "Zamestnanci"
End Function

Public Function Zp_SkupinaZmenenaUI() As Boolean
    On Error Resume Next
    Dim frm As Form, b As Boolean
    Set frm = Forms(FRM_PRIR)
    b = CBool(Nz(frm!chkZpSkupina.Value, False))
    frm!txtZpNazov.Enabled = b
    frm!chkZpKopiaFondu.Enabled = b
    frm!chkZpKopiaSablony.Enabled = b
    Zp_SkupinaZmenenaUI = True
End Function

Public Function Zp_PouzitUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, lRok As Long, lMes As Long, lF As Long, lP As Long, lK As Long, lU As Long
    Dim bSk As Boolean, bNF As Boolean, bNS As Boolean, strNazov As String, strVys As String, vOC As Variant, n As Long

    Set frm = Forms(FRM_PRIR)
    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboZpMesiac, lRok, lMes) Then
        MsgBox "Vyberte mesiac, od ktorého nastavenia platia.", vbExclamation, "Zamestnanci"
        Exit Function
    End If
    lF = ZoznamHodnota(frm!cboZpFond): lP = ZoznamHodnota(frm!cboZpSablona): lK = ZoznamHodnota(frm!cboZpKalendar)
    If Len(Trim$(CStr(Nz(frm!txtZpUvazok.Value, "")))) > 0 Then
        If Not IsNumeric(frm!txtZpUvazok.Value) Then
            MsgBox "Úväzok zadajte číslom v percentách (napr. 100 alebo 50).", vbExclamation, "Zamestnanci"
            Exit Function
        End If
        lU = CLng(frm!txtZpUvazok.Value)
        If lU < 1 Or lU > 200 Then
            MsgBox "Úväzok musí byť v rozsahu 1 až 200 %.", vbExclamation, "Zamestnanci"
            Exit Function
        End If
    End If
    bSk = CBool(Nz(frm!chkZpSkupina.Value, False))
    bNF = bSk And CBool(Nz(frm!chkZpKopiaFondu.Value, False))
    bNS = bSk And CBool(Nz(frm!chkZpKopiaSablony.Value, False))
    strNazov = Trim$(CStr(Nz(frm!txtZpNazov.Value, "")))
    If bSk And Not (bNF Or bNS) Then
        MsgBox "Pre novú skupinu zaškrtnite aspoň jednu z kópií (fond alebo pravidlá prerušení).", vbExclamation, "Zamestnanci"
        Exit Function
    End If
    If (bNF Or bNS) And Len(strNazov) = 0 Then
        MsgBox "Zadajte názov skupiny.", vbExclamation, "Zamestnanci"
        Exit Function
    End If
    If lF <= 0 And lP <= 0 And lK <= 0 And lU <= 0 And Not (bNF Or bNS) Then
        MsgBox "Nie je čo zmeniť: vyberte fond, šablónu, kalendár, zadajte úväzok alebo vytvorte novú skupinu.", vbInformation, "Zamestnanci"
        Exit Function
    End If

    vOC = Split(CStr(Nz(frm!txtZpOC.Value, "")), ",")
    If MsgBox("Použiť nastavenia pre " & (UBound(vOC) - LBound(vOC) + 1) & " zamestnancov od mesiaca " & lMes & "/" & lRok & "?", _
              vbQuestion + vbYesNo, "Zamestnanci") <> vbYes Then Exit Function

    n = mod_15_Zamestnanci.HromadnePriradenie(vOC, CInt(lRok), CInt(lMes), lF, lP, lK, lU, bNF, bNS, strNazov, strVys)
    Call mod_UI_Pomocnik.OznacCinnost("ZAMESTNANCI")
    frm!lblZpStav.Caption = IIf(n > 0, "Hotovo.", "Nič sa nezmenilo.")
    MsgBox strVys, IIf(n > 0, vbInformation, vbExclamation), "Zamestnanci"
    Call mod_UI_Tab_Zamestnanci.Zam_ObnovUI
    Zp_PouzitUI = (n > 0)
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_ZamKarta.Zp_PouzitUI", "ERROR", Err.Description)
    MsgBox "Priradenie sa nepodarilo: " & Err.Description, vbExclamation, "Zamestnanci"
End Function

Public Function Zp_ZavriUI() As Boolean
    On Error Resume Next
    DoCmd.Close acForm, FRM_PRIR, acSaveNo
    Zp_ZavriUI = True
End Function

Public Function Zp_PoZatvoreniUI() As Boolean
    On Error Resume Next
    Call mod_UI_Tab_Zamestnanci.Zam_ObnovUI
    If mod_00_Common.FormIsOpen(FRM_KARTA) Then Call Zk_MesiacZmenenyUI
    Zp_PoZatvoreniUI = True
End Function
