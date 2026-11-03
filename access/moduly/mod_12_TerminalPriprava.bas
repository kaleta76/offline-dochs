Attribute VB_Name = "mod_12_TerminalPriprava"
'@Verzia 1.2.0
Option Compare Database
Option Explicit

' Stĺpce Overenie a ZariadenieID v TerminalInbox sa dopĺňajú jednorazovo za reláciu (1.2.0).
Private mInboxPolia As Boolean

'===============================================================================
' MODUL: mod_12_TerminalPriprava
' POPIS: PRÍPRAVA vrstvy pre komunikáciu s terminálovou webovou aplikáciou (Lovable).
'        Komunikácia sa ZATIAĽ NEIMPLEMENTUJE - modul pripravuje len dátový model a
'        kontrakt, aby sa neskôr dal doplniť transport (API / súbor / tlač) bez zmeny jadra:
'
'          TERMINÁL -> ACCESS   tabuľka TerminalInbox (príjem razení)
'                               PrijmiRazenie()  zapíše razenie do inboxu (idempotentne podľa ExterneID)
'                               SpracujInbox()   prenesie nové razenia do DochadzkaImport
'          ACCESS -> TERMINÁL   tabuľka KonfiguraciaVerzie (verzie konfigurácie prerušení)
'                               GenerujKonfiguraciuJSON()      zostaví JSON bez osobných údajov
'                               VytvorVerziuKonfiguracie()     uloží novú verziu, ak sa konfigurácia zmenila
'                               ExportujKonfiguraciuDoSuboru() zápis do súboru (dočasný prenos)
'
'        Terminál nepozná osobné údaje: posiela len osobné číslo, čas, kód razenia a ID zariadenia.
'        Razenie sa nikdy nevkladá dvakrát (ExterneID), chyby ostanú v inboxe so stavom CHYBA.
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - ZabezpecTabulky(db)                        : Vytvorí TerminalInbox a KonfiguraciaVerzie.
' - PrijmiRazenie(...)                         : Príjem jedného razenia do inboxu (aj s príznakom overenia zariadenia a ID zariadenia).
' - AktualizujOverenie(externeID, overenie)    : Zmení príznak overenia už prijatého razenia (vedúci ho potvrdil v termináli).
' - SpracujInbox()                             : Prenos NOVE -> DochadzkaImport; vráti textový report.
' - GenerujKonfiguraciuJSON(rok)               : JSON konfigurácia (kódy, pravidlá, sviatky) bez osobných údajov.
' - VytvorVerziuKonfiguracie(autor)            : Uloží novú verziu konfigurácie; vráti jej číslo (0 = bez zmeny).
' - ExportujKonfiguraciuDoSuboru(priecinok)    : Uloží aktuálnu konfiguráciu do dochs_config.json.
'===============================================================================

Public Sub ZabezpecTabulky(ByRef db As DAO.Database)
    On Error GoTo Chyba
    If Not mod_00_Common.TabulkaExistujeDB(db, "TerminalInbox") Then
        db.Execute "CREATE TABLE TerminalInbox (ID AUTOINCREMENT PRIMARY KEY, PrijateKedy DATETIME, ExterneID TEXT(50), OsobneCislo TEXT(20), " & _
                   "CasRazenia DATETIME, KodRazenia LONG, Zariadenie TEXT(30), Payload LONGTEXT, Stav TEXT(10), Chyba TEXT(255), DatumSpracovania DATETIME)", dbFailOnError
        db.Execute "CREATE INDEX idxTI_ExterneID ON TerminalInbox (ExterneID)", dbFailOnError
        db.Execute "CREATE INDEX idxTI_Stav ON TerminalInbox (Stav)", dbFailOnError
        mInboxPolia = False
    End If
    If Not mInboxPolia Then
        ' jeden pokus za reláciu; ak sa pole nepodarí pridať, razenia sa prijímajú aj bez príznaku overenia (pozri PrijmiRazenie)
        mInboxPolia = True
        If Not mod_00_Common.PoleExistujeDB(db, "TerminalInbox", "Overenie") Then db.Execute "ALTER TABLE TerminalInbox ADD COLUMN Overenie TEXT(12)", dbFailOnError
        If Not mod_00_Common.PoleExistujeDB(db, "TerminalInbox", "ZariadenieID") Then db.Execute "ALTER TABLE TerminalInbox ADD COLUMN ZariadenieID TEXT(40)", dbFailOnError
    End If
    If Not mod_00_Common.TabulkaExistujeDB(db, "KonfiguraciaVerzie") Then
        db.Execute "CREATE TABLE KonfiguraciaVerzie (ID AUTOINCREMENT PRIMARY KEY, Verzia LONG, Vytvorene DATETIME, Autor TEXT(50), Obsah LONGTEXT, " & _
                   "Stav TEXT(12), DatumOdoslania DATETIME, DatumPotvrdenia DATETIME)", dbFailOnError
        db.Execute "CREATE INDEX idxKV_Verzia ON KonfiguraciaVerzie (Verzia)", dbFailOnError
    End If
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_12_TerminalPriprava.ZabezpecTabulky", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Zapíše razenie do inboxu. Vráti ID záznamu, 0 ak ide o duplicitu (rovnaké ExterneID) alebo -1 pri chybe.
'-------------------------------------------------------------------------------
Public Function PrijmiRazenie(ByVal strExterneID As String, ByVal strOC As String, ByVal dCas As Date, ByVal lKod As Long, _
                              Optional ByVal strZariadenie As String = "", Optional ByVal strPayload As String = "", _
                              Optional ByVal strOverenie As String = "", Optional ByVal strZariadenieID As String = "") As Long
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset
    Set db = CurrentDb
    Call ZabezpecTabulky(db)
    If Len(strExterneID) > 0 Then
        If DCount("*", "TerminalInbox", "ExterneID = " & mod_00_Common.SqlText(strExterneID)) > 0 Then Exit Function
    End If
    Set rs = db.OpenRecordset("TerminalInbox", dbOpenDynaset, dbAppendOnly)
    rs.AddNew
    rs!PrijateKedy = Now
    rs!ExterneID = Left$(strExterneID, 50)
    rs!OsobneCislo = Left$(Trim$(strOC), 20)
    rs!CasRazenia = dCas
    rs!KodRazenia = lKod
    rs!Zariadenie = Left$(strZariadenie, 30)
    If Len(strPayload) > 0 Then rs!Payload = strPayload
    If Len(strOverenie) > 0 Or Len(strZariadenieID) > 0 Then
        ' stĺpce pribudli v 1.2.0; ak ich nebolo možné pridať, razenie sa prijme aj bez príznaku
        On Error Resume Next
        rs!Overenie = Left$(strOverenie, 12)
        rs!ZariadenieID = Left$(strZariadenieID, 40)
        If Err.Number <> 0 Then
            Call mod_00_Common.ZapisLog("mod_12_TerminalPriprava.PrijmiRazenie", "WARN", "Príznak overenia zariadenia sa neuložil: " & Err.Description)
            Err.Clear
        End If
        On Error GoTo Chyba
    End If
    rs!Stav = "NOVE"
    PrijmiRazenie = rs!ID
    rs.Update
    rs.Close
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_12_TerminalPriprava.PrijmiRazenie", "ERROR", Err.Description)
    PrijmiRazenie = -1
End Function

'-------------------------------------------------------------------------------
' Zmení príznak overenia zariadenia už prijatého razenia (napr. unverified -> confirmed, keď ho vedúci potvrdil v termináli).
' Samotné razenie ani jeho spracovanie sa nemení. Vráti True, ak sa príznak zmenil.
'-------------------------------------------------------------------------------
Public Function AktualizujOverenie(ByVal strExterneID As String, ByVal strOverenie As String) As Boolean
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset
    If Len(strExterneID) = 0 Or Len(strOverenie) = 0 Then Exit Function
    Set db = CurrentDb
    If Not mod_00_Common.PoleExistujeDB(db, "TerminalInbox", "Overenie") Then Exit Function
    Set rs = db.OpenRecordset("SELECT ID, Overenie FROM TerminalInbox WHERE ExterneID = " & mod_00_Common.SqlText(strExterneID) & ";", dbOpenDynaset)
    If Not rs.EOF Then
        If Nz(rs!Overenie, "") <> Left$(strOverenie, 12) Then
            rs.Edit
            rs!Overenie = Left$(strOverenie, 12)
            rs.Update
            AktualizujOverenie = True
        End If
    End If
    rs.Close
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_12_TerminalPriprava.AktualizujOverenie", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Prenesie razenia so stavom NOVE do DochadzkaImport. Neznáme osobné číslo / kód -> stav CHYBA (ostáva v inboxe na riešenie).
' Rovnaké ExterneID už prenesené skôr sa nevloží druhýkrát.
'-------------------------------------------------------------------------------
Public Function SpracujInbox() As String
    On Error GoTo Chyba
    Dim db As DAO.Database, rsIn As DAO.Recordset, rsOut As DAO.Recordset, rsK As DAO.Recordset
    Dim nOK As Long, nDup As Long, nChyb As Long, nUz As Long, strOC As String, strErr As String, dCas As Date, lCislo As Long, strSmer As String

    Set db = CurrentDb
    Call ZabezpecTabulky(db)
    Call mod_01_SystemInit.MigrujDatovyModel(db)

    Set rsIn = db.OpenRecordset("SELECT * FROM TerminalInbox WHERE Stav = 'NOVE' ORDER BY CasRazenia, ID;", dbOpenDynaset)
    Set rsOut = db.OpenRecordset("DochadzkaImport", dbOpenDynaset)
    Do While Not rsIn.EOF
        strErr = ""
        strOC = Trim$(Nz(rsIn!OsobneCislo, ""))
        If IsNull(rsIn!CasRazenia) Then
            strErr = "Chýba čas razenia"
        ElseIf DCount("*", "Zamestnanci", "OsobneCislo = " & mod_00_Common.SqlText(strOC)) = 0 Then
            strErr = "Neznáme osobné číslo " & strOC
        ElseIf mod_18_Uzavierka.JeUzavretyDen(strOC, rsIn!CasRazenia) Then
            ' mesiac je uzavretý (podpísaný): razenie sa nevloží, počká v inboxe; po otvorení mesiaca sa vráti na spracovanie
            rsIn.Edit: rsIn!Stav = "UZAVRETY": rsIn!Chyba = Left$("Mesiac " & Month(CDate(rsIn!CasRazenia)) & "/" & Year(CDate(rsIn!CasRazenia)) & " je uzavretý", 255)
            rsIn!DatumSpracovania = Now: rsIn.Update
            nUz = nUz + 1
            GoTo Dalsi
        Else
            Set rsK = db.OpenRecordset("SELECT CisloPreruseni, Smer FROM KodyRazeni WHERE KodRazenia = " & CLng(Nz(rsIn!KodRazenia, 0)) & ";", dbOpenSnapshot)
            If rsK.EOF Then
                strErr = "Neznámy kód razenia " & Nz(rsIn!KodRazenia, 0)
            Else
                lCislo = CLng(rsK!CisloPreruseni)
                strSmer = CStr(rsK!Smer)
            End If
            rsK.Close
        End If

        If Len(strErr) = 0 Then
            If Len(Nz(rsIn!ExterneID, "")) > 0 Then
                If DCount("*", "DochadzkaImport", "ExterneID = " & mod_00_Common.SqlText(CStr(rsIn!ExterneID))) > 0 Then
                    rsIn.Edit: rsIn!Stav = "DUPLICITA": rsIn!DatumSpracovania = Now: rsIn.Update
                    nDup = nDup + 1
                    GoTo Dalsi
                End If
            End If
            dCas = CDate(rsIn!CasRazenia)
            rsOut.AddNew
            rsOut!Datum = DateValue(dCas)
            rsOut!Cas = Hour(dCas) * 60 + Minute(dCas)
            rsOut!OsobneCislo = strOC
            rsOut!KodPrerusenia = CLng(rsIn!KodRazenia)
            rsOut!CisloPreruseni = lCislo
            rsOut!Smer = strSmer
            rsOut!Platnost = True
            rsOut!Zdroj = 0
            rsOut!ZdrojZapisu = "TERMINAL"
            rsOut!ExterneID = Nz(rsIn!ExterneID, Null)
            rsOut!Zariadenie = Nz(rsIn!Zariadenie, Null)
            rsOut!DatumZmeny = Now
            rsOut.Update
            rsIn.Edit: rsIn!Stav = "SPRACOVANE": rsIn!DatumSpracovania = Now: rsIn!Chyba = Null: rsIn.Update
            nOK = nOK + 1
        Else
            rsIn.Edit: rsIn!Stav = "CHYBA": rsIn!Chyba = Left$(strErr, 255): rsIn!DatumSpracovania = Now: rsIn.Update
            nChyb = nChyb + 1
        End If
Dalsi:
        rsIn.MoveNext
    Loop
    rsIn.Close: rsOut.Close
    SpracujInbox = "Prenesené razenia: " & nOK & ", duplicity: " & nDup & ", chyby: " & nChyb & IIf(nUz > 0, ", do uzavretých mesiacov (nevložené): " & nUz, "")
    Call mod_00_Common.ZapisLog("SpracujInbox", "INFO", SpracujInbox)
    Exit Function
Chyba:
    SpracujInbox = "Chyba spracovania inboxu: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_12_TerminalPriprava.SpracujInbox", "ERROR", Err.Description)
End Function

Private Function J(ByVal s As String) As String
    J = """" & mod_00_Common.OsetriJSONText(s) & """"
End Function

Private Function JB(ByVal b As Boolean) As String
    JB = IIf(b, "true", "false")
End Function

'-------------------------------------------------------------------------------
' JSON konfigurácia pre terminál. OBSAHUJE: parametre výpočtu, číselník prerušení, kódy razení, sviatky.
' NEOBSAHUJE osobné údaje (mená, e-maily, oddelenia).
'-------------------------------------------------------------------------------
Public Function GenerujKonfiguraciuJSON(Optional ByVal iRok As Integer = 0) As String
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset, s As String, b As Boolean, r As Integer, dN As Date
    Dim dicSv As Object, k As Variant

    If iRok = 0 Then iRok = Year(Date)
    Set db = CurrentDb
    Call mod_08_UdalostiDna.ObnovParametre

    s = "{" & vbCrLf & "  ""schema_version"": 1," & vbCrLf
    s = s & "  ""config_version"": " & J(Format$(Now, "yyyy.mm.dd.hhnn")) & "," & vbCrLf
    s = s & "  ""rok"": " & iRok & "," & vbCrLf
    s = s & "  ""rules"": {" & vbCrLf
    s = s & "    ""work_window_start_min"": " & mod_08_UdalostiDna.PrmOknoOd() & "," & vbCrLf
    s = s & "    ""work_window_end_min"": " & mod_08_UdalostiDna.PrmOknoDo() & "," & vbCrLf
    s = s & "    ""full_day_obstacle_min"": " & mod_08_UdalostiDna.PrmCelodennaPrekazka() & "," & vbCrLf
    s = s & "    ""auto_lunch_trigger_min"": " & mod_08_UdalostiDna.PrmObedLimit() & "," & vbCrLf
    s = s & "    ""auto_lunch_deduct_min"": " & mod_08_UdalostiDna.PrmObedMin() & "," & vbCrLf
    s = s & "    ""auto_lunch_enabled"": " & JB(Not mod_00_Common.PravidloVypnute("AUTO_OBED_NAD_6H")) & "," & vbCrLf
    s = s & "    ""duplicate_punch_window_min"": " & mod_08_UdalostiDna.PrmDuplicitaLimit() & "," & vbCrLf
    s = s & "    ""default_daily_fund_min"": " & CLng(Val(mod_00_Common.GetNastavenie("PredvolenyFondMin", "450"))) & "," & vbCrLf
    s = s & "    ""auto_repair_mode"": " & mod_09_AutoOprava.RezimAutoOpravy() & vbCrLf
    s = s & "  }," & vbCrLf

    s = s & "  ""interruptions"": [" & vbCrLf
    If mod_00_Common.TabulkaExistujeDB(db, "CiselnikPreruseni") Then
        Dim bAuto As Boolean, bAK As Boolean
        bAuto = mod_00_Common.PoleExistujeDB(db, "CiselnikPreruseni", "AutoKoniecDoKoncaSmeny")
        Set rs = db.OpenRecordset("SELECT * FROM CiselnikPreruseni ORDER BY Cislo;", dbOpenSnapshot)
        b = True
        Do While Not rs.EOF
            If Not b Then s = s & "," & vbCrLf
            b = False
            bAK = False
            If bAuto Then bAK = CBool(Nz(rs!AutoKoniecDoKoncaSmeny, False))
            s = s & "    { ""code"": " & rs!Cislo & ", ""name"": " & J(CStr(Nz(rs!Nazov, ""))) & ", ""short_name"": " & J(CStr(Nz(rs!NazovSkratka, ""))) & _
                    ", ""start_punch_code"": " & CLng(Nz(rs!KodZaciatok, 0)) & ", ""end_punch_code"": " & CLng(Nz(rs!KodKoniec, 0)) & _
                    ", ""is_work"": " & JB(CLng(rs!Cislo) = 1) & ", ""is_lunch"": " & JB(CLng(rs!Cislo) = 7) & _
                    ", ""auto_end_of_shift"": " & JB(bAK) & " }"
            rs.MoveNext
        Loop
        rs.Close
    End If
    s = s & vbCrLf & "  ]," & vbCrLf

    s = s & "  ""punch_codes"": [" & vbCrLf
    If mod_00_Common.TabulkaExistujeDB(db, "KodyRazeni") Then
        Set rs = db.OpenRecordset("SELECT KodRazenia, CisloPreruseni, Smer, TextRazenia FROM KodyRazeni ORDER BY KodRazenia;", dbOpenSnapshot)
        b = True
        Do While Not rs.EOF
            If Not b Then s = s & "," & vbCrLf
            b = False
            s = s & "    { ""code"": " & rs!KodRazenia & ", ""interruption"": " & CLng(Nz(rs!CisloPreruseni, 0)) & ", ""direction"": " & J(CStr(Nz(rs!Smer, ""))) & ", ""label"": " & J(CStr(Nz(rs!TextRazenia, ""))) & " }"
            rs.MoveNext
        Loop
        rs.Close
    End If
    s = s & vbCrLf & "  ]," & vbCrLf

    ' sviatky na rok a rok + 1 (pevné + pohyblivé podľa stĺpca Rok)
    Set dicSv = CreateObject("Scripting.Dictionary")
    If mod_00_Common.TabulkaExistujeDB(db, "Sviatky") Then
        Dim bRok As Boolean
        bRok = mod_00_Common.PoleExistujeDB(db, "Sviatky", "Rok")
        For r = iRok To iRok + 1
            Set rs = db.OpenRecordset("SELECT Den, Mesiac, Nazov FROM Sviatky" & IIf(bRok, " WHERE Rok IS NULL OR Rok = " & r, "") & ";", dbOpenSnapshot)
            Do While Not rs.EOF
                On Error Resume Next
                dicSv(Format$(DateSerial(r, CLng(rs!Mesiac), CLng(rs!Den)), "yyyy-mm-dd")) = CStr(Nz(rs!Nazov, ""))
                On Error GoTo Chyba
                rs.MoveNext
            Loop
            rs.Close
        Next r
    End If
    s = s & "  ""holidays"": ["
    b = True
    For Each k In dicSv.Keys
        s = s & IIf(b, "", ", ") & "{ ""date"": " & J(CStr(k)) & ", ""name"": " & J(CStr(dicSv(k))) & " }"
        b = False
    Next k
    s = s & "]" & vbCrLf & "}"
    GenerujKonfiguraciuJSON = s
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_12_TerminalPriprava.GenerujKonfiguraciuJSON", "ERROR", Err.Description)
    GenerujKonfiguraciuJSON = "{}"
End Function

'-------------------------------------------------------------------------------
' Porovnateľný obsah bez premenlivých polí (config_version) na zistenie, či sa konfigurácia zmenila.
'-------------------------------------------------------------------------------
Private Function BezVerzie(ByVal strJson As String) As String
    Dim p1 As Long, p2 As Long
    p1 = InStr(strJson, """config_version""")
    If p1 > 0 Then
        p2 = InStr(p1, strJson, vbCrLf)
        If p2 > p1 Then strJson = Left$(strJson, p1 - 1) & Mid$(strJson, p2)
    End If
    BezVerzie = strJson
End Function

'-------------------------------------------------------------------------------
' Uloží novú verziu konfigurácie, ak sa od poslednej uloženej zmenila. Vráti číslo novej verzie (0 = bez zmeny, -1 = chyba).
'-------------------------------------------------------------------------------
Public Function VytvorVerziuKonfiguracie(Optional ByVal strAutor As String = "") As Long
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset, strNovy As String, lPoslednaVerzia As Long, strPosledny As String
    Set db = CurrentDb
    Call ZabezpecTabulky(db)
    strNovy = GenerujKonfiguraciuJSON()
    lPoslednaVerzia = CLng(Nz(DMax("Verzia", "KonfiguraciaVerzie"), 0))
    If lPoslednaVerzia > 0 Then
        Set rs = db.OpenRecordset("SELECT Obsah FROM KonfiguraciaVerzie WHERE Verzia = " & lPoslednaVerzia & ";", dbOpenSnapshot)
        If Not rs.EOF Then strPosledny = CStr(Nz(rs!Obsah, ""))
        rs.Close
        If BezVerzie(strPosledny) = BezVerzie(strNovy) Then Exit Function
    End If
    Set rs = db.OpenRecordset("KonfiguraciaVerzie", dbOpenDynaset, dbAppendOnly)
    rs.AddNew
    rs!Verzia = lPoslednaVerzia + 1
    rs!Vytvorene = Now
    rs!Autor = Left$(IIf(Len(strAutor) > 0, strAutor, mod_00_Common.Uzivatel()), 50)
    rs!Obsah = strNovy
    rs!Stav = "PRIPRAVENA"
    rs.Update
    rs.Close
    VytvorVerziuKonfiguracie = lPoslednaVerzia + 1
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_12_TerminalPriprava.VytvorVerziuKonfiguracie", "ERROR", Err.Description)
    VytvorVerziuKonfiguracie = -1
End Function

'-------------------------------------------------------------------------------
' Uloží aktuálnu konfiguráciu do súboru dochs_config.json v zadanom priečinku (dočasný prenos do terminálu).
'-------------------------------------------------------------------------------
Public Function ExportujKonfiguraciuDoSuboru(Optional ByVal strPriecinok As String = "") As String
    On Error GoTo Chyba
    Dim strCesta As String
    If Len(strPriecinok) = 0 Then strPriecinok = CurrentProject.Path
    If Right$(strPriecinok, 1) <> "\" Then strPriecinok = strPriecinok & "\"
    strCesta = strPriecinok & "dochs_config.json"
    Call mod_00_Common.UlozUTF8Sustor(strCesta, GenerujKonfiguraciuJSON())
    Call VytvorVerziuKonfiguracie()
    ExportujKonfiguraciuDoSuboru = strCesta
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_12_TerminalPriprava.ExportujKonfiguraciuDoSuboru", "ERROR", Err.Description)
End Function
