Attribute VB_Name = "mod_UI_Spolocne"
'@Verzia 1.2.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_UI_Spolocne
' POPIS: Spoločné prvky používateľského rozhrania konzoly:
'        - výber mesiaca rozbaľovacím zoznamom ("november 2026") namiesto písania mesiaca a roka,
'        - zadávanie osobných čísel textom s automatickým rozpoznaním oddeľovača a rozsahov,
'        - rozloženie a písmo generovaných formulárov (šírka obsahu, zmeranie textu, zmenšenie písma
'          tak, aby popisky a tlačidlá neboli orezané, odstránenie pripojených popiskov),
'        - hlavička / päta formulára a dočasné premenné relácie (TempVars).
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - TVGet(nazov, predvolene) / TVSet(nazov, hodnota) : Bezpečné čítanie / zápis dočasných premenných (TempVars).
' - ZapniHlavickuPaticku(frm, vyskaH, vyskaF)    : Zapne hlavičku a pätu formulára v návrhu (False, ak to nejde).
' - RozsirStranu(page, faktor, kotva, posunY)  : Roztiahne obsah karty do šírky (aj šírky stĺpcov zoznamov) a posunie ho nahor.
' - DnoStrany(page)                             : Spodný okraj obsahu karty (twipy).
' - PrisposobOvladac(formular, ovladac)          : Písmo Segoe UI; zmenší písmo, ak by sa text orezal.
' - NormalizujFormular(frm)                      : Odstráni pripojené popisky a prispôsobí všetky ovládacie prvky.
' - NazovMesiaca(m)                              : Slovenský názov mesiaca (január ... december).
' - ZoznamMesiacovRowSource(rokZahrn)            : RowSource (Value List) mesiacov od najnovšieho po najstarší.
' - VytvorVyberMesiaca(frm, page, meno, x, y, w)  : Vytvorí rozbaľovací zoznam mesiacov (v návrhu formulára).
' - NastavVyberMesiaca(ctl, rok, mes)             : Nastaví zvolený mesiac (a obnoví zoznam rokov).
' - ObdobieZVyberu(ctl, rok, mes)                 : Prečíta zvolený mesiac; False, ak nie je platný.
' - PosunVyberMesiaca(ctl, delta)                 : Posun o delta mesiacov (tlačidlá < >).
' - OsobneCislaZTextu(text, nezname, overit)      : Rozdelí text na osobné čísla (ľubovoľný oddeľovač, rozsahy 1001-1010).
' - SqlZoznamOC(pole)                             : Pole osobných čísel -> SQL zoznam 'a','b' pre IN (...).
' - OsobneCislaSql(text, nezname, pocet)          : Text -> SQL zoznam (skratka).
' - DlgNovyFormular(...)                           : Nový vyskakovací modálny formulár (v návrhu) pre dialógové okná.
' - DlgPopisok / DlgPole / DlgVyber / DlgZaskrtavatko / DlgTlacidlo : Ovládacie prvky dialógových okien.
' - DlgUlozFormular(frm, tmp, nazov)               : Normalizuje, uloží a premenuje dialógový formulár.
'===============================================================================

Public Const UI_PISMO As String = "Segoe UI"
Public Const UI_VELKOSTPISMA As Long = 10

Private mCacheSirky As Object      ' namerané šírky textov (kľúč: veľkosť|tučné|text)

'-------------------------------------------------------------------------------
' Slovenský názov mesiaca (1-12), inak prázdny reťazec.
'-------------------------------------------------------------------------------
Public Function NazovMesiaca(ByVal iMes As Long) As String
    If iMes < 1 Or iMes > 12 Then Exit Function
    NazovMesiaca = Choose(iMes, "január", "február", "marec", "apríl", "máj", "jún", "júl", "august", "september", "október", "november", "december")
End Function

'-------------------------------------------------------------------------------
' Najstarší rok, ktorý má zmysel ponúkať (podľa razení v databáze, najviac 15 rokov dozadu).
'-------------------------------------------------------------------------------
Private Function NajstarsiRok() As Long
    Dim v As Variant
    NajstarsiRok = Year(Date) - 3
    On Error Resume Next
    v = DMin("Datum", "DochadzkaImport")
    If Not IsNull(v) And Not IsEmpty(v) Then
        If IsDate(v) Then
            If Year(CDate(v)) < NajstarsiRok Then NajstarsiRok = Year(CDate(v))
        End If
    End If
    If NajstarsiRok < Year(Date) - 15 Then NajstarsiRok = Year(Date) - 15
End Function

'-------------------------------------------------------------------------------
' Zoznam mesiacov pre rozbaľovací zoznam: hodnota yyyymm; zobrazený text "november 2026".
' Zoradené od budúceho roka po najstarší rok s dátami. lRokZahrn = rok, ktorý musí byť v zozname.
'-------------------------------------------------------------------------------
Public Function ZoznamMesiacovRowSource(Optional ByVal lRokZahrn As Long = 0) As String
    Dim y As Long, m As Long, s As String, lOd As Long, lDo As Long
    lOd = NajstarsiRok()
    lDo = Year(Date) + 1
    If lRokZahrn >= 1990 And lRokZahrn <= 2100 Then
        If lRokZahrn < lOd Then lOd = lRokZahrn
        If lRokZahrn > lDo Then lDo = lRokZahrn
    End If
    For y = lDo To lOd Step -1
        For m = 12 To 1 Step -1
            s = s & CStr(y * 100 + m) & ";" & NazovMesiaca(m) & " " & y & ";"
        Next m
    Next y
    If Len(s) > 0 Then s = Left$(s, Len(s) - 1)
    ZoznamMesiacovRowSource = s
End Function

'-------------------------------------------------------------------------------
' Vytvorí v návrhu formulára rozbaľovací zoznam mesiacov. strPoZmene = výraz udalosti AfterUpdate (napr. "=Fn()").
'-------------------------------------------------------------------------------
Public Function VytvorVyberMesiaca(ByVal strFrm As String, ByVal strPage As String, ByVal strNazov As String, _
                                   ByVal lX As Long, ByVal lY As Long, Optional ByVal lSirka As Long = 2000, _
                                   Optional ByVal strPoZmene As String = "") As Control
    Dim ctl As Control
    Set ctl = CreateControl(strFrm, acComboBox, acDetail, strPage, "", lX, lY, lSirka, 330)
    ctl.Name = strNazov
    ctl.RowSourceType = "Value List"
    ctl.RowSource = ZoznamMesiacovRowSource()
    ctl.ColumnCount = 2
    ctl.ColumnWidths = "0;" & CStr(lSirka)
    ctl.BoundColumn = 1
    ctl.LimitToList = True
    ctl.ListRows = 16
    ctl.AutoExpand = True
    ctl.ControlTipText = "Vyberte mesiac zo zoznamu alebo začnite písať jeho názov (napr. okt)."
    If Len(strPoZmene) > 0 Then ctl.AfterUpdate = strPoZmene
    Set VytvorVyberMesiaca = ctl
End Function

'-------------------------------------------------------------------------------
' Nastaví zvolený mesiac. bObnovZoznam = znovu zostaví zoznam mesiacov (aktuálne roky + rok lRok).
'-------------------------------------------------------------------------------
Public Sub NastavVyberMesiaca(ByVal ctl As Control, ByVal lRok As Long, ByVal lMes As Long, Optional ByVal bObnovZoznam As Boolean = True)
    On Error Resume Next
    If lMes < 1 Or lMes > 12 Or lRok < 1990 Or lRok > 2100 Then Exit Sub
    If bObnovZoznam Then ctl.RowSource = ZoznamMesiacovRowSource(lRok)
    ctl.Value = CStr(lRok * 100 + lMes)
End Sub

'-------------------------------------------------------------------------------
' Prečíta zvolený mesiac z rozbaľovacieho zoznamu. Vráti False, ak nie je nič platné vybrané.
'-------------------------------------------------------------------------------
Public Function ObdobieZVyberu(ByVal ctl As Control, ByRef lRok As Long, ByRef lMes As Long) As Boolean
    Dim v As String
    On Error Resume Next
    v = Trim$(CStr(Nz(ctl.Value, "")))
    On Error GoTo 0
    If Len(v) = 6 And IsNumeric(v) Then
        lRok = CLng(Left$(v, 4))
        lMes = CLng(Right$(v, 2))
        ObdobieZVyberu = (lRok >= 1990 And lRok <= 2100 And lMes >= 1 And lMes <= 12)
    End If
End Function

'-------------------------------------------------------------------------------
' Posunie zvolený mesiac o lDelta (záporné = dozadu). Ak nie je nič vybrané, začne aktuálnym mesiacom.
'-------------------------------------------------------------------------------
Public Sub PosunVyberMesiaca(ByVal ctl As Control, ByVal lDelta As Long)
    Dim lR As Long, lM As Long, d As Date
    If Not ObdobieZVyberu(ctl, lR, lM) Then lR = Year(Date): lM = Month(Date)
    d = DateSerial(lR, lM + lDelta, 1)
    Call NastavVyberMesiaca(ctl, Year(d), Month(d), (Year(d) <> lR))
End Sub

'-------------------------------------------------------------------------------
' Priradí zadaný token k osobnému číslu v tabuľke Zamestnanci (presná zhoda, potom číselná zhoda 0123 = 123).
' Ak sa nenájde, vráti normalizovaný tvar (číslo bez úvodných núl) a bZnamy = False.
'-------------------------------------------------------------------------------
Private Function PriradOC(ByVal strTok As String, ByVal bOverit As Boolean, ByRef bZnamy As Boolean) As String
    Dim v As Variant
    bZnamy = False
    PriradOC = strTok
    If IsNumeric(strTok) And Not strTok Like "*[!0-9]*" Then
        If Len(strTok) <= 15 Then PriradOC = Format$(CDbl(strTok), "0")
    End If
    If Not bOverit Then Exit Function
    On Error Resume Next
    v = DLookup("OsobneCislo", "Zamestnanci", "OsobneCislo = " & mod_00_Common.SqlText(strTok))
    If IsNull(v) And PriradOC <> strTok Then v = DLookup("OsobneCislo", "Zamestnanci", "OsobneCislo = " & mod_00_Common.SqlText(PriradOC))
    If IsNull(v) And IsNumeric(PriradOC) Then v = DLookup("OsobneCislo", "Zamestnanci", "IsNumeric(OsobneCislo) AND Val(OsobneCislo) = " & PriradOC)
    If Not IsNull(v) And Not IsEmpty(v) Then PriradOC = CStr(v): bZnamy = True
End Function

'-------------------------------------------------------------------------------
' Rozdelí text s osobnými číslami na jedinečné osobné čísla.
'  - oddeľovač sa rozpozná sám: čokoľvek okrem písmen, číslic a pomlčky (čiarka, bodkočiarka, medzera,
'    tabulátor, nový riadok, |, / ...), takže funguje aj text skopírovaný z Excelu alebo e-mailu,
'  - rozsah "1001-1010" sa rozvinie (najviac 2000 čísel),
'  - bOverit = TRUE: čísla sa priradia k tvaru v tabuľke Zamestnanci, nenájdené sa vrátia v strNezname.
' Vráti pole reťazcov (prázdne pole, ak text neobsahuje žiadne číslo).
'-------------------------------------------------------------------------------
Public Function OsobneCislaZTextu(ByVal strText As String, Optional ByRef strNezname As String, Optional ByVal bOverit As Boolean = True) As Variant
    Dim s As String, i As Long, c As String, tok As Variant, dic As Object, strTok As String
    Dim p As Long, dOd As Double, dDo As Double, k As Double, strOC As String, bZnamy As Boolean
    Dim zoz As Collection, v As Variant

    strNezname = ""
    Set dic = CreateObject("Scripting.Dictionary")
    Set zoz = New Collection

    For i = 1 To Len(strText)
        c = Mid$(strText, i, 1)
        If c Like "[0-9A-Za-z]" Or c = "-" Then s = s & c Else s = s & " "
    Next i
    Do While InStr(s, "  ") > 0
        s = Replace(s, "  ", " ")
    Loop
    s = Trim$(s)
    If Len(s) = 0 Then OsobneCislaZTextu = Array(): Exit Function

    For Each tok In Split(s, " ")
        strTok = Trim$(CStr(tok))
        Do While Left$(strTok, 1) = "-"
            strTok = Mid$(strTok, 2)
        Loop
        Do While Right$(strTok, 1) = "-"
            strTok = Left$(strTok, Len(strTok) - 1)
        Loop
        If Len(strTok) > 0 Then
            p = InStr(strTok, "-")
            If p > 0 Then
                If IsNumeric(Left$(strTok, p - 1)) And IsNumeric(Mid$(strTok, p + 1)) And InStr(p + 1, strTok, "-") = 0 Then
                    dOd = CDbl(Left$(strTok, p - 1)): dDo = CDbl(Mid$(strTok, p + 1))
                    If dDo >= dOd And dDo - dOd <= 2000 Then
                        For k = dOd To dDo
                            zoz.Add Format$(k, "0")
                        Next k
                    Else
                        zoz.Add Replace(strTok, "-", "")
                    End If
                Else
                    zoz.Add Replace(strTok, "-", "")
                End If
            Else
                zoz.Add strTok
            End If
        End If
    Next tok

    For Each v In zoz
        strOC = PriradOC(CStr(v), bOverit, bZnamy)
        If Len(strOC) > 0 And Len(strOC) <= 20 And Not dic.Exists(strOC) Then
            dic(strOC) = bZnamy
            If bOverit And Not bZnamy Then strNezname = strNezname & IIf(Len(strNezname) > 0, ", ", "") & strOC
        End If
    Next v

    If dic.Count = 0 Then OsobneCislaZTextu = Array() Else OsobneCislaZTextu = dic.Keys
End Function

'-------------------------------------------------------------------------------
' Pole osobných čísel -> SQL zoznam pre IN (...): 'a','b','c'. Prázdne pole -> "".
'-------------------------------------------------------------------------------
Public Function SqlZoznamOC(ByVal vPole As Variant) As String
    Dim v As Variant, s As String
    If Not IsArray(vPole) Then Exit Function
    For Each v In vPole
        s = s & IIf(Len(s) > 0, ",", "") & mod_00_Common.SqlText(CStr(v))
    Next v
    SqlZoznamOC = s
End Function

'-------------------------------------------------------------------------------
' Text s osobnými číslami -> SQL zoznam (skratka). lPocet = počet rozpoznaných čísel.
'-------------------------------------------------------------------------------
Public Function OsobneCislaSql(ByVal strText As String, Optional ByRef strNezname As String, Optional ByRef lPocet As Long) As String
    Dim a As Variant
    a = OsobneCislaZTextu(strText, strNezname, True)
    lPocet = UBound(a) - LBound(a) + 1
    OsobneCislaSql = SqlZoznamOC(a)
End Function

'===============================================================================
' DOČASNÉ PREMENNÉ RELÁCIE
'===============================================================================

'-------------------------------------------------------------------------------
' Prečíta dočasnú premennú (TempVars); ak neexistuje, vráti predvolenú hodnotu.
'-------------------------------------------------------------------------------
Public Function TVGet(ByVal strNazov As String, Optional ByVal vPredvolene As Variant = "") As Variant
    Dim v As Variant
    On Error Resume Next
    TVGet = vPredvolene
    v = Null
    v = TempVars(strNazov).Value
    If Err.Number <> 0 Then Err.Clear: Exit Function
    ' neexistujúca premenná sa môže vrátiť ako Null - vtedy platí predvolená hodnota (CLng(Null) by zlyhalo)
    If Not IsNull(v) And Not IsEmpty(v) Then TVGet = v
End Function

'-------------------------------------------------------------------------------
' Zapíše (alebo prepíše) dočasnú premennú relácie.
'-------------------------------------------------------------------------------
Public Sub TVSet(ByVal strNazov As String, ByVal vHodnota As Variant)
    On Error Resume Next
    TempVars.Add strNazov, vHodnota
End Sub

'===============================================================================
' ROZLOŽENIE A PÍSMO GENEROVANÝCH FORMULÁROV (volá sa v návrhu formulára)
'===============================================================================

'-------------------------------------------------------------------------------
' Zapne hlavičku a pätu formulára (pevné časti, ktoré sa pri posúvaní nehýbu) a nastaví ich výšku.
' Vráti False, ak to v danej verzii Accessu nejde (volajúci použije záložné rozloženie).
'-------------------------------------------------------------------------------
Public Function ZapniHlavickuPaticku(ByVal frm As Form, ByVal lVyskaH As Long, ByVal lVyskaF As Long) As Boolean
    Dim bViditelne As Boolean
    On Error Resume Next
    frm.Section(acHeader).Visible = True
    frm.Section(acFooter).Visible = True
    frm.Section(acHeader).Height = lVyskaH
    frm.Section(acFooter).Height = lVyskaF
    If Err.Number = 0 Then
        If frm.Section(acHeader).Height = lVyskaH And frm.Section(acFooter).Height = lVyskaF Then
            ZapniHlavickuPaticku = True
            Exit Function
        End If
    End If
    Err.Clear
    ' záloha: prepínač "Hlavička/päta formulára" (funguje len ak ešte nie sú zapnuté)
    bViditelne = (frm.Section(acHeader).Visible Or frm.Section(acFooter).Visible)
    Err.Clear
    If Not bViditelne Then DoCmd.RunCommand acCmdFormHdrFtr
    Err.Clear
    frm.Section(acHeader).Height = lVyskaH
    frm.Section(acFooter).Height = lVyskaF
    If Err.Number = 0 Then
        ZapniHlavickuPaticku = (frm.Section(acHeader).Height = lVyskaH And frm.Section(acFooter).Height = lVyskaF)
    End If
End Function

'-------------------------------------------------------------------------------
' Roztiahne obsah karty (všetky ovládacie prvky na stránke) do šírky: x' = kotva + (x - kotva) * faktor,
' a prípadne ho posunie nahor o lPosunY.
' Zväčší aj šírky stĺpcov zoznamov a rozbaľovacích zoznamov (ak sú zadané v twipoch bez jednotiek).
'-------------------------------------------------------------------------------
Public Sub RozsirStranu(ByVal pg As Object, ByVal dFaktor As Double, Optional ByVal lKotva As Long = 500, Optional ByVal lPosunY As Long = 0)
    Dim ctl As Control
    On Error Resume Next
    If dFaktor = 1 And lPosunY = 0 Then Exit Sub
    For Each ctl In pg.Controls
        If dFaktor <> 1 Then
            ctl.Left = lKotva + CLng((ctl.Left - lKotva) * dFaktor)
            ctl.Width = CLng(ctl.Width * dFaktor)
            Select Case ctl.ControlType
                Case acListBox, acComboBox
                    ctl.ColumnWidths = ZmenStlpce(ctl.ColumnWidths, dFaktor)
            End Select
        End If
        If lPosunY <> 0 Then ctl.Top = ctl.Top - lPosunY
    Next ctl
End Sub

'-------------------------------------------------------------------------------
' Spodný okraj obsahu karty (najväčšie Top + Height zo všetkých ovládacích prvkov na stránke).
'-------------------------------------------------------------------------------
Public Function DnoStrany(ByVal pg As Object) As Long
    Dim ctl As Control, l As Long
    On Error Resume Next
    For Each ctl In pg.Controls
        If ctl.Top + ctl.Height > l Then l = ctl.Top + ctl.Height
    Next ctl
    DnoStrany = l
End Function

Private Function ZmenStlpce(ByVal strSirky As String, ByVal dFaktor As Double) As String
    Dim a() As String, i As Long
    ZmenStlpce = strSirky
    If Len(strSirky) = 0 Then Exit Function
    If strSirky Like "*[!0-9;]*" Then Exit Function
    a = Split(strSirky, ";")
    For i = 0 To UBound(a)
        If Len(a(i)) > 0 Then a(i) = CStr(CLng(CDbl(a(i)) * dFaktor))
    Next i
    ZmenStlpce = Join(a, ";")
End Function

'-------------------------------------------------------------------------------
' Hrubý odhad šírky textu v twipoch (záloha, ak zmeranie zlyhá).
'-------------------------------------------------------------------------------
Private Function OdhadSirkyTextu(ByVal strText As String, ByVal lVelkost As Long, ByVal bTucne As Boolean) As Long
    Dim i As Long, c As String, dEm As Double
    For i = 1 To Len(strText)
        c = Mid$(strText, i, 1)
        If c = " " Then
            dEm = dEm + 0.28
        ElseIf InStr("il.,;:'|!()[]/-", c) > 0 Then
            dEm = dEm + 0.3
        ElseIf InStr("mwMW@%", c) > 0 Then
            dEm = dEm + 0.85
        ElseIf c <> LCase$(c) Then
            dEm = dEm + 0.66
        Else
            dEm = dEm + 0.52
        End If
    Next i
    dEm = dEm * lVelkost * 20
    If bTucne Then dEm = dEm * 1.08
    OdhadSirkyTextu = CLng(dEm)
End Function

'-------------------------------------------------------------------------------
' Zmeria šírku jedného riadku textu (twipy) pomocou dočasného popisku a SizeToFit; pri zlyhaní použije odhad.
'-------------------------------------------------------------------------------
Private Function ZmerajRiadok(ByVal strFrm As String, ByVal strRiadok As String, ByVal lVelkost As Long, ByVal bTucne As Boolean) As Long
    Dim t As Control
    On Error GoTo Chyba
    Set t = CreateControl(strFrm, acLabel, acDetail, "", "", 0, 0, 100, 100)
    t.FontName = UI_PISMO
    t.FontSize = lVelkost
    t.FontBold = bTucne
    t.Caption = strRiadok
    t.SizeToFit
    ZmerajRiadok = t.Width
    DeleteControl strFrm, t.Name
    Exit Function
Chyba:
    On Error Resume Next
    If Not t Is Nothing Then DeleteControl strFrm, t.Name
    ZmerajRiadok = OdhadSirkyTextu(strRiadok, lVelkost, bTucne)
End Function

'-------------------------------------------------------------------------------
' Šírka textu (twipy) v jednom riadku; viacriadkový text = najširší riadok. Výsledky sa zapamätajú.
'-------------------------------------------------------------------------------
Private Function SirkaTextu(ByVal strFrm As String, ByVal strText As String, ByVal lVelkost As Long, ByVal bTucne As Boolean) As Long
    Dim strKluc As String, v As Variant, lMax As Long, lW As Long, strTxt As String
    If mCacheSirky Is Nothing Then Set mCacheSirky = CreateObject("Scripting.Dictionary")
    strKluc = lVelkost & "|" & IIf(bTucne, "B", "N") & "|" & strText
    If mCacheSirky.Exists(strKluc) Then
        SirkaTextu = CLng(mCacheSirky(strKluc))
        Exit Function
    End If
    ' symbol & označuje klávesovú skratku (nezobrazuje sa); && sa zobrazí ako &
    strTxt = Replace(strText, "&&", Chr$(1))
    strTxt = Replace(strTxt, "&", "")
    strTxt = Replace(strTxt, Chr$(1), "&")
    strTxt = Replace(strTxt, vbCr, "")
    For Each v In Split(strTxt, vbLf)
        lW = ZmerajRiadok(strFrm, CStr(v), lVelkost, bTucne)
        If lW > lMax Then lMax = lW
    Next v
    mCacheSirky(strKluc) = lMax
    SirkaTextu = lMax
End Function

'-------------------------------------------------------------------------------
' Nastaví písmo ovládacieho prvku (Segoe UI) a zmenší ho (najviac na 8 b.), ak by sa popisok alebo
' tlačidlo inak orezali. Viacriadkové popisky: počíta sa s výškou prvku. Vráti True, ak sa písmo zmenilo.
'-------------------------------------------------------------------------------
Public Function PrisposobOvladac(ByVal strFrm As String, ByVal ctl As Control) As Boolean
    Dim lS0 As Long, lS As Long, bTucne As Boolean, strCap As String, lPouzitelna As Long
    Dim lDlzka As Long, dW As Double, lPov As Long, bTlacidlo As Boolean, bHotovo As Boolean
    On Error Resume Next
    Select Case ctl.ControlType
        Case acLabel, acCommandButton, acTextBox, acComboBox, acListBox, acCheckBox
        Case Else
            Exit Function
    End Select
    ctl.FontName = UI_PISMO
    If ctl.FontSize = 11 Then ctl.FontSize = UI_VELKOSTPISMA
    If ctl.ControlType <> acLabel And ctl.ControlType <> acCommandButton Then Exit Function

    strCap = CStr(ctl.Caption)
    If Len(strCap) = 0 Then Exit Function
    bTlacidlo = (ctl.ControlType = acCommandButton)
    lS0 = ctl.FontSize
    If lS0 <= 8 Then Exit Function
    bTucne = ctl.FontBold
    lPouzitelna = ctl.Width - IIf(bTlacidlo, 320, 100)
    If lPouzitelna < 200 Then Exit Function
    lDlzka = SirkaTextu(strFrm, strCap, lS0, bTucne)
    If lDlzka <= 0 Then Exit Function

    bHotovo = False
    For lS = lS0 To 8 Step -1
        dW = lDlzka * lS / lS0
        If bTlacidlo Then
            If dW <= lPouzitelna Then
                bHotovo = True
            End If
        Else
            lPov = (ctl.Height + 30) \ CLng(lS * 20 * 1.35)
            If lPov < 1 Then lPov = 1
            If lPov = 1 Then
                If dW <= lPouzitelna Then bHotovo = True
            ElseIf Int(dW * 1.12 / lPouzitelna) + 1 <= lPov Then
                bHotovo = True
            End If
        End If
        If bHotovo Then Exit For
    Next lS
    If lS < 8 Then lS = 8
    If lS <> lS0 Then
        ctl.FontSize = lS
        PrisposobOvladac = True
    End If
End Function

'-------------------------------------------------------------------------------
' Prejde všetky ovládacie prvky formulára (v návrhu): odstráni pripojené popisky textových polí, zoznamov a políčok
' (stratené "Text12:" a pod.) a prispôsobí písmo. Vráti stručný popis (počty) do diagnostiky.
'-------------------------------------------------------------------------------
Public Function NormalizujFormular(ByVal frm As Form) As String
    Dim ctl As Control, colDel As Collection, v As Variant, strFrm As String
    Dim lPopisky As Long, lZmenene As Long, lPocet As Long
    On Error Resume Next
    strFrm = frm.Name
    Set colDel = New Collection
    For Each ctl In frm.Controls
        Select Case ctl.ControlType
            Case acTextBox, acComboBox, acListBox, acCheckBox
                If ctl.Controls.Count > 0 Then colDel.Add ctl.Controls(0).Name
        End Select
        Err.Clear
    Next ctl
    For Each v In colDel
        DeleteControl strFrm, CStr(v)
        If Err.Number = 0 Then lPopisky = lPopisky + 1
        Err.Clear
    Next v
    For Each ctl In frm.Controls
        lPocet = lPocet + 1
        If PrisposobOvladac(strFrm, ctl) Then lZmenene = lZmenene + 1
        Err.Clear
    Next ctl
    NormalizujFormular = frm.Name & ": prvkov " & lPocet & ", odstránených popiskov " & lPopisky & ", zmenšené písmo " & lZmenene
End Function

'===============================================================================
' DIALÓGOVÉ OKNÁ (karta zamestnanca, fondy, pravidlá prerušení ...)
'===============================================================================

'-------------------------------------------------------------------------------
' Vytvorí nový formulár v návrhu: vyskakovacie modálne okno bez posuvníkov. Vráti formulár, strTmp = jeho dočasný názov.
'-------------------------------------------------------------------------------
Public Function DlgNovyFormular(ByVal strNadpis As String, ByVal lSirka As Long, ByVal lVyska As Long, ByRef strTmp As String, _
                                Optional ByVal strPoZatvoreni As String = "") As Form
    Dim frm As Form
    Set frm = CreateForm
    strTmp = frm.Name
    With frm
        .Caption = strNadpis
        .RecordSelectors = False
        .NavigationButtons = False
        .DividingLines = False
        .ScrollBars = 0
        .AutoCenter = True
        .PopUp = True
        .Modal = True
        .BorderStyle = 3
        .Width = lSirka
        .Section(acDetail).Height = lVyska
    End With
    If Len(strPoZatvoreni) > 0 Then frm.OnClose = strPoZatvoreni
    Set DlgNovyFormular = frm
End Function

'-------------------------------------------------------------------------------
' Popisok (lFarba < 0 = predvolená farba).
'-------------------------------------------------------------------------------
Public Function DlgPopisok(ByVal strFrm As String, ByVal strNazov As String, ByVal lX As Long, ByVal lY As Long, ByVal lW As Long, _
                           ByVal lH As Long, ByVal strText As String, Optional ByVal lVelkost As Long = 10, _
                           Optional ByVal bTucne As Boolean = False, Optional ByVal lFarba As Long = -1) As Control
    Dim ctl As Control
    Set ctl = CreateControl(strFrm, acLabel, acDetail, "", "", lX, lY, lW, lH)
    If Len(strNazov) > 0 Then ctl.Name = strNazov
    ctl.Caption = strText
    ctl.FontName = UI_PISMO
    ctl.FontSize = lVelkost
    ctl.FontBold = bTucne
    If lFarba >= 0 Then ctl.ForeColor = lFarba
    Set DlgPopisok = ctl
End Function

'-------------------------------------------------------------------------------
' Textové pole (nepripojené).
'-------------------------------------------------------------------------------
Public Function DlgPole(ByVal strFrm As String, ByVal strNazov As String, ByVal lX As Long, ByVal lY As Long, ByVal lW As Long, _
                        Optional ByVal strPoZmene As String = "") As Control
    Dim ctl As Control
    Set ctl = CreateControl(strFrm, acTextBox, acDetail, "", "", lX, lY, lW, 320)
    ctl.Name = strNazov
    ctl.FontName = UI_PISMO
    ctl.FontSize = UI_VELKOSTPISMA
    If Len(strPoZmene) > 0 Then ctl.AfterUpdate = strPoZmene
    Set DlgPole = ctl
End Function

'-------------------------------------------------------------------------------
' Rozbaľovací zoznam z reťazca "kód;text;kód;text" (skrytý prvý stĺpec = kód).
'-------------------------------------------------------------------------------
Public Function DlgVyber(ByVal strFrm As String, ByVal strNazov As String, ByVal lX As Long, ByVal lY As Long, ByVal lW As Long, _
                         ByVal strZoznam As String, Optional ByVal strPoZmene As String = "") As Control
    Dim ctl As Control
    Set ctl = CreateControl(strFrm, acComboBox, acDetail, "", "", lX, lY, lW, 320)
    ctl.Name = strNazov
    ctl.FontName = UI_PISMO
    ctl.FontSize = UI_VELKOSTPISMA
    ctl.RowSourceType = "Value List"
    ctl.RowSource = strZoznam
    ctl.ColumnCount = 2
    ctl.ColumnWidths = "0;" & CStr(lW)
    ctl.BoundColumn = 1
    ctl.LimitToList = True
    ctl.ListRows = 14
    ctl.AutoExpand = True
    If Len(strPoZmene) > 0 Then ctl.AfterUpdate = strPoZmene
    Set DlgVyber = ctl
End Function

'-------------------------------------------------------------------------------
' Začiarkavacie políčko (popisok vedľa neho vytvorte samostatne cez DlgPopisok).
'-------------------------------------------------------------------------------
Public Function DlgZaskrtavatko(ByVal strFrm As String, ByVal strNazov As String, ByVal lX As Long, ByVal lY As Long, _
                                Optional ByVal strPoZmene As String = "") As Control
    Dim ctl As Control
    Set ctl = CreateControl(strFrm, acCheckBox, acDetail, "", "", lX, lY, 260, 260)
    ctl.Name = strNazov
    If Len(strPoZmene) > 0 Then ctl.AfterUpdate = strPoZmene
    Set DlgZaskrtavatko = ctl
End Function

'-------------------------------------------------------------------------------
' Tlačidlo s obsluhou "=Funkcia()".
'-------------------------------------------------------------------------------
Public Function DlgTlacidlo(ByVal strFrm As String, ByVal strNazov As String, ByVal lX As Long, ByVal lY As Long, ByVal lW As Long, _
                            ByVal strText As String, ByVal strAkcia As String, Optional ByVal bTucne As Boolean = False, _
                            Optional ByVal lH As Long = 400) As Control
    Dim ctl As Control
    Set ctl = CreateControl(strFrm, acCommandButton, acDetail, "", "", lX, lY, lW, lH)
    ctl.Name = strNazov
    ctl.Caption = strText
    ctl.FontName = UI_PISMO
    ctl.FontSize = UI_VELKOSTPISMA
    ctl.FontBold = bTucne
    ctl.OnClick = strAkcia
    Set DlgTlacidlo = ctl
End Function

'-------------------------------------------------------------------------------
' Dokončí dialóg: odstráni pripojené popisky, prispôsobí písmo, uloží formulár a premenuje ho na strKonecnyNazov.
' Vráti stručnú diagnostiku.
'-------------------------------------------------------------------------------
Public Function DlgUlozFormular(ByVal frm As Form, ByVal strTmp As String, ByVal strKonecnyNazov As String) As String
    DlgUlozFormular = NormalizujFormular(frm)
    DoCmd.Save acForm, strTmp
    DoCmd.Close acForm, strTmp, acSaveYes
    DoCmd.Rename strKonecnyNazov, acForm, strTmp
End Function

'-------------------------------------------------------------------------------
' Zavrie a zmaže starý formulár (ak existuje) pred jeho opätovným vytvorením.
'-------------------------------------------------------------------------------
Public Sub DlgZmazFormular(ByVal strNazov As String)
    On Error Resume Next
    If mod_00_Common.FormIsOpen(strNazov) Then DoCmd.Close acForm, strNazov, acSaveNo
    If mod_00_Common.FormularExistujeDB(strNazov) Then DoCmd.DeleteObject acForm, strNazov
    Err.Clear
End Sub
