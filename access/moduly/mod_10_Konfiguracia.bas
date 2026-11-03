Attribute VB_Name = "mod_10_Konfiguracia"
'@Verzia 1.0.1
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_10_Konfiguracia
' POPIS: Minimálna predvolená konfigurácia systému pre inštalácie BEZ importu z Ordata:
'        číselník prerušení + kódy razení (terminál), pravidlá anomálií, parametre výpočtu,
'        štátne sviatky SR (vrátane pohyblivých veľkonočných) a základné nastavenia.
'        Inicializácia je BEZPEČNÁ (idempotentná): dopĺňa len chýbajúce záznamy, nič neprepisuje.
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - InicializujPredvolenuKonfiguraciu(bTicho)  : Dopln všetko, čo chýba; vráti počet pridaných záznamov.
' - ZabezpecStlpceKonfiguracie(db)             : Doplní nové stĺpce (AutoKoniecDoKoncaSmeny, Sviatky.Rok).
' - PridajSviatkyRokov(db, rokOd, rokDo)       : Pohyblivé sviatky (Veľká noc) na zvolené roky.
' - VelkaNoc(rok)                              : Dátum Veľkonočnej nedele.
' - NastavParameterPravidla(kod, kluc, hodn)   : Zmení jeden kľúč v texte Parametre pravidla.
' - UlozParametreVypoctu(...)                  : Uloží okno práce, obed a limit celodennej prekážky.
' - StavKonfiguracie()                        : Textový prehľad stavu konfigurácie.
' - ZoznamPreruseniSQL()                       : SQL pre zoznam prerušení v UI.
' - UlozPrerusenie / ZmazPrerusenie            : Úprava jedného prerušenia a jeho kódov razení.
'===============================================================================

' Predvolené prerušenia: Cislo|Nazov|Skratka|Predvolba|KodZ|TextZ|KodK|TextK|AutoKoniec(1/0)
Private Function PredvolenePreruseniaDef() As Variant
    PredvolenePreruseniaDef = Array( _
        "1|Pracovná doba|Prac.dob||100|Príchod|101|Odchod|0", _
        "2|Návšteva lekára|LEK|lekár|102|Lekár - odchod|103|Lekár - príchod|0", _
        "3|Nadčas|Nadčas|Nadčas|104|Nadčas-odch|105|Nadčas-prích|0", _
        "4|Služobné vzdialenie|SLVZ|Sl.vzdialenie|106|Sl.vzdial-odchod|107|Sl.vzdia-príchod|1", _
        "5|Krátkodobá dovolenka|KDOV|Krátkodobá DOV|114|Krát.DOV-odchod|115|Krát.DOV-príchod|0", _
        "7|Obed|OBED|Obed|110|Obed-odchod|111|Obed-príchod|0", _
        "8|Dovolenka|DOVOL|Dovolenka|116|Dovolenka-odch.|117|Dovolenka-prích.|1", _
        "10|Pošta - Banka|POBA|Pošta-Banka|118|Pošta,ban-odchod|119|Pošta,ban-prích.|0", _
        "11|Nemoc|NEMOC|Nemoc|120|Nemoc-odchod|121|Nemoc-príchod|1", _
        "12|Služobná cesta|SLCE|Služobná cesta|122|Služ.cest-odchod|123|Služ.cest-prích.|1", _
        "13|Ostatné osobné prekážky|OOP|Ost.os.prekážky|124|Ost.os.prek.-od.|125|Ost.os.prek.-pr.|1", _
        "14|Náhradné voľno|NV|Náhradné voľno|126|NV-začiatok|127|NV-koniec|1", _
        "15|Ošetrenie pracovníka|P|Ošetrenie prac.|128|Ošetr.pr.-odchod|129|Ošetr.pr.-prícho|1", _
        "16|Ošetrenie člena rodiny|OČR|Ošetrenie ČR|130|Ošetr. ČR-odchod|131|Ošetr.ČR-príchod|1", _
        "17|Prekážky §142 ods. 3|§142ods3|Prekážky|132|Prekážky-zač.|133|Prekážky-kon.|1")
End Function

' Pevné štátne sviatky SR: Den|Mesiac|Nazov
Private Function PevneSviatkyDef() As Variant
    PevneSviatkyDef = Array( _
        "1|1|Deň vzniku Slovenskej republiky", "6|1|Zjavenie Pána (Traja králi)", "1|5|Sviatok práce", _
        "8|5|Deň víťazstva nad fašizmom", "5|7|Sviatok sv. Cyrila a Metoda", "29|8|Výročie SNP", _
        "1|9|Deň Ústavy Slovenskej republiky", "15|9|Sedembolestná Panna Mária", "1|11|Sviatok všetkých svätých", _
        "17|11|Deň boja za slobodu a demokraciu", "24|12|Štedrý deň", "25|12|Prvý sviatok vianočný", "26|12|Druhý sviatok vianočný")
End Function

'-------------------------------------------------------------------------------
' Dátum Veľkonočnej nedele (Anonymný gregoriánsky algoritmus).
'-------------------------------------------------------------------------------
Public Function VelkaNoc(ByVal iRok As Integer) As Date
    Dim a As Long, b As Long, c As Long, d As Long, e As Long, f As Long, g As Long
    Dim h As Long, i As Long, k As Long, l As Long, m As Long, mes As Long, den As Long
    a = iRok Mod 19
    b = iRok \ 100
    c = iRok Mod 100
    d = b \ 4
    e = b Mod 4
    f = (b + 8) \ 25
    g = (b - f + 1) \ 3
    h = (19 * a + b - d - g + 15) Mod 30
    i = c \ 4
    k = c Mod 4
    l = (32 + 2 * e + 2 * i - h - k) Mod 7
    m = (a + 11 * h + 22 * l) \ 451
    mes = (h + l - 7 * m + 114) \ 31
    den = ((h + l - 7 * m + 114) Mod 31) + 1
    VelkaNoc = DateSerial(iRok, mes, den)
End Function

Private Sub PridajStlpec(ByRef db As DAO.Database, ByVal strTab As String, ByVal strPole As String, ByVal strTyp As String)
    On Error Resume Next
    If Not mod_00_Common.TabulkaExistujeDB(db, strTab) Then Exit Sub
    If Not mod_00_Common.PoleExistujeDB(db, strTab, strPole) Then db.Execute "ALTER TABLE " & strTab & " ADD COLUMN " & strPole & " " & strTyp, dbFailOnError
End Sub

'-------------------------------------------------------------------------------
' Doplní nové stĺpce do existujúcich tabuliek (staršie databázy).
'-------------------------------------------------------------------------------
Public Sub ZabezpecStlpceKonfiguracie(ByRef db As DAO.Database)
    Call PridajStlpec(db, "CiselnikPreruseni", "AutoKoniecDoKoncaSmeny", "YESNO")
    Call PridajStlpec(db, "CiselnikPreruseni", "ZapocitavatDoPrace", "YESNO")
    Call PridajStlpec(db, "Sviatky", "Rok", "LONG")
End Sub

Private Function NajdiPrvok(ByVal strZoznam As String, ByVal lPoz As Long) As String
    Dim a() As String
    a = Split(strZoznam, "|")
    If lPoz <= UBound(a) Then NajdiPrvok = a(lPoz)
End Function

'-------------------------------------------------------------------------------
' Dopln chýbajúce prerušenia, kódy razení a typy udalostí.
'-------------------------------------------------------------------------------
Private Function DoplnPreruseniaAKody(ByRef db As DAO.Database) As Long
    Dim v As Variant, a() As String, rs As DAO.Recordset, n As Long, lCislo As Long, bNove As Boolean
    For Each v In PredvolenePreruseniaDef()
        a = Split(CStr(v), "|")
        lCislo = CLng(a(0))

        Set rs = db.OpenRecordset("SELECT * FROM CiselnikPreruseni WHERE Cislo = " & lCislo & ";", dbOpenDynaset)
        If rs.EOF Then
            rs.AddNew
            rs!Cislo = lCislo
            rs!Nazov = a(1)
            rs!NazovSkratka = a(2)
            If Len(a(3)) > 0 Then rs!TextPredvolba = a(3)
            rs!KodZaciatok = CLng(a(4))
            rs!TextZaciatok = a(5)
            rs!FunkciaZaciatok = IIf(lCislo = 1, 2, 1)
            rs!KodKoniec = CLng(a(6))
            rs!TextKoniec = a(7)
            rs!FunkciaKoniec = IIf(lCislo = 1, 3, 1)
            rs!TypVypoctu = "STANDARD"
            rs!ZapocitavatDoFondu = False
            rs!AutoDopocet = False
            rs!AutoKoniecDoKoncaSmeny = (a(8) = "1")
            rs.Update
            n = n + 1
        End If
        rs.Close

        n = n + DoplnKodRazenia(db, CLng(a(4)), lCislo, "Z", a(5), a(1))
        n = n + DoplnKodRazenia(db, CLng(a(6)), lCislo, "K", a(7), a(1))
    Next v
    DoplnPreruseniaAKody = n
End Function

Private Function DoplnKodRazenia(ByRef db As DAO.Database, ByVal lKod As Long, ByVal lCislo As Long, ByVal strSmer As String, _
                                 ByVal strText As String, ByVal strNazov As String) As Long
    Dim rs As DAO.Recordset
    Set rs = db.OpenRecordset("SELECT * FROM KodyRazeni WHERE KodRazenia = " & lKod & ";", dbOpenDynaset)
    If rs.EOF Then
        rs.AddNew
        rs!KodRazenia = lKod
        rs!CisloPreruseni = lCislo
        rs!Smer = strSmer
        rs!TextRazenia = Left$(strText, 50)
        rs.Update
        DoplnKodRazenia = 1
    End If
    rs.Close
    If mod_00_Common.TabulkaExistujeDB(db, "TypyUdalosti") Then
        Set rs = db.OpenRecordset("SELECT * FROM TypyUdalosti WHERE Kod = " & lKod & ";", dbOpenDynaset)
        If rs.EOF Then
            rs.AddNew
            rs!Kod = lKod
            rs!Nazov = Left$(strText, 100)
            rs!Typ = strSmer
            rs!Kategoria = Left$(strNazov, 50)
            rs!ZapocitatDoPrace = (lCislo = 1)
            rs.Update
        End If
        rs.Close
    End If
End Function

'-------------------------------------------------------------------------------
' Predvolené nastavenia systému (iba chýbajúce kľúče).
'-------------------------------------------------------------------------------
Private Function DoplnNastavenia() As Long
    Dim v As Variant, a() As String, n As Long
    For Each v In Array( _
        "OknoPraceOd|06:00|Začiatok okna, v ktorom sa počíta odpracovaný čas (HH:MM)", _
        "OknoPraceDo|17:00|Koniec okna, v ktorom sa počíta odpracovaný čas (HH:MM)", _
        "CelodennaPrekazkaMin|360|Prekážka dlhšia ako tento počet minút sa počíta ako celý denný fond", _
        "AutoOpravaRezim|1|Automatické opravy: 0=vypnuté, 1=isté automaticky + odhady na schválenie, 2=všetko automaticky", _
        "PredvolenyFondMin|450|Denný fond (min) pre zamestnancov bez priradeného fondu (7,5 h)", _
        "OsobneCisloDlzka|0|Povinná dĺžka osobného čísla pri importe z CSV/AD (0 = ľubovoľná)")
        a = Split(CStr(v), "|")
        If Len(mod_00_Common.GetNastavenie(a(0), "")) = 0 Then
            Call mod_00_Common.SetNastavenie(a(0), a(1), a(2))
            n = n + 1
        End If
    Next v
    DoplnNastavenia = n
End Function

'-------------------------------------------------------------------------------
' Pridá pohyblivé (Veľký piatok, Veľkonočný pondelok) a chýbajúce pevné sviatky.
'-------------------------------------------------------------------------------
Public Function PridajSviatkyRokov(ByRef db As DAO.Database, ByVal iRokOd As Integer, ByVal iRokDo As Integer) As Long
    Dim v As Variant, a() As String, n As Long, r As Integer, dN As Date
    If Not mod_00_Common.TabulkaExistujeDB(db, "Sviatky") Then Exit Function
    Call PridajStlpec(db, "Sviatky", "Rok", "LONG")

    ' existujúce riadky Veľkej noci bez roka: priraď rok podľa dátumu, ktorý zodpovedá výpočtu
    For r = iRokOd - 5 To iRokDo
        dN = VelkaNoc(r)
        db.Execute "UPDATE Sviatky SET Rok = " & r & " WHERE Rok IS NULL AND Den = " & Day(dN - 2) & " AND Mesiac = " & Month(dN - 2) & ";", dbFailOnError
        db.Execute "UPDATE Sviatky SET Rok = " & r & " WHERE Rok IS NULL AND Den = " & Day(dN + 1) & " AND Mesiac = " & Month(dN + 1) & ";", dbFailOnError
    Next r

    For Each v In PevneSviatkyDef()
        a = Split(CStr(v), "|")
        If DCount("*", "Sviatky", "Den = " & a(0) & " AND Mesiac = " & a(1) & " AND Rok IS NULL") = 0 Then
            db.Execute "INSERT INTO Sviatky (Den, Mesiac, Nazov) VALUES (" & a(0) & ", " & a(1) & ", " & mod_00_Common.SqlText(a(2)) & ");", dbFailOnError
            n = n + 1
        End If
    Next v

    For r = iRokOd To iRokDo
        dN = VelkaNoc(r)
        If DCount("*", "Sviatky", "Rok = " & r & " AND Den = " & Day(dN - 2) & " AND Mesiac = " & Month(dN - 2)) = 0 Then
            db.Execute "INSERT INTO Sviatky (Den, Mesiac, Nazov, Rok) VALUES (" & Day(dN - 2) & ", " & Month(dN - 2) & ", 'Veľký piatok', " & r & ");", dbFailOnError
            n = n + 1
        End If
        If DCount("*", "Sviatky", "Rok = " & r & " AND Den = " & Day(dN + 1) & " AND Mesiac = " & Month(dN + 1)) = 0 Then
            db.Execute "INSERT INTO Sviatky (Den, Mesiac, Nazov, Rok) VALUES (" & Day(dN + 1) & ", " & Month(dN + 1) & ", 'Veľkonočný pondelok', " & r & ");", dbFailOnError
            n = n + 1
        End If
    Next r
    PridajSviatkyRokov = n
End Function

'-------------------------------------------------------------------------------
' Nastaví pre doteraz neoznačené prerušenia predvolené "ukončiť do konca smeny" (jednorazovo).
'-------------------------------------------------------------------------------
Private Sub InicializujAutoKoniec(ByRef db As DAO.Database)
    Dim v As Variant, a() As String
    If Not mod_00_Common.PoleExistujeDB(db, "CiselnikPreruseni", "AutoKoniecDoKoncaSmeny") Then Exit Sub
    If Len(mod_00_Common.GetNastavenie("AutoKoniecInicializovane", "")) > 0 Then Exit Sub
    If DCount("*", "CiselnikPreruseni", "AutoKoniecDoKoncaSmeny = True") = 0 Then
        For Each v In PredvolenePreruseniaDef()
            a = Split(CStr(v), "|")
            If a(8) = "1" Then db.Execute "UPDATE CiselnikPreruseni SET AutoKoniecDoKoncaSmeny = True WHERE Cislo = " & a(0) & ";", dbFailOnError
        Next v
    End If
    Call mod_00_Common.SetNastavenie("AutoKoniecInicializovane", "1", "Predvolené príznaky 'ukončiť prerušenie do konca smeny' už boli nastavené")
End Sub

'-------------------------------------------------------------------------------
' Hlavná inicializácia. Vráti počet pridaných záznamov (-1 pri chybe).
'-------------------------------------------------------------------------------
Public Function InicializujPredvolenuKonfiguraciu(Optional ByVal bTicho As Boolean = False) As Long
    On Error GoTo Chyba
    Dim db As DAO.Database, n As Long
    Set db = CurrentDb

    Call mod_01_SystemInit.VytvorTabulkyImportu(db)
    Call mod_01_SystemInit.InicializujPravidlaAnomalii
    Call ZabezpecStlpceKonfiguracie(db)
    Call mod_09_AutoOprava.ZabezpecTabulky(db)

    n = n + DoplnPreruseniaAKody(db)
    Call InicializujAutoKoniec(db)
    n = n + DoplnNastavenia()
    n = n + PridajSviatkyRokov(db, Year(Date) - 1, Year(Date) + 2)

    Call mod_09_AutoOprava.ObnovCache
    Call mod_08_UdalostiDna.ObnovParametre
    Call modMesaatnaDochadzka.ObnovCacheNazvov
    Call mod_00_Common.ZapisLog("InicializujPredvolenuKonfiguraciu", "INFO", "Pridaných záznamov: " & n)
    If Not bTicho Then MsgBox "Predvolená konfigurácia je pripravená." & vbCrLf & "Pridaných záznamov: " & n & vbCrLf & vbCrLf & _
                              "Existujúce nastavenia sa nemenili.", vbInformation, "Konfigurácia"
    InicializujPredvolenuKonfiguraciu = n
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_10_Konfiguracia.InicializujPredvolenuKonfiguraciu", "ERROR", Err.Description)
    If Not bTicho Then MsgBox "Chyba pri inicializácii konfigurácie: " & Err.Description, vbCritical
    InicializujPredvolenuKonfiguraciu = -1
End Function

'-------------------------------------------------------------------------------
' Zmení jeden kľúč v texte Parametre pravidla ("A=1; B=2"); ak kľúč chýba, pridá ho.
'-------------------------------------------------------------------------------
Public Function NastavParameterPravidla(ByVal strKod As String, ByVal strKluc As String, ByVal strHodnota As String) As Boolean
    On Error GoTo Chyba
    Dim rs As DAO.Recordset, a() As String, i As Long, strNovy As String, strP As String, bNasiel As Boolean, p As Long
    Set rs = CurrentDb.OpenRecordset("SELECT Parametre FROM CiselnikPravidielAnomalii WHERE KodAnomalie = " & mod_00_Common.SqlText(strKod) & ";", dbOpenDynaset)
    If rs.EOF Then rs.Close: Exit Function
    strP = CStr(Nz(rs!Parametre, ""))
    a = Split(Replace(strP, vbCrLf, ";"), ";")
    For i = 0 To UBound(a)
        If Len(Trim$(a(i))) > 0 Then
            p = InStr(a(i), "=")
            If p > 0 And StrComp(Trim$(Left$(a(i), p - 1)), strKluc, vbTextCompare) = 0 Then
                strNovy = strNovy & IIf(Len(strNovy) > 0, "; ", "") & strKluc & "=" & strHodnota
                bNasiel = True
            Else
                strNovy = strNovy & IIf(Len(strNovy) > 0, "; ", "") & Trim$(a(i))
            End If
        End If
    Next i
    If Not bNasiel Then strNovy = strNovy & IIf(Len(strNovy) > 0, "; ", "") & strKluc & "=" & strHodnota
    rs.Edit
    rs!Parametre = Left$(strNovy, 255)
    rs.Update
    rs.Close
    NastavParameterPravidla = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_10_Konfiguracia.NastavParameterPravidla", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Uloží parametre výpočtu. Vráti chybovú správu (prázdna = OK).
'-------------------------------------------------------------------------------
Public Function UlozParametreVypoctu(ByVal strOd As String, ByVal strDo As String, ByVal lObedMin As Long, _
                                     ByVal lObedLimit As Long, ByVal lCelodenna As Long) As String
    On Error GoTo Chyba
    Dim lOdMin As Long, lDoMin As Long
    lOdMin = mod_00_Common.CasNaMinuty(strOd)
    lDoMin = mod_00_Common.CasNaMinuty(strDo)
    If lOdMin < 0 Or lDoMin <= lOdMin Then UlozParametreVypoctu = "Okno práce musí byť v tvare HH:MM a koniec musí byť po začiatku.": Exit Function
    If lObedMin < 0 Or lObedMin > 120 Then UlozParametreVypoctu = "Trvanie obeda musí byť 0 až 120 minút.": Exit Function
    If lObedLimit < 60 Then UlozParametreVypoctu = "Limit pre odpočet obeda musí byť aspoň 60 minút.": Exit Function
    If lCelodenna < 60 Then UlozParametreVypoctu = "Limit celodennej prekážky musí byť aspoň 60 minút.": Exit Function

    Call mod_00_Common.SetNastavenie("OknoPraceOd", Format$(lOdMin \ 60, "00") & ":" & Format$(lOdMin Mod 60, "00"))
    Call mod_00_Common.SetNastavenie("OknoPraceDo", Format$(lDoMin \ 60, "00") & ":" & Format$(lDoMin Mod 60, "00"))
    Call mod_00_Common.SetNastavenie("CelodennaPrekazkaMin", CStr(lCelodenna))
    Call NastavParameterPravidla("AUTO_OBED_NAD_6H", "TrvanieObedaMin", CStr(lObedMin))
    CurrentDb.Execute "UPDATE CiselnikPravidielAnomalii SET CasovyLimitMin = " & lObedLimit & " WHERE KodAnomalie = 'AUTO_OBED_NAD_6H';", dbFailOnError
    Call mod_08_UdalostiDna.ObnovParametre
    Exit Function
Chyba:
    UlozParametreVypoctu = Err.Description
End Function

'-------------------------------------------------------------------------------
' SQL pre zoznam prerušení v UI (prvý stĺpec = Cislo).
'-------------------------------------------------------------------------------
Public Function ZoznamPreruseniSQL() As String
    ZoznamPreruseniSQL = "SELECT Cislo, Nazov, NazovSkratka, KodZaciatok, KodKoniec, IIf(AutoKoniecDoKoncaSmeny, 'áno', '') AS AutoKon " & _
                         "FROM CiselnikPreruseni ORDER BY Cislo;"
End Function

'-------------------------------------------------------------------------------
' Uloží (vloží / zmení) jedno prerušenie spolu s jeho kódmi razení. Vráti chybovú správu (prázdna = OK).
'-------------------------------------------------------------------------------
Public Function UlozPrerusenie(ByVal lCislo As Long, ByVal strNazov As String, ByVal strSkratka As String, _
                               ByVal lKodZ As Long, ByVal lKodK As Long, ByVal bAutoKoniec As Boolean) As String
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset
    Set db = CurrentDb

    If lCislo <= 0 Then UlozPrerusenie = "Číslo prerušenia musí byť kladné.": Exit Function
    If Len(Trim$(strNazov)) = 0 Then UlozPrerusenie = "Zadajte názov prerušenia.": Exit Function
    If lCislo = 1 Then bAutoKoniec = False
    If lKodZ <= 0 Or lKodK <= 0 Or lKodZ = lKodK Then UlozPrerusenie = "Kódy razenia (začiatok / koniec) musia byť rôzne kladné čísla.": Exit Function
    If DCount("*", "KodyRazeni", "KodRazenia = " & lKodZ & " AND CisloPreruseni <> " & lCislo) > 0 Then UlozPrerusenie = "Kód " & lKodZ & " už používa iné prerušenie.": Exit Function
    If DCount("*", "KodyRazeni", "KodRazenia = " & lKodK & " AND CisloPreruseni <> " & lCislo) > 0 Then UlozPrerusenie = "Kód " & lKodK & " už používa iné prerušenie.": Exit Function

    Call ZabezpecStlpceKonfiguracie(db)
    Set rs = db.OpenRecordset("SELECT * FROM CiselnikPreruseni WHERE Cislo = " & lCislo & ";", dbOpenDynaset)
    If rs.EOF Then
        rs.AddNew
        rs!Cislo = lCislo
        rs!FunkciaZaciatok = IIf(lCislo = 1, 2, 1)
        rs!FunkciaKoniec = IIf(lCislo = 1, 3, 1)
        rs!TypVypoctu = "STANDARD"
        rs!ZapocitavatDoFondu = False
        rs!AutoDopocet = False
    Else
        ' pôvodné kódy odpoj od tohto prerušenia (ak sa menili)
        db.Execute "DELETE FROM KodyRazeni WHERE CisloPreruseni = " & lCislo & " AND KodRazenia NOT IN (" & lKodZ & ", " & lKodK & ") " & _
                   "AND KodRazenia NOT IN (SELECT KodPrerusenia FROM DochadzkaImport WHERE KodPrerusenia IS NOT NULL);", dbFailOnError
        rs.Edit
    End If
    rs!Nazov = Left$(Trim$(strNazov), 100)
    rs!NazovSkratka = Left$(Trim$(strSkratka), 20)
    rs!KodZaciatok = lKodZ
    rs!KodKoniec = lKodK
    rs!TextZaciatok = Left$(Trim$(strNazov) & " - odchod", 50)
    rs!TextKoniec = Left$(Trim$(strNazov) & " - príchod", 50)
    rs!AutoKoniecDoKoncaSmeny = bAutoKoniec
    rs.Update
    rs.Close

    Call ZapisKodRazenia(db, lKodZ, lCislo, "Z", Left$(Trim$(strNazov) & " - odchod", 50), strNazov)
    Call ZapisKodRazenia(db, lKodK, lCislo, "K", Left$(Trim$(strNazov) & " - príchod", 50), strNazov)
    Call mod_09_AutoOprava.ObnovCache
    Call modMesaatnaDochadzka.ObnovCacheNazvov
    Call mod_00_Common.ZapisLog("Konfigurácia", "INFO", "Uložené prerušenie " & lCislo & " (" & strNazov & ")")
    Exit Function
Chyba:
    UlozPrerusenie = Err.Description
End Function

Private Sub ZapisKodRazenia(ByRef db As DAO.Database, ByVal lKod As Long, ByVal lCislo As Long, ByVal strSmer As String, ByVal strText As String, ByVal strNazov As String)
    Dim rs As DAO.Recordset
    Set rs = db.OpenRecordset("SELECT * FROM KodyRazeni WHERE KodRazenia = " & lKod & ";", dbOpenDynaset)
    If rs.EOF Then rs.AddNew: rs!KodRazenia = lKod Else rs.Edit
    rs!CisloPreruseni = lCislo
    rs!Smer = strSmer
    rs!TextRazenia = strText
    rs.Update
    rs.Close
    If mod_00_Common.TabulkaExistujeDB(db, "TypyUdalosti") Then
        Set rs = db.OpenRecordset("SELECT * FROM TypyUdalosti WHERE Kod = " & lKod & ";", dbOpenDynaset)
        If rs.EOF Then rs.AddNew: rs!Kod = lKod Else rs.Edit
        rs!Nazov = Left$(strText, 100)
        rs!Typ = strSmer
        rs!Kategoria = Left$(strNazov, 50)
        rs!ZapocitatDoPrace = (lCislo = 1)
        rs.Update
        rs.Close
    End If
End Sub

'-------------------------------------------------------------------------------
' Zmaže prerušenie, ak sa nepoužíva v žiadnom razení. Vráti chybovú správu (prázdna = OK).
'-------------------------------------------------------------------------------
Public Function ZmazPrerusenie(ByVal lCislo As Long) As String
    On Error GoTo Chyba
    Dim db As DAO.Database
    Set db = CurrentDb
    If lCislo = 1 Or lCislo = 7 Then ZmazPrerusenie = "Prerušenie " & lCislo & " (práca / obed) je systémové a nedá sa zmazať.": Exit Function
    Dim lPouzite As Long
    lPouzite = DCount("*", "DochadzkaImport", "CisloPreruseni = " & lCislo)
    If lPouzite = 0 Then lPouzite = DCount("*", "DochadzkaImport", "KodPrerusenia IN (SELECT KodRazenia FROM KodyRazeni WHERE CisloPreruseni = " & lCislo & ")")
    If lPouzite > 0 Then
        ZmazPrerusenie = "Prerušenie sa už používa v " & lPouzite & " razeniach - mazanie by poškodilo históriu."
        Exit Function
    End If
    db.Execute "DELETE FROM KodyRazeni WHERE CisloPreruseni = " & lCislo & ";", dbFailOnError
    db.Execute "DELETE FROM CiselnikPreruseni WHERE Cislo = " & lCislo & ";", dbFailOnError
    Call mod_09_AutoOprava.ObnovCache
    Call modMesaatnaDochadzka.ObnovCacheNazvov
    Call mod_00_Common.ZapisLog("Konfigurácia", "INFO", "Zmazané prerušenie " & lCislo)
    Exit Function
Chyba:
    ZmazPrerusenie = Err.Description
End Function

'-------------------------------------------------------------------------------
' Textový prehľad stavu konfigurácie (na kontrolu v UI).
'-------------------------------------------------------------------------------
Public Function StavKonfiguracie() As String
    On Error Resume Next
    Dim s As String
    s = "Prerušenia: " & DCount("*", "CiselnikPreruseni") & vbCrLf & _
        "Kódy razení: " & DCount("*", "KodyRazeni") & vbCrLf & _
        "Pravidlá anomálií: " & DCount("*", "CiselnikPravidielAnomalii") & vbCrLf & _
        "Sviatky (riadkov): " & DCount("*", "Sviatky") & vbCrLf & _
        "Zamestnanci: " & DCount("*", "Zamestnanci") & vbCrLf & _
        "Pracovné fondy: " & DCount("*", "PracovneFondy") & " (bez fondu sa používa " & mod_00_Common.GetNastavenie("PredvolenyFondMin", "450") & " min/deň)"
    StavKonfiguracie = s
End Function
