Attribute VB_Name = "mod_21_RezimyVypoctu"
'@Verzia 1.1.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_21_RezimyVypoctu
' POPIS: Režimy výpočtu (kontrakt 1.5.0) - dátová vrstva. Režim je pomenovaná sada prepísaných parametrov, ktorú správca (HR)
'        priradí zamestnancovi na obdobie od - do (napr. krízová situácia). Mimo obdobia platia základné nastavenia.
'
'   Princíp (rozhodnutie vlastníka 5. 11. 2026): či a ako sa čo počíta, určujú parametre v Accesse, nie kód. My dodáme len počiatočné
'   hodnoty podľa organizácie; za nastavenie zodpovedá správca. Preto je zoznam parametrov, ktoré režim smie prepísať, zatvorený
'   (rovnaký ako v kontrakte 1.5.0) a každá hodnota sa pri uložení overí v rovnakých medziach, aké overuje terminál.
'
'   Tabuľky (všetky prázdne, kým správca nič nenastaví - výpočet sa potom nemení):
'     RezimyVypoctu      (RezimID, Nazov, Poznamka, Vytvoril, VytvorenyDna)       - zoznam režimov, najviac 20, číslo 1 až 99
'     RezimyPravidla     (RezimID, Kluc, Hodnota)                                  - prepísané pravidlá, Kluc je názov z kontraktu
'     RezimyPreruseni    (RezimID, CisloPreruseni, TypVypoctu, PrahCelyDenMin, DoZakladuObeda)
'                                                                                  - úpravy prerušení; prázdna hodnota = bez úpravy
'     ZamestnanciRezimy  (ID, OsobneCislo, RezimID, PlatiOd, PlatiDo)              - obdobia zamestnanca (vrátane oboch dní, bez prekrytia)
'   Nové vlastnosti prerušenia v číselníku (CiselnikPreruseni): PrahCelyDenMin (od akej dĺžky jedného intervalu sa započíta celý
'   denný fond; prázdne = spoločná hranica z nastavení) a DoZakladuObeda (čas prerušenia sa pripočíta k základu pre prah obeda).
'
'   Výpočet: pred výpočtom každého dňa zamestnanca sa režim dňa nastaví cez mod_08_UdalostiDna.NastavRezimVypoctu (modMesaatnaDochadzka,
'   mod_09_AutoOprava); export podľa kontraktu 1.5.0 je v mod_20_KonfiguraciaExport. Neplatný režim (ChybaRezimu) sa vo výpočte ani
'   v exporte neuplatní, deň sa počíta so základnými nastaveniami.
'
'   Uzavretý mesiac sa nemení: obdobie ani parametre režimu, ktoré by zasiahli uzavretý mesiac zamestnanca, sa neuložia.
'
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - ZabezpecTabulky(db)                          : Vytvorí tabuľky režimov a ich období (stĺpce číselníka prerušení doplní mod_10_Konfiguracia).
' - ZoznamPravidiel()                            : Zatvorený zoznam pravidiel, ktoré režim smie prepísať.
' - RozsahPravidla / ChybaPravidla               : Medze pravidla a text chyby pre hodnotu (prázdny text = v poriadku).
' - ZakladnyVypocet(db, č. prerušenia)           : COUNTED / UNPAID / WORK / LUNCH podľa číselníka prerušení.
' - ChybaVlastnostiPreruseni / UlozVlastnostiPreruseni : Overenie a uloženie PrahCelyDenMin a DoZakladuObeda v číselníku.
' - UlozRezim / ZmazRezim                        : Založenie, premenovanie a zmazanie režimu (vrátia text chyby alebo "").
' - UlozPravidloRezimu / OdstranPravidloRezimu   : Prepísané pravidlo režimu.
' - UlozUpravuPrerusenia / OdstranUpravuPrerusenia : Úprava prerušenia v režime.
' - ChybaRezimu(db, id)                          : Kontrola celého režimu (dvojica okna práce, úpravy prerušení); "" = použiteľný.
' - UlozObdobie / OdstranObdobie                 : Obdobie režimu zamestnanca.
' - RezimNaDen(db, OC, deň)                      : Číslo režimu platného v deň (0 = bez režimu).
' - RezimyMesiaca(db, OC, rok, mesiac, pole)     : Číslo režimu pre každý deň mesiaca (pole 1 až 31; používa výpočet a export).
' - DotknutyUzavrety(db, id)                     : Prvý uzavretý mesiac zamestnanca, ktorý režim používa ("" = žiadny).
'===============================================================================

Public Const REZIM_MAX_POCET As Long = 20
Public Const REZIM_MAX_ID As Long = 99
Public Const REZIM_MAX_NAZOV As Long = 40

Private Const TBL_REZIMY As String = "RezimyVypoctu"
Private Const TBL_PRAVIDLA As String = "RezimyPravidla"
Private Const TBL_PRERUSENIA As String = "RezimyPreruseni"
Private Const TBL_OBDOBIA As String = "ZamestnanciRezimy"

'===============================================================================
' TABUĽKY
'===============================================================================

Public Sub ZabezpecTabulky(ByRef db As DAO.Database)
    Dim bNova As Boolean
    On Error GoTo Chyba
    If Not mod_00_Common.TabulkaExistujeDB(db, TBL_REZIMY) Then
        db.Execute "CREATE TABLE " & TBL_REZIMY & " (RezimID LONG PRIMARY KEY, Nazov TEXT(40), Poznamka TEXT(255), Vytvoril TEXT(50), VytvorenyDna DATETIME)", dbFailOnError
        bNova = True
    End If
    If Not mod_00_Common.TabulkaExistujeDB(db, TBL_PRAVIDLA) Then
        db.Execute "CREATE TABLE " & TBL_PRAVIDLA & " (RezimID LONG, Kluc TEXT(40), Hodnota LONG, " & _
                   "CONSTRAINT PK_RezPravidla PRIMARY KEY (RezimID, Kluc))", dbFailOnError
        bNova = True
    End If
    If Not mod_00_Common.TabulkaExistujeDB(db, TBL_PRERUSENIA) Then
        db.Execute "CREATE TABLE " & TBL_PRERUSENIA & " (RezimID LONG, CisloPreruseni LONG, TypVypoctu TEXT(10), PrahCelyDenMin LONG, DoZakladuObeda LONG, " & _
                   "CONSTRAINT PK_RezPreruseni PRIMARY KEY (RezimID, CisloPreruseni))", dbFailOnError
        bNova = True
    End If
    If Not mod_00_Common.TabulkaExistujeDB(db, TBL_OBDOBIA) Then
        db.Execute "CREATE TABLE " & TBL_OBDOBIA & " (ID AUTOINCREMENT PRIMARY KEY, OsobneCislo TEXT(20), RezimID LONG, PlatiOd DATETIME, PlatiDo DATETIME)", dbFailOnError
        On Error Resume Next
        db.Execute "CREATE INDEX idxZR_OC_Od ON " & TBL_OBDOBIA & " (OsobneCislo, PlatiOd)", dbFailOnError
        Err.Clear
        On Error GoTo Chyba
        bNova = True
    End If
    If bNova Then db.TableDefs.Refresh
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_21_RezimyVypoctu.ZabezpecTabulky", "ERROR", Err.Description)
End Sub

'===============================================================================
' ZATVORENÝ ZOZNAM PRAVIDIEL (kontrakt 1.5.0, regimes[].rules)
'===============================================================================

Public Function ZoznamPravidiel() As Variant
    ZoznamPravidiel = Array("work_window_start_min", "work_window_end_min", "full_day_obstacle_min", "auto_lunch_enabled", _
                            "auto_lunch_trigger_min", "auto_lunch_deduct_min", "lunch_recorded_mode", "lunch_min_min", _
                            "unlabeled_out_is_lunch", "rounding_in_min", "rounding_out_min", "rounding_mode", _
                            "auto_repair_mode", "auto_repair_target", "auto_repair_cases")
End Function

'-------------------------------------------------------------------------------
' Medze hodnoty pravidla. False, ak pravidlo režim prepísať nesmie. Áno/nie sa ukladá ako 0 / 1.
'-------------------------------------------------------------------------------
Public Function RozsahPravidla(ByVal strKluc As String, ByRef lMin As Long, ByRef lMax As Long) As Boolean
    RozsahPravidla = True
    Select Case strKluc
        Case "work_window_start_min", "work_window_end_min", "auto_lunch_trigger_min"
            lMin = 0
            lMax = 1440
        Case "full_day_obstacle_min"
            lMin = 1
            lMax = 1440
        Case "auto_lunch_deduct_min", "lunch_min_min"
            lMin = 0
            lMax = 600
        Case "rounding_in_min", "rounding_out_min"
            lMin = 0
            lMax = 60
        Case "lunch_recorded_mode"
            lMin = 0
            lMax = 2
        Case "rounding_mode"
            lMin = 0
            lMax = 3
        Case "auto_repair_mode"
            lMin = 0              ' kontrakt pripúšťa 0 až 9, Access pozná len 0 vypnuté, 1 isté automaticky, 2 všetko automaticky
            lMax = 2
        Case "auto_repair_target", "auto_lunch_enabled", "unlabeled_out_is_lunch"
            lMin = 0
            lMax = 1
        Case "auto_repair_cases"
            lMin = 1
            lMax = 3
        Case Else
            RozsahPravidla = False
            lMin = 0
            lMax = 0
    End Select
End Function

Public Function ChybaPravidla(ByVal strKluc As String, ByVal lHodnota As Long) As String
    Dim lMin As Long, lMax As Long
    If Not RozsahPravidla(strKluc, lMin, lMax) Then
        ChybaPravidla = "Pravidlo " & strKluc & " režim meniť nesmie."
    ElseIf lHodnota < lMin Or lHodnota > lMax Then
        ChybaPravidla = "Pravidlo " & strKluc & " musí byť celé číslo " & lMin & " až " & lMax & "."
    End If
End Function

'===============================================================================
' ZÁKLAD PRERUŠENIA A VLASTNOSTI V ČÍSELNÍKU
'===============================================================================

'-------------------------------------------------------------------------------
' Ako sa prerušenie počíta bez režimu (zodpovedá mod_20_KonfiguraciaExport.TypVypoctu).
'-------------------------------------------------------------------------------
Public Function ZakladnyVypocet(ByRef db As DAO.Database, ByVal lCislo As Long) As String
    Dim rs As DAO.Recordset
    On Error GoTo Chyba
    If lCislo = 1 Then
        ZakladnyVypocet = "WORK"
        Exit Function
    ElseIf lCislo = 7 Then
        ZakladnyVypocet = "LUNCH"
        Exit Function
    End If
    ZakladnyVypocet = "COUNTED"
    If Not mod_00_Common.PoleExistujeDB(db, "CiselnikPreruseni", "NezapocitavatInterval") Then Exit Function
    Set rs = db.OpenRecordset("SELECT NezapocitavatInterval FROM CiselnikPreruseni WHERE Cislo = " & lCislo & ";", dbOpenSnapshot)
    If Not rs.EOF Then
        If Nz(rs!NezapocitavatInterval, False) Then ZakladnyVypocet = "UNPAID"
    End If
    rs.Close
    Exit Function
Chyba:
    ZakladnyVypocet = "COUNTED"
End Function

Private Function ExistujePrerusenie(ByRef db As DAO.Database, ByVal lCislo As Long) As Boolean
    Dim rs As DAO.Recordset
    On Error GoTo Chyba
    Set rs = db.OpenRecordset("SELECT Cislo FROM CiselnikPreruseni WHERE Cislo = " & lCislo & ";", dbOpenSnapshot)
    ExistujePrerusenie = Not rs.EOF
    rs.Close
    Exit Function
Chyba:
    ExistujePrerusenie = False
End Function

'-------------------------------------------------------------------------------
' Overí vlastnosti prerušenia pre výpočet. vPrah: prázdne (Null alebo "") = spoločná hranica, inak 1 až 1440.
' strVypocet: výpočet, ktorý prerušenie bude mať (COUNTED / UNPAID / WORK / LUNCH). Vlastnosti patria len prerušeniu COUNTED.
'-------------------------------------------------------------------------------
Public Function ChybaVlastnostiPreruseni(ByVal lCislo As Long, ByVal strVypocet As String, ByVal vPrah As Variant, ByVal bDoZakladu As Boolean) As String
    Dim bPrah As Boolean
    bPrah = Not (IsNull(vPrah) Or IsEmpty(vPrah))
    If bPrah Then bPrah = (Len(CStr(vPrah)) > 0)
    If bPrah Then
        If Not IsNumeric(vPrah) Then
            ChybaVlastnostiPreruseni = "Hranica celého dňa musí byť celé číslo minút 1 až 1440."
            Exit Function
        End If
        If CDbl(vPrah) <> Int(CDbl(vPrah)) Or CDbl(vPrah) < 1 Or CDbl(vPrah) > 1440 Then
            ChybaVlastnostiPreruseni = "Hranica celého dňa musí byť celé číslo minút 1 až 1440."
            Exit Function
        End If
    End If
    If (bPrah Or bDoZakladu) And strVypocet <> "COUNTED" Then
        ChybaVlastnostiPreruseni = "Hranica celého dňa a pripočítanie k základu obeda patria len prerušeniu, ktorého čas sa započítava " & _
                                   "(nie práci č. 1, obedu č. 7 ani prerušeniu, ktorého interval sa nezapočíta)."
    End If
End Function

'-------------------------------------------------------------------------------
' Uloží vlastnosti prerušenia do číselníka. Vráti text chyby alebo "".
'-------------------------------------------------------------------------------
Public Function UlozVlastnostiPreruseni(ByRef db As DAO.Database, ByVal lCislo As Long, ByVal vPrah As Variant, ByVal bDoZakladu As Boolean) As String
    Dim rs As DAO.Recordset, strChyba As String, bPrah As Boolean
    On Error GoTo Chyba
    If Not ExistujePrerusenie(db, lCislo) Then
        UlozVlastnostiPreruseni = "Prerušenie č. " & lCislo & " neexistuje."
        Exit Function
    End If
    strChyba = ChybaVlastnostiPreruseni(lCislo, ZakladnyVypocet(db, lCislo), vPrah, bDoZakladu)
    If Len(strChyba) > 0 Then
        UlozVlastnostiPreruseni = strChyba
        Exit Function
    End If
    bPrah = Not (IsNull(vPrah) Or IsEmpty(vPrah))
    If bPrah Then bPrah = (Len(CStr(vPrah)) > 0)
    Set rs = db.OpenRecordset("SELECT * FROM CiselnikPreruseni WHERE Cislo = " & lCislo & ";", dbOpenDynaset)
    rs.Edit
    If bPrah Then rs!PrahCelyDenMin = CLng(vPrah) Else rs!PrahCelyDenMin = Null
    rs!DoZakladuObeda = bDoZakladu
    rs.Update
    rs.Close
    mod_08_UdalostiDna.ObnovParametre
    Exit Function
Chyba:
    UlozVlastnostiPreruseni = "Vlastnosti prerušenia sa nepodarilo uložiť: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_21_RezimyVypoctu.UlozVlastnostiPreruseni", "ERROR", Err.Description)
End Function

'===============================================================================
' REŽIMY
'===============================================================================

Private Function ExistujeRezim(ByRef db As DAO.Database, ByVal lID As Long) As Boolean
    Dim rs As DAO.Recordset
    On Error GoTo Chyba
    Set rs = db.OpenRecordset("SELECT RezimID FROM " & TBL_REZIMY & " WHERE RezimID = " & lID & ";", dbOpenSnapshot)
    ExistujeRezim = Not rs.EOF
    rs.Close
    Exit Function
Chyba:
    ExistujeRezim = False
End Function

Private Function ChybaNazvu(ByRef db As DAO.Database, ByVal lID As Long, ByVal strNazov As String) As String
    Dim rs As DAO.Recordset, i As Long
    If Len(strNazov) < 1 Or Len(strNazov) > REZIM_MAX_NAZOV Then
        ChybaNazvu = "Názov režimu musí mať 1 až " & REZIM_MAX_NAZOV & " znakov."
        Exit Function
    End If
    For i = 1 To Len(strNazov)
        If AscW(Mid$(strNazov, i, 1)) < 32 Then
            ChybaNazvu = "Názov režimu nesmie obsahovať riadiace znaky."
            Exit Function
        End If
    Next i
    Set rs = db.OpenRecordset("SELECT RezimID, Nazov FROM " & TBL_REZIMY & ";", dbOpenSnapshot)
    Do While Not rs.EOF
        If CLng(rs!RezimID) <> lID Then
            If StrComp(CStr(Nz(rs!Nazov, "")), strNazov, vbTextCompare) = 0 Then
                ChybaNazvu = "Režim s názvom '" & strNazov & "' už existuje (číslo " & rs!RezimID & ")."
                Exit Do
            End If
        End If
        rs.MoveNext
    Loop
    rs.Close
End Function

'-------------------------------------------------------------------------------
' Založí režim, alebo zmení názov a poznámku existujúceho. Vráti text chyby alebo "".
'-------------------------------------------------------------------------------
Public Function UlozRezim(ByRef db As DAO.Database, ByVal lID As Long, ByVal strNazov As String, Optional ByVal strPoznamka As String = "") As String
    Dim rs As DAO.Recordset, strChyba As String, lPocet As Long, strZ As String
    On Error GoTo Chyba
    If lID < 1 Or lID > REZIM_MAX_ID Then
        UlozRezim = "Číslo režimu musí byť 1 až " & REZIM_MAX_ID & "."
        Exit Function
    End If
    strNazov = Trim$(strNazov)
    strChyba = ChybaNazvu(db, lID, strNazov)
    If Len(strChyba) > 0 Then
        UlozRezim = strChyba
        Exit Function
    End If
    If ExistujeRezim(db, lID) Then
        strZ = DotknutyUzavrety(db, lID)
        If Len(strZ) > 0 Then
            UlozRezim = "Režim používa uzavretý mesiac (" & strZ & "), preto ho nemožno zmeniť. Založte nový režim alebo mesiac najprv otvorte."
            Exit Function
        End If
        Set rs = db.OpenRecordset("SELECT * FROM " & TBL_REZIMY & " WHERE RezimID = " & lID & ";", dbOpenDynaset)
        rs.Edit
    Else
        Set rs = db.OpenRecordset("SELECT COUNT(*) AS Pocet FROM " & TBL_REZIMY & ";", dbOpenSnapshot)
        lPocet = CLng(Nz(rs!Pocet, 0))
        rs.Close
        If lPocet >= REZIM_MAX_POCET Then
            UlozRezim = "Režimov môže byť najviac " & REZIM_MAX_POCET & "."
            Exit Function
        End If
        Set rs = db.OpenRecordset("SELECT * FROM " & TBL_REZIMY & " WHERE RezimID = " & lID & ";", dbOpenDynaset)
        rs.AddNew
        rs!RezimID = lID
        rs!Vytvoril = Left$(mod_00_Common.Uzivatel(), 50)
        rs!VytvorenyDna = Now()
    End If
    rs!Nazov = strNazov
    rs!Poznamka = Left$(strPoznamka, 255)
    rs.Update
    rs.Close
    mod_08_UdalostiDna.ObnovParametre
    Exit Function
Chyba:
    UlozRezim = "Režim sa nepodarilo uložiť: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_21_RezimyVypoctu.UlozRezim", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Zmaže režim s jeho pravidlami a úpravami. Režim priradený zamestnancovi sa nezmaže (najprv treba zrušiť jeho obdobia).
'-------------------------------------------------------------------------------
Public Function ZmazRezim(ByRef db As DAO.Database, ByVal lID As Long) As String
    Dim rs As DAO.Recordset, lPouzit As Long
    On Error GoTo Chyba
    If Not ExistujeRezim(db, lID) Then
        ZmazRezim = "Režim č. " & lID & " neexistuje."
        Exit Function
    End If
    Set rs = db.OpenRecordset("SELECT COUNT(*) AS Pocet FROM " & TBL_OBDOBIA & " WHERE RezimID = " & lID & ";", dbOpenSnapshot)
    lPouzit = CLng(Nz(rs!Pocet, 0))
    rs.Close
    If lPouzit > 0 Then
        ZmazRezim = "Režim je priradený zamestnancom (" & lPouzit & " období). Najprv zrušte tieto obdobia."
        Exit Function
    End If
    db.Execute "DELETE FROM " & TBL_PRERUSENIA & " WHERE RezimID = " & lID & ";", dbFailOnError
    db.Execute "DELETE FROM " & TBL_PRAVIDLA & " WHERE RezimID = " & lID & ";", dbFailOnError
    db.Execute "DELETE FROM " & TBL_REZIMY & " WHERE RezimID = " & lID & ";", dbFailOnError
    mod_08_UdalostiDna.ObnovParametre
    Exit Function
Chyba:
    ZmazRezim = "Režim sa nepodarilo zmazať: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_21_RezimyVypoctu.ZmazRezim", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Kontrola celého režimu: dvojica okna práce, úpravy prerušení. Vráti text prvej chyby, alebo "" (režim je použiteľný).
'-------------------------------------------------------------------------------
Public Function ChybaRezimu(ByRef db As DAO.Database, ByVal lID As Long) As String
    Dim rs As DAO.Recordset, bZac As Boolean, bKon As Boolean, lZac As Long, lKon As Long
    Dim lC As Long, strTyp As String, strEf As String, bPrah As Boolean, lDo As Long, bMa As Boolean
    On Error GoTo Chyba
    If Not ExistujeRezim(db, lID) Then
        ChybaRezimu = "Režim č. " & lID & " neexistuje."
        Exit Function
    End If
    Set rs = db.OpenRecordset("SELECT Kluc, Hodnota FROM " & TBL_PRAVIDLA & " WHERE RezimID = " & lID & ";", dbOpenSnapshot)
    Do While Not rs.EOF
        If IsNull(rs!Hodnota) Then
            ChybaRezimu = "Pravidlo " & rs!Kluc & " nemá hodnotu."
            rs.Close
            Exit Function
        End If
        ChybaRezimu = ChybaPravidla(CStr(rs!Kluc), CLng(rs!Hodnota))
        If Len(ChybaRezimu) > 0 Then
            rs.Close
            Exit Function
        End If
        If rs!Kluc = "work_window_start_min" Then
            bZac = True
            lZac = CLng(rs!Hodnota)
        ElseIf rs!Kluc = "work_window_end_min" Then
            bKon = True
            lKon = CLng(rs!Hodnota)
        End If
        bMa = True
        rs.MoveNext
    Loop
    rs.Close
    If bZac <> bKon Then
        ChybaRezimu = "Začiatok a koniec okna práce sa musia nastaviť spolu."
        Exit Function
    End If
    If bZac And lKon <= lZac Then
        ChybaRezimu = "Koniec okna práce musí byť po jeho začiatku."
        Exit Function
    End If
    Set rs = db.OpenRecordset("SELECT CisloPreruseni, TypVypoctu, PrahCelyDenMin, DoZakladuObeda FROM " & TBL_PRERUSENIA & " WHERE RezimID = " & lID & ";", dbOpenSnapshot)
    Do While Not rs.EOF
        lC = CLng(rs!CisloPreruseni)
        bMa = True
        If lC = 1 Or lC = 7 Then
            ChybaRezimu = "Prácu (č. 1) a obed (č. 7) režim nemení; pravidlá obeda sú medzi pravidlami režimu."
        ElseIf Not ExistujePrerusenie(db, lC) Then
            ChybaRezimu = "Úprava neexistujúceho prerušenia č. " & lC & "."
        End If
        If Len(ChybaRezimu) = 0 Then
            strTyp = CStr(Nz(rs!TypVypoctu, ""))
            bPrah = Not IsNull(rs!PrahCelyDenMin)
            lDo = CLng(Nz(rs!DoZakladuObeda, 0))
            If Len(strTyp) = 0 And Not bPrah And IsNull(rs!DoZakladuObeda) Then
                ChybaRezimu = "Prerušenie č. " & lC & " nič nemení."
            ElseIf Len(strTyp) > 0 And strTyp <> "COUNTED" And strTyp <> "UNPAID" Then
                ChybaRezimu = "Prerušenie č. " & lC & ": výpočet musí byť COUNTED alebo UNPAID."
            ElseIf lDo <> 0 And lDo <> 1 Then
                ChybaRezimu = "Prerušenie č. " & lC & ": pripočítanie k základu obeda musí byť 0 alebo 1."
            End If
        End If
        If Len(ChybaRezimu) = 0 Then
            If Len(strTyp) > 0 Then strEf = strTyp Else strEf = ZakladnyVypocet(db, lC)
            If bPrah Then
                If CLng(rs!PrahCelyDenMin) < 1 Or CLng(rs!PrahCelyDenMin) > 1440 Then
                    ChybaRezimu = "Prerušenie č. " & lC & ": hranica celého dňa musí byť 1 až 1440."
                ElseIf strEf <> "COUNTED" Then
                    ChybaRezimu = "Prerušenie č. " & lC & ": hranica celého dňa patrí len prerušeniu, ktorého čas sa započítava."
                End If
            End If
            If Len(ChybaRezimu) = 0 And lDo = 1 And strEf <> "COUNTED" Then
                ChybaRezimu = "Prerušenie č. " & lC & ": pripočítanie k základu obeda patrí len prerušeniu, ktorého čas sa započítava."
            End If
        End If
        If Len(ChybaRezimu) > 0 Then
            rs.Close
            Exit Function
        End If
        rs.MoveNext
    Loop
    rs.Close
    If Not bMa Then ChybaRezimu = "Režim nič nemení (nemá žiadne pravidlo ani úpravu prerušenia)."
    Exit Function
Chyba:
    ChybaRezimu = "Režim sa nepodarilo skontrolovať: " & Err.Description
End Function

Private Function ChybaZmenyRezimu(ByRef db As DAO.Database, ByVal lID As Long) As String
    Dim strZ As String
    If Not ExistujeRezim(db, lID) Then
        ChybaZmenyRezimu = "Režim č. " & lID & " neexistuje."
        Exit Function
    End If
    strZ = DotknutyUzavrety(db, lID)
    If Len(strZ) > 0 Then
        ChybaZmenyRezimu = "Režim používa uzavretý mesiac (" & strZ & "), preto ho nemožno zmeniť. Založte nový režim alebo mesiac najprv otvorte."
    End If
End Function

'-------------------------------------------------------------------------------
' Prepíše pravidlo v režime. Samotná hodnota sa overí hneď, súvislosti (dvojica okna práce) overí ChybaRezimu.
'-------------------------------------------------------------------------------
Public Function UlozPravidloRezimu(ByRef db As DAO.Database, ByVal lID As Long, ByVal strKluc As String, ByVal lHodnota As Long) As String
    Dim rs As DAO.Recordset, strChyba As String
    On Error GoTo Chyba
    strChyba = ChybaZmenyRezimu(db, lID)
    If Len(strChyba) = 0 Then strChyba = ChybaPravidla(strKluc, lHodnota)
    If Len(strChyba) > 0 Then
        UlozPravidloRezimu = strChyba
        Exit Function
    End If
    Set rs = db.OpenRecordset("SELECT * FROM " & TBL_PRAVIDLA & " WHERE RezimID = " & lID & " AND Kluc = " & mod_00_Common.SqlText(strKluc) & ";", dbOpenDynaset)
    If rs.EOF Then
        rs.AddNew
        rs!RezimID = lID
        rs!Kluc = strKluc
    Else
        rs.Edit
    End If
    rs!Hodnota = lHodnota
    rs.Update
    rs.Close
    mod_08_UdalostiDna.ObnovParametre
    Exit Function
Chyba:
    UlozPravidloRezimu = "Pravidlo sa nepodarilo uložiť: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_21_RezimyVypoctu.UlozPravidloRezimu", "ERROR", Err.Description)
End Function

Public Function OdstranPravidloRezimu(ByRef db As DAO.Database, ByVal lID As Long, ByVal strKluc As String) As String
    Dim strChyba As String
    On Error GoTo Chyba
    strChyba = ChybaZmenyRezimu(db, lID)
    If Len(strChyba) > 0 Then
        OdstranPravidloRezimu = strChyba
        Exit Function
    End If
    db.Execute "DELETE FROM " & TBL_PRAVIDLA & " WHERE RezimID = " & lID & " AND Kluc = " & mod_00_Common.SqlText(strKluc) & ";", dbFailOnError
    mod_08_UdalostiDna.ObnovParametre
    Exit Function
Chyba:
    OdstranPravidloRezimu = "Pravidlo sa nepodarilo odstrániť: " & Err.Description
End Function

'-------------------------------------------------------------------------------
' Úprava prerušenia v režime. strTyp: "" bez zmeny výpočtu, "COUNTED" alebo "UNPAID". vPrah: prázdne = bez úpravy, inak 1 až 1440.
' vDoZakladu: prázdne = bez úpravy, 0 alebo 1.
'-------------------------------------------------------------------------------
Public Function UlozUpravuPrerusenia(ByRef db As DAO.Database, ByVal lID As Long, ByVal lCislo As Long, ByVal strTyp As String, _
                                     ByVal vPrah As Variant, ByVal vDoZakladu As Variant) As String
    Dim rs As DAO.Recordset, strChyba As String, strEf As String, bPrah As Boolean, bZakl As Boolean, lZakl As Long
    On Error GoTo Chyba
    strChyba = ChybaZmenyRezimu(db, lID)
    If Len(strChyba) > 0 Then
        UlozUpravuPrerusenia = strChyba
        Exit Function
    End If
    If lCislo = 1 Or lCislo = 7 Then
        UlozUpravuPrerusenia = "Prácu (č. 1) a obed (č. 7) režim nemení; pravidlá obeda sú medzi pravidlami režimu."
        Exit Function
    End If
    If Not ExistujePrerusenie(db, lCislo) Then
        UlozUpravuPrerusenia = "Prerušenie č. " & lCislo & " neexistuje."
        Exit Function
    End If
    If Len(strTyp) > 0 And strTyp <> "COUNTED" And strTyp <> "UNPAID" Then
        UlozUpravuPrerusenia = "Výpočet prerušenia musí byť COUNTED alebo UNPAID."
        Exit Function
    End If
    bZakl = Not (IsNull(vDoZakladu) Or IsEmpty(vDoZakladu))
    If bZakl Then bZakl = (Len(CStr(vDoZakladu)) > 0)
    If bZakl Then
        If Not IsNumeric(vDoZakladu) Then
            UlozUpravuPrerusenia = "Pripočítanie k základu obeda musí byť 0 alebo 1."
            Exit Function
        End If
        lZakl = CLng(vDoZakladu)
        If lZakl <> 0 And lZakl <> 1 Then
            UlozUpravuPrerusenia = "Pripočítanie k základu obeda musí byť 0 alebo 1."
            Exit Function
        End If
    End If
    bPrah = Not (IsNull(vPrah) Or IsEmpty(vPrah))
    If bPrah Then bPrah = (Len(CStr(vPrah)) > 0)
    If Len(strTyp) > 0 Then strEf = strTyp Else strEf = ZakladnyVypocet(db, lCislo)
    strChyba = ChybaVlastnostiPreruseni(lCislo, strEf, vPrah, (bZakl And lZakl = 1))
    If Len(strChyba) > 0 Then
        UlozUpravuPrerusenia = strChyba
        Exit Function
    End If
    If Len(strTyp) = 0 And Not bPrah And Not bZakl Then
        UlozUpravuPrerusenia = "Úprava nič nemení. Ak ju už nechcete, odstráňte ju."
        Exit Function
    End If
    Set rs = db.OpenRecordset("SELECT * FROM " & TBL_PRERUSENIA & " WHERE RezimID = " & lID & " AND CisloPreruseni = " & lCislo & ";", dbOpenDynaset)
    If rs.EOF Then
        rs.AddNew
        rs!RezimID = lID
        rs!CisloPreruseni = lCislo
    Else
        rs.Edit
    End If
    If Len(strTyp) > 0 Then rs!TypVypoctu = strTyp Else rs!TypVypoctu = Null
    If bPrah Then rs!PrahCelyDenMin = CLng(vPrah) Else rs!PrahCelyDenMin = Null
    If bZakl Then rs!DoZakladuObeda = lZakl Else rs!DoZakladuObeda = Null
    rs.Update
    rs.Close
    mod_08_UdalostiDna.ObnovParametre
    Exit Function
Chyba:
    UlozUpravuPrerusenia = "Úpravu prerušenia sa nepodarilo uložiť: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_21_RezimyVypoctu.UlozUpravuPrerusenia", "ERROR", Err.Description)
End Function

Public Function OdstranUpravuPrerusenia(ByRef db As DAO.Database, ByVal lID As Long, ByVal lCislo As Long) As String
    Dim strChyba As String
    On Error GoTo Chyba
    strChyba = ChybaZmenyRezimu(db, lID)
    If Len(strChyba) > 0 Then
        OdstranUpravuPrerusenia = strChyba
        Exit Function
    End If
    db.Execute "DELETE FROM " & TBL_PRERUSENIA & " WHERE RezimID = " & lID & " AND CisloPreruseni = " & lCislo & ";", dbFailOnError
    mod_08_UdalostiDna.ObnovParametre
    Exit Function
Chyba:
    OdstranUpravuPrerusenia = "Úpravu prerušenia sa nepodarilo odstrániť: " & Err.Description
End Function

'===============================================================================
' OBDOBIA REŽIMU ZAMESTNANCA
'===============================================================================

'-------------------------------------------------------------------------------
' Prvý uzavretý mesiac zamestnanca, ktorý používa obdobie režimu (text "OC mesiac/rok"), alebo "".
'-------------------------------------------------------------------------------
Public Function DotknutyUzavrety(ByRef db As DAO.Database, ByVal lRezimID As Long) As String
    Dim rs As DAO.Recordset, d As Date, dKon As Date, strOC As String
    On Error GoTo Chyba
    If Not mod_18_Uzavierka.ExistujeUzavrety() Then Exit Function
    Set rs = db.OpenRecordset("SELECT OsobneCislo, PlatiOd, PlatiDo FROM " & TBL_OBDOBIA & " WHERE RezimID = " & lRezimID & ";", dbOpenSnapshot)
    Do While Not rs.EOF
        strOC = CStr(rs!OsobneCislo)
        d = DateSerial(Year(rs!PlatiOd), Month(rs!PlatiOd), 1)
        dKon = CDate(rs!PlatiDo)
        Do While d <= dKon
            If mod_18_Uzavierka.JeUzavrety(strOC, Year(d), Month(d)) Then
                DotknutyUzavrety = strOC & " " & Month(d) & "/" & Year(d)
                rs.Close
                Exit Function
            End If
            d = DateAdd("m", 1, d)
        Loop
        rs.MoveNext
    Loop
    rs.Close
    Exit Function
Chyba:
    DotknutyUzavrety = ""
End Function

'-------------------------------------------------------------------------------
' Je niektorý mesiac od dOd po dDo uzavretý pre zamestnanca? Vráti text "mesiac/rok" prvého, alebo "".
'-------------------------------------------------------------------------------
Private Function PrvyUzavretyMesiac(ByVal strOC As String, ByVal dOd As Date, ByVal dDo As Date) As String
    Dim d As Date
    If Not mod_18_Uzavierka.ExistujeUzavrety() Then Exit Function
    d = DateSerial(Year(dOd), Month(dOd), 1)
    Do While d <= dDo
        If mod_18_Uzavierka.JeUzavrety(strOC, Year(d), Month(d)) Then
            PrvyUzavretyMesiac = Month(d) & "/" & Year(d)
            Exit Function
        End If
        d = DateAdd("m", 1, d)
    Loop
End Function

'-------------------------------------------------------------------------------
' Pridá obdobie režimu zamestnancovi, alebo (lIDObdobia > 0) zmení existujúce. Vráti text chyby alebo "".
' Kontroly: zamestnanec a režim existujú, režim je použiteľný, od <= do, obdobia jedného zamestnanca sa neprekrývajú,
' žiaden dotknutý mesiac nie je uzavretý (ani pôvodného obdobia pri zmene).
'-------------------------------------------------------------------------------
Public Function UlozObdobie(ByRef db As DAO.Database, ByVal strOC As String, ByVal lRezimID As Long, ByVal dOd As Date, ByVal dDo As Date, _
                            Optional ByVal lIDObdobia As Long = 0) As String
    Dim rs As DAO.Recordset, strChyba As String, strM As String
    On Error GoTo Chyba
    strOC = Trim$(strOC)
    dOd = Int(dOd)
    dDo = Int(dDo)
    If Len(strOC) < 1 Or Len(strOC) > 20 Then
        UlozObdobie = "Osobné číslo musí mať 1 až 20 znakov."
        Exit Function
    End If
    If mod_00_Common.TabulkaExistujeDB(db, "Zamestnanci") Then
        Set rs = db.OpenRecordset("SELECT OsobneCislo FROM Zamestnanci WHERE OsobneCislo = " & mod_00_Common.SqlText(strOC) & ";", dbOpenSnapshot)
        If rs.EOF Then
            rs.Close
            UlozObdobie = "Zamestnanec " & strOC & " neexistuje."
            Exit Function
        End If
        rs.Close
    End If
    strChyba = ChybaRezimu(db, lRezimID)
    If Len(strChyba) > 0 Then
        UlozObdobie = "Režim č. " & lRezimID & " sa nedá priradiť: " & strChyba
        Exit Function
    End If
    If dDo < dOd Then
        UlozObdobie = "Obdobie musí končiť v deň začiatku alebo po ňom."
        Exit Function
    End If
    Set rs = db.OpenRecordset("SELECT ID, RezimID, PlatiOd, PlatiDo FROM " & TBL_OBDOBIA & " WHERE OsobneCislo = " & mod_00_Common.SqlText(strOC) & _
                              " AND PlatiOd <= " & mod_00_Common.SqlDatum(dDo) & " AND PlatiDo >= " & mod_00_Common.SqlDatum(dOd) & _
                              " AND ID <> " & lIDObdobia & ";", dbOpenSnapshot)
    If Not rs.EOF Then
        UlozObdobie = "Obdobie sa prekrýva s iným obdobím zamestnanca (režim " & rs!RezimID & ", " & Format$(rs!PlatiOd, "d.m.yyyy") & " až " & Format$(rs!PlatiDo, "d.m.yyyy") & ")."
        rs.Close
        Exit Function
    End If
    rs.Close
    strM = PrvyUzavretyMesiac(strOC, dOd, dDo)
    If Len(strM) = 0 And lIDObdobia > 0 Then
        Set rs = db.OpenRecordset("SELECT OsobneCislo, PlatiOd, PlatiDo FROM " & TBL_OBDOBIA & " WHERE ID = " & lIDObdobia & ";", dbOpenSnapshot)
        If rs.EOF Then
            rs.Close
            UlozObdobie = "Obdobie č. " & lIDObdobia & " neexistuje."
            Exit Function
        End If
        If CStr(rs!OsobneCislo) <> strOC Then
            rs.Close
            UlozObdobie = "Obdobie patrí inému zamestnancovi, nemožno ho presunúť."
            Exit Function
        End If
        strM = PrvyUzavretyMesiac(strOC, CDate(rs!PlatiOd), CDate(rs!PlatiDo))
        rs.Close
    End If
    If Len(strM) > 0 Then
        UlozObdobie = mod_18_Uzavierka.TextBlokovanejZmeny(strOC & " " & strM)
        Exit Function
    End If
    If lIDObdobia > 0 Then
        Set rs = db.OpenRecordset("SELECT * FROM " & TBL_OBDOBIA & " WHERE ID = " & lIDObdobia & ";", dbOpenDynaset)
        rs.Edit
    Else
        Set rs = db.OpenRecordset("SELECT * FROM " & TBL_OBDOBIA & " WHERE ID = 0;", dbOpenDynaset)
        rs.AddNew
        rs!OsobneCislo = strOC
    End If
    rs!RezimID = lRezimID
    rs!PlatiOd = dOd
    rs!PlatiDo = dDo
    rs.Update
    rs.Close
    Exit Function
Chyba:
    UlozObdobie = "Obdobie sa nepodarilo uložiť: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_21_RezimyVypoctu.UlozObdobie", "ERROR", Err.Description)
End Function

Public Function OdstranObdobie(ByRef db As DAO.Database, ByVal lIDObdobia As Long) As String
    Dim rs As DAO.Recordset, strM As String, strOC As String
    On Error GoTo Chyba
    Set rs = db.OpenRecordset("SELECT OsobneCislo, PlatiOd, PlatiDo FROM " & TBL_OBDOBIA & " WHERE ID = " & lIDObdobia & ";", dbOpenSnapshot)
    If rs.EOF Then
        rs.Close
        OdstranObdobie = "Obdobie č. " & lIDObdobia & " neexistuje."
        Exit Function
    End If
    strOC = CStr(rs!OsobneCislo)
    strM = PrvyUzavretyMesiac(strOC, CDate(rs!PlatiOd), CDate(rs!PlatiDo))
    rs.Close
    If Len(strM) > 0 Then
        OdstranObdobie = mod_18_Uzavierka.TextBlokovanejZmeny(strOC & " " & strM)
        Exit Function
    End If
    db.Execute "DELETE FROM " & TBL_OBDOBIA & " WHERE ID = " & lIDObdobia & ";", dbFailOnError
    Exit Function
Chyba:
    OdstranObdobie = "Obdobie sa nepodarilo odstrániť: " & Err.Description
End Function

'-------------------------------------------------------------------------------
' Číslo režimu, ktorý platí zamestnancovi v daný deň (0 = bez režimu, aj keď tabuľka ešte neexistuje).
'-------------------------------------------------------------------------------
Public Function RezimNaDen(ByRef db As DAO.Database, ByVal strOC As String, ByVal dDen As Date) As Long
    Dim rs As DAO.Recordset
    On Error GoTo Chyba
    If Not mod_00_Common.TabulkaExistujeDB(db, TBL_OBDOBIA) Then Exit Function
    dDen = Int(dDen)
    Set rs = db.OpenRecordset("SELECT RezimID FROM " & TBL_OBDOBIA & " WHERE OsobneCislo = " & mod_00_Common.SqlText(strOC) & _
                              " AND PlatiOd <= " & mod_00_Common.SqlDatum(dDen) & " AND PlatiDo >= " & mod_00_Common.SqlDatum(dDen) & ";", dbOpenSnapshot)
    If Not rs.EOF Then RezimNaDen = CLng(Nz(rs!RezimID, 0))
    rs.Close
    Exit Function
Chyba:
    RezimNaDen = 0
End Function

'-------------------------------------------------------------------------------
' Číslo režimu pre každý deň mesiaca zamestnanca: lId(1 až 31), 0 = bez režimu. Pole sa vždy vytvorí (aj pri chybe alebo bez tabuľky).
'-------------------------------------------------------------------------------
Public Sub RezimyMesiaca(ByRef db As DAO.Database, ByVal strOC As String, ByVal iRok As Long, ByVal iMes As Long, ByRef lId() As Long)
    Dim rs As DAO.Recordset, d1 As Date, d2 As Date, a As Date, b As Date, i As Long
    ReDim lId(1 To 31)
    On Error GoTo Chyba
    If Not mod_00_Common.TabulkaExistujeDB(db, TBL_OBDOBIA) Then Exit Sub
    d1 = DateSerial(iRok, iMes, 1)
    d2 = DateSerial(iRok, iMes + 1, 0)
    Set rs = db.OpenRecordset("SELECT RezimID, PlatiOd, PlatiDo FROM " & TBL_OBDOBIA & " WHERE OsobneCislo = " & mod_00_Common.SqlText(strOC) & _
                              " AND PlatiOd <= " & mod_00_Common.SqlDatum(d2) & " AND PlatiDo >= " & mod_00_Common.SqlDatum(d1) & " ORDER BY PlatiOd;", dbOpenSnapshot)
    Do While Not rs.EOF
        a = CDate(rs!PlatiOd)
        If a < d1 Then a = d1
        b = CDate(rs!PlatiDo)
        If b > d2 Then b = d2
        For i = Day(a) To Day(b)
            lId(i) = CLng(Nz(rs!RezimID, 0))
        Next i
        rs.MoveNext
    Loop
    rs.Close
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_21_RezimyVypoctu.RezimyMesiaca", "ERROR", Err.Description, "OC=" & strOC & " " & iMes & "/" & iRok)
End Sub
