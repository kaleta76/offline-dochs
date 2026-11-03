Attribute VB_Name = "mod_01_SystemInit"
'@Verzia 2.9.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_01_SystemInit
' POPIS: Inicializácia databázy, DDL štruktúr, audit prihlásení používateľov
'        a správa verzií tabuliek.
'===============================================================================

'-------------------------------------------------------------------------------
' Hlavný vstupný bod po štarte databázy (AutoExec macro).
'-------------------------------------------------------------------------------
Public Function AutoExecStart() As Boolean
    On Error GoTo ChybaHandler

    If Not mod_01_SystemInit.SkontrolujVBAReferencie() Then
        AutoExecStart = False
        Exit Function
    End If

    If Not mod_00_Common.TabulkaExistuje("NastaveniaSystemu") Then
        Call mod_01_SystemInit.InicializujDatabazuV2
    End If
    ' Doplní stĺpce/tabuľky novšieho dátového modelu (opakovateľné, bez straty dát)
    Call mod_01_SystemInit.ZabezpecStrukturuImportu

    ' Audit prihlásenia používateľa
    Call ZapisPrihlasenie

    ' Tabuľky a texty Pomocníka (info okná kariet)
    Call mod_UI_Pomocnik.ZabezpecPomocnik

    ' Spustenie centrálnej konzoly cez mod_UI_Core
    Call mod_UI_Core.OtvorHlavnuKonzolu

    ' Skrytie pásu kariet a navigačného panela (dajú sa kedykoľvek zobraziť tlačidlom Menu)
    Call mod_UI_Core.UI_SkryMenuPriStarte

    ' Úvodné info okno aktívnej karty (napr. postup importu pri prázdnej databáze)
    Call mod_UI_Pomocnik.PomocnikPriStarte

    AutoExecStart = True
    Exit Function

ChybaHandler:
    Call mod_00_Common.ZapisLog("AutoExecStart", "ERROR", "Kritická chyba pri štarte: " & Err.Description)
    AutoExecStart = False
End Function

'-------------------------------------------------------------------------------
' Dynamicky otvára okno vývojárskych a správcovských nástrojov.
'-------------------------------------------------------------------------------
Public Function SpustiAdminNastroje() As Boolean
    On Error GoTo ChybaHandler
    On Error Resume Next
    Application.Run "mod_06_AdminTools.OtvorAdminNastroje"
    If Err.Number <> 0 Then
        MsgBox "Modul Admin nástrojov (mod_06_AdminTools) zatiaľ nie je naimportovaný.", vbInformation, "Informácia"
    End If
    On Error GoTo ChybaHandler
    SpustiAdminNastroje = True
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("SpustiAdminNastroje", "ERROR", "Chyba pri otváraní Admin nástrojov: " & Err.Description)
    SpustiAdminNastroje = False
End Function

'-------------------------------------------------------------------------------
' Programovo pridáva tlačidlo pre Admin nástroje do zadaného formulára.
'-------------------------------------------------------------------------------
Public Sub PridajTlacitkoAdminNastroje(ByVal strNazovFormulara As String, Optional ByVal lX As Long = 7000, Optional ByVal lY As Long = 200)
    On Error Resume Next
    Dim btn As Control
    Set btn = CreateControl(strNazovFormulara, acCommandButton, acDetail, , "", lX, lY, 2500, 400)
    btn.Name = "btnOtvoriAdminNastroje"
    btn.Caption = "Admin nástroje"
    btn.FontBold = True
    btn.ForeColor = RGB(150, 0, 0)
    btn.OnClick = "=SpustiAdminNastroje()"
End Sub

'-------------------------------------------------------------------------------
' Zapisuje auditné údaje o prihlásení používateľa.
'-------------------------------------------------------------------------------
Public Sub ZapisPrihlasenie()
    On Error GoTo ChybaHandler

    Dim db As DAO.Database
    Set db = CurrentDb

    If Not mod_00_Common.TabulkaExistuje("PrihlaseniUzivatelia") Then
        db.Execute "CREATE TABLE PrihlaseniUzivatelia (" & _
                   "ID AUTOINCREMENT PRIMARY KEY, " & _
                   "DatumCasPrihlasenia DATETIME, " & _
                   "LoginWindows TEXT(100), " & _
                   "Pocitac TEXT(100), " & _
                   "Domain TEXT(100), " & _
                   "OsobneCislo TEXT(20), " & _
                   "MenoZamestnanca TEXT(150));", dbFailOnError
    End If

    Dim strLogin As String, strPocitac As String, strDomain As String
    strLogin = Environ$("USERNAME")
    strPocitac = Environ$("COMPUTERNAME")
    strDomain = Environ$("USERDOMAIN")

    Dim strOsobneCislo As String, strMeno As String
    strOsobneCislo = ""
    strMeno = "Neklasifikovaný používateľ"

    If mod_00_Common.TabulkaExistuje("Zamestnanci") Then
        Dim rsZam As DAO.Recordset
        Dim strSQL As String
        strSQL = "SELECT OsobneCislo, IIf(Nz(CeleMeno,'')<>'', CeleMeno, Trim(Nz(Titul,'') & ' ' & Nz(Meno,'') & ' ' & Nz(Priezvisko,''))) AS VypisMeno " & _
                 "FROM Zamestnanci WHERE LoginAD = '" & Replace(strLogin, "'", "''") & "';"
        
        Set rsZam = db.OpenRecordset(strSQL, dbOpenSnapshot)
        If Not rsZam.EOF Then
            strOsobneCislo = Nz(rsZam!OsobneCislo, "")
            strMeno = Nz(rsZam!VypisMeno, strMeno)
        End If
        rsZam.Close: Set rsZam = Nothing
    End If

    Dim rsLog As DAO.Recordset
    Set rsLog = db.OpenRecordset("PrihlaseniUzivatelia", dbOpenDynaset)
    rsLog.AddNew
    rsLog!DatumCasPrihlasenia = Now
    rsLog!LoginWindows = strLogin
    rsLog!Pocitac = strPocitac
    rsLog!Domain = strDomain
    rsLog!OsobneCislo = strOsobneCislo
    rsLog!MenoZamestnanca = strMeno
    rsLog.Update
    
    rsLog.Close: Set rsLog = Nothing
    Set db = Nothing
    Exit Sub

ChybaHandler:
    Call mod_00_Common.ZapisLog("ZapisPrihlasenie", "ERROR", "Chyba zápisu prihlásenia: " & Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Kontroluje, či nie sú v Access projekte poškodené VBA referencie.
'-------------------------------------------------------------------------------
Public Function SkontrolujVBAReferencie() As Boolean
    On Error GoTo ChybaHandler
    Dim ref As Access.Reference
    Dim pocetChyb As Long, zoznamChyb As String
    
    pocetChyb = 0: zoznamChyb = ""

    For Each ref In Application.References
        If ref.IsBroken Then
            pocetChyb = pocetChyb + 1
            zoznamChyb = zoznamChyb & "• " & ref.Name & " (" & ref.FullPath & ")" & vbCrLf
            Call mod_00_Common.ZapisLog("SkontrolujVBAReferencie", "ERROR", "Chýbajúca referencia: " & ref.Name)
        End If
    Next ref

    If pocetChyb > 0 Then
        MsgBox "Aplikácia zistila poškodené VBA referencie (" & pocetChyb & "):" & vbCrLf & zoznamChyb, vbCritical, "Chyba referencií"
        SkontrolujVBAReferencie = False
    Else
        SkontrolujVBAReferencie = True
    End If
    Exit Function
ChybaHandler:
    SkontrolujVBAReferencie = False
End Function

'-------------------------------------------------------------------------------
' Vyhodnocuje skutočný stav dokončenia importných krokov.
'-------------------------------------------------------------------------------
Public Function ZistiSkutocnyKrok() As Long
    On Error GoTo ChybaHandler
    If Not mod_00_Common.TabulkaExistuje("NastaveniaSystemu") Or Not mod_00_Common.TabulkaExistuje("Zamestnanci") Then
        ZistiSkutocnyKrok = 0: Exit Function
    End If

    Dim ulozenyKrok As Long, pocetZam As Long, pocetAD As Long, pocetDoch As Long, pocetPrerus As Long
    ulozenyKrok = mod_00_Common.GetPoslednyKrok()

    pocetZam = DCount("*", "Zamestnanci")
    If pocetZam > 0 Then pocetAD = DCount("*", "Zamestnanci", "LoginAD Is Not Null AND Len(LoginAD) > 0")
    If mod_00_Common.TabulkaExistuje("DochadzkaImport") Then pocetDoch = DCount("*", "DochadzkaImport")
    If mod_00_Common.TabulkaExistuje("KodyRazeni") Then pocetPrerus = DCount("*", "KodyRazeni")

    Dim vypocitanyKrok As Long
    vypocitanyKrok = 1
    If pocetZam > 0 Then vypocitanyKrok = 2
    If pocetAD > 0 Then vypocitanyKrok = 3
    If pocetDoch > 0 Then vypocitanyKrok = 4
    If pocetPrerus > 0 And pocetDoch > 0 Then vypocitanyKrok = 5

    If vypocitanyKrok > ulozenyKrok Then
        Call mod_00_Common.SetPoslednyKrok(vypocitanyKrok)
        ZistiSkutocnyKrok = vypocitanyKrok
    Else
        ZistiSkutocnyKrok = ulozenyKrok
    End If
    Exit Function
ChybaHandler:
    ZistiSkutocnyKrok = mod_00_Common.GetPoslednyKrok()
End Function

'-------------------------------------------------------------------------------
' Hlavná čistá reinicializácia databázy - ZMAŽE A REKONŠTRUJE VŠETKY TABUĽKY.
'-------------------------------------------------------------------------------
Public Sub InicializujDatabazuV2(Optional ByVal bPotvrdene As Boolean = False)
    Dim db As DAO.Database, strPotvrdenie As String, strZaloha As String
    Set db = CurrentDb

    ' Ochrana pred omylom: ak v databáze sú dáta, vyžaduje sa potvrdenie a vytvorí sa záloha tabuliek (bak_<čas>_*)
    If Not bPotvrdene Then
        Dim lRazeni As Long, lZam As Long, lUz As Long
        On Error Resume Next
        lRazeni = DCount("*", "DochadzkaImport")
        lZam = DCount("*", "Zamestnanci")
        lUz = mod_18_Uzavierka.PocetUzavretych()
        On Error GoTo 0
        If lRazeni > 0 Or lZam > 0 Then
            strPotvrdenie = InputBox("POZOR: Reinicializácia ZMAŽE všetky tabuľky (razenia: " & lRazeni & ", zamestnanci: " & lZam & _
                                     IIf(lUz > 0, ", UZAVRETÉ (podpísané) mesiace: " & lUz, "") & ")." & vbCrLf & _
                                     "Pred zmazaním sa vytvoria zálohové tabuľky bak_*." & vbCrLf & vbCrLf & "Pre pokračovanie napíšte: ZMAZAT", "Reinicializácia databázy")
            If UCase$(Trim$(strPotvrdenie)) <> "ZMAZAT" Then
                MsgBox "Reinicializácia bola zrušená, dáta ostali nezmenené.", vbInformation, "Reinicializácia databázy"
                Exit Sub
            End If
        End If
    End If
    strZaloha = ZalohujTabulky(db)

    On Error Resume Next
    DoCmd.DeleteObject acTable, "DochadzkaAutoOpravy"
    DoCmd.DeleteObject acTable, "DochadzkaUzavierka"
    DoCmd.DeleteObject acTable, "DochadzkaUzavierkaLog"
    Call mod_18_Uzavierka.ResetCache
    DoCmd.DeleteObject acTable, "CiselnikPravidielAnomalii"
    DoCmd.DeleteObject acTable, "DochadzkaAnomalie"
    DoCmd.DeleteObject acTable, "DochadzkaIntervaly"
    DoCmd.DeleteObject acTable, "DochadzkaDni"
    DoCmd.DeleteObject acTable, "DochadzkaMesiacSumar"
    DoCmd.DeleteObject acTable, "ParametrePreruseni"
    DoCmd.DeleteObject acTable, "SablonyPraceVNoci"
    DoCmd.DeleteObject acTable, "SablonyNadcasov"
    DoCmd.DeleteObject acTable, "SablonyDochadzky"
    DoCmd.DeleteObject acTable, "ZamestnanciFondy"
    DoCmd.DeleteObject acTable, "KalendarDni"
    DoCmd.DeleteObject acTable, "Kalendare"
    DoCmd.DeleteObject acTable, "Sviatky"
    DoCmd.DeleteObject acTable, "PracovneFondyDni"
    DoCmd.DeleteObject acTable, "PracovneFondy"
    DoCmd.DeleteObject acTable, "KodyRazeni"
    DoCmd.DeleteObject acTable, "DochadzkaImport"
    DoCmd.DeleteObject acTable, "CiselnikPreruseni"
    DoCmd.DeleteObject acTable, "NastaveniaSystemu"
    DoCmd.DeleteObject acTable, "LogImportu"
    DoCmd.DeleteObject acTable, "TypyUdalosti"
    DoCmd.DeleteObject acTable, "Zamestnanci"
    DoCmd.DeleteObject acTable, "PrihlaseniUzivatelia"
    Err.Clear

    On Error GoTo ChybaHandler

    db.Execute "CREATE TABLE LogImportu (ID AUTOINCREMENT PRIMARY KEY, DatumCas DATETIME, Krok TEXT(50), TypUdalosti TEXT(20), Sprava TEXT(255), Detail LONGTEXT)"
    db.Execute "CREATE TABLE NastaveniaSystemu (Kluc TEXT(50) PRIMARY KEY, Hodnota TEXT(255), Popis TEXT(255))"
    db.Execute "CREATE TABLE PrihlaseniUzivatelia (ID AUTOINCREMENT PRIMARY KEY, DatumCasPrihlasenia DATETIME, LoginWindows TEXT(100), Pocitac TEXT(100), Domain TEXT(100), OsobneCislo TEXT(20), MenoZamestnanca TEXT(150))"

    db.Execute "CREATE TABLE Zamestnanci (ID AUTOINCREMENT PRIMARY KEY, OsobneCislo TEXT(20) UNIQUE, LoginAD TEXT(100), Meno TEXT(50), Priezvisko TEXT(50), " & _
               "CeleMeno TEXT(150), Email TEXT(255), Rola TEXT(20), ADAktivny YESNO, DatumImportu DATETIME, " & _
               "Titul TEXT(20), CisloKarty LONG, StrediskoCislo LONG, StrediskoNazov TEXT(50), OrganizaciaCislo LONG, BlokovanyStary YESNO, " & _
               "Telefon TEXT(50), Mobil TEXT(50), Organizacia TEXT(100), Pracovisko TEXT(100), Oddelenie TEXT(150), " & _
               "ManagerDN TEXT(255), ManagerLogin TEXT(100), ManagerMeno TEXT(150), ManagerEmail TEXT(255))"

    ' Plná štruktúra DochadzkaImport so všetkými novými poliami (vrátane ručných úprav dochádzky)
    db.Execute "CREATE TABLE DochadzkaImport (ID AUTOINCREMENT PRIMARY KEY, Datum DATE, Cas LONG, DatumSnim DATE, CisPam LONG, DatumPoc DATE, CasPoc LONG, " & _
               "OsobneCislo TEXT(20), KodPrerusenia LONG, Platnost YESNO, Zdroj LONG, Uzivatel TEXT(50), OdpracDoba LONG, Poradie LONG, StavUza YESNO, Poznamka LONGTEXT, " & _
               "CisloPreruseni LONG, Smer TEXT(1), RucneUpravene YESNO, ZdrojZapisu TEXT(30), UzivatelZmeny TEXT(50), DatumZmeny DATETIME)"

    db.Execute "CREATE TABLE TypyUdalosti (Kod LONG PRIMARY KEY, Nazov TEXT(100), Typ TEXT(1), Kategoria TEXT(50), ZapocitatDoPrace YESNO)"

    db.Execute "CREATE TABLE DochadzkaDni (ID AUTOINCREMENT PRIMARY KEY, OsobneCislo TEXT(20), Datum DATE, TypDna TEXT(5), " & _
               "DennyFondMin LONG, OdpracovaneMin LONG, NadcasMin LONG, UznanyNadcasMin LONG, SaldoMin LONG, PriebezneSaldoMin LONG)"

    db.Execute "CREATE TABLE DochadzkaIntervaly (ID AUTOINCREMENT PRIMARY KEY, OsobneCislo TEXT(20), Datum DATE, Poradie INTEGER, " & _
               "CisloPreruseni LONG, NazovPreruseni TEXT(50), ZaciatokMin LONG, KoniecMin LONG, ZaciatokText TEXT(10), KoniecText TEXT(10), TrvanieMin LONG)"

    db.Execute "CREATE TABLE DochadzkaMesiacSumar (ID AUTOINCREMENT PRIMARY KEY, OsobneCislo TEXT(20), Rok INTEGER, Mesiac INTEGER, " & _
               "MesacnyFondMin LONG, MesacnyFondDni INTEGER, OdpracovaneMin LONG, OdpracovaneDni INTEGER, NadcasMin LONG, UznanyNadcasMin LONG, " & _
               "StavMesiacaMin LONG, StavPracDenMin LONG, RozpadPreruseni LONGTEXT)"

    Call mod_01_SystemInit.VytvorTabulkyImportu(db)
    Call mod_01_SystemInit.InicializujPravidlaAnomalii

    db.TableDefs.Refresh
    DBEngine.Idle dbRefreshCache

    Call mod_00_Common.NastavImportDokonceny(False)
    Call mod_00_Common.SetPoslednyKrok(1)
    Call mod_00_Common.VytvorFrmProgress
    Call mod_00_Common.ZapisLog("InicializujDatabazuV2", "INFO", "Inicializácia databázy úspešná." & IIf(Len(strZaloha) > 0, " Záloha: " & strZaloha, ""))
    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("InicializujDatabazuV2", "ERROR", "Chyba inicializácie databázy: " & Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Zálohuje dôležité tabuľky do tabuliek bak_<yyyymmdd_hhnnss>_<názov>. Vráti predponu zálohy ("" ak nebolo čo zálohovať).
'-------------------------------------------------------------------------------
Private Function ZalohujTabulky(ByRef db As DAO.Database) As String
    On Error Resume Next
    Dim v As Variant, strPred As String, n As Long
    strPred = "bak_" & Format$(Now, "yyyymmdd_hhnnss") & "_"
    For Each v In Array("DochadzkaImport", "Zamestnanci", "NastaveniaSystemu", "CiselnikPreruseni", "KodyRazeni", "CiselnikPravidielAnomalii", _
                        "DochadzkaAutoOpravy", "DochadzkaUpraveneDni", "DochadzkaImportPovodne", "DochadzkaAudit", "Sviatky", "DochadzkaUzavierka", "DochadzkaUzavierkaLog")
        If mod_00_Common.TabulkaExistujeDB(db, CStr(v)) Then
            Err.Clear
            db.Execute "SELECT * INTO [" & strPred & CStr(v) & "] FROM [" & CStr(v) & "];", dbFailOnError
            If Err.Number = 0 Then n = n + 1
        End If
    Next v
    If n > 0 Then ZalohujTabulky = strPred & "*"
End Function

'-------------------------------------------------------------------------------
' Pomocná DDL funkcia: vytvorí index, ak ešte neexistuje (pri chybe duplicít unikátny index preskočí).
'-------------------------------------------------------------------------------
Private Sub VytvorIndexAkChyba(ByRef db As DAO.Database, ByVal strTab As String, ByVal strIdx As String, ByVal strStlpce As String, Optional ByVal bUnikatny As Boolean = False)
    On Error GoTo Chyba
    Dim ix As DAO.Index
    If Not mod_00_Common.TabulkaExistujeDB(db, strTab) Then Exit Sub
    For Each ix In db.TableDefs(strTab).Indexes
        If StrComp(ix.Name, strIdx, vbTextCompare) = 0 Then Exit Sub
    Next ix
    db.Execute "CREATE " & IIf(bUnikatny, "UNIQUE ", "") & "INDEX " & strIdx & " ON [" & strTab & "] (" & strStlpce & ")", dbFailOnError
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("VytvorIndexAkChyba", "WARN", "Index " & strIdx & " na " & strTab & " sa nepodarilo vytvoriť: " & Err.Description)
End Sub

'-------------------------------------------------------------------------------
' MIGRÁCIA DÁTOVÉHO MODELU (bezpečná, opakovateľná, bez straty dát):
'  - DochadzkaImport: DovodNeplatnosti, PovodneID, DovodZmeny (nedeštruktívne úpravy), ExterneID + Zariadenie
'    (idempotentný príjem z terminálu), index (OsobneCislo, Datum)
'  - DochadzkaDni: unikátny index (OsobneCislo, Datum), DochadzkaIntervaly / MesiacSumar: indexy
'  - DochadzkaAutoOpravy, rozšírené DochadzkaAnomalie, Sviatky.Rok, AutoKoniecDoKoncaSmeny, Zamestnanci.ManagerOC
'-------------------------------------------------------------------------------
Public Sub MigrujDatovyModel(ByRef db As DAO.Database)
    On Error GoTo Chyba
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaImport") Then
        Call PridajStlpec(db, "DochadzkaImport", "DovodNeplatnosti", "TEXT(50)")
        Call PridajStlpec(db, "DochadzkaImport", "PovodneID", "LONG")
        Call PridajStlpec(db, "DochadzkaImport", "DovodZmeny", "TEXT(255)")
        Call PridajStlpec(db, "DochadzkaImport", "ExterneID", "TEXT(50)")
        Call PridajStlpec(db, "DochadzkaImport", "Zariadenie", "TEXT(30)")
        Call VytvorIndexAkChyba(db, "DochadzkaImport", "idxDI_OC_Datum", "OsobneCislo, Datum")
        Call VytvorIndexAkChyba(db, "DochadzkaImport", "idxDI_ExterneID", "ExterneID")
    End If
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaDni") Then Call VytvorIndexAkChyba(db, "DochadzkaDni", "idxDD_OC_Datum", "OsobneCislo, Datum", True)
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaIntervaly") Then Call VytvorIndexAkChyba(db, "DochadzkaIntervaly", "idxDInt_OC_Datum", "OsobneCislo, Datum")
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaMesiacSumar") Then Call VytvorIndexAkChyba(db, "DochadzkaMesiacSumar", "idxDMS_OC_RM", "OsobneCislo, Rok, Mesiac")
    If mod_00_Common.TabulkaExistujeDB(db, "Zamestnanci") Then
        Call PridajStlpec(db, "Zamestnanci", "ManagerOC", "TEXT(20)")
        Call PridajStlpec(db, "Zamestnanci", "ZdrojZaznamu", "TEXT(10)")
    End If
    Call mod_10_Konfiguracia.ZabezpecStlpceKonfiguracie(db)
    Call mod_09_AutoOprava.ZabezpecTabulky(db)
    Call mod_12_TerminalPriprava.ZabezpecTabulky(db)
    Call mod_18_Uzavierka.ZabezpecTabulky(db)       ' uzávierka mesiaca (zámok po tlači a podpise zostavy)
    db.TableDefs.Refresh
    Call mod_15_Zamestnanci.ZabezpecModel(db)       ' vyradenie, úväzok, fond podľa dňa, pravidlá prerušení
    db.TableDefs.Refresh
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("MigrujDatovyModel", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Kontroluje štruktúru pri bežnom štarte databázy.
'-------------------------------------------------------------------------------
Public Sub ZabezpecStrukturuImportu()
    On Error GoTo ChybaHandler
    Dim db As DAO.Database
    Set db = CurrentDb

    Call ZmazAkStaraStruktura("CiselnikPreruseni", "Cislo")
    Call ZmazAkStaraStruktura("ZamestnanciFondy", "ZmenyKod")
    Call ZmazAkStaraStruktura("KalendarDni", "Datum")
    Call ZmazAkStaraStruktura("PracovneFondy", "Rok")

    Call VytvorTabulkyImportu(db)
    Call InicializujPravidlaAnomalii

    If mod_00_Common.TabulkaExistuje("Zamestnanci") Then
        Call PridajStlpec(db, "Zamestnanci", "Titul", "TEXT(20)")
        Call PridajStlpec(db, "Zamestnanci", "CisloKarty", "LONG")
        Call PridajStlpec(db, "Zamestnanci", "StrediskoCislo", "LONG")
        Call PridajStlpec(db, "Zamestnanci", "StrediskoNazov", "TEXT(50)")
        Call PridajStlpec(db, "Zamestnanci", "OrganizaciaCislo", "LONG")
        Call PridajStlpec(db, "Zamestnanci", "BlokovanyStary", "YESNO")
        Call PridajStlpec(db, "Zamestnanci", "Telefon", "TEXT(50)")
        Call PridajStlpec(db, "Zamestnanci", "Mobil", "TEXT(50)")
        Call PridajStlpec(db, "Zamestnanci", "Organizacia", "TEXT(100)")
        Call PridajStlpec(db, "Zamestnanci", "Pracovisko", "TEXT(100)")
        Call PridajStlpec(db, "Zamestnanci", "Oddelenie", "TEXT(150)")
        Call PridajStlpec(db, "Zamestnanci", "ManagerDN", "TEXT(255)")
        Call PridajStlpec(db, "Zamestnanci", "ManagerLogin", "TEXT(100)")
        Call PridajStlpec(db, "Zamestnanci", "ManagerMeno", "TEXT(150)")
        Call PridajStlpec(db, "Zamestnanci", "ManagerEmail", "TEXT(255)")
    End If

    If mod_00_Common.TabulkaExistuje("DochadzkaImport") Then
        Call PridajStlpec(db, "DochadzkaImport", "CisloPreruseni", "LONG")
        Call PridajStlpec(db, "DochadzkaImport", "Smer", "TEXT(1)")
        Call PridajStlpec(db, "DochadzkaImport", "RucneUpravene", "YESNO")
        Call PridajStlpec(db, "DochadzkaImport", "ZdrojZapisu", "TEXT(30)")
        Call PridajStlpec(db, "DochadzkaImport", "UzivatelZmeny", "TEXT(50)")
        Call PridajStlpec(db, "DochadzkaImport", "DatumZmeny", "DATETIME")
    End If
    
    If mod_00_Common.TabulkaExistuje("ParametrePreruseni") Then
        Call PridajStlpec(db, "ParametrePreruseni", "KodPaM", "LONG")
    End If

    Call MigrujDatovyModel(db)
    db.TableDefs.Refresh
    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("ZabezpecStrukturuImportu", "ERROR", "Chyba kontroly štruktúry: " & Err.Description)
End Sub

'-------------------------------------------------------------------------------
' DOČASNÁ VÝVOJÁRSKA PROCEDÚRA: Doplní chýbajúce stĺpce bez straty dát.
' Samostatná procedúra bez parametrov pre ručné spustenie v Immediate Window (Ctrl+G).
'-------------------------------------------------------------------------------
Public Sub Dev_DoplnStlpceBezReimportu()
    On Error GoTo ChybaHandler
    Dim db As DAO.Database
    Set db = CurrentDb

    If mod_00_Common.TabulkaExistuje("DochadzkaImport") Then
        Call PridajStlpecAkChyba(db, "DochadzkaImport", "CisloPreruseni", "LONG")
        Call PridajStlpecAkChyba(db, "DochadzkaImport", "Smer", "TEXT(1)")
        Call PridajStlpecAkChyba(db, "DochadzkaImport", "RucneUpravene", "YESNO")
        Call PridajStlpecAkChyba(db, "DochadzkaImport", "ZdrojZapisu", "TEXT(30)")
        Call PridajStlpecAkChyba(db, "DochadzkaImport", "UzivatelZmeny", "TEXT(50)")
        Call PridajStlpecAkChyba(db, "DochadzkaImport", "DatumZmeny", "DATETIME")
    End If
    
    If mod_00_Common.TabulkaExistuje("CiselnikPreruseni") Then
        Call PridajStlpecAkChyba(db, "CiselnikPreruseni", "ParentCisloPreruseni", "LONG")
        Call PridajStlpecAkChyba(db, "CiselnikPreruseni", "VyzadujePamSablonu", "YESNO")
        Call PridajStlpecAkChyba(db, "CiselnikPreruseni", "ZapocitavatDoPrace", "YESNO")
        Call PridajStlpecAkChyba(db, "CiselnikPreruseni", "OdpocitavatZDovolenky", "YESNO")
        Call PridajStlpecAkChyba(db, "CiselnikPreruseni", "AutoKoniecDoKoncaSmeny", "YESNO")
    End If
    
    db.TableDefs.Refresh
    MsgBox "Stĺpce boli úspešne doplnené bez reimportu.", vbInformation, "Dev Upgrade"
    Exit Sub

ChybaHandler:
    MsgBox "Chyba pri dopĺňaní stĺpcov: " & Err.Description, vbCritical, "Dev Upgrade"
End Sub

'-------------------------------------------------------------------------------
' Skrytá pomocná DDL funkcia pre dočasný vývojársky upgrade stĺpcov.
'-------------------------------------------------------------------------------
Private Sub PridajStlpecAkChyba(ByVal db As DAO.Database, ByVal strTabulka As String, ByVal strPole As String, ByVal strTyp As String)
    On Error GoTo ChybaHandler
    If Not mod_00_Common.PoleExistujeDB(db, strTabulka, strPole) Then
        db.Execute "ALTER TABLE [" & strTabulka & "] ADD COLUMN [" & strPole & "] " & strTyp, dbFailOnError
        Call mod_00_Common.ZapisLog("PridajStlpecAkChyba", "INFO", "Pridaný vývojársky stĺpec: " & strTabulka & "." & strPole)
    End If
    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("PridajStlpecAkChyba", "ERROR", "Chyba pridávania stĺpca " & strTabulka & "." & strPole & ": " & Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Bezpečne odstráni databázovú tabuľku, ak existuje.
'-------------------------------------------------------------------------------
Private Sub ZmazTabulku(ByVal Tabulka As String)
    On Error GoTo Chyba
    If mod_00_Common.TabulkaExistuje(Tabulka) Then
        CurrentDb.Execute "DROP TABLE [" & Tabulka & "]"
        Call mod_00_Common.ZapisLog("ZabezpecStrukturuImportu", "INFO", "Zmazaná tabuľka: " & Tabulka)
    End If
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("ZabezpecStrukturuImportu", "ERROR", "Nepodarilo sa zmazať tabuľku " & Tabulka & ": " & Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Testuje starú štruktúru tabuľky a v prípade nekompatibility ju vymaže pre re-inicializáciu.
'-------------------------------------------------------------------------------
Private Sub ZmazAkStaraStruktura(ByVal Tabulka As String, ByVal NoveKlucovePole As String)
    ' Tabuľka so starou štruktúrou sa NEMAŽE - premenuje sa na old_<čas>_<názov> a vytvorí sa nová (dáta ostávajú zachované).
    On Error GoTo Chyba
    Dim strNovy As String
    If mod_00_Common.TabulkaExistuje(Tabulka) Then
        If Not mod_00_Common.PoleExistujeDB(CurrentDb, Tabulka, NoveKlucovePole) Then
            strNovy = "old_" & Format$(Now, "yyyymmdd_hhnnss") & "_" & Tabulka
            CurrentDb.TableDefs(Tabulka).Name = strNovy
            CurrentDb.TableDefs.Refresh
            Call mod_00_Common.ZapisLog("ZabezpecStrukturuImportu", "WARN", "Tabuľka " & Tabulka & " mala starú štruktúru, premenovaná na " & strNovy)
        End If
    End If
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("ZabezpecStrukturuImportu", "ERROR", "Nepodarilo sa premenovať tabuľku " & Tabulka & ": " & Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Pomocná DDL funkcia pre bezpečné pridanie stĺpca do tabuľky.
'-------------------------------------------------------------------------------
Private Sub PridajStlpec(ByVal db As DAO.Database, ByVal Tabulka As String, ByVal pole As String, ByVal Typ As String)
    On Error GoTo Chyba
    If Not mod_00_Common.PoleExistujeDB(db, Tabulka, pole) Then
        db.Execute "ALTER TABLE [" & Tabulka & "] ADD COLUMN " & pole & " " & Typ
    End If
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("ZabezpecStrukturuImportu", "ERROR", "Nepodarilo sa pridať stĺpec " & Tabulka & "." & pole & ": " & Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Pomocná DDL funkcia na vytvorenie tabuľky, ak neexistuje.
'-------------------------------------------------------------------------------
Private Sub VytvorAkChyba(ByVal db As DAO.Database, ByVal Tabulka As String, ByVal Ddl As String)
    On Error GoTo Chyba
    If Not mod_00_Common.TabulkaExistuje(Tabulka) Then db.Execute Ddl
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("ZabezpecStrukturuImportu", "ERROR", "Nepodarilo sa vytvoriť tabuľku " & Tabulka & ": " & Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Vytvára DDL štruktúry číselníkových a konfiguračných tabuliek.
'-------------------------------------------------------------------------------
Public Sub VytvorTabulkyImportu(ByVal db As DAO.Database)
    Dim s As String, z As Long, d As Long

    Call VytvorAkChyba(db, "ZamestnanciFondy", _
        "CREATE TABLE ZamestnanciFondy (OsobneCislo TEXT(20), PracFondKod LONG, ParDochKod LONG, ParPrerKod LONG, KalendarKod LONG, ZmenyKod LONG, " & _
        "Rok INTEGER, Mesiac INTEGER, CONSTRAINT PK_ZF PRIMARY KEY (OsobneCislo, Rok, Mesiac))")

    Call VytvorAkChyba(db, "CiselnikPreruseni", _
        "CREATE TABLE CiselnikPreruseni (Cislo LONG PRIMARY KEY, Nazov TEXT(100), NazovSkratka TEXT(20), TextPredvolba TEXT(50), " & _
        "KodZaciatok LONG, TextZaciatok TEXT(50), FunkciaZaciatok LONG, KodKoniec LONG, TextKoniec TEXT(50), FunkciaKoniec LONG, " & _
        "TypVypoctu TEXT(30), ZapocitavatDoFondu YESNO, AutoDopocet YESNO, ParentCisloPreruseni LONG, VyzadujePamSablonu YESNO, " & _
        "ZapocitavatDoPrace YESNO, OdpocitavatZDovolenky YESNO, AutoKoniecDoKoncaSmeny YESNO)")

    Call VytvorAkChyba(db, "KodyRazeni", _
        "CREATE TABLE KodyRazeni (KodRazenia LONG PRIMARY KEY, CisloPreruseni LONG, Smer TEXT(1), TextRazenia TEXT(50))")

    Call VytvorAkChyba(db, "PracovneFondy", _
        "CREATE TABLE PracovneFondy (Cislo LONG, Rok INTEGER, Mesiac INTEGER, Nazov TEXT(100), AutoGenerovanie YESNO, PocetZmien INTEGER, " & _
        "TypFondu INTEGER, TypOpakovania INTEGER, PriemernaDlzkaMin LONG, DlzkaMesiacaMin LONG, AutoPVDni YESNO, AutoPS YESNO, " & _
        "CONSTRAINT PK_PracFond PRIMARY KEY (Cislo, Rok, Mesiac))")

    s = "CREATE TABLE PracovneFondyDni (Cislo LONG, Rok INTEGER, Mesiac INTEGER, Den INTEGER, "
    For z = 1 To 3
        s = s & "Zac" & z & " LONG, Kon" & z & " LONG, "
        s = s & "Prest1Zac" & z & " LONG, Prest1Kon" & z & " LONG, Prest2Zac" & z & " LONG, Prest2Kon" & z & " LONG, "
        s = s & "MaxPred" & z & " LONG, MaxPo" & z & " LONG, "
    Next z
    s = s & "DlzkaSPrestavkouMin LONG, DlzkaBezPrestavkyMin LONG, ZacVnutorne LONG, KonVnutorne LONG, "
    s = s & "CONSTRAINT PK_PracFondDni PRIMARY KEY (Cislo, Rok, Mesiac, Den))"
    Call VytvorAkChyba(db, "PracovneFondyDni", s)

    Call VytvorAkChyba(db, "SablonyDochadzky", _
        "CREATE TABLE SablonyDochadzky (Cislo LONG, Rok INTEGER, Mesiac INTEGER, Nazov TEXT(100), PlusCas LONG, MinusCas LONG, Surove LONGTEXT, " & _
        "CONSTRAINT PK_SablDoch PRIMARY KEY (Cislo, Rok, Mesiac))")
    Call VytvorAkChyba(db, "SablonyNadcasov", _
        "CREATE TABLE SablonyNadcasov (Cislo LONG, Rok INTEGER, Mesiac INTEGER, DolnaHranicaMin LONG, " & _
        "MaxZdrojTyzdenMin LONG, MaxNahradneVolnoTyzdenMin LONG, Surove LONGTEXT, " & _
        "CONSTRAINT PK_SablNadc PRIMARY KEY (Cislo, Rok, Mesiac))")
    Call VytvorAkChyba(db, "SablonyPraceVNoci", _
        "CREATE TABLE SablonyPraceVNoci (Cislo LONG, Rok INTEGER, Mesiac INTEGER, Surove LONGTEXT, " & _
        "CONSTRAINT PK_SablNoc PRIMARY KEY (Cislo, Rok, Mesiac))")

    s = "CREATE TABLE ParametrePreruseni (Sablona LONG, Rok INTEGER, Mesiac INTEGER, CisloPreruseni LONG, NazovSablony TEXT(50), NazovPreruseni TEXT(50), KodPaM LONG, " & _
        "KonverznaTabulka LONG, IntervalMesiacOdMin LONG, IntervalMesiacDoMin LONG, OdpocitaniePrestavky YESNO, " & _
        "ZaokruhlenieZaciatkuKonca LONG, ZaokruhlenieTrvania LONG, MaxTrvanieMesiacMin LONG, PrerusenieAkPrekroceny LONG, MaxTrvanieDniTyzdna YESNO, " & _
        "AutoDopocetTyp LONG, AutoDopocetCasMin LONG, PredvolbaTyp LONG, PredvolbaCasMin LONG, PredvolbaVolnyDen YESNO, PredvolbaPracSviatok YESNO, " & _
        "IntervalDniTyzdna YESNO, PrevodTyp LONG, PrevodCasMin LONG, "
    For d = 1 To 7
        s = s & "MaxTrvanieDen" & d & "Min LONG, IntervalDen" & d & "OdMin LONG, IntervalDen" & d & "DoMin LONG, "
    Next d
    s = s & "Surove LONGTEXT, CONSTRAINT PK_ParPrer PRIMARY KEY (Sablona, Rok, Mesiac, CisloPreruseni))"
    Call VytvorAkChyba(db, "ParametrePreruseni", s)

    Call VytvorAkChyba(db, "Kalendare", _
        "CREATE TABLE Kalendare (Cislo LONG, Rok INTEGER, Mesiac INTEGER, Nazov TEXT(50), AutoGenerovanie YESNO, TypKalendara YESNO, " & _
        "PorZac INTEGER, PorNas INTEGER, Prac INTEGER, Volno INTEGER, TypyDni TEXT(35), " & _
        "CONSTRAINT PK_Kalendare PRIMARY KEY (Cislo, Rok, Mesiac))")
    Call VytvorAkChyba(db, "KalendarDni", _
        "CREATE TABLE KalendarDni (Kalendar LONG, Datum DATETIME, TypDna TEXT(1), CONSTRAINT PK_KalendarDni PRIMARY KEY (Kalendar, Datum))")
    Call VytvorAkChyba(db, "Sviatky", _
        "CREATE TABLE Sviatky (ID AUTOINCREMENT PRIMARY KEY, Den INTEGER, Mesiac INTEGER, Nazov TEXT(50))")
End Sub

'-------------------------------------------------------------------------------
' Inicializácia číselníka pravidiel anomálií s automatickou kontrolou verzie
'-------------------------------------------------------------------------------
Public Sub InicializujPravidlaAnomalii()
    On Error GoTo ChybaHandler
    Dim db As DAO.Database
    Dim strSQL As String
    Dim strTabulka As String
    Dim bPotrebneVytvorit As Boolean
    
    Set db = CurrentDb
    strTabulka = "CiselnikPravidielAnomalii"
    bPotrebneVytvorit = False

    ' 1. Test existencie a verzie štruktúry tabuľky
    If mod_00_Common.TabulkaExistujeDB(db, strTabulka) Then
        If Not JeStrukturaTabulkyAktualna(db, strTabulka) Then
            Call mod_00_Common.ZapisLog("InicializujPravidlaAnomalii", "WARN", "Zistená stará verzia tabuľky " & strTabulka & ". Prebieha zmazanie a rekonštrukcia...")
            Call VymazTabulku(db, strTabulka)
            bPotrebneVytvorit = True
        End If
    Else
        bPotrebneVytvorit = True
    End If

    ' 2. Vytvorenie a naplnenie najnovšou verziou štruktúry a pravidiel
    If bPotrebneVytvorit Then

        strSQL = "CREATE TABLE " & strTabulka & " (" & _
                 "KodAnomalie VARCHAR(50) PRIMARY KEY, " & _
                 "NazovAnomalie VARCHAR(150), " & _
                 "TypPravidla VARCHAR(50), " & _
                 "FazaSpracovania VARCHAR(30), " & _
                 "Priorita INT, " & _
                 "SposobRiesenia VARCHAR(50), " & _
                 "RezimVyhodnotenia VARCHAR(30), " & _
                 "CasovyLimitMin INT, " & _
                 "Parametre VARCHAR(255), " & _
                 "Aktivne YESNO, " & _
                 "PopisAnomalie MEMO" & _
                 ");"
        db.Execute strSQL, dbFailOnError

        ' Vloženie aktuálnej sady pravidiel
        db.Execute "INSERT INTO CiselnikPravidielAnomalii VALUES (" & _
                   "'KOLIZIA_PAM_VS_TERMINAL', " & _
                   "'Súbežná mzdová šablóna PAM a pípnutie', " & _
                   "'KOLIZIA_UDALOSTI', 'KONSOLIDACIA', 10, " & _
                   "'PRIORITA_TERMINAL', 'AUTOMATICKY', 0, " & _
                   "'DeaktivovatPAM=True', True, " & _
                   "'Fyzické pípnutie karty na termináli má prednosť pred celodennou šablónou z PAM. Šablóna z PAM sa zneplatní.');", dbFailOnError

        db.Execute "INSERT INTO CiselnikPravidielAnomalii VALUES (" & _
                   "'DUPLICITA_DO_10MIN', " & _
                   "'Zneplatnenie duplicity rovnakého kódu do X minút', " & _
                   "'DUPLICITA_UDALOSTI', 'KONSOLIDACIA', 20, " & _
                   "'AUTO_DEAKTIVOVAT', 'AUTOMATICKY', 10, " & _
                   "'Ponechat=PrveRazenie; ZneplatnitDruhe=True', True, " & _
                   "'Bezpečné zneplatnenie: Ak je rovnaký kód pípnutý 2x do 10 minút, druhé pípnutie sa zneplatní (Platnost=False).');", dbFailOnError

        db.Execute "INSERT INTO CiselnikPravidielAnomalii VALUES (" & _
                   "'PLYNULY_PRECHOD', " & _
                   "'Plynulý prechod prerušení v rovnakej minúte', " & _
                   "'POVOLENY_PRECHOD', 'ENGINE', 30, " & _
                   "'IGNOROVAT', 'AUTOMATICKY', 0, " & _
                   "'ToleranciaMin=0; ZachovatObe=True', True, " & _
                   "'Ukončenie jedného prerušenia a začiatok druhého v rovnakej minúte je platný prechod s nulovým trvaním.');", dbFailOnError

        db.Execute "INSERT INTO CiselnikPravidielAnomalii VALUES (" & _
                   "'AUTO_OBED_NAD_6H', " & _
                   "'Automatický odpočet obeda po 6 odpracovaných hodinách', " & _
                   "'KONTROLA_FONDU', 'ENGINE', 40, " & _
                   "'AUTO_DOPLNIT', 'AUTOMATICKY', 360, " & _
                   "'TrvanieObedaMin=30; NepipnutyObed=True', True, " & _
                   "'Ak zamestnanec odpracuje viac ako 6 hodín (360 minút) a nepípol prestávku na obed, engine automaticky odpočíta 30 minút obeda.');", dbFailOnError

        db.Execute "INSERT INTO CiselnikPravidielAnomalii VALUES (" & _
                   "'OPAKOVANY_KOD_NAD_10MIN', " & _
                   "'Opakovaný kód bez ukončenia s odstupom nad X minút', " & _
                   "'OPAKOVANY_KOD', 'KONSOLIDACIA', 50, " & _
                   "'VYSTAZA', 'MANUAL', 10, " & _
                   "'FormUpozornenie=ZmenaKodu', True, " & _
                   "'Dvakrát pípaný rovnaký kód s odstupom vyšším ako 10 minút bez odchodu. Vyžaduje preverenie a manuálnu korekciu.');", dbFailOnError

        db.Execute "INSERT INTO CiselnikPravidielAnomalii VALUES (" & _
                   "'NEPARNY_POCET_RAZENI', " & _
                   "'Nepárny počet pípnutí / Chýbajúci odchod domov', " & _
                   "'NEUPLNA_POSTUPNOST', 'ENGINE', 60, " & _
                   "'AUTO_DOPLNIT', 'KONTROLA', 60, " & _
                   "'MaxSaldoMin=60; DoplnitPodlaFondu=True', True, " & _
                   "'Chýbajúce pípnutie v dni. Engine preverí saldo dňa a pri odchýlke nad 60 minút označí deň ako anomáliu.');", dbFailOnError

        Call mod_00_Common.ZapisLog("InicializujPravidlaAnomalii", "INFO", "Tabuľka " & strTabulka & " bola úspešne zrekonštruovaná na najnovšiu verziu.")
    End If
    Exit Sub

ChybaHandler:
    Call mod_00_Common.ZapisLog("InicializujPravidlaAnomalii", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Pomocná súkromná procedúra na bezpečné odstránenie tabuľky z DB.
'-------------------------------------------------------------------------------
Private Sub VymazTabulku(ByRef db As DAO.Database, ByVal strNazovTabulky As String)
    ' Nemaže - premenuje starú tabuľku na old_<čas>_<názov>, aby nikdy nedošlo k strate dát.
    On Error Resume Next
    db.TableDefs(strNazovTabulky).Name = "old_" & Format$(Now, "yyyymmdd_hhnnss") & "_" & strNazovTabulky
    db.TableDefs.Refresh
    On Error GoTo 0
End Sub

'-------------------------------------------------------------------------------
' Pomocná súkromná funkcia na verifikáciu verzie štruktúry tabuľky.
'-------------------------------------------------------------------------------
Private Function JeStrukturaTabulkyAktualna(ByRef db As DAO.Database, ByVal strNazovTabulky As String) As Boolean
    On Error GoTo ChybaHandler
    Dim tdf As DAO.TableDef
    Dim fld As DAO.Field
    Dim bMaTypPravidla As Boolean
    Dim bMaPopisAnomalie As Boolean
    Dim bMaPriorita As Boolean

    Set tdf = db.TableDefs(strNazovTabulky)

    For Each fld In tdf.Fields
        Select Case fld.Name
            Case "TypPravidla": bMaTypPravidla = True
            Case "PopisAnomalie": bMaPopisAnomalie = True
            Case "Priorita": bMaPriorita = True
        End Select
    Next fld

    JeStrukturaTabulkyAktualna = (bMaTypPravidla And bMaPopisAnomalie And bMaPriorita)
    Exit Function

ChybaHandler:
    JeStrukturaTabulkyAktualna = False
End Function


