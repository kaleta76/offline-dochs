Attribute VB_Name = "mod_00_Common"
'@Verzia 2.7.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_00_Common
' POPIS: Zdieľané pomocné funkcie, logovanie, správa nastavení, exkluzívny prístup,
'        správa priebehu (Progress GUI), detekcia schémy DB/citlivých polí,
'        bezpečné čítanie/zápis DAO polí, export metadát tabuliek (JSON) a Win32 API.
'===============================================================================

#If VBA7 Then
    Public Declare PtrSafe Sub CopyMemory Lib "kernel32" Alias "RtlMoveMemory" ( _
        Destination As Any, Source As Any, ByVal Length As LongPtr)
#Else
    Public Declare Sub CopyMemory Lib "kernel32" Alias "RtlMoveMemory" ( _
        Destination As Any, Source As Any, ByVal Length As Long)
#End If


'===============================================================================
' ZDIEĽANÉ POMOCNÉ FUNKCIE (jediné miesto pre SQL literály, čas a parametre)
'===============================================================================

'-------------------------------------------------------------------------------
' Vráti dátum ako bezpečný SQL literál pre Jet/ACE (#mm/dd/yyyy#).
'-------------------------------------------------------------------------------
Public Function SqlDatum(ByVal d As Date) As String
    SqlDatum = "#" & Format$(d, "mm\/dd\/yyyy") & "#"
End Function

'-------------------------------------------------------------------------------
' Vráti text ako bezpečný SQL literál (apostrofy zdvojené).
'-------------------------------------------------------------------------------
Public Function SqlText(ByVal s As String) As String
    SqlText = "'" & Replace(s, "'", "''") & "'"
End Function

'-------------------------------------------------------------------------------
' Vráti SQL podmienku "platný záznam" (NULL sa berie ako platný) - jediná definícia pre všetky moduly.
'-------------------------------------------------------------------------------
Public Function SqlPlatne(Optional ByVal strAlias As String = "") As String
    Dim p As String
    If Len(strAlias) > 0 Then p = strAlias & "."
    SqlPlatne = "(" & p & "Platnost IS NULL OR " & p & "Platnost = True)"
End Function

'-------------------------------------------------------------------------------
' Vráti meno prihláseného používateľa (max 50 znakov) pre audit zmien.
'-------------------------------------------------------------------------------
Public Function Uzivatel() As String
    Dim s As String
    s = Trim$(Environ$("USERNAME"))
    If Len(s) = 0 Then s = "admin"
    Uzivatel = Left$(s, 50)
End Function

'-------------------------------------------------------------------------------
' Prevedie text času ("7:05", "07.05", "705", "1730") na minúty od polnoci; neplatný vstup vráti -1.
'-------------------------------------------------------------------------------
Public Function CasNaMinuty(ByVal strCas As String) As Long
    Dim t As String, h As Long, m As Long, p As Long
    t = Trim$(strCas)
    CasNaMinuty = -1
    If Len(t) = 0 Then Exit Function
    t = Replace(Replace(t, ".", ":"), ",", ":")
    p = InStr(t, ":")
    If p > 0 Then
        If Not (IsNumeric(Left$(t, p - 1)) And IsNumeric(Mid$(t, p + 1))) Then Exit Function
        h = CLng(Left$(t, p - 1)): m = CLng(Mid$(t, p + 1))
    Else
        If Not IsNumeric(t) Then Exit Function
        If Len(t) <= 2 Then
            h = CLng(t): m = 0
        Else
            h = CLng(Left$(t, Len(t) - 2)): m = CLng(Right$(t, 2))
        End If
    End If
    If h < 0 Or h > 24 Or m < 0 Or m > 59 Then Exit Function
    CasNaMinuty = h * 60 + m
End Function

'-------------------------------------------------------------------------------
' Z textu parametrov v tvare "Kluc1=Hodnota1; Kluc2=Hodnota2" vráti hodnotu kľúča (alebo predvolenú).
'-------------------------------------------------------------------------------
Public Function ParamKV(ByVal strParametre As String, ByVal strKluc As String, Optional ByVal strDefault As String = "") As String
    Dim a() As String, i As Long, p As Long
    ParamKV = strDefault
    If Len(strParametre) = 0 Then Exit Function
    a = Split(strParametre, ";")
    For i = LBound(a) To UBound(a)
        p = InStr(a(i), "=")
        If p > 0 Then
            If StrComp(Trim$(Left$(a(i), p - 1)), strKluc, vbTextCompare) = 0 Then
                ParamKV = Trim$(Mid$(a(i), p + 1))
                Exit Function
            End If
        End If
    Next i
End Function

'-------------------------------------------------------------------------------
' Vráti parameter aktívneho pravidla z CiselnikPravidielAnomalii (stĺpec Parametre) alebo predvolenú hodnotu.
'-------------------------------------------------------------------------------
Public Function ParamPravidla(ByVal strKodPravidla As String, ByVal strKluc As String, Optional ByVal strDefault As String = "") As String
    On Error GoTo Chyba
    Dim rs As DAO.Recordset
    ParamPravidla = strDefault
    Set rs = CurrentDb.OpenRecordset("SELECT Parametre FROM CiselnikPravidielAnomalii WHERE KodAnomalie=" & SqlText(strKodPravidla), dbOpenSnapshot)
    If Not rs.EOF Then ParamPravidla = ParamKV(CStr(Nz(rs!Parametre, "")), strKluc, strDefault)
    rs.Close
    Exit Function
Chyba:
    ParamPravidla = strDefault
End Function

'-------------------------------------------------------------------------------
' Vráti True, ak pravidlo v číselníku existuje a je vypnuté (Aktivne = False); pri chýbajúcom pravidle vráti False.
'-------------------------------------------------------------------------------
Public Function PravidloVypnute(ByVal strKodPravidla As String) As Boolean
    On Error GoTo Chyba
    Dim rs As DAO.Recordset
    Set rs = CurrentDb.OpenRecordset("SELECT Aktivne FROM CiselnikPravidielAnomalii WHERE KodAnomalie=" & SqlText(strKodPravidla), dbOpenSnapshot)
    If Not rs.EOF Then PravidloVypnute = Not CBool(Nz(rs!Aktivne, True))
    rs.Close
    Exit Function
Chyba:
    PravidloVypnute = False
End Function

'-------------------------------------------------------------------------------
' Vráti limit pravidla (CasovyLimitMin) alebo predvolenú hodnotu, ak pravidlo nie je aktívne/neexistuje.
'-------------------------------------------------------------------------------
Public Function LimitPravidla(ByVal strKodPravidla As String, ByVal lDefault As Long) As Long
    On Error GoTo Chyba
    Dim rs As DAO.Recordset
    LimitPravidla = lDefault
    Set rs = CurrentDb.OpenRecordset("SELECT CasovyLimitMin FROM CiselnikPravidielAnomalii WHERE Aktivne=True AND KodAnomalie=" & SqlText(strKodPravidla), dbOpenSnapshot)
    If Not rs.EOF Then
        If Not IsNull(rs!CasovyLimitMin) Then LimitPravidla = CLng(rs!CasovyLimitMin)
    End If
    rs.Close
    Exit Function
Chyba:
    LimitPravidla = lDefault
End Function

'-------------------------------------------------------------------------------
' Bleskový SQL dotaz pre zoznam zamestnancov s možnosťou filtrácie podľa razení v období.
'-------------------------------------------------------------------------------
Public Function ZiskajSQLZoznamZamestnancov(Optional ByVal dtOd As Variant = Null, Optional ByVal dtDo As Variant = Null) As String
    On Error Resume Next
    Dim strSQL As String, strSQLFiltered As String
    Dim db As DAO.Database, rsCheck As DAO.Recordset

    Set db = CurrentDb

    If IsDate(dtOd) And IsDate(dtDo) And TabulkaExistujeDB(db, "DochadzkaImport") Then
        strSQLFiltered = "SELECT DISTINCT Z.OsobneCislo, Z.OsobneCislo & ' - ' & Nz(Z.Priezvisko & ' ' & Z.Meno, Nz(Z.CeleMeno, 'Zamestnanec ' & Z.OsobneCislo)) AS CeleMeno " & _
                         "FROM Zamestnanci AS Z INNER JOIN DochadzkaImport AS I ON CStr(Z.OsobneCislo) = CStr(I.OsobneCislo) " & _
                         "WHERE I.Datum >= #" & Format$(CDate(dtOd), "yyyy\-mm\-dd") & "# AND I.Datum <= #" & Format$(CDate(dtDo), "yyyy\-mm\-dd") & "# " & _
                         "AND " & mod_15_Zamestnanci.SqlAktivny("Z", CDate(dtOd)) & " " & _
                         "ORDER BY Z.OsobneCislo;"

        Set rsCheck = db.OpenRecordset(strSQLFiltered, dbOpenSnapshot)
        If Not rsCheck Is Nothing Then
            If Not rsCheck.EOF Then
                ZiskajSQLZoznamZamestnancov = strSQLFiltered
                rsCheck.Close: Set rsCheck = Nothing: Set db = Nothing
                Exit Function
            End If
            rsCheck.Close: Set rsCheck = Nothing
        End If
    End If

    strSQL = "SELECT OsobneCislo, OsobneCislo & ' - ' & Nz(Priezvisko & ' ' & Meno, Nz(CeleMeno, 'Zamestnanec ' & OsobneCislo)) AS CeleMeno " & _
             "FROM Zamestnanci WHERE OsobneCislo IS NOT NULL AND " & mod_15_Zamestnanci.SqlAktivny("", IIf(IsDate(dtOd), CDate(dtOd), Date)) & _
             " ORDER BY OsobneCislo;"

    Set db = Nothing
    ZiskajSQLZoznamZamestnancov = strSQL
End Function

'-------------------------------------------------------------------------------
' Vráti čiarkou oddelený reťazec vybraných osobných čísel z ListBoxu pre SQL WHERE IN (...).
'-------------------------------------------------------------------------------
Public Function ZiskajVybraneOsobneCislaListBox(ByRef lst As Access.ListBox) As String
    On Error Resume Next
    Dim varItem As Variant, strRes As String
    If lst Is Nothing Or lst.ItemsSelected.Count = 0 Then
        ZiskajVybraneOsobneCislaListBox = ""
        Exit Function
    End If

    For Each varItem In lst.ItemsSelected
        If Len(strRes) > 0 Then strRes = strRes & ", "
        strRes = strRes & "'" & Replace(lst.ItemData(varItem), "'", "''") & "'"
    Next varItem
    ZiskajVybraneOsobneCislaListBox = strRes
End Function

'-------------------------------------------------------------------------------
' Kontroluje, či konkrétne pole existuje v zadanej databázovej tabuľke.
'-------------------------------------------------------------------------------
Public Function PoleExistujeDB(ByRef db As DAO.Database, ByVal strTabulka As String, ByVal strPole As String) As Boolean
    On Error Resume Next
    Dim fld As DAO.Field
    Err.Clear
    Set fld = db.TableDefs(strTabulka).Fields(strPole)
    PoleExistujeDB = (Err.Number = 0)
    Err.Clear
End Function

'-------------------------------------------------------------------------------
' Kontroluje, či v MS Access projekte existuje formulár so zadaným názvom.
'-------------------------------------------------------------------------------
Public Function FormularExistujeDB(ByVal strFormName As String) As Boolean
    On Error Resume Next
    Dim obj As Object
    Set obj = CurrentProject.AllForms(strFormName)
    FormularExistujeDB = Not (obj Is Nothing)
    Err.Clear
End Function

'-------------------------------------------------------------------------------
' Preváda počet minút na formátovaný časový text HH:MM.
'-------------------------------------------------------------------------------
Public Function MinutyNaCasText(ByVal lMinuty As Long) As String
    If lMinuty < 0 Then lMinuty = 0
    MinutyNaCasText = Format(lMinuty \ 60, "00") & ":" & Format(lMinuty Mod 60, "00")
End Function

'-------------------------------------------------------------------------------
' Preváda počet minút na formátovaný časový text HH:MM (alias k MinutyNaCasText).
'-------------------------------------------------------------------------------
Public Function FormatCasMin(ByVal lMinuty As Long) As String
    FormatCasMin = MinutyNaCasText(lMinuty)
End Function

'-------------------------------------------------------------------------------
' Kontroluje, či v databáze existuje tabuľka so zadaným názvom.
'-------------------------------------------------------------------------------
Public Function TabulkaExistujeDB(ByRef db As DAO.Database, ByVal strTabulka As String) As Boolean
    On Error Resume Next
    Dim tdf As DAO.TableDef
    Err.Clear
    Set tdf = db.TableDefs(strTabulka)
    TabulkaExistujeDB = (Err.Number = 0)
    Err.Clear
End Function

'-------------------------------------------------------------------------------
' Zisťuje prítomnosť tabuľky v aktuálnej databáze CurrentDb.
'-------------------------------------------------------------------------------
Public Function TabulkaExistuje(ByVal NazovTabulky As String) As Boolean
    On Error Resume Next
    Dim db As DAO.Database
    Set db = CurrentDb
    db.TableDefs.Refresh
    TabulkaExistuje = TabulkaExistujeDB(db, NazovTabulky)
    Set db = Nothing
End Function

'-------------------------------------------------------------------------------
' Bezpečne načíta hodnotu poľa z DAO recordsetu vrátane fallbacku pri NULL alebo neexistujúcom poli.
'-------------------------------------------------------------------------------
Public Function ZiskajHodnotuPola(ByRef rs As DAO.Recordset, ByVal strPoleNazov As String, Optional ByVal vDefault As Variant = Null) As Variant
    On Error Resume Next
    ZiskajHodnotuPola = vDefault
    If rs Is Nothing Then Exit Function
    Dim vVal As Variant
    vVal = rs.Fields(strPoleNazov).Value
    If Err.Number = 0 Then
        If Not IsNull(vVal) Then ZiskajHodnotuPola = vVal
    End If
    Err.Clear
End Function

'-------------------------------------------------------------------------------
' Bezpečne načíta hodnotu z prvého existujúceho poľa zo zoznamu názvov (napr. rôzne verzie schémy).
'-------------------------------------------------------------------------------
Public Function ZiskajHodnotuPolaViac(ByRef rs As DAO.Recordset, ByVal varNazvyPoli As Variant, Optional ByVal vDefault As Variant = Null) As Variant
    On Error Resume Next
    ZiskajHodnotuPolaViac = vDefault
    If rs Is Nothing Then Exit Function
    Dim i As Long, vVal As Variant
    For i = LBound(varNazvyPoli) To UBound(varNazvyPoli)
        Err.Clear
        vVal = rs.Fields(CStr(varNazvyPoli(i))).Value
        If Err.Number = 0 Then
            If Not IsNull(vVal) Then
                ZiskajHodnotuPolaViac = vVal
                Exit Function
            End If
        End If
    Next i
    Err.Clear
End Function

'-------------------------------------------------------------------------------
' Bezpečne zapíše hodnotu do poľa DAO recordsetu.
'-------------------------------------------------------------------------------
Public Sub NastavHodnotuPola(ByRef rs As DAO.Recordset, ByVal strPoleNazov As String, ByVal vHodnota As Variant)
    On Error Resume Next
    If rs Is Nothing Then Exit Sub
    rs.Fields(strPoleNazov).Value = vHodnota
    Err.Clear
End Sub

'-------------------------------------------------------------------------------
' Vrací slovenský názov mesiaca podľa jeho poradového čísla (1-12).
'-------------------------------------------------------------------------------
Public Function NazovMesiacaSlovensky(ByVal iMesiac As Integer) As String
    Dim arrMesiace As Variant
    arrMesiace = Array("", "Január", "Február", "Marec", "Apríl", "Máj", "Jún", "Júl", "August", "September", "Október", "November", "December")
    If iMesiac >= 1 And iMesiac <= 12 Then
        NazovMesiacaSlovensky = arrMesiace(iMesiac)
    Else
        NazovMesiacaSlovensky = ""
    End If
End Function

'-------------------------------------------------------------------------------
' Ukladá textový obsah do súboru v kódovaní UTF-8 pomocou ADODB.Stream.
'-------------------------------------------------------------------------------
Public Sub UlozUTF8Sustor(ByVal filePath As String, ByVal obsah As String)
    Dim stream As Object
    Set stream = CreateObject("ADODB.Stream")
    stream.Type = 2: stream.Charset = "utf-8": stream.Open
    stream.WriteText obsah, 1
    stream.SaveToFile filePath, 2
    stream.Close: Set stream = Nothing
End Sub

'-------------------------------------------------------------------------------
' Ošetruje špeciálne znaky pre korektný JSON výstup (úvodzovky, spätné lomítka, odriadkovania).
'-------------------------------------------------------------------------------
Public Function OsetriJSONText(ByVal strInput As String) As String
    strInput = Replace(strInput, "\", "\\")
    strInput = Replace(strInput, """", "\""")
    strInput = Replace(strInput, vbCr, "")
    strInput = Replace(strInput, vbLf, "")
    OsetriJSONText = strInput
End Function

'-------------------------------------------------------------------------------
' Pripraví a overí cieľový adresár pre exporty. Ak neexistuje, vytvorí ho.
'-------------------------------------------------------------------------------
Public Function PripravAdresarExportu(ByVal Folder As String) As String
    Dim f As String
    If Len(Folder) > 0 Then f = Folder Else f = CurrentProject.Path & "\Export_Access_CSV\"
    If Right$(f, 1) <> "\" Then f = f & "\"
    If Dir(f, vbDirectory) = "" Then MkDir f
    PripravAdresarExportu = f
End Function

'-------------------------------------------------------------------------------
' Testuje, či je tabuľka používateľská (ignoruje systémové tabuľky MSys* a dočasné tabuľky).
'-------------------------------------------------------------------------------
Public Function JeUzivatelskaTabulka(ByVal tdf As DAO.TableDef) As Boolean
    JeUzivatelskaTabulka = ((tdf.Attributes And dbSystemObject) = 0 And Left$(tdf.Name, 4) <> "MSys" And Left$(tdf.Name, 1) <> "~")
End Function

'-------------------------------------------------------------------------------
' Testuje, či názov poľa obsahuje citlivé osobné údaje pre anonymizáciu (GDPR).
'-------------------------------------------------------------------------------
Public Function JeCitlivePole(ByVal nazovPola As String) As Boolean
    Dim fn As String, i As Long, vzory As Variant
    fn = UCase$(nazovPola)
    vzory = Array("MENO", "PRIEZV", "TITUL", "RODNE", "RODCIS", "MAIL", "TELEF", "MOBIL", "ADRES", "ULICA", "MANAGERDN", "POPISAD", "UZIVATEL")
    For i = LBound(vzory) To UBound(vzory)
        If InStr(fn, CStr(vzory(i))) > 0 Then JeCitlivePole = True: Exit Function
    Next i
End Function

'-------------------------------------------------------------------------------
' Exportuje metadáta a schému všetkých používateľských tabuliek do súboru JSON.
'-------------------------------------------------------------------------------
Public Function ExportovatMetadataTabuliek(Optional ByVal strCestaSuboru As String = "") As String
    On Error GoTo ChybaHandler
    Dim db As DAO.Database, tdf As DAO.TableDef, fld As DAO.Field, iFile As Integer, strPath As String
    Set db = CurrentDb

    If Len(Trim$(strCestaSuboru)) = 0 Then
        strPath = PripravAdresarExportu("") & "Schema_Metadata_" & Format(Now, "yyyy-mm-dd_hhnnss") & ".json"
    Else
        strPath = strCestaSuboru
    End If

    iFile = FreeFile
    Open strPath For Output As #iFile

    Print #iFile, "{"
    Print #iFile, "  ""Database"": """ & Replace(db.Name, "\", "\\") & ""","
    Print #iFile, "  ""ExportDate"": """ & Format(Now, "yyyy-mm-dd hh:nn:ss") & ""","
    Print #iFile, "  ""Tables"": ["

    Dim bFirstTable As Boolean: bFirstTable = True
    For Each tdf In db.TableDefs
        If JeUzivatelskaTabulka(tdf) Then
            If Not bFirstTable Then Print #iFile, "    ,"
            bFirstTable = False

            Print #iFile, "    {"
            Print #iFile, "      ""TableName"": """ & tdf.Name & ""","
            Print #iFile, "      ""RowCount"": " & tdf.RecordCount & ","
            Print #iFile, "      ""Fields"": ["

            Dim bFirstField As Boolean: bFirstField = True
            For Each fld In tdf.Fields
                If Not bFirstField Then Print #iFile, "        ,"
                bFirstField = False

                Print #iFile, "        {"
                Print #iFile, "          ""Name"": """ & OsetriJSONText(fld.Name) & ""","
                Print #iFile, "          ""Type"": """ & PrevedTypPolaNaText(fld.Type) & ""","
                Print #iFile, "          ""Size"": " & fld.Size & ","
                Print #iFile, "          ""Required"": " & LCase$(CStr(fld.Required))
                Print #iFile, "        }"
            Next fld

            Print #iFile, "      ]"
            Print #iFile, "    }"
        End If
    Next tdf

    Print #iFile, "  ]"
    Print #iFile, "}"

    Close #iFile
    Set db = Nothing
    ExportovatMetadataTabuliek = strPath
    Exit Function

ChybaHandler:
    If iFile > 0 Then Close #iFile
    ExportovatMetadataTabuliek = ""
    MsgBox "Chyba pri exporte metadát: " & Err.Description, vbCritical
End Function

'-------------------------------------------------------------------------------
' Preváda číselný DAO typ poľa na čitateľný textový popis.
'-------------------------------------------------------------------------------
Private Function PrevedTypPolaNaText(ByVal iType As Integer) As String
    Select Case iType
        Case dbBoolean: PrevedTypPolaNaText = "Boolean"
        Case dbByte: PrevedTypPolaNaText = "Byte"
        Case dbInteger: PrevedTypPolaNaText = "Integer"
        Case dbLong: PrevedTypPolaNaText = "Long"
        Case dbCurrency: PrevedTypPolaNaText = "Currency"
        Case dbSingle: PrevedTypPolaNaText = "Single"
        Case dbDouble: PrevedTypPolaNaText = "Double"
        Case dbDate: PrevedTypPolaNaText = "DateTime"
        Case dbText: PrevedTypPolaNaText = "Text"
        Case dbLongBinary: PrevedTypPolaNaText = "OLEObject"
        Case dbMemo: PrevedTypPolaNaText = "LongText/Memo"
        Case dbGUID: PrevedTypPolaNaText = "GUID"
        Case Else: PrevedTypPolaNaText = "Unknown(" & iType & ")"
    End Select
End Function

'-------------------------------------------------------------------------------
' Testuje, či má používateľ exkluzívny prístup k databázovému súboru.
'-------------------------------------------------------------------------------
Public Function SkontrolujExkluzivnyPristup() As Boolean
    On Error Resume Next
    Dim dbTest As DAO.Database
    Err.Clear
    Set dbTest = DBEngine.OpenDatabase(CurrentProject.FullName, True)
    If Err.Number <> 0 Then
        SkontrolujExkluzivnyPristup = False
    Else
        dbTest.Close
        Set dbTest = Nothing
        SkontrolujExkluzivnyPristup = True
    End If
End Function

'-------------------------------------------------------------------------------
' Nastavuje príznak režimu údržby databázy v systémových nastaveniach.
'-------------------------------------------------------------------------------
Public Sub NastavRezimUdrzby(ByVal Zapnut As Boolean)
    Call mod_00_Common.SetNastavenie("RezimUdrzby", IIf(Zapnut, "TRUE", "FALSE"), "Indikátor prebiehajúceho importu/údržby databázy")
End Sub

'-------------------------------------------------------------------------------
' Zisťuje, či je databáza momentálne v režime údržby.
'-------------------------------------------------------------------------------
Public Function JeRezimUdrzby() As Boolean
    JeRezimUdrzby = (UCase$(Trim(mod_00_Common.GetNastavenie("RezimUdrzby", "FALSE"))) = "TRUE")
End Function

'-------------------------------------------------------------------------------
' Vymaže všetky tabuľky, formuláre a zostavy pri priprave čistej databázy (moduly zostanú).
'-------------------------------------------------------------------------------
Private Sub VymazVsetkyObjektyOkremModulov()
    On Error Resume Next
    Dim db As DAO.Database, tdf As DAO.TableDef, i As Long
    Set db = CurrentDb

    If MsgBox("Naozaj chcete vymazať všetky tabuľky a formuláre a pripraviť čistú DB?", vbQuestion + vbYesNo, "Vyčistenie DB") <> vbYes Then Exit Sub

    DoCmd.Close acForm, "frmSprievodcaImportom", acSaveNo
    DoCmd.Close acForm, "frmProgress", acSaveNo

    For i = CurrentProject.AllForms.Count - 1 To 0 Step -1
        DoCmd.DeleteObject acForm, CurrentProject.AllForms(i).Name
    Next i

    For i = CurrentProject.AllReports.Count - 1 To 0 Step -1
        DoCmd.DeleteObject acReport, CurrentProject.AllReports(i).Name
    Next i

    For i = db.TableDefs.Count - 1 To 0 Step -1
        Set tdf = db.TableDefs(i)
        If (tdf.Attributes And dbSystemObject) = 0 And Left$(tdf.Name, 4) <> "MSys" Then
            DoCmd.DeleteObject acTable, tdf.Name
        End If
    Next i

    DBEngine.Idle dbRefreshCache
    MsgBox "Databáza bola úspešne vyčistená. Moduly zostali zachované.", vbInformation, "Hotovo"
End Sub

'-------------------------------------------------------------------------------
' Centrálny zápis systémových udalostí a chýb do tabuľky LogImportu.
'-------------------------------------------------------------------------------
Public Sub ZapisLog(ByVal Krok As String, ByVal TypUdalosti As String, ByVal Sprava As String, Optional ByVal Detail As String = "")
    On Error Resume Next
    Dim sql As String
    
    Sprava = Replace(Left$(Sprava, 255), "'", "''")
    Detail = Replace(Detail, "'", "''")
    
    sql = "INSERT INTO LogImportu (DatumCas, Krok, TypUdalosti, Sprava, Detail) VALUES (" & _
          "#" & Format$(Now, "yyyy\-mm\-dd hh:nn:ss") & "#, " & _
          "'" & Replace(Left$(Krok, 50), "'", "''") & "', " & _
          "'" & Replace(Left$(TypUdalosti, 20), "'", "''") & "', " & _
          "'" & Sprava & "', " & _
          "'" & Detail & "')"
          
    CurrentDb.Execute sql, dbFailOnError
    
    If mod_00_Common.FormIsOpen("frmSprievodcaImportom") Then
        Forms!frmSprievodcaImportom!txtStavInfo = "[" & TypUdalosti & "][" & Krok & "] " & Replace(Sprava, "''", "'")
    End If
    ' stavový riadok hlavnej konzoly - používateľ vidí, čo sa práve deje (aj chyby, ktoré sa inak len zapíšu do logu)
    If mod_00_Common.FormIsOpen("frmHlavnaKonzola") Then
        Forms!frmHlavnaKonzola!txtMainStatus = Format$(Now, "hh:nn:ss") & "  [" & TypUdalosti & "] " & Krok & ": " & Replace(Sprava, "''", "'")
    End If
    Debug.Print "[" & Format$(Now, "hh:nn:ss") & "][" & Krok & "][" & TypUdalosti & "] " & Sprava
End Sub

'-------------------------------------------------------------------------------
' Načíta hodnotu systémového nastavenia z tabuľky NastaveniaSystemu.
'-------------------------------------------------------------------------------
Public Function GetNastavenie(ByVal kluc As String, Optional ByVal DefaultHodnota As String = "") As String
    On Error Resume Next
    Dim rs As DAO.Recordset
    Set rs = CurrentDb.OpenRecordset("SELECT Hodnota FROM NastaveniaSystemu WHERE Kluc=" & SqlText(kluc), dbOpenSnapshot)
    If Not rs Is Nothing Then
        If Not rs.EOF Then GetNastavenie = CStr(Nz(rs!Hodnota, DefaultHodnota)) Else GetNastavenie = DefaultHodnota
        rs.Close
        Set rs = Nothing
    Else
        GetNastavenie = DefaultHodnota
    End If
End Function

'-------------------------------------------------------------------------------
' Zapisuje alebo aktualizuje hodnotu kľúča v tabuľke NastaveniaSystemu.
'-------------------------------------------------------------------------------
Public Sub SetNastavenie(ByVal kluc As String, ByVal Hodnota As String, Optional ByVal popis As String = "")
    On Error GoTo ChybaHandler
    Dim db As DAO.Database, rs As DAO.Recordset
    Set db = CurrentDb
    If Not TabulkaExistujeDB(db, "NastaveniaSystemu") Then Exit Sub

    Set rs = db.OpenRecordset("SELECT * FROM NastaveniaSystemu WHERE Kluc=" & SqlText(kluc), dbOpenDynaset)
    If rs.EOF Then
        rs.AddNew
        rs!kluc = kluc
    Else
        rs.Edit
    End If
    rs!Hodnota = Left$(Hodnota, 255)
    If Len(popis) > 0 Then rs!popis = Left$(popis, 255)
    rs.Update
    rs.Close
    Set rs = Nothing
    Exit Sub
ChybaHandler:
    Call ZapisLog("SetNastavenie", "ERROR", "Chyba zápisu nastavenia " & kluc & ": " & Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Načíta číslo posledného dokončeného kroku sprievodcu importom.
'-------------------------------------------------------------------------------
Public Function GetPoslednyKrok() As Long
    GetPoslednyKrok = Val(mod_00_Common.GetNastavenie("PoslednyKrok", "0"))
End Function

'-------------------------------------------------------------------------------
' Ukladá číslo posledného dokončeného kroku sprievodcu importom.
'-------------------------------------------------------------------------------
Public Sub SetPoslednyKrok(ByVal Krok As Long)
    Call mod_00_Common.SetNastavenie("PoslednyKrok", CStr(Krok), "Posledný dokončený krok importu")
End Sub

'-------------------------------------------------------------------------------
' Zisťuje, či je v systéme uzamknutý import dát.
'-------------------------------------------------------------------------------
Public Function JeImportZamknuty() As Boolean
    JeImportZamknuty = (UCase$(Trim(mod_00_Common.GetNastavenie("ImportDokonceny", "FALSE"))) = "TRUE")
End Function

'-------------------------------------------------------------------------------
' Nastavuje stav uzamknutia importu v systémových nastaveniach.
'-------------------------------------------------------------------------------
Public Sub NastavImportDokonceny(ByVal Stav As Boolean)
    Call mod_00_Common.SetNastavenie("ImportDokonceny", IIf(Stav, "TRUE", "FALSE"), "Stav uzamknutia importu")
End Sub

'-------------------------------------------------------------------------------
' Testuje, či je konkrétny formulár momentálne otvorený.
'-------------------------------------------------------------------------------
Public Function FormIsOpen(ByVal FormName As String) As Boolean
    On Error Resume Next
    FormIsOpen = ((SysCmd(acSysCmdGetObjectState, acForm, FormName) And acObjStateOpen) <> 0)
End Function

'-------------------------------------------------------------------------------
' Programovo generuje pomocný formulár pre zobrazenie priebehu spracovania (frmProgress).
'-------------------------------------------------------------------------------
Public Sub VytvorFrmProgress()
    On Error GoTo ChybaHandler
    If mod_00_Common.FormIsOpen("frmProgress") Then DoCmd.Close acForm, "frmProgress", acSaveNo
    On Error Resume Next
    DoCmd.DeleteObject acForm, "frmProgress"
    On Error GoTo ChybaHandler
    
    Dim frm As Form, ctl As Control, TmpFormName As String
    CreateForm
    Set frm = Screen.ActiveForm
    TmpFormName = frm.Name

    With frm
        .Caption = "Priebeh spracovania"
        .RecordSelectors = False: .NavigationButtons = False: .AutoCenter = True
        .ScrollBars = 0
        .Width = 10000: .Section(acDetail).Height = 3000
    End With

    Set ctl = CreateControl(TmpFormName, acLabel, acDetail, "", "", 300, 150, 9400, 400)
    ctl.Caption = "Priebeh spracovania dát"
    ctl.FontSize = 14: ctl.FontBold = True: ctl.ForeColor = RGB(15, 30, 90)

    ' popisky sú samostatné; poradie vytvorenia textových polí sa nesmie meniť (AktualizujProgressGUI)
    Set ctl = CreateControl(TmpFormName, acLabel, acDetail, "", "", 300, 800, 1900, 300): ctl.Caption = "Priebeh:": ctl.FontBold = True
    Set ctl = CreateControl(TmpFormName, acTextBox, acDetail, "", "", 2300, 780, 4200, 330): ctl.Name = "txtPocitadlo"
    Set ctl = CreateControl(TmpFormName, acLabel, acDetail, "", "", 300, 1350, 1900, 300): ctl.Caption = "Súbor / položka:": ctl.FontBold = True
    Set ctl = CreateControl(TmpFormName, acTextBox, acDetail, "", "", 2300, 1330, 7400, 330): ctl.Name = "txtOsobneCislo"
    Set ctl = CreateControl(TmpFormName, acLabel, acDetail, "", "", 300, 1900, 1900, 300): ctl.Caption = "Podrobnosti:": ctl.FontBold = True
    Set ctl = CreateControl(TmpFormName, acTextBox, acDetail, "", "", 2300, 1880, 7400, 330): ctl.Name = "txtMeno"
    Set ctl = CreateControl(TmpFormName, acLabel, acDetail, "", "", 300, 2450, 1900, 300): ctl.Caption = "Stav:": ctl.FontBold = True
    Set ctl = CreateControl(TmpFormName, acTextBox, acDetail, "", "", 2300, 2430, 7400, 330): ctl.Name = "txtStav"

    For Each ctl In frm.Controls
        If ctl.ControlType = acTextBox Then
            ctl.Locked = True
            ctl.TabStop = False
        End If
    Next ctl
    Call mod_UI_Spolocne.NormalizujFormular(frm)

    DoCmd.Save acForm, TmpFormName
    DoCmd.Close acForm, TmpFormName, acSaveYes
    DoCmd.Rename "frmProgress", acForm, TmpFormName
    Call mod_00_Common.SetNastavenie("ProgressFormVerzia", "2.0", "Verzia okna priebehu spracovania (frmProgress)")
    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("VytvorFrmProgress", "ERROR", "Chyba pri vytváraní progress baru: " & Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Vygeneruje okno priebehu, ak chýba alebo je z staršej verzie (bez popiskov polí).
'-------------------------------------------------------------------------------
Private Sub ZabezpecProgressForm()
    On Error Resume Next
    If mod_00_Common.FormIsOpen("frmProgress") Then Exit Sub
    If (Not mod_00_Common.FormularExistujeDB("frmProgress")) Or mod_00_Common.GetNastavenie("ProgressFormVerzia", "") <> "2.0" Then
        Call mod_00_Common.VytvorFrmProgress
    End If
End Sub

'-------------------------------------------------------------------------------
' Otvára alebo pripravuje formulár priebehu (frmProgress) pred dlhotrvajúcou operáciou.
'-------------------------------------------------------------------------------
Public Sub PripravProgressForm()
    On Error Resume Next
    If Not mod_00_Common.FormIsOpen("frmProgress") Then
        Call ZabezpecProgressForm
        DoCmd.OpenForm "frmProgress", acNormal
        If Err.Number <> 0 Then
            Err.Clear
            Call mod_00_Common.VytvorFrmProgress
            DoCmd.OpenForm "frmProgress", acNormal
        End If
    End If
End Sub

'-------------------------------------------------------------------------------
' Bezpečne zatvára formulár priebehu (frmProgress).
'-------------------------------------------------------------------------------
Public Sub ZavriProgressForm()
    On Error Resume Next
    If mod_00_Common.FormIsOpen("frmProgress") Then DoCmd.Close acForm, "frmProgress", acSaveNo
End Sub

'-------------------------------------------------------------------------------
' Obnovuje počítadlá a stavové texty vo formulári priebehu (frmProgress).
'-------------------------------------------------------------------------------
Public Sub AktualizujProgressGUI(ByVal StavText As String, ByVal Aktualne As Long, ByVal Celkovo As Long, Optional ByVal SuborText As String = "", Optional ByVal DetailText As String = "")
    On Error Resume Next
    If Not mod_00_Common.FormIsOpen("frmProgress") Then
        Call ZabezpecProgressForm
        DoCmd.OpenForm "frmProgress", acNormal
    End If
    If mod_00_Common.FormIsOpen("frmProgress") Then
        Forms!frmProgress!txtStav = StavText
        If Celkovo > 0 Then
            Dim pct As Long: pct = CLng((Aktualne / Celkovo) * 100)
            Forms!frmProgress!txtPocitadlo = Aktualne & " / " & Celkovo & " (" & pct & "%)"
        ElseIf Aktualne > 0 Then
            Forms!frmProgress!txtPocitadlo = "Spracované: " & Format$(Aktualne, "#,##0")
        Else
            Forms!frmProgress!txtPocitadlo = "Spracovávam..."
        End If

        If Len(SuborText) > 0 Then Forms!frmProgress!txtOsobneCislo = SuborText
        Dim ctl As Control, tbCount As Long
        For Each ctl In Forms!frmProgress.Controls
            If ctl.ControlType = acTextBox Then
                tbCount = tbCount + 1
                If tbCount = 3 Then
                    ctl.Value = DetailText
                    Exit For
                End If
            End If
        Next ctl
        Forms!frmProgress.Recalc
        Forms!frmProgress.Repaint
        DoEvents
    End If
End Sub

'-------------------------------------------------------------------------------
' Bezpečne vyhľadá a vráti cestu k DBF/CSV súboru alebo otvorí dialóg výberu súboru.
'-------------------------------------------------------------------------------
Public Function VyberDBFSuborBezpecne(ByVal Titulok As String, ByVal PredvolenyNazov As String) As String
    On Error GoTo ChybaHandler
    Dim cesta As String, adr As String

    If mod_00_Common.FormIsOpen("frmHlavnaKonzola") Then
        On Error Resume Next
        adr = Trim(Nz(Forms!frmHlavnaKonzola!txtAdresarDBF, ""))
        On Error GoTo ChybaHandler
    ElseIf mod_00_Common.FormIsOpen("frmSprievodcaImportom") Then
        adr = Trim(Nz(Forms!frmSprievodcaImportom!txtAdresarDBF, ""))
    End If
    If Len(adr) = 0 Then adr = mod_00_Common.GetNastavenie("CestaDBFAdresar", "")

    If Len(adr) > 0 Then
        If Right$(adr, 1) <> "\" Then adr = adr & "\"
        cesta = adr & PredvolenyNazov
        If Dir(cesta) <> "" Then
            VyberDBFSuborBezpecne = cesta
            Exit Function
        End If
    End If

    cesta = CurrentProject.Path & "\" & PredvolenyNazov
    If Dir(cesta) <> "" Then
        VyberDBFSuborBezpecne = cesta
        Exit Function
    End If

    Dim fd As Object
    Set fd = Application.FileDialog(3)
    With fd
        .Title = Titulok
        .Filters.Clear
        .Filters.Add "Všetky podporované (*.dbf;*.csv;*.txt)", "*.dbf;*.csv;*.txt"
        .Filters.Add "DBF Súbory (*.dbf)", "*.dbf"
        If Len(adr) > 0 And Dir(adr, vbDirectory) <> "" Then .InitialFileName = adr Else .InitialFileName = CurrentProject.Path & "\"
        If .Show = -1 Then VyberDBFSuborBezpecne = .SelectedItems(1) Else VyberDBFSuborBezpecne = ""
    End With
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("VyberDBFSuborBezpecne", "ERROR", "Chyba výberu súboru: " & Err.Description)
    VyberDBFSuborBezpecne = ""
End Function

'-------------------------------------------------------------------------------
' Otvára dialóg na výber adresára so zdrojovými DBF súbormi.
'-------------------------------------------------------------------------------
Public Function VyberAdresarDBF() As String
    On Error GoTo ChybaHandler
    Dim fd As Object
    Set fd = Application.FileDialog(4)
    With fd
        .Title = "Vyberte adresár so súbormi DBF zo starej dochádzky"
        Dim strPoc As String
        strPoc = mod_00_Common.GetNastavenie("CestaDBFAdresar", "")
        If Len(strPoc) = 0 Or Len(Dir(strPoc, vbDirectory)) = 0 Then strPoc = CurrentProject.Path
        If Right$(strPoc, 1) <> "\" Then strPoc = strPoc & "\"
        .InitialFileName = strPoc
        If .Show = -1 Then
            VyberAdresarDBF = .SelectedItems(1)
            Call mod_00_Common.SetNastavenie("CestaDBFAdresar", VyberAdresarDBF, "Adresár pre import DBF")
        Else
            VyberAdresarDBF = ""
        End If
    End With
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("VyberAdresarDBF", "ERROR", "Chyba výberu adresára: " & Err.Description)
    VyberAdresarDBF = ""
End Function

'-------------------------------------------------------------------------------
' Extrahujeme osobné číslo z binárnych bajtov DBF poľa (podpora číselných aj reťazcových typov).
'-------------------------------------------------------------------------------
Public Function ExtrahujOSCislo(ByRef buf() As Byte, ByVal Offset As Long, ByVal Length As Long, ByVal fType As String) As Double
    On Error Resume Next
    Dim d As Double, txt As String, i As Long

    If Length >= 8 Then
        CopyMemory d, buf(Offset), 8
        If d >= 1000000 And d <= 9999999 Then
            ExtrahujOSCislo = d
            Exit Function
        End If

        Dim temp(0 To 7) As Byte
        For i = 0 To 7
            temp(i) = buf(Offset + 7 - i)
        Next i
        temp(7) = temp(7) Xor &H80
        CopyMemory d, temp(0), 8
        If d >= 1000000 And d <= 9999999 Then
            ExtrahujOSCislo = d
            Exit Function
        End If
    End If

    txt = ""
    For i = 0 To Length - 1
        If buf(Offset + i) >= 48 And buf(Offset + i) <= 57 Then txt = txt & Chr$(buf(Offset + i))
    Next i
    If Len(txt) > 0 Then ExtrahujOSCislo = Val(txt) Else ExtrahujOSCislo = 0
End Function

'-------------------------------------------------------------------------------
' Vypočíta percentuálnu podobnosť dvoch textových reťazcov pomocou Levenshteinovej vzdialenosti.
'-------------------------------------------------------------------------------
Public Function SimilarityPercent(ByVal s1 As String, ByVal s2 As String) As Double
    On Error GoTo ChybaHandler
    Dim maxLen As Long, dist As Long
    s1 = NormalizeName(Trim(s1)): s2 = NormalizeName(Trim(s2))
    maxLen = Len(s1)
    If Len(s2) > maxLen Then maxLen = Len(s2)
    If maxLen = 0 Then SimilarityPercent = 100: Exit Function
    
    dist = LevenshteinDistance(s1, s2)
    SimilarityPercent = (1 - dist / maxLen) * 100
    Exit Function
ChybaHandler:
    SimilarityPercent = 0
End Function

'-------------------------------------------------------------------------------
' Vypočíta Levenshteinovu vzdialenosť (počet úprav) medzi dvoma reťazcami.
'-------------------------------------------------------------------------------
Public Function LevenshteinDistance(ByVal s1 As String, ByVal s2 As String) As Long
    On Error GoTo ChybaHandler
    Dim i As Long, j As Long, cost As Long, l1 As Long, l2 As Long, d() As Long
    l1 = Len(s1): l2 = Len(s2)
    ReDim d(0 To l1, 0 To l2)
    For i = 0 To l1: d(i, 0) = i: Next
    For j = 0 To l2: d(0, j) = j: Next

    For i = 1 To l1
        For j = 1 To l2
            If Mid$(s1, i, 1) = Mid$(s2, j, 1) Then cost = 0 Else cost = 1
            d(i, j) = Min3(d(i - 1, j) + 1, d(i, j - 1) + 1, d(i - 1, j - 1) + cost)
        Next
    Next
    LevenshteinDistance = d(l1, l2)
    Exit Function
ChybaHandler:
    LevenshteinDistance = 0
End Function

'-------------------------------------------------------------------------------
' Vráti minimálnu hodnotu z troch celých čísel.
'-------------------------------------------------------------------------------
Private Function Min3(ByVal a As Long, ByVal b As Long, ByVal c As Long) As Long
    Min3 = a
    If b < Min3 Then Min3 = b
    If c < Min3 Then Min3 = c
End Function

'-------------------------------------------------------------------------------
' Normalizuje text pre porovnávanie: prevádza na malé písmená a odstraňuje slovenské diakritické znamienka.
'-------------------------------------------------------------------------------
Private Function NormalizeName(ByVal s As String) As String
    On Error Resume Next
    s = LCase(s)
    s = Replace(s, "á", "a"): s = Replace(s, "ä", "a"): s = Replace(s, "č", "c")
    s = Replace(s, "ď", "d"): s = Replace(s, "é", "e"): s = Replace(s, "ě", "e")
    s = Replace(s, "í", "i"): s = Replace(s, "ľ", "l"): s = Replace(s, "ĺ", "l")
    s = Replace(s, "ň", "n"): s = Replace(s, "ó", "o"): s = Replace(s, "ô", "o")
    s = Replace(s, "ŕ", "r"): s = Replace(s, "š", "s"): s = Replace(s, "ť", "t")
    s = Replace(s, "ú", "u"): s = Replace(s, "ý", "y"): s = Replace(s, "ž", "z")
    NormalizeName = s
End Function

'-------------------------------------------------------------------------------
' Rozdelí plnú cestu k súboru na samostatný adresár a názov súboru bez prípony.
'-------------------------------------------------------------------------------
Public Sub OdtahujCestuASubor(ByVal plnaCesta As String, ByRef Adresar As String, ByRef SuborBezPripony As String)
    On Error Resume Next
    If InStrRev(plnaCesta, "\") > 0 Then
        Adresar = Left$(plnaCesta, InStrRev(plnaCesta, "\") - 1)
        Dim fn As String
        fn = Mid$(plnaCesta, InStrRev(plnaCesta, "\") + 1)
        If InStrRev(fn, ".") > 0 Then SuborBezPripony = Left$(fn, InStrRev(fn, ".") - 1) Else SuborBezPripony = fn
    Else
        Adresar = CurrentProject.Path
        SuborBezPripony = plnaCesta
    End If
End Sub

'-------------------------------------------------------------------------------
' Vyhľadá prvý existujúci súbor zo zoznamu možných názvov v zadanom adresári.
'-------------------------------------------------------------------------------
Public Function NajdiSuborVAdresari(ByVal Adresar As String, ParamArray NazvySuborov() As Variant) As String
    Dim i As Long, subor As String, plnaCesta As String
    If Len(Adresar) = 0 Then Exit Function
    If Right$(Adresar, 1) <> "\" Then Adresar = Adresar & "\"
    For i = LBound(NazvySuborov) To UBound(NazvySuborov)
        subor = CStr(NazvySuborov(i))
        plnaCesta = Adresar & subor
        If Dir(plnaCesta) <> "" Then NajdiSuborVAdresari = plnaCesta: Exit Function
    Next i
    NajdiSuborVAdresari = ""
End Function


