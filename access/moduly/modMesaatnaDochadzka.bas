Attribute VB_Name = "modMesaatnaDochadzka"
'@Verzia 2.9.0
Option Compare Database
Option Explicit

' Cache názvov prerušení (musí byť deklarovaná pred prvou procedúrou modulu)
Private mDicNazvy As Object

'-------------------------------------------------------------------------------
' Prepočíta dochádzku jedného zamestnanca za mesiac (automatické opravy, intervaly, denné a mesačné sumáre).
' Jediný vstupný bod výpočtu - používa ho zostava, editor aj hromadný výpočet.
'-------------------------------------------------------------------------------
Public Sub PrepocitajMesiac(ByRef db As DAO.Database, ByVal strOC As String, ByVal iRok As Integer, ByVal iMesiac As Integer, _
                            Optional ByVal bAutoAnalyza As Boolean = True)
    On Error GoTo Err_Handler
    Call ZabezpecStrukturuPreVypocet(db)
    ' uzavretý (podpísaný) mesiac sa neprepočítava - zostava sa tlačí z uložených údajov
    If mod_18_Uzavierka.JeUzavrety(strOC, iRok, iMesiac) Then
        If mod_18_Uzavierka.PrepocetZakazany(db, strOC, iRok, iMesiac) Then Exit Sub
        bAutoAnalyza = False    ' výpočtové riadky chýbajú (napr. po prenose databázy) - dopočítajú sa iba z uzavretých razení
    End If
    If bAutoAnalyza Then Call mod_09_AutoOprava.AnalyzujMesiacZamestnanca(db, strOC, iRok, iMesiac)
    Call VymazStareVypocty(db, strOC, iRok, iMesiac)
    Call GenerujDniAIntervaly(db, strOC, iRok, iMesiac)
    Call GenerujMesacnySumar(db, strOC, iRok, iMesiac)
    Exit Sub
Err_Handler:
    Call ZapisChybuDoTabulky("PrepocitajMesiac", Err.Number, Err.Description, "OsobneCislo=" & strOC & ", " & iMesiac & "/" & iRok)
End Sub

'-------------------------------------------------------------------------------
' Vypočíta dochádzku pre jedného zamestnanca a otvorí tlačovú zostavu v náhľade.
'-------------------------------------------------------------------------------
Public Sub SpracujAOtvorZostavu( _
    ByVal strOsobneCislo As String, _
    ByVal iRok As Integer, _
    ByVal iMesiac As Integer, _
    Optional ByVal strNazovZostavy As String = "rptMesaatnaDochadzka")

    On Error GoTo Err_Handler
    Dim db As DAO.Database: Set db = CurrentDb
    Dim strWhere As String

    Call ZabezpecStrukturuPreVypocet(db)
    Call ZabezpecExistenciuZostavy(strNazovZostavy, iRok, iMesiac)
    If Not mod_09_AutoOprava.PripravAOveriMesiac(strOsobneCislo, iRok, iMesiac) Then GoTo Exit_Handler
    Call PrepocitajMesiac(db, strOsobneCislo, iRok, iMesiac)
    Call mod_18_Uzavierka.ZaznamenajZostavu(strOsobneCislo, iRok, iMesiac)

    strWhere = "OsobneCislo = " & mod_00_Common.SqlText(strOsobneCislo) & _
               " AND Datum >= " & mod_00_Common.SqlDatum(DateSerial(iRok, iMesiac, 1)) & _
               " AND Datum < " & mod_00_Common.SqlDatum(DateSerial(iRok, iMesiac + 1, 1))

    Call mod_UI_Core.UI_ZobrazPasKariet   ' náhľad zostavy potrebuje pás kariet (tlač, zatvorenie)
    DoCmd.OpenReport ReportName:=strNazovZostavy, View:=acViewPreview, WhereCondition:=strWhere

Exit_Handler:
    Set db = Nothing
    Exit Sub

Err_Handler:
    Dim lErrNum As Long, strErrDesc As String
    lErrNum = Err.Number: strErrDesc = Err.Description
    Call ZapisChybuDoTabulky("SpracujAOtvorZostavu", lErrNum, strErrDesc, "OsobneCislo=" & strOsobneCislo & ", Rok=" & iRok & ", Mesiac=" & iMesiac)
    MsgBox "Pri výpočte dochádzky nastala chyba:" & vbCrLf & "Chyba " & lErrNum & ": " & strErrDesc, vbCritical, "Chyba " & lErrNum
    Resume Exit_Handler
End Sub

'-------------------------------------------------------------------------------
' Prepočíta intervaly, denné a mesačné sumáre dochádzky bez otvárania tlačovej zostavy.
'-------------------------------------------------------------------------------
Public Sub PrecalculujDochadzkuBezZostavy(ByVal strOsobneCislo As String, ByVal iRok As Integer, ByVal iMesiac As Integer)
    Dim db As DAO.Database
    Set db = CurrentDb
    Call PrepocitajMesiac(db, strOsobneCislo, iRok, iMesiac)
    Set db = Nothing
End Sub

'-------------------------------------------------------------------------------
' Zapíše intervaly a denné sumáre jedného zamestnanca za mesiac na základe jadra mod_08_UdalostiDna.
'-------------------------------------------------------------------------------
Private Sub GenerujDniAIntervaly(ByRef db As DAO.Database, ByVal strOC As String, ByVal iRok As Integer, ByVal iMesiac As Integer)
    On Error GoTo Err_Handler
    Dim u() As TUdalost, n As Long, i As Long, i1 As Long, j As Long, iDen As Integer
    Dim r As TVysledokDna, k As TKontextMesiaca
    Dim rsIv As DAO.Recordset, rsDni As DAO.Recordset
    Dim dDen As Date, lFond As Long, lOdpr As Long, lPrek As Long, lSpolu As Long, lSaldo As Long, lPrieb As Long
    Dim strAn As String, bAuto As Boolean, bMaAuto As Boolean, bMaAnom As Boolean, lRez() As Long

    n = mod_08_UdalostiDna.NacitajUdalosti(db, strOC, DateSerial(iRok, iMesiac, 1), DateSerial(iRok, iMesiac + 1, 1), u)
    Call mod_08_UdalostiDna.NacitajKontextMesiaca(db, strOC, iRok, iMesiac, k)
    Call mod_21_RezimyVypoctu.RezimyMesiaca(db, strOC, iRok, iMesiac, lRez)      ' režim výpočtu pre každý deň mesiaca (0 = bez režimu)

    Set rsIv = db.OpenRecordset("SELECT * FROM DochadzkaIntervaly WHERE ID = 0;", dbOpenDynaset, dbAppendOnly)
    Set rsDni = db.OpenRecordset("SELECT * FROM DochadzkaDni WHERE ID = 0;", dbOpenDynaset, dbAppendOnly)
    bMaAnom = mod_00_Common.PoleExistujeDB(db, "DochadzkaDni", "Anomalia")
    bMaAuto = mod_00_Common.PoleExistujeDB(db, "DochadzkaDni", "AutoOprava")

    i = 1
    For iDen = 1 To k.PocetDni
        dDen = DateSerial(iRok, iMesiac, iDen)
        lFond = k.Fond(iDen)
        Call mod_08_UdalostiDna.NastavRezimVypoctu(lRez(iDen))     ' pravidlá a úpravy prerušení platné v tento deň
        Do While i <= n
            If u(i).Datum < dDen Then
                i = i + 1
            Else
                Exit Do
            End If
        Loop

        r.nIv = 0: r.nAn = 0
        bAuto = False: strAn = ""
        If i <= n Then
            If u(i).Datum = dDen Then
                i1 = mod_08_UdalostiDna.HranicaDna(u, n, i)
                Call mod_08_UdalostiDna.SpracujDen(u, i, i1, r)
                For j = i To i1
                    If u(j).Zdroj <> 0 Then bAuto = True
                Next j
                i = i1 + 1
            End If
        End If

        Call mod_08_UdalostiDna.UplatniZaokruhlenie(r)     ' zaokrúhlenie podľa pravidiel výpočtu (predvolene vypnuté)
        Call ZoradIntervaly(r)
        For j = 1 To r.nIv
            Call ZapisInterval(rsIv, strOC, dDen, j, r.Iv(j), lFond)
        Next j

        Call mod_08_UdalostiDna.SumarDna(r, lFond, lOdpr, lPrek)
        lSpolu = lOdpr + lPrek
        lSaldo = lSpolu - lFond
        lPrieb = lPrieb + lSaldo

        For j = 1 To r.nAn
            If r.An(j).Kod <> "DUPLICITA" Then
                If InStr(strAn, r.An(j).Kod) = 0 Then
                    If Len(strAn) > 0 Then strAn = strAn & ","
                    strAn = strAn & r.An(j).Kod
                End If
            End If
        Next j

        rsDni.AddNew
        rsDni!OsobneCislo = strOC
        rsDni!Datum = dDen
        rsDni!TypDna = k.Typ(iDen)
        rsDni!DennyFondMin = lFond
        rsDni!OdpracovaneMin = lSpolu
        rsDni!SaldoMin = lSaldo
        rsDni!PriebezneSaldoMin = lPrieb
        If bMaAnom Then rsDni!Anomalia = Left$(strAn, 100)
        If bMaAuto Then rsDni!AutoOprava = bAuto
        rsDni.Update
    Next iDen

    Call mod_08_UdalostiDna.NastavRezimVypoctu(0)
    rsIv.Close: rsDni.Close
    Exit Sub
Err_Handler:
    Call mod_08_UdalostiDna.NastavRezimVypoctu(0)
    Call ZapisChybuDoTabulky("GenerujDniAIntervaly", Err.Number, Err.Description, "OsobneCislo=" & strOC)
End Sub

'-------------------------------------------------------------------------------
' Zoradí intervaly dňa podľa času začiatku (potom konca) - zodpovedá poradiu na zostave.
'-------------------------------------------------------------------------------
Private Sub ZoradIntervaly(ByRef r As TVysledokDna)
    Dim i As Long, j As Long, t As TInterval
    For i = 2 To r.nIv
        t = r.Iv(i)
        j = i - 1
        Do While j >= 1
            If r.Iv(j).Zac > t.Zac Or (r.Iv(j).Zac = t.Zac And r.Iv(j).Kon > t.Kon) Then
                r.Iv(j + 1) = r.Iv(j)
                j = j - 1
            Else
                Exit Do
            End If
        Loop
        r.Iv(j + 1) = t
    Next i
End Sub

'-------------------------------------------------------------------------------
' Zapíše jeden interval do DochadzkaIntervaly ("r" = razený čas, "a" = doplnené automatickou opravou).
'-------------------------------------------------------------------------------
Private Sub ZapisInterval(ByRef rs As DAO.Recordset, ByVal strOC As String, ByVal dDen As Date, ByVal iPoradie As Integer, _
                          ByRef iv As TInterval, ByVal lFond As Long)
    Dim lTrv As Long, strZ As String, strK As String, strP As String, bRZ As Boolean, bRK As Boolean
    If iv.Kon < iv.Zac Then Exit Sub
    If iv.Kon = iv.Zac And iv.Cislo = 1 Then Exit Sub     ' nulová pracovná dĺžka sa nezapisuje
    lTrv = mod_08_UdalostiDna.TrvanieIntervalu(iv.Cislo, iv.Zac, iv.Kon, lFond)

    strZ = mod_00_Common.MinutyNaCasText(iv.Zac)
    strK = mod_00_Common.MinutyNaCasText(iv.Kon)
    If iv.Cislo = 1 Then
        bRZ = (Not iv.ZacAuto) And (Not iv.ZacRezum)
        bRK = Not iv.KonAuto
        If bRZ Then strZ = strZ & "r"
        If bRK Then strK = strK & "r"
        If bRZ Or bRK Then strP = "r"
    End If
    If iv.ZacAuto Or iv.KonAuto Then strP = strP & "a"

    rs.AddNew
    rs!OsobneCislo = strOC
    rs!Datum = dDen
    rs!Poradie = iPoradie
    rs!CisloPreruseni = iv.Cislo
    rs!NazovPreruseni = Left$(ZistiNazovPrerusenia(iv.Cislo), 50)
    rs!ZaciatokMin = iv.Zac
    rs!KoniecMin = iv.Kon
    rs!ZaciatokText = strZ
    rs!KoniecText = strK
    rs!TrvanieMin = lTrv
    rs!Poznamka = strP
    rs.Update
End Sub


'-------------------------------------------------------------------------------
' Vracia plný názov prerušenia podľa jeho čísla (s cache - číselník sa číta raz).
'-------------------------------------------------------------------------------
Private Function ZistiNazovPrerusenia(ByVal lCislo As Long) As String
    Dim rs As DAO.Recordset
    On Error Resume Next
    If mDicNazvy Is Nothing Then
        Set mDicNazvy = CreateObject("Scripting.Dictionary")
        Set rs = CurrentDb.OpenRecordset("SELECT Cislo, Nazov FROM CiselnikPreruseni;", dbOpenSnapshot)
        If Not rs Is Nothing Then
            Do While Not rs.EOF
                mDicNazvy(CLng(rs!Cislo)) = CStr(Nz(rs!Nazov, ""))
                rs.MoveNext
            Loop
            rs.Close
        End If
    End If
    If mDicNazvy.Exists(lCislo) Then
        ZistiNazovPrerusenia = mDicNazvy(lCislo)
    ElseIf lCislo = 1 Then
        ZistiNazovPrerusenia = "Pracovná doba"
    Else
        ZistiNazovPrerusenia = "Prerušenie " & lCislo
    End If
End Function

'-------------------------------------------------------------------------------
' Zahodí cache názvov prerušení a parametrov (volať po úprave číselníka alebo pravidiel).
'-------------------------------------------------------------------------------
Public Sub ObnovCacheNazvov()
    Set mDicNazvy = Nothing
    Call mod_08_UdalostiDna.ObnovParametre
End Sub

'-------------------------------------------------------------------------------
' Generuje mesačný sumár (odpracované dni a minúty, fond, stav mesiaca) do DochadzkaMesiacSumar.
'-------------------------------------------------------------------------------
Private Sub GenerujMesacnySumar(ByRef db As DAO.Database, ByVal strOC As String, ByVal iRok As Integer, ByVal iMesiac As Integer)
    On Error GoTo Err_Handler
    If Not mod_00_Common.TabulkaExistujeDB(db, "DochadzkaMesiacSumar") Or Not mod_00_Common.TabulkaExistujeDB(db, "DochadzkaDni") Then Exit Sub

    Dim strSQL As String
    strSQL = "INSERT INTO DochadzkaMesiacSumar (OsobneCislo, Rok, Mesiac, OdpracovaneDni, OdpracovaneMin, StavMesiacaMin, MesacnyFondMin, MesacnyFondDni) " & _
             "SELECT OsobneCislo, " & iRok & ", " & iMesiac & ", " & _
             "SUM(IIf(OdpracovaneMin > 0, 1, 0)), SUM(OdpracovaneMin), SUM(SaldoMin), SUM(DennyFondMin), SUM(IIf(DennyFondMin > 0, 1, 0)) " & _
             "FROM DochadzkaDni " & _
             "WHERE OsobneCislo = " & mod_00_Common.SqlText(strOC) & _
             " AND Datum >= " & mod_00_Common.SqlDatum(DateSerial(iRok, iMesiac, 1)) & _
             " AND Datum < " & mod_00_Common.SqlDatum(DateSerial(iRok, iMesiac + 1, 1)) & _
             " GROUP BY OsobneCislo;"
    db.Execute strSQL, dbFailOnError
    Exit Sub
Err_Handler:
    Call ZapisChybuDoTabulky("GenerujMesacnySumar", Err.Number, Err.Description, "OsobneCislo=" & strOC)
End Sub

'-------------------------------------------------------------------------------
' Overuje a dopĺňa chýbajúce stĺpce vo výpočtových tabuľkách.
'-------------------------------------------------------------------------------
Private Sub ZabezpecStrukturuPreVypocet(ByRef db As DAO.Database)
    On Error Resume Next
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaIntervaly") Then
        If Not mod_00_Common.PoleExistujeDB(db, "DochadzkaIntervaly", "Poznamka") Then db.Execute "ALTER TABLE DochadzkaIntervaly ADD COLUMN Poznamka TEXT(50);", dbFailOnError
    End If
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaDni") Then
        If Not mod_00_Common.PoleExistujeDB(db, "DochadzkaDni", "Anomalia") Then db.Execute "ALTER TABLE DochadzkaDni ADD COLUMN Anomalia TEXT(100);", dbFailOnError
        If Not mod_00_Common.PoleExistujeDB(db, "DochadzkaDni", "AutoOprava") Then db.Execute "ALTER TABLE DochadzkaDni ADD COLUMN AutoOprava YESNO;", dbFailOnError
    End If
End Sub

'-------------------------------------------------------------------------------
' Vymaže prepočítané (odvodené) dáta zamestnanca za mesiac pred novým výpočtom.
' Pozor: ide iba o odvodené tabuľky - pôvodné razenia sa nikdy nemažú.
'-------------------------------------------------------------------------------
Private Sub VymazStareVypocty(ByRef db As DAO.Database, ByVal strOC As String, ByVal iRok As Integer, ByVal iMesiac As Integer)
    On Error GoTo Err_Handler
    Dim strRozsah As String
    strRozsah = "OsobneCislo = " & mod_00_Common.SqlText(strOC) & _
                " AND Datum >= " & mod_00_Common.SqlDatum(DateSerial(iRok, iMesiac, 1)) & _
                " AND Datum < " & mod_00_Common.SqlDatum(DateSerial(iRok, iMesiac + 1, 1))

    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaIntervaly") Then db.Execute "DELETE FROM DochadzkaIntervaly WHERE " & strRozsah & ";", dbFailOnError
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaDni") Then db.Execute "DELETE FROM DochadzkaDni WHERE " & strRozsah & ";", dbFailOnError
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaMesiacSumar") Then
        db.Execute "DELETE FROM DochadzkaMesiacSumar WHERE OsobneCislo = " & mod_00_Common.SqlText(strOC) & " AND Rok = " & iRok & " AND Mesiac = " & iMesiac & ";", dbFailOnError
    End If
    Exit Sub
Err_Handler:
    Call ZapisChybuDoTabulky("VymazStareVypocty", Err.Number, Err.Description, "OsobneCislo=" & strOC)
End Sub

'-------------------------------------------------------------------------------
' Prepočíta dochádzku a otvorí tlačenú zostavu pre skupinu vybraných zamestnancov.
'-------------------------------------------------------------------------------
Public Sub SpracujAOtvorZostavuMulti( _
    ByVal strOsobneCislaSQL As String, _
    ByVal iRok As Integer, _
    ByVal iMesiac As Integer, _
    Optional ByVal strNazovZostavy As String = "rptMesaatnaDochadzka")

    On Error GoTo Err_Handler
    Dim db As DAO.Database: Set db = CurrentDb
    Dim rsEmp As DAO.Recordset
    Dim strSQL As String, strWhereOsc As String, strWhere As String, osc As String

    Call ZabezpecStrukturuPreVypocet(db)
    Call ZabezpecExistenciuZostavy(strNazovZostavy, iRok, iMesiac)

    If Len(Trim$(strOsobneCislaSQL)) > 0 Then
        strSQL = "SELECT DISTINCT OsobneCislo FROM Zamestnanci WHERE OsobneCislo IN (" & strOsobneCislaSQL & ");"
        strWhereOsc = "OsobneCislo IN (" & strOsobneCislaSQL & ") AND "
    Else
        strSQL = "SELECT DISTINCT OsobneCislo FROM Zamestnanci WHERE OsobneCislo IS NOT NULL AND " & _
                 mod_15_Zamestnanci.SqlAktivny("", DateSerial(iRok, iMesiac, 1)) & ";"
        ' bez výberu: zo zostavy sa vynechajú vyradení zamestnanci
        strWhereOsc = Mid$(mod_15_Zamestnanci.SqlVynechVyradenych("OsobneCislo", DateSerial(iRok, iMesiac, 1)), 6)
        If Len(strWhereOsc) > 0 Then strWhereOsc = strWhereOsc & " AND "
    End If

    If Not mod_09_AutoOprava.PripravAOveriMesiac("", iRok, iMesiac, strOsobneCislaSQL) Then GoTo Exit_Handler

    Set rsEmp = db.OpenRecordset(strSQL, dbOpenSnapshot)
    Do While Not rsEmp.EOF
        osc = CStr(Nz(rsEmp!OsobneCislo, ""))
        If Len(osc) > 0 Then
            Call PrepocitajMesiac(db, osc, iRok, iMesiac)
            Call mod_18_Uzavierka.ZaznamenajZostavu(osc, iRok, iMesiac)
        End If
        rsEmp.MoveNext
    Loop
    rsEmp.Close: Set rsEmp = Nothing

    strWhere = strWhereOsc & "Datum >= " & mod_00_Common.SqlDatum(DateSerial(iRok, iMesiac, 1)) & _
               " AND Datum < " & mod_00_Common.SqlDatum(DateSerial(iRok, iMesiac + 1, 1))

    Call mod_UI_Core.UI_ZobrazPasKariet   ' náhľad zostavy potrebuje pás kariet (tlač, zatvorenie)
    DoCmd.OpenReport ReportName:=strNazovZostavy, View:=acViewPreview, WhereCondition:=strWhere

Exit_Handler:
    Set db = Nothing
    Exit Sub

Err_Handler:
    MsgBox "Pri výpočte dochádzky pre zostavu nastala chyba: " & Err.Description, vbCritical
    Resume Exit_Handler
End Sub


'-------------------------------------------------------------------------------
' Sostavuje podrobný textový priebeh razení a prerušení pre konkrétny deň.
'-------------------------------------------------------------------------------
Public Function ZiskajDetailyDna(ByVal strOsobneCislo As String, ByVal dDatum As Date) As String
    On Error GoTo Err_Handler
    Dim db As DAO.Database: Set db = CurrentDb
    If Not mod_00_Common.TabulkaExistujeDB(db, "DochadzkaIntervaly") Then Exit Function

    Dim rs As DAO.Recordset
    Dim strSQL As String, strVystup As String
    Dim bHasLunch As Boolean: bHasLunch = False
    Dim lTotalWorkMin As Long: lTotalWorkMin = 0

    strSQL = "SELECT * FROM DochadzkaIntervaly " & _
             "WHERE OsobneCislo = '" & strOsobneCislo & "' AND Datum = #" & Format(dDatum, "mm\/dd\/yyyy") & "# " & _
             "ORDER BY Poradie, ZaciatokMin;"

    Set rs = db.OpenRecordset(strSQL, dbOpenSnapshot)
    Do While Not rs.EOF
        Dim lCisloPrer As Long
        lCisloPrer = CLng(Val(mod_00_Common.ZiskajHodnotuPola(rs, "CisloPreruseni", 1)))

        If lCisloPrer = 7 Or lCisloPrer = 110 Or lCisloPrer = 111 Then
            bHasLunch = True
        End If

        If lCisloPrer = 1 Then
            lTotalWorkMin = lTotalWorkMin + CLng(Val(mod_00_Common.ZiskajHodnotuPola(rs, "TrvanieMin", 0)))
        End If

        If Len(strVystup) > 0 Then strVystup = strVystup & " | "
        strVystup = strVystup & CStr(mod_00_Common.ZiskajHodnotuPola(rs, "NazovPreruseni", "")) & " " & CStr(mod_00_Common.ZiskajHodnotuPola(rs, "ZaciatokText", "")) & "-" & CStr(mod_00_Common.ZiskajHodnotuPola(rs, "KoniecText", ""))
        rs.MoveNext
    Loop
    rs.Close: Set rs = Nothing

    If lTotalWorkMin > 360 And Not bHasLunch Then
        If Len(strVystup) > 0 Then strVystup = strVystup & " | "
        strVystup = strVystup & "Obed [auto] 11:30-12:00"
    End If

    ZiskajDetailyDna = strVystup
    Exit Function

Err_Handler:
    Call ZapisChybuDoTabulky("ZiskajDetailyDna", Err.Number, Err.Description, "OsobneCislo=" & strOsobneCislo)
    ZiskajDetailyDna = ""
End Function

'-------------------------------------------------------------------------------
' Generuje sumárny text čerpania jednotlivých typov prerušení za mesiac pre pätku výkazu.
'-------------------------------------------------------------------------------
Public Function ZiskajTextCerpaniaPreruseni( _
    ByVal strOsobneCislo As String, _
    ByVal iRok As Integer, _
    ByVal iMesiac As Integer) As String

    On Error GoTo Err_Handler
    Dim db As DAO.Database: Set db = CurrentDb
    
    If Not mod_00_Common.TabulkaExistujeDB(db, "DochadzkaIntervaly") Then
        ZiskajTextCerpaniaPreruseni = ""
        Exit Function
    End If

    Dim dOd As Date, dDo As Date
    dOd = DateSerial(iRok, iMesiac, 1)
    dDo = DateSerial(iRok, iMesiac + 1, 0)

    Dim strSQL As String
    strSQL = "SELECT I.CisloPreruseni, " & _
             "First(I.NazovPreruseni) AS NazovInt, " & _
             "SUM(I.TrvanieMin) AS SpoluMin " & _
             "FROM DochadzkaIntervaly AS I " & _
             "WHERE I.OsobneCislo = '" & strOsobneCislo & "' " & _
             "AND I.Datum >= #" & Format(dOd, "mm\/dd\/yyyy") & "# AND I.Datum <= #" & Format(dDo, "mm\/dd\/yyyy") & "# " & _
             "AND I.CisloPreruseni NOT IN (7) " & _
             "GROUP BY I.CisloPreruseni " & _
             "ORDER BY I.CisloPreruseni;"

    Dim rs As DAO.Recordset
    Set rs = db.OpenRecordset(strSQL, dbOpenSnapshot)

    Dim strVystup As String: strVystup = ""
    Dim lCisloPrer As Long, lMin As Long, lHod As Long, lZvySok As Long
    Dim strSkratka As String

    Do While Not rs.EOF
        lCisloPrer = CLng(Val(Nz(rs!CisloPreruseni, 1)))
        lMin = CLng(Val(Nz(rs!SpoluMin, 0)))
        strSkratka = ZistiSkratkuPrerusenia(db, lCisloPrer)

        lHod = lMin \ 60
        lZvySok = lMin Mod 60

        If strVystup <> "" Then strVystup = strVystup & "  |  "
        strVystup = strVystup & lCisloPrer & "-" & strSkratka & ": " & _
                    Format(lHod, "00") & ":" & Format(lZvySok, "00")

        rs.MoveNext
    Loop
    rs.Close: Set rs = Nothing

    ZiskajTextCerpaniaPreruseni = strVystup
    Exit Function

Err_Handler:
    ZiskajTextCerpaniaPreruseni = ""
End Function

'-------------------------------------------------------------------------------
' Vyhľadá oficiálnu skratku prerušenia v číselníku CiselnikPreruseni.
'-------------------------------------------------------------------------------
Private Function ZistiSkratkuPrerusenia(ByRef db As DAO.Database, ByVal lCisloPrer As Long) As String
    On Error Resume Next
    ZistiSkratkuPrerusenia = ""

    If mod_00_Common.TabulkaExistujeDB(db, "CiselnikPreruseni") Then
        Dim rs As DAO.Recordset
        Set rs = db.OpenRecordset("SELECT NazovSkratka, Nazov FROM CiselnikPreruseni WHERE Cislo = " & lCisloPrer & ";", dbOpenSnapshot)
        If Not rs.EOF Then
            ZistiSkratkuPrerusenia = CStr(Nz(rs!NazovSkratka, Nz(rs!nazov, "")))
        End If
        rs.Close: Set rs = Nothing
    End If

    If Len(ZistiSkratkuPrerusenia) = 0 Then
        Select Case lCisloPrer
            Case 1: ZistiSkratkuPrerusenia = "Prac.dob"
            Case 8: ZistiSkratkuPrerusenia = "DOVOL"
            Case 13: ZistiSkratkuPrerusenia = "OOP"
            Case 16: ZistiSkratkuPrerusenia = "OČR"
            Case Else: ZistiSkratkuPrerusenia = "Prer." & lCisloPrer
        End Select
    End If
End Function

'-------------------------------------------------------------------------------
' Vypočíta kumulatívny stav salda k predchádzajúcemu dňu pred dátumom spracovania.
'-------------------------------------------------------------------------------
Public Function ZiskajStavKPredchadzajucemuDnu( _
    ByVal strOsobneCislo As String, _
    ByVal iRok As Integer, _
    ByVal iMesiac As Integer, _
    Optional ByVal dDatumSpracovania As Date = #12/31/9999#) As Long

    On Error GoTo Err_Handler
    Dim db As DAO.Database: Set db = CurrentDb
    Dim dHranica As Date

    If Not mod_00_Common.TabulkaExistujeDB(db, "DochadzkaDni") Then
        ZiskajStavKPredchadzajucemuDnu = 0
        Exit Function
    End If

    If dDatumSpracovania = #12/31/9999# Then
        Dim dKoniecMesiaca As Date
        dKoniecMesiaca = DateSerial(iRok, iMesiac + 1, 0)
        If Date < dKoniecMesiaca Then
            dDatumSpracovania = Date
        Else
            dDatumSpracovania = dKoniecMesiaca
        End If
    End If

    dHranica = dDatumSpracovania - 1

    If dHranica < DateSerial(iRok, iMesiac, 1) Then
        ZiskajStavKPredchadzajucemuDnu = 0
        Exit Function
    End If

    Dim rsSum As DAO.Recordset
    Dim strSQL As String
    strSQL = "SELECT SUM(SaldoMin) AS TotSaldo FROM DochadzkaDni " & _
             "WHERE OsobneCislo = '" & strOsobneCislo & "' " & _
             "AND Month(Datum) = " & iMesiac & " AND Year(Datum) = " & iRok & " " & _
             "AND Datum <= #" & Format(dHranica, "mm\/dd\/yyyy") & "#;"

    Set rsSum = db.OpenRecordset(strSQL, dbOpenSnapshot)
    If Not rsSum.EOF Then
        ZiskajStavKPredchadzajucemuDnu = Nz(rsSum!TotSaldo, 0)
    Else
        ZiskajStavKPredchadzajucemuDnu = 0
    End If
    rsSum.Close: Set rsSum = Nothing
    Exit Function

Err_Handler:
    Call ZapisChybuDoTabulky("ZiskajStavKPredchadzajucemuDnu", Err.Number, Err.Description, "OsobneCislo=" & strOsobneCislo)
    ZiskajStavKPredchadzajucemuDnu = 0
End Function

'-------------------------------------------------------------------------------
' Programovo generuje a pripravuje tlačenú zostavu Záznam o dochádzke.
'-------------------------------------------------------------------------------
Private Sub ZabezpecExistenciuZostavy(ByVal strNazov As String, ByVal iRok As Integer, ByVal iMesiac As Integer)
    On Error GoTo Err_Handler

    Dim obj As AccessObject
    For Each obj In CurrentProject.AllReports
        If obj.Name = strNazov Then
            DoCmd.DeleteObject acReport, strNazov
            Exit For
        End If
    Next obj

    Dim rpt As Report
    Dim strTempName As String
    Dim ctl As Control

    Set rpt = CreateReport
    strTempName = rpt.Name

    With rpt
        .RecordSource = "SELECT D.OsobneCislo, " & _
                        "IIf(Nz(Z.CeleMeno,'')<>'', Z.CeleMeno, Trim(Nz(Z.Titul,'') & ' ' & Nz(Z.Meno,'') & ' ' & Nz(Z.Priezvisko,''))) AS MenoZamestnanca, " & _
                        "Nz(Z.StrediskoNazov, 'Neklasifikované') AS StrediskoNazov, " & _
                        "D.Datum, Day(D.Datum) AS DenCislo, D.TypDna, D.DennyFondMin, D.OdpracovaneMin, D.SaldoMin " & _
                        "FROM DochadzkaDni AS D LEFT JOIN Zamestnanci AS Z ON D.OsobneCislo = Z.OsobneCislo;"
        .Caption = "ZÁZNAM O DOCHÁDZKE"
        .Width = 10200
    End With

    Call CreateGroupLevel(strTempName, "OsobneCislo", False, True)
    Call CreateGroupLevel(strTempName, "Datum", False, False)

    With rpt.Section(acPageHeader)
        .Height = 1800
        .BackColor = RGB(255, 255, 255)
    End With

    With rpt.Section(acDetail)
        .Height = 280
        .BackColor = RGB(255, 255, 255)
        .AlternateBackColor = RGB(255, 255, 255)
    End With

    With rpt.Section(6)
        .Height = 3100
        .BackColor = RGB(255, 255, 255)
        .CanGrow = True
        .ForceNewPage = 2
    End With

    Set ctl = CreateReportControl(strTempName, acLabel, acPageHeader, "", "", 300, 200, 6000, 400)
    ctl.Caption = "ZÁZNAM O DOCHÁDZKE": ctl.FontSize = 14: ctl.FontBold = True

    Set ctl = CreateReportControl(strTempName, acLabel, acPageHeader, "", "", 300, 700, 1500, 250): ctl.Caption = "Meno:": ctl.FontBold = True
    Set ctl = CreateReportControl(strTempName, acTextBox, acPageHeader, "", "MenoZamestnanca", 1800, 700, 3500, 250)

    Set ctl = CreateReportControl(strTempName, acLabel, acPageHeader, "", "", 5500, 700, 1500, 250): ctl.Caption = "Osobné číslo:": ctl.FontBold = True
    Set ctl = CreateReportControl(strTempName, acTextBox, acPageHeader, "", "OsobneCislo", 7100, 700, 2000, 250)

    Set ctl = CreateReportControl(strTempName, acLabel, acPageHeader, "", "", 300, 1000, 1500, 250): ctl.Caption = "Stredisko:": ctl.FontBold = True
    Set ctl = CreateReportControl(strTempName, acTextBox, acPageHeader, "", "StrediskoNazov", 1800, 1000, 3500, 250)

    Set ctl = CreateReportControl(strTempName, acLabel, acPageHeader, "", "", 5500, 1000, 1500, 250): ctl.Caption = "Obdobie:": ctl.FontBold = True
    Set ctl = CreateReportControl(strTempName, acLabel, acPageHeader, "", "", 7100, 1000, 2500, 250)
    ctl.Caption = mod_00_Common.NazovMesiacaSlovensky(iMesiac) & " " & iRok

    Set ctl = CreateReportControl(strTempName, acRectangle, acPageHeader, "", "", 300, 1400, 9600, 350)
    Set ctl = CreateReportControl(strTempName, acLabel, acPageHeader, "", "", 400, 1450, 500, 250): ctl.Caption = "Deň": ctl.FontBold = True
    Set ctl = CreateReportControl(strTempName, acLabel, acPageHeader, "", "", 950, 1450, 500, 250): ctl.Caption = "Typ": ctl.FontBold = True
    Set ctl = CreateReportControl(strTempName, acLabel, acPageHeader, "", "", 1500, 1450, 5800, 250): ctl.Caption = "Priebeh razení a prerušení": ctl.FontBold = True
    Set ctl = CreateReportControl(strTempName, acLabel, acPageHeader, "", "", 7400, 1450, 1000, 250): ctl.Caption = "Fond": ctl.FontBold = True
    Set ctl = CreateReportControl(strTempName, acLabel, acPageHeader, "", "", 8500, 1450, 1200, 250): ctl.Caption = "Spolu": ctl.FontBold = True

    Set ctl = CreateReportControl(strTempName, acTextBox, acDetail, "", "DenCislo", 400, 20, 500, 240)
    Set ctl = CreateReportControl(strTempName, acTextBox, acDetail, "", "TypDna", 950, 20, 500, 240)

    Set ctl = CreateReportControl(strTempName, acTextBox, acDetail, "", "", 1500, 20, 5800, 240)
    ctl.ControlSource = "=ZiskajDetailyDna([OsobneCislo],[Datum])"
    ctl.FontSize = 8

    Set ctl = CreateReportControl(strTempName, acTextBox, acDetail, "", "", 7400, 20, 1000, 240)
    ctl.ControlSource = "=Format(Nz([DennyFondMin],0)\60,'00') & ':' & Format(Nz([DennyFondMin],0) Mod 60,'00')"

    Set ctl = CreateReportControl(strTempName, acTextBox, acDetail, "", "", 8500, 20, 1200, 240)
    ctl.ControlSource = "=Format(Nz([OdpracovaneMin],0)\60,'00') & ':' & Format(Nz([OdpracovaneMin],0) Mod 60,'00')"

    Set ctl = CreateReportControl(strTempName, acLine, 6, "", "", 300, 100, 9600, 0)

    Set ctl = CreateReportControl(strTempName, acLabel, 6, "", "", 300, 200, 1300, 250): ctl.Caption = "Mes.fond:": ctl.FontBold = True
    Set ctl = CreateReportControl(strTempName, acTextBox, 6, "", "", 1600, 200, 1800, 250)
    ctl.ControlSource = "=Format(Sum(Nz([DennyFondMin],0))\60,'00') & ':' & Format(Sum(Nz([DennyFondMin],0)) Mod 60,'00') & '/' & Sum(IIf(Nz([DennyFondMin],0)>0,1,0))"
    ctl.FontBold = True

    Set ctl = CreateReportControl(strTempName, acLabel, 6, "", "", 3600, 200, 1200, 250): ctl.Caption = "Spolu:": ctl.FontBold = True
    Set ctl = CreateReportControl(strTempName, acTextBox, 6, "", "", 4800, 200, 1800, 250)
    ctl.ControlSource = "=Format(Sum(Nz([OdpracovaneMin],0))\60,'00') & ':' & Format(Sum(Nz([OdpracovaneMin],0)) Mod 60,'00') & '/' & Sum(IIf(Nz([OdpracovaneMin],0)>0,1,0))"
    ctl.FontBold = True

    Set ctl = CreateReportControl(strTempName, acLabel, 6, "", "", 6800, 200, 1200, 250): ctl.Caption = "Nadčas:": ctl.FontBold = True
    Set ctl = CreateReportControl(strTempName, acTextBox, 6, "", "", 8000, 200, 1800, 250)
    ctl.ControlSource = "=Format(Sum(IIf(Nz([SaldoMin],0)>0,Nz([SaldoMin],0),0))\60,'00') & ':' & Format(Sum(IIf(Nz([SaldoMin],0)>0,Nz([SaldoMin],0),0)) Mod 60,'00')"
    ctl.FontBold = True

    Set ctl = CreateReportControl(strTempName, acLabel, 6, "", "", 300, 500, 1300, 250): ctl.Caption = "Sviatky:": ctl.FontBold = True
    Set ctl = CreateReportControl(strTempName, acTextBox, 6, "", "", 1600, 500, 1800, 250)
    ctl.ControlSource = "=""00:00/0"""

    Set ctl = CreateReportControl(strTempName, acLabel, 6, "", "", 3600, 500, 1200, 250): ctl.Caption = "Uzn.nad.:": ctl.FontBold = True
    Set ctl = CreateReportControl(strTempName, acTextBox, 6, "", "", 4800, 500, 1800, 250)
    ctl.ControlSource = "=Format(Sum(IIf(Nz([SaldoMin],0)>0,Nz([SaldoMin],0),0))\60,'00') & ':' & Format(Sum(IIf(Nz([SaldoMin],0)>0,Nz([SaldoMin],0),0)) Mod 60,'00')"

    Set ctl = CreateReportControl(strTempName, acLabel, 6, "", "", 6800, 500, 1200, 250): ctl.Caption = "Nadčas pl.:": ctl.FontBold = True
    Set ctl = CreateReportControl(strTempName, acTextBox, 6, "", "", 8000, 500, 1800, 250)
    ctl.ControlSource = "=""00:00"""

    Set ctl = CreateReportControl(strTempName, acLabel, 6, "", "", 300, 800, 1300, 250): ctl.Caption = "NV z m.m.:": ctl.FontBold = True
    Set ctl = CreateReportControl(strTempName, acTextBox, 6, "", "", 1600, 800, 1800, 250)
    ctl.ControlSource = "=""00:00"""

    Set ctl = CreateReportControl(strTempName, acLabel, 6, "", "", 3600, 800, 1200, 250): ctl.Caption = "Prenos NV:": ctl.FontBold = True
    Set ctl = CreateReportControl(strTempName, acTextBox, 6, "", "", 4800, 800, 1800, 250)
    ctl.ControlSource = "=""00:00"""

    Set ctl = CreateReportControl(strTempName, acLabel, 6, "", "", 6800, 800, 1200, 250): ctl.Caption = "Stav:": ctl.FontBold = True
    Set ctl = CreateReportControl(strTempName, acTextBox, 6, "", "", 8000, 800, 1800, 250)
    ctl.ControlSource = "=IIf(Sum(Nz([SaldoMin],0))<0,'- ','') & Format(Abs(Sum(Nz([SaldoMin],0)))\60,'00') & ':' & Format(Abs(Sum(Nz([SaldoMin],0))) Mod 60,'00')"
    ctl.FontBold = True

    Set ctl = CreateReportControl(strTempName, acLabel, 6, "", "", 300, 1100, 1600, 250): ctl.Caption = "Stav pr.deň.:": ctl.FontBold = True
    Set ctl = CreateReportControl(strTempName, acTextBox, 6, "", "", 1900, 1100, 2000, 250)
    ctl.ControlSource = "=IIf(ZiskajStavKPredchadzajucemuDnu([OsobneCislo], " & iRok & ", " & iMesiac & ")<0,'- ','') & Format(Abs(ZiskajStavKPredchadzajucemuDnu([OsobneCislo], " & iRok & ", " & iMesiac & "))\60,'00') & ':' & Format(Abs(ZiskajStavKPredchadzajucemuDnu([OsobneCislo], " & iRok & ", " & iMesiac & ")) Mod 60,'00')"
    ctl.FontBold = True

    Set ctl = CreateReportControl(strTempName, acLabel, 6, "", "", 300, 1450, 1600, 250)
    ctl.Caption = "Čerpanie prerušení:"
    ctl.FontBold = True

    Set ctl = CreateReportControl(strTempName, acTextBox, 6, "", "", 1900, 1450, 8000, 500)
    ctl.ControlSource = "=ZiskajTextCerpaniaPreruseni([OsobneCislo], " & iRok & ", " & iMesiac & ")"
    ctl.FontSize = 8
    ctl.CanGrow = True

    Set ctl = CreateReportControl(strTempName, acLabel, 6, "", "", 300, 1900, 2200, 250): ctl.Caption = "Zamestnanec: ____________"
    Set ctl = CreateReportControl(strTempName, acLabel, 6, "", "", 2700, 1900, 2200, 250): ctl.Caption = "Spracoval: ____________"
    Set ctl = CreateReportControl(strTempName, acLabel, 6, "", "", 5100, 1900, 2200, 250): ctl.Caption = "Kontroloval: ____________"
    Set ctl = CreateReportControl(strTempName, acLabel, 6, "", "", 7500, 1900, 2200, 250): ctl.Caption = "Schválil: ____________"

    Set ctl = CreateReportControl(strTempName, acLabel, 6, "", "", 300, 2400, 9000, 200)
    ctl.Caption = "Spracované v systéme Dochádzka | " & Format(Now, "dd.mm.yyyy hh:nn:ss")
    ctl.FontSize = 8: ctl.ForeColor = RGB(120, 120, 120)

    ' stav uzávierky mesiaca (návrh / uzavreté) a kontrolný kód údajov - podľa neho sa dá overiť, že podpísaná zostava zodpovedá údajom
    Set ctl = CreateReportControl(strTempName, acTextBox, 6, "", "", 300, 2700, 9600, 250)
    ctl.ControlSource = "=Uz_TextZostavy([OsobneCislo]," & iRok & "," & iMesiac & ")"
    ctl.FontSize = 8: ctl.FontBold = True

    DoCmd.Close acReport, strTempName, acSaveYes
    DoCmd.Rename strNazov, acReport, strTempName
    Exit Sub

Err_Handler:
    Dim strOpisChyby As String: strOpisChyby = Err.Description
    On Error Resume Next
    Call ZapisChybuDoTabulky("ZabezpecExistenciuZostavy", Err.Number, strOpisChyby, "Nazov=" & strNazov)
    If Len(strTempName) > 0 Then DoCmd.Close acReport, strTempName, acSaveNo
    MsgBox "Chyba pri vytváraní zostavy: " & strOpisChyby, vbCritical
End Sub

'-------------------------------------------------------------------------------
' Zapisuje chybu z výpočtového motora do centrálneho systémového logu LogImportu.
'-------------------------------------------------------------------------------
Public Sub ZapisChybuDoTabulky(ByVal strProcedura As String, ByVal lErrNum As Long, ByVal strErrDesc As String, Optional ByVal strDetail As String = "")
    Call mod_00_Common.ZapisLog("modMesaatnaDochadzka." & strProcedura, "ERROR", "Chyba " & lErrNum & ": " & strErrDesc, strDetail)
End Sub


