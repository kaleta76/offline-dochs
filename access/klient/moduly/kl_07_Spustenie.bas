Attribute VB_Name = "kl_07_Spustenie"
'@Verzia 1.0.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: kl_07_Spustenie
' POPIS: Štart klienta. Spusti() je cieľ makra AutoExec (volá ho Access po otvorení DochadzkaKlient.accdb); PripravKlienta()
'        volá zostavovač Instaluj-Klienta.ps1 raz pri zostavení (vytvorí formulár frmKlient a nastaví vzhľad aplikácie).
'
'        Štart (Spusti), v tomto poradí:
'          1. skrytie pásu kariet a navigačného panela (správca otvorí klienta so Shiftom a má všetko),
'          2. lokálne priečinky (ak sa nedajú vytvoriť, razenie sa vypne, lebo sa nemá kam zapisovať),
'          3. zámok jednej inštancie (klient.lock otvorený na výhradný zápis po celý čas behu; druhá inštancia skončí),
'          4. základ na serveri zo zaklad.txt (chýba = klient nebol spustený cez Spusti-Dochadzku.cmd, razenie vypnuté),
'          5. identita (kl_01_Identita), konfigurácia (kl_04_Konfig), upratanie odoslaných razení (staršie než 90 dní),
'          6. okno (kl_06_Okno) a až potom odoslanie čakajúcich razení z predošlých behov (odlozene=1).
' ZOZNAM VEREJNÝCH PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - Spusti()           : Štart klienta (cieľ AutoExec). Vráti True, ak sa okno otvorilo.
' - Ukonci()           : Uvoľní zámok inštancie a ukončí Access.
' - PripravKlienta()   : Pre zostavovač: vytvorí formulár a nastaví vlastnosti aplikácie; vráti "" alebo text chyby.
'===============================================================================

Public Const SPRAVA_BEZ_ZAKLADU As String = "Klient nebol spustený cez Spusti-Dochadzku.cmd. Zatvorte ho a spustite Dochádzku odkazom na ploche."
Public Const NADPIS_OKNA As String = "Dochádzka"
Private Const CHYBA_ZAMKNUTE As Long = 70

Private mZamok As Integer       ' číslo súboru klient.lock držaného po celý čas behu (0 = nedržíme)
Private mSpusteny As Boolean

'===============================================================================
' Zámok jednej inštancie
'===============================================================================
' True = zámok získaný (alebo sa ho nepodarilo zistiť z iného dôvodu než "už beží": razenie to neblokuje).
' False = klient už beží (súbor je zamknutý druhou inštanciou).
Private Function ZiskajZamok() As Boolean
    Dim strCesta As String, lCislo As Integer
    On Error GoTo Chyba
    strCesta = kl_00_Spolocne.LokalnyPriecinok() & "\" & kl_00_Spolocne.SUBOR_ZAMOK
    lCislo = FreeFile
    Open strCesta For Binary Access Read Write Lock Read Write As #lCislo
    mZamok = lCislo
    ZiskajZamok = True
    Exit Function
Chyba:
    If Err.Number = CHYBA_ZAMKNUTE Then
        ZiskajZamok = False
    Else
        Call kl_00_Spolocne.ZapisLog("WARN", "Zámok inštancie sa nepodarilo vytvoriť (chyba " & Err.Number & "), pokračujem bez neho.")
        ZiskajZamok = True
    End If
End Function

Private Sub UvolniZamok()
    On Error Resume Next
    If mZamok <> 0 Then
        Close #mZamok
        mZamok = 0
    End If
    Err.Clear
End Sub

Public Sub Ukonci()
    On Error Resume Next
    Call UvolniZamok
    Call kl_00_Spolocne.ZapisLog("INFO", "Koniec klienta.")
    Application.Quit acQuitSaveNone
End Sub

'===============================================================================
' Vzhľad aplikácie
'===============================================================================
' Skryje pás kariet a navigačný panel (rovnako ako konzola HR). Volá sa pred otvorením okna, aby príkaz nezasiahol okno klienta.
Private Sub SkryMenu()
    On Error Resume Next
    DoCmd.ShowToolbar "Ribbon", acToolbarNo
    Err.Clear
    DoCmd.NavigateTo "acNavigationCategoryObjectType"
    If Err.Number <> 0 Then
        Err.Clear
        DoCmd.SelectObject acTable, , True
    End If
    DoCmd.RunCommand acCmdWindowHide
    Err.Clear
End Sub

' Nastaví vlastnosť databázy (vytvorí ju, ak ešte neexistuje). Vráti True, ak sa to podarilo.
Private Function NastavVlastnostDB(ByVal strNazov As String, ByVal lTyp As Long, ByVal vHodnota As Variant) As Boolean
    Dim db As DAO.Database, prp As DAO.Property
    On Error Resume Next
    Set db = CurrentDb
    db.Properties(strNazov).Value = vHodnota
    If Err.Number = 0 Then NastavVlastnostDB = True: Exit Function
    Err.Clear
    Set prp = db.CreateProperty(strNazov, lTyp, vHodnota)
    db.Properties.Append prp
    NastavVlastnostDB = (Err.Number = 0)
    Err.Clear
End Function

' Pre zostavovač: vytvorí formulár frmKlient a nastaví vlastnosti aplikácie. Vráti "" alebo text chyby.
Public Function PripravKlienta() As String
    Dim strChyba As String
    strChyba = kl_06_Okno.VytvorFormular()
    If Len(strChyba) > 0 Then
        PripravKlienta = strChyba
        Exit Function
    End If
    If Not NastavVlastnostDB("AppTitle", dbText, "Dochádzka – razenie") Then
        PripravKlienta = "Nepodarilo sa nastaviť názov aplikácie."
        Exit Function
    End If
    If Not NastavVlastnostDB("StartUpShowDBWindow", dbBoolean, False) Then
        PripravKlienta = "Nepodarilo sa skryť okno databázy pri štarte."
        Exit Function
    End If
    On Error Resume Next
    Application.RefreshTitleBar
    Err.Clear
End Function

'===============================================================================
' Štart
'===============================================================================
Public Function Spusti() As Boolean
    Dim strChyba As String, strOc As String, strLogin As String, strPc As String, strZdroj As String, strZaklad As String

    On Error GoTo Chyba
    If mSpusteny Then Exit Function
    mSpusteny = True
    Call SkryMenu

    strChyba = kl_00_Spolocne.PripravLokalnePriecinky()
    If Len(strChyba) > 0 Then
        Call kl_05_Razenie.VypniRazenie(strChyba & " Razenie je vypnuté, obráťte sa na IT.")
    ElseIf Not ZiskajZamok() Then
        MsgBox "Klient už beží. Použite jeho okno (nájdete ho na paneli úloh).", vbInformation, NADPIS_OKNA
        Call Ukonci
        Exit Function
    Else
        Call kl_00_Spolocne.ZapisLog("INFO", "Štart klienta verzia " & kl_00_Spolocne.VERZIA_KLIENTA & ".")
        strZaklad = kl_00_Spolocne.ZakladPriecinok()
        If Len(strZaklad) = 0 Then
            Call kl_00_Spolocne.ZapisLog("ERROR", "Chýba zaklad.txt, klient nebol spustený cez Spusti-Dochadzku.cmd.")
            Call kl_05_Razenie.VypniRazenie(SPRAVA_BEZ_ZAKLADU)
        ElseIf kl_01_Identita.ZistiIdentitu(strOc, strLogin, strPc, strZdroj, strChyba) Then
            Call kl_05_Razenie.NastavIdentitu(strOc, strLogin, strPc, strZdroj)
        Else
            Call kl_05_Razenie.VypniRazenie(strChyba)
        End If
        Call kl_04_Konfig.NacitajKonfig
        Call kl_03_Fronta.UpracOdoslane(Now)
    End If

    If Not kl_06_Okno.OtvorOkno() Then Exit Function
    Spusti = True
    DoEvents
    ' razenia z predošlých behov (odlozene=1); okno je už otvorené, takže pomalý server ho nezdrží
    If Len(kl_03_Fronta.CestaPrijmu()) > 0 Then
        Call kl_03_Fronta.OdosliCakajuce(True)
        Call kl_06_Okno.ObnovOkno
    End If
    Exit Function
Chyba:
    Call kl_00_Spolocne.ZapisLog("ERROR", "Štart klienta skončil chybou " & Err.Number & ": " & Err.Description)
    MsgBox "Klient sa nepodarilo spustiť (chyba " & Err.Number & "). Obráťte sa na IT.", vbCritical, NADPIS_OKNA
End Function
