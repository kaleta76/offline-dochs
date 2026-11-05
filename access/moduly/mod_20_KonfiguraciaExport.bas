Attribute VB_Name = "mod_20_KonfiguraciaExport"
'@Verzia 1.1.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_20_KonfiguraciaExport
' POPIS: Export konfigurácie a VÝPOČTOVÉHO PLÁNU z Accessu pre terminál (kontrakt 1.2.0, schema_version 2,
'        súbor dochs_config.json). Access je systém, ktorý rozhoduje (fondy, kalendáre, sviatky, úväzky, pravidlá
'        prerušení); terminál preberá hotové výsledky a podľa nich počíta saldo tak, aby sa zhodovalo s Accessom
'        a zamestnanec ho mohol skontrolovať skôr, než sekretárka mesiac opraví, vytlačí a uzavrie.
'
'        Export je NADMNOŽINA pôvodnej konfigurácie (schema_version 1): ostávajú rules, interruptions, punch_codes
'        a holidays, pribúda
'          - interruptions[].calc    ako sa interval prerušenia počíta do dňa (WORK / LUNCH / COUNTED / UNPAID),
'          - interruptions[] voliteľne terminal_button, terminal_label, terminal_order, terminal_icon, terminal_request,
'                                    needs_approval, full_day_only (kontrakt 1.3.0 a 1.4.0; len keď ich správca nastavil),
'          - terminal_code_map       kódy razení terminála (WORK, DOCTOR, ...) -> čísla prerušení v Accesse,
'          - funds, templates        názvy fondov a pravidlá prerušení (parametre) po mesiacoch,
'          - employees[].months[]    pre každého zamestnanca a mesiac okna: úväzok, priradenie a PLÁN DNÍ
'                                    (typ dňa a denný fond v minútach, už po zohľadnení kalendára, sviatkov,
'                                    fondu podľa dňa v týždni, pevného mesačného fondu a úväzku).
'        Plán sa počíta tou istou funkciou ako vo výpočte mesiaca (mod_08.NacitajKontextMesiaca), takže terminál
'        nemusí poznať žiadne pravidlá fondov. Súbor NEOBSAHUJE osobné údaje: zamestnanec je len osobné číslo
'        (pre terminál: číslo SAP z TerminalMapaOsob, ak je zadané).
'
'        Okno plánu: predchádzajúci mesiac až nasledujúci mesiac (nastavenia PlanMesiacovDozadu a PlanMesiacovDopredu,
'        predvolene 1 a 1; najviac 14 mesiacov). Vyradený zamestnanec sa do mesiaca nezahrnie (rovnako ako vo výpočte).
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - GenerujKonfiguraciuV2JSON(odYM, doYM)  : Zostaví JSON konfigurácie s plánom; "" pri chybe. YM = rok * 100 + mesiac.
' - SpravaExportu()                        : Text o poslednom exporte (počty, preskočené položky) na zobrazenie používateľovi.
' - PocetZamestnancovVPlane()              : Počet zamestnancov v poslednom exporte.
'===============================================================================

Private Const MAX_MESIACOV As Long = 14

Private mCh() As String
Private mChN As Long
Private mSprava As String
Private mPocetZam As Long

'-------------------------------------------------------------------------------
' Pomocné funkcie: JSON text, pravdivostná hodnota, zreťazenie veľkých reťazcov bez opakovaného kopírovania.
'-------------------------------------------------------------------------------
Private Function J(ByVal s As String) As String
    Dim i As Long, c As Long, t As String
    s = mod_00_Common.OsetriJSONText(s)
    For i = 1 To Len(s)
        c = AscW(Mid$(s, i, 1))
        ' riadiace znaky (napr. tabulátor) JSON v texte nepovoľuje; AscW vracia pre znaky nad 32767 záporné číslo
        If c < 0 Or c >= 32 Then t = t & Mid$(s, i, 1) Else t = t & " "
    Next i
    J = """" & t & """"
End Function

Private Function JB(ByVal b As Boolean) As String
    JB = IIf(b, "true", "false")
End Function

Private Sub SbInit()
    ReDim mCh(0 To 255)
    mChN = 0
End Sub

Private Sub Sb(ByVal s As String)
    If mChN > UBound(mCh) Then ReDim Preserve mCh(0 To UBound(mCh) * 2 + 1)
    mCh(mChN) = s
    mChN = mChN + 1
End Sub

Private Function SbText() As String
    If mChN = 0 Then Exit Function
    ReDim Preserve mCh(0 To mChN - 1)
    SbText = Join(mCh, "")
End Function

Private Function Klamp(ByVal v As Long, ByVal lMin As Long, ByVal lMax As Long) As Long
    If v < lMin Then v = lMin
    If v > lMax Then v = lMax
    Klamp = v
End Function

Private Function MesText(ByVal lYM As Long) As String
    MesText = Format$(lYM \ 100, "0000") & "-" & Format$(lYM Mod 100, "00")
End Function

' Posunie YM (rok * 100 + mesiac) o n mesiacov.
Private Function YMPosun(ByVal lYM As Long, ByVal n As Long) As Long
    Dim t As Long
    t = (lYM \ 100) * 12 + (lYM Mod 100 - 1) + n
    YMPosun = (t \ 12) * 100 + (t Mod 12) + 1
End Function

Private Function PocetMesiacov(ByVal lOd As Long, ByVal lDo As Long) As Long
    PocetMesiacov = ((lDo \ 100) * 12 + lDo Mod 100) - ((lOd \ 100) * 12 + lOd Mod 100) + 1
End Function

Private Function NastavCele(ByVal strKluc As String, ByVal lPredvolene As Long) As Long
    Dim v As Long
    v = CLng(Val(mod_00_Common.GetNastavenie(strKluc, CStr(lPredvolene))))
    NastavCele = Klamp(v, 0, 6)
End Function

' Zoradené číselné kľúče slovníka (prázdne pole, ak je slovník prázdny).
Private Function KluceUsporiadane(ByVal dic As Object) As Variant
    Dim a() As Long, v As Variant, n As Long, i As Long, j As Long, t As Long
    n = dic.Count
    If n = 0 Then
        KluceUsporiadane = Array()
        Exit Function
    End If
    ReDim a(0 To n - 1)
    i = 0
    For Each v In dic.Keys
        a(i) = CLng(v)
        i = i + 1
    Next v
    For i = 1 To n - 1
        t = a(i)
        j = i - 1
        Do While j >= 0
            If a(j) > t Then
                a(j + 1) = a(j)
                j = j - 1
            Else
                Exit Do
            End If
        Loop
        a(j + 1) = t
    Next i
    KluceUsporiadane = a
End Function

' Znak ASCII písmeno alebo číslica (porovnanie podľa kódu, nie podľa zoradenia jazyka: "Ž" nesmie prejsť ako písmeno A-Z).
Private Function JeAlnum(ByVal lKod As Long) As Boolean
    JeAlnum = (lKod >= 48 And lKod <= 57) Or (lKod >= 65 And lKod <= 90) Or (lKod >= 97 And lKod <= 122)
End Function

' Osobné číslo smie mať len písmená a číslice (1 až 20 znakov), inak ho kontrakt neprijme.
Private Function PlatneOC(ByVal s As String) As Boolean
    Dim i As Long
    If Len(s) = 0 Or Len(s) > 20 Then Exit Function
    For i = 1 To Len(s)
        If Not JeAlnum(AscW(Mid$(s, i, 1))) Then Exit Function
    Next i
    PlatneOC = True
End Function

' Kód razenia terminála: veľké písmeno, potom veľké písmená, číslice alebo podčiarkovník (najviac 20 znakov).
Private Function PlatnyKodTerminalu(ByVal s As String) As Boolean
    Dim i As Long, c As Long
    If Len(s) = 0 Or Len(s) > 20 Then Exit Function
    For i = 1 To Len(s)
        c = AscW(Mid$(s, i, 1))
        If Not ((c >= 65 And c <= 90) Or c = 95 Or (i > 1 And c >= 48 And c <= 57)) Then Exit Function
    Next i
    PlatnyKodTerminalu = True
End Function

Private Function PoleBool(ByRef rs As DAO.Recordset, ByVal strPole As String, ByVal bExistuje As Boolean) As Boolean
    If bExistuje Then PoleBool = CBool(Nz(rs.Fields(strPole).Value, False))
End Function

'-------------------------------------------------------------------------------
' Zamestnanec je v mesiaci už vyradený (rovnaká podmienka ako mod_15_Zamestnanci.SqlNeaktivny).
'-------------------------------------------------------------------------------
Private Function NeaktivnyVMesiaci(ByRef rs As DAO.Recordset, ByVal bStlpce As Boolean, ByVal dZaciatokMesiaca As Date) As Boolean
    If Not bStlpce Then Exit Function
    If CBool(Nz(rs!Vyradeny, False)) Then
        If IsNull(rs!VyradenyOd) Then
            NeaktivnyVMesiaci = True
        ElseIf CDate(rs!VyradenyOd) <= dZaciatokMesiaca Then
            NeaktivnyVMesiaci = True
        End If
    End If
End Function

'-------------------------------------------------------------------------------
' Sekcie súboru
'-------------------------------------------------------------------------------
Private Function SekciaPravidla() As String
    Dim s As String
    s = "  ""rules"": {" & vbCrLf
    s = s & "    ""work_window_start_min"": " & mod_08_UdalostiDna.PrmOknoOd() & "," & vbCrLf
    s = s & "    ""work_window_end_min"": " & mod_08_UdalostiDna.PrmOknoDo() & "," & vbCrLf
    s = s & "    ""full_day_obstacle_min"": " & mod_08_UdalostiDna.PrmCelodennaPrekazka() & "," & vbCrLf
    s = s & "    ""auto_lunch_trigger_min"": " & mod_08_UdalostiDna.PrmObedLimit() & "," & vbCrLf
    s = s & "    ""auto_lunch_deduct_min"": " & mod_08_UdalostiDna.PrmObedMin() & "," & vbCrLf
    s = s & "    ""auto_lunch_enabled"": " & JB(Not mod_00_Common.PravidloVypnute("AUTO_OBED_NAD_6H")) & "," & vbCrLf
    s = s & "    ""duplicate_punch_window_min"": " & mod_08_UdalostiDna.PrmDuplicitaLimit() & "," & vbCrLf
    s = s & "    ""default_daily_fund_min"": " & CLng(Val(mod_00_Common.GetNastavenie("PredvolenyFondMin", "450"))) & "," & vbCrLf
    s = s & "    ""auto_repair_mode"": " & mod_09_AutoOprava.RezimAutoOpravy() & "," & vbCrLf
    s = s & "    ""interruption_check_enabled"": " & JB(mod_00_Common.GetNastavenie("KontrolaPravidielPreruseni", "1") <> "0") & vbCrLf
    s = s & "  }"
    SekciaPravidla = s
End Function

' Číselník prerušení; do slovníka dicPrer uloží čísla prerušení (na kontrolu odkazov v ďalších sekciách).
Private Function SekciaPreruseni(ByRef db As DAO.Database, ByVal dicPrer As Object) As String
    Dim rs As DAO.Recordset, s As String, b As Boolean, c As Long
    Dim bAK As Boolean, bFond As Boolean, bPrac As Boolean, bDov As Boolean, bTerm As Boolean, bNezap As Boolean
    s = "  ""interruptions"": [" & vbCrLf
    If mod_00_Common.TabulkaExistujeDB(db, "CiselnikPreruseni") Then
        bAK = mod_00_Common.PoleExistujeDB(db, "CiselnikPreruseni", "AutoKoniecDoKoncaSmeny")
        bFond = mod_00_Common.PoleExistujeDB(db, "CiselnikPreruseni", "ZapocitavatDoFondu")
        bPrac = mod_00_Common.PoleExistujeDB(db, "CiselnikPreruseni", "ZapocitavatDoPrace")
        bDov = mod_00_Common.PoleExistujeDB(db, "CiselnikPreruseni", "OdpocitavatZDovolenky")
        bTerm = mod_00_Common.PoleExistujeDB(db, "CiselnikPreruseni", "TerminalTlacidlo") And mod_00_Common.PoleExistujeDB(db, "CiselnikPreruseni", "NezapocitavatInterval")
        Set rs = db.OpenRecordset("SELECT * FROM CiselnikPreruseni ORDER BY Cislo;", dbOpenSnapshot)
        b = True
        Do While Not rs.EOF
            c = CLng(rs!Cislo)
            dicPrer(c) = True
            If Not b Then s = s & "," & vbCrLf
            b = False
            bNezap = PoleBool(rs, "NezapocitavatInterval", bTerm)
            s = s & "    { ""code"": " & c & ", ""name"": " & J(CStr(Nz(rs!Nazov, ""))) & ", ""short_name"": " & J(CStr(Nz(rs!NazovSkratka, ""))) & _
                    ", ""start_punch_code"": " & CLng(Nz(rs!KodZaciatok, 0)) & ", ""end_punch_code"": " & CLng(Nz(rs!KodKoniec, 0)) & _
                    ", ""is_work"": " & JB(c = 1) & ", ""is_lunch"": " & JB(c = 7) & _
                    ", ""auto_end_of_shift"": " & JB(PoleBool(rs, "AutoKoniecDoKoncaSmeny", bAK)) & _
                    ", ""calc"": " & J(TypVypoctu(c, bNezap)) & _
                    ", ""counts_to_fund"": " & JB(PoleBool(rs, "ZapocitavatDoFondu", bFond)) & _
                    ", ""counts_to_work"": " & JB(PoleBool(rs, "ZapocitavatDoPrace", bPrac)) & _
                    ", ""deducts_leave"": " & JB(PoleBool(rs, "OdpocitavatZDovolenky", bDov)) & _
                    PriznakyTerminalu(rs, bTerm, c) & " }"
            rs.MoveNext
        Loop
        rs.Close
    End If
    s = s & vbCrLf & "  ]"
    SekciaPreruseni = s
End Function

'-------------------------------------------------------------------------------
' Ako sa interval prerušenia počíta do dňa. Zodpovedá mod_08_UdalostiDna.TrvanieIntervalu a SumarDna:
'   č. 1 práca (oreže sa oknom práce), č. 7 obed (skutočné trvanie, jeho prítomnosť vypína automatický obed),
'   ostatné prerušenia: skutočné trvanie; od hranice celodennej prekážky sa započíta denný fond dňa,
'   prerušenie s príznakom NezapocitavatInterval (UNPAID, kontrakt 1.4.0): interval sa nezapočíta (mod_08.JeNezapocitavane).
' Ak sa počítanie v Accesse zmení (napr. začne sa čítať ZapocitavatDoFondu), pribudne tu nová hodnota a zvýši sa verzia kontraktu.
'-------------------------------------------------------------------------------
Private Function TypVypoctu(ByVal c As Long, ByVal bNezapocitat As Boolean) As String
    If c = 1 Then
        TypVypoctu = "WORK"
    ElseIf c = 7 Then
        TypVypoctu = "LUNCH"
    ElseIf bNezapocitat Then
        TypVypoctu = "UNPAID"
    Else
        TypVypoctu = "COUNTED"
    End If
End Function

'-------------------------------------------------------------------------------
' Voliteľné kľúče prerušenia pre terminál (kontrakt 1.3.0 a 1.4.0), vkladajú sa len keď ich správca nastavil:
' terminal_button / terminal_label / terminal_order / terminal_icon (len s tlačidlom), terminal_request, needs_approval, full_day_only.
' Prerušenie č. 1 ich nemá nikdy. Vráti text začínajúci čiarkou, alebo prázdny reťazec.
'-------------------------------------------------------------------------------
Private Function PriznakyTerminalu(ByRef rs As DAO.Recordset, ByVal bStlpce As Boolean, ByVal c As Long) As String
    Dim s As String, strT As String, strI As String, lP As Long
    If Not bStlpce Then Exit Function
    If c = 1 Then Exit Function
    If CBool(Nz(rs!TerminalTlacidlo, False)) Then
        s = s & ", ""terminal_button"": true"
        strT = Trim$(CStr(Nz(rs!TerminalText, "")))
        If Len(strT) > 0 Then s = s & ", ""terminal_label"": " & J(strT)
        lP = CLng(Nz(rs!TerminalPoradie, 0))
        If lP > 0 Then s = s & ", ""terminal_order"": " & Klamp(lP, 1, 99)
        strI = LCase$(Trim$(CStr(Nz(rs!TerminalIkona, ""))))
        If Len(strI) > 0 Then s = s & ", ""terminal_icon"": " & J(strI)
    End If
    If CBool(Nz(rs!TerminalZiadost, False)) Then s = s & ", ""terminal_request"": true"
    If CBool(Nz(rs!VyzadujeSchvalenie, False)) Then s = s & ", ""needs_approval"": true"
    If CBool(Nz(rs!LenCelyDen, False)) Then s = s & ", ""full_day_only"": true"
    PriznakyTerminalu = s
End Function

Private Function SekciaKodyRazeni(ByRef db As DAO.Database) As String
    Dim rs As DAO.Recordset, s As String, b As Boolean
    s = "  ""punch_codes"": [" & vbCrLf
    If mod_00_Common.TabulkaExistujeDB(db, "KodyRazeni") Then
        Set rs = db.OpenRecordset("SELECT KodRazenia, CisloPreruseni, Smer, TextRazenia FROM KodyRazeni ORDER BY KodRazenia;", dbOpenSnapshot)
        b = True
        Do While Not rs.EOF
            If Not b Then s = s & "," & vbCrLf
            b = False
            s = s & "    { ""code"": " & CLng(rs!KodRazenia) & ", ""interruption"": " & CLng(Nz(rs!CisloPreruseni, 0)) & _
                    ", ""direction"": " & J(CStr(Nz(rs!Smer, ""))) & ", ""label"": " & J(CStr(Nz(rs!TextRazenia, ""))) & " }"
            rs.MoveNext
        Loop
        rs.Close
    End If
    s = s & vbCrLf & "  ]"
    SekciaKodyRazeni = s
End Function

' Sviatky na rok a rok + 1 (pevné a pohyblivé podľa stĺpca Rok), rovnaký výber ako v NacitajKontextMesiaca.
Private Function SekciaSviatky(ByRef db As DAO.Database, ByVal iRok As Integer) As String
    Dim rs As DAO.Recordset, dicSv As Object, k As Variant, r As Integer, bRok As Boolean, s As String, b As Boolean
    Set dicSv = CreateObject("Scripting.Dictionary")
    If mod_00_Common.TabulkaExistujeDB(db, "Sviatky") Then
        bRok = mod_00_Common.PoleExistujeDB(db, "Sviatky", "Rok")
        For r = iRok To iRok + 1
            Set rs = db.OpenRecordset("SELECT Den, Mesiac, Nazov FROM Sviatky" & IIf(bRok, " WHERE Rok IS NULL OR Rok = " & r, "") & ";", dbOpenSnapshot)
            Do While Not rs.EOF
                On Error Resume Next
                dicSv(Format$(DateSerial(r, CLng(rs!Mesiac), CLng(rs!Den)), "yyyy-mm-dd")) = CStr(Nz(rs!Nazov, ""))
                On Error GoTo 0
                rs.MoveNext
            Loop
            rs.Close
        Next r
    End If
    s = "  ""holidays"": [" & vbCrLf
    b = True
    For Each k In dicSv.Keys
        If Not b Then s = s & "," & vbCrLf
        b = False
        s = s & "    { ""date"": " & J(CStr(k)) & ", ""name"": " & J(CStr(dicSv(k))) & " }"
    Next k
    s = s & vbCrLf & "  ]"
    SekciaSviatky = s
End Function

' Kódy razení terminála -> čísla prerušení (TerminalMapaKodov). Neplatné riadky sa preskočia a zapíšu do logu.
Private Function SekciaMapaKodov(ByRef db As DAO.Database, ByVal dicPrer As Object) As String
    Dim rs As DAO.Recordset, s As String, b As Boolean, strKod As String, c As Long
    s = "  ""terminal_code_map"": [" & vbCrLf
    If mod_00_Common.TabulkaExistujeDB(db, "TerminalMapaKodov") Then
        Set rs = db.OpenRecordset("SELECT Kod, CisloPreruseni FROM TerminalMapaKodov ORDER BY Kod;", dbOpenSnapshot)
        b = True
        Do While Not rs.EOF
            strKod = UCase$(Trim$(CStr(Nz(rs!Kod, ""))))
            c = CLng(Nz(rs!CisloPreruseni, 0))
            If Not PlatnyKodTerminalu(strKod) Then
                Call mod_00_Common.ZapisLog("mod_20_KonfiguraciaExport.SekciaMapaKodov", "WARN", "Kód terminála '" & strKod & "' má neplatný tvar, preskočený.")
                mSprava = mSprava & "Preskočený kód terminála " & strKod & " (neplatný tvar)." & vbCrLf
            ElseIf Not dicPrer.Exists(c) Then
                Call mod_00_Common.ZapisLog("mod_20_KonfiguraciaExport.SekciaMapaKodov", "WARN", "Kód terminála " & strKod & " odkazuje na neexistujúce prerušenie " & c & ", preskočený.")
                mSprava = mSprava & "Preskočený kód terminála " & strKod & " (prerušenie " & c & " neexistuje)." & vbCrLf
            Else
                If Not b Then s = s & "," & vbCrLf
                b = False
                s = s & "    { ""code"": " & J(strKod) & ", ""interruption"": " & c & " }"
            End If
            rs.MoveNext
        Loop
        rs.Close
    End If
    s = s & vbCrLf & "  ]"
    SekciaMapaKodov = s
End Function

' Číslo SAP pre osobné číslo Accessu (TerminalMapaOsob), ak je zadané; inak osobné číslo.
Private Function MapaOsobDoTerminalu(ByRef db As DAO.Database) As Object
    Dim dic As Object, rs As DAO.Recordset, oc As String, sap As String
    Set dic = CreateObject("Scripting.Dictionary")
    If mod_00_Common.TabulkaExistujeDB(db, "TerminalMapaOsob") Then
        Set rs = db.OpenRecordset("SELECT SapCislo, OsobneCislo FROM TerminalMapaOsob ORDER BY SapCislo;", dbOpenSnapshot)
        Do While Not rs.EOF
            oc = Trim$(CStr(Nz(rs!OsobneCislo, "")))
            sap = Trim$(CStr(Nz(rs!SapCislo, "")))
            If Len(oc) > 0 And Len(sap) > 0 Then
                If Not dic.Exists(oc) Then dic.Add oc, sap
            End If
            rs.MoveNext
        Loop
        rs.Close
    End If
    Set MapaOsobDoTerminalu = dic
End Function

'-------------------------------------------------------------------------------
' Plán zamestnancov (veľká časť súboru). Do slovníkov uloží použité fondy a šablóny (na ich katalógy).
' Vráti text poľa employees bez zátvoriek.
'-------------------------------------------------------------------------------
Private Function SekciaZamestnanci(ByRef db As DAO.Database, ByRef lMes() As Long, ByVal nMes As Long, _
                                   ByVal dicFond As Object, ByVal dicSab As Object, ByRef nMesPlanov As Long) As String
    Dim rs As DAO.Recordset, strOC As String, strPN As String, i As Long, d As Long, y As Long, m As Long
    Dim k As TKontextMesiaca, kPrazdny As TKontextMesiaca
    Dim lFond As Long, lSab As Long, lKal As Long, lUv As Long, f As Long
    Dim sT As String, sF As String, sM As String, nM As Long, bVyr As Boolean, bPrvy As Boolean
    Dim dicMapa As Object

    Set dicMapa = MapaOsobDoTerminalu(db)
    bVyr = mod_00_Common.PoleExistujeDB(db, "Zamestnanci", "Vyradeny") And mod_00_Common.PoleExistujeDB(db, "Zamestnanci", "VyradenyOd")
    Set rs = db.OpenRecordset("SELECT * FROM Zamestnanci WHERE OsobneCislo Is Not Null ORDER BY OsobneCislo;", dbOpenSnapshot)
    Call SbInit
    bPrvy = True
    Do While Not rs.EOF
        strOC = Trim$(CStr(rs!OsobneCislo))
        If dicMapa.Exists(strOC) Then strPN = CStr(dicMapa(strOC)) Else strPN = strOC
        If Not PlatneOC(strPN) Then
            Call mod_00_Common.ZapisLog("mod_20_KonfiguraciaExport.SekciaZamestnanci", "WARN", "Osobné číslo má nepovolený tvar, zamestnanec preskočený.", "OC=" & strOC)
            mSprava = mSprava & "Preskočený zamestnanec " & strOC & " (osobné číslo musí mať len písmená a číslice, najviac 20 znakov)." & vbCrLf
        Else
            sM = ""
            nM = 0
            For i = 1 To nMes
                y = lMes(i) \ 100
                m = lMes(i) Mod 100
                If Not NeaktivnyVMesiaci(rs, bVyr, DateSerial(y, m, 1)) Then
                    k = kPrazdny
                    Call mod_08_UdalostiDna.NacitajKontextMesiaca(db, strOC, y, m, k)
                    If Len(k.Typ(1)) <> 2 Or k.PocetDni < 28 Then
                        Call mod_00_Common.ZapisLog("mod_20_KonfiguraciaExport.SekciaZamestnanci", "WARN", "Plán mesiaca sa nepodarilo vypočítať, mesiac vynechaný.", "OC=" & strOC & " " & MesText(lMes(i)))
                        mSprava = mSprava & "Vynechaný plán " & strOC & " " & MesText(lMes(i)) & " (výpočet zlyhal, pozri protokol)." & vbCrLf
                    Else
                        Call mod_08_UdalostiDna.NastaveniaZamestnanca(db, strOC, y, m, lFond, lSab, lKal)
                        lUv = Klamp(mod_15_Zamestnanci.UvazokZamestnanca(db, strOC, y, m), 1, 200)
                        dicFond(lFond) = True
                        dicSab(lSab) = True
                        sT = ""
                        sF = ""
                        For d = 1 To k.PocetDni
                            f = Klamp(k.Fond(d), 0, 1440)
                            sT = sT & IIf(d > 1, ", ", "") & """" & k.Typ(d) & """"
                            sF = sF & IIf(d > 1, ", ", "") & f
                        Next d
                        If nM > 0 Then sM = sM & "," & vbCrLf
                        sM = sM & "        { ""month"": " & J(MesText(lMes(i))) & ", ""employment_pct"": " & lUv & ", ""fund_id"": " & lFond & _
                                  ", ""template_id"": " & lSab & ", ""calendar_id"": " & lKal & "," & vbCrLf & _
                                  "          ""day_types"": [" & sT & "]," & vbCrLf & _
                                  "          ""expected_min"": [" & sF & "] }"
                        nM = nM + 1
                    End If
                End If
            Next i
            If nM > 0 Then
                If Not bPrvy Then Call Sb("," & vbCrLf)
                bPrvy = False
                Call Sb("    {" & vbCrLf & "      ""personnel_number"": " & J(strPN) & "," & vbCrLf & "      ""months"": [" & vbCrLf & sM & vbCrLf & "      ]" & vbCrLf & "    }")
                mPocetZam = mPocetZam + 1
                nMesPlanov = nMesPlanov + nM
            End If
        End If
        rs.MoveNext
    Loop
    rs.Close
    SekciaZamestnanci = SbText()
End Function

' Katalóg použitých fondov (názov a typ z najnovšej verzie fondu).
Private Function SekciaFondy(ByRef db As DAO.Database, ByVal dicFond As Object) As String
    Dim v As Variant, i As Long, rs As DAO.Recordset, s As String, strNazov As String, lTyp As Long, bTab As Boolean
    bTab = mod_00_Common.TabulkaExistujeDB(db, "PracovneFondy")
    s = "  ""funds"": [" & vbCrLf
    v = KluceUsporiadane(dicFond)
    For i = LBound(v) To UBound(v)
        strNazov = ""
        lTyp = 0
        If bTab Then
            Set rs = db.OpenRecordset("SELECT TOP 1 Nazov, TypFondu FROM PracovneFondy WHERE Cislo = " & CLng(v(i)) & " ORDER BY (Rok * 12 + Mesiac) DESC;", dbOpenSnapshot)
            If Not rs.EOF Then
                strNazov = CStr(Nz(rs!Nazov, ""))
                lTyp = Klamp(CLng(Nz(rs!TypFondu, 0)), 0, 9)
            End If
            rs.Close
        End If
        If i > LBound(v) Then s = s & "," & vbCrLf
        s = s & "    { ""id"": " & CLng(v(i)) & ", ""name"": " & J(strNazov) & ", ""type"": " & lTyp & " }"
    Next i
    s = s & vbCrLf & "  ]"
    SekciaFondy = s
End Function

' Pole siedmich čísel (pondelok až nedeľa): hodnoty podľa dňa, alebo jedna spoločná hodnota pre všetky dni.
Private Function PoleDni(ByVal x As Object, ByVal strPred As String, ByVal bPodlaDna As Boolean, ByVal lSpolocna As Long) As String
    Dim d As Long, v As Long, s As String
    For d = 1 To 7
        If bPodlaDna Then v = CLng(x.Item(strPred & d)) Else v = lSpolocna
        s = s & IIf(d > 1, ", ", "") & Klamp(v, 0, 1440)
    Next d
    PoleDni = "[" & s & "]"
End Function

' Šablóny pravidiel prerušení použité zamestnancami; pravidlá sú vyhodnotené pre každý mesiac okna rovnako ako pri kontrole dňa.
Private Function SekciaSablony(ByRef db As DAO.Database, ByVal dicSab As Object, ByRef lMes() As Long, ByVal nMes As Long, ByVal dicPrer As Object) As String
    Dim v As Variant, kl As Variant, i As Long, iMes As Long, q As Long, s As String, strNazov As String, vN As Variant
    Dim rul As Object, x As Object, c As Long, a As Long
    s = "  ""templates"": [" & vbCrLf
    v = KluceUsporiadane(dicSab)
    For i = LBound(v) To UBound(v)
        strNazov = ""
        If mod_00_Common.TabulkaExistujeDB(db, "ParametrePreruseni") Then
            vN = DLookup("NazovSablony", "ParametrePreruseni", "Sablona = " & CLng(v(i)))
            If Not IsNull(vN) Then strNazov = CStr(vN)
        End If
        If i > LBound(v) Then s = s & "," & vbCrLf
        s = s & "    {" & vbCrLf & "      ""id"": " & CLng(v(i)) & ", ""name"": " & J(strNazov) & "," & vbCrLf & "      ""months"": [" & vbCrLf
        For iMes = 1 To nMes
            Set rul = mod_16_PravidlaPreruseni.PravidlaSablonyPreMesiac(db, CLng(v(i)), CLng(lMes(iMes) \ 100) * 12 + (lMes(iMes) Mod 100))
            If iMes > 1 Then s = s & "," & vbCrLf
            s = s & "        { ""month"": " & J(MesText(lMes(iMes))) & ", ""rules"": ["
            kl = KluceUsporiadane(rul)
            q = 0
            For a = LBound(kl) To UBound(kl)
                c = CLng(kl(a))
                If dicPrer.Exists(c) Then
                    Set x = rul.Item(c)
                    s = s & IIf(q > 0, ",", "") & vbCrLf & "          { ""interruption"": " & c & ", ""disabled"": " & JB(CLng(x.Item("Vypnute")) <> 0) & "," & vbCrLf & _
                            "            ""allowed_from_min"": " & PoleDni(x, "IntOd", CLng(x.Item("IntDni")) <> 0, CLng(x.Item("IntOdM"))) & "," & vbCrLf & _
                            "            ""allowed_to_min"": " & PoleDni(x, "IntDo", CLng(x.Item("IntDni")) <> 0, CLng(x.Item("IntDoM"))) & "," & vbCrLf & _
                            "            ""max_duration_min"": " & PoleDni(x, "Max", CLng(x.Item("MaxDni")) <> 0, CLng(x.Item("MaxM"))) & "," & vbCrLf & _
                            "            ""min_duration_min"": " & Klamp(CLng(x.Item("MinT")), 0, 1440) & ", ""min_worked_before_min"": " & Klamp(CLng(x.Item("MinO")), 0, 1440) & " }"
                    q = q + 1
                End If
            Next a
            s = s & IIf(q > 0, vbCrLf & "          ", "") & "] }"
        Next iMes
        s = s & vbCrLf & "      ]" & vbCrLf & "    }"
    Next i
    s = s & vbCrLf & "  ]"
    SekciaSablony = s
End Function

'-------------------------------------------------------------------------------
' Zostaví celý súbor. lOdYM / lDoYM (rok * 100 + mesiac) určujú okno plánu; bez nich sa použije predchádzajúci až nasledujúci mesiac.
' Pri chybe vráti prázdny reťazec (podrobnosti v protokole), nikdy čiastočný súbor.
'-------------------------------------------------------------------------------
Public Function GenerujKonfiguraciuV2JSON(Optional ByVal lOdYM As Long = 0, Optional ByVal lDoYM As Long = 0) As String
    On Error GoTo Chyba
    Dim db As DAO.Database, lDnes As Long, nMes As Long, i As Long, lMes() As Long
    Dim dicPrer As Object, dicFond As Object, dicSab As Object
    Dim sPrer As String, sKody As String, sSv As String, sMapa As String, sZam As String, sFond As String, sSab As String
    Dim nMesPlanov As Long, s As String, strChyba As String

    mSprava = ""
    mPocetZam = 0
    Set db = CurrentDb
    Call mod_08_UdalostiDna.ObnovParametre
    Call mod_16_PravidlaPreruseni.ObnovPravidla
    Call mod_19_TerminalImport.ZabezpecTabulky(db)

    ' tlačidlá a príznaky prerušení: neplatné nastavenie by terminál odmietol, preto sa súbor radšej nevytvorí
    strChyba = mod_10_Konfiguracia.ChybaTlacidiel(db)
    If Len(strChyba) > 0 Then
        Call mod_00_Common.ZapisLog("mod_20_KonfiguraciaExport.GenerujKonfiguraciuV2JSON", "ERROR", "Neplatné tlačidlá alebo príznaky prerušení: " & Replace(strChyba, vbCrLf, " | "))
        mSprava = "Konfiguráciu sa nepodarilo zostaviť, opravte nastavenie prerušení (karta 5):" & vbCrLf & strChyba
        GenerujKonfiguraciuV2JSON = ""
        Exit Function
    End If

    lDnes = Year(Date) * 100 + Month(Date)
    If lOdYM = 0 Then lOdYM = YMPosun(lDnes, -NastavCele("PlanMesiacovDozadu", 1))
    If lDoYM = 0 Then lDoYM = YMPosun(lDnes, NastavCele("PlanMesiacovDopredu", 1))
    If lDoYM < lOdYM Then lDoYM = lOdYM
    If PocetMesiacov(lOdYM, lDoYM) > MAX_MESIACOV Then lDoYM = YMPosun(lOdYM, MAX_MESIACOV - 1)
    nMes = PocetMesiacov(lOdYM, lDoYM)
    ReDim lMes(1 To nMes)
    For i = 1 To nMes
        lMes(i) = YMPosun(lOdYM, i - 1)
    Next i

    Set dicPrer = CreateObject("Scripting.Dictionary")
    Set dicFond = CreateObject("Scripting.Dictionary")
    Set dicSab = CreateObject("Scripting.Dictionary")

    sPrer = SekciaPreruseni(db, dicPrer)
    sKody = SekciaKodyRazeni(db)
    sSv = SekciaSviatky(db, CInt(lOdYM \ 100))
    sMapa = SekciaMapaKodov(db, dicPrer)
    sZam = SekciaZamestnanci(db, lMes, nMes, dicFond, dicSab, nMesPlanov)
    sFond = SekciaFondy(db, dicFond)
    sSab = SekciaSablony(db, dicSab, lMes, nMes, dicPrer)

    s = "{" & vbCrLf & "  ""schema_version"": 2," & vbCrLf
    ' config_version a generated_at sú na jednom riadku: porovnanie verzií (mod_12.BezVerzie) ich vynechá spolu
    s = s & "  ""config_version"": " & J(Format$(Now, "yyyy.mm.dd.hhnn")) & ", ""generated_at"": " & _
            J(Format$(Now, "yyyy-mm-dd") & "T" & Format$(Now, "hh:nn:ss")) & "," & vbCrLf
    s = s & "  ""rok"": " & (lOdYM \ 100) & "," & vbCrLf
    s = s & SekciaPravidla() & "," & vbCrLf
    s = s & sPrer & "," & vbCrLf
    s = s & sKody & "," & vbCrLf
    s = s & sSv & "," & vbCrLf
    s = s & "  ""period"": { ""from_month"": " & J(MesText(lOdYM)) & ", ""to_month"": " & J(MesText(lDoYM)) & " }," & vbCrLf
    s = s & sMapa & "," & vbCrLf
    s = s & sFond & "," & vbCrLf
    s = s & sSab & "," & vbCrLf
    s = s & "  ""employees"": [" & vbCrLf & sZam & vbCrLf & "  ]," & vbCrLf
    s = s & "  ""counts"": { ""employees"": " & mPocetZam & ", ""employee_months"": " & nMesPlanov & " }" & vbCrLf & "}"

    mSprava = "Okno plánu " & MesText(lOdYM) & " až " & MesText(lDoYM) & ": " & mPocetZam & " zamestnancov, " & nMesPlanov & " mesačných plánov." & vbCrLf & mSprava
    GenerujKonfiguraciuV2JSON = s
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_20_KonfiguraciaExport.GenerujKonfiguraciuV2JSON", "ERROR", Err.Description)
    mSprava = "Konfiguráciu sa nepodarilo zostaviť: " & Err.Description
    GenerujKonfiguraciuV2JSON = ""
End Function

Public Function SpravaExportu() As String
    SpravaExportu = mSprava
End Function

Public Function PocetZamestnancovVPlane() As Long
    PocetZamestnancovVPlane = mPocetZam
End Function
