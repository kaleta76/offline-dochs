Attribute VB_Name = "mod_UI_Uzavierka"
'@Verzia 1.0.0
Option Compare Database
Option Explicit

' ==============================================================================
' MODUL: mod_UI_Uzavierka
' POPIS: Okno "Uzávierka mesiaca" (formulár frmUzavierka): potvrdenie, že mesačná zostava zamestnanca bola vytlačená a podpísaná,
'        uzavretie mesiaca zamestnanca (zámok proti zmene razení, výpočtu, fondu a pravidiel), opätovné otvorenie s dôvodom
'        a kontrola, či sa uzavreté údaje po uzavretí nezmenili. Logika je v module mod_18_Uzavierka.
'
'        Postup: 1. na karte 6 zobraziť zostavu, vytlačiť, podpísať; 2. v tomto okne označiť zamestnancov a stlačiť Uzavrieť.
'        Okno je modálne, preto sa zostava zobrazuje na karte 6 (nie z okna).
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - Uz_OtvorOknoUI()        : Otvorí okno pre mesiac zvolený na karte 6.
' - OtvorOknoUzavierky      : Otvorí okno pre zadaný mesiac.
' - Uz_ObnovUI()            : Znova načíta zoznam zamestnancov a súhrn.
' - Uz_MesPredUI / Uz_MesDalsiUI / Uz_OznacVsetkychUI / Uz_ZrusOznacenieUI : Ovládanie zoznamu.
' - Uz_UzavriUI()           : Uzavrie mesiac označeným zamestnancom.
' - Uz_OtvorMesiacUI()      : Znova otvorí uzavretý mesiac označeným zamestnancom (dôvod je povinný).
' - Uz_OveritUI() / Uz_OveritVsetkoUI() : Kontrola integrity uzavretých mesiacov.
' - Uz_ZavriUI / Uz_PoZatvoreniUI : Zatvorenie okna.
' - TextInfoUzavierky(rok, mes) : Krátky text o uzavretých mesiacoch pre kartu 6.
' ==============================================================================

Private Const FRM_UZ As String = "frmUzavierka"
Private Const VERZIA_UZ As String = "1.0"
Private Const KLUC_VER_UZ As String = "UzavierkaFormVerzia"
Private Const FARBA_NADPIS As Long = 5905935         ' RGB(15, 30, 90)
Private Const NADPIS_MSG As String = "Uzávierka mesiaca"

'===============================================================================
' VYTVORENIE FORMULÁRA
'===============================================================================

Private Sub VytvorOkno()
    On Error GoTo Chyba
    Dim frm As Form, strTmp As String, ctl As Control, strDiag As String, strE As String
    Dim vS As Variant, vH As Variant, i As Long, lX As Long

    Call mod_UI_Spolocne.DlgZmazFormular(FRM_UZ)
    Set frm = mod_UI_Spolocne.DlgNovyFormular(NADPIS_MSG, 10400, 8500, strTmp, "=Uz_PoZatvoreniUI()")

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 100, 9800, 400, "Uzávierka mesiaca - potvrdenie vytlačenej a podpísanej zostavy", 13, True, FARBA_NADPIS)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "lblUzPostup", 300, 540, 9800, 900, _
        "Postup: 1. Na karte 6 zobrazte tlačovú zostavu zamestnanca, vytlačte ju a nechajte podpísať. " & _
        "2. Tu označte zamestnancov s podpísanou zostavou a stlačte Uzavrieť. Uzavretý mesiac sa už nedá meniť " & _
        "(razenia, výpočet, fond ani pravidlá platné pre mesiac). Zostavu možno vytlačiť aj znova - pätička uvedie, že mesiac je uzavretý. " & _
        "Uzavrieť možno od posledného dňa mesiaca.", 9, False, RGB(60, 60, 60))

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 1560, 900, 300, "Mesiac:", 10, True)
    Call mod_UI_Spolocne.DlgVyber(strTmp, "cboUzMesiac", 1250, 1520, 2400, mod_UI_Spolocne.ZoznamMesiacovRowSource(), "=Uz_ObnovUI()")
    Set ctl = mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnUzMesPred", 3750, 1520, 400, "<", "=Uz_MesPredUI()", True, 330)
    ctl.ControlTipText = "Predchádzajúci mesiac"
    Set ctl = mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnUzMesDalsi", 4200, 1520, 400, ">", "=Uz_MesDalsiUI()", True, 330)
    ctl.ControlTipText = "Nasledujúci mesiac"
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "lblUzSuhrn", 4800, 1530, 5300, 300, "", 9, True, RGB(15, 30, 90))

    ' hlavička zoznamu (záhlavie stĺpcov je z popiskov, aby sa zhodovali s číslovaním riadkov zoznamu)
    vH = Array("Os. číslo", "Zamestnanec", "Stav", "Zostava", "Uzavrel / potvrdil")
    vS = Array(1100, 3200, 1100, 1700, 2700)
    lX = 300
    For i = 0 To UBound(vH)
        Set ctl = mod_UI_Spolocne.DlgPopisok(strTmp, "", lX, 1960, CLng(vS(i)), 250, CStr(vH(i)), 8, True)
        ctl.BackStyle = 1
        ctl.BackColor = RGB(215, 222, 238)
        lX = lX + CLng(vS(i))
    Next i

    Set ctl = CreateControl(strTmp, acListBox, acDetail, "", "", 300, 2220, 9800, 2700)
    ctl.Name = "lstUzZam"
    With ctl
        .MultiSelect = 2
        .ColumnCount = 5
        .ColumnWidths = "1100;3200;1100;1700;2700"
        .ColumnHeads = False
        .RowSourceType = "Table/Query"
        .FontName = mod_UI_Spolocne.UI_PISMO
        .FontSize = 9
    End With

    Call mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnUzVsetci", 300, 5000, 2000, "Označiť &všetkých", "=Uz_OznacVsetkychUI()", False, 340)
    Call mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnUzNikoho", 2450, 5000, 2000, "Zrušiť o&značenie", "=Uz_ZrusOznacenieUI()", False, 340)

    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 5530, 2100, 300, "Potvrdil (podpísal):")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtUzPotvrdil", 2450, 5490, 3600)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 6200, 5530, 3900, 300, "(kto zostavu podpísal / zodpovedá za uzavretie)", 8, False, RGB(100, 100, 100))
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 300, 5930, 2100, 300, "Poznámka / dôvod:")
    Call mod_UI_Spolocne.DlgPole(strTmp, "txtUzDovod", 2450, 5890, 7650)

    Call mod_UI_Spolocne.DlgZaskrtavatko(strTmp, "chkUzPodpisane", 300, 6380)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "", 650, 6370, 9450, 300, _
        "Potvrdzujem, že zostavy označených zamestnancov boli vytlačené a podpísané.", 10, True, FARBA_NADPIS)

    Set ctl = mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnUzUzavri", 300, 6850, 2900, "&Uzavrieť označených", "=Uz_UzavriUI()", True, 450)
    ctl.Default = True
    Call mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnUzOtvor", 3350, 6850, 2900, "&Otvoriť označených (dôvod)", "=Uz_OtvorMesiacUI()", False, 450)
    Set ctl = mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnUzZavri", 8200, 6850, 1900, "&Zavrieť", "=Uz_ZavriUI()", False, 450)
    ctl.Cancel = True
    Call mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnUzOver", 300, 7400, 2900, "&Skontrolovať integritu mesiaca", "=Uz_OveritUI()", False, 400)
    Call mod_UI_Spolocne.DlgTlacidlo(strTmp, "btnUzOverVsetko", 3350, 7400, 2900, "Skontrolovať &všetky mesiace", "=Uz_OveritVsetkoUI()", False, 400)
    Call mod_UI_Spolocne.DlgPopisok(strTmp, "lblUzStav", 300, 7930, 9800, 400, "", 9, False, RGB(0, 100, 0))

    strDiag = mod_UI_Spolocne.DlgUlozFormular(frm, strTmp, FRM_UZ)
    Call mod_00_Common.SetNastavenie(KLUC_VER_UZ, VERZIA_UZ, "Verzia okna Uzávierka mesiaca (frmUzavierka)")
    Call mod_00_Common.ZapisLog("mod_UI_Uzavierka.VytvorOkno", "INFO", "Okno uzávierky vytvorené. " & strDiag)
    Exit Sub
Chyba:
    strE = Err.Description
    Call mod_00_Common.ZapisLog("mod_UI_Uzavierka.VytvorOkno", "ERROR", strE)
    On Error Resume Next
    If Len(strTmp) > 0 Then DoCmd.Close acForm, strTmp, acSaveNo
    On Error GoTo 0
    Err.Raise vbObjectError + 718, "VytvorOkno", "Okno uzávierky sa nepodarilo vytvoriť: " & strE
End Sub

'===============================================================================
' OTVORENIE OKNA
'===============================================================================

'-------------------------------------------------------------------------------
' Otvorí okno pre mesiac zvolený na karte 6 (tlačidlo na karte).
'-------------------------------------------------------------------------------
Public Function Uz_OtvorOknoUI() As Boolean
    Dim lRok As Long, lMes As Long, d As Date
    On Error Resume Next
    If mod_00_Common.FormIsOpen("frmHlavnaKonzola") Then Call mod_UI_Spolocne.ObdobieZVyberu(Forms!frmHlavnaKonzola!cboVypocetObdobie, lRok, lMes)
    Err.Clear
    On Error GoTo 0
    If lRok = 0 Or lMes = 0 Then
        d = DateAdd("m", -1, Date)
        lRok = Year(d): lMes = Month(d)
    End If
    Uz_OtvorOknoUI = OtvorOknoUzavierky(lRok, lMes)
End Function

Public Function OtvorOknoUzavierky(ByVal lRok As Long, ByVal lMes As Long) As Boolean
    On Error GoTo Chyba
    Dim frm As Form, db As DAO.Database
    Set db = CurrentDb
    Call mod_18_Uzavierka.ZabezpecTabulky(db)
    If (mod_00_Common.GetNastavenie(KLUC_VER_UZ, "") <> VERZIA_UZ) Or Not mod_00_Common.FormularExistujeDB(FRM_UZ) Then Call VytvorOkno
    If mod_00_Common.FormIsOpen(FRM_UZ) Then DoCmd.Close acForm, FRM_UZ, acSaveNo

    DoCmd.OpenForm FRM_UZ, acNormal
    Set frm = Forms(FRM_UZ)
    frm!txtUzPotvrdil = mod_00_Common.Uzivatel()
    frm!txtUzDovod = Null
    frm!chkUzPodpisane = False
    frm!lblUzStav.Caption = ""
    Call mod_UI_Spolocne.NastavVyberMesiaca(frm!cboUzMesiac, lRok, lMes)
    Call Uz_ObnovUI
    OtvorOknoUzavierky = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Uzavierka.OtvorOknoUzavierky", "ERROR", Err.Description)
    MsgBox "Okno uzávierky sa nepodarilo otvoriť: " & Err.Description, vbExclamation, NADPIS_MSG
End Function

'===============================================================================
' ZOZNAM A OVLÁDANIE
'===============================================================================

Private Function ZvolenyMesiac(ByVal frm As Form, ByRef lRok As Long, ByRef lMes As Long) As Boolean
    ZvolenyMesiac = mod_UI_Spolocne.ObdobieZVyberu(frm!cboUzMesiac, lRok, lMes)
    If Not ZvolenyMesiac Then MsgBox "Vyberte mesiac zo zoznamu.", vbExclamation, NADPIS_MSG
End Function

'-------------------------------------------------------------------------------
' Osobné čísla označené v zozname (pole reťazcov; prázdne pole, ak nie je nič označené).
'-------------------------------------------------------------------------------
Private Function VybraniOC(ByVal frm As Form) As Variant
    Dim v As Variant, lst As Access.ListBox, a() As String, n As Long
    On Error Resume Next
    Set lst = frm!lstUzZam
    If lst.ItemsSelected.Count = 0 Then VybraniOC = Array(): Exit Function
    ReDim a(0 To lst.ItemsSelected.Count - 1)
    For Each v In lst.ItemsSelected
        a(n) = CStr(lst.ItemData(v))
        n = n + 1
    Next v
    VybraniOC = a
End Function

Private Function MenoOC(ByVal strOC As String) As String
    Dim v As Variant
    On Error Resume Next
    v = DLookup("Priezvisko & ' ' & Meno", "Zamestnanci", "OsobneCislo = " & mod_00_Common.SqlText(strOC))
    If IsNull(v) Then MenoOC = strOC Else MenoOC = Trim$(CStr(v)) & " (" & strOC & ")"
End Function

Public Function Uz_ObnovUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, lRok As Long, lMes As Long, nSpolu As Long, nUz As Long, dKoniec As Date, s As String
    If Not mod_00_Common.FormIsOpen(FRM_UZ) Then Exit Function
    Set frm = Forms(FRM_UZ)
    If Not mod_UI_Spolocne.ObdobieZVyberu(frm!cboUzMesiac, lRok, lMes) Then
        frm!lstUzZam.RowSource = ""
        frm!lblUzSuhrn.Caption = "Vyberte mesiac."
        Exit Function
    End If
    Call mod_18_Uzavierka.ResetCache
    frm!lstUzZam.RowSource = mod_18_Uzavierka.SqlZoznamUzavierky(lRok, lMes)
    frm!lstUzZam.Requery
    nSpolu = frm!lstUzZam.ListCount
    nUz = mod_18_Uzavierka.PocetUzavretych(lRok, lMes)
    s = "Zamestnancov: " & nSpolu & "   uzavretých: " & nUz & "   otvorených: " & IIf(nSpolu >= nUz, nSpolu - nUz, 0)
    dKoniec = DateSerial(lRok, lMes + 1, 0)
    If Date < dKoniec Then s = s & "   (mesiac skončí " & Format$(dKoniec, "dd.mm.yyyy") & ")"
    frm!lblUzSuhrn.Caption = s
    Uz_ObnovUI = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_Uzavierka.Uz_ObnovUI", "ERROR", Err.Description)
    On Error Resume Next
    frm!lblUzSuhrn.Caption = "Zoznam sa nepodarilo načítať: " & Err.Description
End Function

Public Function Uz_MesPredUI() As Boolean
    On Error Resume Next
    Call mod_UI_Spolocne.PosunVyberMesiaca(Forms(FRM_UZ)!cboUzMesiac, -1)
    Uz_MesPredUI = Uz_ObnovUI()
End Function

Public Function Uz_MesDalsiUI() As Boolean
    On Error Resume Next
    Call mod_UI_Spolocne.PosunVyberMesiaca(Forms(FRM_UZ)!cboUzMesiac, 1)
    Uz_MesDalsiUI = Uz_ObnovUI()
End Function

Public Function Uz_OznacVsetkychUI() As Boolean
    Dim lst As Access.ListBox, i As Long
    On Error Resume Next
    Set lst = Forms(FRM_UZ)!lstUzZam
    For i = 0 To lst.ListCount - 1
        lst.Selected(i) = True
    Next i
    Uz_OznacVsetkychUI = True
End Function

Public Function Uz_ZrusOznacenieUI() As Boolean
    Dim lst As Access.ListBox, i As Long
    On Error Resume Next
    Set lst = Forms(FRM_UZ)!lstUzZam
    For i = 0 To lst.ListCount - 1
        lst.Selected(i) = False
    Next i
    Uz_ZrusOznacenieUI = True
End Function

'===============================================================================
' UZAVRETIE, OTVORENIE, KONTROLA
'===============================================================================

Public Function Uz_UzavriUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, lRok As Long, lMes As Long, vOC As Variant, v As Variant, strPotv As String, strPozn As String
    Dim nOk As Long, nChyb As Long, strChyby As String, strE As String, nAno As Long, nNav As Long, strUpoz As String, n As Long

    Set frm = Forms(FRM_UZ)
    If Not ZvolenyMesiac(frm, lRok, lMes) Then Exit Function
    vOC = VybraniOC(frm)
    If UBound(vOC) < LBound(vOC) Then
        MsgBox "Označte v zozname aspoň jedného zamestnanca.", vbExclamation, NADPIS_MSG
        Exit Function
    End If
    strPotv = Trim$(CStr(Nz(frm!txtUzPotvrdil.Value, "")))
    If Len(strPotv) < 2 Then
        MsgBox "Uveďte, kto zostavy potvrdil (podpísal).", vbExclamation, NADPIS_MSG
        frm!txtUzPotvrdil.SetFocus
        Exit Function
    End If
    If Not CBool(Nz(frm!chkUzPodpisane.Value, False)) Then
        MsgBox "Zaškrtnite potvrdenie, že zostavy označených zamestnancov boli vytlačené a podpísané.", vbExclamation, NADPIS_MSG
        Exit Function
    End If
    If Date < DateSerial(lRok, lMes + 1, 0) Then
        MsgBox "Mesiac " & lMes & "/" & lRok & " ešte neskončil - uzavrieť ho možno od " & Format$(DateSerial(lRok, lMes + 1, 0), "dd.mm.yyyy") & ".", vbExclamation, NADPIS_MSG
        Exit Function
    End If
    strPozn = Trim$(CStr(Nz(frm!txtUzDovod.Value, "")))

    For Each v In vOC
        nAno = nAno + mod_09_AutoOprava.PocetAnomalii(CInt(lRok), CInt(lMes), CStr(v), "CHYBA")
        nNav = nNav + mod_09_AutoOprava.PocetNavrhov(CInt(lRok), CInt(lMes), "NAVRH", CStr(v))
    Next v
    n = UBound(vOC) - LBound(vOC) + 1
    If nAno > 0 Or nNav > 0 Then
        strUpoz = vbCrLf & vbCrLf & "POZOR: u označených zamestnancov zostali nevyriešené nezrovnalosti (chyby: " & nAno & _
                  ", návrhy opráv na schválenie: " & nNav & "). Po uzavretí ich už nebude možné opraviť bez opätovného otvorenia mesiaca."
    End If
    If MsgBox("Uzavrieť mesiac " & lMes & "/" & lRok & " pre " & n & " zamestnancov (potvrdil: " & strPotv & ")?" & vbCrLf & vbCrLf & _
              "Po uzavretí sa nebudú dať meniť razenia, výpočet, fond ani pravidlá prerušení platné pre tento mesiac. " & _
              "Otvoriť ho možno len s uvedením dôvodu a zostavu bude treba vytlačiť a podpísať znova." & strUpoz, _
              vbQuestion + vbYesNo + vbDefaultButton2, NADPIS_MSG) <> vbYes Then Exit Function

    DoCmd.Hourglass True
    For Each v In vOC
        SysCmd acSysCmdSetStatus, "Uzávierka " & lMes & "/" & lRok & ": " & CStr(v)
        strE = mod_18_Uzavierka.Uzavri(CStr(v), lRok, lMes, strPotv, strPozn)
        If Len(strE) = 0 Then
            nOk = nOk + 1
        Else
            nChyb = nChyb + 1
            If nChyb <= 12 Then strChyby = strChyby & MenoOC(CStr(v)) & ": " & strE & vbCrLf
        End If
    Next v
    DoCmd.Hourglass False
    SysCmd acSysCmdClearStatus
    If nChyb > 12 Then strChyby = strChyby & "... a ďalších " & (nChyb - 12) & vbCrLf

    Call Uz_ObnovUI
    frm!lblUzStav.Caption = "Uzavretých: " & nOk & IIf(nChyb > 0, ", neuzavretých: " & nChyb, "") & "."
    frm!chkUzPodpisane = False
    If nChyb = 0 Then
        MsgBox "Mesiac " & lMes & "/" & lRok & " bol uzavretý pre " & nOk & " zamestnancov.", vbInformation, NADPIS_MSG
    Else
        MsgBox "Uzavretých: " & nOk & vbCrLf & "Neuzavretých: " & nChyb & vbCrLf & vbCrLf & strChyby, vbExclamation, NADPIS_MSG
    End If
    Call mod_UI_Pomocnik.OznacCinnost("VYPOCET")
    Uz_UzavriUI = (nOk > 0)
    Exit Function
Chyba:
    strE = Err.Description
    On Error Resume Next
    DoCmd.Hourglass False
    SysCmd acSysCmdClearStatus
    Call mod_00_Common.ZapisLog("mod_UI_Uzavierka.Uz_UzavriUI", "ERROR", strE)
    MsgBox "Uzavretie sa nepodarilo: " & strE, vbExclamation, NADPIS_MSG
End Function

Public Function Uz_OtvorMesiacUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, lRok As Long, lMes As Long, vOC As Variant, v As Variant, strDovod As String
    Dim nOk As Long, nChyb As Long, strChyby As String, strE As String, n As Long

    Set frm = Forms(FRM_UZ)
    If Not ZvolenyMesiac(frm, lRok, lMes) Then Exit Function
    vOC = VybraniOC(frm)
    If UBound(vOC) < LBound(vOC) Then
        MsgBox "Označte v zozname aspoň jedného zamestnanca.", vbExclamation, NADPIS_MSG
        Exit Function
    End If
    strDovod = Trim$(CStr(Nz(frm!txtUzDovod.Value, "")))
    If Len(strDovod) < 5 Then
        MsgBox "Do poľa Poznámka / dôvod zadajte dôvod otvorenia mesiaca (aspoň 5 znakov). Zapíše sa do protokolu uzávierky.", vbExclamation, NADPIS_MSG
        frm!txtUzDovod.SetFocus
        Exit Function
    End If
    n = UBound(vOC) - LBound(vOC) + 1
    If MsgBox("Znova otvoriť mesiac " & lMes & "/" & lRok & " pre " & n & " zamestnancov?" & vbCrLf & vbCrLf & "Dôvod: " & strDovod & vbCrLf & vbCrLf & _
              "Podpísaná zostava tým prestáva platiť - po úprave bude treba zostavu vytlačiť, podpísať a mesiac uzavrieť znova. " & _
              "Otvorenie sa zaznamená (kto, kedy, dôvod).", vbQuestion + vbYesNo + vbDefaultButton2, NADPIS_MSG) <> vbYes Then Exit Function

    DoCmd.Hourglass True
    For Each v In vOC
        strE = mod_18_Uzavierka.Otvor(CStr(v), lRok, lMes, strDovod)
        If Len(strE) = 0 Then
            nOk = nOk + 1
        Else
            nChyb = nChyb + 1
            If nChyb <= 12 Then strChyby = strChyby & MenoOC(CStr(v)) & ": " & strE & vbCrLf
        End If
    Next v
    DoCmd.Hourglass False
    If nChyb > 12 Then strChyby = strChyby & "... a ďalších " & (nChyb - 12) & vbCrLf

    Call Uz_ObnovUI
    frm!lblUzStav.Caption = "Otvorených: " & nOk & IIf(nChyb > 0, ", nezmenených: " & nChyb, "") & "."
    If nChyb = 0 Then
        MsgBox "Mesiac " & lMes & "/" & lRok & " bol znova otvorený pre " & nOk & " zamestnancov.", vbInformation, NADPIS_MSG
    Else
        MsgBox "Otvorených: " & nOk & vbCrLf & "Nezmenených: " & nChyb & vbCrLf & vbCrLf & strChyby, vbExclamation, NADPIS_MSG
    End If
    Uz_OtvorMesiacUI = (nOk > 0)
    Exit Function
Chyba:
    strE = Err.Description
    On Error Resume Next
    DoCmd.Hourglass False
    Call mod_00_Common.ZapisLog("mod_UI_Uzavierka.Uz_OtvorMesiacUI", "ERROR", strE)
    MsgBox "Otvorenie sa nepodarilo: " & strE, vbExclamation, NADPIS_MSG
End Function

'-------------------------------------------------------------------------------
' Skontroluje uzavreté mesiace (zvolený mesiac alebo všetky) a zobrazí výsledok.
'-------------------------------------------------------------------------------
Private Function Over(ByVal lRok As Long, ByVal lMes As Long) As Boolean
    Dim nZle As Long, nSpolu As Long, strSprava As String, strKde As String
    strKde = IIf(lRok > 0, "mesiac " & lMes & "/" & lRok, "všetky mesiace")
    DoCmd.Hourglass True
    strSprava = mod_18_Uzavierka.OverVsetky(lRok, lMes, nZle, nSpolu)
    DoCmd.Hourglass False
    If nSpolu = 0 Then
        MsgBox "Kontrola (" & strKde & "): nie je žiadny uzavretý mesiac na kontrolu.", vbInformation, NADPIS_MSG
    ElseIf nZle = 0 Then
        MsgBox "Kontrola (" & strKde & "): všetkých " & nSpolu & " uzavretých mesiacov je nezmenených - zodpovedajú podpísaným zostavám.", vbInformation, NADPIS_MSG
    Else
        MsgBox "Kontrola (" & strKde & "): zmenených údajov po uzavretí: " & nZle & " z " & nSpolu & "." & vbCrLf & vbCrLf & strSprava & vbCrLf & _
               "Údaje sa zmenili mimo programu (napr. priamo v tabuľkách) alebo po obnove databázy. Zostava vytlačená teraz by sa líšila od podpísanej. " & _
               "Po overení príčiny mesiac otvorte, prepočítajte, vytlačte a podpíšte znova.", vbExclamation, NADPIS_MSG
    End If
    Over = (nZle = 0)
End Function

Public Function Uz_OveritUI() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, lRok As Long, lMes As Long
    Set frm = Forms(FRM_UZ)
    If Not ZvolenyMesiac(frm, lRok, lMes) Then Exit Function
    Uz_OveritUI = Over(lRok, lMes)
    Exit Function
Chyba:
    DoCmd.Hourglass False
    Call mod_00_Common.ZapisLog("mod_UI_Uzavierka.Uz_OveritUI", "ERROR", Err.Description)
    MsgBox "Kontrola sa nepodarila: " & Err.Description, vbExclamation, NADPIS_MSG
End Function

Public Function Uz_OveritVsetkoUI() As Boolean
    On Error GoTo Chyba
    Uz_OveritVsetkoUI = Over(0, 0)
    Exit Function
Chyba:
    DoCmd.Hourglass False
    Call mod_00_Common.ZapisLog("mod_UI_Uzavierka.Uz_OveritVsetkoUI", "ERROR", Err.Description)
    MsgBox "Kontrola sa nepodarila: " & Err.Description, vbExclamation, NADPIS_MSG
End Function

Public Function Uz_ZavriUI() As Boolean
    On Error Resume Next
    DoCmd.Close acForm, FRM_UZ, acSaveNo
    Uz_ZavriUI = True
End Function

Public Function Uz_PoZatvoreniUI() As Boolean
    On Error Resume Next
    Call mod_UI_Tab_Vypocet.ObnovInfoUzavierky
    Uz_PoZatvoreniUI = True
End Function

'-------------------------------------------------------------------------------
' Krátky text pre kartu 6: koľko zamestnancov má zvolený mesiac uzavretý a koľko uzavretých mesiacov je celkovo.
'-------------------------------------------------------------------------------
Public Function TextInfoUzavierky(ByVal lRok As Long, ByVal lMes As Long) As String
    Dim nMes As Long, nVsetko As Long, s As String
    On Error Resume Next
    If Not mod_18_Uzavierka.ExistujeUzavrety() Then
        TextInfoUzavierky = "Zatiaľ nie je uzavretý žiadny mesiac. Po vytlačení a podpise zostavy ju tu potvrďte - mesiac sa tým zamkne proti zmenám."
        Exit Function
    End If
    nVsetko = mod_18_Uzavierka.PocetUzavretych()
    If lRok > 0 And lMes > 0 Then
        nMes = mod_18_Uzavierka.PocetUzavretych(lRok, lMes)
        s = "Mesiac " & lMes & "/" & lRok & ": uzavretých zamestnancov " & nMes & ". "
    End If
    TextInfoUzavierky = s & "Celkovo uzavretých záznamov (zamestnanec a mesiac): " & nVsetko & "."
End Function
