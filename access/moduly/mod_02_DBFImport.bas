Attribute VB_Name = "mod_02_DBFImport"
'@Verzia 2.7.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_02_DBFImport
' POPIS: Import dát zo starej DOS/Windows dochádzky (DBF) do nového modelu.
'        Import NIE JE 1:1 - štruktúra cieľových tabuliek kopíruje okná pôvodnej aplikácie:
'
'   Okno pôvodnej aplikácie                       -> Cieľové tabuľky            (zdroj DBF)
'   -------------------------------------------------------------------------------------
'   Číselník prerušení                            -> CiselnikPreruseni          (cis_preruseni)
'        (jedno prerušenie má 2 razenia)          -> KodyRazeni (kód = začiatok/koniec)
'                                                 -> TypyUdalosti
'   Pracovný fond (zoznam + karta)                -> PracovneFondy              (cis_pracfondy)
'                                                 -> PracovneFondyDni           (cis_pracfondzme)
'   Šablóna parametrov dochádzky (3 záložky)      -> SablonyDochadzky           (cis_pardochvyp)
'                                                 -> SablonyNadcasov            (cis_pardochcas)
'                                                 -> SablonyPraceVNoci          (cis_pardochnoc)
'   Číselník parametrov výpočtu pre prerušenia    -> ParametrePreruseni         (cis_parprer)
'     + Karta šablóny parametrov prerušení           (1 riadok = šablóna x mesiac x prerušenie)
'                                                    (POLE13 = KodPaM)
'   Kalendár (reťazec typov dní)                  -> Kalendare + KalendarDni    (cis_kalendar)
'                                                    (reťazec "PPVV.." sa rozbalí na 1 riadok = 1 deň)
'                                                 -> Sviatky                    (cis_sviatkov)
'   Zamestnanec + priradenie fondov               -> Zamestnanci, ZamestnanciFondy (cis_zamestnanec, cis_zamdoch)
'   Dochádzka (razenia)                           -> DochadzkaImport            (cis_dochdata)
'
'   Polia, ktorých význam sa nedal jednoznačne určiť z obrazoviek, sa ukladajú
'   do stĺpca "Surove" ako text POLE=hodnota; (nič sa nestráca).
'
'   Bezpečný import číselníka a parametrov prerušení (2.7.0): číselník sa najprv porovná so súčasným a pri rozdieloch sa raz opýta,
'   či prepísať hodnotami z Ordata (predvolene ponechať súčasné; chýbajúce prerušenia sa pridajú). Parametre prerušení sa preberajú len
'   na výslovné Áno, existujúce riadky sa nemažú ani neprepisujú (dopĺňajú sa len chýbajúce). Fondy, kalendár a priradenia sa nemenili.
'
'   Čítanie DBF zabezpečuje mod_02a_DBFReader (binárne; dBase III aj dBase 7).
'===============================================================================

Private mBatch As Boolean
Private mOdM As Long, mOdR As Long, mDoM As Long, mDoR As Long
Private mStrukturaOK As Boolean
Private mFilterOC As Object          ' filter osobných čísel pre import (Nothing / prázdny = všetci)
Private mPoznamkyImportu As String   ' čo sa pri dávkovom importe rozhodlo (zobrazí sa na konci)

'-------------------------------------------------------------------------------
' Zastaraná funkcia pre konverziu kódovania (kódovanie 1250/852 rieši priamo binárny čítač DBF).
'-------------------------------------------------------------------------------
Public Function KonvertujCP852toANSI(ByVal strInput As String) As String
    KonvertujCP852toANSI = strInput
End Function

'-------------------------------------------------------------------------------
' Pomocná funkcia pre nahradenie prázdneho reťazca hodnotou Null pre databázový zápis.
'-------------------------------------------------------------------------------
Private Function NV(ByVal s As String) As Variant
    If Len(s) = 0 Then NV = Null Else NV = s
End Function

'-------------------------------------------------------------------------------
' Aktualizuje posledný dokončený krok sprievodcu importom, ak je nový krok vyšší ako uložený.
'-------------------------------------------------------------------------------
Private Sub PosunKrok(ByVal Krok As Long)
    If Krok > mod_00_Common.GetPoslednyKrok() Then Call mod_00_Common.SetPoslednyKrok(Krok)
End Sub

'-------------------------------------------------------------------------------
' Zapisuje systémovú chybu pri importe do centrálneho logu LogImportu.
'-------------------------------------------------------------------------------
Private Sub ChybaImportu(ByVal Krok As String, ByVal Cislo As Long, ByVal popis As String)
    Call mod_00_Common.ZapisLog(Krok, "ERROR", "Chyba " & Cislo & ": " & popis)
End Sub

'-------------------------------------------------------------------------------
' Overuje a zabezpečuje existenciu požadovaných databázových tabuliek a stĺpcov pred spustením importu.
'-------------------------------------------------------------------------------
Private Sub PripravStrukturu()
    If mStrukturaOK Then Exit Sub
    Call mod_01_SystemInit.ZabezpecStrukturuImportu
    mStrukturaOK = True
End Sub

'-------------------------------------------------------------------------------
' Načíta rozsah spracovávaných mesiacov a rokov zo sprievodcu importom alebo používateľského vstupu.
'-------------------------------------------------------------------------------
Private Sub NacitajObdobie()
    If mBatch Then Exit Sub
    Call mod_02_DBFImport.ZistiObdobieImportu(mOdM, mOdR, mDoM, mDoR)
End Sub

'-------------------------------------------------------------------------------
' Pri samostatnom spustení (mimo dávky) načíta filter osobných čísel z konzoly.
'-------------------------------------------------------------------------------
Private Sub NacitajFilterOC()
    If mBatch Then Exit Sub
    On Error Resume Next
    Set mFilterOC = Nothing
    If mod_00_Common.FormIsOpen("frmHlavnaKonzola") Then Call NastavFilterOC(Nz(Forms!frmHlavnaKonzola!txtImportOC, ""))
End Sub

'-------------------------------------------------------------------------------
' Testuje, či sa zadaný rok a mesiac nachádzajú v stanovenom rozsahu importovaného obdobia.
'-------------------------------------------------------------------------------
Private Function JeVObdobi(ByVal rok As Long, ByVal mes As Long) As Boolean
    Dim ym As Long
    If rok <= 0 Or mes <= 0 Then JeVObdobi = True: Exit Function
    ym = rok * 12 + mes
    JeVObdobi = ((ym >= mOdR * 12 + mOdM) And (ym <= mDoR * 12 + mDoM))
End Function

'-------------------------------------------------------------------------------
' Bezpečne zatvára formulár priebehu spracovania (frmProgress).
'-------------------------------------------------------------------------------
Private Sub ZavriProgress()
    If mBatch Then Exit Sub
    Call mod_00_Common.ZavriProgressForm
End Sub

'-------------------------------------------------------------------------------
' Obnovuje počítadlo spracovaných záznamov a stavový text vo formulári priebehu spracovania.
'-------------------------------------------------------------------------------
Private Sub AktualizujProgress(ByVal TextStavu As String, Optional ByVal Aktualne As Long = 0, Optional ByVal Celkovo As Long = 0)
    Call mod_00_Common.AktualizujProgressGUI(TextStavu, Aktualne, Celkovo)
End Sub

'-------------------------------------------------------------------------------
' Načíta CSV/TXT súbor so zamestnancami (zoznam osobných čísel alebo CSV s hlavičkou) - deleguje na mod_11_ImportZamestnancov.
'-------------------------------------------------------------------------------
Public Sub ImportZamestnancovCSVPriamo(Optional ByVal CestaKSuboru As String = "")
    ' Deleguje na univerzálny importér (rozpoznanie oddeľovača, hlavičky, kódovania; doplnenie údajov a vedúcich).
    Call mod_11_ImportZamestnancov.ImportZamestnancovZCSV(CestaKSuboru, True)
End Sub

'-------------------------------------------------------------------------------
' Spracuje textový zoznam osobných čísel z formulára alebo CSV a zapíše nových zamestnancov do DB.
'-------------------------------------------------------------------------------
Public Sub PridajZamestnancovRucne(Optional ByVal VstupnyText As String = "")
    On Error GoTo ChybaHandler
    If Len(Trim(VstupnyText)) = 0 And mod_00_Common.FormIsOpen("frmSprievodcaImportom") Then
        VstupnyText = Trim(Nz(Forms!frmSprievodcaImportom!txtRucneOSCisla, ""))
    End If
    If Len(Trim(VstupnyText)) = 0 Then Exit Sub
    Call PripravStrukturu

    Dim txtClean As String, polozky() As String, i As Long, cisloStr As String, ocVal As Double, pridaneCount As Long
    Dim poznane As Object, ocMin As Double, ocMax As Double, rs As DAO.Recordset
    ocMin = Val(mod_00_Common.GetNastavenie("OCMin", "1000000"))
    ocMax = Val(mod_00_Common.GetNastavenie("OCMax", "9999999"))

    txtClean = Replace(Replace(Replace(Replace(VstupnyText, vbCrLf, " "), vbCr, " "), vbLf, " "), ",", " ")
    txtClean = Replace(Replace(txtClean, ";", " "), vbTab, " ")
    polozky = Split(txtClean, " ")

    Set poznane = NacitajOC()
    Set rs = CurrentDb.OpenRecordset("Zamestnanci", dbOpenDynaset)

    For i = LBound(polozky) To UBound(polozky)
        cisloStr = Trim$(polozky(i))
        If Len(cisloStr) > 0 Then
            ocVal = Val(cisloStr)
            If ocVal >= ocMin And ocVal <= ocMax Then
                If Not poznane.Exists(CStr(CLng(ocVal))) Then
                    rs.AddNew
                    rs!OsobneCislo = CStr(CLng(ocVal))
                    rs!ADAktivny = True
                    rs!DatumImportu = Now()
                    rs.Update
                    poznane(CStr(CLng(ocVal))) = True
                    pridaneCount = pridaneCount + 1
                End If
            End If
        End If
    Next i
    rs.Close

    If pridaneCount > 0 Then Call PosunKrok(2)
    Call mod_00_Common.ZapisLog("PridajZamestnancovRucne", "INFO", "Pridaných OC: " & pridaneCount)
    Exit Sub
ChybaHandler:
    Call ChybaImportu("PridajZamestnancovRucne", Err.Number, Err.Description)
    On Error Resume Next
    If Not rs Is Nothing Then rs.Close
End Sub

'-------------------------------------------------------------------------------
' Spracuje ručne zadané kódy a názvy prerušení vo formáte 'KOD=NAZOV' a uloží ich do KodyRazeni.
'-------------------------------------------------------------------------------
Public Sub PridajPreruseniaRucne(Optional ByVal VstupnyText As String = "")
    On Error GoTo ChybaHandler
    If Len(Trim(VstupnyText)) = 0 And mod_00_Common.FormIsOpen("frmSprievodcaImportom") Then
        VstupnyText = Trim(Nz(Forms!frmSprievodcaImportom!txtRucnePrerusenia, ""))
    End If
    If Len(Trim(VstupnyText)) = 0 Then Exit Sub
    Call PripravStrukturu

    Dim txtClean As String, polozky() As String, i As Long, par As String, posEq As Long
    Dim kKod As String, kNazov As String, kod As Long, pocet As Long
    Dim db As DAO.Database, rs As DAO.Recordset

    txtClean = Replace(Replace(Replace(VstupnyText, vbCrLf, ";"), vbCr, ";"), vbLf, ";")
    polozky = Split(txtClean, ";")
    Set db = CurrentDb

    For i = LBound(polozky) To UBound(polozky)
        par = Trim$(polozky(i))
        If Len(par) > 0 Then
            posEq = InStr(par, "=")
            If posEq > 0 Then
                kKod = Trim$(Left$(par, posEq - 1))
                kNazov = Trim$(Mid$(par, posEq + 1))
            Else
                kKod = par
                kNazov = "Prerušenie " & par
            End If
            kod = CLng(Val(kKod))
            If kod > 0 Then
                Set rs = db.OpenRecordset("SELECT * FROM KodyRazeni WHERE KodRazenia=" & kod, dbOpenDynaset)
                If rs.EOF Then
                    rs.AddNew
                    rs!KodRazenia = kod
                Else
                    rs.Edit
                End If
                rs!textRazenia = NV(Left$(kNazov, 50))
                rs.Update
                rs.Close
                pocet = pocet + 1
            End If
        End If
    Next i
    Call mod_00_Common.ZapisLog("PridajPreruseniaRucne", "INFO", "Uložených kódov razení: " & pocet)
    Exit Sub
ChybaHandler:
    Call ChybaImportu("PridajPreruseniaRucne", Err.Number, Err.Description)
    On Error Resume Next
    If Not rs Is Nothing Then rs.Close
End Sub

'-------------------------------------------------------------------------------
' Vytvorí pamäťový slovník (Dictionary) všetkých existujúcich osobných čísel pre rýchlu kontrolu duplicity.
'-------------------------------------------------------------------------------
Private Function NacitajOC() As Object
    Dim d As Object, rs As DAO.Recordset, s As String, v As Double
    Set d = CreateObject("Scripting.Dictionary")
    Set rs = CurrentDb.OpenRecordset("SELECT OsobneCislo FROM Zamestnanci", dbOpenSnapshot)
    Do While Not rs.EOF
        s = Trim$(CStr(Nz(rs!OsobneCislo, "")))
        v = Val(s)
        If v > 0 Then
            d(CStr(CLng(v))) = True
        ElseIf Len(s) > 0 Then
            d(s) = True
        End If
        rs.MoveNext
    Loop
    rs.Close
    Set NacitajOC = d
End Function

'-------------------------------------------------------------------------------
' Vytvorí slovník kódov (fondov, kalendárov, šablón) použitých v tabuľke ZamestnanciFondy pre filtrovanie.
'-------------------------------------------------------------------------------
Private Function NacitajPouzite(ByVal pole As String) As Object
    Dim d As Object, rs As DAO.Recordset
    Set d = CreateObject("Scripting.Dictionary")
    Set rs = CurrentDb.OpenRecordset("SELECT DISTINCT " & pole & " FROM ZamestnanciFondy WHERE " & pole & " IS NOT NULL AND " & pole & " <> 0", dbOpenSnapshot)
    Do While Not rs.EOF
        d(CStr(CLng(rs.Fields(0).Value))) = True
        rs.MoveNext
    Loop
    rs.Close
    Set NacitajPouzite = d
End Function

'-------------------------------------------------------------------------------
' Vyhľadá požadovaný DBF súbor v adresári zo zoznamu možných názvov a zapíše varovanie v prípade absencie.
'-------------------------------------------------------------------------------
Private Function NajdiAleboLog(ByVal Adresar As String, ByVal popis As String, ParamArray Nazvy() As Variant) As String
    Dim i As Long, cesta As String
    For i = LBound(Nazvy) To UBound(Nazvy)
        cesta = mod_00_Common.NajdiSuborVAdresari(Adresar, CStr(Nazvy(i)))
        If Len(cesta) > 0 Then NajdiAleboLog = cesta: Exit Function
    Next i
    Call mod_00_Common.ZapisLog("NajdiSubor", "WARN", "Súbor pre " & popis & " sa v adresári '" & Adresar & "' nenašiel.")
End Function

'-------------------------------------------------------------------------------
' Zisťuje a overuje rozsah importovaného obdobia (od mesiac/rok po mesiac/rok) z GUI alebo vyzvaním.
'-------------------------------------------------------------------------------
Public Function ZistiObdobieImportu(ByRef odM As Long, ByRef odR As Long, ByRef doM As Long, ByRef doR As Long) As Boolean
    On Error Resume Next
    Dim lR As Long, lM As Long, bZFormulara As Boolean
    odM = 0: odR = 0: doM = 0: doR = 0
    Set mFilterOC = Nothing

    ' 1) Hlavná konzola (karta Import): výber mesiacov + osobné čísla
    If mod_00_Common.FormIsOpen("frmHlavnaKonzola") Then
        If mod_UI_Spolocne.ObdobieZVyberu(Forms!frmHlavnaKonzola!cboImportOd, lR, lM) Then odR = lR: odM = lM
        If mod_UI_Spolocne.ObdobieZVyberu(Forms!frmHlavnaKonzola!cboImportDo, lR, lM) Then doR = lR: doM = lM
        Call NastavFilterOC(Nz(Forms!frmHlavnaKonzola!txtImportOC, ""))
        bZFormulara = (odR > 0 And doR > 0)
    ' 2) Starší formulár sprievodcu importom (spätná kompatibilita)
    ElseIf mod_00_Common.FormIsOpen("frmSprievodcaImportom") Then
        odM = Val(Nz(Forms!frmSprievodcaImportom!txtOdMesiac, 0))
        odR = Val(Nz(Forms!frmSprievodcaImportom!txtOdRok, 0))
        doM = Val(Nz(Forms!frmSprievodcaImportom!txtDoMesiac, 0))
        doR = Val(Nz(Forms!frmSprievodcaImportom!txtDoRok, 0))
        bZFormulara = True
    End If

    ' 3) Bez formulára: posledné použité obdobie z nastavení, inak otázka
    If Not bZFormulara Then
        lR = CLng(Val(mod_00_Common.GetNastavenie("ImportObdobieOd", "0")))
        lM = CLng(Val(mod_00_Common.GetNastavenie("ImportObdobieDo", "0")))
        If lR > 199000 And lM > 199000 Then
            odR = lR \ 100: odM = lR Mod 100: doR = lM \ 100: doM = lM Mod 100
        Else
            Dim inp As String, p() As String, pOd() As String, pDo() As String
            inp = InputBox("Zadajte obdobie pre import vo formáte: MM.YYYY-MM.YYYY" & vbCrLf & "(Napríklad: 01.2026-10.2026)", "Obdobie importu", "01." & Year(Date) & "-" & Format$(Month(Date), "00") & "." & Year(Date))
            If Len(inp) > 0 And InStr(inp, "-") > 0 Then
                p = Split(inp, "-")
                If UBound(p) = 1 Then
                    pOd = Split(Trim$(p(0)), ".")
                    pDo = Split(Trim$(p(1)), ".")
                    If UBound(pOd) = 1 And UBound(pDo) = 1 Then
                        odM = Val(pOd(0)): odR = Val(pOd(1))
                        doM = Val(pDo(0)): doR = Val(pDo(1))
                    End If
                End If
            End If
        End If
    End If

    If odM < 1 Or odM > 12 Then odM = 1
    If odR < 1990 Then odR = Year(Date)
    If doM < 1 Or doM > 12 Then doM = Month(Date)
    If doR < 1990 Then doR = Year(Date)
    If odR * 100 + odM > doR * 100 + doM Then
        lR = odR: lM = odM: odR = doR: odM = doM: doR = lR: doM = lM
    End If

    Call mod_00_Common.ZapisLog("ZistiObdobieImportu", "INFO", "Obdobie importu: " & Format$(odM, "00") & "/" & odR & " - " & Format$(doM, "00") & "/" & doR & _
                                IIf(PocetFiltraOC() > 0, ", osobné čísla: " & PocetFiltraOC(), ", všetci zamestnanci"))
    ZistiObdobieImportu = True
End Function

'-------------------------------------------------------------------------------
' Nastaví filter osobných čísel pre import (text s ľubovoľným oddeľovačom; prázdny = všetci).
' Čísla sa normalizujú rovnako ako pri importe razení (bez úvodných núl).
'-------------------------------------------------------------------------------
Public Sub NastavFilterOC(ByVal strText As String)
    Dim a As Variant, v As Variant, strNez As String, d As Double
    Set mFilterOC = CreateObject("Scripting.Dictionary")
    a = mod_UI_Spolocne.OsobneCislaZTextu(strText, strNez, False)
    If Not IsArray(a) Then Exit Sub
    For Each v In a
        d = Val(CStr(v))
        If d > 0 And d < 2147483647# Then mFilterOC(CStr(CLng(d))) = True Else mFilterOC(CStr(v)) = True
    Next v
End Sub

'-------------------------------------------------------------------------------
' Počet osobných čísel vo filtri importu (0 = bez filtra).
'-------------------------------------------------------------------------------
Public Function PocetFiltraOC() As Long
    If mFilterOC Is Nothing Then Exit Function
    PocetFiltraOC = mFilterOC.Count
End Function

'-------------------------------------------------------------------------------
' Patrí osobné číslo (normalizované) do filtra importu? Bez filtra vždy TRUE.
'-------------------------------------------------------------------------------
Private Function JeVoFiltri(ByVal strOC As String) As Boolean
    If mFilterOC Is Nothing Then JeVoFiltri = True: Exit Function
    If mFilterOC.Count = 0 Then JeVoFiltri = True: Exit Function
    JeVoFiltri = mFilterOC.Exists(strOC)
End Function

'-------------------------------------------------------------------------------
' SQL podmienka " AND OsobneCislo IN (...)" pre filter importu ("" bez filtra).
'-------------------------------------------------------------------------------
Private Function SqlFiltraOC() As String
    If PocetFiltraOC() = 0 Then Exit Function
    SqlFiltraOC = " AND OsobneCislo IN (" & mod_UI_Spolocne.SqlZoznamOC(mFilterOC.Keys) & ")"
End Function

'-------------------------------------------------------------------------------
' Načíta aktuálny zdrojový adresár DBF súborov z formulára sprievodcu alebo systémových nastavení.
'-------------------------------------------------------------------------------
Public Function GetAktualnyAdresarDBF() As String
    Dim adr As String
    On Error Resume Next
    If mod_00_Common.FormIsOpen("frmHlavnaKonzola") Then
        adr = Trim(Nz(Forms!frmHlavnaKonzola!txtAdresarDBF, ""))
        If Len(adr) > 0 Then
            If Right$(adr, 1) = "\" And Len(adr) > 3 Then adr = Left$(adr, Len(adr) - 1)
            Call mod_00_Common.SetNastavenie("CestaDBFAdresar", adr, "Adresár pre import DBF")
            GetAktualnyAdresarDBF = adr
            Exit Function
        End If
    End If
    On Error GoTo 0
    If mod_00_Common.FormIsOpen("frmSprievodcaImportom") Then
        adr = Trim(Nz(Forms!frmSprievodcaImportom!txtAdresarDBF, ""))
        If Len(adr) > 0 Then
            Call mod_00_Common.SetNastavenie("CestaDBFAdresar", adr, "Adresár pre import DBF")
            GetAktualnyAdresarDBF = adr
            Exit Function
        End If
    End If
    adr = mod_00_Common.GetNastavenie("CestaDBFAdresar", "")
    GetAktualnyAdresarDBF = adr
End Function

'-------------------------------------------------------------------------------
' Importuje zoznam zamestnancov (osobné číslo, meno, stredisko, karta) zo súboru cis_zamestnanec.dbf.
'-------------------------------------------------------------------------------
Public Sub ImportZamestnancovDBFPriamo(Optional ByVal CestaKSuboru As String = "")
    On Error GoTo ChybaHandler
    Dim t As DbfTab, rs As DAO.Recordset, poznane As Object
    Dim filePath As String, d As Double, oc As String
    Dim ocMin As Double, ocMax As Double
    Dim pocNovych As Long, pocAktual As Long, pocMimo As Long
    Dim pfx As String

    Call PripravStrukturu
    Call NacitajFilterOC
    filePath = CestaKSuboru
    If Len(filePath) = 0 Then filePath = NajdiAleboLog(GetAktualnyAdresarDBF(), "zamestnancov (CIS_ZAMESTNANEC)", "cis_zamestnanec.dbf")
    If Len(filePath) = 0 Then Exit Sub
    If Not DbfOtvor(filePath, t) Then Exit Sub

    ocMin = Val(mod_00_Common.GetNastavenie("OCMin", "1000000"))
    ocMax = Val(mod_00_Common.GetNastavenie("OCMax", "9999999"))
    
    pfx = IIf(mBatch, "[Krok 1/6] ", "")
    Call AktualizujProgress(pfx & "Importujem zamestnancov (cis_zamestnanec.dbf)...", 0, t.PocetZaznamov)

    Set poznane = NacitajOC()
    Set rs = CurrentDb.OpenRecordset("SELECT * FROM Zamestnanci", dbOpenDynaset)

    Do While DbfDalsi(t)
        d = DbfCislo(t, "OS_CISLO|OS_CIS")
        If d >= ocMin And d <= ocMax Then oc = CStr(CLng(d)) Else oc = ""
        If Len(oc) > 0 And Not JeVoFiltri(oc) Then
            pocMimo = pocMimo + 1
        ElseIf Len(oc) > 0 Then
            If poznane.Exists(oc) Then
                rs.FindFirst "OsobneCislo='" & oc & "'"
                If Not rs.NoMatch Then
                    rs.Edit
                    Call NastavPoliaZamestnanca(rs, t, False)
                    rs.Update
                    pocAktual = pocAktual + 1
                End If
            Else
                rs.AddNew
                rs!OsobneCislo = oc
                rs!ADAktivny = True
                rs!DatumImportu = Now()
                Call NastavPoliaZamestnanca(rs, t, True)
                rs.Update
                poznane(oc) = True
                pocNovych = pocNovych + 1
            End If
        Else
            pocMimo = pocMimo + 1
        End If
        If (t.Prejdenych Mod 30) = 0 Or t.Prejdenych = t.PocetZaznamov Then
            Call AktualizujProgress(pfx & "Načítavam zamestnancov...", t.Prejdenych, t.PocetZaznamov)
        End If
    Loop

    rs.Close
    Call DbfZatvor(t)
    Call mod_00_Common.ZapisLog("ImportZamestnancovDBFPriamo", "INFO", "Zamestnanci z DBF: nových " & pocNovych & ", aktualizovaných " & pocAktual & ".")
    If pocNovych + pocAktual > 0 Then Call PosunKrok(2)
    Call ZavriProgress
    Exit Sub
ChybaHandler:
    Call ChybaImportu("ImportZamestnancovDBFPriamo", Err.Number, Err.Description)
    On Error Resume Next
    If Not rs Is Nothing Then rs.Close
    Call DbfZatvor(t)
    Call ZavriProgress
End Sub

'-------------------------------------------------------------------------------
' Pomocná procedúra pre nastavenie osobnostných a organizačných polí zamestnanca z DBF záznamu.
'-------------------------------------------------------------------------------
Private Sub NastavPoliaZamestnanca(ByRef rs As DAO.Recordset, ByRef t As DbfTab, ByVal jeNovy As Boolean)
    rs!Titul = NV(Left$(DbfText(t, "TITUL"), 20))
    If jeNovy Or Len(Nz(rs!Meno, "")) = 0 Then rs!Meno = NV(Left$(DbfText(t, "MENO"), 50))
    If jeNovy Or Len(Nz(rs!Priezvisko, "")) = 0 Then rs!Priezvisko = NV(Left$(DbfText(t, "PRIEZVISKO"), 50))
    rs!CisloKarty = DbfLong(t, "CIS_KARTY")
    rs!StrediskoCislo = DbfLong(t, "CIS_STRE")
    rs!StrediskoNazov = NV(Left$(DbfText(t, "STREDISKO"), 50))
    rs!OrganizaciaCislo = DbfLong(t, "CIS_ORGA")
    rs!BlokovanyStary = DbfBool(t, "BLOK")
End Sub

'-------------------------------------------------------------------------------
' Importuje mesačné priradenie fondov, kalendárov a šablón zamestnancom zo súboru cis_zamdoch.dbf.
'-------------------------------------------------------------------------------
Public Sub ImportZamestnanciFondyDBF(ByVal CestaDBF As String)
    If Len(CestaDBF) = 0 Then Exit Sub
    On Error GoTo ChybaHandler
    If Not mod_18_Uzavierka.PrepisNastaveniPovoleny("priradenia fondov zamestnancom") Then Exit Sub
    Dim t As DbfTab, rs As DAO.Recordset, poznane As Object, kluce As Object
    Dim oc As String, rVal As Long, mVal As Long, kluc As String, pocet As Long
    Dim pfx As String

    Call PripravStrukturu
    Call NacitajObdobie
    If Not DbfOtvor(CestaDBF, t) Then Exit Sub

    pfx = IIf(mBatch, "[Krok 2/6] ", "")
    Call AktualizujProgress(pfx & "Importujem priradenie fondov (cis_zamdoch.dbf)...", 0, t.PocetZaznamov)

    Set poznane = NacitajOC()
    Set kluce = CreateObject("Scripting.Dictionary")
    CurrentDb.Execute "DELETE FROM ZamestnanciFondy", dbFailOnError
    Set rs = CurrentDb.OpenRecordset("ZamestnanciFondy", dbOpenDynaset, dbAppendOnly)

    Do While DbfDalsi(t)
        oc = CStr(DbfLong(t, "OS_CISLO|OS_CIS"))
        If poznane.Exists(oc) Then
            mVal = DbfLong(t, "MESIAC")
            rVal = DbfLong(t, "ROK")
            ' Bez obmedzenia na spracovávané obdobie - ROK a MESIAC predstavujú začiatok platnosti šablóny ("Platí od")
            kluc = oc & "|" & rVal & "|" & mVal
            If Not kluce.Exists(kluc) Then
                kluce(kluc) = True
                rs.AddNew
                rs!OsobneCislo = oc
                rs!PracFondKod = DbfLong(t, "S_PRACFOND")
                rs!ParDochKod = DbfLong(t, "S_PARDOCH")
                rs!ParPrerKod = DbfLong(t, "S_PARPRER")
                rs!KalendarKod = DbfLong(t, "S_KALENDAR")
                rs!ZmenyKod = DbfLong(t, "S_ZMENY")
                rs!rok = rVal
                rs!Mesiac = mVal
                rs.Update
                pocet = pocet + 1
            End If
        End If

        If (t.Prejdenych Mod 50) = 0 Or t.Prejdenych = t.PocetZaznamov Then
            Call AktualizujProgress(pfx & "Importujem priradenie fondov...", t.Prejdenych, t.PocetZaznamov)
        End If
    Loop

    rs.Close
    Call DbfZatvor(t)
    Call mod_00_Common.ZapisLog("ImportZamestnanciFondyDBF", IIf(pocet > 0, "INFO", "WARN"), "Priradení fondov zamestnancom: " & pocet)
    Call ZavriProgress
    Exit Sub
ChybaHandler:
    Call ChybaImportu("ImportZamestnanciFondyDBF", Err.Number, Err.Description)
    On Error Resume Next
    If Not rs Is Nothing Then rs.Close
    Call DbfZatvor(t)
    Call ZavriProgress
End Sub

'-------------------------------------------------------------------------------
' Súčasná hodnota textového poľa a hodnota z Ordata sa líšia (bez ohľadu na medzery na okrajoch, rozlišuje malé/veľké písmená a diakritiku).
'-------------------------------------------------------------------------------
Private Function InyText(ByVal vAccess As Variant, ByVal strOrdata As String) As Boolean
    InyText = (StrComp(Trim$(CStr(Nz(vAccess, ""))), Trim$(strOrdata), vbBinaryCompare) <> 0)
End Function

'-------------------------------------------------------------------------------
' Rozdiely medzi prerušením v Accesse (rs) a riadkom z Ordata (p = Array(číslo, názov, skratka, predvolba, kódZ, kódK, textZ, textK, funZ, funK)).
' Vráti čitateľný zoznam rozdielov ("" = rovnaké); bKody sa nastaví, ak sa líšia kódy razení.
'-------------------------------------------------------------------------------
Private Function RozdielPreruseni(ByRef rs As DAO.Recordset, ByVal p As Variant, ByRef bKody As Boolean) As String
    Dim s As String
    If InyText(rs!Nazov, CStr(p(1))) Then s = s & "názov „" & Trim$(CStr(Nz(rs!Nazov, ""))) & "“ -> „" & CStr(p(1)) & "“; "
    If InyText(rs!NazovSkratka, CStr(p(2))) Then s = s & "skratka „" & Trim$(CStr(Nz(rs!NazovSkratka, ""))) & "“ -> „" & CStr(p(2)) & "“; "
    If InyText(rs!TextPredvolba, CStr(p(3))) Then s = s & "predvoľba „" & Trim$(CStr(Nz(rs!TextPredvolba, ""))) & "“ -> „" & CStr(p(3)) & "“; "
    If CLng(Nz(rs!KodZaciatok, 0)) <> CLng(p(4)) Or CLng(Nz(rs!KodKoniec, 0)) <> CLng(p(5)) Then
        s = s & "kódy razení " & CLng(Nz(rs!KodZaciatok, 0)) & "/" & CLng(Nz(rs!KodKoniec, 0)) & " -> " & CLng(p(4)) & "/" & CLng(p(5)) & "; "
        bKody = True
    End If
    If CLng(Nz(rs!FunkciaZaciatok, 0)) <> CLng(p(8)) Or CLng(Nz(rs!FunkciaKoniec, 0)) <> CLng(p(9)) Then
        s = s & "funkcie razení " & CLng(Nz(rs!FunkciaZaciatok, 0)) & "/" & CLng(Nz(rs!FunkciaKoniec, 0)) & " -> " & CLng(p(8)) & "/" & CLng(p(9)) & "; "
    End If
    If InyText(rs!TextZaciatok, CStr(p(6))) Then s = s & "text začiatku „" & Trim$(CStr(Nz(rs!TextZaciatok, ""))) & "“ -> „" & CStr(p(6)) & "“; "
    If InyText(rs!TextKoniec, CStr(p(7))) Then s = s & "text konca „" & Trim$(CStr(Nz(rs!TextKoniec, ""))) & "“ -> „" & CStr(p(7)) & "“; "
    If Len(s) > 0 Then s = Left$(s, Len(s) - 2)
    RozdielPreruseni = s
End Function

'-------------------------------------------------------------------------------
' Kód razenia z Ordata už v Accesse patrí inému prerušeniu (kolízia). Vráti text kolízie alebo "".
'-------------------------------------------------------------------------------
Private Function KoliziaKodu(ByVal lKod As Long, ByVal lCislo As Long) As String
    Dim v As Variant
    If lKod <= 0 Then Exit Function
    v = DLookup("CisloPreruseni", "KodyRazeni", "KodRazenia = " & lKod)
    If Not IsNull(v) Then
        If CLng(v) <> lCislo And CLng(v) > 0 Then KoliziaKodu = "kód razenia " & lKod & " už patrí prerušeniu " & CLng(v)
    End If
End Function

'-------------------------------------------------------------------------------
' Importuje číselník prerušení a generuje párové kódy razení pre príchody a odchody (cis_preruseni.dbf).
' Bezpečný import: súbor sa najprv načíta a porovná so súčasným číselníkom v Accesse. Prerušenia, ktoré v Accesse chýbajú, sa pridajú.
' Ak sa niektoré existujúce prerušenie líši (názov, skratka, texty, kódy razení), ukáže sa zoznam rozdielov a opýta sa RAZ:
' Áno = prepísať súčasné hodnoty hodnotami z Ordata, Nie (predvolené) = ponechať súčasné. Nové prerušenie, ktorého kód razenia
' už patrí inému prerušeniu, sa pri odpovedi Nie nepridá.
'-------------------------------------------------------------------------------
Public Sub ImportPreruseniDBFPriamo(Optional ByVal CestaKSuboru As String = "")
    On Error GoTo ChybaHandler
    Dim t As DbfTab, db As DAO.Database, rsC As DAO.Recordset
    Dim filePath As String, Cislo As Long, nazov As String
    Dim kodZ As Long, kodK As Long, txtZ As String, txtK As String
    Dim pocetP As Long, pocetK As Long, pfx As String
    Dim polozky As Collection, p As Variant, strR As String, strKol As String
    Dim strZoznam As String, strPrompt As String, nRozdiel As Long, nPonechane As Long, nNove As Long, nPreskocene As Long
    Dim bKody As Boolean, bPrevziat As Boolean, bNove As Boolean, bZapis As Boolean, nRiadkov As Long

    Call PripravStrukturu
    filePath = CestaKSuboru
    If Len(filePath) = 0 Then filePath = NajdiAleboLog(GetAktualnyAdresarDBF(), "číselníka prerušení (CIS_PRERUSENI)", "cis_preruseni.dbf", "CIS_PRERUS.DBF", "CIS_PRER.DBF", "PRERUSENI.DBF")
    If Len(filePath) = 0 Then Exit Sub
    If Not DbfOtvor(filePath, t) Then Exit Sub

    pfx = IIf(mBatch, "[Krok 3/6] ", "")
    Call AktualizujProgress(pfx & "Načítavam číselník prerušení (cis_preruseni.dbf)...", 0, t.PocetZaznamov)

    ' 1. načítanie súboru do pamäte
    Set polozky = New Collection
    Do While DbfDalsi(t)
        Cislo = DbfLong(t, "CISLO")
        If Cislo > 0 Then
            nazov = DbfText(t, "NAZOV|NAZOV_PRER")
            kodZ = DbfLong(t, "KOD_ZAC|KOD_ODCH")
            kodK = DbfLong(t, "KOD_KON|KOD_PRICH")
            txtZ = DbfText(t, "TEXT_ZAC")
            txtK = DbfText(t, "TEXT_KON")
            If Len(txtZ) = 0 Then txtZ = nazov & " - zaciatok"
            If Len(txtK) = 0 Then txtK = nazov & " - koniec"
            polozky.Add Array(Cislo, Left$(nazov, 100), Left$(DbfText(t, "NAZOV_SKR"), 20), Left$(DbfText(t, "TEXT_PRED"), 50), kodZ, kodK, _
                              Left$(txtZ, 50), Left$(txtK, 50), DbfLong(t, "FUN_ZAC"), DbfLong(t, "FUN_KON"))
        End If
    Loop
    Call DbfZatvor(t)

    ' 2. porovnanie so súčasným číselníkom
    Set db = CurrentDb
    Set rsC = db.OpenRecordset("SELECT * FROM CiselnikPreruseni", dbOpenDynaset)
    For Each p In polozky
        nRiadkov = nRiadkov + 1
        rsC.FindFirst "Cislo=" & CLng(p(0))
        If rsC.NoMatch Then
            strR = ""
            strKol = KoliziaKodu(CLng(p(4)), CLng(p(0)))
            If Len(strKol) = 0 Then strKol = KoliziaKodu(CLng(p(5)), CLng(p(0)))
            If Len(strKol) > 0 Then strR = "nové prerušenie: " & strKol
        Else
            strR = RozdielPreruseni(rsC, p, bKody)
        End If
        If Len(strR) > 0 Then
            nRozdiel = nRozdiel + 1
            strZoznam = strZoznam & "č. " & CLng(p(0)) & ": " & strR & vbCrLf
        End If
    Next p

    ' 3. jedno rozhodnutie za import (bez rozdielov sa nepýta)
    bPrevziat = True
    If nRozdiel > 0 Then
        Call mod_00_Common.ZapisLog("ImportPreruseniDBFPriamo", "WARN", "Číselník prerušení z Ordata sa líši v " & nRozdiel & " prerušeniach.", strZoznam)
        strPrompt = "Číselník prerušení z Ordata sa líši od súčasného v Accesse (" & nRozdiel & " z " & nRiadkov & " prerušení):" & vbCrLf & vbCrLf & _
                    UkazkaRiadkov(strZoznam, 480) & vbCrLf & _
                    IIf(bKody, "POZOR: líšia sa aj kódy razení. Ak ponecháte súčasné, razenia z Ordata s inými kódmi sa nepriradia k týmto prerušeniam." & vbCrLf & vbCrLf, "") & _
                    "Áno = prepísať hodnotami z Ordata" & vbCrLf & "Nie = ponechať súčasné (odporúčané); chýbajúce prerušenia sa pridajú" & vbCrLf & _
                    "(úplný zoznam je v logu)"
        bPrevziat = (MsgBox(strPrompt, vbQuestion + vbYesNo + vbDefaultButton2, "Import číselníka prerušení z Ordata") = vbYes)
    End If

    ' 4. zápis
    Call AktualizujProgress(pfx & "Importujem číselník prerušení...", 0, nRiadkov)
    For Each p In polozky
        rsC.FindFirst "Cislo=" & CLng(p(0))
        bNove = rsC.NoMatch
        bZapis = True
        If bNove Then
            If Not bPrevziat Then
                If Len(KoliziaKodu(CLng(p(4)), CLng(p(0)))) > 0 Or Len(KoliziaKodu(CLng(p(5)), CLng(p(0)))) > 0 Then bZapis = False
            End If
            If bZapis Then
                rsC.AddNew
                rsC!Cislo = CLng(p(0))
                rsC!TypVypoctu = "STANDARD"
            Else
                nPreskocene = nPreskocene + 1
            End If
        ElseIf bPrevziat Then
            rsC.Edit
        Else
            bZapis = False
            nPonechane = nPonechane + 1
        End If

        If bZapis Then
            rsC!nazov = NV(CStr(p(1)))
            rsC!NazovSkratka = NV(CStr(p(2)))
            rsC!TextPredvolba = NV(CStr(p(3)))
            rsC!KodZaciatok = CLng(p(4))
            rsC!TextZaciatok = NV(CStr(p(6)))
            rsC!FunkciaZaciatok = CLng(p(8))
            rsC!KodKoniec = CLng(p(5))
            rsC!TextKoniec = NV(CStr(p(7)))
            rsC!FunkciaKoniec = CLng(p(9))
            rsC.Update
            pocetP = pocetP + 1
            If bNove Then nNove = nNove + 1

            If CLng(p(4)) > 0 Then Call UlozKodRazenia(db, CLng(p(4)), CLng(p(0)), "Z", CStr(p(6)), CStr(p(1))): pocetK = pocetK + 1
            If CLng(p(5)) > 0 Then Call UlozKodRazenia(db, CLng(p(5)), CLng(p(0)), "K", CStr(p(7)), CStr(p(1))): pocetK = pocetK + 1
        End If
    Next p

    rsC.Close
    Call DoplnPrerusenieDoDochadzky
    Call mod_00_Common.ZapisLog("ImportPreruseniDBFPriamo", "INFO", "Číselník prerušení: zapísaných " & pocetP & " (z toho nových " & nNove & "), ponechaných súčasných " & nPonechane & _
                                ", nepridaných pre kolíziu kódu " & nPreskocene & ", kódov razení " & pocetK & IIf(nRozdiel > 0, ", rozdiely: " & IIf(bPrevziat, "prevzaté z Ordata", "ponechané súčasné"), "") & ".")
    If nRozdiel > 0 Then
        mPoznamkyImportu = mPoznamkyImportu & "Číselník prerušení: " & IIf(bPrevziat, "rozdiely (" & nRozdiel & ") sa prevzali z Ordata.", "rozdiely (" & nRozdiel & ") sa ponechali podľa Accessu; pridaných nových prerušení " & nNove & IIf(nPreskocene > 0, ", nepridaných pre kolíziu kódu " & nPreskocene, "") & ".") & vbCrLf
    End If
    Call PosunKrok(5)
    Call ZavriProgress
    Exit Sub
ChybaHandler:
    Call ChybaImportu("ImportPreruseniDBFPriamo", Err.Number, Err.Description)
    On Error Resume Next
    If Not rsC Is Nothing Then rsC.Close
    Call DbfZatvor(t)
    Call ZavriProgress
End Sub

'-------------------------------------------------------------------------------
' Prvé riadky zoznamu (najviac lMax znakov), každý skrátený; zvyšok nahradí poznámkou "a ďalších N".
'-------------------------------------------------------------------------------
Private Function UkazkaRiadkov(ByVal strZoznam As String, ByVal lMax As Long) As String
    Dim a() As String, i As Long, s As String, strR As String, nZvysok As Long
    a = Split(strZoznam, vbCrLf)
    For i = LBound(a) To UBound(a)
        If Len(a(i)) > 0 Then
            strR = a(i)
            If Len(strR) > 110 Then strR = Left$(strR, 107) & "..."
            If Len(s) + Len(strR) + 2 > lMax Then
                nZvysok = nZvysok + 1
            Else
                s = s & strR & vbCrLf
            End If
        End If
    Next i
    If nZvysok > 0 Then s = s & "... a ďalších " & nZvysok & vbCrLf
    UkazkaRiadkov = s
End Function

'-------------------------------------------------------------------------------
' Zapisuje alebo aktualizuje kód razenia v tabuľkách KodyRazeni a TypyUdalosti.
'-------------------------------------------------------------------------------
Private Sub UlozKodRazenia(ByVal db As DAO.Database, ByVal kod As Long, ByVal Cislo As Long, _
                           ByVal smer As String, ByVal textRazenia As String, ByVal nazovPrerusenia As String)
    Dim rs As DAO.Recordset
    Set rs = db.OpenRecordset("SELECT * FROM KodyRazeni WHERE KodRazenia=" & kod, dbOpenDynaset)
    If rs.EOF Then
        rs.AddNew
        rs!KodRazenia = kod
    Else
        rs.Edit
    End If
    rs!CisloPreruseni = Cislo
    rs!smer = smer
    rs!textRazenia = NV(Left$(textRazenia, 50))
    rs.Update
    rs.Close

    Set rs = db.OpenRecordset("SELECT * FROM TypyUdalosti WHERE Kod=" & kod, dbOpenDynaset)
    If rs.EOF Then
        rs.AddNew
        rs!kod = kod
    Else
        rs.Edit
    End If
    rs!nazov = NV(Left$(textRazenia, 100))
    rs!Typ = smer
    rs!Kategoria = NV(Left$(nazovPrerusenia, 50))
    rs!ZapocitatDoPrace = (Cislo = 1)
    rs.Update
    rs.Close
End Sub

'-------------------------------------------------------------------------------
' Dopočíta a priradí číslo prerušenia a smer (Z/K) ku všetkým razeniam v tabuľke DochadzkaImport.
'-------------------------------------------------------------------------------
Public Sub DoplnPrerusenieDoDochadzky()
    On Error GoTo ChybaHandler
    If DCount("*", "KodyRazeni") = 0 Then Exit Sub
    CurrentDb.Execute "UPDATE DochadzkaImport AS D INNER JOIN KodyRazeni AS K ON D.KodPrerusenia = K.KodRazenia " & _
                      "SET D.CisloPreruseni = K.CisloPreruseni, D.Smer = K.Smer" & _
                      Replace(mod_18_Uzavierka.SqlVynechUzavrete(), " AND ID NOT IN", " WHERE D.ID NOT IN", 1, 1), dbFailOnError
    Exit Sub
ChybaHandler:
    Call ChybaImportu("DoplnPrerusenieDoDochadzky", Err.Number, Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Importuje definície pracovných fondov a ich denné časové hranice (cis_pracfondy.dbf a cis_pracfondzme.dbf).
'-------------------------------------------------------------------------------
Public Sub ImportPracovnychFondovDBF(ByVal Adresar As String)
    If Len(Adresar) = 0 Then Exit Sub
    On Error GoTo ChybaHandler
    If Not mod_18_Uzavierka.PrepisNastaveniPovoleny("pracovné fondy") Then Exit Sub
    Dim db As DAO.Database, t As DbfTab, rs As DAO.Recordset
    Dim pouzite As Object, kluce As Object
    Dim cesta As String, Cislo As Long, rok As Long, mes As Long, den As Long, kluc As String, z As Long
    Dim pocH As Long, pocD As Long, pfx As String

    Call PripravStrukturu
    Call NacitajObdobie
    Set db = CurrentDb
    Set pouzite = NacitajPouzite("PracFondKod")
    Set kluce = CreateObject("Scripting.Dictionary")

    pfx = IIf(mBatch, "[Krok 4/6] ", "")

    cesta = NajdiAleboLog(Adresar, "pracovných fondov (CIS_PRACFONDY)", "cis_pracfondy.dbf")
    If Len(cesta) = 0 Then Exit Sub
    If Not DbfOtvor(cesta, t) Then Exit Sub

    Call AktualizujProgress(pfx & "Importujem pracovné fondy...", 0, t.PocetZaznamov)

    db.Execute "DELETE FROM PracovneFondyDni", dbFailOnError
    db.Execute "DELETE FROM PracovneFondy", dbFailOnError
    Set rs = db.OpenRecordset("PracovneFondy", dbOpenDynaset, dbAppendOnly)

    Do While DbfDalsi(t)
        Cislo = DbfLong(t, "CISLO")
        rok = DbfLong(t, "ROK")
        mes = DbfLong(t, "MESIAC")
        If Cislo > 0 Then
            If pouzite.Count = 0 Or pouzite.Exists(CStr(Cislo)) Then
                If JeVObdobi(rok, mes) Then
                    kluc = Cislo & "|" & rok & "|" & mes
                    If Not kluce.Exists(kluc) Then
                        kluce(kluc) = True
                        rs.AddNew
                        rs!Cislo = Cislo
                        rs!rok = rok
                        rs!Mesiac = mes
                        rs!nazov = NV(Left$(DbfText(t, "NAZOV"), 100))
                        rs!AutoGenerovanie = DbfBool(t, "AUTO_GEN")
                        rs!PocetZmien = DbfLong(t, "POC_ZMIEN")
                        rs!TypFondu = DbfLong(t, "TYP_FONDU")
                        rs!TypOpakovania = DbfLong(t, "TYP_OPAK")
                        rs!PriemernaDlzkaMin = DbfLong(t, "PRIEMER")
                        rs!DlzkaMesiacaMin = DbfLong(t, "DLZKA_MES")
                        rs!AutoPVDni = DbfBool(t, "AUTOPVDNI")
                        rs!AutoPS = DbfBool(t, "AUTOPS")
                        rs.Update
                        pocH = pocH + 1
                    End If
                End If
            End If
        End If

        If (t.Prejdenych Mod 20) = 0 Or t.Prejdenych = t.PocetZaznamov Then
            Call AktualizujProgress(pfx & "Importujem pracovné fondy...", t.Prejdenych, t.PocetZaznamov)
        End If
    Loop
    rs.Close
    Call DbfZatvor(t)

    cesta = NajdiAleboLog(Adresar, "denných hraníc fondov (CIS_PRACFONDZME)", "cis_pracfondzme.dbf")
    If Len(cesta) > 0 Then
        If DbfOtvor(cesta, t) Then
            Call AktualizujProgress(pfx & "Importujem denné hranice fondov...", 0, t.PocetZaznamov)
            Set rs = db.OpenRecordset("PracovneFondyDni", dbOpenDynaset, dbAppendOnly)
            Set pouzite = CreateObject("Scripting.Dictionary")
            Do While DbfDalsi(t)
                Cislo = DbfLong(t, "CISLO")
                rok = DbfLong(t, "ROK")
                mes = DbfLong(t, "MESIAC")
                den = DbfLong(t, "DEN")
                If kluce.Exists(Cislo & "|" & rok & "|" & mes) Then
                    kluc = Cislo & "|" & rok & "|" & mes & "|" & den
                    If Not pouzite.Exists(kluc) Then
                        pouzite(kluc) = True
                        rs.AddNew
                        rs!Cislo = Cislo
                        rs!rok = rok
                        rs!Mesiac = mes
                        rs!den = den
                        For z = 1 To 3
                            rs.Fields("Zac" & z) = DbfLong(t, "ZAC" & z)
                            rs.Fields("Kon" & z) = DbfLong(t, "KON" & z)
                            rs.Fields("Prest1Zac" & z) = DbfLong(t, "PRESZAC" & z)
                            rs.Fields("Prest1Kon" & z) = DbfLong(t, "PRESKON" & z)
                            rs.Fields("Prest2Zac" & z) = DbfLong(t, "PRES2ZAC" & z)
                            rs.Fields("Prest2Kon" & z) = DbfLong(t, "PRES2KON" & z)
                            rs.Fields("MaxPred" & z) = DbfLong(t, "MAXPRED" & z)
                            rs.Fields("MaxPo" & z) = DbfLong(t, "MAXPO" & z)
                        Next z
                        rs!DlzkaSPrestavkouMin = DbfLong(t, "DLZKA")
                        rs!DlzkaBezPrestavkyMin = DbfLong(t, "DLZKA1")
                        rs!ZacVnutorne = DbfLong(t, "ZACVNU")
                        rs!KonVnutorne = DbfLong(t, "KONVNU")
                        rs.Update
                        pocD = pocD + 1
                    End If
                End If

                If (t.Prejdenych Mod 100) = 0 Or t.Prejdenych = t.PocetZaznamov Then
                    Call AktualizujProgress(pfx & "Importujem denné hranice fondov...", t.Prejdenych, t.PocetZaznamov)
                End If
            Loop
            rs.Close
            Call DbfZatvor(t)
        End If
    End If

    Call mod_00_Common.ZapisLog("ImportPracovnychFondovDBF", "INFO", "Pracovné fondy: " & pocH & ", denných hraníc: " & pocD)
    Call ZavriProgress
    Exit Sub
ChybaHandler:
    Call ChybaImportu("ImportPracovnychFondovDBF", Err.Number, Err.Description)
    On Error Resume Next
    If Not rs Is Nothing Then rs.Close
    Call DbfZatvor(t)
    Call ZavriProgress
End Sub

'-------------------------------------------------------------------------------
' Importuje parametre prerušení z Ordata (cis_parprer.dbf). Bezpečný import: preberá sa len na výslovné Áno (predvolené je Nie),
' súčasné riadky sa nemažú ani neprepisujú, dopĺňajú sa len riadky (šablóna, rok, mesiac, prerušenie), ktoré v Accesse ešte nie sú.
' Pri uzavretých mesiacoch sa import nevykoná (pridané riadky by zmenili parametre uzavretého mesiaca).
'-------------------------------------------------------------------------------
Public Sub ImportParametrovPreruseniDBF(ByVal CestaDBF As String)
    If Len(CestaDBF) = 0 Then Exit Sub
    On Error GoTo ChybaHandler
    If Not mod_18_Uzavierka.PrepisNastaveniPovoleny("pravidlá (parametre) prerušení", True) Then Exit Sub
    Dim db As DAO.Database, t As DbfTab, rs As DAO.Recordset, rsE As DAO.Recordset
    Dim pouzite As Object, kluce As Object, existujuce As Object
    Dim sablona As Long, rok As Long, mes As Long, cisPrer As Long, kluc As String
    Dim d As Long, pocet As Long, pocetPonechane As Long, pocetSucasne As Long, pfx As String

    Call PripravStrukturu
    Call NacitajObdobie
    Set db = CurrentDb
    pocetSucasne = DCount("*", "ParametrePreruseni")

    ' súhlas: parametre sa nepreberajú automaticky
    If MsgBox("Prevziať z Ordata aj parametre prerušení (povolený čas, najdlhšie a najkratšie trvanie prerušení)?" & vbCrLf & vbCrLf & _
              "Access z nich robí upozornenia v zozname anomálií a posiela ich aj terminálu v konfigurácii (šablóny); vypočítaný čas nemenia. " & _
              "Zaokrúhlenie a odpočet prestávky z Ordata Access nečíta." & vbCrLf & vbCrLf & _
              "Súčasné parametre v Accesse (riadkov: " & pocetSucasne & ") sa nemažú ani neprepisujú, doplnia sa len chýbajúce riadky." & vbCrLf & vbCrLf & _
              "Áno = doplniť z Ordata" & vbCrLf & "Nie = neprebrať (parametre môžete zadať ručne v editore Pravidlá prerušení)", _
              vbQuestion + vbYesNo + vbDefaultButton2, "Parametre prerušení z Ordata") <> vbYes Then
        Call mod_00_Common.ZapisLog("ImportParametrovPreruseniDBF", "INFO", "Parametre prerušení z Ordata sa neprevzali (voľba používateľa); súčasných riadkov: " & pocetSucasne)
        mPoznamkyImportu = mPoznamkyImportu & "Parametre prerušení: neprevzaté (súčasných riadkov " & pocetSucasne & ")." & vbCrLf
        Exit Sub
    End If

    If Not DbfOtvor(CestaDBF, t) Then Exit Sub

    pfx = IIf(mBatch, "[Krok 5/6] ", "")
    Call AktualizujProgress(pfx & "Importujem parametre prerušení (cis_parprer.dbf)...", 0, t.PocetZaznamov)

    Set pouzite = NacitajPouzite("ParPrerKod")
    Set kluce = CreateObject("Scripting.Dictionary")
    Set existujuce = CreateObject("Scripting.Dictionary")

    ' súčasné riadky sa zapamätajú, aby sa neprepisovali
    Set rsE = db.OpenRecordset("SELECT Sablona, Rok, Mesiac, CisloPreruseni FROM ParametrePreruseni;", dbOpenSnapshot)
    Do While Not rsE.EOF
        existujuce(CLng(Nz(rsE!sablona, 0)) & "|" & CLng(Nz(rsE!rok, 0)) & "|" & CLng(Nz(rsE!Mesiac, 0)) & "|" & CLng(Nz(rsE!CisloPreruseni, 0))) = True
        rsE.MoveNext
    Loop
    rsE.Close

    Set rs = db.OpenRecordset("ParametrePreruseni", dbOpenDynaset, dbAppendOnly)

    Do While DbfDalsi(t)
        sablona = DbfLong(t, "CISLO")
        rok = DbfLong(t, "ROK")
        mes = DbfLong(t, "MESIAC")
        cisPrer = DbfLong(t, "CIS_PRER")
        kluc = sablona & "|" & rok & "|" & mes & "|" & cisPrer
        If sablona > 0 And cisPrer > 0 Then
            If pouzite.Count = 0 Or pouzite.Exists(CStr(sablona)) Then
                If JeVObdobi(rok, mes) And Not kluce.Exists(kluc) Then
                    kluce(kluc) = True
                    If existujuce.Exists(kluc) Then
                        pocetPonechane = pocetPonechane + 1
                    Else
                        rs.AddNew
                        rs!sablona = sablona
                        rs!rok = rok
                        rs!Mesiac = mes
                        rs!CisloPreruseni = cisPrer
                        rs!NazovSablony = NV(Left$(DbfText(t, "NAZOV"), 50))
                        rs!NazovPreruseni = NV(Left$(DbfText(t, "NAZ_PRER"), 50))

                        On Error Resume Next
                        rs!KodPaM = DbfLong(t, "POLE13")
                        On Error GoTo ChybaHandler

                        rs!KonverznaTabulka = DbfLong(t, "POLE14")
                        rs!IntervalMesiacOdMin = DbfLong(t, "POLE16")
                        rs!IntervalMesiacDoMin = DbfLong(t, "POLE17")
                        rs!OdpocitaniePrestavky = DbfBool(t, "POLE15")
                        rs!ZaokruhlenieZaciatkuKonca = DbfLong(t, "POLE9")
                        rs!ZaokruhlenieTrvania = DbfLong(t, "POLE10")
                        rs!MaxTrvanieMesiacMin = DbfLong(t, "POLE11")
                        rs!PrerusenieAkPrekroceny = DbfLong(t, "POLE12")
                        rs!MaxTrvanieDniTyzdna = DbfBool(t, "MAXCAS_T")
                        rs!AutoDopocetTyp = DbfLong(t, "AUTO_DOP")
                        rs!AutoDopocetCasMin = DbfLong(t, "CAS_DOP")
                        rs!PredvolbaTyp = DbfLong(t, "PRED_TYP")
                        rs!PredvolbaCasMin = DbfLong(t, "PRED_CAS")
                        rs!PredvolbaVolnyDen = DbfBool(t, "PREDAJVOL")
                        rs!PredvolbaPracSviatok = DbfBool(t, "PREDAJPS")
                        rs!IntervalDniTyzdna = DbfBool(t, "CASODDOTYZ")
                        rs!PrevodTyp = DbfLong(t, "TYPPREPAM")
                        rs!PrevodCasMin = DbfLong(t, "CASPREPAM")
                        For d = 1 To 7
                            rs.Fields("MaxTrvanieDen" & d & "Min") = DbfLong(t, "MAXDEN" & d)
                            rs.Fields("IntervalDen" & d & "OdMin") = DbfLong(t, "CASOD" & d)
                            rs.Fields("IntervalDen" & d & "DoMin") = DbfLong(t, "CASDO" & d & "|CASODO" & d)
                        Next d
                        rs.Update
                        pocet = pocet + 1
                    End If
                End If
            End If
        End If

        If (t.Prejdenych Mod 50) = 0 Or t.Prejdenych = t.PocetZaznamov Then
            Call AktualizujProgress(pfx & "Importujem parametre prerušení...", t.Prejdenych, t.PocetZaznamov)
        End If
    Loop

    rs.Close
    Call DbfZatvor(t)
    Call mod_00_Common.ZapisLog("ImportParametrovPreruseniDBF", "INFO", "Parametre prerušení: pridaných " & pocet & ", ponechaných súčasných " & pocetPonechane & " (nič sa nemazalo ani neprepísalo).")
    mPoznamkyImportu = mPoznamkyImportu & "Parametre prerušení: pridaných " & pocet & ", súčasné ponechané (" & pocetPonechane & " zhodných kľúčov)." & vbCrLf
    Call ZavriProgress
    Exit Sub
ChybaHandler:
    Call ChybaImportu("ImportParametrovPreruseniDBF", Err.Number, Err.Description)
    On Error Resume Next
    If Not rs Is Nothing Then rs.Close
    Call DbfZatvor(t)
    Call ZavriProgress
End Sub

'-------------------------------------------------------------------------------
' Importuje ročné kalendáre, rozbaľuje ich reťazce typov dní na jednotlivé dni a načítava číselník sviatkov.
'-------------------------------------------------------------------------------
Public Sub ImportKalendaraDBF(ByVal Adresar As String)
    If Len(Adresar) = 0 Then Exit Sub
    On Error GoTo ChybaHandler
    If Not mod_18_Uzavierka.PrepisNastaveniPovoleny("kalendáre a sviatky") Then Exit Sub
    Dim db As DAO.Database, t As DbfTab, rsH As DAO.Recordset, rsD As DAO.Recordset, rs As DAO.Recordset
    Dim pouzite As Object, kluce As Object, sviatky As Object, k As Variant
    Dim cesta As String, Cislo As Long, rok As Long, mes As Long, kluc As String
    Dim typy As String, den As Long, pocetDni As Long, znak As String
    Dim pocK As Long, pocD As Long, pocS As Long, pfx As String

    Call PripravStrukturu
    Call NacitajObdobie
    Set db = CurrentDb
    Set pouzite = NacitajPouzite("KalendarKod")
    Set kluce = CreateObject("Scripting.Dictionary")
    pfx = IIf(mBatch, "[Krok 5/6] ", "")

    cesta = NajdiAleboLog(Adresar, "kalendárov (CIS_KALENDAR)", "cis_kalendar.dbf")
    If Len(cesta) > 0 Then
        If DbfOtvor(cesta, t) Then
            Call AktualizujProgress(pfx & "Importujem kalendáre (cis_kalendar.dbf)...", 0, t.PocetZaznamov)
            db.Execute "DELETE FROM KalendarDni", dbFailOnError
            db.Execute "DELETE FROM Kalendare", dbFailOnError
            Set rsH = db.OpenRecordset("Kalendare", dbOpenDynaset, dbAppendOnly)
            Set rsD = db.OpenRecordset("KalendarDni", dbOpenDynaset, dbAppendOnly)
            Do While DbfDalsi(t)
                Cislo = DbfLong(t, "CISLO")
                rok = DbfLong(t, "ROK")
                mes = DbfLong(t, "MESIAC")
                kluc = Cislo & "|" & rok & "|" & mes
                If Cislo > 0 And rok >= 1900 And mes >= 1 And mes <= 12 Then
                    If (pouzite.Count = 0 Or pouzite.Exists(CStr(Cislo))) And JeVObdobi(rok, mes) And Not kluce.Exists(kluc) Then
                        kluce(kluc) = True
                        typy = DbfText(t, "TYPY_DNI")
                        rsH.AddNew
                        rsH!Cislo = Cislo
                        rsH!rok = rok
                        rsH!Mesiac = mes
                        rsH!nazov = NV(Left$(DbfText(t, "NAZOV"), 50))
                        rsH!AutoGenerovanie = DbfBool(t, "AUTO")
                        rsH!TypKalendara = DbfBool(t, "TYP")
                        rsH!PorZac = DbfLong(t, "POR_ZAC")
                        rsH!PorNas = DbfLong(t, "POR_NAS")
                        rsH!Prac = DbfLong(t, "PRAC")
                        rsH!Volno = DbfLong(t, "VOLNO")
                        rsH!TypyDni = NV(Left$(typy, 35))
                        rsH.Update
                        pocK = pocK + 1

                        pocetDni = Day(DateSerial(rok, mes + 1, 0))
                        For den = 1 To pocetDni
                            If den <= Len(typy) Then znak = Mid$(typy, den, 1) Else znak = ""
                            rsD.AddNew
                            rsD!Kalendar = Cislo
                            rsD!Datum = DateSerial(rok, mes, den)
                            rsD!TypDna = NV(Trim$(znak))
                            rsD.Update
                            pocD = pocD + 1
                        Next den
                    End If
                End If

                If (t.Prejdenych Mod 10) = 0 Or t.Prejdenych = t.PocetZaznamov Then
                    Call AktualizujProgress(pfx & "Importujem kalendáre...", t.Prejdenych, t.PocetZaznamov)
                End If
            Loop
            rsH.Close: rsD.Close
            Call DbfZatvor(t)
        End If
    End If

    cesta = mod_00_Common.NajdiSuborVAdresari(Adresar, "cis_sviatkov.dbf")
    If Len(cesta) > 0 Then
        If DbfOtvor(cesta, t) Then
            Call AktualizujProgress(pfx & "Importujem číselník sviatkov...", 0, t.PocetZaznamov)
            Set sviatky = CreateObject("Scripting.Dictionary")
            Do While DbfDalsi(t)
                den = DbfLong(t, "DEN")
                mes = DbfLong(t, "MESIAC")
                If den > 0 And mes > 0 Then sviatky(mes * 100 + den) = DbfText(t, "NAZOV")
            Loop
            Call DbfZatvor(t)
            db.Execute "DELETE FROM Sviatky", dbFailOnError
            Set rs = db.OpenRecordset("Sviatky", dbOpenDynaset, dbAppendOnly)
            For Each k In sviatky.Keys
                rs.AddNew
                rs!den = CLng(k) Mod 100
                rs!Mesiac = CLng(k) \ 100
                rs!nazov = NV(Left$(CStr(sviatky(k)), 50))
                rs.Update
                pocS = pocS + 1
            Next k
            rs.Close
        End If
    End If

    Call mod_00_Common.ZapisLog("ImportKalendaraDBF", "INFO", "Kalendáre: " & pocK & ", rozbalených dní: " & pocD)
    Call ZavriProgress
    Exit Sub
ChybaHandler:
    Call ChybaImportu("ImportKalendaraDBF", Err.Number, Err.Description)
    On Error Resume Next
    If Not rsH Is Nothing Then rsH.Close
    If Not rsD Is Nothing Then rsD.Close
    If Not rs Is Nothing Then rs.Close
    Call DbfZatvor(t)
    Call ZavriProgress
End Sub

'-------------------------------------------------------------------------------
' Importuje dochádzkové razenia za zvolené obdobie (cez DAO ovládač s fallbackom na binárny DBFReader).
'-------------------------------------------------------------------------------
Public Sub ImportDochadzkyDBFPriamo(Optional ByVal CestaKSuboru As String = "")
    On Error GoTo ChybaHandler
    Dim filePath As String, pfx As String
    filePath = CestaKSuboru

    Call PripravStrukturu
    Call NacitajObdobie

    If mOdM < 1 Or mOdM > 12 Then mOdM = 1
    If mOdR < 1990 Then mOdR = Year(Date)
    If mDoM < 1 Or mDoM > 12 Then mDoM = Month(Date)
    If mDoR < 1990 Then mDoR = Year(Date)

    Dim dOd As Date, dDo As Date
    dOd = DateSerial(mOdR, mOdM, 1)
    dDo = DateSerial(mDoR, mDoM + 1, 0)

    If Len(filePath) = 0 Then
        filePath = NajdiAleboLog(GetAktualnyAdresarDBF(), "dochádzky (CIS_DOCHDATA)", "cis_dochdata.dbf", "CISDOCH_DATA.DBF")
    End If
    If Len(filePath) = 0 Then Exit Sub

    Dim poznane As Object
    Set poznane = NacitajOC()
    If poznane.Count = 0 Then
        Call mod_00_Common.ZapisLog("ImportDochadzkyDBFPriamo", "WARN", "V tabuľke Zamestnanci nie sú žiadne osobné čísla.")
        Exit Sub
    End If

    pfx = IIf(mBatch, "[Krok 6/6] ", "")
    Call AktualizujProgress(pfx & "Importujem dochádzkové razenia za obdobie " & Format$(dOd, "mm/yyyy") & " - " & Format$(dDo, "mm/yyyy") & "...", 0, 0)

    ' Ručne upravené dni (editor dochádzky, mod_05) sa pri opakovanom importe nemažú ani neprepisujú.
    Call mod_05_UI_AttendanceEditor.Ed_ResetCacheUpravenychDni
    CurrentDb.Execute "DELETE FROM DochadzkaImport WHERE Datum >= #" & Format$(dOd, "yyyy\-mm\-dd") & "# AND Datum <= #" & Format$(dDo, "yyyy\-mm\-dd") & "#" & _
                      " AND (ZdrojZapisu IS NULL OR ZdrojZapisu = 'DBF') AND (RucneUpravene IS NULL OR RucneUpravene = False)" & _
                      SqlFiltraOC() & mod_05_UI_AttendanceEditor.Ed_SqlVynechUpraveneDni(), dbFailOnError

    Dim folderPath As String, fileNameNoExt As String
    OdtahujCestuASubor filePath, folderPath, fileNameNoExt

    Dim dbDBF As DAO.Database, rsDBF As DAO.Recordset, rsDest As DAO.Recordset
    Dim pocetImp As Long, spracovaneCount As Long, totalCount As Long
    Dim sOEC As String, valOEC As Double, strOECNorm As String
    Dim uspesneDAO As Boolean

    On Error Resume Next
    Set dbDBF = DBEngine.OpenDatabase(folderPath, False, False, "dBase III;")
    If dbDBF Is Nothing Then Set dbDBF = DBEngine.OpenDatabase(folderPath, False, False, "dBase IV;")
    If dbDBF Is Nothing Then Set dbDBF = DBEngine.OpenDatabase(folderPath, False, False, "FoxPro 3.0;")

    If Not dbDBF Is Nothing Then
        Err.Clear
        Set rsDBF = dbDBF.OpenRecordset("SELECT * FROM [" & fileNameNoExt & "] WHERE DATUM >= #" & Format$(dOd, "yyyy\-mm\-dd") & "# AND DATUM <= #" & Format$(dDo, "yyyy\-mm\-dd") & "#", dbOpenSnapshot)
        If Err.Number = 0 And Not rsDBF Is Nothing Then
            uspesneDAO = True
            Set rsDest = CurrentDb.OpenRecordset("DochadzkaImport", dbOpenDynaset, dbAppendOnly)

            If Not rsDBF.EOF Then rsDBF.MoveLast: totalCount = rsDBF.RecordCount: rsDBF.MoveFirst

            Do While Not rsDBF.EOF
                spracovaneCount = spracovaneCount + 1
                sOEC = Trim$(CStr(Nz(rsDBF!OS_CISLO, "")))
                valOEC = Val(sOEC)
                If valOEC > 0 Then strOECNorm = CStr(CLng(valOEC)) Else strOECNorm = sOEC

                If Len(strOECNorm) > 0 And poznane.Exists(strOECNorm) And JeVoFiltri(strOECNorm) And Not mod_05_UI_AttendanceEditor.Ed_JeDenUpraveny(strOECNorm, rsDBF!Datum) Then
                    rsDest.AddNew
                    rsDest!Datum = rsDBF!Datum
                    rsDest!Cas = Nz(rsDBF!Cas, 0)
                    On Error Resume Next
                    rsDest!DatumSnim = rsDBF!DAT_SNIM
                    rsDest!CisPam = Nz(rsDBF!CIS_PAM, 0)
                    rsDest!DatumPoc = rsDBF!DAT_POC
                    rsDest!CasPoc = Nz(rsDBF!CAS_POC, 0)
                    rsDest!KodPrerusenia = Nz(rsDBF!KOD_PRER, 0)
                    rsDest!Platnost = Nz(rsDBF!Platnost, False)
                    rsDest!Zdroj = Val(Nz(rsDBF!Zdroj, 0))
                    rsDest!Uzivatel = NV(Left$(Nz(rsDBF!Uzivatel, ""), 50))
                    rsDest!OdpracDoba = Nz(rsDBF!ODPR_DOBA, 0)
                    rsDest!Poradie = Nz(rsDBF!Poradie, 0)
                    rsDest!StavUza = Nz(rsDBF!STAV_UZA, False)
                    rsDest!Poznamka = NV(Nz(rsDBF!Poznamka, ""))
                    On Error GoTo ChybaHandler
                    rsDest!OsobneCislo = strOECNorm
                    rsDest!ZdrojZapisu = "DBF"
                    rsDest.Update
                    pocetImp = pocetImp + 1
                End If

                If (spracovaneCount Mod 200) = 0 Or spracovaneCount = totalCount Then
                    Call AktualizujProgress(pfx & "Importujem dochádzku...", spracovaneCount, totalCount)
                End If
                rsDBF.MoveNext
            Loop
            rsDBF.Close
            rsDest.Close
            dbDBF.Close
        End If
    End If
    On Error GoTo ChybaHandler

    ' Záložné binárne čítanie DBF
    If Not uspesneDAO Then
        Dim t As DbfTab
        If DbfOtvor(filePath, t) Then
            Dim iDatum As Long, iCas As Long, iDatSnim As Long, iCisPam As Long, iDatPoc As Long, iCasPoc As Long
            Dim iOC As Long, iKod As Long, iPlat As Long, iZdroj As Long, iUziv As Long, iOdpr As Long
            Dim iPor As Long, iStav As Long, iPozn As Long
            Dim ymdOd As Long, ymdDo As Long, ymd As Long

            ymdOd = Year(dOd) * 10000 + Month(dOd) * 100 + Day(dOd)
            ymdDo = Year(dDo) * 10000 + Month(dDo) * 100 + Day(dDo)

            iDatum = DbfIdx(t, "DATUM"):        iCas = DbfIdx(t, "CAS")
            iDatSnim = DbfIdx(t, "DAT_SNIM"):   iCisPam = DbfIdx(t, "CIS_PAM")
            iDatPoc = DbfIdx(t, "DAT_POC"):     iCasPoc = DbfIdx(t, "CAS_POC")
            iOC = DbfIdx(t, "OS_CISLO|OS_CIS"): iKod = DbfIdx(t, "KOD_PRER")
            iPlat = DbfIdx(t, "PLATNOST"):      iZdroj = DbfIdx(t, "ZDROJ")
            iUziv = DbfIdx(t, "UZIVATEL"):      iOdpr = DbfIdx(t, "ODPR_DOBA")
            iPor = DbfIdx(t, "PORADIE"):        iStav = DbfIdx(t, "STAV_UZA")
            iPozn = DbfIdx(t, "POZNAMKA")

            Set rsDest = CurrentDb.OpenRecordset("DochadzkaImport", dbOpenDynaset, dbAppendOnly)

            Do While DbfDalsi(t)
                ymd = DbfYmdI(t, iDatum)
                If ymd >= ymdOd And ymd <= ymdDo Then
                    sOEC = Trim$(DbfTextI(t, iOC))
                    valOEC = Val(sOEC)
                    If valOEC > 0 Then strOECNorm = CStr(CLng(valOEC)) Else strOECNorm = sOEC

                    If Len(strOECNorm) > 0 And poznane.Exists(strOECNorm) And JeVoFiltri(strOECNorm) And Not mod_05_UI_AttendanceEditor.Ed_JeDenUpraveny(strOECNorm, DbfDatumI(t, iDatum)) Then
                        rsDest.AddNew
                        rsDest!Datum = DbfDatumI(t, iDatum)
                        rsDest!Cas = DbfLongI(t, iCas)
                        If iDatSnim >= 0 Then rsDest!DatumSnim = DbfDatumI(t, iDatSnim)
                        If iCisPam >= 0 Then rsDest!CisPam = DbfLongI(t, iCisPam)
                        If iDatPoc >= 0 Then rsDest!DatumPoc = DbfDatumI(t, iDatPoc)
                        If iCasPoc >= 0 Then rsDest!CasPoc = DbfLongI(t, iCasPoc)
                        rsDest!OsobneCislo = strOECNorm
                        rsDest!ZdrojZapisu = "DBF"
                        If iKod >= 0 Then rsDest!KodPrerusenia = DbfLongI(t, iKod)
                        If iPlat >= 0 Then rsDest!Platnost = DbfBoolI(t, iPlat)
                        If iZdroj >= 0 Then rsDest!Zdroj = DbfLongI(t, iZdroj)
                        If iUziv >= 0 Then rsDest!Uzivatel = NV(Left$(DbfTextI(t, iUziv), 50))
                        If iOdpr >= 0 Then rsDest!OdpracDoba = DbfLongI(t, iOdpr)
                        If iPor >= 0 Then rsDest!Poradie = DbfLongI(t, iPor)
                        If iStav >= 0 Then rsDest!StavUza = DbfBoolI(t, iStav)
                        If iPozn >= 0 Then rsDest!Poznamka = NV(DbfTextI(t, iPozn))
                        rsDest.Update
                        pocetImp = pocetImp + 1
                    End If
                End If
                If (t.Prejdenych Mod 200) = 0 Or t.Prejdenych = t.PocetZaznamov Then
                    Call AktualizujProgress(pfx & "Importujem dochádzku...", spracovaneCount, totalCount)
                End If
            Loop
            rsDest.Close
            Call DbfZatvor(t)
        End If
    End If

    Call DoplnPrerusenieDoDochadzky
    Call mod_00_Common.ZapisLog("ImportDochadzkyDBFPriamo", "INFO", "Dochádzka " & Format$(dOd, "dd.mm.yyyy") & "-" & Format$(dDo, "dd.mm.yyyy") & ": naimportovaných " & pocetImp & " razení.")
    Call PosunKrok(4)
    Call ZavriProgress
    Exit Sub

ChybaHandler:
    Call ChybaImportu("ImportDochadzkyDBFPriamo", Err.Number, Err.Description)
    On Error Resume Next
    If Not rsDest Is Nothing Then rsDest.Close
    If Not rsDBF Is Nothing Then rsDBF.Close
    If Not dbDBF Is Nothing Then dbDBF.Close
    Call ZavriProgress
End Sub

'-------------------------------------------------------------------------------
' Vykonáva kompletný dávkový import všetkých číselníkov, fondov, kalendárov a razení v správnom poradí.
'-------------------------------------------------------------------------------
Public Sub ImportVsetkychDBFTabuliek()
    On Error GoTo ChybaHandler
    Dim adr As String, f As String, strBlok As String

    Call PripravStrukturu
    adr = mod_02_DBFImport.GetAktualnyAdresarDBF()
    If Len(adr) = 0 Or Dir(adr, vbDirectory) = "" Then
        adr = mod_00_Common.VyberAdresarDBF()
    End If
    If Len(adr) = 0 Then Exit Sub

    mBatch = False
    Call mod_02_DBFImport.ZistiObdobieImportu(mOdM, mOdR, mDoM, mDoR)
    mBatch = True
    mPoznamkyImportu = ""
    Call mod_18_Uzavierka.ZacniDavkuImportu

    Call AktualizujProgress("Štartujem dávkový import zo všetkých DBF súborov...", 0, 0)
    Call mod_00_Common.ZapisLog("ImportVsetkychDBFTabuliek", "INFO", "Štart šaržového importu. Adresár: " & adr)

    ' 1. Zamestnanci a priradenia
    f = NajdiAleboLog(adr, "zamestnancov", "cis_zamestnanec.dbf")
    If Len(f) > 0 Then Call mod_02_DBFImport.ImportZamestnancovDBFPriamo(f)
    f = NajdiAleboLog(adr, "priradenia fondov zamestnancom", "cis_zamdoch.dbf")
    If Len(f) > 0 Then Call mod_02_DBFImport.ImportZamestnanciFondyDBF(f)

    ' 2. Číselník prerušení
    f = NajdiAleboLog(adr, "číselníka prerušení", "cis_preruseni.dbf", "CIS_PRERUS.DBF", "CIS_PRER.DBF", "PRERUSENI.DBF")
    If Len(f) > 0 Then Call mod_02_DBFImport.ImportPreruseniDBFPriamo(f)

    ' 3. Fondy, parametre prerušení a kalendár
    Call mod_02_DBFImport.ImportPracovnychFondovDBF(adr)
    f = NajdiAleboLog(adr, "parametrov prerušení", "cis_parprer.dbf", "CIS_PARPRERUS.DBF")
    If Len(f) > 0 Then Call mod_02_DBFImport.ImportParametrovPreruseniDBF(f)
    Call mod_02_DBFImport.ImportKalendaraDBF(adr)

    ' 4. Dochádzkové razenia
    Call mod_02_DBFImport.ImportDochadzkyDBFPriamo(NajdiAleboLog(adr, "dochádzky", "cis_dochdata.dbf", "CISDOCH_DATA.DBF"))

    mBatch = False
    Call ZavriProgress
    strBlok = mod_18_Uzavierka.SkonciDavkuImportu()
    If Len(strBlok) = 0 Then Call mod_18_Uzavierka.VymazOznacenieNastaveni
    Call mod_00_Common.ZapisLog("ImportVsetkychDBFTabuliek", "INFO", "Šaržový import dokončený.")
    If Len(strBlok) = 0 Then
        MsgBox "Kompletný dávkový import bol úspešne dokončený." & IIf(Len(mPoznamkyImportu) > 0, vbCrLf & vbCrLf & mPoznamkyImportu, ""), vbInformation, "Import dokončený"
    Else
        MsgBox "Dávkový import bol dokončený, ale tieto nastavenia sa NEPREPÍSALI (existujú uzavreté mesiace alebo ste prepis nepotvrdili):" & vbCrLf & strBlok & vbCrLf & _
               "Razenia a zamestnanci sa naimportovali; uzavreté mesiace a ich razenia ostali nezmenené." & IIf(Len(mPoznamkyImportu) > 0, vbCrLf & vbCrLf & mPoznamkyImportu, ""), vbExclamation, "Import dokončený"
    End If
    Exit Sub
ChybaHandler:
    Call ChybaImportu("ImportVsetkychDBFTabuliek", Err.Number, Err.Description)
    Call mod_18_Uzavierka.SkonciDavkuImportu
    mBatch = False
    Call ZavriProgress
End Sub

'-------------------------------------------------------------------------------
' Identifikuje neznáme kódy prerušení z razení a automaticky ich doplní do KodyRazeni.
'-------------------------------------------------------------------------------
Public Function SkontrolujChybajucePrerusenia() As Long
    On Error GoTo ChybaHandler
    Dim db As DAO.Database, rs As DAO.Recordset, kod As Long, pocet As Long, zoznam As String

    Call PripravStrukturu
    Set db = CurrentDb
    Set rs = db.OpenRecordset("SELECT DISTINCT D.KodPrerusenia FROM DochadzkaImport AS D " & _
                              "LEFT JOIN KodyRazeni AS K ON D.KodPrerusenia = K.KodRazenia " & _
                              "WHERE D.KodPrerusenia IS NOT NULL AND D.KodPrerusenia <> 0 AND K.KodRazenia IS NULL", dbOpenSnapshot)
    Do While Not rs.EOF
        kod = CLng(Nz(rs!KodPrerusenia, 0))
        If kod > 0 Then
            pocet = pocet + 1
            db.Execute "INSERT INTO KodyRazeni (KodRazenia, TextRazenia) VALUES (" & kod & ", 'NEZNÁME (" & kod & ")')", dbFailOnError
            zoznam = zoznam & kod & "=Neznáme prerušenie " & kod & vbCrLf
        End If
        rs.MoveNext
    Loop
    rs.Close

    If pocet > 0 And mod_00_Common.FormIsOpen("frmSprievodcaImportom") Then
        Forms!frmSprievodcaImportom!txtRucnePrerusenia = zoznam
    End If

    SkontrolujChybajucePrerusenia = pocet
    Exit Function
ChybaHandler:
    Call ChybaImportu("SkontrolujChybajucePrerusenia", Err.Number, Err.Description)
    On Error Resume Next
    If Not rs Is Nothing Then rs.Close
    SkontrolujChybajucePrerusenia = 0
End Function

