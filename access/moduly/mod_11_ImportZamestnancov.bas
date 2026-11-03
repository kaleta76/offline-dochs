Attribute VB_Name = "mod_11_ImportZamestnancov"
'@Verzia 1.0.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_11_ImportZamestnancov
' POPIS: Import zamestnancov z CSV / TXT pre inštalácie bez Ordata.
'        Podporuje:
'          - jednoduchý zoznam osobných čísel (jedno číslo na riadok, aj viac čísel oddelených medzerou),
'          - plnohodnotné CSV s hlavičkou (osobné číslo, meno, priezvisko, oddelenie, e-mail, login,
'            osobné číslo vedúceho / login vedúceho, telefón, mobil) - názvy stĺpcov sa rozpoznajú
'            automaticky (slovenské aj anglické, aj bez diakritiky),
'          - oddeľovač ; , TAB alebo | (rozpozná sa automaticky), úvodzovky, kódovanie UTF-8 / UTF-16 / Windows-1250.
'        Existujúci zamestnanci sa doplnia (neprázdne hodnoty z CSV), nikdy sa nemení rola ani príznak aktivity.
'        Po importe sa prepočíta hierarchia (vedúci) a roly.
' NASTAVENIA: OsobneCisloDlzka - ak > 0, osobné číslo musí mať presne toľko číslic (0 = ľubovoľné 1-20 znakov).
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - ImportZamestnancovZCSV(cesta, bTicho)        : Hlavný import; vráti textový report.
' - ImportZamestnancovZTextu(text, bTicho)       : Import z textu (zoznam čísel / CSV obsah).
' - NormalizujOC(s) / JePlatneOC(s)              : Spoločná kontrola osobného čísla.
' - ZabezpecTabulkuZamestnancov(db)              : Vytvorí tabuľku a doplní stĺpce (ManagerOC, ZdrojZaznamu).
' - CitajTextSubor(cesta)                        : Načíta súbor s automatickým kódovaním.
'===============================================================================

' logické polia
Private Const F_OC As Long = 0
Private Const F_MENO As Long = 1
Private Const F_PRIEZ As Long = 2
Private Const F_ODD As Long = 3
Private Const F_EMAIL As Long = 4
Private Const F_LOGIN As Long = 5
Private Const F_MOC As Long = 6
Private Const F_MLOGIN As Long = 7
Private Const F_TEL As Long = 8
Private Const F_MOBIL As Long = 9
Private Const F_CELE As Long = 10
Private Const F_POCET As Long = 11

Private mCeleObratene As Boolean   ' stĺpec celého mena je v poradí Priezvisko Meno

'-------------------------------------------------------------------------------
' Vytvorí tabuľku Zamestnanci (ak chýba) a doplní stĺpce potrebné pre import a hierarchiu.
'-------------------------------------------------------------------------------
Public Sub ZabezpecTabulkuZamestnancov(ByRef db As DAO.Database)
    On Error Resume Next
    If Not mod_00_Common.TabulkaExistujeDB(db, "Zamestnanci") Then
        Call mod_01_SystemInit.ZabezpecStrukturuImportu
        db.TableDefs.Refresh
    End If
    If Not mod_00_Common.PoleExistujeDB(db, "Zamestnanci", "ManagerOC") Then db.Execute "ALTER TABLE Zamestnanci ADD COLUMN ManagerOC TEXT(20)", dbFailOnError
    If Not mod_00_Common.PoleExistujeDB(db, "Zamestnanci", "ZdrojZaznamu") Then db.Execute "ALTER TABLE Zamestnanci ADD COLUMN ZdrojZaznamu TEXT(10)", dbFailOnError
    If Not mod_00_Common.PoleExistujeDB(db, "Zamestnanci", "CeleMeno") Then db.Execute "ALTER TABLE Zamestnanci ADD COLUMN CeleMeno TEXT(255)", dbFailOnError
End Sub

'-------------------------------------------------------------------------------
' Očistí osobné číslo (medzery, apostrof z Excelu, ".0", vedecký zápis).
'-------------------------------------------------------------------------------
Public Function NormalizujOC(ByVal s As String) As String
    Dim t As String
    t = Replace(Replace(Replace(s, ChrW(160), ""), vbTab, ""), " ", "")
    t = Trim$(t)
    If Left$(t, 1) = "'" Then t = Mid$(t, 2)
    If Left$(t, 1) = """" And Right$(t, 1) = """" And Len(t) >= 2 Then t = Mid$(t, 2, Len(t) - 2)
    If InStr(UCase$(t), "E+") > 0 And IsNumeric(t) Then t = Format$(CDbl(t), "0")
    If Right$(t, 2) = ".0" Or Right$(t, 2) = ",0" Then t = Left$(t, Len(t) - 2)
    NormalizujOC = t
End Function

'-------------------------------------------------------------------------------
' Platné osobné číslo: 1-20 alfanumerických znakov; pri nastavení OsobneCisloDlzka > 0 presne toľko číslic.
'-------------------------------------------------------------------------------
Public Function JePlatneOC(ByVal s As String) As Boolean
    Dim i As Long, c As String, lDlzka As Long
    If Len(s) < 1 Or Len(s) > 20 Then Exit Function
    For i = 1 To Len(s)
        c = Mid$(s, i, 1)
        If Not (c Like "[0-9A-Za-z]") Then Exit Function
    Next i
    lDlzka = CLng(Val(mod_00_Common.GetNastavenie("OsobneCisloDlzka", "0")))
    If lDlzka > 0 Then
        If Len(s) <> lDlzka Then Exit Function
        If Not (s Like String$(lDlzka, "#")) Then Exit Function
    End If
    JePlatneOC = True
End Function

'-------------------------------------------------------------------------------
' Normalizovaný názov stĺpca: malé písmená, bez diakritiky a bez nealfanumerických znakov.
'-------------------------------------------------------------------------------
Private Function KlucHlavicky(ByVal s As String) As String
    Dim zdroj As String, ciel As String, i As Long, p As Long, c As String, r As String
    zdroj = "áäčďéěíĺľňóôöŕřšťúůüýž"
    ciel = "aacdeeillnooorrstuuuyz"
    s = LCase$(s)
    For i = 1 To Len(s)
        c = Mid$(s, i, 1)
        p = InStr(zdroj, c)
        If p > 0 Then c = Mid$(ciel, p, 1)
        If c Like "[a-z0-9]" Then r = r & c
    Next i
    KlucHlavicky = r
End Function

'-------------------------------------------------------------------------------
' Priradí názov stĺpca k logickému poľu; -1 ak nie je rozpoznaný.
'-------------------------------------------------------------------------------
Private Function PoleZHlavicky(ByVal strNazov As String) As Long
    Dim k As String
    k = KlucHlavicky(strNazov)
    PoleZHlavicky = -1
    If Len(k) = 0 Then Exit Function
    Select Case k
        Case "osobnecislo", "oc", "osc", "osobnecisloz", "cislo", "cisloz", "cisloosoby", "personalnumber", "personnumber", "employeeid", _
             "employeenumber", "empid", "pernr", "persno", "id", "osobnecislozamestnanca", "oscislo", "ocislo", "cislozamestnanca", "czamestnanca", "idzamestnanca", "ozamestnanca"
            PoleZHlavicky = F_OC
        Case "meno", "krstnemeno", "firstname", "givenname"
            PoleZHlavicky = F_MENO
        Case "priezvisko", "lastname", "surname", "sn", "familyname"
            PoleZHlavicky = F_PRIEZ
        Case "celemeno", "menoapriezvisko", "priezviskoameno", "priezviskomeno", "fullname", "displayname", "zamestnanec", "name", "menozamestnanca"
            PoleZHlavicky = F_CELE
        Case "oddelenie", "department", "utvar", "stredisko", "organizacnajednotka", "ou", "oddelenienazov"
            PoleZHlavicky = F_ODD
        Case "email", "mail", "emailovaadresa", "emailova", "emailadresa"
            PoleZHlavicky = F_EMAIL
        Case "login", "loginad", "samaccountname", "username", "pouzivatel", "prihlasovacimeno", "uzivatel", "userid"
            PoleZHlavicky = F_LOGIN
        Case "veduciosobnecislo", "veduciocislo", "veduci", "veduciosc", "veduceoc", "veduciocnadriadeny", "manageroc", "managernumber", "managerid", _
             "nadriadenyoc", "nadriadeny", "nadriadenyosobnecislo", "managerpersonalnumber", "ocveduceho", "osobnecislovedouceho", "osobnecisloveduceho", "ocnadriadeneho"
            PoleZHlavicky = F_MOC
        Case "managerlogin", "loginveduceho", "loginnadriadeneho", "manager", "veducilogin", "nadriadenylogin"
            PoleZHlavicky = F_MLOGIN
        Case "telefon", "telephone", "phone", "telefonne", "tel"
            PoleZHlavicky = F_TEL
        Case "mobil", "mobile", "mobilnetelefon", "gsm"
            PoleZHlavicky = F_MOBIL
    End Select
End Function

'-------------------------------------------------------------------------------
' Načíta textový súbor; kódovanie sa rozpozná (BOM UTF-8 / UTF-16, inak UTF-8, pri chybe Windows-1250).
'-------------------------------------------------------------------------------
Public Function CitajTextSubor(ByVal strCesta As String) As String
    On Error GoTo Chyba
    Dim st As Object, b As Variant, strCS As String, s As String
    Set st = CreateObject("ADODB.Stream")
    st.Type = 1
    st.Open
    st.LoadFromFile strCesta
    If st.Size = 0 Then st.Close: Exit Function
    b = st.Read(2)
    strCS = "utf-8"
    If UBound(b) >= 1 Then
        If b(0) = 255 And b(1) = 254 Then strCS = "unicode"
        If b(0) = 254 And b(1) = 255 Then strCS = "unicodeFFFE"
    End If
    st.Position = 0
    st.Type = 2
    st.Charset = strCS
    s = st.ReadText
    st.Close
    If strCS = "utf-8" And InStr(s, ChrW(&HFFFD)) > 0 Then
        Set st = CreateObject("ADODB.Stream")
        st.Type = 1
        st.Open
        st.LoadFromFile strCesta
        st.Position = 0
        st.Type = 2
        st.Charset = "windows-1250"
        s = st.ReadText
        st.Close
    End If
    If Len(s) > 0 Then If AscW(Left$(s, 1)) = &HFEFF Then s = Mid$(s, 2)
    CitajTextSubor = s
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_11_ImportZamestnancov.CitajTextSubor", "ERROR", Err.Description, strCesta)
    CitajTextSubor = ""
End Function

'-------------------------------------------------------------------------------
' Rozpozná oddeľovač podľa prvých riadkov (mimo úvodzoviek).
'-------------------------------------------------------------------------------
Private Function ZistiOddelovac(ByVal t As String) As String
    Dim kand As Variant, best As String, bestN As Long, n As Long, i As Long, c As String, bQ As Boolean, riadky As Long, k As Variant
    best = ";"
    For Each kand In Array(";", vbTab, ",", "|")
        n = 0: riadky = 0: bQ = False
        For i = 1 To Len(t)
            c = Mid$(t, i, 1)
            If c = """" Then
                bQ = Not bQ
            ElseIf Not bQ Then
                If c = CStr(kand) Then n = n + 1
                If c = vbLf Then
                    riadky = riadky + 1
                    If riadky >= 5 Then Exit For
                End If
            End If
        Next i
        If n > bestN Then bestN = n: best = CStr(kand)
    Next kand
    ZistiOddelovac = best
End Function

'-------------------------------------------------------------------------------
' Rozdelí text na riadky a polia (úvodzovky, zdvojené úvodzovky, zalomenie v poli). Vráti počet riadkov.
'-------------------------------------------------------------------------------
Private Function ParsujCSV(ByVal t As String, ByVal d As String, ByRef rows() As Variant) As Long
    Dim i As Long, n As Long, c As String, bQ As Boolean, pole() As String, nP As Long, cur As String
    Dim bPrazdny As Boolean

    ReDim rows(1 To 256)
    ReDim pole(1 To 64)
    nP = 0: cur = "": bQ = False
    t = Replace(Replace(t, vbCrLf, vbLf), vbCr, vbLf)
    For i = 1 To Len(t) + 1
        If i <= Len(t) Then c = Mid$(t, i, 1) Else c = vbLf
        If bQ Then
            If c = """" Then
                If i < Len(t) Then
                    If Mid$(t, i + 1, 1) = """" Then cur = cur & """": i = i + 1 Else bQ = False
                Else
                    bQ = False
                End If
            Else
                cur = cur & c
            End If
        ElseIf c = """" Then
            bQ = True
        ElseIf c = d Or c = vbLf Then
            nP = nP + 1
            If nP > UBound(pole) Then ReDim Preserve pole(1 To UBound(pole) * 2)
            pole(nP) = cur
            cur = ""
            If c = vbLf Then
                bPrazdny = (nP = 1 And Len(Trim$(pole(1))) = 0)
                If Not bPrazdny Then
                    n = n + 1
                    If n > UBound(rows) Then ReDim Preserve rows(1 To UBound(rows) * 2)
                    Dim ar() As String, j As Long
                    ReDim ar(1 To nP)
                    For j = 1 To nP
                        ar(j) = pole(j)
                    Next j
                    rows(n) = ar
                End If
                nP = 0
            End If
        Else
            cur = cur & c
        End If
    Next i
    ParsujCSV = n
End Function

'-------------------------------------------------------------------------------
' Import zo súboru. Pri prázdnej ceste otvorí dialóg výberu súboru.
'-------------------------------------------------------------------------------
Public Function ImportZamestnancovZCSV(Optional ByVal strCesta As String = "", Optional ByVal bTicho As Boolean = False) As String
    On Error GoTo Chyba
    Dim t As String
    If Len(strCesta) = 0 Then strCesta = mod_00_Common.VyberDBFSuborBezpecne("Vyberte súbor so zamestnancami (CSV / TXT)", "zamestnanci.csv")
    If Len(strCesta) = 0 Then Exit Function
    If Len(Dir(strCesta)) = 0 Then
        ImportZamestnancovZCSV = "Súbor sa nenašiel: " & strCesta
        If Not bTicho Then MsgBox ImportZamestnancovZCSV, vbExclamation, "Import zamestnancov"
        Exit Function
    End If
    t = CitajTextSubor(strCesta)
    If Len(Trim$(t)) = 0 Then
        ImportZamestnancovZCSV = "Súbor je prázdny alebo ho nie je možné prečítať."
        If Not bTicho Then MsgBox ImportZamestnancovZCSV, vbExclamation, "Import zamestnancov"
        Exit Function
    End If
    ImportZamestnancovZCSV = ImportZamestnancovZTextu(t, bTicho, strCesta)
    Exit Function
Chyba:
    ImportZamestnancovZCSV = "Chyba importu CSV: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_11_ImportZamestnancov.ImportZamestnancovZCSV", "ERROR", Err.Description)
    If Not bTicho Then MsgBox ImportZamestnancovZCSV, vbCritical, "Import zamestnancov"
End Function

'-------------------------------------------------------------------------------
' Import z textu. Vráti textový report.
'-------------------------------------------------------------------------------
Public Function ImportZamestnancovZTextu(ByVal t As String, Optional ByVal bTicho As Boolean = False, Optional ByVal strZdroj As String = "") As String
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset, rows() As Variant, nR As Long, d As String
    Dim map(0 To F_POCET - 1) As Long, i As Long, j As Long, r As Variant, f As Long, nCol As Long
    Dim bHlavicka As Boolean, iStart As Long, vals(0 To F_POCET - 1) As String
    Dim nNovych As Long, nAkt As Long, nChyb As Long, nDup As Long, strChyby As String, strOC As String
    Dim dicVidene As Object, bExistuje As Boolean, strRep As String, bJenCisla As Boolean

    Set db = CurrentDb
    Call ZabezpecTabulkuZamestnancov(db)
    Set dicVidene = CreateObject("Scripting.Dictionary")

    d = ZistiOddelovac(t)
    nR = ParsujCSV(t, d, rows)
    If nR = 0 Then ImportZamestnancovZTextu = "Nenašli sa žiadne riadky.": Exit Function

    For f = 0 To F_POCET - 1
        map(f) = -1
    Next f

    ' hlavička: riadok, v ktorom je rozpoznaný stĺpec osobného čísla
    r = rows(1)
    For j = 1 To UBound(r)
        f = PoleZHlavicky(CStr(r(j)))
        If f >= 0 Then
            If map(f) < 0 Then map(f) = j
        End If
    Next j
    bHlavicka = (map(F_OC) > 0)
    mCeleObratene = False
    If bHlavicka And map(F_CELE) > 0 Then mCeleObratene = (Left$(KlucHlavicky(CStr(r(map(F_CELE)))), 10) = "priezvisko")

    If Not bHlavicka Then
        ' bez hlavičky: ak má prvý riadok viac ako jedno rozpoznateľné pole mien, je to hlavička bez osobného čísla -> chyba
        Dim nRozpoznanych As Long
        For j = 1 To UBound(r)
            If PoleZHlavicky(CStr(r(j))) >= 0 Then nRozpoznanych = nRozpoznanych + 1
        Next j
        If nRozpoznanych > 0 Then
            strRep = "V hlavičke sa nenašiel stĺpec osobného čísla. Pomenujte ho napr. OsobneCislo, OC alebo EmployeeID."
            If Not bTicho Then MsgBox strRep, vbExclamation, "Import zamestnancov"
            ImportZamestnancovZTextu = strRep
            Exit Function
        End If
        ' zoznam čísel: prvý stĺpec je osobné číslo; ostatné stĺpce sa ignorujú
        map(F_OC) = 1
        iStart = 1
        bJenCisla = True
    Else
        iStart = 2
    End If

    Set rs = db.OpenRecordset("SELECT * FROM Zamestnanci;", dbOpenDynaset)

    For i = iStart To nR
        r = rows(i)
        nCol = UBound(r)
        For f = 0 To F_POCET - 1
            vals(f) = ""
            If map(f) > 0 And map(f) <= nCol Then vals(f) = Trim$(CStr(r(map(f))))
        Next f

        If bJenCisla Then
            ' viac čísel v jednom riadku oddelených medzerou / čiarkou nie je vo všeobecnosti možné s oddeľovačom; skús aj rozdelenie podľa medzier
            Dim tok() As String, k As Long
            tok = Split(Replace(Replace(vals(F_OC), ",", " "), vbTab, " "), " ")
            For k = LBound(tok) To UBound(tok)
                If Len(Trim$(tok(k))) > 0 Then
                    strOC = NormalizujOC(tok(k))
                    Call UlozZamestnanca(rs, strOC, vals, dicVidene, nNovych, nAkt, nChyb, nDup, strChyby, i)
                End If
            Next k
        Else
            strOC = NormalizujOC(vals(F_OC))
            Call UlozZamestnanca(rs, strOC, vals, dicVidene, nNovych, nAkt, nChyb, nDup, strChyby, i)
        End If
    Next i
    rs.Close

    Call mod_03_ADSync.PrepocitajHierarchiu
    If nNovych + nAkt > 0 Then Call mod_00_Common.SetPoslednyKrok(2)

    strRep = IIf(bHlavicka, "Rozpoznané stĺpce: ", "Zoznam osobných čísel. ") & IIf(bHlavicka, PopisMapovania(map), "") & vbCrLf & _
             "Pridaní zamestnanci: " & nNovych & vbCrLf & "Doplnení existujúci: " & nAkt & vbCrLf & _
             "Duplicity v súbore: " & nDup & vbCrLf & "Zamietnuté riadky: " & nChyb
    If Len(strChyby) > 0 Then strRep = strRep & vbCrLf & "Zamietnuté (prvé): " & strChyby
    Call mod_00_Common.ZapisLog("ImportZamestnancovZTextu", "INFO", Replace(strRep, vbCrLf, "; "), strZdroj)
    If Not bTicho Then MsgBox strRep, vbInformation, "Import zamestnancov"
    ImportZamestnancovZTextu = strRep
    Exit Function
Chyba:
    ImportZamestnancovZTextu = "Chyba importu: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_11_ImportZamestnancov.ImportZamestnancovZTextu", "ERROR", Err.Description)
    On Error Resume Next
    rs.Close
    If Not bTicho Then MsgBox ImportZamestnancovZTextu, vbCritical, "Import zamestnancov"
End Function

Private Function PopisMapovania(ByRef map() As Long) As String
    Dim nazvy As Variant, f As Long, s As String
    nazvy = Array("osobné číslo", "meno", "priezvisko", "oddelenie", "e-mail", "login", "vedúci (OČ)", "vedúci (login)", "telefón", "mobil", "celé meno")
    For f = 0 To F_POCET - 1
        If map(f) > 0 Then s = s & nazvy(f) & ", "
    Next f
    If Len(s) > 0 Then s = Left$(s, Len(s) - 2)
    PopisMapovania = s
End Function

'-------------------------------------------------------------------------------
' Vloží alebo doplní jedného zamestnanca; aktualizuje počítadlá.
'-------------------------------------------------------------------------------
Private Sub UlozZamestnanca(ByRef rs As DAO.Recordset, ByVal strOC As String, ByRef vals() As String, ByRef dicVidene As Object, _
                            ByRef nNovych As Long, ByRef nAkt As Long, ByRef nChyb As Long, ByRef nDup As Long, ByRef strChyby As String, ByVal lRiadok As Long)
    Dim sCele As String, sMOC As String
    If Not JePlatneOC(strOC) Then
        nChyb = nChyb + 1
        If nChyb <= 5 Then strChyby = strChyby & "r." & lRiadok & " '" & Left$(strOC, 20) & "'; "
        Exit Sub
    End If
    If dicVidene.Exists(strOC) Then nDup = nDup + 1: Exit Sub
    dicVidene(strOC) = True

    rs.FindFirst "OsobneCislo = " & mod_00_Common.SqlText(strOC)
    If rs.NoMatch Then
        rs.AddNew
        rs!OsobneCislo = strOC
        rs!Rola = "USER"
        rs!ADAktivny = True
        rs!ZdrojZaznamu = "CSV"
    Else
        rs.Edit
    End If
    If Len(vals(F_MENO)) > 0 Then rs!Meno = Left$(vals(F_MENO), 50)
    If Len(vals(F_PRIEZ)) > 0 Then rs!Priezvisko = Left$(vals(F_PRIEZ), 50)
    If Len(vals(F_CELE)) > 0 And Len(vals(F_MENO)) = 0 And Len(vals(F_PRIEZ)) = 0 Then
        ' celé meno: "Meno Priezvisko" (posledné slovo = priezvisko) alebo pri hlavičke "Priezvisko a meno" opačne (prvé slovo)
        Dim p As Long, sC As String
        sC = Trim$(vals(F_CELE))
        If mCeleObratene Then p = InStr(sC, " ") Else p = InStrRev(sC, " ")
        If p > 0 Then
            If mCeleObratene Then
                rs!Priezvisko = Left$(Trim$(Left$(sC, p - 1)), 50)
                rs!Meno = Left$(Trim$(Mid$(sC, p + 1)), 50)
            Else
                rs!Meno = Left$(Trim$(Left$(sC, p - 1)), 50)
                rs!Priezvisko = Left$(Trim$(Mid$(sC, p + 1)), 50)
            End If
        Else
            rs!Priezvisko = Left$(Trim$(vals(F_CELE)), 50)
        End If
    End If
    sCele = Trim$(Nz(rs!Meno, "") & " " & Nz(rs!Priezvisko, ""))
    If Len(sCele) > 0 Then rs!CeleMeno = Left$(sCele, 255)
    If Len(vals(F_ODD)) > 0 Then rs!Oddelenie = Left$(vals(F_ODD), 150)
    If Len(vals(F_EMAIL)) > 0 Then rs!Email = Left$(vals(F_EMAIL), 255)
    If Len(vals(F_LOGIN)) > 0 Then rs!LoginAD = Left$(vals(F_LOGIN), 100)
    If Len(vals(F_TEL)) > 0 Then rs!Telefon = Left$(vals(F_TEL), 50)
    If Len(vals(F_MOBIL)) > 0 Then rs!Mobil = Left$(vals(F_MOBIL), 50)
    sMOC = NormalizujOC(vals(F_MOC))
    If Len(sMOC) > 0 And JePlatneOC(sMOC) Then
        rs!ManagerOC = sMOC
    ElseIf Len(vals(F_MLOGIN)) > 0 Then
        rs!ManagerLogin = Left$(vals(F_MLOGIN), 100)
    ElseIf Len(vals(F_MOC)) > 0 Then
        ' v stĺpci vedúceho je login, nie číslo
        rs!ManagerLogin = Left$(vals(F_MOC), 100)
    End If
    rs!DatumImportu = Now()

    If rs.EditMode = dbEditAdd Then nNovych = nNovych + 1 Else nAkt = nAkt + 1
    rs.Update
End Sub
