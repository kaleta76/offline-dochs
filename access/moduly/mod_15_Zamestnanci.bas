Attribute VB_Name = "mod_15_Zamestnanci"
'@Verzia 1.1.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_15_Zamestnanci
' POPIS: Dáta a logika ručnej správy zamestnancov:
'        - doplnenie dátového modelu (vyradenie, úväzok, text na displeji, poznámka; rozšírenie fondov a pravidiel prerušení),
'        - osobné nastavenia zamestnanca: pracovný fond, šablóna prerušení, kalendár (tabuľka ZamestnanciFondy,
'          platné od zvoleného mesiaca - rovnako ako v pôvodnej aplikácii Ordata),
'        - úväzok v % (denný fond zamestnanca = denný fond x úväzok),
'        - vyradenie zamestnanca zo zoznamov, výpočtov a zostáv (Vyradeny, VyradenyOd),
'        - hromadné priradenie nastavení vybraným zamestnancom a vytvorenie novej skupiny
'          (vlastná kópia pracovného fondu a šablóny pravidiel prerušení).
'   Skupina = zamestnanci, ktorí majú rovnaký fond a rovnakú šablónu prerušení; zvláštna tabuľka skupín sa nevedie.
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - ZabezpecModel(db)                     : Doplní stĺpce potrebné pre zamestnancov, fondy a pravidlá prerušení.
' - SqlNeaktivny / SqlAktivny             : SQL podmienka (ne)aktívneho zamestnanca pre obdobie.
' - SqlVynechVyradenych(pole, dOd)        : " AND pole NOT IN (vyradení zamestnanci)" alebo "".
' - UvazokZamestnanca(db, OC, rok, mes) : Úväzok v % platný pre mesiac (predvolene 100).
' - PlatnePriradenie(...)                 : Fond, šablóna prerušení a kalendár platné pre mesiac.
' - UlozPriradenie(...)                   : Zapíše priradenie platné od mesiaca.
' - UlozZamestnanca(d, bNovy)             : Uloží základné údaje zamestnanca (vráti text chyby alebo "").
' - NastavVyradenie(zoznamOC, bVyradit, d): Vyradí / vráti zamestnancov.
' - HromadnePriradenie(...)               : Priradí nastavenia viacerým zamestnancom (voliteľne s novou skupinou).
' - KopiaFondu / KopiaSablony             : Vytvorí kópiu pracovného fondu / šablóny pravidiel prerušení.
' - Zam_FondText / Zam_PrerText / Zam_UvazokText : Texty pre zoznam zamestnancov (volané z SQL dopytu).
' - Zam_ZrusCache()                       : Vymaže vyrovnávaciu pamäť textov (pred obnovením zoznamu).
' - Zam_NastavMesiac(rok, mesiac)         : Mesiac, pre ktorý zoznam ukazuje fond a šablónu (0, 0 = aktuálny mesiac).
' - KopirujRiadky(...)                    : Skopíruje riadky tabuľky podľa podmienky (s náhradou vybraných polí).
' - ZoznamFondovVL / ZoznamSablonVL / ZoznamKalendarovVL : Zoznamy hodnôt pre rozbaľovacie polia.
' - NazovFondu / NazovSablony / NazovKalendara : Názvy podľa čísla.
'===============================================================================

Private mCache As Object          ' osobné číslo -> pole (fond, šablóna, kalendár, od)
Private mNazvy As Object          ' kľúč -> názov
Private mRok As Integer           ' mesiac, pre ktorý zoznam zamestnancov ukazuje fond a šablónu (0 = aktuálny)
Private mMes As Integer

'-------------------------------------------------------------------------------
' Pomocná DDL funkcia: pridá stĺpec, ak chýba.
'-------------------------------------------------------------------------------
Private Sub PridajStlpec(ByRef db As DAO.Database, ByVal strTab As String, ByVal strPole As String, ByVal strTyp As String)
    On Error GoTo Chyba
    If Not mod_00_Common.PoleExistujeDB(db, strTab, strPole) Then
        db.Execute "ALTER TABLE [" & strTab & "] ADD COLUMN " & strPole & " " & strTyp, dbFailOnError
    End If
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_15_Zamestnanci.ZabezpecModel", "ERROR", "Nepodarilo sa pridať stĺpec " & strTab & "." & strPole & ": " & Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Doplní stĺpce dátového modelu (opakovateľné, bez straty dát).
'-------------------------------------------------------------------------------
Public Sub ZabezpecModel(ByRef db As DAO.Database)
    On Error GoTo Chyba
    If mod_00_Common.TabulkaExistujeDB(db, "Zamestnanci") Then
        Call PridajStlpec(db, "Zamestnanci", "Vyradeny", "YESNO")
        Call PridajStlpec(db, "Zamestnanci", "VyradenyOd", "DATETIME")
        Call PridajStlpec(db, "Zamestnanci", "UvazokPercent", "LONG")
        Call PridajStlpec(db, "Zamestnanci", "TextDisplej", "TEXT(50)")
        Call PridajStlpec(db, "Zamestnanci", "Poznamka", "TEXT(255)")
    End If
    If mod_00_Common.TabulkaExistujeDB(db, "PracovneFondy") Then
        Call PridajStlpec(db, "PracovneFondy", "FondPodlaDna", "YESNO")
    End If
    If mod_00_Common.TabulkaExistujeDB(db, "ZamestnanciFondy") Then
        If Not mod_00_Common.PoleExistujeDB(db, "ZamestnanciFondy", "UvazokPercent") Then
            Call PridajStlpec(db, "ZamestnanciFondy", "UvazokPercent", "LONG")
            db.TableDefs.Refresh
            ' doterajší úväzok zamestnanca sa zapíše do všetkých jeho priradení (úväzok je odteraz platný od mesiaca)
            On Error Resume Next
            db.Execute "UPDATE ZamestnanciFondy INNER JOIN Zamestnanci ON ZamestnanciFondy.OsobneCislo = Zamestnanci.OsobneCislo " & _
                       "SET ZamestnanciFondy.UvazokPercent = Zamestnanci.UvazokPercent WHERE Zamestnanci.UvazokPercent Is Not Null;", dbFailOnError
            If Err.Number <> 0 Then Call mod_00_Common.ZapisLog("mod_15_Zamestnanci.ZabezpecModel", "WARN", "Prenos úväzku do priradení sa nepodaril: " & Err.Description)
            Err.Clear
            On Error GoTo Chyba
        End If
    End If
    If mod_00_Common.TabulkaExistujeDB(db, "ParametrePreruseni") Then
        Call PridajStlpec(db, "ParametrePreruseni", "MinOdpracovaneMin", "LONG")
        Call PridajStlpec(db, "ParametrePreruseni", "MinTrvanieMin", "LONG")
        Call PridajStlpec(db, "ParametrePreruseni", "PravidloVypnute", "YESNO")
    End If
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_15_Zamestnanci.ZabezpecModel", "ERROR", Err.Description)
End Sub

'===============================================================================
' VYRADENÍ ZAMESTNANCI (SQL podmienky)
'===============================================================================

'-------------------------------------------------------------------------------
' Podmienka "zamestnanec je v období, ktoré začína dňom dOd, už vyradený".
'-------------------------------------------------------------------------------
Public Function SqlNeaktivny(ByVal strAlias As String, ByVal dObdobiaOd As Date) As String
    Dim p As String
    If Len(strAlias) > 0 Then p = strAlias & "."
    SqlNeaktivny = "(Nz(" & p & "Vyradeny, False) = True AND (" & p & "VyradenyOd Is Null OR " & p & "VyradenyOd <= " & _
                   mod_00_Common.SqlDatum(dObdobiaOd) & "))"
End Function

'-------------------------------------------------------------------------------
' Opak podmienky; ak stĺpec Vyradeny ešte neexistuje, vráti vždy pravdivú podmienku.
'-------------------------------------------------------------------------------
Public Function SqlAktivny(ByVal strAlias As String, ByVal dObdobiaOd As Date) As String
    On Error Resume Next
    SqlAktivny = "(1 = 1)"
    If mod_00_Common.PoleExistujeDB(CurrentDb, "Zamestnanci", "Vyradeny") Then
        SqlAktivny = "(Not " & SqlNeaktivny(strAlias, dObdobiaOd) & ")"
    End If
End Function

'-------------------------------------------------------------------------------
' " AND pole NOT IN (SELECT ... vyradení ...)" na doplnenie do WHERE (zostavy, analýza). Bez stĺpca vráti "".
'-------------------------------------------------------------------------------
Public Function SqlVynechVyradenych(ByVal strPoleOC As String, ByVal dObdobiaOd As Date) As String
    On Error Resume Next
    If mod_00_Common.PoleExistujeDB(CurrentDb, "Zamestnanci", "Vyradeny") Then
        SqlVynechVyradenych = " AND " & strPoleOC & " NOT IN (SELECT Z2.OsobneCislo FROM Zamestnanci AS Z2 WHERE " & _
                              SqlNeaktivny("Z2", dObdobiaOd) & " AND Z2.OsobneCislo Is Not Null)"
    End If
End Function

'===============================================================================
' ÚVÄZOK A PRIRADENIE FONDU
'===============================================================================

'-------------------------------------------------------------------------------
' Úväzok zamestnanca v % (1 až 200). Ak je zadaný mesiac, vráti úväzok z priradenia platného pre tento mesiac
' (úväzok je platný od mesiaca ako fond a pravidlá); bez neho alebo bez údaja v priradení úväzok zo záznamu
' zamestnanca; bez údaja 100.
'-------------------------------------------------------------------------------
Public Function UvazokZamestnanca(ByRef db As DAO.Database, ByVal strOC As String, Optional ByVal iRok As Integer = 0, Optional ByVal iMes As Integer = 0) As Long
    Dim v As Variant, iOdR As Integer, iOdM As Integer, f As Long, p As Long, k As Long, y As Long, u As Long
    UvazokZamestnanca = 100
    On Error Resume Next
    If iRok > 0 And iMes > 0 Then
        Call PlatnePriradenie(strOC, iRok, iMes, iOdR, iOdM, f, p, k, y, u)
        If u >= 1 And u <= 200 Then
            UvazokZamestnanca = u
            Exit Function
        End If
    End If
    If Not mod_00_Common.PoleExistujeDB(db, "Zamestnanci", "UvazokPercent") Then Exit Function
    v = DLookup("UvazokPercent", "Zamestnanci", "OsobneCislo = " & mod_00_Common.SqlText(strOC))
    If Not IsNull(v) Then
        If CLng(v) >= 1 And CLng(v) <= 200 Then UvazokZamestnanca = CLng(v)
    End If
End Function

'-------------------------------------------------------------------------------
' Priradenie platné pre mesiac (posledné s platnosťou od mesiaca <= iMes; inak najstaršie).
' Vráti True, ak zamestnanec má vlastné priradenie. Bez priradenia sú všetky kódy 1.
'-------------------------------------------------------------------------------
Public Function PlatnePriradenie(ByVal strOC As String, ByVal iRok As Integer, ByVal iMes As Integer, _
                                 ByRef iOdRok As Integer, ByRef iOdMes As Integer, ByRef lFond As Long, _
                                 ByRef lPrer As Long, ByRef lKal As Long, ByRef lVyp As Long, Optional ByRef lUv As Long = 0) As Boolean
    On Error GoTo Chyba
    Dim rs As DAO.Recordset, db As DAO.Database, strSQL As String, strKrit As String
    lFond = 1: lPrer = 1: lKal = 1: lVyp = 1: lUv = 0
    iOdRok = 0: iOdMes = 0
    Set db = CurrentDb
    If Not mod_00_Common.TabulkaExistujeDB(db, "ZamestnanciFondy") Then Exit Function

    strKrit = "OsobneCislo = " & mod_00_Common.SqlText(strOC)
    strSQL = "SELECT TOP 1 * FROM ZamestnanciFondy WHERE " & strKrit & " AND (Rok * 12 + Mesiac) <= " & (CLng(iRok) * 12 + iMes) & _
             " ORDER BY (Rok * 12 + Mesiac) DESC;"
    Set rs = db.OpenRecordset(strSQL, dbOpenSnapshot)
    If rs.EOF Then
        rs.Close
        strSQL = "SELECT TOP 1 * FROM ZamestnanciFondy WHERE " & strKrit & " ORDER BY (Rok * 12 + Mesiac);"
        Set rs = db.OpenRecordset(strSQL, dbOpenSnapshot)
    End If
    If Not rs.EOF Then
        lFond = CLng(Val(Nz(rs!PracFondKod, 1)))
        lPrer = CLng(Val(Nz(rs!ParPrerKod, 1)))
        lKal = CLng(Val(Nz(rs!KalendarKod, 1)))
        lVyp = CLng(Val(Nz(rs!ParDochKod, 1)))
        On Error Resume Next
        lUv = CLng(Val(Nz(rs.Fields("UvazokPercent").Value, 0)))
        Err.Clear
        On Error GoTo Chyba
        iOdRok = CInt(Val(Nz(rs!Rok, 0)))
        iOdMes = CInt(Val(Nz(rs!Mesiac, 0)))
        If lFond <= 0 Then lFond = 1
        If lPrer <= 0 Then lPrer = 1
        If lKal <= 0 Then lKal = 1
        If lVyp <= 0 Then lVyp = 1
        PlatnePriradenie = True
    End If
    rs.Close
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_15_Zamestnanci.PlatnePriradenie", "ERROR", Err.Description, "OC=" & strOC)
End Function

'-------------------------------------------------------------------------------
' Zamestnanec bez vlastného priradenia: prvé priradenie by sa podľa pravidla "pred prvou verziou platí najstaršia"
' uplatnilo aj na staršie mesiace. Preto sa pre mesiace pred zvoleným vytvorí základné priradenie (fond, šablóna a
' kalendár 1, doterajší úväzok) od najstaršieho mesiaca s údajmi zamestnanca.
'-------------------------------------------------------------------------------
Private Sub ZabezpecZakladnePriradenie(ByVal strOC As String, ByVal iRok As Integer, ByVal iMes As Integer)
    Dim ym0 As Long, lR As Long, lM As Long, rs As DAO.Recordset, lU As Long
    On Error GoTo Chyba
    If Nz(DCount("*", "ZamestnanciFondy", "OsobneCislo = " & mod_00_Common.SqlText(strOC)), 0) > 0 Then Exit Sub
    ym0 = mod_18_Uzavierka.NajstarsiMesiacZamestnanca(strOC)
    If ym0 = 0 Or ym0 >= CLng(iRok) * 12 + iMes Then Exit Sub
    lR = (ym0 - 1) \ 12
    lM = ym0 - lR * 12
    lU = UvazokZamestnanca(CurrentDb, strOC)
    Set rs = CurrentDb.OpenRecordset("SELECT * FROM ZamestnanciFondy WHERE 1 = 0;", dbOpenDynaset)
    rs.AddNew
    rs!OsobneCislo = strOC
    rs!Rok = lR
    rs!Mesiac = lM
    rs!PracFondKod = 1
    rs!ParPrerKod = 1
    rs!KalendarKod = 1
    rs!ParDochKod = 1
    On Error Resume Next
    rs.Fields("UvazokPercent").Value = lU
    Err.Clear
    On Error GoTo Chyba
    rs.Update
    rs.Close
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_15_Zamestnanci.ZabezpecZakladnePriradenie", "ERROR", Err.Description, "OC=" & strOC)
End Sub

'-------------------------------------------------------------------------------
' Zapíše priradenie platné od mesiaca iMes/iRok (lUvazok > 0 = aj úväzok od tohto mesiaca; 0 = ponechá platný).
' Uzavretý (podpísaný) mesiac sa týmto nezmení - ak by ho zmena zasiahla, nezapíše sa nič. Vráti text chyby alebo "".
'-------------------------------------------------------------------------------
Public Function UlozPriradenie(ByVal strOC As String, ByVal iRok As Integer, ByVal iMes As Integer, _
                               ByVal lFond As Long, ByVal lPrer As Long, ByVal lKal As Long, ByVal lVyp As Long, _
                               Optional ByVal lUvazok As Long = 0) As String
    On Error GoTo Chyba
    Dim rs As DAO.Recordset, strZ As String, bNovy As Boolean, lU As Long, ym0 As Long
    If iRok < 1990 Or iRok > 2100 Or iMes < 1 Or iMes > 12 Then
        UlozPriradenie = "Neplatný mesiac platnosti nastavení."
        Exit Function
    End If
    If lFond <= 0 Or lPrer <= 0 Or lKal <= 0 Then
        UlozPriradenie = "Vyberte pracovný fond, šablónu prerušení aj kalendár."
        Exit Function
    End If
    If lUvazok < 0 Or lUvazok > 200 Then
        UlozPriradenie = "Úväzok zadajte v percentách (1 až 200), napr. 100 alebo 50."
        Exit Function
    End If
    If lVyp <= 0 Then lVyp = 1

    ' ochrana uzavretých mesiacov
    ym0 = mod_18_Uzavierka.NajstarsiMesiacZamestnanca(strOC)
    strZ = mod_18_Uzavierka.DotknutyZamestnanec(strOC, iRok, iMes, (ym0 > 0 And ym0 < CLng(iRok) * 12 + iMes))
    If Len(strZ) > 0 Then
        UlozPriradenie = mod_18_Uzavierka.TextBlokovanejZmeny(strZ)
        Exit Function
    End If
    Call ZabezpecZakladnePriradenie(strOC, iRok, iMes)

    lU = lUvazok
    If lU <= 0 Then lU = UvazokZamestnanca(CurrentDb, strOC, iRok, iMes)
    Set rs = CurrentDb.OpenRecordset("SELECT * FROM ZamestnanciFondy WHERE OsobneCislo = " & mod_00_Common.SqlText(strOC) & _
                                     " AND Rok = " & iRok & " AND Mesiac = " & iMes & ";", dbOpenDynaset)
    If rs.EOF Then
        bNovy = True
        rs.AddNew
        rs!OsobneCislo = strOC
        rs!Rok = iRok
        rs!Mesiac = iMes
    Else
        rs.Edit
    End If
    rs!PracFondKod = lFond
    rs!ParPrerKod = lPrer
    rs!KalendarKod = lKal
    rs!ParDochKod = lVyp
    On Error Resume Next
    rs.Fields("UvazokPercent").Value = lU
    Err.Clear
    On Error GoTo Chyba
    rs.Update
    rs.Close
    Call Zam_ZrusCache
    Call mod_18_Uzavierka.OznacNastaveniaLokalne
    Exit Function
Chyba:
    UlozPriradenie = "Priradenie sa nepodarilo uložiť: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_15_Zamestnanci.UlozPriradenie", "ERROR", Err.Description, "OC=" & strOC)
End Function

'===============================================================================
' ZÁKLADNÉ ÚDAJE ZAMESTNANCA
'===============================================================================

Private Function Skrat(ByVal v As Variant, ByVal lMax As Long) As Variant
    Dim s As String
    s = Trim$(CStr(Nz(v, "")))
    If Len(s) = 0 Then
        Skrat = Null
    Else
        Skrat = Left$(s, lMax)
    End If
End Function

Private Sub NP(ByRef rs As DAO.Recordset, ByVal strPole As String, ByVal v As Variant)
    On Error Resume Next
    rs.Fields(strPole).Value = v
End Sub

'-------------------------------------------------------------------------------
' Zistí, či zmena vyradenia alebo úväzku (porovnanie otvoreného záznamu rs s hodnotami v slovníku d) zasiahne uzavretý mesiac.
' Vráti opis prvého zasiahnutého mesiaca alebo "".
'-------------------------------------------------------------------------------
Private Function ZmenaDotykaUzavretehoMesiaca(ByRef rs As DAO.Recordset, ByVal d As Object, ByVal lNovyUvazok As Long) As String
    Dim bOld As Boolean, bNew As Boolean, dOld As Date, dNew As Date, dZm As Date, bMaDatum As Boolean, lOld As Long, strOC As String
    On Error GoTo Chyba
    If Not mod_18_Uzavierka.ExistujeUzavrety() Then Exit Function
    strOC = Trim$(CStr(Nz(d("OC"), "")))
    bOld = CBool(Nz(rs.Fields("Vyradeny").Value, False))
    If bOld Then
        If IsNull(rs.Fields("VyradenyOd").Value) Then dOld = DateSerial(1900, 1, 1) Else dOld = CDate(rs.Fields("VyradenyOd").Value)
    End If
    bNew = CBool(d("Vyradeny"))
    If bNew Then
        If IsDate(d("VyradenyOd")) Then dNew = CDate(d("VyradenyOd")) Else dNew = DateSerial(1900, 1, 1)
    End If
    If bOld <> bNew Or (bOld And bNew And dOld <> dNew) Then
        If bOld Then dZm = dOld: bMaDatum = True
        If bNew Then
            If Not bMaDatum Or dNew < dZm Then dZm = dNew
            bMaDatum = True
        End If
        If bMaDatum Then ZmenaDotykaUzavretehoMesiaca = mod_18_Uzavierka.DotknutyVyradenim(strOC, dZm)
        If Len(ZmenaDotykaUzavretehoMesiaca) > 0 Then Exit Function
    End If
    ' úväzok zo záznamu zamestnanca platí pre mesiace bez vlastného priradenia - zmena by ich zmenila spätne
    lOld = 100
    If Not IsNull(rs.Fields("UvazokPercent").Value) Then lOld = CLng(rs.Fields("UvazokPercent").Value)
    If lOld <> lNovyUvazok Then
        If Nz(DCount("*", "ZamestnanciFondy", "OsobneCislo = " & mod_00_Common.SqlText(strOC)), 0) = 0 Then
            ZmenaDotykaUzavretehoMesiaca = mod_18_Uzavierka.DotknutyZamestnanec(strOC, 1990, 1)
        End If
    End If
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_15_Zamestnanci.ZmenaDotykaUzavretehoMesiaca", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Uloží údaje zamestnanca zo slovníka d (kľúče: OC, Titul, Meno, Priezvisko, Karta, Org, Stred, Displej,
' Blok, Vyradeny, VyradenyOd, Uvazok, Poznamka). Vráti text chyby alebo "".
'-------------------------------------------------------------------------------
Public Function UlozZamestnanca(ByVal d As Object, ByVal bNovy As Boolean) As String
    On Error GoTo Chyba
    Dim rs As DAO.Recordset, strOC As String, lU As Long, strMeno As String, strPr As String, strZ As String

    strOC = Trim$(CStr(Nz(d("OC"), "")))
    If Len(strOC) = 0 Then UlozZamestnanca = "Zadajte osobné číslo.": Exit Function
    If Len(strOC) > 20 Then UlozZamestnanca = "Osobné číslo môže mať najviac 20 znakov.": Exit Function
    lU = CLng(Val(Nz(d("Uvazok"), 100)))
    If lU < 1 Or lU > 200 Then UlozZamestnanca = "Úväzok zadajte v percentách (1 až 200), napr. 100 alebo 50.": Exit Function
    If CBool(d("Vyradeny")) Then
        If Not IsDate(d("VyradenyOd")) Then UlozZamestnanca = "Pri vyradení zadajte dátum, od ktorého je zamestnanec vyradený.": Exit Function
    End If

    Set rs = CurrentDb.OpenRecordset("SELECT * FROM Zamestnanci WHERE OsobneCislo = " & mod_00_Common.SqlText(strOC) & ";", dbOpenDynaset)
    If bNovy Then
        If Not rs.EOF Then
            rs.Close
            UlozZamestnanca = "Zamestnanec s osobným číslom " & strOC & " už existuje."
            Exit Function
        End If
        rs.AddNew
        rs!OsobneCislo = strOC
        Call NP(rs, "ZdrojZaznamu", "RUCNE")
        Call NP(rs, "DatumImportu", Now)
        Call NP(rs, "ADAktivny", False)
    Else
        If rs.EOF Then
            rs.Close
            UlozZamestnanca = "Zamestnanec " & strOC & " sa nenašiel."
            Exit Function
        End If
        strZ = ZmenaDotykaUzavretehoMesiaca(rs, d, lU)
        If Len(strZ) > 0 Then
            rs.Close
            UlozZamestnanca = mod_18_Uzavierka.TextBlokovanejZmeny(strZ)
            Exit Function
        End If
        rs.Edit
    End If

    strMeno = Trim$(CStr(Nz(d("Meno"), "")))
    strPr = Trim$(CStr(Nz(d("Priezvisko"), "")))
    Call NP(rs, "Titul", Skrat(d("Titul"), 20))
    Call NP(rs, "Meno", Skrat(strMeno, 50))
    Call NP(rs, "Priezvisko", Skrat(strPr, 50))
    Call NP(rs, "CeleMeno", Skrat(strMeno & " " & strPr, 150))
    Call NP(rs, "CisloKarty", CLng(Val(Nz(d("Karta"), 0))))
    Call NP(rs, "Organizacia", Skrat(d("Org"), 100))
    Call NP(rs, "StrediskoNazov", Skrat(d("Stred"), 50))
    Call NP(rs, "TextDisplej", Skrat(d("Displej"), 50))
    Call NP(rs, "BlokovanyStary", CBool(d("Blok")))
    Call NP(rs, "Vyradeny", CBool(d("Vyradeny")))
    If CBool(d("Vyradeny")) Then
        Call NP(rs, "VyradenyOd", CDate(d("VyradenyOd")))
    Else
        Call NP(rs, "VyradenyOd", Null)
    End If
    Call NP(rs, "UvazokPercent", lU)
    Call NP(rs, "Poznamka", Skrat(d("Poznamka"), 255))
    rs.Update
    rs.Close
    Call Zam_ZrusCache
    Exit Function
Chyba:
    UlozZamestnanca = "Zamestnanca sa nepodarilo uložiť: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_15_Zamestnanci.UlozZamestnanca", "ERROR", Err.Description, "OC=" & strOC)
End Function

'-------------------------------------------------------------------------------
' Vyradí (alebo vráti) zamestnancov zo zoznamu v SQL tvare 'a','b'. Vráti počet zmenených riadkov (-1 chyba, -2 zablokované uzavretým mesiacom - hlásenie už zobrazené).
'-------------------------------------------------------------------------------
Public Function NastavVyradenie(ByVal strOcSql As String, ByVal bVyradit As Boolean, ByVal dOd As Date) As Long
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset, strZ As String
    If Len(strOcSql) = 0 Then Exit Function
    Set db = CurrentDb
    If mod_18_Uzavierka.ExistujeUzavrety() Then
        Set rs = db.OpenRecordset("SELECT OsobneCislo, Vyradeny, VyradenyOd FROM Zamestnanci WHERE OsobneCislo IN (" & strOcSql & ");", dbOpenSnapshot)
        Do While Not rs.EOF
            strZ = ""
            If bVyradit Then
                strZ = mod_18_Uzavierka.DotknutyVyradenim(CStr(rs!OsobneCislo), dOd)
            ElseIf CBool(Nz(rs!Vyradeny, False)) Then
                ' vrátenie zasiahne mesiace od pôvodného dátumu vyradenia
                If IsNull(rs!VyradenyOd) Then
                    strZ = mod_18_Uzavierka.DotknutyVyradenim(CStr(rs!OsobneCislo), DateSerial(1900, 1, 1))
                Else
                    strZ = mod_18_Uzavierka.DotknutyVyradenim(CStr(rs!OsobneCislo), CDate(rs!VyradenyOd))
                End If
            End If
            If Len(strZ) > 0 Then
                rs.Close
                MsgBox mod_18_Uzavierka.TextBlokovanejZmeny(strZ), vbExclamation, "Uzavretý mesiac"
                NastavVyradenie = -2
                Exit Function
            End If
            rs.MoveNext
        Loop
        rs.Close
    End If
    If bVyradit Then
        db.Execute "UPDATE Zamestnanci SET Vyradeny = True, VyradenyOd = " & mod_00_Common.SqlDatum(dOd) & _
                   " WHERE OsobneCislo IN (" & strOcSql & ");", dbFailOnError
    Else
        db.Execute "UPDATE Zamestnanci SET Vyradeny = False, VyradenyOd = Null WHERE OsobneCislo IN (" & strOcSql & ");", dbFailOnError
    End If
    NastavVyradenie = db.RecordsAffected
    Call Zam_ZrusCache
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_15_Zamestnanci.NastavVyradenie", "ERROR", Err.Description)
    NastavVyradenie = -1
End Function

'===============================================================================
' KÓPIE FONDOV A ŠABLÓN, HROMADNÉ PRIRADENIE
'===============================================================================

Public Function NasledneCislo(ByVal strTab As String, ByVal strPole As String, ByVal strTab2 As String, ByVal strPole2 As String) As Long
    Dim l1 As Long, l2 As Long
    On Error Resume Next
    l1 = CLng(Nz(DMax(strPole, strTab), 0))
    l2 = CLng(Nz(DMax(strPole2, strTab2), 0))
    If l2 > l1 Then l1 = l2
    NasledneCislo = l1 + 1
End Function

'-------------------------------------------------------------------------------
' Skopíruje riadky tabuľky podľa podmienky; hodnoty polí zo slovníka dicNahrad sa použijú namiesto pôvodných.
'-------------------------------------------------------------------------------
Public Function KopirujRiadky(ByRef db As DAO.Database, ByVal strTab As String, ByVal strWhere As String, ByVal dicNahrad As Object) As Long
    Dim rsZ As DAO.Recordset, rsC As DAO.Recordset, f As DAO.Field, n As Long
    Set rsZ = db.OpenRecordset("SELECT * FROM [" & strTab & "] WHERE " & strWhere & ";", dbOpenSnapshot)
    Set rsC = db.OpenRecordset("SELECT * FROM [" & strTab & "] WHERE 1 = 0;", dbOpenDynaset)
    Do While Not rsZ.EOF
        rsC.AddNew
        For Each f In rsZ.Fields
            If (f.Attributes And dbAutoIncrField) = 0 Then
                If dicNahrad.Exists(f.Name) Then
                    rsC.Fields(f.Name).Value = dicNahrad(f.Name)
                Else
                    rsC.Fields(f.Name).Value = f.Value
                End If
            End If
        Next f
        rsC.Update
        n = n + 1
        rsZ.MoveNext
    Loop
    rsZ.Close
    rsC.Close
    KopirujRiadky = n
End Function

'-------------------------------------------------------------------------------
' Vytvorí nový pracovný fond ako kópiu fondu lZdroj (všetky platnosti). Ak zdroj neexistuje, založí fond s
' denným fondom 7:30 platný od aktuálneho mesiaca. Vráti číslo nového fondu (0 pri chybe).
'-------------------------------------------------------------------------------
Public Function KopiaFondu(ByVal lZdroj As Long, ByVal strNazov As String) As Long
    On Error GoTo Chyba
    Dim db As DAO.Database, lNove As Long, dic As Object, n As Long, rs As DAO.Recordset
    Set db = CurrentDb
    lNove = NasledneCislo("PracovneFondy", "Cislo", "ZamestnanciFondy", "PracFondKod")
    Set dic = CreateObject("Scripting.Dictionary")
    dic("Cislo") = lNove
    dic("Nazov") = Left$(strNazov, 100)
    n = KopirujRiadky(db, "PracovneFondy", "Cislo = " & lZdroj, dic)
    If n = 0 Then
        Set rs = db.OpenRecordset("SELECT * FROM PracovneFondy WHERE 1 = 0;", dbOpenDynaset)
        rs.AddNew
        rs!Cislo = lNove
        rs!Rok = Year(Date)
        rs!Mesiac = Month(Date)
        rs!Nazov = Left$(strNazov, 100)
        rs!PocetZmien = 1
        rs!TypFondu = 2
        rs!TypOpakovania = 1
        rs!PriemernaDlzkaMin = 450
        rs.Update
        rs.Close
    Else
        dic.Remove "Nazov"
        Call KopirujRiadky(db, "PracovneFondyDni", "Cislo = " & lZdroj, dic)
    End If
    Call Zam_ZrusCache
    KopiaFondu = lNove
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_15_Zamestnanci.KopiaFondu", "ERROR", Err.Description)
    KopiaFondu = 0
End Function

'-------------------------------------------------------------------------------
' Vytvorí novú šablónu pravidiel prerušení ako kópiu šablóny lZdroj (všetky platnosti). Vráti jej číslo (0 pri chybe).
'-------------------------------------------------------------------------------
Public Function KopiaSablony(ByVal lZdroj As Long, ByVal strNazov As String) As Long
    On Error GoTo Chyba
    Dim db As DAO.Database, lNove As Long, dic As Object, n As Long
    Set db = CurrentDb
    lNove = NasledneCislo("ParametrePreruseni", "Sablona", "ZamestnanciFondy", "ParPrerKod")
    Set dic = CreateObject("Scripting.Dictionary")
    dic("Sablona") = lNove
    dic("NazovSablony") = Left$(strNazov, 50)
    n = KopirujRiadky(db, "ParametrePreruseni", "Sablona = " & lZdroj, dic)
    If n = 0 Then
        Call mod_00_Common.ZapisLog("mod_15_Zamestnanci.KopiaSablony", "WARN", "Šablóna " & lZdroj & " nemá žiadne pravidlá; nová šablóna " & lNove & " je prázdna.")
    End If
    Call Zam_ZrusCache
    KopiaSablony = lNove
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_15_Zamestnanci.KopiaSablony", "ERROR", Err.Description)
    KopiaSablony = 0
End Function

'-------------------------------------------------------------------------------
' Priradí nastavenia zamestnancom z poľa vOC od mesiaca iMes/iRok. Hodnota -1 (alebo <= 0 pri úväzku) = nemeniť.
' bNovyFond / bNovaSablona = pre skupinu sa vytvorí vlastná kópia (zdroj = vybraný fond / šablóna, inak aktuálny
' fond / šablóna prvého zamestnanca). Vráti počet spracovaných zamestnancov; strVysledok = správa pre používateľa.
'-------------------------------------------------------------------------------
Public Function HromadnePriradenie(ByVal vOC As Variant, ByVal iRok As Integer, ByVal iMes As Integer, _
                                   ByVal lFond As Long, ByVal lPrer As Long, ByVal lKal As Long, ByVal lUvazok As Long, _
                                   ByVal bNovyFond As Boolean, ByVal bNovaSablona As Boolean, ByVal strSkupina As String, _
                                   ByRef strVysledok As String) As Long
    On Error GoTo Chyba
    Dim v As Variant, f As Long, p As Long, k As Long, y As Long, iOvRok As Integer, iOvMes As Integer
    Dim n As Long, strErr As String, strChyby As String, lSrc As Long, strOcSql As String, lNovyF As Long, lNovaS As Long

    strVysledok = ""
    If Not IsArray(vOC) Then strVysledok = "Neboli vybraní žiadni zamestnanci.": Exit Function
    If UBound(vOC) < LBound(vOC) Then strVysledok = "Neboli vybraní žiadni zamestnanci.": Exit Function
    If (bNovyFond Or bNovaSablona) And Len(Trim$(strSkupina)) = 0 Then
        strVysledok = "Zadajte názov skupiny."
        Exit Function
    End If

    If bNovyFond Then
        lSrc = lFond
        If lSrc <= 0 Then
            Call PlatnePriradenie(CStr(vOC(LBound(vOC))), iRok, iMes, iOvRok, iOvMes, f, p, k, y)
            lSrc = f
        End If
        lNovyF = KopiaFondu(lSrc, Trim$(strSkupina))
        If lNovyF <= 0 Then strVysledok = "Nový pracovný fond sa nepodarilo vytvoriť (pozrite protokol).": Exit Function
        lFond = lNovyF
    End If
    If bNovaSablona Then
        lSrc = lPrer
        If lSrc <= 0 Then
            Call PlatnePriradenie(CStr(vOC(LBound(vOC))), iRok, iMes, iOvRok, iOvMes, f, p, k, y)
            lSrc = p
        End If
        lNovaS = KopiaSablony(lSrc, Trim$(strSkupina))
        If lNovaS <= 0 Then strVysledok = "Novú šablónu prerušení sa nepodarilo vytvoriť (pozrite protokol).": Exit Function
        lPrer = lNovaS
    End If

    For Each v In vOC
        Call PlatnePriradenie(CStr(v), iRok, iMes, iOvRok, iOvMes, f, p, k, y)
        If lFond > 0 Then f = lFond
        If lPrer > 0 Then p = lPrer
        If lKal > 0 Then k = lKal
        strErr = UlozPriradenie(CStr(v), iRok, iMes, f, p, k, y, IIf(lUvazok > 0, lUvazok, 0))
        If Len(strErr) = 0 Then
            n = n + 1
            strOcSql = strOcSql & IIf(Len(strOcSql) > 0, ",", "") & mod_00_Common.SqlText(CStr(v))
        Else
            strChyby = strChyby & vbCrLf & CStr(v) & ": " & strErr
        End If
    Next v

    If lUvazok > 0 And Len(strOcSql) > 0 Then
        CurrentDb.Execute "UPDATE Zamestnanci SET UvazokPercent = " & lUvazok & " WHERE OsobneCislo IN (" & strOcSql & ");", dbFailOnError
    End If

    strVysledok = "Nastavenia platné od " & iMes & "/" & iRok & " boli priradené " & n & " zamestnancom."
    If lNovyF > 0 Then strVysledok = strVysledok & vbCrLf & "Nový pracovný fond č. " & lNovyF & " (" & Trim$(strSkupina) & ") - upravíte ho tlačidlom Fondy."
    If lNovaS > 0 Then strVysledok = strVysledok & vbCrLf & "Nová šablóna prerušení č. " & lNovaS & " (" & Trim$(strSkupina) & ") - pravidlá upravíte tlačidlom Pravidlá prerušení."
    If lUvazok > 0 Then strVysledok = strVysledok & vbCrLf & "Úväzok: " & lUvazok & " %."
    If Len(strChyby) > 0 Then strVysledok = strVysledok & vbCrLf & vbCrLf & "Nepodarilo sa:" & strChyby
    Call Zam_ZrusCache
    HromadnePriradenie = n
    Exit Function
Chyba:
    strVysledok = "Hromadné priradenie zlyhalo: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_15_Zamestnanci.HromadnePriradenie", "ERROR", Err.Description)
End Function

'===============================================================================
' NÁZVY A ZOZNAMY
'===============================================================================

Private Function NazvyCache() As Object
    If mNazvy Is Nothing Then Set mNazvy = CreateObject("Scripting.Dictionary")
    Set NazvyCache = mNazvy
End Function

Private Function CistiVL(ByVal s As String) As String
    CistiVL = Replace(Replace(Replace(s, ";", ","), """", "'"), vbCrLf, " ")
End Function

Public Function NazovFondu(ByVal lFond As Long) As String
    Dim c As Object, k As String, v As Variant
    On Error Resume Next
    Set c = NazvyCache()
    k = "F" & lFond
    If c.Exists(k) Then NazovFondu = c(k): Exit Function
    v = DLookup("Nazov", "PracovneFondy", "Cislo = " & lFond & " AND (Rok * 12 + Mesiac) = " & CLng(Nz(DMax("Rok * 12 + Mesiac", "PracovneFondy", "Cislo = " & lFond), 0)))
    If IsNull(v) Then NazovFondu = "(chýba v číselníku)" Else NazovFondu = CStr(v)
    c(k) = NazovFondu
End Function

Public Function NazovSablony(ByVal lSablona As Long) As String
    Dim c As Object, k As String, v As Variant
    On Error Resume Next
    Set c = NazvyCache()
    k = "S" & lSablona
    If c.Exists(k) Then NazovSablony = c(k): Exit Function
    v = DLookup("NazovSablony", "ParametrePreruseni", "Sablona = " & lSablona)
    If IsNull(v) Then NazovSablony = "(bez pravidiel)" Else NazovSablony = CStr(v)
    c(k) = NazovSablony
End Function

Public Function NazovKalendara(ByVal lKal As Long) As String
    Dim c As Object, k As String, v As Variant
    On Error Resume Next
    Set c = NazvyCache()
    k = "K" & lKal
    If c.Exists(k) Then NazovKalendara = c(k): Exit Function
    v = DLookup("Nazov", "Kalendare", "Cislo = " & lKal)
    If IsNull(v) Then NazovKalendara = "(chýba v číselníku)" Else NazovKalendara = CStr(v)
    c(k) = NazovKalendara
End Function

Private Function Efekt(ByVal strOC As String) As Variant
    Dim a As Variant, iOvRok As Integer, iOvMes As Integer, f As Long, p As Long, k As Long, y As Long, u As Long
    If mCache Is Nothing Then Set mCache = CreateObject("Scripting.Dictionary")
    If mCache.Exists(strOC) Then
        Efekt = mCache.Item(strOC)
        Exit Function
    End If
    If mRok > 0 And mMes > 0 Then
        Call PlatnePriradenie(strOC, mRok, mMes, iOvRok, iOvMes, f, p, k, y, u)
    Else
        Call PlatnePriradenie(strOC, Year(Date), Month(Date), iOvRok, iOvMes, f, p, k, y, u)
    End If
    If u < 1 Or u > 200 Then u = UvazokZamestnanca(CurrentDb, strOC)
    a = Array(f, p, k, CLng(iOvRok) * 100 + iOvMes, u)
    mCache.Add strOC, a
    Efekt = a
End Function

'-------------------------------------------------------------------------------
' Vymaže vyrovnávaciu pamäť (volá sa pred obnovením zoznamu a po zmene priradení).
'-------------------------------------------------------------------------------
Public Sub Zam_ZrusCache()
    Set mCache = Nothing
    Set mNazvy = Nothing
End Sub

'-------------------------------------------------------------------------------
' Nastaví mesiac, pre ktorý Zam_FondText a Zam_PrerText ukazujú platné nastavenie (0, 0 = aktuálny mesiac).
'-------------------------------------------------------------------------------
Public Sub Zam_NastavMesiac(ByVal iRok As Integer, ByVal iMes As Integer)
    mRok = iRok
    mMes = iMes
    Call Zam_ZrusCache
End Sub

'-------------------------------------------------------------------------------
' Texty do zoznamu zamestnancov (volajú sa priamo z SQL dopytu zoznamu).
'-------------------------------------------------------------------------------
Public Function Zam_FondText(ByVal vOC As Variant) As String
    Dim a As Variant
    On Error Resume Next
    a = Efekt(CStr(Nz(vOC, "")))
    Zam_FondText = CStr(a(0)) & " - " & NazovFondu(CLng(a(0)))
End Function

Public Function Zam_UvazokText(ByVal vOC As Variant) As String
    Dim a As Variant
    On Error Resume Next
    a = Efekt(CStr(Nz(vOC, "")))
    Zam_UvazokText = CStr(a(4)) & " %"
End Function

Public Function Zam_PrerText(ByVal vOC As Variant) As String
    Dim a As Variant
    On Error Resume Next
    a = Efekt(CStr(Nz(vOC, "")))
    Zam_PrerText = CStr(a(1)) & " - " & NazovSablony(CLng(a(1)))
End Function

'-------------------------------------------------------------------------------
' Zoznamy hodnôt "kód;text;kód;text" pre rozbaľovacie polia. bNemenit = prvá položka "(nemeniť)" s kódom -1.
'-------------------------------------------------------------------------------
Private Function ZoznamKodov(ByVal strSql1 As String, ByVal strSql2 As String, ByVal strTyp As String, ByVal bNemenit As Boolean) As String
    Dim dic As Object, rs As DAO.Recordset, k As Variant, s As String, l As Long, strTxt As String
    On Error GoTo Chyba
    Set dic = CreateObject("Scripting.Dictionary")
    Dim aSql As Variant, vSql As Variant
    aSql = Array(strSql1, strSql2)
    For Each vSql In aSql
        If Len(CStr(vSql)) > 0 Then
            Set rs = CurrentDb.OpenRecordset(CStr(vSql), dbOpenSnapshot)
            Do While Not rs.EOF
                If Not IsNull(rs.Fields(0).Value) Then
                    l = CLng(rs.Fields(0).Value)
                    If l > 0 And Not dic.Exists(CStr(l)) Then dic(CStr(l)) = l
                End If
                rs.MoveNext
            Loop
            rs.Close
        End If
    Next vSql
    If bNemenit Then s = "-1;(nemeniť)"
    ' zoradenie podľa čísla
    Dim arr() As Long, i As Long, j As Long, t As Long, n As Long
    n = dic.Count
    If n > 0 Then
        ReDim arr(1 To n)
        i = 0
        For Each k In dic.Items
            i = i + 1
            arr(i) = CLng(k)
        Next k
        For i = 1 To n - 1
            For j = i + 1 To n
                If arr(j) < arr(i) Then t = arr(i): arr(i) = arr(j): arr(j) = t
            Next j
        Next i
        For i = 1 To n
            Select Case strTyp
                Case "F": strTxt = NazovFondu(arr(i))
                Case "S": strTxt = NazovSablony(arr(i))
                Case Else: strTxt = NazovKalendara(arr(i))
            End Select
            s = s & IIf(Len(s) > 0, ";", "") & arr(i) & ";" & CistiVL(arr(i) & " - " & strTxt)
        Next i
    End If
    ZoznamKodov = s
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_15_Zamestnanci.ZoznamKodov", "ERROR", Err.Description)
    ZoznamKodov = s
End Function

Public Function ZoznamFondovVL(Optional ByVal bNemenit As Boolean = False) As String
    ZoznamFondovVL = ZoznamKodov("SELECT DISTINCT Cislo FROM PracovneFondy;", "SELECT DISTINCT PracFondKod FROM ZamestnanciFondy;", "F", bNemenit)
End Function

Public Function ZoznamSablonVL(Optional ByVal bNemenit As Boolean = False) As String
    ZoznamSablonVL = ZoznamKodov("SELECT DISTINCT Sablona FROM ParametrePreruseni;", "SELECT DISTINCT ParPrerKod FROM ZamestnanciFondy;", "S", bNemenit)
End Function

Public Function ZoznamKalendarovVL(Optional ByVal bNemenit As Boolean = False) As String
    ZoznamKalendarovVL = ZoznamKodov("SELECT DISTINCT Cislo FROM Kalendare;", "SELECT DISTINCT KalendarKod FROM ZamestnanciFondy;", "K", bNemenit)
End Function
