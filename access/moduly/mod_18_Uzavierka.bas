Attribute VB_Name = "mod_18_Uzavierka"
'@Verzia 1.0.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_18_Uzavierka
' POPIS: Uzávierka mesiaca zamestnanca - zámok po vytlačení a podpise zostavy.
'
'   Postup: (1) zostava sa zobrazí a vytlačí (pri jej vytvorení sa zaznamená kontrolný kód údajov mesiaca),
'           (2) po podpise používateľ mesiac uzavrie (Uzavri) - zapíše sa kto, kedy a kto zostavu potvrdil,
'           (3) uzavretý mesiac sa už nedá zmeniť: nedajú sa upravovať ani pridávať razenia (editor, import z DBF,
'               terminál, staršia databáza), prepočítať výpočet, schvaľovať automatické opravy ani meniť parametre,
'               ktoré mesiac používa (pracovný fond, pravidlá prerušení, priradenie, úväzok, vyradenie),
'           (4) uzavretý mesiac sa dá znova otvoriť iba s uvedením dôvodu (Otvor) - každá zmena stavu sa zapíše
'               do tabuľky DochadzkaUzavierkaLog a po otvorení treba zostavu vytlačiť a podpísať znova.
'
'   Kontrolný kód (Sucet): zmena údajov, ktoré spravila iná cesta ako aplikácia (priamo v tabuľke), sa dá odhaliť
'   porovnaním troch súčtov uložených pri uzavretí - razenia, výpočet (dni, intervaly, mesačný súhrn) a parametre
'   (priradenie, typy dní s denným fondom, pracovný fond, pravidlá prerušení). Ide o kontrolný súčet na odhalenie
'   zmeny, nie o kryptografický podpis - kto má plný prístup k súboru databázy, môže upraviť aj samotné súčty.
'
'   Zámok je zámerne na úrovni aplikácie: chráni pred omylom a nechceným prepisom (import, prepočet, editor).
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - ZabezpecTabulky(db)                          : Vytvorí DochadzkaUzavierka a DochadzkaUzavierkaLog.
' - JeUzavrety / JeUzavretyDen                   : Je mesiac (deň) zamestnanca uzavretý?
' - ExistujeUzavrety / PocetUzavretych           : Existuje aspoň jeden uzavretý mesiac / koľko ich je.
' - SqlVynechUzavrete() / SqlNeuzavrete(...)     : SQL podmienky na vynechanie uzavretých mesiacov.
' - ZablokovanaUprava(OC, deň, hlásiť)           : True (a hlásenie), ak je mesiac dňa uzavretý.
' - PrepocetZakazany(db, OC, rok, mes)           : True, ak sa výpočet uzavretého mesiaca nesmie prepísať.
' - SpocitajSucty(...) / SnimkaParametrov(...)   : Kontrolné súčty a čitateľný snímok parametrov mesiaca.
' - ZaznamenajZostavu(OC, rok, mes)              : Zaznamená vytvorenie zostavy (vráti kontrolný kód).
' - Uz_TextZostavy(OC, rok, mes)                 : Text do pätičky zostavy (stav uzávierky a kontrolný kód).
' - Uzavri / Otvor                               : Uzavretie a opätovné otvorenie mesiaca (vrátia text chyby alebo "").
' - OverIntegritu / OverVsetky                   : Kontrola, či sa uzavreté údaje nezmenili.
' - DotknutyFond / DotknutaSablona / DotknutyZamestnanec / DotknutyVyradenim : Ktorý uzavretý mesiac by zmena zasiahla.
' - TextBlokovanejZmeny(...)                     : Jednotný text hlásenia o zablokovanej zmene.
' - NajstarsiMesiacZamestnanca / NajstarsiUzavretyMesiac : Pomocné pre zachovanie histórie pri prvom priradení.
' - PrepisNastaveniPovoleny / OznacNastaveniaLokalne     : Ochrana pred prepísaním nastavení importom z DBF.
'===============================================================================

Private Const TBL As String = "DochadzkaUzavierka"
Private Const TBL_LOG As String = "DochadzkaUzavierkaLog"
Public Const UZ_UZAVRETY As String = "UZAVRETY"
Public Const UZ_OTVORENY As String = "OTVORENY"
Private Const KLUC_LOKALNE As String = "NastaveniaUpravene"
Private Const CACHE_SEKUND As Long = 20

Private mUzav As Object          ' "OC|rok*12+mesiac" -> True (uzavreté mesiace)
Private mCas As Double           ' kedy sa načítala vyrovnávacia pamäť (Timer)
Private mPocet As Long
Private mTexty As Object         ' vyrovnávacia pamäť textov pätičky zostavy
Private mParCache As Object      ' vyrovnávacia pamäť textov fondu a pravidiel
Private mH1 As Double
Private mH2 As Double
Private mPrepis As Long          ' 0 = nezistené, 1 = povolené, 2 = zamietnuté
Private mTichoPrepis As Boolean
Private mBlokImport As String
Private mZozn As Object           ' texty zoznamu uzávierky (OC -> stav|zostava|uzavrel)
Private mZoznYm As Long
Private mZoznCas As Double

'===============================================================================
' TABUĽKY
'===============================================================================

Public Sub ZabezpecTabulky(ByRef db As DAO.Database)
    Dim bNova As Boolean
    On Error GoTo Chyba
    If Not mod_00_Common.TabulkaExistujeDB(db, TBL) Then
        db.Execute "CREATE TABLE " & TBL & " (ID AUTOINCREMENT PRIMARY KEY, OsobneCislo TEXT(20), Rok INTEGER, Mesiac INTEGER, Stav TEXT(10), " & _
                   "UzavrelDna DATETIME, Uzavrel TEXT(50), Potvrdil TEXT(100), Poznamka TEXT(255), " & _
                   "Sucet TEXT(25), SucetRazenia TEXT(25), SucetVypocet TEXT(25), SucetParametre TEXT(25), SnimkaParametrov LONGTEXT, " & _
                   "ZostavaDna DATETIME, ZostavaSucet TEXT(25), OtvorenyDna DATETIME, Otvoril TEXT(50), DovodOtvorenia TEXT(255), PocetOtvoreni LONG)", dbFailOnError
        bNova = True
    End If
    If bNova Then
        On Error Resume Next
        db.Execute "CREATE UNIQUE INDEX idxUz_OC_RM ON " & TBL & " (OsobneCislo, Rok, Mesiac)", dbFailOnError
        Err.Clear
        On Error GoTo Chyba
    End If
    If Not mod_00_Common.TabulkaExistujeDB(db, TBL_LOG) Then
        db.Execute "CREATE TABLE " & TBL_LOG & " (ID AUTOINCREMENT PRIMARY KEY, DatumCas DATETIME, Uzivatel TEXT(50), OsobneCislo TEXT(20), " & _
                   "Rok INTEGER, Mesiac INTEGER, Akcia TEXT(20), Sucet TEXT(25), Popis TEXT(255))", dbFailOnError
        db.TableDefs.Refresh
    ElseIf bNova Then
        db.TableDefs.Refresh
    End If
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_18_Uzavierka.ZabezpecTabulky", "ERROR", Err.Description)
End Sub

Private Sub LogUz(ByVal strOC As String, ByVal iRok As Long, ByVal iMes As Long, ByVal strAkcia As String, ByVal strSucet As String, ByVal strPopis As String)
    On Error Resume Next
    CurrentDb.Execute "INSERT INTO " & TBL_LOG & " (DatumCas, Uzivatel, OsobneCislo, Rok, Mesiac, Akcia, Sucet, Popis) VALUES (Now(), " & _
                      mod_00_Common.SqlText(mod_00_Common.Uzivatel()) & ", " & mod_00_Common.SqlText(strOC) & ", " & iRok & ", " & iMes & ", " & _
                      mod_00_Common.SqlText(Left$(strAkcia, 20)) & ", " & mod_00_Common.SqlText(Left$(strSucet, 25)) & ", " & _
                      mod_00_Common.SqlText(Left$(strPopis, 255)) & ");", dbFailOnError
    Call mod_00_Common.ZapisLog("Uzavierka", "INFO", strAkcia & " " & strOC & " " & iMes & "/" & iRok & ": " & strPopis)
End Sub

'===============================================================================
' STAV MESIACA (vyrovnávacia pamäť sa po 20 s načíta znova, aby bola aktuálna aj pri práci viacerých používateľov)
'===============================================================================

Public Sub ResetCache()
    Set mUzav = Nothing
    Set mTexty = Nothing
    Set mZozn = Nothing
End Sub

Private Function Kluc(ByVal strOC As String, ByVal iRok As Long, ByVal iMes As Long) As String
    Kluc = strOC & "|" & (iRok * 12 + iMes)
End Function

Private Sub NacitajCache()
    Dim rs As DAO.Recordset, k As String
    On Error GoTo Koniec
    Set mUzav = CreateObject("Scripting.Dictionary")
    mPocet = 0
    mCas = Timer
    If Not mod_00_Common.TabulkaExistuje(TBL) Then Exit Sub
    Set rs = CurrentDb.OpenRecordset("SELECT OsobneCislo, Rok, Mesiac FROM " & TBL & " WHERE Stav = '" & UZ_UZAVRETY & "';", dbOpenSnapshot)
    Do While Not rs.EOF
        k = Kluc(CStr(Nz(rs!OsobneCislo, "")), CLng(Nz(rs!Rok, 0)), CLng(Nz(rs!Mesiac, 0)))
        If Not mUzav.Exists(k) Then
            mUzav.Add k, True
            mPocet = mPocet + 1
        End If
        rs.MoveNext
    Loop
    rs.Close
Koniec:
End Sub

Private Sub ObnovCacheAkTreba()
    If mUzav Is Nothing Then
        Call NacitajCache
    ElseIf Abs(Timer - mCas) > CACHE_SEKUND Then
        Call NacitajCache
    End If
End Sub

Public Function JeUzavrety(ByVal strOC As String, ByVal iRok As Long, ByVal iMes As Long) As Boolean
    On Error Resume Next
    Call ObnovCacheAkTreba
    If mPocet = 0 Then Exit Function
    JeUzavrety = mUzav.Exists(Kluc(strOC, iRok, iMes))
End Function

Public Function JeUzavretyDen(ByVal strOC As String, ByVal vDatum As Variant) As Boolean
    On Error Resume Next
    If Not IsDate(vDatum) Then Exit Function
    JeUzavretyDen = JeUzavrety(strOC, Year(CDate(vDatum)), Month(CDate(vDatum)))
End Function

Public Function ExistujeUzavrety() As Boolean
    On Error Resume Next
    Call ObnovCacheAkTreba
    ExistujeUzavrety = (mPocet > 0)
End Function

Public Function PocetUzavretych(Optional ByVal iRok As Long = 0, Optional ByVal iMes As Long = 0) As Long
    Dim k As Variant, ym As Long, p As Variant
    On Error Resume Next
    Call ObnovCacheAkTreba
    If iRok = 0 Then
        PocetUzavretych = mPocet
        Exit Function
    End If
    ym = iRok * 12 + iMes
    For Each k In mUzav.Keys
        p = Split(CStr(k), "|")
        If UBound(p) = 1 Then
            If CLng(p(1)) = ym Then PocetUzavretych = PocetUzavretych + 1
        End If
    Next k
End Function

'-------------------------------------------------------------------------------
' " AND ID NOT IN (razenia v uzavretých mesiacoch)" na doplnenie do WHERE nad DochadzkaImport; bez uzavretých mesiacov "".
'-------------------------------------------------------------------------------
Public Function SqlVynechUzavrete() As String
    If Not ExistujeUzavrety() Then Exit Function
    SqlVynechUzavrete = " AND ID NOT IN (SELECT D9.ID FROM DochadzkaImport AS D9, " & TBL & " AS U9 WHERE D9.OsobneCislo = U9.OsobneCislo " & _
                        "AND Year(D9.Datum) = U9.Rok AND Month(D9.Datum) = U9.Mesiac AND U9.Stav = '" & UZ_UZAVRETY & "')"
End Function

'-------------------------------------------------------------------------------
' " AND NOT EXISTS (...)" - riadky zdrojovej tabuľky (alias strAlias) s razeniami v uzavretých mesiacoch sa nepreberajú.
'-------------------------------------------------------------------------------
Public Function SqlVynechUzavreteZdroj(ByVal strAlias As String) As String
    If Not ExistujeUzavrety() Then Exit Function
    SqlVynechUzavreteZdroj = " AND NOT EXISTS (SELECT 1 FROM " & TBL & " AS U8 WHERE U8.Stav = '" & UZ_UZAVRETY & "' AND U8.OsobneCislo = " & strAlias & ".OsobneCislo " & _
                             "AND U8.Rok = Year(" & strAlias & ".Datum) AND U8.Mesiac = Month(" & strAlias & ".Datum))"
End Function

'-------------------------------------------------------------------------------
' " AND pole NOT IN ('a','b')" - zamestnanci, ktorí majú mesiac iRok/iMes uzavretý; ak nikto, "".
'-------------------------------------------------------------------------------
Public Function SqlNeuzavrete(ByVal iRok As Long, ByVal iMes As Long, ByVal strPoleOC As String) As String
    Dim k As Variant, p As Variant, ym As Long, s As String
    On Error Resume Next
    If Not ExistujeUzavrety() Then Exit Function
    ym = iRok * 12 + iMes
    For Each k In mUzav.Keys
        p = Split(CStr(k), "|")
        If UBound(p) = 1 Then
            If CLng(p(1)) = ym Then s = s & IIf(Len(s) > 0, ",", "") & mod_00_Common.SqlText(CStr(p(0)))
        End If
    Next k
    If Len(s) > 0 Then SqlNeuzavrete = " AND " & strPoleOC & " NOT IN (" & s & ")"
End Function

Private Function MenoOC(ByVal strOC As String) As String
    Dim v As Variant
    On Error Resume Next
    v = DLookup("CeleMeno", "Zamestnanci", "OsobneCislo = " & mod_00_Common.SqlText(strOC))
    If Len(Trim$(CStr(Nz(v, "")))) = 0 Then
        MenoOC = strOC
    Else
        MenoOC = Trim$(CStr(v)) & " (" & strOC & ")"
    End If
End Function

Public Function TextBlokovanejZmeny(ByVal strDotknuty As String) As String
    TextBlokovanejZmeny = "Zmenu nie je možné uložiť - zasiahla by uzavretý (podpísaný) mesiac: " & strDotknuty & "." & vbCrLf & vbCrLf & _
        "Zvoľte platnosť od mesiaca po poslednom uzavretom mesiaci, alebo najprv uzavretý mesiac otvorte " & _
        "(záložka 6 Výpočet - Uzávierka mesiaca; otvorenie sa zapíše aj s dôvodom)."
End Function

'-------------------------------------------------------------------------------
' Je mesiac dňa uzavretý? Pri bHlasit zobrazí vysvetlenie (editor dňa, ručné zásahy).
'-------------------------------------------------------------------------------
Public Function ZablokovanaUprava(ByVal strOC As String, ByVal vDatum As Variant, Optional ByVal bHlasit As Boolean = True) As Boolean
    If Not JeUzavretyDen(strOC, vDatum) Then Exit Function
    ZablokovanaUprava = True
    If bHlasit Then
        MsgBox "Mesiac " & Month(CDate(vDatum)) & "/" & Year(CDate(vDatum)) & " zamestnanca " & MenoOC(strOC) & " je uzavretý - zostava bola vytlačená a podpísaná." & _
               vbCrLf & vbCrLf & "Razenia sa v uzavretom mesiaci nedajú meniť. Ak je zmena nevyhnutná, mesiac najprv otvorte " & _
               "(záložka 6 Výpočet - Uzávierka mesiaca; potrebný je dôvod) a po úprave zostavu vytlačte a podpíšte znova.", _
               vbExclamation, "Uzavretý mesiac"
    End If
End Function

'-------------------------------------------------------------------------------
' Výpočet uzavretého mesiaca sa nesmie prepísať, ak výpočtové riadky existujú. Ak chýbajú (napr. po prenose databázy),
' dajú sa vytvoriť znova - kontrola súčtov potom ukáže, či sa zhodujú s uzavretými.
'-------------------------------------------------------------------------------
Public Function PrepocetZakazany(ByRef db As DAO.Database, ByVal strOC As String, ByVal iRok As Long, ByVal iMes As Long) As Boolean
    On Error Resume Next
    If Not JeUzavrety(strOC, iRok, iMes) Then Exit Function
    If Not mod_00_Common.TabulkaExistujeDB(db, "DochadzkaDni") Then Exit Function
    PrepocetZakazany = (Nz(DCount("*", "DochadzkaDni", "OsobneCislo = " & mod_00_Common.SqlText(strOC) & _
                         " AND Datum >= " & mod_00_Common.SqlDatum(DateSerial(iRok, iMes, 1)) & _
                         " AND Datum < " & mod_00_Common.SqlDatum(DateSerial(iRok, iMes + 1, 1))), 0) > 0)
End Function

'===============================================================================
' KONTROLNÉ SÚČTY
'===============================================================================

Private Sub HashStart()
    mH1 = 7
    mH2 = 11
End Sub

Private Sub HashPridaj(ByVal s As String)
    Dim i As Long, c As Double
    For i = 1 To Len(s)
        c = AscW(Mid$(s, i, 1))
        If c < 0 Then c = c + 65536
        mH1 = mH1 * 257 + c
        mH1 = mH1 - Int(mH1 / 4294967291#) * 4294967291#
        mH2 = mH2 * 131 + c
        mH2 = mH2 - Int(mH2 / 2147483647#) * 2147483647#
    Next i
End Sub

Private Function HashVysledok() As String
    HashVysledok = Format$(mH1, "0000000000") & "-" & Format$(mH2, "0000000000")
End Function

Private Function VT(ByVal v As Variant) As String
    If IsNull(v) Then
        VT = "~"
        Exit Function
    End If
    Select Case VarType(v)
        Case vbBoolean
            If CBool(v) Then VT = "1" Else VT = "0"
        Case vbDate
            VT = Format$(v, "yyyymmddhhnn")
        Case vbSingle, vbDouble, vbCurrency, vbDecimal
            VT = Trim$(Str$(CDbl(v)))
        Case vbString
            VT = Trim$(CStr(v))
        Case Else
            VT = CStr(v)
    End Select
End Function

Private Function Bool01(ByVal v As Variant) As String
    On Error Resume Next
    If CBool(Nz(v, False)) Then Bool01 = "1" Else Bool01 = "0"
End Function

Private Function PoleHodn(ByRef rs As DAO.Recordset, ByVal strPole As String) As String
    Dim x As Variant
    On Error Resume Next
    x = rs.Fields(strPole).Value
    If Err.Number <> 0 Then
        Err.Clear
        PoleHodn = "?"
        Exit Function
    End If
    PoleHodn = VT(x)
End Function

Private Sub HashRs(ByRef rs As DAO.Recordset, ByVal strPred As String, ByVal vPole As Variant)
    Dim v As Variant, s As String
    Do While Not rs.EOF
        s = strPred
        For Each v In vPole
            s = s & "|" & PoleHodn(rs, CStr(v))
        Next v
        HashPridaj s & vbLf
        rs.MoveNext
    Loop
End Sub

Private Sub ParCacheReset()
    Set mParCache = Nothing
End Sub

'-------------------------------------------------------------------------------
' Text pracovného fondu a pravidiel prerušení šablóny platných pre mesiac (čitateľný, bez čísel verzií).
' Pravidlá, ktoré sú vypnuté alebo neexistujú, sa nevypisujú (nemajú žiadny účinok).
'-------------------------------------------------------------------------------
Private Function TextFonduAPravidiel(ByRef db As DAO.Database, ByVal lFond As Long, ByVal lSab As Long, ByVal iRok As Long, ByVal iMes As Long) As String
    Dim kl As String, d As Object, s As String, n As Long, rs As DAO.Recordset, lCis As Long
    On Error GoTo Chyba
    kl = lFond & "|" & lSab & "|" & (iRok * 12 + iMes)
    If mParCache Is Nothing Then Set mParCache = CreateObject("Scripting.Dictionary")
    If mParCache.Exists(kl) Then
        TextFonduAPravidiel = CStr(mParCache.Item(kl))
        Exit Function
    End If
    Set d = CreateObject("Scripting.Dictionary")
    If mod_17_FondyPravidla.NacitajFond(lFond, CInt(iRok), CInt(iMes), d) Then
        s = "FOND " & lFond & " [" & CStr(d("Nazov")) & "] typ=" & d("Typ") & " opak=" & d("Opak") & " denny=" & d("Denny") & _
            " mesacny=" & d("Mesacny") & " podla=" & Bool01(d("PodlaDna"))
        For n = 1 To 7
            s = s & " d" & n & "=" & d("D" & n & "Od") & "-" & d("D" & n & "Do") & "/" & d("D" & n & "Fond") & "/" & d("D" & n & "Prest")
        Next n
        s = s & vbLf
    Else
        s = "FOND " & lFond & " (bez verzie)" & vbLf
    End If
    If mod_00_Common.TabulkaExistujeDB(db, "ParametrePreruseni") Then
        Set rs = db.OpenRecordset("SELECT DISTINCT CisloPreruseni FROM ParametrePreruseni WHERE Sablona = " & lSab & " ORDER BY CisloPreruseni;", dbOpenSnapshot)
        Do While Not rs.EOF
            lCis = CLng(Nz(rs!CisloPreruseni, 0))
            If lCis > 0 Then
                If mod_17_FondyPravidla.NacitajPravidlo(lSab, lCis, CInt(iRok), CInt(iMes), d) Then
                    If CBool(d("Existuje")) And CBool(d("Aktivne")) Then
                        s = s & "PRAVIDLO " & lCis & " [" & CStr(d("Nazov")) & "] od=" & d("IntOd") & " do=" & d("IntDo") & " max=" & d("Max") & _
                            " mino=" & d("MinO") & " mint=" & d("MinT") & " rozne=" & Bool01(d("RozneDni"))
                        If CBool(d("RozneDni")) Then
                            For n = 1 To 7
                                s = s & " d" & n & "=" & d("D" & n & "Od") & "-" & d("D" & n & "Do") & "/" & d("D" & n & "Max")
                            Next n
                        End If
                        s = s & vbLf
                    End If
                End If
            End If
            rs.MoveNext
        Loop
        rs.Close
    End If
    mParCache.Add kl, s
    TextFonduAPravidiel = s
    Exit Function
Chyba:
    TextFonduAPravidiel = "CHYBA nacitania parametrov: " & Err.Description & vbLf
    Call mod_00_Common.ZapisLog("mod_18_Uzavierka.TextFonduAPravidiel", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Čitateľný snímok parametrov, podľa ktorých sa mesiac zamestnanca počíta (ukladá sa pri uzavretí):
' priradenie, úväzok, typ a denný fond každého dňa (kalendár, sviatky), pracovný fond a pravidlá prerušení.
'-------------------------------------------------------------------------------
Public Function SnimkaParametrov(ByRef db As DAO.Database, ByVal strOC As String, ByVal iRok As Long, ByVal iMes As Long) As String
    Dim iOdR As Integer, iOdM As Integer, f As Long, p As Long, k As Long, y As Long, u As Long, kon As TKontextMesiaca, i As Long, s As String
    On Error GoTo Chyba
    Call mod_15_Zamestnanci.PlatnePriradenie(strOC, CInt(iRok), CInt(iMes), iOdR, iOdM, f, p, k, y)
    u = mod_15_Zamestnanci.UvazokZamestnanca(db, strOC, CInt(iRok), CInt(iMes))
    s = "PRIRADENIE fond=" & f & " sablona=" & p & " kalendar=" & k & " vykaz=" & y & " uvazok=" & u & vbLf
    Call mod_08_UdalostiDna.NacitajKontextMesiaca(db, strOC, CInt(iRok), CInt(iMes), kon)
    s = s & "DNI"
    For i = 1 To kon.PocetDni
        s = s & " " & kon.Typ(i) & ":" & kon.Fond(i)
    Next i
    s = s & vbLf
    s = s & TextFonduAPravidiel(db, f, p, iRok, iMes)
    SnimkaParametrov = s
    Exit Function
Chyba:
    SnimkaParametrov = "CHYBA snimky parametrov: " & Err.Description & vbLf
    Call mod_00_Common.ZapisLog("mod_18_Uzavierka.SnimkaParametrov", "ERROR", Err.Description, "OC=" & strOC)
End Function

'-------------------------------------------------------------------------------
' Vypočíta kontrolné súčty mesiaca zamestnanca: sRaz (platné razenia), sVyp (dni, intervaly, mesačný súhrn),
' sPar (parametre). strSnimka dostane čitateľný text parametrov. Vráti celkový kontrolný kód.
'-------------------------------------------------------------------------------
Public Function SpocitajSucty(ByRef db As DAO.Database, ByVal strOC As String, ByVal iRok As Long, ByVal iMes As Long, _
                              ByRef sRaz As String, ByRef sVyp As String, ByRef sPar As String, ByRef strSnimka As String) As String
    Dim dOd As Date, dDo As Date, strKrit As String, rs As DAO.Recordset
    On Error GoTo Chyba
    dOd = DateSerial(iRok, iMes, 1)
    dDo = DateSerial(iRok, iMes + 1, 1)
    strKrit = "OsobneCislo = " & mod_00_Common.SqlText(strOC) & " AND Datum >= " & mod_00_Common.SqlDatum(dOd) & " AND Datum < " & mod_00_Common.SqlDatum(dDo)

    ' 1. razenia (platné)
    Call HashStart
    Set rs = db.OpenRecordset("SELECT * FROM DochadzkaImport WHERE " & strKrit & " AND " & mod_00_Common.SqlPlatne() & _
                              " ORDER BY Datum, Cas, KodPrerusenia, ID;", dbOpenSnapshot)
    Call HashRs(rs, "R", Array("Datum", "Cas", "KodPrerusenia", "CisloPreruseni", "Smer"))
    rs.Close
    sRaz = HashVysledok()

    ' 2. výpočet
    Call HashStart
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaDni") Then
        Set rs = db.OpenRecordset("SELECT * FROM DochadzkaDni WHERE " & strKrit & " ORDER BY Datum;", dbOpenSnapshot)
        Call HashRs(rs, "D", Array("Datum", "TypDna", "DennyFondMin", "OdpracovaneMin", "NadcasMin", "UznanyNadcasMin", "SaldoMin", "PriebezneSaldoMin"))
        rs.Close
    End If
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaIntervaly") Then
        Set rs = db.OpenRecordset("SELECT * FROM DochadzkaIntervaly WHERE " & strKrit & " ORDER BY Datum, Poradie, ZaciatokMin;", dbOpenSnapshot)
        Call HashRs(rs, "I", Array("Datum", "Poradie", "CisloPreruseni", "ZaciatokMin", "KoniecMin", "TrvanieMin"))
        rs.Close
    End If
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaMesiacSumar") Then
        Set rs = db.OpenRecordset("SELECT * FROM DochadzkaMesiacSumar WHERE OsobneCislo = " & mod_00_Common.SqlText(strOC) & _
                                  " AND Rok = " & iRok & " AND Mesiac = " & iMes & ";", dbOpenSnapshot)
        Call HashRs(rs, "S", Array("OdpracovaneDni", "OdpracovaneMin", "StavMesiacaMin", "MesacnyFondMin", "MesacnyFondDni"))
        rs.Close
    End If
    sVyp = HashVysledok()

    ' 3. parametre
    strSnimka = SnimkaParametrov(db, strOC, iRok, iMes)
    Call HashStart
    Call HashPridaj(strSnimka)
    sPar = HashVysledok()

    Call HashStart
    Call HashPridaj(sRaz & "/" & sVyp & "/" & sPar)
    SpocitajSucty = HashVysledok()
    Exit Function
Chyba:
    SpocitajSucty = "CHYBA"
    Call mod_00_Common.ZapisLog("mod_18_Uzavierka.SpocitajSucty", "ERROR", Err.Description, "OC=" & strOC & ", " & iMes & "/" & iRok)
End Function

'===============================================================================
' ZOSTAVA, UZAVRETIE, OTVORENIE
'===============================================================================

Private Function OtvorRiadok(ByRef db As DAO.Database, ByVal strOC As String, ByVal iRok As Long, ByVal iMes As Long, ByVal bVytvor As Boolean) As DAO.Recordset
    Dim rs As DAO.Recordset
    Set rs = db.OpenRecordset("SELECT * FROM " & TBL & " WHERE OsobneCislo = " & mod_00_Common.SqlText(strOC) & _
                              " AND Rok = " & iRok & " AND Mesiac = " & iMes & ";", dbOpenDynaset)
    If rs.EOF And bVytvor Then
        rs.AddNew
        rs!OsobneCislo = strOC
        rs!Rok = iRok
        rs!Mesiac = iMes
        rs!Stav = UZ_OTVORENY
        rs!PocetOtvoreni = 0
        rs.Update
        rs.Close
        Set rs = db.OpenRecordset("SELECT * FROM " & TBL & " WHERE OsobneCislo = " & mod_00_Common.SqlText(strOC) & _
                                  " AND Rok = " & iRok & " AND Mesiac = " & iMes & ";", dbOpenDynaset)
    End If
    Set OtvorRiadok = rs
End Function

'-------------------------------------------------------------------------------
' Zaznamená vytvorenie zostavy: uloží čas a kontrolný kód údajov mesiaca (uzavretie je potom možné len s touto zostavou).
' Pri uzavretom mesiaci sa nič neprepíše - skontroluje sa, či sa údaje nezmenili. Vráti kontrolný kód ("" pri chybe).
'-------------------------------------------------------------------------------
Public Function ZaznamenajZostavu(ByVal strOC As String, ByVal iRok As Long, ByVal iMes As Long) As String
    Dim db As DAO.Database, rs As DAO.Recordset, sRaz As String, sVyp As String, sPar As String, strSn As String, strSuc As String
    On Error GoTo Chyba
    Set db = CurrentDb
    Call ZabezpecTabulky(db)
    Call ParCacheReset
    Set mTexty = Nothing
    Set mZozn = Nothing
    strSuc = SpocitajSucty(db, strOC, iRok, iMes, sRaz, sVyp, sPar, strSn)
    If strSuc = "CHYBA" Then Exit Function
    Set rs = OtvorRiadok(db, strOC, iRok, iMes, True)
    If Not rs.EOF Then
        If CStr(Nz(rs!Stav, "")) <> UZ_UZAVRETY Then
            rs.Edit
            rs!ZostavaDna = Now
            rs!ZostavaSucet = strSuc
            rs.Update
            Call LogUz(strOC, iRok, iMes, "ZOSTAVA", strSuc, "Zostava vytvorená (návrh)")
        Else
            Call LogUz(strOC, iRok, iMes, "ZOSTAVA", strSuc, "Zostava uzavretého mesiaca zobrazená znova")
        End If
    End If
    rs.Close
    ZaznamenajZostavu = strSuc
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_18_Uzavierka.ZaznamenajZostavu", "ERROR", Err.Description, "OC=" & strOC)
End Function

'-------------------------------------------------------------------------------
' Text do pätičky zostavy (volá sa priamo z výrazu zostavy).
'-------------------------------------------------------------------------------
Public Function Uz_TextZostavy(ByVal vOC As Variant, ByVal vRok As Variant, ByVal vMes As Variant) As String
    Dim db As DAO.Database, rs As DAO.Recordset, strOC As String, iRok As Long, iMes As Long, strKl As String, s As String, strProb As String
    On Error GoTo Chyba
    strOC = CStr(Nz(vOC, ""))
    iRok = CLng(Val(CStr(Nz(vRok, 0))))
    iMes = CLng(Val(CStr(Nz(vMes, 0))))
    If Len(strOC) = 0 Or iRok = 0 Then Exit Function
    strKl = Kluc(strOC, iRok, iMes)
    If mTexty Is Nothing Then Set mTexty = CreateObject("Scripting.Dictionary")
    If mTexty.Exists(strKl) Then
        Uz_TextZostavy = CStr(mTexty.Item(strKl))
        Exit Function
    End If
    If Not mod_00_Common.TabulkaExistuje(TBL) Then
        s = "NAVRH - mesiac nie je uzavretý"
    Else
        Set db = CurrentDb
        Set rs = OtvorRiadok(db, strOC, iRok, iMes, False)
        If rs.EOF Then
            s = "NAVRH - mesiac nie je uzavretý"
        ElseIf CStr(Nz(rs!Stav, "")) = UZ_UZAVRETY Then
            strProb = OverIntegritu(strOC, iRok, iMes)
            If Len(strProb) = 0 Then
                s = "MESIAC JE UZAVRETÝ " & Format$(Nz(rs!UzavrelDna, Date), "dd.mm.yyyy") & " (potvrdil: " & CStr(Nz(rs!Potvrdil, "")) & ") | kontrolný kód " & CStr(Nz(rs!Sucet, ""))
            Else
                s = "POZOR: mesiac je uzavretý, ale údaje sa po uzavretí zmenili (kontrolný kód nesedí) - zostava nie je platná"
            End If
        Else
            s = "NÁVRH - mesiac nie je uzavretý | kontrolný kód " & CStr(Nz(rs!ZostavaSucet, ""))
        End If
        rs.Close
    End If
    mTexty.Add strKl, s
    Uz_TextZostavy = s
    Exit Function
Chyba:
    Uz_TextZostavy = ""
End Function

'-------------------------------------------------------------------------------
' Uzavrie mesiac zamestnanca. Podmienky: mesiac skončil, zostava bola vytvorená z aktuálnych údajov, je uvedené, kto ju potvrdil.
' Vráti text chyby alebo "".
'-------------------------------------------------------------------------------
Public Function Uzavri(ByVal strOC As String, ByVal iRok As Long, ByVal iMes As Long, ByVal strPotvrdil As String, ByVal strPozn As String) As String
    Dim db As DAO.Database, rs As DAO.Recordset, sRaz As String, sVyp As String, sPar As String, strSn As String, strSuc As String
    Dim strKrit As String
    On Error GoTo Chyba
    Set db = CurrentDb
    Call ZabezpecTabulky(db)
    Call ParCacheReset
    If Len(Trim$(strOC)) = 0 Then Uzavri = "Chýba osobné číslo.": Exit Function
    If Len(Trim$(strPotvrdil)) < 2 Then Uzavri = "Uveďte, kto zostavu potvrdil (podpísal).": Exit Function
    If Date < DateSerial(iRok, iMes + 1, 0) Then
        Uzavri = "Mesiac " & iMes & "/" & iRok & " ešte neskončil - uzavrieť ho možno od posledného dňa mesiaca."
        Exit Function
    End If
    If JeUzavrety(strOC, iRok, iMes) Then Uzavri = "Mesiac je už uzavretý.": Exit Function
    strKrit = "OsobneCislo = " & mod_00_Common.SqlText(strOC) & " AND Datum >= " & mod_00_Common.SqlDatum(DateSerial(iRok, iMes, 1)) & _
              " AND Datum < " & mod_00_Common.SqlDatum(DateSerial(iRok, iMes + 1, 1))
    If Nz(DCount("*", "DochadzkaDni", strKrit), 0) = 0 Then
        Uzavri = "Mesiac nemá vypočítané dni - najprv zobrazte tlačovú zostavu."
        Exit Function
    End If

    strSuc = SpocitajSucty(db, strOC, iRok, iMes, sRaz, sVyp, sPar, strSn)
    If strSuc = "CHYBA" Then Uzavri = "Kontrolné súčty sa nepodarilo vypočítať (pozrite protokol).": Exit Function

    Set rs = OtvorRiadok(db, strOC, iRok, iMes, False)
    If rs.EOF Then
        rs.Close
        Uzavri = "Pre tento mesiac sa ešte nevytvorila tlačová zostava - zobrazte ju, vytlačte a nechajte podpísať."
        Exit Function
    End If
    If IsNull(rs!ZostavaSucet) Then
        rs.Close
        Uzavri = "Pre tento mesiac sa ešte nevytvorila tlačová zostava - zobrazte ju, vytlačte a nechajte podpísať."
        Exit Function
    End If
    If CStr(rs!ZostavaSucet) <> strSuc Then
        rs.Close
        Uzavri = "Údaje mesiaca sa po vytvorení poslednej zostavy zmenili (kontrolný kód zostavy " & CStr(rs!ZostavaSucet) & ", aktuálny " & strSuc & _
                 "). Zobrazte zostavu znova, vytlačte ju a nechajte podpísať novú."
        Exit Function
    End If

    rs.Edit
    rs!Stav = UZ_UZAVRETY
    rs!UzavrelDna = Now
    rs!Uzavrel = mod_00_Common.Uzivatel()
    rs!Potvrdil = Left$(Trim$(strPotvrdil), 100)
    If Len(Trim$(strPozn)) > 0 Then rs!Poznamka = Left$(Trim$(strPozn), 255) Else rs!Poznamka = Null
    rs!Sucet = strSuc
    rs!SucetRazenia = sRaz
    rs!SucetVypocet = sVyp
    rs!SucetParametre = sPar
    rs!SnimkaParametrov = strSn
    rs.Update
    rs.Close
    Call ResetCache
    Call LogUz(strOC, iRok, iMes, "UZAVRETIE", strSuc, "Potvrdil: " & Left$(Trim$(strPotvrdil), 100))
    Exit Function
Chyba:
    Uzavri = "Mesiac sa nepodarilo uzavrieť: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_18_Uzavierka.Uzavri", "ERROR", Err.Description, "OC=" & strOC)
End Function

'-------------------------------------------------------------------------------
' Znova otvorí uzavretý mesiac (dôvod je povinný). Po otvorení treba zostavu vytlačiť a podpísať znova.
' Razenia z terminálu, ktoré medzitým prišli do uzavretého mesiaca, sa vrátia na spracovanie. Vráti text chyby alebo "".
'-------------------------------------------------------------------------------
Public Function Otvor(ByVal strOC As String, ByVal iRok As Long, ByVal iMes As Long, ByVal strDovod As String) As String
    Dim db As DAO.Database, rs As DAO.Recordset
    On Error GoTo Chyba
    Set db = CurrentDb
    Call ZabezpecTabulky(db)
    If Len(Trim$(strDovod)) < 5 Then Otvor = "Zadajte dôvod otvorenia mesiaca (aspoň 5 znakov).": Exit Function
    Set rs = OtvorRiadok(db, strOC, iRok, iMes, False)
    If rs.EOF Then
        rs.Close
        Otvor = "Mesiac nie je uzavretý.": Exit Function
    End If
    If CStr(Nz(rs!Stav, "")) <> UZ_UZAVRETY Then
        rs.Close
        Otvor = "Mesiac nie je uzavretý.": Exit Function
    End If
    rs.Edit
    rs!Stav = UZ_OTVORENY
    rs!OtvorenyDna = Now
    rs!Otvoril = mod_00_Common.Uzivatel()
    rs!DovodOtvorenia = Left$(Trim$(strDovod), 255)
    rs!PocetOtvoreni = CLng(Nz(rs!PocetOtvoreni, 0)) + 1
    rs!ZostavaSucet = Null
    rs!ZostavaDna = Null
    rs.Update
    rs.Close
    Call ResetCache
    On Error Resume Next
    If mod_00_Common.TabulkaExistuje("TerminalInbox") Then
        db.Execute "UPDATE TerminalInbox SET Stav = 'NOVE', Chyba = Null WHERE Stav = 'UZAVRETY' AND OsobneCislo = " & mod_00_Common.SqlText(strOC) & _
                   " AND CasRazenia >= " & mod_00_Common.SqlDatum(DateSerial(iRok, iMes, 1)) & " AND CasRazenia < " & mod_00_Common.SqlDatum(DateSerial(iRok, iMes + 1, 1)), dbFailOnError
        Err.Clear
    End If
    On Error GoTo Chyba
    Call LogUz(strOC, iRok, iMes, "OTVORENIE", "", Left$(Trim$(strDovod), 200))
    Exit Function
Chyba:
    Otvor = "Mesiac sa nepodarilo otvoriť: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_18_Uzavierka.Otvor", "ERROR", Err.Description, "OC=" & strOC)
End Function

'===============================================================================
' KONTROLA INTEGRITY
'===============================================================================

Private Function PrvyRozdiel(ByVal strStary As String, ByVal strNovy As String) As String
    Dim a() As String, b() As String, i As Long, n As Long, sA As String, sB As String
    strStary = Replace(strStary, vbCr, "")
    strNovy = Replace(strNovy, vbCr, "")
    a = Split(strStary, vbLf)
    b = Split(strNovy, vbLf)
    n = UBound(a)
    If UBound(b) > n Then n = UBound(b)
    For i = 0 To n
        sA = "": sB = ""
        If i <= UBound(a) Then sA = a(i)
        If i <= UBound(b) Then sB = b(i)
        If sA <> sB Then
            PrvyRozdiel = "pri uzavretí: " & Left$(sA, 120) & " | teraz: " & Left$(sB, 120)
            Exit Function
        End If
    Next i
End Function

'-------------------------------------------------------------------------------
' Skontroluje, či sa údaje uzavretého mesiaca nezmenili od uzavretia. Vráti "" (v poriadku) alebo opis rozdielu.
'-------------------------------------------------------------------------------
Public Function OverIntegritu(ByVal strOC As String, ByVal iRok As Long, ByVal iMes As Long) As String
    Dim db As DAO.Database, rs As DAO.Recordset, sRaz As String, sVyp As String, sPar As String, strSn As String, strSuc As String
    Dim s As String, strStary As String
    On Error GoTo Chyba
    Set db = CurrentDb
    If Not mod_00_Common.TabulkaExistuje(TBL) Then OverIntegritu = "Mesiac nie je uzavretý.": Exit Function
    Set rs = OtvorRiadok(db, strOC, iRok, iMes, False)
    If rs.EOF Then
        rs.Close
        OverIntegritu = "Mesiac nie je uzavretý."
        Exit Function
    End If
    If CStr(Nz(rs!Stav, "")) <> UZ_UZAVRETY Then
        rs.Close
        OverIntegritu = "Mesiac nie je uzavretý."
        Exit Function
    End If
    strSuc = SpocitajSucty(db, strOC, iRok, iMes, sRaz, sVyp, sPar, strSn)
    If strSuc = "CHYBA" Then
        rs.Close
        OverIntegritu = "kontrolu sa nepodarilo vykonať (pozrite protokol)"
        Exit Function
    End If
    If strSuc = CStr(Nz(rs!Sucet, "")) Then
        rs.Close
        Exit Function
    End If
    If sRaz <> CStr(Nz(rs!SucetRazenia, "")) Then s = s & "razenia (pípnutia) sa zmenili; "
    If sVyp <> CStr(Nz(rs!SucetVypocet, "")) Then s = s & "výpočet (dni, intervaly, súhrn) sa zmenil alebo chýba; "
    If sPar <> CStr(Nz(rs!SucetParametre, "")) Then
        strStary = CStr(Nz(rs!SnimkaParametrov, ""))
        s = s & "parametre sa zmenili (" & PrvyRozdiel(strStary, strSn) & "); "
    End If
    rs.Close
    If Len(s) = 0 Then s = "kontrolný kód sa nezhoduje; "
    OverIntegritu = Left$(s, Len(s) - 2)
    Exit Function
Chyba:
    OverIntegritu = "kontrolu sa nepodarilo vykonať: " & Err.Description
End Function

'-------------------------------------------------------------------------------
' Skontroluje všetky uzavreté mesiace (iRok = 0: všetky, inak mesiac iRok/iMes). nZle = počet zmenených.
' Vráti text správy (zoznam nájdených rozdielov).
'-------------------------------------------------------------------------------
Public Function OverVsetky(ByVal iRok As Long, ByVal iMes As Long, ByRef nZle As Long, ByRef nSpolu As Long) As String
    Dim db As DAO.Database, rs As DAO.Recordset, strKrit As String, strProb As String, s As String
    On Error GoTo Chyba
    nZle = 0: nSpolu = 0
    If Not mod_00_Common.TabulkaExistuje(TBL) Then Exit Function
    Set db = CurrentDb
    Call ParCacheReset
    strKrit = "Stav = '" & UZ_UZAVRETY & "'"
    If iRok > 0 Then strKrit = strKrit & " AND Rok = " & iRok & " AND Mesiac = " & iMes
    Set rs = db.OpenRecordset("SELECT OsobneCislo, Rok, Mesiac FROM " & TBL & " WHERE " & strKrit & " ORDER BY Rok, Mesiac, OsobneCislo;", dbOpenSnapshot)
    Do While Not rs.EOF
        nSpolu = nSpolu + 1
        strProb = OverIntegritu(CStr(rs!OsobneCislo), CLng(rs!Rok), CLng(rs!Mesiac))
        If Len(strProb) > 0 Then
            nZle = nZle + 1
            If nZle <= 20 Then s = s & MenoOC(CStr(rs!OsobneCislo)) & " " & rs!Mesiac & "/" & rs!Rok & ": " & strProb & vbCrLf
        End If
        rs.MoveNext
    Loop
    rs.Close
    If nZle > 20 Then s = s & "... a ďalších " & (nZle - 20) & vbCrLf
    OverVsetky = s
    Call mod_00_Common.ZapisLog("Uzavierka", IIf(nZle > 0, "WARN", "INFO"), "Kontrola uzavretých mesiacov: " & nSpolu & ", zmenených: " & nZle, s)
    Exit Function
Chyba:
    OverVsetky = "Chyba kontroly: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_18_Uzavierka.OverVsetky", "ERROR", Err.Description)
End Function

'===============================================================================
' KTORÝ UZAVRETÝ MESIAC BY ZMENA ZASIAHLA
'===============================================================================

'-------------------------------------------------------------------------------
' Najstarší mesiac (rok*12+mesiac), za ktorý má zamestnanec údaje (razenia alebo uzavretie); 0, ak žiadny.
'-------------------------------------------------------------------------------
Public Function NajstarsiMesiacZamestnanca(ByVal strOC As String) As Long
    Dim v As Variant, ym As Long, v2 As Variant
    On Error Resume Next
    v = DMin("Datum", "DochadzkaImport", "OsobneCislo = " & mod_00_Common.SqlText(strOC))
    If Not IsNull(v) Then
        If IsDate(v) Then ym = CLng(Year(CDate(v))) * 12 + Month(CDate(v))
    End If
    If mod_00_Common.TabulkaExistuje(TBL) Then
        v2 = DMin("Rok * 12 + Mesiac", TBL, "OsobneCislo = " & mod_00_Common.SqlText(strOC) & " AND Stav = '" & UZ_UZAVRETY & "'")
        If Not IsNull(v2) Then
            If ym = 0 Or CLng(v2) < ym Then ym = CLng(v2)
        End If
    End If
    NajstarsiMesiacZamestnanca = ym
End Function

'-------------------------------------------------------------------------------
' Najstarší uzavretý mesiac (rok*12+mesiac) zamestnancov, ktorí používajú fond ("F") alebo šablónu ("S") s daným číslom; 0, ak žiadny.
'-------------------------------------------------------------------------------
Public Function NajstarsiUzavretyMesiac(ByVal strTyp As String, ByVal lCislo As Long) As Long
    Dim rs As DAO.Recordset, c As Long, iOdR As Integer, iOdM As Integer, f As Long, p As Long, k As Long, y As Long, bTyka As Boolean
    On Error GoTo Chyba
    If Not ExistujeUzavrety() Then Exit Function
    Set rs = CurrentDb.OpenRecordset("SELECT OsobneCislo, Rok, Mesiac FROM " & TBL & " WHERE Stav = '" & UZ_UZAVRETY & "' ORDER BY Rok, Mesiac;", dbOpenSnapshot)
    Do While Not rs.EOF
        Call mod_15_Zamestnanci.PlatnePriradenie(CStr(rs!OsobneCislo), CInt(rs!Rok), CInt(rs!Mesiac), iOdR, iOdM, f, p, k, y)
        If strTyp = "F" Then bTyka = (f = lCislo) Else bTyka = (p = lCislo)
        If bTyka Then
            c = CLng(rs!Rok) * 12 + CLng(rs!Mesiac)
            Exit Do
        End If
        rs.MoveNext
    Loop
    rs.Close
    NajstarsiUzavretyMesiac = c
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_18_Uzavierka.NajstarsiUzavretyMesiac", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Spoločné jadro: koľko uzavretých mesiacov by zmena zasiahla a ktorý je prvý ("" = žiadny).
' strTyp: "F" fond, "S" šablóna, "Z" jeden zamestnanec. ym = od mesiaca (rok*12+mesiac); bPred = zmena sa uplatní aj
' na mesiace pred zvoleným (zvolený mesiac je pred najstaršou verziou, preto platí spätne).
'-------------------------------------------------------------------------------
Private Function Dotknute(ByVal strTyp As String, ByVal lCislo As Long, ByVal strOC As String, ByVal ym As Long, ByVal bPred As Boolean) As String
    Dim rs As DAO.Recordset, n As Long, strPrvy As String, c As Long, bTyka As Boolean, strKrit As String
    Dim iOdR As Integer, iOdM As Integer, f As Long, p As Long, k As Long, y As Long
    On Error GoTo Chyba
    If Not ExistujeUzavrety() Then Exit Function
    strKrit = "Stav = '" & UZ_UZAVRETY & "'"
    If strTyp = "Z" Then strKrit = strKrit & " AND OsobneCislo = " & mod_00_Common.SqlText(strOC)
    Set rs = CurrentDb.OpenRecordset("SELECT OsobneCislo, Rok, Mesiac FROM " & TBL & " WHERE " & strKrit & " ORDER BY Rok, Mesiac, OsobneCislo;", dbOpenSnapshot)
    Do While Not rs.EOF
        c = CLng(rs!Rok) * 12 + CLng(rs!Mesiac)
        If c >= ym Or bPred Then
            bTyka = True
            If strTyp <> "Z" Then
                Call mod_15_Zamestnanci.PlatnePriradenie(CStr(rs!OsobneCislo), CInt(rs!Rok), CInt(rs!Mesiac), iOdR, iOdM, f, p, k, y)
                If strTyp = "F" Then bTyka = (f = lCislo) Else bTyka = (p = lCislo)
            End If
            If bTyka Then
                n = n + 1
                If n = 1 Then strPrvy = MenoOC(CStr(rs!OsobneCislo)) & ", mesiac " & rs!Mesiac & "/" & rs!Rok
            End If
        End If
        rs.MoveNext
    Loop
    rs.Close
    If n = 0 Then Exit Function
    If n > 1 Then
        Dotknute = strPrvy & " (a ďalších " & (n - 1) & ")"
    Else
        Dotknute = strPrvy
    End If
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_18_Uzavierka.Dotknute", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Uloženie fondu od mesiaca iRok/iMes: ktorý uzavretý mesiac by sa zmenil ("" = žiadny).
'-------------------------------------------------------------------------------
Public Function DotknutyFond(ByVal lFond As Long, ByVal iRok As Long, ByVal iMes As Long) As String
    Dim v As Variant, ym As Long, bPred As Boolean
    On Error Resume Next
    If Not ExistujeUzavrety() Then Exit Function
    ym = iRok * 12 + iMes
    v = DMin("Rok * 12 + Mesiac", "PracovneFondy", "Cislo = " & lFond)
    If IsNull(v) Then bPred = True Else bPred = (ym <= CLng(v))
    DotknutyFond = Dotknute("F", lFond, "", ym, bPred)
End Function

'-------------------------------------------------------------------------------
' Uloženie pravidla prerušenia šablóny od mesiaca: ktorý uzavretý mesiac by sa zmenil. bMozeZaklad = ak pravidlo ešte nemá
' žiadnu verziu, dá sa pre staršie mesiace vytvoriť vypnutá základná verzia (staré mesiace sa potom nezmenia).
'-------------------------------------------------------------------------------
Public Function DotknutaSablona(ByVal lSab As Long, ByVal lCis As Long, ByVal iRok As Long, ByVal iMes As Long, Optional ByVal bMozeZaklad As Boolean = False) As String
    Dim v As Variant, ym As Long, bPred As Boolean
    On Error Resume Next
    If Not ExistujeUzavrety() Then Exit Function
    ym = iRok * 12 + iMes
    v = DMin("Rok * 12 + Mesiac", "ParametrePreruseni", "Sablona = " & lSab & " AND CisloPreruseni = " & lCis)
    If IsNull(v) Then
        bPred = Not bMozeZaklad
    Else
        bPred = (ym <= CLng(v))
    End If
    DotknutaSablona = Dotknute("S", lSab, "", ym, bPred)
End Function

'-------------------------------------------------------------------------------
' Uloženie priradenia (fond, šablóna, kalendár, úväzok) zamestnanca od mesiaca: ktorý uzavretý mesiac by sa zmenil.
' bMozeZaklad = zamestnanec ešte nemá priradenie a pre staršie mesiace sa vytvorí základné (staré mesiace sa nezmenia).
'-------------------------------------------------------------------------------
Public Function DotknutyZamestnanec(ByVal strOC As String, ByVal iRok As Long, ByVal iMes As Long, Optional ByVal bMozeZaklad As Boolean = False) As String
    Dim v As Variant, ym As Long, bPred As Boolean
    On Error Resume Next
    If Not ExistujeUzavrety() Then Exit Function
    ym = iRok * 12 + iMes
    v = DMin("Rok * 12 + Mesiac", "ZamestnanciFondy", "OsobneCislo = " & mod_00_Common.SqlText(strOC))
    If IsNull(v) Then
        bPred = Not bMozeZaklad
    Else
        bPred = (ym <= CLng(v))
    End If
    DotknutyZamestnanec = Dotknute("Z", 0, strOC, ym, bPred)
End Function

'-------------------------------------------------------------------------------
' Vyradenie / vrátenie zamestnanca s dátumom dZmeny: zasiahne uzavretý mesiac, ktorý končí v deň dZmeny alebo neskôr.
'-------------------------------------------------------------------------------
Public Function DotknutyVyradenim(ByVal strOC As String, ByVal dZmeny As Date) As String
    Dim rs As DAO.Recordset, n As Long, strPrvy As String, dKoniec As Date
    On Error GoTo Chyba
    If Not ExistujeUzavrety() Then Exit Function
    Set rs = CurrentDb.OpenRecordset("SELECT Rok, Mesiac FROM " & TBL & " WHERE Stav = '" & UZ_UZAVRETY & "' AND OsobneCislo = " & _
                                     mod_00_Common.SqlText(strOC) & " ORDER BY Rok, Mesiac;", dbOpenSnapshot)
    Do While Not rs.EOF
        dKoniec = DateSerial(CInt(rs!Rok), CInt(rs!Mesiac) + 1, 0)
        If dKoniec >= dZmeny Then
            n = n + 1
            If n = 1 Then strPrvy = MenoOC(strOC) & ", mesiac " & rs!Mesiac & "/" & rs!Rok
        End If
        rs.MoveNext
    Loop
    rs.Close
    If n = 0 Then Exit Function
    If n > 1 Then
        DotknutyVyradenim = strPrvy & " (a ďalších " & (n - 1) & ")"
    Else
        DotknutyVyradenim = strPrvy
    End If
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_18_Uzavierka.DotknutyVyradenim", "ERROR", Err.Description)
End Function

'===============================================================================
' OCHRANA PRED PREPISOM NASTAVENÍ IMPORTOM Z DBF (Ordata)
'===============================================================================

'-------------------------------------------------------------------------------
' Import z DBF nahrádza pracovné fondy, pravidlá prerušení, priradenia a kalendáre celým obsahom súborov DBF.
' Ak existuje uzavretý mesiac, import nastavení sa nevykoná. Ak boli nastavenia upravované v tejto aplikácii,
' opýta sa na potvrdenie (raz za dávku). Vráti True, ak sa import nastavení smie vykonať.
'-------------------------------------------------------------------------------
Public Function PrepisNastaveniPovoleny(ByVal strNazov As String) As Boolean
    Dim strLok As String
    On Error Resume Next
    If ExistujeUzavrety() Then
        mBlokImport = mBlokImport & strNazov & vbCrLf
        Call mod_00_Common.ZapisLog("Import DBF", "WARN", "Import nastavení preskočený (existujú uzavreté mesiace): " & strNazov)
        If Not mTichoPrepis Then
            MsgBox "Import nastavení (" & strNazov & ") sa nevykonal - existujú uzavreté (podpísané) mesiace a import by prepísal ich pracovné fondy, " & _
                   "pravidlá a priradenia." & vbCrLf & vbCrLf & "Ak je import nevyhnutný, najprv otvorte uzavreté mesiace (záložka 6 Výpočet - Uzávierka mesiaca).", _
                   vbExclamation, "Uzavreté mesiace"
        End If
        Exit Function
    End If
    If mPrepis = 1 Then PrepisNastaveniPovoleny = True: Exit Function
    If mPrepis = 2 Then
        mBlokImport = mBlokImport & strNazov & vbCrLf
        Exit Function
    End If
    strLok = mod_00_Common.GetNastavenie(KLUC_LOKALNE, "")
    If Len(strLok) = 0 Then
        PrepisNastaveniPovoleny = True
        Exit Function
    End If
    If MsgBox("Pracovné fondy, pravidlá prerušení alebo priradenia boli upravované v tejto aplikácii (naposledy " & strLok & ")." & vbCrLf & vbCrLf & _
              "Import z DBF ich nahradí údajmi z Ordaty a ručné úpravy sa stratia. Pokračovať?", vbExclamation + vbYesNo + vbDefaultButton2, "Import nastavení z DBF") = vbYes Then
        mPrepis = 1
        PrepisNastaveniPovoleny = True
    Else
        mPrepis = 2
        mBlokImport = mBlokImport & strNazov & vbCrLf
    End If
End Function

'-------------------------------------------------------------------------------
' Začiatok a koniec dávky importov (raz sa pýta a raz hlási). Koniec vráti text o preskočených importoch alebo "".
'-------------------------------------------------------------------------------
Public Sub ZacniDavkuImportu()
    mPrepis = 0
    mTichoPrepis = True
    mBlokImport = ""
End Sub

Public Function SkonciDavkuImportu() As String
    mTichoPrepis = False
    SkonciDavkuImportu = mBlokImport
    mBlokImport = ""
End Function

Public Sub OznacNastaveniaLokalne()
    On Error Resume Next
    Call mod_00_Common.SetNastavenie(KLUC_LOKALNE, Format$(Now, "dd.mm.yyyy hh:nn"), "Fondy, pravidlá alebo priradenia upravené v aplikácii (ochrana pred prepísaním importom z DBF)")
End Sub

Public Sub VymazOznacenieNastaveni()
    On Error Resume Next
    CurrentDb.Execute "DELETE FROM NastaveniaSystemu WHERE Kluc = '" & KLUC_LOKALNE & "';", dbFailOnError
    mPrepis = 0
End Sub

'===============================================================================
' PODKLAD PRE OKNO UZÁVIERKY
'===============================================================================

'-------------------------------------------------------------------------------
' Texty stĺpcov zoznamu (volajú sa priamo z dotazu zoznamu, preto sú verejné a bez názvu modulu).
' vTyp: 1 = stav (UZAVRETÝ / otvorený), 2 = kedy bola vytvorená zostava, 3 = kto a kedy uzavrel.
'-------------------------------------------------------------------------------
Public Function Uz_PoleZoznamu(ByVal vOC As Variant, ByVal vRok As Variant, ByVal vMes As Variant, ByVal vTyp As Variant) As String
    Dim strOC As String, iRok As Long, iMes As Long, iTyp As Long, ym As Long, rs As DAO.Recordset, k As String, st As String
    Dim strZ As String, strU As String, strS As String, v As Variant
    On Error GoTo Chyba
    strOC = CStr(Nz(vOC, ""))
    iRok = CLng(Val(CStr(Nz(vRok, 0))))
    iMes = CLng(Val(CStr(Nz(vMes, 0))))
    iTyp = CLng(Val(CStr(Nz(vTyp, 0))))
    ym = iRok * 12 + iMes
    If mZozn Is Nothing Or ym <> mZoznYm Or Abs(Timer - mZoznCas) > 5 Then
        Set mZozn = CreateObject("Scripting.Dictionary")
        mZoznYm = ym
        mZoznCas = Timer
        If mod_00_Common.TabulkaExistuje(TBL) Then
            Set rs = CurrentDb.OpenRecordset("SELECT OsobneCislo, Stav, ZostavaDna, UzavrelDna, Potvrdil FROM " & TBL & _
                                             " WHERE Rok = " & iRok & " AND Mesiac = " & iMes & ";", dbOpenSnapshot)
            Do While Not rs.EOF
                st = CStr(Nz(rs!Stav, ""))
                k = CStr(Nz(rs!OsobneCislo, ""))
                If Not mZozn.Exists(k) Then
                    strZ = "-"
                    If Not IsNull(rs!ZostavaDna) Then strZ = Format$(rs!ZostavaDna, "dd.mm. hh:nn")
                    strU = ""
                    strS = "otvorený"
                    If st = UZ_UZAVRETY Then
                        strS = "UZAVRETÝ"
                        If Not IsNull(rs!UzavrelDna) Then strU = Format$(rs!UzavrelDna, "dd.mm.yyyy")
                        strU = Trim$(strU & " " & Replace(CStr(Nz(rs!Potvrdil, "")), "|", "/"))
                    End If
                    mZozn.Add k, strS & "|" & strZ & "|" & strU
                End If
                rs.MoveNext
            Loop
            rs.Close
        End If
    End If
    If mZozn.Exists(strOC) Then
        v = Split(CStr(mZozn(strOC)), "|")
        Uz_PoleZoznamu = CStr(v(iTyp - 1))
    Else
        Select Case iTyp
            Case 1: Uz_PoleZoznamu = "otvorený"
            Case 2: Uz_PoleZoznamu = "-"
            Case Else: Uz_PoleZoznamu = ""
        End Select
    End If
    Exit Function
Chyba:
    Uz_PoleZoznamu = ""
End Function

'-------------------------------------------------------------------------------
' SQL zoznamu zamestnancov mesiaca so stavom uzávierky (okno Uzávierka mesiaca): zamestnanci s razeniami v mesiaci
' alebo s uzavretým mesiacom. Stĺpce: OsobneCislo, Meno, Stav, Zostava, Uzavrel.
'-------------------------------------------------------------------------------
Public Function SqlZoznamUzavierky(ByVal iRok As Long, ByVal iMes As Long) As String
    Dim dOd As String, dDo As String, strMeno As String, strArg As String
    dOd = mod_00_Common.SqlDatum(DateSerial(iRok, iMes, 1))
    dDo = mod_00_Common.SqlDatum(DateSerial(iRok, iMes + 1, 1))
    strMeno = "Trim(Nz(Z.Priezvisko,'') & ' ' & Nz(Z.Meno,''))"
    strArg = "Z.OsobneCislo, " & iRok & ", " & iMes
    SqlZoznamUzavierky = "SELECT Z.OsobneCislo, IIf(Len(" & strMeno & ") > 0, " & strMeno & ", Nz(Z.CeleMeno, 'Zamestnanec ' & Z.OsobneCislo)) AS Meno, " & _
        "Uz_PoleZoznamu(" & strArg & ", 1) AS Stav, Uz_PoleZoznamu(" & strArg & ", 2) AS Zostava, Uz_PoleZoznamu(" & strArg & ", 3) AS Uzavrel " & _
        "FROM Zamestnanci AS Z " & _
        "WHERE Z.OsobneCislo IS NOT NULL AND (" & _
        "Z.OsobneCislo IN (SELECT OsobneCislo FROM " & TBL & " WHERE Rok = " & iRok & " AND Mesiac = " & iMes & " AND Stav = '" & UZ_UZAVRETY & "') OR " & _
        "(Z.OsobneCislo IN (SELECT OsobneCislo FROM DochadzkaImport WHERE Datum >= " & dOd & " AND Datum < " & dDo & ") AND " & _
        mod_15_Zamestnanci.SqlAktivny("Z", DateSerial(iRok, iMes, 1)) & ")) " & _
        "ORDER BY Z.OsobneCislo;"
End Function
