Attribute VB_Name = "mod_13_Instalacia"
'@Verzia 1.0.4
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_13_Instalacia
' POPIS: Podpora inštalátora a evidencia verzií modulov.
'        Inštalátor (Instaluj-Dochadzku.ps1) volá cez Application.Run tieto verejné funkcie:
'          InstalacnaInicializacia  - vytvorí/overí štruktúru, voliteľne naimportuje staršiu databázu, doplní predvolenú konfiguráciu
'          VerzieModulovText        - vráti nainštalované verzie modulov "modul|verzia|hash;..."
'          ZapisManifestModulov     - zapíše nainštalované verzie do tabuľky VerzieModulov
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - InstalacnaInicializacia(zdrojDB, rezim)   : Kompletná inicializácia databázy po importe modulov.
' - ZabezpecTabulkuVerzii(db)                 : Vytvorí tabuľku VerzieModulov, ak chýba.
' - ZapisManifestModulov(manifest)            : Upsert verzií modulov (vstup: "modul|verzia|hash;modul|verzia|hash").
' - VerzieModulovText()                       : Výpis nainštalovaných verzií v tvare "modul|verzia|hash;...".
' - VerziaModulu(modul)                       : Nainštalovaná verzia konkrétneho modulu ("" ak nie je evidovaná).
' - ZoznamVerziiModulov()                     : Čitateľný zoznam verzií (na zobrazenie v okne Immediate / MsgBox).
' - NastavVerziuBalika(verzia)              : Zapíše verziu inštalačného balíka (NastaveniaSystemu.VerziaBalika).
' - InstalacnyTestStartu()                    : Spustí AutoExecStart() a vráti výsledok + posledné chyby z LogImportu (diagnostika inštalátora).
' - PoslednyChybyLog(n, od, do)               : Posledných n záznamov ERROR/WARN z LogImportu ako text (voliteľne v časovom rozsahu).
'===============================================================================

Public Const DATA_MODEL_VERZIA As Long = 2

'-------------------------------------------------------------------------------
' Kompletná inicializácia po importe modulov. Opakovateľná (nič neničí). Vráti text s priebehom.
' Poradie: štruktúra -> migrácia modelu -> import zo staršej DB (ak je zadaná) -> predvolená konfigurácia.
'-------------------------------------------------------------------------------
Public Function InstalacnaInicializacia(Optional ByVal strZdrojDB As String = "", Optional ByVal iRezim As Long = 1) As String
    On Error GoTo Chyba
    Dim sb As String, n As Long, strTlac As String
    If Not mod_00_Common.TabulkaExistuje("NastaveniaSystemu") Or Not mod_00_Common.TabulkaExistuje("Zamestnanci") Then
        Call mod_01_SystemInit.InicializujDatabazuV2(True)
        sb = sb & "Vytvorená základná štruktúra tabuliek." & vbCrLf
    End If
    Call mod_01_SystemInit.ZabezpecStrukturuImportu
    Call ZabezpecTabulkuVerzii(CurrentDb)
    sb = sb & "Dátový model overený (verzia modelu " & DATA_MODEL_VERZIA & ")." & vbCrLf

    If Len(strZdrojDB) > 0 Then
        sb = sb & vbCrLf & mod_14_ImportModelu.ImportZoStarsejDatabazy(strZdrojDB, iRezim, True) & vbCrLf & vbCrLf
    End If

    ' Predvolená konfigurácia sa pridáva iba raz za databázu (pri aktualizácii sa nevracajú zmazané/upravené položky)
    If UCase$(mod_00_Common.GetNastavenie("PredvolenaKonfiguraciaInicializovana", "")) <> "TRUE" Then
        n = mod_10_Konfiguracia.InicializujPredvolenuKonfiguraciu(True)
        Call mod_00_Common.SetNastavenie("PredvolenaKonfiguraciaInicializovana", "TRUE", "Predvolená konfigurácia prerušení už bola doplnená")
        sb = sb & "Predvolená konfigurácia prerušení a sviatkov doplnená (nových položiek: " & n & ")." & vbCrLf
        If Len(mod_10_Konfiguracia.PoslednaSpravaTlacidiel()) > 0 Then sb = sb & mod_10_Konfiguracia.PoslednaSpravaTlacidiel() & vbCrLf
    Else
        sb = sb & "Predvolená konfigurácia už bola doplnená skôr - preskočené (kartu Prerušenia môžete použiť na doplnenie ručne)." & vbCrLf
    End If

    ' Predvolené tlačidlá a príznaky prerušení pre terminál: jednorazovo aj v databáze, ktorá už konfiguráciu má (aktualizácia).
    ' Uplatnia sa len na prerušenia, ktoré správca nikdy nenastavil; nastavené sa nemenia.
    Call mod_10_Konfiguracia.UplatniPredvolenyTlacidla(strTlac)
    If Len(strTlac) > 0 Then sb = sb & strTlac & vbCrLf

    Call mod_00_Common.SetNastavenie("VerziaDatovehoModelu", CStr(DATA_MODEL_VERZIA), "Verzia dátového modelu (nastavuje inštalátor)")
    Call mod_00_Common.SetNastavenie("InstalaciaDatum", Format$(Now, "yyyy-mm-dd hh:nn:ss"), "Posledná inštalácia / aktualizácia modulov")
    Call mod_00_Common.ZapisLog("InstalacnaInicializacia", "INFO", "Inštalačná inicializácia dokončená", sb)
    InstalacnaInicializacia = sb
    Exit Function
Chyba:
    InstalacnaInicializacia = "CHYBA: " & Err.Description & IIf(Len(sb) > 0, vbCrLf & sb, "")
    Call mod_00_Common.ZapisLog("InstalacnaInicializacia", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Vytvorí tabuľku VerzieModulov (evidencia nainštalovaných verzií modulov), ak neexistuje.
'-------------------------------------------------------------------------------
Public Sub ZabezpecTabulkuVerzii(ByRef db As DAO.Database)
    On Error GoTo Chyba
    If Not mod_00_Common.TabulkaExistujeDB(db, "VerzieModulov") Then
        db.Execute "CREATE TABLE VerzieModulov (Modul TEXT(60) PRIMARY KEY, Verzia TEXT(20), Hash TEXT(64), DatumInstalacie DATETIME, Instaloval TEXT(50))", dbFailOnError
        db.TableDefs.Refresh
    End If
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("ZabezpecTabulkuVerzii", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Zapíše (upsert) verzie modulov nainštalované inštalátorom. Vstup: "modul|verzia|hash;modul|verzia|hash".
' Vráti počet zapísaných modulov.
'-------------------------------------------------------------------------------
Public Function ZapisManifestModulov(ByVal strManifest As String) As Long
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset, v As Variant, p() As String, n As Long
    Set db = CurrentDb
    Call ZabezpecTabulkuVerzii(db)
    Set rs = db.OpenRecordset("SELECT * FROM VerzieModulov;", dbOpenDynaset)
    For Each v In Split(strManifest, ";")
        p = Split(CStr(v), "|")
        If UBound(p) >= 1 And Len(Trim$(p(0))) > 0 Then
            rs.FindFirst "Modul = " & mod_00_Common.SqlText(Trim$(p(0)))
            If rs.NoMatch Then rs.AddNew Else rs.Edit
            rs!Modul = Left$(Trim$(p(0)), 60)
            rs!Verzia = Left$(Trim$(p(1)), 20)
            If UBound(p) >= 2 Then rs!Hash = Left$(Trim$(p(2)), 64)
            rs!DatumInstalacie = Now
            rs!Instaloval = mod_00_Common.Uzivatel()
            rs.Update
            n = n + 1
        End If
    Next v
    rs.Close
    ZapisManifestModulov = n
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("ZapisManifestModulov", "ERROR", Err.Description)
    ZapisManifestModulov = -1
End Function

'-------------------------------------------------------------------------------
' Vráti evidované verzie modulov vo formáte "modul|verzia|hash;..." (prázdny reťazec, ak evidencia neexistuje).
'-------------------------------------------------------------------------------
Public Function VerzieModulovText() As String
    On Error GoTo Chyba
    Dim rs As DAO.Recordset, s As String
    If Not mod_00_Common.TabulkaExistuje("VerzieModulov") Then Exit Function
    Set rs = CurrentDb.OpenRecordset("SELECT Modul, Verzia, Hash FROM VerzieModulov ORDER BY Modul;", dbOpenSnapshot)
    Do While Not rs.EOF
        s = s & rs!Modul & "|" & Nz(rs!Verzia, "") & "|" & Nz(rs!Hash, "") & ";"
        rs.MoveNext
    Loop
    rs.Close
    VerzieModulovText = s
    Exit Function
Chyba:
    VerzieModulovText = ""
End Function

'-------------------------------------------------------------------------------
' Nainštalovaná verzia konkrétneho modulu ("" ak nie je evidovaná).
'-------------------------------------------------------------------------------
Public Function VerziaModulu(ByVal strModul As String) As String
    On Error Resume Next
    VerziaModulu = Nz(DLookup("Verzia", "VerzieModulov", "Modul = " & mod_00_Common.SqlText(strModul)), "")
End Function

'-------------------------------------------------------------------------------
' Čitateľný zoznam verzií modulov (Immediate: ?mod_13_Instalacia.ZoznamVerziiModulov).
'-------------------------------------------------------------------------------
Public Function ZoznamVerziiModulov() As String
    On Error Resume Next
    Dim rs As DAO.Recordset, s As String
    s = "Dátový model: " & mod_00_Common.GetNastavenie("VerziaDatovehoModelu", "?") & ", UI: " & mod_UI_Core.VERZIA_UI & vbCrLf
    Set rs = CurrentDb.OpenRecordset("SELECT Modul, Verzia, DatumInstalacie FROM VerzieModulov ORDER BY Modul;", dbOpenSnapshot)
    Do While Not rs.EOF
        s = s & rs!Modul & "  v" & rs!Verzia & "  (" & Format$(rs!DatumInstalacie, "dd.mm.yyyy hh:nn") & ")" & vbCrLf
        rs.MoveNext
    Loop
    rs.Close
    ZoznamVerziiModulov = s
End Function

'-------------------------------------------------------------------------------
' Diagnostika inštalátora: spustí AutoExecStart() (ako makro AutoExec) a vráti výsledok spolu s poslednými chybami z logu.
'-------------------------------------------------------------------------------
Public Function InstalacnyTestStartu() As String
    Dim ok As Boolean, s As String, lErr As Long, strErr As String, dStart As Date
    On Error Resume Next
    dStart = DateAdd("s", -2, Now)
    ' skúšobný štart: bez skrývania menu a bez info okien; konzola sa vždy vygeneruje nanovo
    Call mod_UI_Spolocne.TVSet("DochTest", 1)
    Call mod_UI_Core.UI_ZneplatniKonzolu
    ok = mod_01_SystemInit.AutoExecStart()
    lErr = Err.Number: strErr = Err.Description
    Err.Clear
    TempVars.Remove "DochTest"
    Err.Clear
    On Error GoTo 0
    s = "AutoExecStart() vrátil: " & IIf(ok, "True (OK)", "False (zlyhal)")
    If lErr <> 0 Then s = s & "; VBA chyba " & lErr & ": " & strErr
    s = s & vbCrLf & mod_UI_Core.UI_DiagnostikaText()
    s = s & vbCrLf & "Chyby/upozornenia pri tomto štarte:" & vbCrLf & PoslednyChybyLog(12, dStart)
    s = s & "Staršie chyby/upozornenia z predošlej prevádzky (len informatívne):" & vbCrLf & PoslednyChybyLog(5, 0, dStart)
    InstalacnyTestStartu = s
End Function

'-------------------------------------------------------------------------------
' Posledných n záznamov typu ERROR/WARN z tabuľky LogImportu (text, jeden záznam na riadok).
'-------------------------------------------------------------------------------
Public Function PoslednyChybyLog(ByVal n As Long, Optional ByVal dOd As Date = 0, Optional ByVal dDo As Date = 0) As String
    On Error Resume Next
    Dim rs As DAO.Recordset, s As String, strKde As String
    strKde = "TypUdalosti IN ('ERROR','WARN')"
    If dOd <> 0 Then strKde = strKde & " AND DatumCas >= #" & Format$(dOd, "yyyy\-mm\-dd hh:nn:ss") & "#"
    If dDo <> 0 Then strKde = strKde & " AND DatumCas < #" & Format$(dDo, "yyyy\-mm\-dd hh:nn:ss") & "#"
    Set rs = CurrentDb.OpenRecordset("SELECT TOP " & n & " DatumCas, Krok, TypUdalosti, Sprava FROM LogImportu WHERE " & strKde & " ORDER BY ID DESC;", dbOpenSnapshot)
    If Not rs Is Nothing Then
        Do While Not rs.EOF
            s = s & Format$(rs!DatumCas, "hh:nn:ss") & " [" & rs!TypUdalosti & "] " & rs!Krok & ": " & Nz(rs!Sprava, "") & vbCrLf
            rs.MoveNext
        Loop
        rs.Close
    End If
    If Len(s) = 0 Then s = "(žiadne)" & vbCrLf
    PoslednyChybyLog = s
End Function

'-------------------------------------------------------------------------------
' Zapíše verziu inštalačného balíka (podľa nej inštalátor rozpozná databázu v priečinku).
'-------------------------------------------------------------------------------
Public Function NastavVerziuBalika(ByVal strVerzia As String) As Boolean
    On Error GoTo Chyba
    Call mod_00_Common.SetNastavenie("VerziaBalika", Left$(strVerzia, 20), "Verzia inštalačného balíka (zapisuje inštalátor)")
    NastavVerziuBalika = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("NastavVerziuBalika", "ERROR", Err.Description)
End Function
