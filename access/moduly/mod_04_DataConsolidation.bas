Attribute VB_Name = "mod_04_DataConsolidation"
'@Verzia 2.5.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_04_DataConsolidation
' POPIS: Modul pre konsolidáciu, dátovú hygienu, validáciu pripravenosti dát
'        a aplikáciu pravidiel z CiselnikPravidielAnomalii.
'===============================================================================

Private Const MODUL_FAZA As String = "KONSOLIDACIA" ' Prepínač fázy pre načítanie pravidiel

'-------------------------------------------------------------------------------
' Overí pripravenosť dát v databáze podľa stavu naimportovaných tabuliek.
'-------------------------------------------------------------------------------
Public Function ZistiStavPripravenostiData(Optional ByVal iRok As Integer = 0, Optional ByVal iMesiac As Integer = 0, Optional ByRef strDetail As String = "") As Long
    On Error GoTo ChybaHandler
    
    Dim db As DAO.Database
    Dim lZamPocet As Long, lPrerPocet As Long, lRazPocet As Long, lRazCelkovo As Long
    Dim dMaxDatum As Variant
    Set db = CurrentDb
    
    ' 1. Kontrola zamestnancov
    If mod_00_Common.TabulkaExistujeDB(db, "Zamestnanci") Then
        lZamPocet = DCount("*", "Zamestnanci")
    End If
    
    ' 2. Kontrola prerušení / kódov razení
    If mod_00_Common.TabulkaExistujeDB(db, "KodyRazeni") Then
        lPrerPocet = DCount("*", "KodyRazeni")
    End If
    If lPrerPocet = 0 And mod_00_Common.TabulkaExistujeDB(db, "CiselnikPreruseni") Then
        lPrerPocet = DCount("*", "CiselnikPreruseni")
    End If
    
    ' 3. Kontrola razení dochádzky
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaImport") Then
        lRazCelkovo = DCount("*", "DochadzkaImport")
        
        If iRok = 0 Or iMesiac = 0 Then
            dMaxDatum = DMax("Datum", "DochadzkaImport")
            If Not IsNull(dMaxDatum) And IsDate(dMaxDatum) Then
                If iRok = 0 Then iRok = Year(CDate(dMaxDatum))
                If iMesiac = 0 Then iMesiac = Month(CDate(dMaxDatum))
            End If
        End If
        
        If iRok > 0 And iMesiac > 0 Then
            lRazPocet = DCount("*", "DochadzkaImport", "Datum >= " & mod_00_Common.SqlDatum(DateSerial(iRok, iMesiac, 1)) & " AND Datum < " & mod_00_Common.SqlDatum(DateSerial(iRok, iMesiac + 1, 1)))
        Else
            lRazPocet = lRazCelkovo
        End If
    End If
    
    ' Vyhodnotenie stavu pripravenosti
    If lZamPocet = 0 And lPrerPocet = 0 And lRazCelkovo = 0 Then
        ZistiStavPripravenostiData = 0
        strDetail = "Databáza je iba inicializovaná (DDL). Neboli importované žiadne dáta."
    ElseIf lZamPocet = 0 Then
        ZistiStavPripravenostiData = 1
        strDetail = "V databáze neboli nájdení žiadni zamestnanci. Importujte cis_zamestnanec.dbf, načítajte CSV alebo zamestnancov z Active Directory."
    ElseIf lPrerPocet = 0 Then
        ZistiStavPripravenostiData = 2
        strDetail = "V databáze chýba číselník prerušení a kódov razení. Importujte cis_preruseni.dbf alebo použite INICIALIZOVAŤ PREDVOLENÚ KONFIGURÁCIU v záložke 5."
    ElseIf lRazCelkovo = 0 Or lRazPocet = 0 Then
        ZistiStavPripravenostiData = 3
        If iRok > 0 And iMesiac > 0 Then
            strDetail = "Číselníky sú prítomné (" & lZamPocet & " zamestnancov, " & lPrerPocet & " prerušení), ale v DochadzkaImport chýbajú razenia pre obdobie " & iMesiac & "/" & iRok & "."
        Else
            strDetail = "Číselníky sú prítomné, ale neboli načítané žiadne dochádzkové razenia."
        End If
    Else
        ZistiStavPripravenostiData = 4
        strDetail = "Dáta sú pripravené na konsolidáciu pre obdobie " & iMesiac & "/" & iRok & _
                   " (" & lZamPocet & " zamestnancov, " & lPrerPocet & " prerušení, " & lRazPocet & " razení v tomto mesiaci)."
    End If
    Exit Function

ChybaHandler:
    ZistiStavPripravenostiData = -1
    strDetail = "Chyba pri zisťovaní stavu dát: " & Err.Description
End Function

'-------------------------------------------------------------------------------
' Rýchly Boolean test pripravenosti konsolidácie.
'-------------------------------------------------------------------------------
Public Function JeMozneSpustitKonsolidaciu(Optional ByVal iRok As Integer = 0, Optional ByVal iMesiac As Integer = 0) As Boolean
    Dim strDetail As String, lStav As Long
    lStav = ZistiStavPripravenostiData(iRok, iMesiac, strDetail)
    JeMozneSpustitKonsolidaciu = (lStav >= 3)
End Function

'-------------------------------------------------------------------------------
' Hlavný orchestrátor konsolidácie dát za zvolené/detegované obdobie.
'-------------------------------------------------------------------------------
Public Function SpracujKonsolidaciuObdobia(Optional ByVal iRok As Integer = 0, Optional ByVal iMesiac As Integer = 0) As Boolean
    On Error GoTo ChybaHandler

    Dim db As DAO.Database, strStavDetail As String, lStav As Long
    Dim dMaxDatum As Variant
    Dim lAnomaliePocet As Long, lVyreseneRules As Long, lChybajuceNastavenia As Long
    
    If iRok = 0 Or iMesiac = 0 Then
        dMaxDatum = DMax("Datum", "DochadzkaImport")
        If Not IsNull(dMaxDatum) And IsDate(dMaxDatum) Then
            If iRok = 0 Then iRok = Year(CDate(dMaxDatum))
            If iMesiac = 0 Then iMesiac = Month(CDate(dMaxDatum))
        End If
    End If

    lStav = ZistiStavPripravenostiData(iRok, iMesiac, strStavDetail)
    If lStav < 3 Then
        MsgBox "Konsolidáciu nie je možné spustiť:" & vbCrLf & strStavDetail, vbExclamation, "Konsolidácia dát"
        Call mod_00_Common.ZapisLog("SpracujKonsolidaciuObdobia", "WARNING", "Konsolidácia zrušená: " & strStavDetail)
        SpracujKonsolidaciuObdobia = False
        Exit Function
    End If

    Set db = CurrentDb
    Call mod_01_SystemInit.MigrujDatovyModel(db)      ' doplní stĺpce a tabuľky potrebné pre konsolidáciu a auto-opravy

    Call mod_00_Common.ZapisLog("SpracujKonsolidaciuObdobia", "INFO", "Štart konsolidácie dát pre obdobie: " & iMesiac & "/" & iRok)
    Call mod_00_Common.PripravProgressForm

    ' 1. Krok: Dátová hygiena a oprava kódov prerušení
    Call mod_00_Common.AktualizujProgressGUI("Oprava kódov prerušení...", 1, 5)
    Call mod_04_DataConsolidation.SkontrolujAOpravKodyPreruseni

    ' 2. Krok: Vytvorenie pomocnej tabuľky pre anomálie
    Call mod_00_Common.AktualizujProgressGUI("Príprava tabuľky anomálií...", 2, 5)
    Call mod_04_DataConsolidation.VytvorTabulkuAnomalii(db)

    ' 3. Krok: Aplikácia pravidiel definovaných pre fázu KONSOLIDACIA
    Call mod_00_Common.AktualizujProgressGUI("Aplikácia pravidiel konsolidácie...", 3, 5)
    lVyreseneRules = mod_04_DataConsolidation.AplikujPravidlaKonsolidacie(iRok, iMesiac)

    ' 4. Krok: Detekcia nerozriešených anomálií pre manuálny prehľad
    Call mod_00_Common.AktualizujProgressGUI("Analýza pípnutí a návrhy automatických opráv...", 4, 5)
    lAnomaliePocet = mod_04_DataConsolidation.DetegujAnomalieARazenia(iRok, iMesiac)

    ' 5. Krok: Kontrola pokrytia fondov zamestnancov
    Call mod_00_Common.AktualizujProgressGUI("Kontrola nastavení zamestnancov...", 5, 5)
    lChybajuceNastavenia = mod_04_DataConsolidation.OverPokrytieNastaveni(iRok, iMesiac)

    Call mod_00_Common.ZavriProgressForm

    Call mod_00_Common.ZapisLog("SpracujKonsolidaciuObdobia", "INFO", _
        "Konsolidácia dokončená. Auto-vyčistené: " & lVyreseneRules & ", Nájdene anomálie: " & lAnomaliePocet & ", Chýbajúce fondy: " & lChybajuceNastavenia)

    MsgBox "Konsolidácia obdobia " & iMesiac & "/" & iRok & " bola úspešne dokončená." & vbCrLf & _
           "- Automaticky ošetrené pravidlá: " & lVyreseneRules & vbCrLf & _
           "- Anomálie na ručné posúdenie: " & lAnomaliePocet & vbCrLf & _
           "- Automatické opravy: uplatnené " & mod_09_AutoOprava.PocetNavrhov(iRok, iMesiac, "UPLATNENE") & ", návrhy na schválenie " & mod_09_AutoOprava.PocetNavrhov(iRok, iMesiac, "NAVRH") & _
           " (záložka 3)" & vbCrLf & _
           "- Zamestnanci bez priradeného fondu (použije sa predvolený): " & lChybajuceNastavenia, vbInformation, "Konsolidácia dát"

    SpracujKonsolidaciuObdobia = True
    Exit Function

ChybaHandler:
    Call mod_00_Common.ZavriProgressForm
    Call mod_00_Common.ZapisLog("SpracujKonsolidaciuObdobia", "ERROR", Err.Description)
    SpracujKonsolidaciuObdobia = False
End Function

'-------------------------------------------------------------------------------
' DYNAMICKÁ APLIKÁCIA PRAVIDIEL Z TABUĽKY CiselnikPravidielAnomalii
' Načítava iba pravidlá pre FazaSpracovania = 'KONSOLIDACIA'
'-------------------------------------------------------------------------------
Public Function AplikujPravidlaKonsolidacie(Optional ByVal iRok As Integer = 0, Optional ByVal iMesiac As Integer = 0) As Long
    On Error GoTo ChybaHandler
    Dim db As DAO.Database, rsPravidla As DAO.Recordset
    Dim strSQL As String, lPocetOsetrenych As Long
    Set db = CurrentDb

    ' 1. Overenie, či existuje číselník pravidiel
    If Not mod_00_Common.TabulkaExistujeDB(db, "CiselnikPravidielAnomalii") Then
        Call mod_00_Common.ZapisLog("AplikujPravidlaKonsolidacie", "WARN", "Tabuľka CiselnikPravidielAnomalii neexistuje.")
        AplikujPravidlaKonsolidacie = 0
        Exit Function
    End If

    ' 2. Výber aktívnych pravidiel pre fázu KONSOLIDACIA podľa priority
    strSQL = "SELECT KodAnomalie, SposobRiesenia, CasovyLimitMin, Parametre " & _
             "FROM CiselnikPravidielAnomalii " & _
             "WHERE FazaSpracovania='" & MODUL_FAZA & "' AND Aktivne=True " & _
             "ORDER BY Priorita ASC"

    Set rsPravidla = db.OpenRecordset(strSQL, dbOpenSnapshot)
    lPocetOsetrenych = 0

    ' 3. Postupné vykonanie pravidiel
    Do While Not rsPravidla.EOF
        Dim strKod As String, strSposob As String, lLimit As Long
        strKod = Trim(Nz(rsPravidla!KodAnomalie, ""))
        strSposob = Trim(Nz(rsPravidla!SposobRiesenia, ""))
        lLimit = CLng(Nz(rsPravidla!CasovyLimitMin, 0))

        Select Case strKod
            Case "KOLIZIA_PAM_VS_TERMINAL"
                ' Fyzické pípnutie karty má prednosť pred celodennou PAM šablónou
                lPocetOsetrenych = lPocetOsetrenych + VyriesKoliziuPamVsTerminal(db, iRok, iMesiac)

            Case "DUPLICITA_DO_10MIN"
                ' Zneplatnenie druhej duplicity do N minút
                If lLimit = 0 Then lLimit = 10
                lPocetOsetrenych = lPocetOsetrenych + VyriesDuplicituDoLimit(db, iRok, iMesiac, lLimit)

        End Select

        rsPravidla.MoveNext
    Loop
    rsPravidla.Close

    AplikujPravidlaKonsolidacie = lPocetOsetrenych
    Exit Function

ChybaHandler:
    Call mod_00_Common.ZapisLog("AplikujPravidlaKonsolidacie", "ERROR", Err.Description)
    AplikujPravidlaKonsolidacie = -1
End Function

'-------------------------------------------------------------------------------
' Pomocná funkcia: Zneplatní celodennú PAM šablónu IBA ak fyzická práca pokrýva smenu
'-------------------------------------------------------------------------------
Private Function VyriesKoliziuPamVsTerminal(ByRef db As DAO.Database, ByVal iRok As Integer, ByVal iMesiac As Integer) As Long
    On Error GoTo ChybaHandler
    Dim rs As DAO.Recordset, dicTerm As Object, strSQL As String, strWhereD As String, lDotknute As Long
    Dim strKluc As String, v As Variant, lMin As Long, lMax As Long

    If iRok > 0 And iMesiac > 0 Then
        strWhereD = " AND Datum >= " & mod_00_Common.SqlDatum(DateSerial(iRok, iMesiac, 1)) & " AND Datum < " & mod_00_Common.SqlDatum(DateSerial(iRok, iMesiac + 1, 1))
    End If

    ' 1) rozsah fyzických pípnutí (terminál) za deň a zamestnanca - agregačný dotaz iba na čítanie
    Set dicTerm = CreateObject("Scripting.Dictionary")
    strSQL = "SELECT OsobneCislo, Datum, MIN(Cas) AS MinCas, MAX(Cas) AS MaxCas FROM DochadzkaImport " & _
             "WHERE (CisPam = 0 OR CisPam IS NULL) AND " & mod_00_Common.SqlPlatne() & strWhereD & " GROUP BY OsobneCislo, Datum;"
    Set rs = db.OpenRecordset(strSQL, dbOpenSnapshot)
    Do While Not rs.EOF
        dicTerm(CStr(rs!OsobneCislo) & "|" & Format$(rs!Datum, "yyyymmdd")) = Array(CLng(Nz(rs!MinCas, 0)), CLng(Nz(rs!MaxCas, 0)))
        rs.MoveNext
    Loop
    rs.Close

    ' 2) PAM šablóny - jednoduchý aktualizovateľný dotaz (po ID); ručne upravené riadky sa nemenia
    strSQL = "SELECT * FROM DochadzkaImport WHERE CisPam > 0 AND " & mod_00_Common.SqlPlatne() & _
             " AND (RucneUpravene IS NULL OR RucneUpravene = False)" & strWhereD & ";"
    Set rs = db.OpenRecordset(strSQL, dbOpenDynaset)
    Do While Not rs.EOF
        strKluc = CStr(rs!OsobneCislo) & "|" & Format$(rs!Datum, "yyyymmdd")
        If dicTerm.Exists(strKluc) Then
            v = dicTerm(strKluc)
            lMin = v(0): lMax = v(1)
            ' ak fyzické pípnutia na termináli trvali >= 420 minút (7 hodín), PAM šablóna sa zneplatní
            If lMax - lMin >= 420 Then
                rs.Edit
                rs!Platnost = False
                rs!DovodNeplatnosti = "PAM_KOLIZIA"
                rs!Poznamka = Left$(Trim$(Nz(rs!Poznamka, "") & " Auto-zneplatnená celodenná PAM šablóna (odpracovaný plný deň na termináli)"), 2000)
                rs!DatumZmeny = Now
                rs!UzivatelZmeny = "SYSTEM"
                rs.Update
                lDotknute = lDotknute + 1
            End If
        End If
        rs.MoveNext
    Loop
    rs.Close

    If lDotknute > 0 Then
        Call mod_00_Common.ZapisLog("VyriesKoliziuPamVsTerminal", "INFO", "Vyriešených kolízií PAM vs Terminál: " & lDotknute)
    End If

    VyriesKoliziuPamVsTerminal = lDotknute
    Exit Function

ChybaHandler:
    Call mod_00_Common.ZapisLog("VyriesKoliziuPamVsTerminal", "ERROR", Err.Description)
    VyriesKoliziuPamVsTerminal = 0
End Function

'-------------------------------------------------------------------------------
' Pomocná funkcia: Zneplatní opakované pípnutie karty s rovnakým kódom do N minút
'-------------------------------------------------------------------------------
Private Function VyriesDuplicituDoLimit(ByRef db As DAO.Database, ByVal iRok As Integer, ByVal iMesiac As Integer, ByVal lLimitMin As Long) As Long
    On Error GoTo ChybaHandler
    Dim rs As DAO.Recordset, strSQL As String
    Dim strPrevOC As String, dPrevCas As Date, dCurrCas As Date
    Dim strPrevKod As String, strCurrKod As String
    Dim strPrevSmer As String, strCurrSmer As String
    Dim lCasVal As Long, lZneplatnene As Long
    Dim lLimitSec As Long

    lLimitSec = lLimitMin * 60

    strSQL = "SELECT * FROM DochadzkaImport WHERE " & mod_00_Common.SqlPlatne() & " "

    If iRok > 0 And iMesiac > 0 Then
        strSQL = strSQL & "AND Datum >= " & mod_00_Common.SqlDatum(DateSerial(iRok, iMesiac, 1)) & " AND Datum < " & mod_00_Common.SqlDatum(DateSerial(iRok, iMesiac + 1, 1)) & " "
    End If

    strSQL = strSQL & "ORDER BY OsobneCislo, Datum, Cas, ID"

    Set rs = db.OpenRecordset(strSQL, dbOpenDynaset)
    strPrevOC = "": lZneplatnene = 0

    Do While Not rs.EOF
        Dim strOC As String
        strOC = Trim(Nz(rs!OsobneCislo, ""))
        strCurrKod = Trim(Nz(rs!KodPrerusenia, ""))
        strCurrSmer = Trim(Nz(rs!smer, ""))

        If IsDate(rs!Datum) Then
            lCasVal = CLng(Nz(rs!Cas, 0))
            If lCasVal > 1440 Then
                dCurrCas = CDate(rs!Datum) + (CDbl(lCasVal) / 86400#)
            Else
                dCurrCas = CDate(rs!Datum) + (CDbl(lCasVal) / 1440#)
            End If

            If strOC = strPrevOC Then
                ' Ak ide o rovnaký kód a smer v rozmedzí do LimitMin, druhé pípnutie sa zneplatní
                If strCurrKod = strPrevKod And strCurrSmer = strPrevSmer Then
                    Dim lDiffSec As Long
                    lDiffSec = DateDiff("s", dPrevCas, dCurrCas)
                    If lDiffSec >= 0 And lDiffSec <= lLimitSec And Not CBool(Nz(rs!RucneUpravene, False)) Then
                        rs.Edit
                        rs!Platnost = False
                        rs!DovodNeplatnosti = "DUPLICITA"
                        rs!Poznamka = Left$(Trim$(Nz(rs!Poznamka, "") & " Auto-zneplatnená duplicita do " & lLimitMin & " min"), 2000)
                        rs!DatumZmeny = Now
                        rs!UzivatelZmeny = "SYSTEM"
                        rs.Update
                        lZneplatnene = lZneplatnene + 1
                    Else
                        dPrevCas = dCurrCas
                    End If
                Else
                    dPrevCas = dCurrCas
                    strPrevKod = strCurrKod
                    strPrevSmer = strCurrSmer
                End If
            Else
                strPrevOC = strOC
                dPrevCas = dCurrCas
                strPrevKod = strCurrKod
                strPrevSmer = strCurrSmer
            End If
        End If

        rs.MoveNext
    Loop
    rs.Close

    If lZneplatnene > 0 Then
        Call mod_00_Common.ZapisLog("VyriesDuplicituDoLimit", "INFO", "Zneplatnených duplicít do " & lLimitMin & " min: " & lZneplatnene)
    End If

    VyriesDuplicituDoLimit = lZneplatnene
    Exit Function

ChybaHandler:
    Call mod_00_Common.ZapisLog("VyriesDuplicituDoLimit", "ERROR", Err.Description)
    VyriesDuplicituDoLimit = 0
End Function

'-------------------------------------------------------------------------------
' Automatická oprava neznámych kódov prerušení.
'-------------------------------------------------------------------------------
Public Sub SkontrolujAOpravKodyPreruseni()
    On Error GoTo ChybaHandler
    Call mod_02_DBFImport.SkontrolujChybajucePrerusenia
    Call mod_02_DBFImport.DoplnPrerusenieDoDochadzky
    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("SkontrolujAOpravKodyPreruseni", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Overuje pokrytie fondov pre zamestnancov.
'-------------------------------------------------------------------------------
Public Function OverPokrytieNastaveni(Optional ByVal iRok As Integer = 0, Optional ByVal iMesiac As Integer = 0) As Long
    On Error GoTo ChybaHandler
    Dim db As DAO.Database, rs As DAO.Recordset
    Dim lChybaPocet As Long, dMaxDatum As Variant, strSQL As String
    Set db = CurrentDb

    If iRok = 0 Or iMesiac = 0 Then
        dMaxDatum = DMax("Datum", "DochadzkaImport")
        If Not IsNull(dMaxDatum) And IsDate(dMaxDatum) Then
            If iRok = 0 Then iRok = Year(CDate(dMaxDatum))
            If iMesiac = 0 Then iMesiac = Month(CDate(dMaxDatum))
        End If
    End If

    If iRok > 0 And iMesiac > 0 Then
        Dim lTargetYM As Long
        lTargetYM = CLng(iRok) * 12 + CLng(iMesiac)
        
        strSQL = "SELECT Z.OsobneCislo " & _
                 "FROM Zamestnanci AS Z LEFT JOIN (" & _
                 "   SELECT DISTINCT OsobneCislo FROM ZamestnanciFondy " & _
                 "   WHERE (Rok * 12 + Mesiac) <= " & lTargetYM & " AND OsobneCislo IS NOT NULL" & _
                 ") AS ZF ON Trim(Z.OsobneCislo) = Trim(ZF.OsobneCislo) " & _
                 "WHERE ZF.OsobneCislo IS NULL"
    Else
        strSQL = "SELECT Z.OsobneCislo " & _
                 "FROM Zamestnanci AS Z LEFT JOIN (" & _
                 "   SELECT DISTINCT OsobneCislo FROM ZamestnanciFondy WHERE OsobneCislo IS NOT NULL" & _
                 ") AS ZF ON Trim(Z.OsobneCislo) = Trim(ZF.OsobneCislo) " & _
                 "WHERE ZF.OsobneCislo IS NULL"
    End If

    Set rs = db.OpenRecordset(strSQL, dbOpenSnapshot)
    Do While Not rs.EOF
        lChybaPocet = lChybaPocet + 1
        rs.MoveNext
    Loop
    rs.Close

    OverPokrytieNastaveni = lChybaPocet
    Exit Function

ChybaHandler:
    Call mod_00_Common.ZapisLog("OverPokrytieNastaveni", "ERROR", Err.Description)
    OverPokrytieNastaveni = -1
End Function

'-------------------------------------------------------------------------------
' Analyzuje dni mesiaca, vygeneruje návrhy automatických opráv a uloží anomálie na ručné posúdenie do DochadzkaAnomalie.
' Vráti počet anomálií, ktoré vyžadujú ručné posúdenie (-1 pri chybe).
'-------------------------------------------------------------------------------
Public Function DetegujAnomalieARazenia(Optional ByVal iRok As Integer = 0, Optional ByVal iMesiac As Integer = 0) As Long
    On Error GoTo ChybaHandler
    Dim dMaxDatum As Variant
    If iRok = 0 Or iMesiac = 0 Then
        dMaxDatum = DMax("Datum", "DochadzkaImport")
        If Not IsNull(dMaxDatum) And IsDate(dMaxDatum) Then
            If iRok = 0 Then iRok = Year(CDate(dMaxDatum))
            If iMesiac = 0 Then iMesiac = Month(CDate(dMaxDatum))
        End If
    End If
    If iRok = 0 Or iMesiac = 0 Then Exit Function
    ' jednotná analýza dní (stavový automat) + návrhy automatických opráv - viď mod_09_AutoOprava
    DetegujAnomalieARazenia = mod_09_AutoOprava.AnalyzujObdobie(iRok, iMesiac)
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("DetegujAnomalieARazenia", "ERROR", Err.Description)
    DetegujAnomalieARazenia = -1
End Function

'-------------------------------------------------------------------------------
' Vytvára DDL štruktúru tabuľky DochadzkaAnomalie.
'-------------------------------------------------------------------------------
Public Sub VytvorTabulkuAnomalii(ByRef db As DAO.Database)
    On Error GoTo ChybaHandler
    If Not mod_00_Common.TabulkaExistujeDB(db, "DochadzkaAnomalie") Then
        Dim strSQL As String
        strSQL = "CREATE TABLE DochadzkaAnomalie (" & _
                 "ID COUNTER PRIMARY KEY, " & _
                 "OsobneCislo VARCHAR(20), " & _
                 "Rok INT, " & _
                 "Mesiac INT, " & _
                 "Datum DATETIME, " & _
                 "TypAnomalie VARCHAR(50), " & _
                 "PopisAnomalie VARCHAR(255), " & _
                 "DatumZaznamu DATETIME" & _
                 ");"
        db.Execute strSQL, dbFailOnError
    End If
    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("VytvorTabulkuAnomalii", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Uzamyká import dát a schvaľuje dáta pre výpočtový motor dochádzky.
'-------------------------------------------------------------------------------
Public Function ZamkniObdobieASchvalData() As Boolean
    On Error GoTo ChybaHandler
    Call mod_00_Common.NastavImportDokonceny(True)
    Call mod_00_Common.SetPoslednyKrok(4)
    Call mod_00_Common.ZapisLog("ZamkniObdobieASchvalData", "INFO", "Import dát bol uzamknutý a schválený na výpočet.")
    MsgBox "Import dát bol uzamknutý a schválený na výpočet.", vbInformation, "Schválenie dát"
    ZamkniObdobieASchvalData = True
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("ZamkniObdobieASchvalData", "ERROR", Err.Description)
    ZamkniObdobieASchvalData = False
End Function

'-------------------------------------------------------------------------------
' Programovo generuje formulár frmKonsolidaciaData pre obsluhu dátovej konsolidácie.
'-------------------------------------------------------------------------------
Public Sub VytvorFrmKonsolidaciaData()
    On Error GoTo ChybaHandler
    Dim frm As Form, strFrmName As String, ctl As Control

    strFrmName = "frmKonsolidaciaData"
    On Error Resume Next
    If mod_00_Common.FormIsOpen(strFrmName) Then DoCmd.Close acForm, strFrmName, acSaveNo
    DoCmd.DeleteObject acForm, strFrmName
    On Error GoTo ChybaHandler

    Set frm = CreateForm
    strFrmName = frm.Name

    With frm
        .Caption = "Konsolidácia a Príprava Dát Dochádzky"
        .RecordSelectors = False
        .NavigationButtons = False
        .DividingLines = False
        .ScrollBars = 0
        .AutoCenter = True
        .Width = 9600
        .Section(acDetail).Height = 7000
    End With

    ' Nadpis
    Set ctl = CreateControl(strFrmName, acLabel, acDetail, "", "", 400, 300, 8800, 400)
    ctl.Caption = "Dátová Hygiena, Kontrola Pokrytia a Aplikácia Pravidiel"
    ctl.FontSize = 13: ctl.FontBold = True: ctl.ForeColor = RGB(15, 30, 90)

    ' Tlačidlo 1: Oprava kódov
    Set ctl = CreateControl(strFrmName, acCommandButton, acDetail, "", "", 400, 1000, 4200, 500)
    ctl.Name = "btnOpravKody"
    ctl.Caption = "1. SPUSTIŤ KONTROLU A OPRAVU KÓDOV"
    ctl.FontBold = True
    ctl.OnClick = "=SkontrolujAOpravKodyPreruseni()"

    ' Tlačidlo 2: Pokrytie zamestnancov
    Set ctl = CreateControl(strFrmName, acCommandButton, acDetail, "", "", 4800, 1000, 4400, 500)
    ctl.Name = "btnSkontrolujNastavenia"
    ctl.Caption = "2. OVERIŤ PRIRADENIA FONDOV"
    ctl.FontBold = True

    ' Tlačidlo 3: Aplikácia Pravidiel Konsolidácie
    Set ctl = CreateControl(strFrmName, acCommandButton, acDetail, "", "", 400, 1700, 4200, 500)
    ctl.Name = "btnAplikujPravidla"
    ctl.Caption = "3. APLIKOVAŤ PRAVIDLÁ KONSOLIDÁCIE"
    ctl.FontBold = True
    ctl.OnClick = "=SpracujKonsolidaciuObdobia()"

    ' Tlačidlo 4: Správa Pravidiel
    Set ctl = CreateControl(strFrmName, acCommandButton, acDetail, "", "", 4800, 1700, 4400, 500)
    ctl.Name = "btnPravidla"
    ctl.Caption = "4. SPRÁVA PRAVIDIEL ANOMÁLIÍ"
    ctl.FontBold = True
    ctl.OnClick = "=OtvorPravidlaAnomalii()"

    ' Tlačidlo 5: Uzamknutie a schválenie
    Set ctl = CreateControl(strFrmName, acCommandButton, acDetail, "", "", 400, 2400, 8800, 600)
    ctl.Name = "btnSchvalData"
    ctl.Caption = "5. SCHVÁLIŤ DÁTA A ZAMKNÚŤ IMPORT"
    ctl.FontBold = True: ctl.ForeColor = RGB(0, 100, 0)
    ctl.OnClick = "=ZamkniObdobieASchvalData()"

    DoCmd.Save acForm, strFrmName
    DoCmd.Close acForm, strFrmName, acSaveYes
    DoCmd.Rename "frmKonsolidaciaData", acForm, strFrmName

    Call mod_00_Common.ZapisLog("VytvorFrmKonsolidaciaData", "INFO", "Formulár frmKonsolidaciaData bol úspešne vygenerovaný.")
    Exit Sub

ChybaHandler:
    Call mod_00_Common.ZapisLog("VytvorFrmKonsolidaciaData", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Otvorí editačný formulár pre správu pravidiel anomálií
'-------------------------------------------------------------------------------
Public Function OtvorPravidlaAnomalii()
    On Error GoTo ChybaHandler
    DoCmd.OpenForm "frmPravidlaAnomalii", acNormal
    Exit Function
ChybaHandler:
    Call mod_00_Common.ZapisLog("OtvorPravidlaAnomalii", "ERROR", Err.Description)
End Function


