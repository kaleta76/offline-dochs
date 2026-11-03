Attribute VB_Name = "mod_14_ImportModelu"
'@Verzia 1.1.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_14_ImportModelu
' POPIS: Import dát zo STARŠEJ verzie databázy dochádzky (iný súbor .accdb/.mdb) do aktuálnej databázy.
'        Zdrojová databáza sa otvára len na čítanie. Nič sa nemaže ani neprepisuje - riadky sa len dopĺňajú.
'        Stĺpce sa párujú podľa názvu, takže rozdiely medzi verziami dátového modelu nevadia
'        (nové stĺpce ostanú prázdne, zrušené stĺpce sa ignorujú). Celé kopírovanie beží v jednej transakcii.
' REŽIMY:
'   0 = naplní iba prázdne tabuľky (neprázdne preskočí)
'   1 = doplní chýbajúce riadky podľa kľúča (predvolené; existujúce riadky nemení)
' PRESKAKUJE SA: DochadzkaDni, DochadzkaIntervaly, DochadzkaMesiacSumar, DochadzkaAnomalie (prepočítajú sa),
'                LogImportu, PrihlaseniUzivatelia (logy), DochadzkaAutoOpravy, TerminalInbox, KonfiguraciaVerzie.
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - ImportZoStarsejDatabazy(cesta, rezim, bTicho)  : Hlavný vstupný bod, vráti textovú správu s výsledkom.
' - ImportStarejDBAuto(cesta)                       : Obálka pre Application.Run z inštalátora (tichý režim 1).
' - ZistiVerziuModelu(db)                           : 0 = nie je databáza dochádzky, 1 = starší model, 2 = aktuálny model.
' - KopirujTabulku(...)                             : Skopíruje jednu tabuľku (spoločné stĺpce, dopĺňanie podľa kľúča).
' - Odpoj*, PripojTabulku                           : Správa dočasných prepojených tabuliek zz_src_*.
'===============================================================================

Private Const PREDPONA_LINKU As String = "zz_src_"

'-------------------------------------------------------------------------------
' Obálka pre inštalátor: tichý import v režime 1, vráti správu (reťazec).
'-------------------------------------------------------------------------------
Public Function ImportStarejDBAuto(ByVal strCesta As String) As String
    ImportStarejDBAuto = ImportZoStarsejDatabazy(strCesta, 1, True)
End Function

'-------------------------------------------------------------------------------
' Zistí verziu dátového modelu databázy: 0 = nerozpoznaná, 1 = starší model (1.x), 2 = model s nedeštruktívnymi úpravami.
'-------------------------------------------------------------------------------
Public Function ZistiVerziuModelu(ByRef db As DAO.Database) As Long
    On Error GoTo Chyba
    Dim bDI As Boolean, bZam As Boolean
    bDI = mod_00_Common.TabulkaExistujeDB(db, "DochadzkaImport")
    bZam = mod_00_Common.TabulkaExistujeDB(db, "Zamestnanci")
    If Not bDI And Not bZam Then ZistiVerziuModelu = 0: Exit Function
    ZistiVerziuModelu = 1
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaAutoOpravy") Then ZistiVerziuModelu = 2: Exit Function
    If bDI Then
        If mod_00_Common.PoleExistujeDB(db, "DochadzkaImport", "DovodNeplatnosti") Then ZistiVerziuModelu = 2
    End If
    Exit Function
Chyba:
    ZistiVerziuModelu = 0
End Function

'-------------------------------------------------------------------------------
' Odstráni dočasné prepojené tabuľky zz_src_* (odstráni sa iba prepojenie, nie dáta v zdrojovom súbore).
'-------------------------------------------------------------------------------
Private Sub OdpojVsetko(ByRef db As DAO.Database)
    On Error Resume Next
    Dim i As Long
    For i = db.TableDefs.Count - 1 To 0 Step -1
        If Left$(db.TableDefs(i).Name, Len(PREDPONA_LINKU)) = PREDPONA_LINKU Then db.TableDefs.Delete db.TableDefs(i).Name
    Next i
    db.TableDefs.Refresh
End Sub

'-------------------------------------------------------------------------------
' Prepojí tabuľku zo zdrojového súboru ako zz_src_<názov>.
'-------------------------------------------------------------------------------
Private Function PripojTabulku(ByRef db As DAO.Database, ByVal strCesta As String, ByVal strTab As String) As Boolean
    On Error GoTo Chyba
    Dim tdf As DAO.TableDef
    Set tdf = db.CreateTableDef(PREDPONA_LINKU & strTab)
    tdf.Connect = ";DATABASE=" & strCesta
    tdf.SourceTableName = strTab
    db.TableDefs.Append tdf
    PripojTabulku = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_14_ImportModelu.PripojTabulku", "WARN", strTab & ": " & Err.Description)
End Function

'-------------------------------------------------------------------------------
' Sú typy polí dostatočne kompatibilné na priame kopírovanie?
'-------------------------------------------------------------------------------
Private Function TypyKompatibilne(ByVal t1 As Long, ByVal t2 As Long) As Boolean
    If t1 = t2 Then TypyKompatibilne = True: Exit Function
    Select Case t1
        Case dbByte, dbInteger, dbLong, dbSingle, dbDouble, dbCurrency, dbDecimal, dbBigInt
            Select Case t2
                Case dbByte, dbInteger, dbLong, dbSingle, dbDouble, dbCurrency, dbDecimal, dbBigInt
                    TypyKompatibilne = True
            End Select
        Case dbText, dbMemo
            TypyKompatibilne = (t2 = dbText Or t2 = dbMemo)
    End Select
End Function

'-------------------------------------------------------------------------------
' Skopíruje jednu tabuľku zo zdroja (zz_src_<tab>) do cieľa. Vráti stručný text výsledku, počet pridaných riadkov v lPridane.
'-------------------------------------------------------------------------------
Private Function KopirujTabulku(ByRef db As DAO.Database, ByVal strTab As String, ByVal strKluce As String, _
                                ByVal iRezim As Long, ByRef lPridane As Long, ByRef lZdroj As Long) As String
    On Error GoTo Chyba
    Dim tdfC As DAO.TableDef, tdfS As DAO.TableDef, fld As DAO.Field, fS As DAO.Field
    Dim strCols As String, strSel As String, strWhere As String, strSQL As String
    Dim lCiel As Long, bPrazdny As Boolean, bAuto As Boolean, v As Variant, strK As String, strNz As String
    Dim pocetKlucov As Long, pocetStlpcov As Long, strVynechane As String, fC As DAO.Field

    lPridane = 0
    Set tdfC = db.TableDefs(strTab)
    Set tdfS = db.TableDefs(PREDPONA_LINKU & strTab)
    lZdroj = DCount("*", PREDPONA_LINKU & strTab)
    lCiel = DCount("*", strTab)
    bPrazdny = (lCiel = 0)

    If lZdroj = 0 Then KopirujTabulku = "zdroj je prázdny": Exit Function
    If Not bPrazdny And iRezim = 0 Then KopirujTabulku = "preskočené (cieľová tabuľka nie je prázdna)": Exit Function
    ' uzavreté (podpísané) mesiace: nastavenia (fondy, pravidlá, priradenia, kalendáre) sa neprebierajú a razenia uzavretých mesiacov tiež nie
    If mod_18_Uzavierka.ExistujeUzavrety() Then
        Select Case strTab
            Case "PracovneFondy", "PracovneFondyDni", "ParametrePreruseni", "ZamestnanciFondy", "Kalendare", "KalendarDni", "Sviatky"
                KopirujTabulku = "preskočené (existujú uzavreté mesiace - nastavenia sa nemenia)"
                Exit Function
        End Select
    End If

    ' Spoločné stĺpce
    For Each fld In tdfC.Fields
        bAuto = ((fld.Attributes And dbAutoIncrField) <> 0)
        Set fS = Nothing
        On Error Resume Next
        Set fS = tdfS.Fields(fld.Name)
        On Error GoTo Chyba
        If Not fS Is Nothing Then
            If Not TypyKompatibilne(fld.Type, fS.Type) Then
                strVynechane = strVynechane & fld.Name & "(typ) "
            ElseIf (bAuto Or StrComp(fld.Name, "PovodneID", vbTextCompare) = 0) And Not bPrazdny Then
                ' pri doplňovaní do neprázdnej tabuľky sa ID prideľuje nanovo a väzba PovodneID by bola neplatná
                strVynechane = strVynechane & fld.Name & "(ID) "
            Else
                If Len(strCols) > 0 Then strCols = strCols & ", ": strSel = strSel & ", "
                strCols = strCols & "[" & fld.Name & "]"
                strSel = strSel & "s.[" & fld.Name & "]"
                pocetStlpcov = pocetStlpcov + 1
            End If
        End If
    Next fld
    If pocetStlpcov = 0 Then KopirujTabulku = "preskočené (žiadne spoločné stĺpce)": Exit Function

    ' Podmienka pre dopĺňanie podľa kľúča (iba pri neprázdnej cieľovej tabuľke)
    If Not bPrazdny Then
        For Each v In Split(strKluce, ",")
            strK = Trim$(CStr(v))
            If Len(strK) > 0 Then
                Set fC = Nothing: Set fS = Nothing
                On Error Resume Next
                Set fC = tdfC.Fields(strK)
                Set fS = tdfS.Fields(strK)
                On Error GoTo Chyba
                If Not fC Is Nothing And Not fS Is Nothing Then
                    If Len(strWhere) > 0 Then strWhere = strWhere & " AND "
                    ' Bez NULL v zdroji stačí priame porovnanie - ACE pritom použije index (rýchle aj pri desaťtisícoch riadkov).
                    ' Nz(...) na oboch stranách index vylúči a pri veľkých tabuľkách je porovnanie extrémne pomalé.
                    If DCount("*", PREDPONA_LINKU & strTab, "[" & strK & "] Is Null") = 0 Then
                        strWhere = strWhere & "t.[" & strK & "] = s.[" & strK & "]"
                    Else
                        If fC.Type = dbText Or fC.Type = dbMemo Then strNz = "''" Else strNz = "0"
                        strWhere = strWhere & "Nz(t.[" & strK & "], " & strNz & ") = Nz(s.[" & strK & "], " & strNz & ")"
                    End If
                    pocetKlucov = pocetKlucov + 1
                End If
            End If
        Next v
        If pocetKlucov = 0 Then KopirujTabulku = "preskočené (kľúčové stĺpce nie sú v oboch tabuľkách)": Exit Function
        strWhere = " WHERE NOT EXISTS (SELECT 1 FROM [" & strTab & "] AS t WHERE " & strWhere & ")"
        If StrComp(strTab, "DochadzkaImport", vbTextCompare) = 0 Then strWhere = strWhere & mod_18_Uzavierka.SqlVynechUzavreteZdroj("s")
    End If

    strSQL = "INSERT INTO [" & strTab & "] (" & strCols & ") SELECT " & strSel & " FROM [" & PREDPONA_LINKU & strTab & "] AS s" & strWhere & ";"
    db.Execute strSQL, dbFailOnError
    lPridane = db.RecordsAffected

    KopirujTabulku = IIf(bPrazdny, "naplnené", "doplnené") & IIf(Len(strVynechane) > 0, " (vynechané stĺpce: " & Trim$(strVynechane) & ")", "")
    Exit Function
Chyba:
    KopirujTabulku = "CHYBA: " & Err.Description
    lPridane = -1
End Function

'-------------------------------------------------------------------------------
' HLAVNÝ VSTUPNÝ BOD: importuje dáta zo staršej databázy dochádzky do aktuálnej.
' Vráti text s výsledkom (aj pri chybe); bTicho = FALSE zobrazí na záver aj okno so správou.
'-------------------------------------------------------------------------------
Public Function ImportZoStarsejDatabazy(ByVal strCesta As String, Optional ByVal iRezim As Long = 1, Optional ByVal bTicho As Boolean = False) As String
    On Error GoTo Chyba
    Dim db As DAO.Database, dbSrc As DAO.Database, wsp As DAO.Workspace
    Dim dicZdroj As Object, tdf As DAO.TableDef, v As Variant, p() As String
    Dim lVerzia As Long, sb As String, strVys As String, lPrid As Long, lZdr As Long, lCelkom As Long
    Dim bTrans As Boolean, strNeznam As String, bChyba As Boolean

    If Len(strCesta) = 0 Then
        ImportZoStarsejDatabazy = "CHYBA: nebola zadaná cesta k súboru."
        GoTo Koniec
    End If
    If Len(Dir$(strCesta)) = 0 Then
        ImportZoStarsejDatabazy = "CHYBA: súbor neexistuje: " & strCesta
        GoTo Koniec
    End If
    Set db = CurrentDb
    If StrComp(strCesta, db.Name, vbTextCompare) = 0 Then
        ImportZoStarsejDatabazy = "CHYBA: zdrojová databáza je rovnaká ako aktuálna."
        GoTo Koniec
    End If

    ' Opakovaný import toho istého súboru: iba doplní chýbajúce riadky (nič nezdvojí), ale upozorníme
    Dim strPredch As String
    strPredch = mod_00_Common.GetNastavenie("ImportStarehoModelu", "")
    If Not bTicho And Len(strPredch) > 0 Then
        If InStr(1, strPredch, strCesta, vbTextCompare) = 1 Then
            If MsgBox("Z tejto databázy už import prebehol:" & vbCrLf & strPredch & vbCrLf & vbCrLf & _
                      "Opakovaný import doplní iba záznamy, ktoré ešte chýbajú (nič sa nezdvojí ani neprepíše)." & vbCrLf & "Pokračovať?", _
                      vbQuestion + vbYesNo + vbDefaultButton2, "Import zo staršej databázy") <> vbYes Then
                ImportZoStarsejDatabazy = "Import zrušený používateľom (databáza už bola importovaná)."
                bTicho = True
                GoTo Koniec
            End If
        End If
    End If
    DoCmd.Hourglass True

    ' Cieľová štruktúra musí existovať a byť aktuálna
    If Not mod_00_Common.TabulkaExistuje("NastaveniaSystemu") Or Not mod_00_Common.TabulkaExistuje("Zamestnanci") Then Call mod_01_SystemInit.InicializujDatabazuV2(True)
    Call mod_01_SystemInit.ZabezpecStrukturuImportu
    Set db = CurrentDb

    ' Prehľad tabuliek zdroja (len na čítanie)
    Set dicZdroj = CreateObject("Scripting.Dictionary")
    dicZdroj.CompareMode = 1
    Set dbSrc = DBEngine.OpenDatabase(strCesta, False, True)
    For Each tdf In dbSrc.TableDefs
        If Left$(tdf.Name, 4) <> "MSys" And Left$(tdf.Name, 1) <> "~" And Left$(tdf.Name, 4) <> "USys" Then dicZdroj(tdf.Name) = 1
    Next tdf
    lVerzia = ZistiVerziuModelu(dbSrc)
    dbSrc.Close: Set dbSrc = Nothing
    If lVerzia = 0 Then
        ImportZoStarsejDatabazy = "CHYBA: súbor nevyzerá ako databáza dochádzky (chýbajú tabuľky Zamestnanci a DochadzkaImport)."
        GoTo Koniec
    End If

    On Error Resume Next
    DBEngine.SetOption dbMaxLocksPerFile, 500000
    On Error GoTo Chyba

    Call OdpojVsetko(db)
    ' Zoznam: Tabuľka | kľúčové stĺpce (pri dopĺňaní) - poradie je dôležité (číselníky pred dátami)
    Dim spec As Variant
    spec = Array("NastaveniaSystemu|Kluc", _
                 "TypyUdalosti|Kod", "CiselnikPreruseni|Cislo", "KodyRazeni|KodRazenia", "CiselnikPravidielAnomalii|KodAnomalie", _
                 "Sviatky|Den,Mesiac,Rok", "Kalendare|Cislo,Rok,Mesiac", "KalendarDni|Kalendar,Datum", _
                 "PracovneFondy|Cislo,Rok,Mesiac", "PracovneFondyDni|Cislo,Rok,Mesiac,Den", _
                 "ParametrePreruseni|Sablona,Rok,Mesiac,CisloPreruseni", _
                 "SablonyDochadzky|Cislo,Rok,Mesiac", "SablonyNadcasov|Cislo,Rok,Mesiac", "SablonyPraceVNoci|Cislo,Rok,Mesiac", _
                 "Zamestnanci|OsobneCislo", "ZamestnanciFondy|OsobneCislo,Rok,Mesiac", _
                 "DochadzkaImport|OsobneCislo,Datum,Cas,KodPrerusenia,CisPam")

    ' Prepojenie potrebných tabuliek (pred transakciou - zmena štruktúry)
    For Each v In spec
        p = Split(CStr(v), "|")
        If dicZdroj.Exists(p(0)) And mod_00_Common.TabulkaExistujeDB(db, p(0)) Then Call PripojTabulku(db, strCesta, p(0))
    Next v
    db.TableDefs.Refresh

    Set wsp = DBEngine.Workspaces(0)
    wsp.BeginTrans: bTrans = True
    sb = "Import zo staršej databázy" & vbCrLf & strCesta & vbCrLf & _
         "Model zdroja: " & IIf(lVerzia = 2, "aktuálny (2)", "starší (1)") & ", režim: " & IIf(iRezim = 0, "iba prázdne tabuľky", "doplnenie chýbajúcich riadkov") & vbCrLf & String$(60, "-") & vbCrLf

    For Each v In spec
        p = Split(CStr(v), "|")
        If Not dicZdroj.Exists(p(0)) Then
            sb = sb & p(0) & ": v zdroji nie je" & vbCrLf
        ElseIf Not mod_00_Common.TabulkaExistujeDB(db, PREDPONA_LINKU & p(0)) Then
            sb = sb & p(0) & ": prepojenie sa nepodarilo (pozri LogImportu)" & vbCrLf
            bChyba = True
        Else
            On Error Resume Next
            SysCmd acSysCmdSetStatus, "Import zo staršej databázy: " & p(0) & "..."
            DoEvents
            On Error GoTo Chyba
            strVys = KopirujTabulku(db, p(0), p(1), iRezim, lPrid, lZdr)
            If lPrid < 0 Then
                bChyba = True
                sb = sb & p(0) & ": " & strVys & vbCrLf
                Exit For
            Else
                lCelkom = lCelkom + lPrid
                sb = sb & p(0) & ": " & lPrid & " z " & lZdr & " - " & strVys & vbCrLf
            End If
        End If
    Next v

    If bChyba Then
        wsp.Rollback: bTrans = False
        sb = sb & String$(60, "-") & vbCrLf & "IMPORT ZRUŠENÝ - zmeny sa vrátili späť, databáza ostala nezmenená."
        Call mod_00_Common.ZapisLog("ImportZoStarsejDatabazy", "ERROR", "Import zrušený (rollback)", sb)
    Else
        wsp.CommitTrans: bTrans = False
        ' Tabuľky, ktoré sa neprenášajú
        For Each v In Array("DochadzkaDni", "DochadzkaIntervaly", "DochadzkaMesiacSumar", "DochadzkaAnomalie", "LogImportu", "PrihlaseniUzivatelia", "DochadzkaAutoOpravy", "TerminalInbox")
            If dicZdroj.Exists(CStr(v)) Then strNeznam = strNeznam & CStr(v) & ", "
        Next v
        If Len(strNeznam) > 0 Then sb = sb & "Neprenášané (prepočítajú sa / logy): " & Left$(strNeznam, Len(strNeznam) - 2) & vbCrLf
        sb = sb & String$(60, "-") & vbCrLf & "Celkom pridaných riadkov: " & lCelkom & vbCrLf
        On Error Resume Next
        mod_03_ADSync.PrepocitajHierarchiu
        mod_00_Common.SetNastavenie "ImportStarehoModelu", strCesta & " (" & Format$(Now, "yyyy-mm-dd hh:nn") & ", model " & lVerzia & ")", "Posledný import zo staršej databázy"
        On Error GoTo Chyba
        sb = sb & "Denné výpočty a sumáre sa vytvoria pri ďalšom prepočte mesiaca (záložka Výpočet)."
        Call mod_00_Common.ZapisLog("ImportZoStarsejDatabazy", "INFO", "Import zo staršej databázy dokončený, pridaných riadkov: " & lCelkom, sb)
    End If
    ImportZoStarsejDatabazy = sb

Koniec:
    On Error Resume Next
    DoCmd.Hourglass False
    SysCmd acSysCmdClearStatus
    If bTrans Then wsp.Rollback
    If Not db Is Nothing Then Call OdpojVsetko(db)
    If Not dbSrc Is Nothing Then dbSrc.Close
    If Not bTicho Then MsgBox ImportZoStarsejDatabazy, vbInformation, "Import zo staršej databázy"
    Exit Function
Chyba:
    ImportZoStarsejDatabazy = "CHYBA pri importe: " & Err.Description & IIf(Len(sb) > 0, vbCrLf & vbCrLf & sb, "")
    Call mod_00_Common.ZapisLog("ImportZoStarsejDatabazy", "ERROR", Err.Description)
    Resume Koniec
End Function
