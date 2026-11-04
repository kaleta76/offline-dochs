Attribute VB_Name = "mod_17_FondyPravidla"
'@Verzia 1.2.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_17_FondyPravidla
' POPIS: Dáta okien "Pracovné fondy" a "Pravidlá prerušení" (načítanie a ukladanie verzií).
'
'   Fond aj pravidlá prerušení sa v pôvodnej aplikácii (Ordata) ukladajú ako VERZIE platné od mesiaca:
'   pre mesiac platí najnovšia verzia s mesiacom <= mesiac (ak taká nie je, najstaršia). Ukladanie preto
'   robí toto: (1) zabezpečí, že verzia v zvolenom mesiaci existuje (vytvorí ju ako kópiu platnej verzie),
'   (2) zapíše zmenu do tejto verzie aj do všetkých novších verzií. Staršie mesiace sa nezmenia.
'
'   Pracovný fond (PracovneFondy + PracovneFondyDni):
'     typ fondu 1 Pevná, 2 Pružná, 3 Voľná podľa denného fondu, 4 Voľná s pevným mesačným fondom spolu za mesiac,
'     denný fond (PriemernaDlzkaMin), mesačný fond (DlzkaMesiacaMin, typ 4), príznak FondPodlaDna a pre každý deň
'     v týždni (Den 1 = pondelok ... 7 = nedeľa): príchod od (Zac1), odchod do (Kon1), fond (DlzkaBezPrestavkyMin)
'     a prestávka (DlzkaSPrestavkouMin - DlzkaBezPrestavkyMin).
'   Pravidlo prerušenia (ParametrePreruseni): povolený čas od - do (jedna dvojica alebo pre každý deň v týždni),
'     najdlhšie trvanie, najmenej odpracovať pred začiatkom, najkratšie trvanie, pravidlo vypnuté.
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - NacitajFond(fond, rok, mes, d)           : Načíta platnú verziu fondu do slovníka d.
' - UlozFond(fond, rok, mes, d)              : Uloží fond od mesiaca (vráti text chyby alebo "").
' - PocetPouzivajucich(typ, cislo)           : Počet zamestnancov s priradeným fondom ("F") / šablónou ("S").
' - NacitajPravidlo(sablona, cislo, rok, mes, d) : Načíta pravidlo prerušenia platné pre mesiac.
' - UlozPravidlo(sablona, cislo, rok, mes, d)    : Uloží pravidlo od mesiaca.
' - ZoznamPreruseniSablonyVL(sablona)        : Zoznam hodnôt "číslo;text;..." prerušení šablóny (vrátane číselníka).
' - ZoznamTypovFonduVL()                     : Zoznam hodnôt typov fondu.
' - MinutyNaText(min) / TextNaMinuty(text)   : Prevod minút na h:mm a späť (-1 pri neplatnom texte, "" = 0).
' - ZoznamVerziiVL(typ, kod, prerusenie)   : Zoznam verzií fondu ("F") / pravidla ("S") "rrrrmm;od m/rrrr;...".
' - ZoznamPouzivajucich(typ, kod, rok, mes, nVMes, nInokedy) : Zamestnanci, ktorí majú fond / šablónu v mesiaci (a inokedy).
' - ZoznamPredvolieFonduVL / PredvolbaFondu(kod, d)      : Predvolené hodnoty nového fondu (pevná, pružná, voľná, zmena ...).
' - ZoznamPredvoliePravidielVL / PredvolbaPravidla(kod, d) : Predvolené hodnoty pravidla prerušenia (obed, krátke prerušenie ...).
' - SqlZamestnanciVyber / TextPouzivajucich(typ, kod, rok, mes) : Zoznam zamestnancov pre skok; text okna Kto používa.
' - NovyFondZPredvolby(nazov, predvolba, rok, mes, chyba) : Nový fond z predvoľby, jedna verzia od mesiaca.
' - DoplnPredvolenyFondASablonu(sprava)     : Predvolený fond, šablóna bez kontroly a kalendár v prázdnej databáze + priradenie zamestnancom bez priradenia.
'===============================================================================

'-------------------------------------------------------------------------------
' Minúty -> "h:mm" (0 = prázdny text, pretože 0 znamená "nezadané").
'-------------------------------------------------------------------------------
Public Function MinutyNaText(ByVal lMin As Long) As String
    If lMin <= 0 Then Exit Function
    MinutyNaText = (lMin \ 60) & ":" & Format$(lMin Mod 60, "00")
End Function

'-------------------------------------------------------------------------------
' Text -> minúty. Prázdny text = 0; neplatný text = -1. Prijíma 7:30, 7.30, 730, 7 (= 7:00), aj 24:00.
'-------------------------------------------------------------------------------
Public Function TextNaMinuty(ByVal strText As String) As Long
    strText = Trim$(strText)
    If Len(strText) = 0 Then TextNaMinuty = 0: Exit Function
    TextNaMinuty = mod_00_Common.CasNaMinuty(strText)
End Function

'-------------------------------------------------------------------------------
' Pomocné: verzia (Rok * 12 + Mesiac) platná pre mesiac ym - najnovšia <= ym, inak najstaršia; 0, ak nič nie je.
'-------------------------------------------------------------------------------
Private Function PlatnaVerzia(ByVal strTab As String, ByVal strKrit As String, ByVal ym As Long) As Long
    Dim v As Variant
    On Error Resume Next
    v = DMax("Rok * 12 + Mesiac", strTab, strKrit & " AND (Rok * 12 + Mesiac) <= " & ym)
    If IsNull(v) Then v = DMin("Rok * 12 + Mesiac", strTab, strKrit)
    If Not IsNull(v) Then PlatnaVerzia = CLng(v)
    Err.Clear
End Function

'-------------------------------------------------------------------------------
' Nový riadok: číselné polia 0, áno/nie Nie (aby sa nezapisovali hodnoty Null).
'-------------------------------------------------------------------------------
Private Sub NulujNovyRiadok(ByRef rs As DAO.Recordset)
    Dim f As DAO.Field
    On Error Resume Next
    For Each f In rs.Fields
        If (f.Attributes And dbAutoIncrField) = 0 Then
            Select Case f.Type
                Case dbBoolean: f.Value = False
                Case dbByte, dbInteger, dbLong, dbCurrency, dbSingle, dbDouble: f.Value = 0
            End Select
        End If
        Err.Clear
    Next f
End Sub

'===============================================================================
' PRACOVNÝ FOND
'===============================================================================

'-------------------------------------------------------------------------------
' Načíta verziu fondu platnú pre mesiac. Slovník d: Nazov, Typ, Opak, Denny, Mesacny, PodlaDna, VerziaRok, VerziaMes
' a pre dni 1 až 7: D<n>Od, D<n>Do, D<n>Fond, D<n>Prest (minúty). Vráti False, ak fond nemá žiadnu verziu.
'-------------------------------------------------------------------------------
Public Function NacitajFond(ByVal lFond As Long, ByVal iRok As Integer, ByVal iMes As Integer, ByVal d As Object) As Boolean
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset, lVer As Long, lRok As Long, lMes As Long, n As Long, lF As Long, lS As Long

    d.RemoveAll
    Set db = CurrentDb
    If Not mod_00_Common.TabulkaExistujeDB(db, "PracovneFondy") Then Exit Function
    lVer = PlatnaVerzia("PracovneFondy", "Cislo = " & lFond, CLng(iRok) * 12 + iMes)
    If lVer = 0 Then Exit Function
    lRok = (lVer - 1) \ 12
    lMes = lVer - lRok * 12

    Set rs = db.OpenRecordset("SELECT * FROM PracovneFondy WHERE Cislo = " & lFond & " AND Rok = " & lRok & " AND Mesiac = " & lMes & ";", dbOpenSnapshot)
    If rs.EOF Then rs.Close: Exit Function
    d("Nazov") = CStr(Nz(rs!Nazov, ""))
    d("Typ") = CLng(Nz(rs!TypFondu, 2))
    d("Opak") = CLng(Nz(rs!TypOpakovania, 1))
    d("Denny") = CLng(Nz(rs!PriemernaDlzkaMin, 0))
    d("Mesacny") = CLng(Nz(rs!DlzkaMesiacaMin, 0))
    d("PodlaDna") = False
    If mod_00_Common.PoleExistujeDB(db, "PracovneFondy", "FondPodlaDna") Then d("PodlaDna") = CBool(Nz(rs!FondPodlaDna, False))
    d("VerziaRok") = lRok
    d("VerziaMes") = lMes
    rs.Close

    For n = 1 To 7
        d("D" & n & "Od") = 0: d("D" & n & "Do") = 0: d("D" & n & "Fond") = 0: d("D" & n & "Prest") = 0
    Next n
    If mod_00_Common.TabulkaExistujeDB(db, "PracovneFondyDni") Then
        Set rs = db.OpenRecordset("SELECT * FROM PracovneFondyDni WHERE Cislo = " & lFond & " AND Rok = " & lRok & " AND Mesiac = " & lMes & _
                                  " AND Den >= 1 AND Den <= 7;", dbOpenSnapshot)
        Do While Not rs.EOF
            n = CLng(rs!Den)
            lF = CLng(Nz(rs!DlzkaBezPrestavkyMin, 0))
            lS = CLng(Nz(rs!DlzkaSPrestavkouMin, 0))
            d("D" & n & "Od") = CLng(Nz(rs!Zac1, 0))
            d("D" & n & "Do") = CLng(Nz(rs!Kon1, 0))
            d("D" & n & "Fond") = lF
            If lS > lF And lF > 0 Then d("D" & n & "Prest") = lS - lF
            rs.MoveNext
        Loop
        rs.Close
    End If
    NacitajFond = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_17_FondyPravidla.NacitajFond", "ERROR", Err.Description, "Fond=" & lFond)
End Function

'-------------------------------------------------------------------------------
' Zabezpečí verziu fondu v mesiaci iRok/iMes: ak neexistuje, vznikne kópiou platnej verzie (aj s dňami);
' ak fond nemá žiadnu verziu, vznikne nová s názvom strNazov.
'-------------------------------------------------------------------------------
Private Sub ZabezpecVerziuFondu(ByRef db As DAO.Database, ByVal lFond As Long, ByVal iRok As Integer, ByVal iMes As Integer, ByVal strNazov As String)
    Dim lVer As Long, lRok As Long, lMes As Long, dic As Object, rs As DAO.Recordset, ym As Long
    ym = CLng(iRok) * 12 + iMes
    If Nz(DCount("*", "PracovneFondy", "Cislo = " & lFond & " AND Rok = " & iRok & " AND Mesiac = " & iMes), 0) > 0 Then Exit Sub
    lVer = PlatnaVerzia("PracovneFondy", "Cislo = " & lFond, ym)
    If lVer = 0 Then
        Set rs = db.OpenRecordset("SELECT * FROM PracovneFondy WHERE 1 = 0;", dbOpenDynaset)
        rs.AddNew
        Call NulujNovyRiadok(rs)
        rs!Cislo = lFond
        rs!Rok = iRok
        rs!Mesiac = iMes
        rs!Nazov = Left$(strNazov, 100)
        rs!PocetZmien = 1
        rs!TypFondu = 2
        rs!TypOpakovania = 1
        rs!PriemernaDlzkaMin = 450
        rs.Update
        rs.Close
        Exit Sub
    End If
    lRok = (lVer - 1) \ 12
    lMes = lVer - lRok * 12
    Set dic = CreateObject("Scripting.Dictionary")
    dic("Rok") = iRok
    dic("Mesiac") = iMes
    Call mod_15_Zamestnanci.KopirujRiadky(db, "PracovneFondy", "Cislo = " & lFond & " AND Rok = " & lRok & " AND Mesiac = " & lMes, dic)
    If mod_00_Common.TabulkaExistujeDB(db, "PracovneFondyDni") Then
        Call mod_15_Zamestnanci.KopirujRiadky(db, "PracovneFondyDni", "Cislo = " & lFond & " AND Rok = " & lRok & " AND Mesiac = " & lMes, dic)
    End If
End Sub

'-------------------------------------------------------------------------------
' Zapíše hodnoty dní (1 až 7) do verzie fondu (rok, mesiac).
'-------------------------------------------------------------------------------
Private Sub UlozDniFondu(ByRef db As DAO.Database, ByVal lFond As Long, ByVal lRok As Long, ByVal lMes As Long, ByVal d As Object)
    Dim n As Long, rs As DAO.Recordset, lF As Long, lP As Long
    For n = 1 To 7
        Set rs = db.OpenRecordset("SELECT * FROM PracovneFondyDni WHERE Cislo = " & lFond & " AND Rok = " & lRok & " AND Mesiac = " & lMes & _
                                  " AND Den = " & n & ";", dbOpenDynaset)
        If rs.EOF Then
            rs.AddNew
            Call NulujNovyRiadok(rs)
            rs!Cislo = lFond
            rs!Rok = lRok
            rs!Mesiac = lMes
            rs!Den = n
        Else
            rs.Edit
        End If
        lF = CLng(d("D" & n & "Fond"))
        lP = CLng(d("D" & n & "Prest"))
        rs!Zac1 = CLng(d("D" & n & "Od"))
        rs!Kon1 = CLng(d("D" & n & "Do"))
        rs!DlzkaBezPrestavkyMin = lF
        rs!DlzkaSPrestavkouMin = IIf(lF > 0, lF + lP, 0)
        rs.Update
        rs.Close
    Next n
End Sub

'-------------------------------------------------------------------------------
' Uloží fond od mesiaca iRok/iMes (platí aj pre všetky novšie verzie). Slovník d ako pri NacitajFond.
' Vráti text chyby alebo "".
'-------------------------------------------------------------------------------
Public Function UlozFond(ByVal lFond As Long, ByVal iRok As Integer, ByVal iMes As Integer, ByVal d As Object) As String
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset, ym As Long, strNazov As String, lTyp As Long, bPodla As Boolean, strZ As String

    strNazov = Trim$(CStr(d("Nazov")))
    If Len(strNazov) = 0 Then UlozFond = "Zadajte názov fondu.": Exit Function
    lTyp = CLng(d("Typ"))
    If lTyp < 1 Or lTyp > 4 Then UlozFond = "Vyberte typ fondu.": Exit Function
    If CLng(d("Denny")) <= 0 Then UlozFond = "Zadajte denný fond (napr. 7:30).": Exit Function
    If lTyp = 4 And CLng(d("Mesacny")) <= 0 Then UlozFond = "Pri type 4 zadajte mesačný fond (napr. 165:00).": Exit Function
    bPodla = CBool(d("PodlaDna"))
    If iRok < 1990 Or iRok > 2100 Or iMes < 1 Or iMes > 12 Then UlozFond = "Vyberte mesiac platnosti.": Exit Function

    ' ochrana uzavretých (podpísaných) mesiacov: zmena fondu sa nesmie dotknúť ich výpočtu
    strZ = mod_18_Uzavierka.DotknutyFond(lFond, iRok, iMes)
    If Len(strZ) > 0 Then
        UlozFond = mod_18_Uzavierka.TextBlokovanejZmeny(strZ)
        Exit Function
    End If

    Set db = CurrentDb
    ym = CLng(iRok) * 12 + iMes
    Call mod_15_Zamestnanci.ZabezpecModel(db)
    Call ZabezpecVerziuFondu(db, lFond, iRok, iMes, strNazov)

    ' názov patrí fondu (všetky verzie)
    db.Execute "UPDATE PracovneFondy SET Nazov = " & mod_00_Common.SqlText(Left$(strNazov, 100)) & " WHERE Cislo = " & lFond & ";", dbFailOnError

    Set rs = db.OpenRecordset("SELECT * FROM PracovneFondy WHERE Cislo = " & lFond & " AND (Rok * 12 + Mesiac) >= " & ym & ";", dbOpenDynaset)
    Do While Not rs.EOF
        rs.Edit
        rs!TypFondu = lTyp
        rs!PriemernaDlzkaMin = CLng(d("Denny"))
        If lTyp = 4 Then rs!DlzkaMesiacaMin = CLng(d("Mesacny"))
        rs!FondPodlaDna = bPodla
        rs.Update
        If bPodla Then Call UlozDniFondu(db, lFond, CLng(rs!Rok), CLng(rs!Mesiac), d)
        rs.MoveNext
    Loop
    rs.Close

    Call mod_15_Zamestnanci.Zam_ZrusCache
    Call mod_08_UdalostiDna.ObnovParametre
    Call mod_18_Uzavierka.OznacNastaveniaLokalne
    Call mod_00_Common.ZapisLog("mod_17_FondyPravidla.UlozFond", "INFO", "Fond " & lFond & " (" & strNazov & ") uložený od " & iMes & "/" & iRok & ".")
    Exit Function
Chyba:
    UlozFond = "Fond sa nepodarilo uložiť: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_17_FondyPravidla.UlozFond", "ERROR", Err.Description, "Fond=" & lFond)
End Function

'-------------------------------------------------------------------------------
' Počet rôznych zamestnancov, ktorí majú niekedy priradený fond ("F") alebo šablónu prerušení ("S") s daným číslom.
'-------------------------------------------------------------------------------
Public Function PocetPouzivajucich(ByVal strTyp As String, ByVal lCislo As Long) As Long
    Dim rs As DAO.Recordset, strPole As String
    On Error Resume Next
    If strTyp = "S" Then strPole = "ParPrerKod" Else strPole = "PracFondKod"
    Set rs = CurrentDb.OpenRecordset("SELECT DISTINCT OsobneCislo FROM ZamestnanciFondy WHERE " & strPole & " = " & lCislo & ";", dbOpenSnapshot)
    Do While Not rs.EOF
        PocetPouzivajucich = PocetPouzivajucich + 1
        rs.MoveNext
    Loop
    rs.Close
    Err.Clear
End Function

Public Function ZoznamTypovFonduVL() As String
    ZoznamTypovFonduVL = "1;1 - Pevná pracovná doba;2;2 - Pružná pracovná doba;3;3 - Voľná, fond podľa denného fondu;4;4 - Voľná, pevný fond spolu za mesiac"
End Function

'===============================================================================
' PRAVIDLÁ PRERUŠENÍ
'===============================================================================

'-------------------------------------------------------------------------------
' Zoznam prerušení šablóny "číslo;číslo - názov;..." (prerušenia v šablóne + prerušenia z číselníka).
'-------------------------------------------------------------------------------
Public Function ZoznamPreruseniSablonyVL(ByVal lSablona As Long) As String
    Dim dic As Object, rs As DAO.Recordset, k As Variant, c As Long, s As String, arr() As Long, n As Long, i As Long, j As Long, t As Long
    On Error GoTo Chyba
    Set dic = CreateObject("Scripting.Dictionary")
    If mod_00_Common.TabulkaExistuje("ParametrePreruseni") Then
        Set rs = CurrentDb.OpenRecordset("SELECT CisloPreruseni, NazovPreruseni FROM ParametrePreruseni WHERE Sablona = " & lSablona & _
                                         " ORDER BY (Rok * 12 + Mesiac);", dbOpenSnapshot)
        Do While Not rs.EOF
            c = CLng(Nz(rs!CisloPreruseni, 0))
            If c > 0 Then
                If dic.Exists(c) Then dic.Remove c
                dic.Add c, CStr(Nz(rs!NazovPreruseni, ""))
            End If
            rs.MoveNext
        Loop
        rs.Close
    End If
    If mod_00_Common.TabulkaExistuje("CiselnikPreruseni") Then
        Set rs = CurrentDb.OpenRecordset("SELECT Cislo, Nazov FROM CiselnikPreruseni ORDER BY Cislo;", dbOpenSnapshot)
        Do While Not rs.EOF
            c = CLng(Nz(rs!Cislo, 0))
            If c > 0 And Not dic.Exists(c) Then dic.Add c, CStr(Nz(rs!Nazov, ""))
            rs.MoveNext
        Loop
        rs.Close
    End If
    n = dic.Count
    If n = 0 Then Exit Function
    ReDim arr(1 To n)
    i = 0
    For Each k In dic.Keys
        i = i + 1
        arr(i) = CLng(k)
    Next k
    For i = 1 To n - 1
        For j = i + 1 To n
            If arr(j) < arr(i) Then t = arr(i): arr(i) = arr(j): arr(j) = t
        Next j
    Next i
    For i = 1 To n
        s = s & IIf(Len(s) > 0, ";", "") & arr(i) & ";" & arr(i) & " - " & Replace(Replace(CStr(dic.Item(arr(i))), ";", ","), """", "'")
    Next i
    ZoznamPreruseniSablonyVL = s
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_17_FondyPravidla.ZoznamPreruseniSablonyVL", "ERROR", Err.Description)
    ZoznamPreruseniSablonyVL = s
End Function

'-------------------------------------------------------------------------------
' Načíta pravidlo prerušenia platné pre mesiac. Slovník d: Nazov, IntOd, IntDo, RozneDni, Max (1440 = bez obmedzenia),
' MinO, MinT, Aktivne, Existuje, D<n>Od, D<n>Do, D<n>Max. Ak pravidlo ešte neexistuje, vráti True s prázdnymi hodnotami.
'-------------------------------------------------------------------------------
Public Function NacitajPravidlo(ByVal lSab As Long, ByVal lCis As Long, ByVal iRok As Integer, ByVal iMes As Integer, ByVal d As Object) As Boolean
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset, lVer As Long, lRok As Long, lMes As Long, n As Long, strKrit As String

    d.RemoveAll
    Set db = CurrentDb
    d("Nazov") = "": d("IntOd") = 0: d("IntDo") = 0: d("RozneDni") = False: d("Max") = 1440
    d("MinO") = 0: d("MinT") = 0: d("Aktivne") = True: d("Existuje") = False
    For n = 1 To 7
        d("D" & n & "Od") = 0: d("D" & n & "Do") = 0: d("D" & n & "Max") = 1440
    Next n
    NacitajPravidlo = True
    If Not mod_00_Common.TabulkaExistujeDB(db, "ParametrePreruseni") Then Exit Function
    strKrit = "Sablona = " & lSab & " AND CisloPreruseni = " & lCis
    lVer = PlatnaVerzia("ParametrePreruseni", strKrit, CLng(iRok) * 12 + iMes)
    If lVer = 0 Then Exit Function
    lRok = (lVer - 1) \ 12
    lMes = lVer - lRok * 12
    Set rs = db.OpenRecordset("SELECT * FROM ParametrePreruseni WHERE " & strKrit & " AND Rok = " & lRok & " AND Mesiac = " & lMes & ";", dbOpenSnapshot)
    If Not rs.EOF Then
        d("Existuje") = True
        d("VerziaRok") = lRok
        d("VerziaMes") = lMes
        d("Nazov") = CStr(Nz(rs!NazovPreruseni, ""))
        d("IntOd") = CLng(Nz(rs!IntervalMesiacOdMin, 0))
        d("IntDo") = CLng(Nz(rs!IntervalMesiacDoMin, 0))
        d("RozneDni") = CBool(Nz(rs!IntervalDniTyzdna, False)) Or CBool(Nz(rs!MaxTrvanieDniTyzdna, False))
        d("Max") = CLng(Nz(rs!MaxTrvanieMesiacMin, 1440))
        If mod_00_Common.PoleExistujeDB(db, "ParametrePreruseni", "MinOdpracovaneMin") Then d("MinO") = CLng(Nz(rs!MinOdpracovaneMin, 0))
        If mod_00_Common.PoleExistujeDB(db, "ParametrePreruseni", "MinTrvanieMin") Then d("MinT") = CLng(Nz(rs!MinTrvanieMin, 0))
        If mod_00_Common.PoleExistujeDB(db, "ParametrePreruseni", "PravidloVypnute") Then d("Aktivne") = Not CBool(Nz(rs!PravidloVypnute, False))
        For n = 1 To 7
            d("D" & n & "Od") = CLng(Nz(rs.Fields("IntervalDen" & n & "OdMin").Value, 0))
            d("D" & n & "Do") = CLng(Nz(rs.Fields("IntervalDen" & n & "DoMin").Value, 0))
            d("D" & n & "Max") = CLng(Nz(rs.Fields("MaxTrvanieDen" & n & "Min").Value, 1440))
        Next n
    End If
    rs.Close
    Exit Function
Chyba:
    NacitajPravidlo = False
    Call mod_00_Common.ZapisLog("mod_17_FondyPravidla.NacitajPravidlo", "ERROR", Err.Description, "Sablona=" & lSab & ", prerusenie=" & lCis)
End Function

'-------------------------------------------------------------------------------
' Zabezpečí verziu pravidla v mesiaci iRok/iMes (kópia platnej verzie; ak pravidlo nemá žiadnu verziu, vznikne prázdna).
'-------------------------------------------------------------------------------
Private Sub ZabezpecVerziuPravidla(ByRef db As DAO.Database, ByVal lSab As Long, ByVal lCis As Long, ByVal iRok As Integer, ByVal iMes As Integer, ByVal strNazov As String)
    Dim lVer As Long, lRok As Long, lMes As Long, dic As Object, rs As DAO.Recordset, strKrit As String, strNazSab As String, v As Variant, n As Long
    strKrit = "Sablona = " & lSab & " AND CisloPreruseni = " & lCis
    If Nz(DCount("*", "ParametrePreruseni", strKrit & " AND Rok = " & iRok & " AND Mesiac = " & iMes), 0) > 0 Then Exit Sub
    lVer = PlatnaVerzia("ParametrePreruseni", strKrit, CLng(iRok) * 12 + iMes)
    If lVer > 0 Then
        lRok = (lVer - 1) \ 12
        lMes = lVer - lRok * 12
        Set dic = CreateObject("Scripting.Dictionary")
        dic("Rok") = iRok
        dic("Mesiac") = iMes
        Call mod_15_Zamestnanci.KopirujRiadky(db, "ParametrePreruseni", strKrit & " AND Rok = " & lRok & " AND Mesiac = " & lMes, dic)
        Exit Sub
    End If
    v = DLookup("NazovSablony", "ParametrePreruseni", "Sablona = " & lSab)
    If IsNull(v) Then strNazSab = "Šablóna " & lSab Else strNazSab = CStr(v)
    Set rs = db.OpenRecordset("SELECT * FROM ParametrePreruseni WHERE 1 = 0;", dbOpenDynaset)
    rs.AddNew
    Call NulujNovyRiadok(rs)
    rs!Sablona = lSab
    rs!Rok = iRok
    rs!Mesiac = iMes
    rs!CisloPreruseni = lCis
    rs!NazovSablony = Left$(strNazSab, 50)
    rs!NazovPreruseni = Left$(strNazov, 50)
    rs!MaxTrvanieMesiacMin = 1440
    rs!PrevodCasMin = 1440
    For n = 1 To 7
        rs.Fields("MaxTrvanieDen" & n & "Min").Value = 1440
    Next n
    rs.Update
    rs.Close
End Sub

'-------------------------------------------------------------------------------
' Uloží pravidlo prerušenia od mesiaca iRok/iMes (platí aj pre všetky novšie verzie). Vráti text chyby alebo "".
'-------------------------------------------------------------------------------
Public Function UlozPravidlo(ByVal lSab As Long, ByVal lCis As Long, ByVal iRok As Integer, ByVal iMes As Integer, ByVal d As Object) As String
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset, ym As Long, n As Long, bRozne As Boolean, lMax As Long, strNazov As String, strKrit As String
    Dim strZ As String, lC0 As Long, bZaklad As Boolean, lRz As Long

    If lSab <= 0 Or lCis <= 0 Then UlozPravidlo = "Vyberte šablónu a prerušenie.": Exit Function
    If iRok < 1990 Or iRok > 2100 Or iMes < 1 Or iMes > 12 Then UlozPravidlo = "Vyberte mesiac platnosti.": Exit Function
    bRozne = CBool(d("RozneDni"))
    If CLng(d("IntOd")) < 0 Or CLng(d("IntDo")) < 0 Or CLng(d("IntDo")) > 1440 Then UlozPravidlo = "Povolený čas zadajte v tvare 11:00 až 13:30.": Exit Function
    If CLng(d("IntDo")) > 0 And CLng(d("IntDo")) <= CLng(d("IntOd")) Then UlozPravidlo = "Koniec povoleného času musí byť neskôr ako začiatok.": Exit Function
    If bRozne Then
        For n = 1 To 7
            If CLng(d("D" & n & "Do")) > 0 And CLng(d("D" & n & "Do")) <= CLng(d("D" & n & "Od")) Then
                UlozPravidlo = "V dni " & n & " (" & Choose(n, "pondelok", "utorok", "streda", "štvrtok", "piatok", "sobota", "nedeľa") & ") musí byť koniec povoleného času neskôr ako začiatok."
                Exit Function
            End If
        Next n
    End If

    Set db = CurrentDb
    ym = CLng(iRok) * 12 + iMes
    strKrit = "Sablona = " & lSab & " AND CisloPreruseni = " & lCis
    strNazov = CStr(d("Nazov"))

    ' ochrana uzavretých (podpísaných) mesiacov. Prvá verzia pravidla by sa podľa pravidla "pred prvou verziou platí najstaršia"
    ' uplatnila aj na staršie mesiace - ak ich uzavreté mesiace používajú, vytvorí sa pre ne vypnutá základná verzia.
    lC0 = mod_18_Uzavierka.NajstarsiUzavretyMesiac("S", lSab)
    bZaklad = (lC0 > 0 And lC0 < ym)
    strZ = mod_18_Uzavierka.DotknutaSablona(lSab, lCis, iRok, iMes, bZaklad)
    If Len(strZ) > 0 Then
        UlozPravidlo = mod_18_Uzavierka.TextBlokovanejZmeny(strZ)
        Exit Function
    End If

    Call mod_15_Zamestnanci.ZabezpecModel(db)
    If bZaklad And Nz(DCount("*", "ParametrePreruseni", strKrit), 0) = 0 Then
        lRz = (lC0 - 1) \ 12
        Call ZabezpecVerziuPravidla(db, lSab, lCis, CInt(lRz), CInt(lC0 - lRz * 12), strNazov)
        db.Execute "UPDATE ParametrePreruseni SET PravidloVypnute = True WHERE " & strKrit & ";", dbFailOnError
    End If
    Call ZabezpecVerziuPravidla(db, lSab, lCis, iRok, iMes, strNazov)

    Set rs = db.OpenRecordset("SELECT * FROM ParametrePreruseni WHERE " & strKrit & " AND (Rok * 12 + Mesiac) >= " & ym & ";", dbOpenDynaset)
    Do While Not rs.EOF
        rs.Edit
        rs!IntervalMesiacOdMin = CLng(d("IntOd"))
        rs!IntervalMesiacDoMin = CLng(d("IntDo"))
        rs!IntervalDniTyzdna = bRozne
        rs!MaxTrvanieDniTyzdna = bRozne
        lMax = CLng(d("Max"))
        If lMax <= 0 Then lMax = 1440
        rs!MaxTrvanieMesiacMin = lMax
        rs!MinOdpracovaneMin = CLng(d("MinO"))
        rs!MinTrvanieMin = CLng(d("MinT"))
        rs!PravidloVypnute = Not CBool(d("Aktivne"))
        If bRozne Then
            For n = 1 To 7
                rs.Fields("IntervalDen" & n & "OdMin").Value = CLng(d("D" & n & "Od"))
                rs.Fields("IntervalDen" & n & "DoMin").Value = CLng(d("D" & n & "Do"))
                lMax = CLng(d("D" & n & "Max"))
                If lMax <= 0 Then lMax = 1440
                rs.Fields("MaxTrvanieDen" & n & "Min").Value = lMax
            Next n
        End If
        rs.Update
        rs.MoveNext
    Loop
    rs.Close

    Call mod_15_Zamestnanci.Zam_ZrusCache
    Call mod_16_PravidlaPreruseni.ObnovPravidla
    Call mod_18_Uzavierka.OznacNastaveniaLokalne
    Call mod_00_Common.ZapisLog("mod_17_FondyPravidla.UlozPravidlo", "INFO", "Pravidlo šablóny " & lSab & ", prerušenie " & lCis & " uložené od " & iMes & "/" & iRok & ".")
    Exit Function
Chyba:
    UlozPravidlo = "Pravidlo sa nepodarilo uložiť: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_17_FondyPravidla.UlozPravidlo", "ERROR", Err.Description, "Sablona=" & lSab & ", prerusenie=" & lCis)
End Function

'===============================================================================
' VERZIE, POUŽÍVATELIA A PREDVOĽBY (pomôcky okien Pracovné fondy a Pravidlá prerušení)
'===============================================================================

'-------------------------------------------------------------------------------
' Zoznam verzií fondu (strTyp "F", lKod = číslo fondu) alebo pravidla (strTyp "S", lKod = šablóna, lCis = prerušenie) ako
' hodnoty rozbaľovacieho zoznamu "rrrrmm;od m/rrrr;..." (najstaršia prvá). Prázdny reťazec, ak verzia neexistuje.
'-------------------------------------------------------------------------------
Public Function ZoznamVerziiVL(ByVal strTyp As String, ByVal lKod As Long, ByVal lCis As Long) As String
    Dim rs As DAO.Recordset, strTab As String, strKrit As String, s As String
    On Error GoTo Chyba
    If strTyp = "S" Then
        strTab = "ParametrePreruseni"
        strKrit = "Sablona = " & lKod & " AND CisloPreruseni = " & lCis
    Else
        strTab = "PracovneFondy"
        strKrit = "Cislo = " & lKod
    End If
    If Not mod_00_Common.TabulkaExistuje(strTab) Then Exit Function
    Set rs = CurrentDb.OpenRecordset("SELECT DISTINCT Rok, Mesiac FROM " & strTab & " WHERE " & strKrit & " ORDER BY Rok, Mesiac;", dbOpenSnapshot)
    Do While Not rs.EOF
        If Len(s) > 0 Then s = s & ";"
        s = s & (CLng(rs!Rok) * 100 + CLng(rs!Mesiac)) & ";od " & CLng(rs!Mesiac) & "/" & CLng(rs!Rok)
        rs.MoveNext
    Loop
    rs.Close
    ZoznamVerziiVL = s
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_17_FondyPravidla.ZoznamVerziiVL", "ERROR", Err.Description)
    ZoznamVerziiVL = s
End Function

'-------------------------------------------------------------------------------
' Zamestnanci s fondom ("F") alebo šablónou ("S") lKod. Vráti riadky "osobné číslo - meno": najprv tí, ktorí ho majú platný
' v mesiaci iRok/iMes (nVMes), potom tí, ktorí ho majú len v inom období (nInokedy; vypíše sa najviac lMax riadkov).
'-------------------------------------------------------------------------------
Public Function ZoznamPouzivajucich(ByVal strTyp As String, ByVal lKod As Long, ByVal iRok As Integer, ByVal iMes As Integer, _
                                    ByRef nVMes As Long, ByRef nInokedy As Long, Optional ByVal lMax As Long = 25) As String
    Dim rs As DAO.Recordset, strPole As String, strOC As String, iOdR As Integer, iOdM As Integer, f As Long, p As Long, k As Long, y As Long
    Dim sV As String, sI As String, strM As String, v As Variant
    On Error GoTo Chyba
    nVMes = 0: nInokedy = 0
    If strTyp = "S" Then strPole = "ParPrerKod" Else strPole = "PracFondKod"
    If Not mod_00_Common.TabulkaExistuje("ZamestnanciFondy") Then Exit Function
    Set rs = CurrentDb.OpenRecordset("SELECT DISTINCT OsobneCislo FROM ZamestnanciFondy WHERE " & strPole & " = " & lKod & " ORDER BY OsobneCislo;", dbOpenSnapshot)
    Do While Not rs.EOF
        strOC = CStr(Nz(rs!OsobneCislo, ""))
        v = Null
        v = DLookup("Priezvisko & ' ' & Meno", "Zamestnanci", "OsobneCislo = " & mod_00_Common.SqlText(strOC))
        If IsNull(v) Then strM = strOC Else strM = strOC & " - " & Trim$(CStr(v))
        Call mod_15_Zamestnanci.PlatnePriradenie(strOC, iRok, iMes, iOdR, iOdM, f, p, k, y)
        If (strTyp = "S" And p = lKod) Or (strTyp <> "S" And f = lKod) Then
            nVMes = nVMes + 1
            If nVMes <= lMax Then sV = sV & strM & vbCrLf
        Else
            nInokedy = nInokedy + 1
            If nInokedy <= lMax Then sI = sI & strM & vbCrLf
        End If
        rs.MoveNext
    Loop
    rs.Close
    If nVMes > lMax Then sV = sV & "... a ďalších " & (nVMes - lMax) & vbCrLf
    If nInokedy > lMax Then sI = sI & "... a ďalších " & (nInokedy - lMax) & vbCrLf
    ZoznamPouzivajucich = sV & IIf(Len(sI) > 0, "|", "") & sI
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_17_FondyPravidla.ZoznamPouzivajucich", "ERROR", Err.Description)
End Function

Private Sub NastavDni(ByVal d As Object, ByVal lOd As Long, ByVal lDo As Long, ByVal lZac As Long, ByVal lKon As Long, ByVal lFond As Long, ByVal lPrest As Long)
    Dim n As Long
    For n = lOd To lDo
        d("D" & n & "Od") = lZac
        d("D" & n & "Do") = lKon
        d("D" & n & "Fond") = lFond
        d("D" & n & "Prest") = lPrest
    Next n
End Sub

'-------------------------------------------------------------------------------
' Predvolené hodnoty nového pracovného fondu (čas v minútach od polnoci). Názov fondu sa nemení.
'-------------------------------------------------------------------------------
Public Function ZoznamPredvolieFonduVL() As String
    ZoznamPredvolieFonduVL = "1;Pevná 7:30 (7:00 - 15:00, prestávka 30 min), Po-Pi;" & _
                             "2;Pevná 8:00 (7:00 - 15:30, prestávka 30 min), Po-Pi;" & _
                             "3;Pružná 7:30 (6:00 - 18:00, prestávka 30 min), Po-Pi;" & _
                             "4;Voľná 7:30 podľa denného fondu (bez časového okna);" & _
                             "5;Voľná, pevný mesačný fond 165:00;" & _
                             "6;Dvanásťhodinová zmena (6:00 - 18:00, fond 11:00, prestávka 60 min), všetky dni"
End Function

Public Function PredvolbaFondu(ByVal lKod As Long, ByVal d As Object) As Boolean
    Dim n As Long
    d.RemoveAll
    d("Typ") = 2: d("Denny") = 450: d("Mesacny") = 0: d("PodlaDna") = False
    Call NastavDni(d, 1, 7, 0, 0, 0, 0)
    PredvolbaFondu = True
    Select Case lKod
        Case 1
            d("Typ") = 1: d("Denny") = 450: d("PodlaDna") = True
            Call NastavDni(d, 1, 5, 420, 900, 450, 30)
        Case 2
            d("Typ") = 1: d("Denny") = 480: d("PodlaDna") = True
            Call NastavDni(d, 1, 5, 420, 930, 480, 30)
        Case 3
            d("Typ") = 2: d("Denny") = 450: d("PodlaDna") = True
            Call NastavDni(d, 1, 5, 360, 1080, 450, 30)
        Case 4
            d("Typ") = 3: d("Denny") = 450
        Case 5
            d("Typ") = 4: d("Denny") = 450: d("Mesacny") = 9900
        Case 6
            d("Typ") = 1: d("Denny") = 660: d("PodlaDna") = True
            Call NastavDni(d, 1, 7, 360, 1080, 660, 60)
        Case Else
            PredvolbaFondu = False
    End Select
End Function

'-------------------------------------------------------------------------------
' Predvolené hodnoty pravidla prerušenia (čas v minútach od polnoci, 1440 = bez obmedzenia trvania).
'-------------------------------------------------------------------------------
Public Function ZoznamPredvoliePravidielVL() As String
    ZoznamPredvoliePravidielVL = "1;Bez kontroly (pravidlo vypnuté);" & _
                                 "2;Obed 11:30 - 13:30, najdlhšie 30 min, po 3 h práce;" & _
                                 "3;Obed 11:00 - 14:00, najdlhšie 60 min, po 3 h práce;" & _
                                 "4;Krátke prerušenie, najdlhšie 20 min;" & _
                                 "5;Lekár / súkromné: 7:00 - 15:00, najdlhšie 4 h"
End Function

Public Function PredvolbaPravidla(ByVal lKod As Long, ByVal d As Object) As Boolean
    Dim n As Long
    d.RemoveAll
    d("Existuje") = True: d("Aktivne") = True: d("RozneDni") = False
    d("IntOd") = 0: d("IntDo") = 0: d("Max") = 1440: d("MinO") = 0: d("MinT") = 0
    For n = 1 To 7
        d("D" & n & "Od") = 0: d("D" & n & "Do") = 0: d("D" & n & "Max") = 1440
    Next n
    PredvolbaPravidla = True
    Select Case lKod
        Case 1
            d("Aktivne") = False
        Case 2
            d("IntOd") = 690: d("IntDo") = 810: d("Max") = 30: d("MinO") = 180
        Case 3
            d("IntOd") = 660: d("IntDo") = 840: d("Max") = 60: d("MinO") = 180
        Case 4
            d("Max") = 20
        Case 5
            d("IntOd") = 420: d("IntDo") = 900: d("Max") = 240
        Case Else
            PredvolbaPravidla = False
    End Select
End Function

'-------------------------------------------------------------------------------
' SQL zoznamu zamestnancov pre rozbaľovací zoznam "Zamestnanec" (skok na fond / pravidlá platné pre neho):
' prvý stĺpec osobné číslo (skrytý), druhý "Priezvisko Meno (osobné číslo)".
'-------------------------------------------------------------------------------
Public Function SqlZamestnanciVyber() As String
    SqlZamestnanciVyber = "SELECT OsobneCislo, Priezvisko & ' ' & Meno & ' (' & OsobneCislo & ')' AS Zamestnanec " & _
                          "FROM Zamestnanci WHERE OsobneCislo IS NOT NULL ORDER BY Priezvisko, Meno, OsobneCislo;"
End Function

'-------------------------------------------------------------------------------
' Text pre okno "Kto používa": zamestnanci, ktorí majú fond ("F") alebo šablónu ("S") platný v mesiaci, a tí, ktorí ho majú
' len v inom období (najviac 12 mien v každej skupine, aby sa text zmestil do správy).
'-------------------------------------------------------------------------------
Public Function TextPouzivajucich(ByVal strTyp As String, ByVal lKod As Long, ByVal iRok As Integer, ByVal iMes As Integer) As String
    Dim s As String, sV As String, sI As String, nV As Long, nI As Long, p As Long, t As String
    On Error GoTo Chyba
    s = ZoznamPouzivajucich(strTyp, lKod, iRok, iMes, nV, nI, 12)
    p = InStr(s, "|")
    If p > 0 Then
        sV = Left$(s, p - 1)
        sI = Mid$(s, p + 1)
    Else
        sV = s
    End If
    t = "V mesiaci " & iMes & "/" & iRok & " platí pre " & nV & " zamestnancov."
    If Len(sV) > 0 Then t = t & vbCrLf & sV
    If nI > 0 Then
        t = t & vbCrLf & "Len v inom období (v tomto mesiaci majú iné priradenie): " & nI & vbCrLf & sI
    End If
    If Len(t) > 1000 Then t = Left$(t, 996) & "..."
    TextPouzivajucich = t
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_17_FondyPravidla.TextPouzivajucich", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Nový fond z predvoľby (PredvolbaFondu): založí fond s najbližším voľným číslom a jednou verziou platnou od mesiaca.
' Vráti číslo nového fondu; pri chybe 0 a text v strChyba.
'-------------------------------------------------------------------------------
Public Function NovyFondZPredvolby(ByVal strNazov As String, ByVal lPredvolba As Long, ByVal iRok As Integer, ByVal iMes As Integer, _
                                   ByRef strChyba As String) As Long
    Dim d As Object, lNovy As Long
    On Error GoTo Chyba
    strChyba = ""
    strNazov = Trim$(strNazov)
    If Len(strNazov) = 0 Then strChyba = "Zadajte názov fondu.": Exit Function
    Set d = CreateObject("Scripting.Dictionary")
    If Not PredvolbaFondu(lPredvolba, d) Then strChyba = "Neznáma predvoľba.": Exit Function
    Call mod_15_Zamestnanci.ZabezpecModel(CurrentDb)
    lNovy = mod_15_Zamestnanci.NasledneCislo("PracovneFondy", "Cislo", "ZamestnanciFondy", "PracFondKod")
    If lNovy <= 0 Then strChyba = "Nepodarilo sa určiť číslo nového fondu.": Exit Function
    d("Nazov") = strNazov
    strChyba = UlozFond(lNovy, iRok, iMes, d)
    If Len(strChyba) = 0 Then NovyFondZPredvolby = lNovy
    Exit Function
Chyba:
    strChyba = "Nový fond sa nepodarilo vytvoriť: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_17_FondyPravidla.NovyFondZPredvolby", "ERROR", Err.Description)
End Function

'===============================================================================
' PREDVOLENÝ FOND, ŠABLÓNA A KALENDÁR (tlačidlo INICIALIZOVAŤ PREDVOLENÚ KONFIGURÁCIU)
'===============================================================================

'-------------------------------------------------------------------------------
' Mesiac, od ktorého platia predvolené nastavenia: mesiac najstaršieho razenia, ak je starší ako január aktuálneho roka,
' inak január aktuálneho roka. Pre staršie mesiace platí najstaršia verzia (pozri PlatnaVerzia), mesiac teda výpočet nemení.
'-------------------------------------------------------------------------------
Private Sub ZaciatokPredvolenychNastaveni(ByRef iRok As Integer, ByRef iMes As Integer)
    Dim v As Variant
    iRok = Year(Date)
    iMes = 1
    On Error Resume Next
    If mod_00_Common.TabulkaExistuje("DochadzkaImport") Then
        v = DMin("Datum", "DochadzkaImport")
        If Not IsNull(v) Then
            If CDate(v) < DateSerial(iRok, 1, 1) And Year(CDate(v)) >= 1990 Then
                iRok = Year(CDate(v))
                iMes = Month(CDate(v))
            End If
        End If
    End If
    Err.Clear
End Sub

'-------------------------------------------------------------------------------
' Doplní predvolený pracovný fond (pružný, denný fond z nastavenia PredvolenyFondMin = 7:30, bez časového okna), šablónu pravidiel
' prerušení bez kontroly a kalendár (pracovné dni Po-Pi + štátne sviatky) a priradí ich zamestnancom, ktorí nemajú žiadne priradenie.
' Nič sa neprepisuje: fond vznikne len v databáze bez fondov, šablóna len bez šablón, kalendár len bez kalendárov; priradenie dostanú
' len zamestnanci bez riadku v ZamestnanciFondy. Ak fondy, šablóny alebo kalendáre už sú, použije sa ten s číslom 1, ak existuje.
' Priradenie je rovnaké, aké výpočet použije pre zamestnanca bez priradenia (fond, šablóna a kalendár č. 1, doterajší úväzok),
' výsledky výpočtu sa teda nemenia; nastavenie je len viditeľné a vyberie sa do exportu pre terminál.
' Vráti počet pridaných záznamov (fond + šablóna + kalendár + priradenia), -1 pri chybe. strSprava = prehľad pre používateľa.
'-------------------------------------------------------------------------------
Public Function DoplnPredvolenyFondASablonu(ByRef strSprava As String) As Long
    On Error GoTo Chyba
    Dim db As DAO.Database, d As Object, rs As DAO.Recordset, rsA As DAO.Recordset, v As Variant
    Dim iRok As Integer, iMes As Integer, n As Long, nZam As Long, bVytvorene As Boolean
    Dim lFond As Long, lSab As Long, lKal As Long, lDenny As Long, strErr As String, strOC As String

    strSprava = ""
    Set db = CurrentDb
    For Each v In Array("PracovneFondy", "ParametrePreruseni", "Kalendare", "ZamestnanciFondy", "Zamestnanci")
        If Not mod_00_Common.TabulkaExistujeDB(db, CStr(v)) Then
            strSprava = "Chýba tabuľka " & CStr(v) & " - najprv spustite inicializáciu databázy."
            DoplnPredvolenyFondASablonu = -1
            Exit Function
        End If
    Next v
    Call mod_15_Zamestnanci.ZabezpecModel(db)
    Call ZaciatokPredvolenychNastaveni(iRok, iMes)

    ' pracovný fond
    If Nz(DCount("*", "PracovneFondy"), 0) = 0 Then
        lDenny = CLng(Val(mod_00_Common.GetNastavenie("PredvolenyFondMin", "450")))
        If lDenny <= 0 Or lDenny > 1440 Then lDenny = 450
        Set d = CreateObject("Scripting.Dictionary")
        d("Nazov") = "Pracovný fond " & MinutyNaText(lDenny) & " (predvolený)"
        d("Typ") = 2: d("Denny") = lDenny: d("Mesacny") = 0: d("PodlaDna") = False
        lFond = mod_15_Zamestnanci.NasledneCislo("PracovneFondy", "Cislo", "ZamestnanciFondy", "PracFondKod")
        strErr = UlozFond(lFond, iRok, iMes, d)
        If Len(strErr) > 0 Then strSprava = strErr: DoplnPredvolenyFondASablonu = -1: Exit Function
        n = n + 1
        bVytvorene = True
        strSprava = strSprava & "Pracovný fond č. " & lFond & " '" & CStr(d("Nazov")) & "': pružný, denný fond " & MinutyNaText(lDenny) & ", bez časového okna, od " & iMes & "/" & iRok & "." & vbCrLf
    Else
        If Nz(DCount("*", "PracovneFondy", "Cislo = 1"), 0) > 0 Then lFond = 1
        strSprava = strSprava & "Pracovné fondy už existujú - nemenili sa." & vbCrLf
    End If

    ' šablóna pravidiel prerušení (jedno vypnuté pravidlo, aby šablóna existovala; pravidlá sa tak nekontrolujú)
    If Nz(DCount("*", "ParametrePreruseni"), 0) = 0 Then
        Set d = CreateObject("Scripting.Dictionary")
        Call PredvolbaPravidla(1, d)
        d("Nazov") = "Pracovná doba"
        lSab = mod_15_Zamestnanci.NasledneCislo("ParametrePreruseni", "Sablona", "ZamestnanciFondy", "ParPrerKod")
        strErr = UlozPravidlo(lSab, 1, iRok, iMes, d)
        If Len(strErr) > 0 Then strSprava = strSprava & strErr: DoplnPredvolenyFondASablonu = -1: Exit Function
        db.Execute "UPDATE ParametrePreruseni SET NazovSablony = 'Základná (bez kontroly)' WHERE Sablona = " & lSab & ";", dbFailOnError
        n = n + 1
        bVytvorene = True
        strSprava = strSprava & "Šablóna pravidiel prerušení č. " & lSab & " 'Základná (bez kontroly)': pravidlá prerušení sa nekontrolujú." & vbCrLf
    Else
        If Nz(DCount("*", "ParametrePreruseni", "Sablona = 1"), 0) > 0 Then lSab = 1
        strSprava = strSprava & "Šablóny pravidiel už existujú - nemenili sa." & vbCrLf
    End If

    ' kalendár: bez vlastných dní, platí pracovný týždeň Po-Pi a štátne sviatky z tabuľky Sviatky
    If Nz(DCount("*", "Kalendare"), 0) = 0 Then
        lKal = mod_15_Zamestnanci.NasledneCislo("Kalendare", "Cislo", "ZamestnanciFondy", "KalendarKod")
        Set rs = db.OpenRecordset("SELECT * FROM Kalendare WHERE 1 = 0;", dbOpenDynaset)
        rs.AddNew
        Call NulujNovyRiadok(rs)
        rs!Cislo = lKal
        rs!Rok = iRok
        rs!Mesiac = iMes
        rs!Nazov = "Pracovné dni Po-Pi, sviatky SR"
        rs.Update
        rs.Close
        n = n + 1
        bVytvorene = True
        strSprava = strSprava & "Kalendár č. " & lKal & " 'Pracovné dni Po-Pi, sviatky SR'." & vbCrLf
    Else
        If Nz(DCount("*", "Kalendare", "Cislo = 1"), 0) > 0 Then lKal = 1
        strSprava = strSprava & "Kalendáre už existujú - nemenili sa." & vbCrLf
    End If

    ' priradenie zamestnancom, ktorí nemajú žiadne
    If lFond > 0 And lSab > 0 And lKal > 0 Then
        Set rs = db.OpenRecordset("SELECT DISTINCT Z.OsobneCislo FROM Zamestnanci AS Z LEFT JOIN ZamestnanciFondy AS F ON Z.OsobneCislo = F.OsobneCislo " & _
                                  "WHERE Z.OsobneCislo Is Not Null AND F.OsobneCislo Is Null;", dbOpenSnapshot)
        Set rsA = db.OpenRecordset("SELECT * FROM ZamestnanciFondy WHERE 1 = 0;", dbOpenDynaset)
        Do While Not rs.EOF
            strOC = Trim$(CStr(Nz(rs!OsobneCislo, "")))
            If Len(strOC) > 0 Then
                rsA.AddNew
                rsA!OsobneCislo = strOC
                rsA!Rok = iRok
                rsA!Mesiac = iMes
                rsA!PracFondKod = lFond
                rsA!ParPrerKod = lSab
                rsA!KalendarKod = lKal
                rsA!ParDochKod = 1
                On Error Resume Next
                rsA.Fields("UvazokPercent").Value = mod_15_Zamestnanci.UvazokZamestnanca(db, strOC)
                Err.Clear
                On Error GoTo Chyba
                rsA.Update
                nZam = nZam + 1
            End If
            rs.MoveNext
        Loop
        rsA.Close
        rs.Close
        If nZam > 0 Then
            strSprava = strSprava & "Priradené zamestnancom bez priradenia: " & nZam & " (fond " & lFond & ", šablóna " & lSab & ", kalendár " & lKal & ", od " & iMes & "/" & iRok & ")." & vbCrLf
        Else
            strSprava = strSprava & "Všetci zamestnanci už majú priradenie." & vbCrLf
        End If
    Else
        strSprava = strSprava & "Priradenie zamestnancom sa nerobilo: fond, šablóna a kalendár č. 1 nie sú všetky v databáze (priraďte ručne na karte Zamestnanci)." & vbCrLf
    End If

    n = n + nZam
    If n > 0 Then
        Call mod_15_Zamestnanci.Zam_ZrusCache
        Call mod_08_UdalostiDna.ObnovParametre
        Call mod_18_Uzavierka.OznacNastaveniaLokalne
    End If
    If bVytvorene Then
        Call mod_00_Common.SetNastavenie("PredvolenePracovneNastavenia", Format$(Now, "yyyy-mm-dd hh:nn"), "Predvolený fond, šablóna alebo kalendár vytvorené tlačidlom INICIALIZOVAŤ PREDVOLENÚ KONFIGURÁCIU (import zo staršej databázy ich zmieša s importovanými)")
    End If
    Call mod_00_Common.ZapisLog("mod_17_FondyPravidla.DoplnPredvolenyFondASablonu", "INFO", "Pridaných záznamov: " & n, strSprava)
    DoplnPredvolenyFondASablonu = n
    Exit Function
Chyba:
    strSprava = strSprava & "CHYBA: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_17_FondyPravidla.DoplnPredvolenyFondASablonu", "ERROR", Err.Description, strSprava)
    DoplnPredvolenyFondASablonu = -1
End Function
