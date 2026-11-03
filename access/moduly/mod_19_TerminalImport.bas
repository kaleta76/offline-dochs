Attribute VB_Name = "mod_19_TerminalImport"
'@Verzia 1.2.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_19_TerminalImport
' POPIS: Import razení zo súboru terminála (kontrakt v1: punches_*.csv) do Accessu.
'        Súbor sa najprv OVERÍ (hlavička, počet riadkov, SHA-256 pätičky, hash reťaz po používateľovi),
'        potom sa kódy terminála (code + direction) PREVEDÚ na prerušenia a kódy razenia Accessu
'        (tabuľka TerminalMapaKodov) a razenia sa uložia do TerminalInbox (idempotentne podľa external_id).
'        Spracovanie inboxu do DochadzkaImport robí mod_12_TerminalPriprava.SpracujInbox
'        (neznáme osobné číslo -> CHYBA, uzavretý mesiac -> UZAVRETY, duplicita -> DUPLICITA).
'
'        Pravidlá párovania (za zamestnanca a lokálny deň, podľa času):
'          WORK/IN        po otvorenom prerušení = jeho koniec (K), inak príchod (Z č. 1)
'          WORK/OUT       posledný WORK/OUT dňa (po ňom už nie je WORK/IN) = odchod (K č. 1);
'                         WORK/OUT medzi príchodmi = začiatok obeda (nastavenie TerminalOdchodBezDovodu = OBED)
'                         alebo odchod (= ODCHOD; potom ďalší WORK/IN je nový príchod)
'          X/OUT          začiatok prerušenia, ktoré je pre kód X v TerminalMapaKodov (Z)
'        Nezmyselné poradie (dvojitý príchod, koniec bez začiatku ...) importér NEOPRAVUJE: razenie sa
'        uloží tak, ako prišlo, a anomáliu rozpozná výpočet dňa (mod_08_UdalostiDna), rovnako ako pri iných zdrojoch.
'
'        Identita: terminál pozná len osobné číslo SAP. TerminalMapaOsob (voliteľná) ho prevedie na OsobneCislo;
'        inak sa hľadá presná zhoda a zhoda po odstránení / doplnení úvodných núl.
'
'        ZNEPLATNENÉ RAZENIA (kontrakt v1.1, voids_RRRRMM.csv): razenie, ktoré zamestnanec zneplatnil v terminále (napr. duplicita) a vedúci
'        schválil, sa v Accesse NEMAŽE: riadok DochadzkaImport dostane Platnost = False a DovodNeplatnosti = 'ZNEPLATNENE_V_TERMINALI'.
'        Zneplatnenia sa ukladajú do TerminalZneplatnenia a použijú sa, až keď je razenie v dochádzke a mesiac nie je uzavretý.
'
'        SAMOČINNÝ TEST (SamoTestTerminalu) overí SHA-256 na známych vektoroch, mapovanie kódov, načíta testovací
'        súbor "nanečisto", na požiadanie ho importuje pre testovacích zamestnancov 90000xx, prepočíta mesiac a
'        zapíše súbory terminal_test_report.txt a terminal_test_access_vysledky.csv (na porovnanie s terminálom).
' ZOZNAM VEREJNÝCH PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - ZabezpecTabulky(db)                      : Vytvorí TerminalMapaKodov (s predvoľbou) a TerminalMapaOsob.
' - NastavPredvolbuMapovania(db)             : Zapíše predvolené mapovanie siedmich kódov terminála na prerušenia.
' - ImportujSubor(cesta, nanecisto, prisne)  : Overí a importuje súbor; vráti textový report.
' - SamoTestTerminalu(cestaCSV)              : Test s reportom (súbory v priečinku databázy).
' - OdstranTestoveData()                     : Zmaže testovacie údaje zamestnancov 9000001 až 9000099.
' - JeSuborZneplatneni(cesta)                : Je súbor zoznam zneplatnených razení (voids_*.csv, kontrakt v1.1)?
' - ImportujZneplatnenia(cesta, nanecisto, prepocitat) : Overí a uloží zneplatnenia, použije ich na razenia v dochádzke.
' - SpracujZneplatnenia(prepocitat)           : Znova skúsi použiť čakajúce zneplatnenia (razenie importované neskôr, otvorený mesiac).
' - SamoTestZneplatneni(cestaCSV)             : Test zneplatnení nad testovacími údajmi 90000xx, prepočet a výsledky na porovnanie.
'===============================================================================

Private Type TRazenie
    PunchID As Long
    ExterneID As String
    Osc As String             ' osobné číslo SAP z terminála
    Kod As String             ' WORK, DOCTOR, TRIP, ...
    Smer As String            ' IN / OUT
    Lokalny As Date           ' lokálny čas razenia (Europe/Bratislava)
    Den As String             ' lokálny deň RRRR-MM-DD
    CasUtc As String          ' RRRR-MM-DDTHH:MM:SS (bez Z)
    CasServer As String       ' RRRR-MM-DDTHH:MM:SS (bez Z)
    UserUuid As String
    PrevHash As String
    RecHash As String
    DeviceID As String
    Zdroj As String           ' terminal / correction
    Overenie As String        ' verified / unverified / confirmed
    Riadok As String          ' pôvodný riadok súboru (do Payload)
    CisloPrer As Long         ' výsledné prerušenie v Accesse (0 = neurčené)
    SmerAccess As String      ' Z / K
    KodRazenia As Long        ' kód razenia v Accesse (100 až 133)
    Chyba As String
End Type

Private mP2(0 To 30) As Long
Private mK(0 To 63) As Long
Private mInit As Boolean

'===============================================================================
' SHA-256 (čistý VBA, bez .NET) - 32-bitové Long so znamienkom, preto vlastné sčítanie a posuny
'===============================================================================
Private Sub InitSha()
    Dim i As Long
    If mInit Then Exit Sub
    mP2(0) = 1
    For i = 1 To 30
        mP2(i) = mP2(i - 1) * 2
    Next i
    mK(0) = &H428A2F98
    mK(1) = &H71374491
    mK(2) = &HB5C0FBCF
    mK(3) = &HE9B5DBA5
    mK(4) = &H3956C25B
    mK(5) = &H59F111F1
    mK(6) = &H923F82A4
    mK(7) = &HAB1C5ED5
    mK(8) = &HD807AA98
    mK(9) = &H12835B01
    mK(10) = &H243185BE
    mK(11) = &H550C7DC3
    mK(12) = &H72BE5D74
    mK(13) = &H80DEB1FE
    mK(14) = &H9BDC06A7
    mK(15) = &HC19BF174
    mK(16) = &HE49B69C1
    mK(17) = &HEFBE4786
    mK(18) = &H0FC19DC6
    mK(19) = &H240CA1CC
    mK(20) = &H2DE92C6F
    mK(21) = &H4A7484AA
    mK(22) = &H5CB0A9DC
    mK(23) = &H76F988DA
    mK(24) = &H983E5152
    mK(25) = &HA831C66D
    mK(26) = &HB00327C8
    mK(27) = &HBF597FC7
    mK(28) = &HC6E00BF3
    mK(29) = &HD5A79147
    mK(30) = &H06CA6351
    mK(31) = &H14292967
    mK(32) = &H27B70A85
    mK(33) = &H2E1B2138
    mK(34) = &H4D2C6DFC
    mK(35) = &H53380D13
    mK(36) = &H650A7354
    mK(37) = &H766A0ABB
    mK(38) = &H81C2C92E
    mK(39) = &H92722C85
    mK(40) = &HA2BFE8A1
    mK(41) = &HA81A664B
    mK(42) = &HC24B8B70
    mK(43) = &HC76C51A3
    mK(44) = &HD192E819
    mK(45) = &HD6990624
    mK(46) = &HF40E3585
    mK(47) = &H106AA070
    mK(48) = &H19A4C116
    mK(49) = &H1E376C08
    mK(50) = &H2748774C
    mK(51) = &H34B0BCB5
    mK(52) = &H391C0CB3
    mK(53) = &H4ED8AA4A
    mK(54) = &H5B9CCA4F
    mK(55) = &H682E6FF3
    mK(56) = &H748F82EE
    mK(57) = &H78A5636F
    mK(58) = &H84C87814
    mK(59) = &H8CC70208
    mK(60) = &H90BEFFFA
    mK(61) = &HA4506CEB
    mK(62) = &HBEF9A3F7
    mK(63) = &HC67178F2
    mInit = True
End Sub

' súčet modulo 2^32
Private Function Sc(ByVal a As Long, ByVal b As Long) As Long
    Dim lo As Long, hi As Long
    lo = (a And &HFFFF&) + (b And &HFFFF&)
    hi = (((a And &HFFFF0000) \ &H10000) And &HFFFF&) + (((b And &HFFFF0000) \ &H10000) And &HFFFF&) + (lo \ &H10000)
    hi = hi And &HFFFF&
    Sc = ((hi And &H7FFF&) * &H10000) Or (lo And &HFFFF&)
    If (hi And &H8000&) <> 0 Then Sc = Sc Or &H80000000
End Function

' logický posun doprava, 1 <= n <= 30
Private Function ShrL(ByVal x As Long, ByVal n As Long) As Long
    If x >= 0 Then
        ShrL = x \ mP2(n)
    Else
        ShrL = ((x And &H7FFFFFFF) \ mP2(n)) Or mP2(31 - n)
    End If
End Function

' posun doľava, 7 <= k <= 30 (vyššie bity sa zahodia)
Private Function ShlL(ByVal x As Long, ByVal k As Long) As Long
    Dim m As Long
    m = x And (mP2(32 - k) - 1)
    ShlL = (m And (mP2(31 - k) - 1)) * mP2(k)
    If (m And mP2(31 - k)) <> 0 Then ShlL = ShlL Or &H80000000
End Function

Private Function RotR(ByVal x As Long, ByVal n As Long) As Long
    RotR = ShrL(x, n) Or ShlL(x, 32 - n)
End Function

Private Sub BlokSha(ByRef h() As Long, ByRef w() As Long)
    Dim a As Long, b As Long, c As Long, d As Long, e As Long, f As Long, g As Long, hh As Long
    Dim t As Long, t1 As Long, t2 As Long, s0 As Long, s1 As Long
    For t = 16 To 63
        s0 = RotR(w(t - 15), 7) Xor RotR(w(t - 15), 18) Xor ShrL(w(t - 15), 3)
        s1 = RotR(w(t - 2), 17) Xor RotR(w(t - 2), 19) Xor ShrL(w(t - 2), 10)
        w(t) = Sc(Sc(Sc(w(t - 16), s0), w(t - 7)), s1)
    Next t
    a = h(0): b = h(1): c = h(2): d = h(3): e = h(4): f = h(5): g = h(6): hh = h(7)
    For t = 0 To 63
        s1 = RotR(e, 6) Xor RotR(e, 11) Xor RotR(e, 25)
        t1 = Sc(Sc(Sc(Sc(hh, s1), (e And f) Xor ((Not e) And g)), mK(t)), w(t))
        s0 = RotR(a, 2) Xor RotR(a, 13) Xor RotR(a, 22)
        t2 = Sc(s0, (a And b) Xor (a And c) Xor (b And c))
        hh = g: g = f: f = e: e = Sc(d, t1): d = c: c = b: b = a: a = Sc(t1, t2)
    Next t
    h(0) = Sc(h(0), a): h(1) = Sc(h(1), b): h(2) = Sc(h(2), c): h(3) = Sc(h(3), d)
    h(4) = Sc(h(4), e): h(5) = Sc(h(5), f): h(6) = Sc(h(6), g): h(7) = Sc(h(7), hh)
End Sub

' bajt doplnenej správy na pozícii p (0 .. lCelkom - 1)
Private Function BajtSpravy(ByRef b() As Byte, ByVal lOd As Long, ByVal lDlzka As Long, ByVal lCelkom As Long, ByVal lBitov As Long, ByVal p As Long) As Long
    If p < lDlzka Then
        BajtSpravy = b(lOd + p)
    ElseIf p = lDlzka Then
        BajtSpravy = 128
    ElseIf p >= lCelkom - 4 Then
        Select Case p - (lCelkom - 4)
            Case 0: BajtSpravy = (lBitov \ &H1000000) And &HFF&
            Case 1: BajtSpravy = (lBitov \ &H10000) And &HFF&
            Case 2: BajtSpravy = (lBitov \ &H100&) And &HFF&
            Case Else: BajtSpravy = lBitov And &HFF&
        End Select
    Else
        BajtSpravy = 0
    End If
End Function

' SHA-256 z lDlzka bajtov poľa b od indexu lOd; vráti 64 malých hexadecimálnych znakov
Private Function Sha256Hex(ByRef b() As Byte, ByVal lOd As Long, ByVal lDlzka As Long) As String
    Dim h(0 To 7) As Long, w(0 To 63) As Long, x(0 To 3) As Long
    Dim bl As Long, j As Long, k As Long, p As Long, lCelkom As Long, lBitov As Long, s As String
    Call InitSha
    If lDlzka > 100000000 Then Err.Raise vbObjectError + 1900, "mod_19_TerminalImport.Sha256Hex", "Súbor je príliš veľký na kontrolu SHA-256."
    h(0) = &H6A09E667
    h(1) = &HBB67AE85
    h(2) = &H3C6EF372
    h(3) = &HA54FF53A
    h(4) = &H510E527F
    h(5) = &H9B05688C
    h(6) = &H1F83D9AB
    h(7) = &H5BE0CD19
    lCelkom = ((lDlzka + 8) \ 64 + 1) * 64
    lBitov = lDlzka * 8
    For bl = 0 To lCelkom \ 64 - 1
        For j = 0 To 15
            For k = 0 To 3
                p = bl * 64 + j * 4 + k
                x(k) = BajtSpravy(b, lOd, lDlzka, lCelkom, lBitov, p)
            Next k
            w(j) = ((x(0) And &H7F&) * &H1000000) Or (x(1) * &H10000) Or (x(2) * &H100&) Or x(3)
            If (x(0) And &H80&) <> 0 Then w(j) = w(j) Or &H80000000
        Next j
        Call BlokSha(h, w)
    Next bl
    For j = 0 To 7
        s = s & LCase$(Right$("00000000" & Hex$(h(j)), 8))
    Next j
    Sha256Hex = s
End Function

Private Function Sha256Text(ByVal strText As String) As String
    Dim b() As Byte, n As Long
    b = StrConv(strText, vbFromUnicode)
    n = Len(strText)
    If n > 0 Then n = UBound(b) + 1
    Sha256Text = Sha256Hex(b, 0, n)
End Function

'===============================================================================
' Pomocné funkcie
'===============================================================================
Private Sub Pis(ByRef rep As String, ByVal s As String)
    rep = rep & s & vbCrLf
End Sub

Private Function CitajBajty(ByVal strCesta As String, ByRef b() As Byte) As Long
    Dim f As Integer, n As Long
    f = FreeFile
    Open strCesta For Binary Access Read As #f
    n = LOF(f)
    If n > 0 Then
        ReDim b(0 To n - 1)
        Get #f, 1, b
    End If
    Close #f
    CitajBajty = n
End Function

' Rozdelí riadok CSV podľa ";" (texty môžu byť v úvodzovkách, "" = úvodzovka). Vráti počet polí.
Private Function RozdelRiadok(ByVal s As String, ByRef pole() As String) As Long
    Dim i As Long, n As Long, c As String, bUv As Boolean, cur As String
    ReDim pole(0 To 63)
    i = 1
    Do While i <= Len(s)
        c = Mid$(s, i, 1)
        If bUv Then
            If c = """" Then
                If Mid$(s, i + 1, 1) = """" Then
                    cur = cur & """"
                    i = i + 1
                Else
                    bUv = False
                End If
            Else
                cur = cur & c
            End If
        ElseIf c = """" Then
            bUv = True
        ElseIf c = ";" Then
            If n < 63 Then pole(n) = cur
            n = n + 1
            cur = ""
        Else
            cur = cur & c
        End If
        i = i + 1
    Loop
    If n < 63 Then pole(n) = cur
    n = n + 1
    If n > 64 Then n = 64
    RozdelRiadok = n
End Function

' RRRR-MM-DD HH:MM:SS -> Date
Private Function ParsujLokalny(ByVal s As String, ByRef d As Date) As Boolean
    On Error GoTo Zle
    If Len(s) < 19 Then Exit Function
    d = DateSerial(CInt(Mid$(s, 1, 4)), CInt(Mid$(s, 6, 2)), CInt(Mid$(s, 9, 2))) + _
        TimeSerial(CInt(Mid$(s, 12, 2)), CInt(Mid$(s, 15, 2)), CInt(Mid$(s, 18, 2)))
    ParsujLokalny = True
    Exit Function
Zle:
    ParsujLokalny = False
End Function

Private Function SkupinaKluc(ByRef r As TRazenie) As String
    SkupinaKluc = r.Osc & "|" & r.Den
End Function

Private Sub ZoradKluce(ByRef kl() As String, ByRef ix() As Long, ByVal lo As Long, ByVal hi As Long)
    Dim i As Long, j As Long, pv As String, tk As String, ti As Long
    i = lo: j = hi
    pv = kl((lo + hi) \ 2)
    Do While i <= j
        Do While StrComp(kl(i), pv, vbBinaryCompare) < 0
            i = i + 1
        Loop
        Do While StrComp(kl(j), pv, vbBinaryCompare) > 0
            j = j - 1
        Loop
        If i <= j Then
            tk = kl(i): kl(i) = kl(j): kl(j) = tk
            ti = ix(i): ix(i) = ix(j): ix(j) = ti
            i = i + 1: j = j - 1
        End If
    Loop
    If lo < j Then Call ZoradKluce(kl, ix, lo, j)
    If i < hi Then Call ZoradKluce(kl, ix, i, hi)
End Sub

Private Function Doplnit(ByVal s As String, ByVal n As Long) As String
    If Len(s) < n Then Doplnit = String$(n - Len(s), "0") & s Else Doplnit = s
End Function

'===============================================================================
' Tabuľky a mapovanie
'===============================================================================
Public Sub ZabezpecTabulky(ByRef db As DAO.Database)
    If Not mod_00_Common.TabulkaExistujeDB(db, "TerminalMapaKodov") Then
        db.Execute "CREATE TABLE TerminalMapaKodov (Kod TEXT(20) PRIMARY KEY, CisloPreruseni LONG, Poznamka TEXT(120))", dbFailOnError
        Call NastavPredvolbuMapovania(db)
    End If
    If Not mod_00_Common.TabulkaExistujeDB(db, "TerminalMapaOsob") Then
        db.Execute "CREATE TABLE TerminalMapaOsob (SapCislo TEXT(20) PRIMARY KEY, OsobneCislo TEXT(20))", dbFailOnError
    End If
    Call ZabezpecTabulkuZneplatneni(db)
End Sub

' Predvolené mapovanie kódov terminála na čísla prerušení v Accesse (upraviteľné v tabuľke TerminalMapaKodov).
Public Sub NastavPredvolbuMapovania(ByRef db As DAO.Database)
    Dim v As Variant, p As Variant
    db.Execute "DELETE FROM TerminalMapaKodov", dbFailOnError
    For Each v In Array("WORK|1|Pracovná doba (príchod / odchod)", "DOCTOR|2|Návšteva lekára", "TRIP|12|Služobná cesta", _
                        "FAMILY|16|Ošetrenie člena rodiny (overiť)", "LEAVE|8|Dovolenka", "SICK|11|Nemoc", "PRIV|13|Ostatné osobné prekážky (overiť)")
        p = Split(CStr(v), "|")
        db.Execute "INSERT INTO TerminalMapaKodov (Kod, CisloPreruseni, Poznamka) VALUES (" & mod_00_Common.SqlText(CStr(p(0))) & ", " & CLng(p(1)) & ", " & _
                   mod_00_Common.SqlText(CStr(p(2))) & ")", dbFailOnError
    Next v
    Call mod_00_Common.ZapisLog("mod_19_TerminalImport.NastavPredvolbuMapovania", "INFO", "Predvolené mapovanie kódov terminála zapísané.")
End Sub

Private Function KodRazeniaPre(ByVal lCislo As Long, ByVal strSmer As String, ByRef dic As Object) As Long
    Dim k As String, v As Variant
    If lCislo <= 0 Then Exit Function
    k = lCislo & "|" & strSmer
    If dic.Exists(k) Then
        KodRazeniaPre = dic(k)
        Exit Function
    End If
    v = DLookup("KodRazenia", "KodyRazeni", "CisloPreruseni = " & lCislo & " AND Smer = '" & strSmer & "'")
    If IsNull(v) Then KodRazeniaPre = 0 Else KodRazeniaPre = CLng(v)
    dic(k) = KodRazeniaPre
End Function

Private Function NajdiOsobneCislo(ByVal strSap As String, ByRef dic As Object) As String
    Dim s As String, v As Variant, k As Variant, res As String
    strSap = Trim$(strSap)
    If dic.Exists(strSap) Then
        NajdiOsobneCislo = dic(strSap)
        Exit Function
    End If
    res = strSap
    v = DLookup("OsobneCislo", "TerminalMapaOsob", "SapCislo = " & mod_00_Common.SqlText(strSap))
    If Not IsNull(v) Then
        res = CStr(v)
    Else
        s = strSap
        Do While Len(s) > 1 And Left$(s, 1) = "0"
            s = Mid$(s, 2)
        Loop
        For Each k In Array(strSap, s, Doplnit(s, 7), Doplnit(s, 8))
            If DCount("*", "Zamestnanci", "OsobneCislo = " & mod_00_Common.SqlText(CStr(k))) > 0 Then
                res = CStr(k)
                Exit For
            End If
        Next k
    End If
    dic(strSap) = res
    NajdiOsobneCislo = res
End Function

' Načíta mapovanie kódov terminála do slovníka Kod -> číslo prerušenia.
Private Function NacitajMapuKodov(ByRef db As DAO.Database) As Object
    Dim dic As Object, rs As DAO.Recordset
    Set dic = CreateObject("Scripting.Dictionary")
    Set rs = db.OpenRecordset("SELECT Kod, CisloPreruseni FROM TerminalMapaKodov;", dbOpenSnapshot)
    Do While Not rs.EOF
        dic(UCase$(Trim$(CStr(rs!Kod)))) = CLng(Nz(rs!CisloPreruseni, 0))
        rs.MoveNext
    Loop
    rs.Close
    Set NacitajMapuKodov = dic
End Function

'===============================================================================
' Párovanie: z kódu terminála (code + direction) a poradia razení za deň urči prerušenie a smer Z/K
'===============================================================================
Private Sub SparujRazenia(ByRef r() As TRazenie, ByRef ix() As Long, ByVal n As Long, ByVal bObed As Boolean, _
                          ByRef mapa As Object, ByRef kodDic As Object)
    Dim g0 As Long, g1 As Long, i As Long, k As Long, lastIn As Long, openNo As Long
    Dim cislo As Long, strSmer As String, lObed As Long
    lObed = CLng(Val(mod_00_Common.GetNastavenie("TerminalObedCislo", "7")))
    g0 = 0
    Do While g0 < n
        g1 = g0
        Do While g1 + 1 < n
            If SkupinaKluc(r(ix(g1 + 1))) <> SkupinaKluc(r(ix(g0))) Then Exit Do
            g1 = g1 + 1
        Loop
        lastIn = -1
        For k = g0 To g1
            If r(ix(k)).Kod = "WORK" And r(ix(k)).Smer = "IN" Then lastIn = k
        Next k
        openNo = 0
        For k = g0 To g1
            i = ix(k)
            If Len(r(i).Chyba) = 0 Then
                cislo = 0: strSmer = ""
                If r(i).Kod = "WORK" Then
                    If r(i).Smer = "IN" Then
                        If openNo <> 0 Then
                            cislo = openNo: strSmer = "K": openNo = 0
                        Else
                            cislo = 1: strSmer = "Z"
                        End If
                    Else
                        If k > lastIn Then
                            cislo = 1: strSmer = "K": openNo = 0
                        ElseIf bObed Then
                            cislo = lObed: strSmer = "Z": openNo = lObed
                        Else
                            cislo = 1: strSmer = "K": openNo = 0
                        End If
                    End If
                ElseIf mapa.Exists(r(i).Kod) Then
                    cislo = CLng(mapa(r(i).Kod))
                    If r(i).Smer = "OUT" Then
                        strSmer = "Z": openNo = cislo
                    Else
                        strSmer = "K"
                        If openNo = cislo Then openNo = 0
                    End If
                Else
                    r(i).Chyba = "Kód '" & r(i).Kod & "' nie je v TerminalMapaKodov"
                End If
                If Len(r(i).Chyba) = 0 Then
                    r(i).CisloPrer = cislo
                    r(i).SmerAccess = strSmer
                    r(i).KodRazenia = KodRazeniaPre(cislo, strSmer, kodDic)
                    If r(i).KodRazenia = 0 Then r(i).Chyba = "V KodyRazeni chýba prerušenie č. " & cislo & " smer " & strSmer
                End If
            End If
        Next k
        g0 = g1 + 1
    Loop
End Sub

'===============================================================================
' Import súboru
'===============================================================================
Public Function ImportujSubor(ByVal strCesta As String, Optional ByVal bNanecisto As Boolean = False, Optional ByVal bPrisne As Boolean = True) As String
    On Error GoTo Chyba
    Dim rep As String, b() As Byte, lN As Long, lStart As Long, p As Long, lHashDlzka As Long
    Dim strPatickaText As String, vP As Variant, i As Long, k As Long
    Dim strRowsP As String, strShaP As String, strShaVyp As String, lRowsP As Long
    Dim strCely As String, strTelo As String, riadky() As String, pole() As String, nPol As Long
    Dim hdr As Object, hlav() As String, nH As Long, kolko As Long
    Dim r() As TRazenie, n As Long, nChybRiadkov As Long, nTvrde As Long
    Dim lMaxId As Long, strOrg As String, strOrgUlozena As String
    Dim lastHash As Object, strVstup As String, strHash As String, nRetaz As Long, nMimo As Long, nPrvych As Long
    Dim kl() As String, ix() As Long, db As DAO.Database, mapa As Object, kodDic As Object, oscDic As Object
    Dim bObed As Boolean, nImp As Long, nDup As Long, nErrIn As Long, lID As Long, strZar As String, dtLok As Date
    Dim colNazvy As Variant, c As Variant, strZn As String

    Pis rep, "Import z terminála: " & strCesta & IIf(bNanecisto, "   [NANEČISTO - nič sa nezapíše]", "")
    If Len(Dir(strCesta)) = 0 Then
        Pis rep, "CHYBA: súbor sa nenašiel."
        ImportujSubor = rep: Exit Function
    End If

    lN = CitajBajty(strCesta, b)
    If lN < 20 Then
        Pis rep, "CHYBA: súbor je prázdny alebo príliš krátky."
        ImportujSubor = rep: Exit Function
    End If
    If lN > 3 Then
        If b(0) = &HEF And b(1) = &HBB And b(2) = &HBF Then lStart = 3
    End If

    ' --- pätička #END;rows=N;sha256=... ---
    p = -1
    For i = lN - 5 To lStart Step -1
        If b(i) = 35 And b(i + 1) = 69 And b(i + 2) = 78 And b(i + 3) = 68 And b(i + 4) = 59 Then
            If i = lStart Then
                p = i: Exit For
            ElseIf b(i - 1) = 10 Then
                p = i: Exit For
            End If
        End If
    Next i
    If p < 0 Then
        Pis rep, "CHYBA: chýba pätička #END (súbor je neúplný)."
        ImportujSubor = rep: Exit Function
    End If
    lHashDlzka = p - lStart
    strCely = StrConv(b, vbUnicode)
    strPatickaText = Trim$(Replace(Replace(Mid$(strCely, p + 1), vbCr, ""), vbLf, ""))
    For Each vP In Split(strPatickaText, ";")
        If LCase$(Left$(CStr(vP), 5)) = "rows=" Then strRowsP = Mid$(CStr(vP), 6)
        If LCase$(Left$(CStr(vP), 7)) = "sha256=" Then strShaP = LCase$(Mid$(CStr(vP), 8))
    Next vP
    lRowsP = CLng(Val(strRowsP))

    ' --- SHA-256 pätičky ---
    strShaVyp = Sha256Hex(b, lStart, lHashDlzka)
    If strShaVyp = strShaP Then
        Pis rep, "SHA-256 pätičky: OK (" & strShaVyp & ")"
    Else
        Pis rep, "SHA-256 pätičky: NESEDÍ  v súbore " & strShaP & "  vypočítané " & strShaVyp
        nTvrde = nTvrde + 1
    End If

    ' --- hlavička a riadky ---
    strTelo = Mid$(strCely, lStart + 1, lHashDlzka)
    riadky = Split(strTelo, vbCrLf)
    nH = RozdelRiadok(riadky(0), hlav)
    Set hdr = CreateObject("Scripting.Dictionary")
    For i = 0 To nH - 1
        hdr(Trim$(hlav(i))) = i
    Next i
    colNazvy = Array("contract_version", "punch_id", "external_id", "personnel_number", "code", "direction", "client_time_local", _
                     "client_time_utc", "server_time_utc", "source", "device_verification", "device_id", "user_uuid", "prev_hash", "record_hash", "organization_id")
    For Each c In colNazvy
        If Not hdr.Exists(CStr(c)) Then
            Pis rep, "CHYBA: v hlavičke chýba stĺpec " & CStr(c)
            ImportujSubor = rep: Exit Function
        End If
    Next c

    ReDim r(0 To UBound(riadky))
    For i = 1 To UBound(riadky)
        If Len(Trim$(riadky(i))) > 0 Then
            nPol = RozdelRiadok(riadky(i), pole)
            With r(n)
                .Riadok = riadky(i)
                If nPol < nH Then
                    .Chyba = "Riadok " & (i + 1) & ": menej polí než hlavička"
                Else
                    If CStr(pole(hdr("contract_version"))) <> "1" Then .Chyba = "Riadok " & (i + 1) & ": nepodporovaná verzia kontraktu " & pole(hdr("contract_version"))
                    .PunchID = CLng(Val(pole(hdr("punch_id"))))
                    .ExterneID = Trim$(pole(hdr("external_id")))
                    .Osc = Trim$(pole(hdr("personnel_number")))
                    .Kod = UCase$(Trim$(pole(hdr("code"))))
                    .Smer = UCase$(Trim$(pole(hdr("direction"))))
                    .CasUtc = Left$(Trim$(pole(hdr("client_time_utc"))), 19)
                    .CasServer = Left$(Trim$(pole(hdr("server_time_utc"))), 19)
                    .UserUuid = Trim$(pole(hdr("user_uuid")))
                    .PrevHash = Trim$(pole(hdr("prev_hash")))
                    .RecHash = LCase$(Trim$(pole(hdr("record_hash"))))
                    .DeviceID = Trim$(pole(hdr("device_id")))
                    .Zdroj = LCase$(Trim$(pole(hdr("source"))))
                    .Overenie = LCase$(Trim$(pole(hdr("device_verification"))))
                    strOrg = Trim$(pole(hdr("organization_id")))
                    If Not ParsujLokalny(Trim$(pole(hdr("client_time_local"))), .Lokalny) Then
                        If Len(.Chyba) = 0 Then .Chyba = "Riadok " & (i + 1) & ": neplatný lokálny čas '" & pole(hdr("client_time_local")) & "'"
                    Else
                        .Den = Format$(.Lokalny, "yyyy\-mm\-dd")
                    End If
                    If Len(.Osc) = 0 Or Len(.ExterneID) = 0 Then
                        If Len(.Chyba) = 0 Then .Chyba = "Riadok " & (i + 1) & ": chýba osobné číslo alebo external_id"
                    End If
                    If .Smer <> "IN" And .Smer <> "OUT" Then
                        If Len(.Chyba) = 0 Then .Chyba = "Riadok " & (i + 1) & ": smer musí byť IN alebo OUT"
                    End If
                End If
                If Len(.Chyba) > 0 Then nChybRiadkov = nChybRiadkov + 1
                If .PunchID > lMaxId Then lMaxId = .PunchID
            End With
            n = n + 1
        End If
    Next i
    Pis rep, "Riadkov v súbore: " & n & "  (pätička uvádza " & lRowsP & ")" & IIf(n = lRowsP, "  OK", "  NESEDÍ")
    If n <> lRowsP Then nTvrde = nTvrde + 1
    If n = 0 Then
        ImportujSubor = rep: Exit Function
    End If

    ' --- hash reťaz po používateľovi (v poradí súboru) ---
    Set lastHash = CreateObject("Scripting.Dictionary")
    For i = 0 To n - 1
        If Len(r(i).Chyba) = 0 Then
            strVstup = r(i).PrevHash & "|" & r(i).UserUuid & "|" & r(i).Kod & "|" & r(i).Smer & "|" & r(i).CasUtc & "|" & r(i).CasServer & "|" & r(i).ExterneID
            If Len(r(i).DeviceID) > 0 Then strVstup = strVstup & "|" & r(i).DeviceID
            strHash = Sha256Text(strVstup)
            ' kód v súbore je v pôvodnej podobe (veľké písmená), hash sa počíta z toho istého textu
            If strHash <> r(i).RecHash Then
                nRetaz = nRetaz + 1
                If nRetaz <= 5 Then Pis rep, "  hash záznamu NESEDÍ: punch_id " & r(i).PunchID
            End If
            If lastHash.Exists(r(i).UserUuid) Then
                If r(i).PrevHash <> lastHash(r(i).UserUuid) Then
                    nRetaz = nRetaz + 1
                    If nRetaz <= 5 Then Pis rep, "  reťaz sa nenadväzuje: punch_id " & r(i).PunchID
                End If
            Else
                nPrvych = nPrvych + 1
                If r(i).PrevHash <> "GENESIS" Then nMimo = nMimo + 1
            End If
            lastHash(r(i).UserUuid) = r(i).RecHash
        End If
    Next i
    If nRetaz = 0 Then
        Pis rep, "Hash reťaz: OK (používateľov v súbore " & nPrvych & ", z toho s predchodcom mimo súboru " & nMimo & " - upozornenie, nie chyba)"
    Else
        Pis rep, "Hash reťaz: CHYBY " & nRetaz
        nTvrde = nTvrde + 1
    End If
    Pis rep, "Poznámka: nadväznosť na predchádzajúci import (posledný hash používateľa) sa zatiaľ nekontroluje."

    If nTvrde > 0 And bPrisne Then
        Pis rep, "IMPORT ZASTAVENÝ: súbor nespĺňa kontrakt (pozri vyššie). Nič sa nezapísalo."
        ImportujSubor = rep: Exit Function
    End If

    ' --- organizácia ---
    Set db = CurrentDb
    Call ZabezpecTabulky(db)
    strOrgUlozena = mod_00_Common.GetNastavenie("TerminalOrganizationId", "")
    If Len(strOrgUlozena) > 0 And Len(strOrg) > 0 And strOrg <> strOrgUlozena Then
        Pis rep, "IMPORT ZASTAVENÝ: súbor je z inej organizácie terminála (" & strOrg & ") než predchádzajúce importy (" & strOrgUlozena & ")."
        ImportujSubor = rep: Exit Function
    End If

    ' --- zoradenie podľa zamestnanca, dňa, času ---
    ReDim kl(0 To n - 1): ReDim ix(0 To n - 1)
    For i = 0 To n - 1
        ix(i) = i
        kl(i) = r(i).Osc & "|" & r(i).Den & "|" & r(i).CasUtc & "|" & Format$(r(i).PunchID, "0000000000")
    Next i
    Call ZoradKluce(kl, ix, 0, n - 1)

    ' --- párovanie ---
    Set mapa = NacitajMapuKodov(db)
    Set kodDic = CreateObject("Scripting.Dictionary")
    bObed = (UCase$(mod_00_Common.GetNastavenie("TerminalOdchodBezDovodu", "OBED")) <> "ODCHOD")
    Call SparujRazenia(r, ix, n, bObed, mapa, kodDic)
    nErrIn = 0
    For i = 0 To n - 1
        If Len(r(i).Chyba) > 0 Then nErrIn = nErrIn + 1
    Next i
    Pis rep, "Párovanie: razení bez chyby " & (n - nErrIn) & ", s chybou " & nErrIn & "; WORK/OUT medzi príchodmi = " & IIf(bObed, "obed č. " & mod_00_Common.GetNastavenie("TerminalObedCislo", "7"), "odchod")
    kolko = 0
    For k = 0 To n - 1
        i = ix(k)
        If Len(r(i).Chyba) > 0 Then
            If kolko < 20 Then Pis rep, "  CHYBA punch_id " & r(i).PunchID & ": " & r(i).Chyba
            kolko = kolko + 1
        End If
    Next k
    If bNanecisto Then
        Pis rep, "Prehľad (poradie: zamestnanec, deň, čas):"
        For k = 0 To n - 1
            If k >= 120 Then
                Pis rep, "  ... ďalších " & (n - k) & " riadkov sa nevypisuje"
                Exit For
            End If
            i = ix(k)
            Pis rep, "  " & r(i).Osc & " " & Format$(r(i).Lokalny, "yyyy\-mm\-dd hh:nn") & "  " & r(i).Kod & "/" & r(i).Smer & "  ->  č." & r(i).CisloPrer & " " & r(i).SmerAccess & "  kód razenia " & r(i).KodRazenia & IIf(Len(r(i).Chyba) > 0, "  CHYBA", "")
        Next k
        Pis rep, "Nanečisto: do databázy sa nič nezapísalo."
        ImportujSubor = rep: Exit Function
    End If

    ' --- zápis do TerminalInbox + spracovanie ---
    Set oscDic = CreateObject("Scripting.Dictionary")
    For i = 0 To n - 1
        If Len(r(i).Chyba) = 0 Then
            If Len(r(i).Zdroj) > 0 And r(i).Zdroj = "correction" Then
                strZar = "korekcia"
            ElseIf Len(r(i).DeviceID) > 0 Then
                strZar = Left$(r(i).DeviceID, 8)
            Else
                strZar = "terminal"
            End If
            lID = mod_12_TerminalPriprava.PrijmiRazenie(r(i).ExterneID, NajdiOsobneCislo(r(i).Osc, oscDic), r(i).Lokalny, r(i).KodRazenia, strZar, r(i).Riadok)
            If lID > 0 Then
                nImp = nImp + 1
            ElseIf lID = 0 Then
                nDup = nDup + 1
            Else
                nErrIn = nErrIn + 1
            End If
        End If
    Next i
    If Len(strOrgUlozena) = 0 And Len(strOrg) > 0 Then Call mod_00_Common.SetNastavenie("TerminalOrganizationId", strOrg, "Organizácia terminála, z ktorej sa importuje")
    If lMaxId > CLng(Val(mod_00_Common.GetNastavenie("TerminalPoslednePunchId", "0"))) Then
        Call mod_00_Common.SetNastavenie("TerminalPoslednePunchId", CStr(lMaxId), "Najvyššie punch_id z posledného importu z terminála")
    End If
    Pis rep, "Do fronty TerminalInbox: nových " & nImp & ", už existujúcich (external_id) " & nDup
    Pis rep, mod_12_TerminalPriprava.SpracujInbox()
    ' zneplatnenia, ktoré čakali na toto razenie (súbor voids_*.csv sa mohol importovať skôr)
    strZn = SpracujZneplatnenia(False)
    If Len(strZn) > 0 Then Pis rep, strZn
    Pis rep, "Posledné punch_id v súbore: " & lMaxId & " (ďalší export žiadajte od " & IIf(lMaxId > 500, lMaxId - 500, 0) & ")"
    ImportujSubor = rep
    Exit Function
Chyba:
    ImportujSubor = rep & "CHYBA importu: " & Err.Number & " " & Err.Description
    Call mod_00_Common.ZapisLog("mod_19_TerminalImport.ImportujSubor", "ERROR", Err.Description)
End Function

'===============================================================================
' Zneplatnené razenia z terminála (kontrakt v1.1: voids_RRRRMM.csv)
'
' Razenie sa v Accesse NEMAŽE: riadok DochadzkaImport dostane Platnost = False a DovodNeplatnosti = 'ZNEPLATNENE_V_TERMINALI'.
' Zoznam sa uloží do TerminalZneplatnenia (idempotentne podľa ExterneID) a spracúva sa opakovane, kým sa nepoužije.
' Stav riadku v TerminalZneplatnenia:
'   CAKA        razenie ešte nie je v dochádzke (importuje sa neskôr) alebo čaká vo fronte TerminalInbox
'   UZAVRETY    mesiac je uzavretý; zneplatnenie sa použije pri ďalšom spracovaní po otvorení mesiaca
'   APLIKOVANE  zneplatnenie sa použilo (alebo bolo razenie už predtým neplatné)
'   NEZHODA     hash alebo osobné číslo nesedí s importovaným razením; nezneplatní sa, treba skontrolovať
'===============================================================================
Private Sub ZabezpecTabulkuZneplatneni(ByRef db As DAO.Database)
    If Not mod_00_Common.TabulkaExistujeDB(db, "TerminalZneplatnenia") Then
        db.Execute "CREATE TABLE TerminalZneplatnenia (ID AUTOINCREMENT PRIMARY KEY, PrijateKedy DATETIME, ExterneID TEXT(50), PunchID LONG, OsobneCislo TEXT(20), " & _
                   "RecordHash TEXT(64), ZneplatneneUtc TEXT(20), Stav TEXT(12), Chyba TEXT(255), DatumSpracovania DATETIME)", dbFailOnError
        db.Execute "CREATE INDEX idxTZ_ExterneID ON TerminalZneplatnenia (ExterneID)", dbFailOnError
        db.Execute "CREATE INDEX idxTZ_Stav ON TerminalZneplatnenia (Stav)", dbFailOnError
    End If
End Sub

' True, ak prvý riadok súboru je hlavička zoznamu zneplatnených razení (obsahuje stĺpec voided_at_utc).
Public Function JeSuborZneplatneni(ByVal strCesta As String) As Boolean
    Dim f As Integer, s As String
    On Error GoTo Zle
    If Len(Dir(strCesta)) = 0 Then Exit Function
    f = FreeFile
    Open strCesta For Input As #f
    If Not EOF(f) Then Line Input #f, s
    Close #f
    JeSuborZneplatneni = (InStr(1, s, "voided_at_utc", vbTextCompare) > 0)
    Exit Function
Zle:
    On Error Resume Next
    Close #f
End Function

' Overí súbor kontraktu: pätička #END, počet riadkov a SHA-256 tela. Vráti telo (bez BOM a bez pätičky). False = súbor sa nedá použiť.
Private Function OverSuborKontraktu(ByVal strCesta As String, ByRef rep As String, ByRef strTelo As String, ByRef lRowsP As Long, ByRef nTvrde As Long) As Boolean
    Dim b() As Byte, lN As Long, lStart As Long, p As Long, lHashDlzka As Long, i As Long, vP As Variant
    Dim strCely As String, strPatickaText As String, strShaP As String, strShaVyp As String, strRowsP As String

    If Len(Dir(strCesta)) = 0 Then
        Pis rep, "CHYBA: súbor sa nenašiel."
        Exit Function
    End If
    lN = CitajBajty(strCesta, b)
    If lN < 20 Then
        Pis rep, "CHYBA: súbor je prázdny alebo príliš krátky."
        Exit Function
    End If
    If lN > 3 Then
        If b(0) = &HEF And b(1) = &HBB And b(2) = &HBF Then lStart = 3
    End If
    p = -1
    For i = lN - 5 To lStart Step -1
        If b(i) = 35 And b(i + 1) = 69 And b(i + 2) = 78 And b(i + 3) = 68 And b(i + 4) = 59 Then
            If i = lStart Then
                p = i: Exit For
            ElseIf b(i - 1) = 10 Then
                p = i: Exit For
            End If
        End If
    Next i
    If p < 0 Then
        Pis rep, "CHYBA: chýba pätička #END (súbor je neúplný)."
        Exit Function
    End If
    lHashDlzka = p - lStart
    strCely = StrConv(b, vbUnicode)
    strPatickaText = Trim$(Replace(Replace(Mid$(strCely, p + 1), vbCr, ""), vbLf, ""))
    For Each vP In Split(strPatickaText, ";")
        If LCase$(Left$(CStr(vP), 5)) = "rows=" Then strRowsP = Mid$(CStr(vP), 6)
        If LCase$(Left$(CStr(vP), 7)) = "sha256=" Then strShaP = LCase$(Mid$(CStr(vP), 8))
    Next vP
    lRowsP = CLng(Val(strRowsP))
    strShaVyp = Sha256Hex(b, lStart, lHashDlzka)
    If strShaVyp = strShaP Then
        Pis rep, "SHA-256 pätičky: OK (" & strShaVyp & ")"
    Else
        Pis rep, "SHA-256 pätičky: NESEDÍ  v súbore " & strShaP & "  vypočítané " & strShaVyp
        nTvrde = nTvrde + 1
    End If
    strTelo = Mid$(strCely, lStart + 1, lHashDlzka)
    OverSuborKontraktu = True
End Function

' record_hash z pôvodného riadku razenia uloženého v TerminalInbox.Payload (posledný stĺpec kontraktu v1). Prázdny reťazec = nedá sa zistiť.
Private Function HashZPayloadu(ByVal strPayload As String) As String
    Dim pole() As String, n As Long, s As String, i As Long
    If Len(strPayload) = 0 Then Exit Function
    n = RozdelRiadok(strPayload, pole)
    If n < 1 Then Exit Function
    s = LCase$(Trim$(pole(n - 1)))
    If Len(s) <> 64 Then Exit Function
    For i = 1 To 64
        If InStr("0123456789abcdef", Mid$(s, i, 1)) = 0 Then Exit Function
    Next i
    HashZPayloadu = s
End Function

' Posúdi jedno zneplatnenie (nič nezapisuje). Vráti: APLIKOVAT, UZ (razenie je už neplatné), CAKA, UZAVRETY alebo NEZHODA.
' strInfo = vysvetlenie, strOC a dDen = osobné číslo a deň nájdeného razenia v DochadzkaImport.
Private Function PosudZneplatnenie(ByRef db As DAO.Database, ByVal strExterneID As String, ByVal strOcOcak As String, ByVal strHashOcak As String, _
                                   ByRef strInfo As String, ByRef strOC As String, ByRef dDen As Date) As String
    Dim rs As DAO.Recordset, rsI As DAO.Recordset, strHashInbox As String, bPlatne As Boolean, strDovod As String

    strInfo = "": strOC = ""
    Set rs = db.OpenRecordset("SELECT OsobneCislo, Datum, Platnost, DovodNeplatnosti FROM DochadzkaImport WHERE ExterneID = " & mod_00_Common.SqlText(strExterneID) & ";", dbOpenSnapshot)
    If rs.EOF Then
        rs.Close
        Set rsI = db.OpenRecordset("SELECT Stav FROM TerminalInbox WHERE ExterneID = " & mod_00_Common.SqlText(strExterneID) & ";", dbOpenSnapshot)
        If rsI.EOF Then
            strInfo = "razenie ešte nebolo importované (najprv importujte punches_*.csv)"
        Else
            strInfo = "razenie čaká vo fronte TerminalInbox (stav " & Nz(rsI!Stav, "?") & ")"
        End If
        rsI.Close
        PosudZneplatnenie = "CAKA"
        Exit Function
    End If

    strOC = Trim$(CStr(Nz(rs!OsobneCislo, "")))
    If IsNull(rs!Datum) Then dDen = Date Else dDen = DateValue(CDate(rs!Datum))
    Do While Not rs.EOF
        If CBool(Nz(rs!Platnost, True)) Then bPlatne = True Else strDovod = CStr(Nz(rs!DovodNeplatnosti, ""))
        rs.MoveNext
    Loop
    rs.Close

    ' kontrola, že ide o to isté razenie: hash z pôvodného riadku a osobné číslo
    Set rsI = db.OpenRecordset("SELECT Payload FROM TerminalInbox WHERE ExterneID = " & mod_00_Common.SqlText(strExterneID) & ";", dbOpenSnapshot)
    If Not rsI.EOF Then strHashInbox = HashZPayloadu(CStr(Nz(rsI!Payload, "")))
    rsI.Close
    If Len(strHashInbox) > 0 And Len(strHashOcak) > 0 Then
        If LCase$(strHashInbox) <> LCase$(strHashOcak) Then
            strInfo = "record_hash zneplatnenia sa líši od importovaného razenia"
            PosudZneplatnenie = "NEZHODA"
            Exit Function
        End If
    End If
    If Len(strOcOcak) > 0 And strOC <> strOcOcak Then
        strInfo = "osobné číslo v zozname (" & strOcOcak & ") sa líši od razenia v dochádzke (" & strOC & ")"
        PosudZneplatnenie = "NEZHODA"
        Exit Function
    End If

    If mod_18_Uzavierka.JeUzavretyDen(strOC, dDen) Then
        strInfo = "mesiac " & Month(dDen) & "/" & Year(dDen) & " je uzavretý"
        PosudZneplatnenie = "UZAVRETY"
        Exit Function
    End If
    If Not bPlatne Then
        strInfo = "razenie je už neplatné" & IIf(Len(strDovod) > 0, " (dôvod " & strDovod & ")", "")
        PosudZneplatnenie = "UZ"
        Exit Function
    End If
    If Len(strHashInbox) = 0 Then strInfo = "hash razenia sa nedal overiť (chýba pôvodný riadok v TerminalInbox)"
    PosudZneplatnenie = "APLIKOVAT"
End Function

'-------------------------------------------------------------------------------
' Použije čakajúce zneplatnenia (CAKA, UZAVRETY) na razenia v DochadzkaImport. Vráti textový report ("" ak nie je čo spracovať).
' bPrepocitat = prepočíta aj dotknuté mesiace zamestnancov (inak ich treba prepočítať v kartách výpočtu).
'-------------------------------------------------------------------------------
Public Function SpracujZneplatnenia(Optional ByVal bPrepocitat As Boolean = False) As String
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset, st As String, strInfo As String, strOC As String, dDen As Date
    Dim nOK As Long, nUz As Long, nCaka As Long, nUzav As Long, nZle As Long, nVsetko As Long, dicMes As Object, k As Variant, part As Variant
    Dim rep As String

    Set db = CurrentDb
    If Not mod_00_Common.TabulkaExistujeDB(db, "TerminalZneplatnenia") Then Exit Function
    If DCount("*", "TerminalZneplatnenia", "Stav IN ('CAKA','UZAVRETY')") = 0 Then Exit Function
    Call mod_01_SystemInit.MigrujDatovyModel(db)
    Set dicMes = CreateObject("Scripting.Dictionary")

    Set rs = db.OpenRecordset("SELECT * FROM TerminalZneplatnenia WHERE Stav IN ('CAKA','UZAVRETY') ORDER BY ID;", dbOpenDynaset)
    Do While Not rs.EOF
        nVsetko = nVsetko + 1
        st = PosudZneplatnenie(db, CStr(rs!ExterneID), CStr(Nz(rs!OsobneCislo, "")), CStr(Nz(rs!RecordHash, "")), strInfo, strOC, dDen)
        Select Case st
            Case "APLIKOVAT"
                db.Execute "UPDATE DochadzkaImport SET Platnost = False, DovodNeplatnosti = 'ZNEPLATNENE_V_TERMINALI', UzivatelZmeny = 'TERMINAL', DatumZmeny = Now() " & _
                           "WHERE ExterneID = " & mod_00_Common.SqlText(CStr(rs!ExterneID)) & " AND (Platnost = True OR Platnost IS NULL)", dbFailOnError
                rs.Edit
                rs!Stav = "APLIKOVANE": rs!Chyba = IIf(Len(strInfo) > 0, Left$(strInfo, 255), Null): rs!DatumSpracovania = Now
                rs.Update
                dicMes(strOC & "|" & Year(dDen) & "|" & Month(dDen)) = 1
                nOK = nOK + 1
            Case "UZ"
                rs.Edit
                rs!Stav = "APLIKOVANE": rs!Chyba = Left$(strInfo, 255): rs!DatumSpracovania = Now
                rs.Update
                nUz = nUz + 1
            Case "NEZHODA"
                rs.Edit
                rs!Stav = "NEZHODA": rs!Chyba = Left$(strInfo, 255): rs!DatumSpracovania = Now
                rs.Update
                nZle = nZle + 1
                If nZle <= 20 Then Pis rep, "  NEZHODA punch_id " & Nz(rs!PunchID, 0) & ": " & strInfo
            Case "UZAVRETY"
                rs.Edit
                rs!Stav = "UZAVRETY": rs!Chyba = Left$(strInfo, 255): rs!DatumSpracovania = Now
                rs.Update
                nUzav = nUzav + 1
            Case Else
                rs.Edit
                rs!Stav = "CAKA": rs!Chyba = Left$(strInfo, 255): rs!DatumSpracovania = Now
                rs.Update
                nCaka = nCaka + 1
        End Select
        rs.MoveNext
    Loop
    rs.Close

    If bPrepocitat Then
        For Each k In dicMes.Keys
            part = Split(CStr(k), "|")
            Call modMesaatnaDochadzka.PrepocitajMesiac(db, CStr(part(0)), CInt(part(1)), CInt(part(2)), False)
        Next k
    End If
    SpracujZneplatnenia = "Zneplatnené razenia: použité " & nOK & ", už boli neplatné " & nUz & ", čakajú na razenie " & nCaka & ", uzavretý mesiac " & nUzav & ", nezhoda " & nZle & _
                          IIf(nOK > 0, IIf(bPrepocitat, "; dotknuté mesiace sú prepočítané.", "; prepočítajte dotknuté mesiace (karty výpočtu)."), "") & vbCrLf & rep
    Call mod_00_Common.ZapisLog("mod_19_TerminalImport.SpracujZneplatnenia", "INFO", "použité " & nOK & ", už neplatné " & nUz & ", čaká " & nCaka & ", uzavretý " & nUzav & ", nezhoda " & nZle)
    Exit Function
Chyba:
    SpracujZneplatnenia = "CHYBA spracovania zneplatnení: " & Err.Number & " " & Err.Description
    Call mod_00_Common.ZapisLog("mod_19_TerminalImport.SpracujZneplatnenia", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Import súboru voids_RRRRMM.csv (kontrakt v1.1). Najprv sa overí súbor (pätička, SHA-256, hlavička, verzia, jedna organizácia),
' potom sa zneplatnenia uložia a použijú. bNanecisto = iba ukáže, čo by sa stalo.
'-------------------------------------------------------------------------------
Public Function ImportujZneplatnenia(ByVal strCesta As String, Optional ByVal bNanecisto As Boolean = False, Optional ByVal bPrepocitat As Boolean = False) As String
    On Error GoTo Chyba
    Dim rep As String, strTelo As String, lRowsP As Long, nTvrde As Long
    Dim riadky() As String, pole() As String, nPol As Long, hlav() As String, nH As Long, hdr As Object
    Dim i As Long, n As Long, nRiadkov As Long, c As Variant, db As DAO.Database, oscDic As Object, rs As DAO.Recordset
    Dim aExt() As String, aOsc() As String, aHash() As String, aPunch() As Long, aUtc() As String
    Dim strOrg As String, strOrgRiadok As String, strOrgUlozena As String
    Dim nNovych As Long, nStarych As Long, nObnovenych As Long, st As String, strInfo As String, strOC As String, dDen As Date, strZn As String

    Pis rep, "Import zneplatnených razení z terminála: " & strCesta & IIf(bNanecisto, "   [NANEČISTO - nič sa nezapíše]", "")
    If Not OverSuborKontraktu(strCesta, rep, strTelo, lRowsP, nTvrde) Then
        ImportujZneplatnenia = rep: Exit Function
    End If

    riadky = Split(strTelo, vbCrLf)
    nH = RozdelRiadok(riadky(0), hlav)
    Set hdr = CreateObject("Scripting.Dictionary")
    For i = 0 To nH - 1
        hdr(Trim$(hlav(i))) = i
    Next i
    For Each c In Array("contract_version", "organization_id", "punch_id", "external_id", "personnel_number", "voided_at_utc", "record_hash")
        If Not hdr.Exists(CStr(c)) Then
            Pis rep, "CHYBA: v hlavičke chýba stĺpec " & CStr(c)
            ImportujZneplatnenia = rep: Exit Function
        End If
    Next c

    ReDim aExt(0 To UBound(riadky)): ReDim aOsc(0 To UBound(riadky)): ReDim aHash(0 To UBound(riadky))
    ReDim aPunch(0 To UBound(riadky)): ReDim aUtc(0 To UBound(riadky))
    For i = 1 To UBound(riadky)
        If Len(Trim$(riadky(i))) > 0 Then
            nRiadkov = nRiadkov + 1
            nPol = RozdelRiadok(riadky(i), pole)
            If nPol < nH Then
                Pis rep, "  Riadok " & (i + 1) & ": menej polí než hlavička"
                nTvrde = nTvrde + 1
            ElseIf CStr(pole(hdr("contract_version"))) <> "1" Then
                Pis rep, "  Riadok " & (i + 1) & ": nepodporovaná verzia kontraktu " & pole(hdr("contract_version"))
                nTvrde = nTvrde + 1
            Else
                aExt(n) = Trim$(pole(hdr("external_id")))
                aOsc(n) = Trim$(pole(hdr("personnel_number")))
                aHash(n) = LCase$(Trim$(pole(hdr("record_hash"))))
                aPunch(n) = CLng(Val(pole(hdr("punch_id"))))
                aUtc(n) = Left$(Trim$(pole(hdr("voided_at_utc"))), 20)
                strOrgRiadok = Trim$(pole(hdr("organization_id")))
                If Len(aExt(n)) = 0 Or Len(aOsc(n)) = 0 Then
                    Pis rep, "  Riadok " & (i + 1) & ": chýba osobné číslo alebo external_id"
                    nTvrde = nTvrde + 1
                End If
                If Len(strOrg) = 0 Then
                    strOrg = strOrgRiadok
                ElseIf strOrgRiadok <> strOrg Then
                    Pis rep, "  Riadok " & (i + 1) & ": iná organizácia než predchádzajúce riadky"
                    nTvrde = nTvrde + 1
                End If
                n = n + 1
            End If
        End If
    Next i
    Pis rep, "Riadkov v súbore: " & nRiadkov & "  (pätička uvádza " & lRowsP & ")" & IIf(nRiadkov = lRowsP, "  OK", "  NESEDÍ")
    If nRiadkov <> lRowsP Then nTvrde = nTvrde + 1
    If nTvrde > 0 Then
        Pis rep, "IMPORT ZASTAVENÝ: súbor nespĺňa kontrakt (pozri vyššie). Nič sa nezapísalo."
        ImportujZneplatnenia = rep: Exit Function
    End If
    If n = 0 Then
        Pis rep, "Súbor neobsahuje žiadne zneplatnenia."
        ImportujZneplatnenia = rep: Exit Function
    End If

    Set db = CurrentDb
    Call ZabezpecTabulky(db)
    strOrgUlozena = mod_00_Common.GetNastavenie("TerminalOrganizationId", "")
    If Len(strOrgUlozena) > 0 And Len(strOrg) > 0 And strOrg <> strOrgUlozena Then
        Pis rep, "IMPORT ZASTAVENÝ: súbor je z inej organizácie terminála (" & strOrg & ") než importované razenia (" & strOrgUlozena & ")."
        ImportujZneplatnenia = rep: Exit Function
    End If
    Set oscDic = CreateObject("Scripting.Dictionary")

    If bNanecisto Then
        Pis rep, "Prehľad (čo by sa stalo):"
        For i = 0 To n - 1
            st = PosudZneplatnenie(db, aExt(i), NajdiOsobneCislo(aOsc(i), oscDic), aHash(i), strInfo, strOC, dDen)
            If i < 120 Then Pis rep, "  " & aOsc(i) & " punch_id " & aPunch(i) & " (" & Left$(aExt(i), 8) & ")  ->  " & st & IIf(Len(strInfo) > 0, "  " & strInfo, "") & IIf(Len(strOC) > 0, "  [" & Format$(dDen, "yyyy\-mm\-dd") & "]", "")
        Next i
        Pis rep, "Nanečisto: do databázy sa nič nezapísalo."
        ImportujZneplatnenia = rep: Exit Function
    End If

    ' uloženie (idempotentne podľa ExterneID)
    Set rs = db.OpenRecordset("TerminalZneplatnenia", dbOpenDynaset)
    For i = 0 To n - 1
        If DCount("*", "TerminalZneplatnenia", "ExterneID = " & mod_00_Common.SqlText(aExt(i))) > 0 Then
            If DCount("*", "TerminalZneplatnenia", "ExterneID = " & mod_00_Common.SqlText(aExt(i)) & " AND Stav = 'NEZHODA'") > 0 Then
                ' predtým nesedel hash alebo osobné číslo: nový súbor môže mať správne údaje, skúsi sa znova
                db.Execute "UPDATE TerminalZneplatnenia SET PunchID = " & aPunch(i) & ", OsobneCislo = " & mod_00_Common.SqlText(Left$(NajdiOsobneCislo(aOsc(i), oscDic), 20)) & _
                           ", RecordHash = " & mod_00_Common.SqlText(Left$(aHash(i), 64)) & ", ZneplatneneUtc = " & mod_00_Common.SqlText(aUtc(i)) & _
                           ", Stav = 'CAKA', Chyba = Null WHERE ExterneID = " & mod_00_Common.SqlText(aExt(i)) & " AND Stav = 'NEZHODA'", dbFailOnError
                nObnovenych = nObnovenych + 1
            Else
                nStarych = nStarych + 1
            End If
        Else
            rs.AddNew
            rs!PrijateKedy = Now
            rs!ExterneID = Left$(aExt(i), 50)
            rs!PunchID = aPunch(i)
            rs!OsobneCislo = Left$(NajdiOsobneCislo(aOsc(i), oscDic), 20)
            rs!RecordHash = Left$(aHash(i), 64)
            rs!ZneplatneneUtc = aUtc(i)
            rs!Stav = "CAKA"
            rs.Update
            nNovych = nNovych + 1
        End If
    Next i
    rs.Close
    Pis rep, "Do zoznamu zneplatnení: nových " & nNovych & ", už existujúcich (external_id) " & nStarych & IIf(nObnovenych > 0, ", znova skúšaných po nezhode " & nObnovenych, "")
    strZn = SpracujZneplatnenia(bPrepocitat)
    If Len(strZn) > 0 Then Pis rep, strZn
    ImportujZneplatnenia = rep
    Exit Function
Chyba:
    ImportujZneplatnenia = rep & "CHYBA importu zneplatnení: " & Err.Number & " " & Err.Description
    Call mod_00_Common.ZapisLog("mod_19_TerminalImport.ImportujZneplatnenia", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Samočinný test zneplatnení nad testovacími údajmi 90000xx (po teste razení): dry-run, ostrý import, prepočet a uloženie výsledkov.
' Výsledky pred zneplatnením sa uložia do terminal_test_access_vysledky_pred_zneplatnenim.csv, výsledky po zneplatnení do
' terminal_test_access_vysledky.csv (na porovnanie s terminálom po zneplatnení tých istých razení).
'-------------------------------------------------------------------------------
Public Function SamoTestZneplatneni(Optional ByVal strCSV As String = "") As String
    On Error GoTo Chyba
    Dim rep As String, db As DAO.Database, rs As DAO.Recordset, strZoznam As String, dMin As Date, dMax As Date
    Dim strRes As String, strPred As String, odp As VbMsgBoxResult, strCestaRep As String

    Set db = CurrentDb
    Pis rep, "SAMOČINNÝ TEST ZNEPLATNENÍ  (mod_19_TerminalImport 1.2.0)"
    Pis rep, "Databáza: " & CurrentProject.FullName
    Pis rep, "Čas testu: " & Format$(Now, "yyyy\-mm\-dd hh:nn:ss")
    Pis rep, ""
    If Len(strCSV) = 0 Then strCSV = CurrentProject.Path & "\voids_test_2026-10.csv"
    If Len(Dir(strCSV)) = 0 Then
        With Application.FileDialog(3)
            .Title = "Vyberte súbor so zneplatnenými razeniami (voids_*.csv)"
            .AllowMultiSelect = False
            .Filters.Clear
            .Filters.Add "CSV", "*.csv"
            If .Show = -1 Then strCSV = .SelectedItems(1) Else strCSV = ""
        End With
    End If
    If Len(strCSV) = 0 Then
        Pis rep, "Súbor nevybraný - test sa končí."
    ElseIf DCount("*", "DochadzkaImport", "OsobneCislo LIKE '90000??'") = 0 Then
        Pis rep, "V databáze nie sú testovacie razenia 90000xx. Najprv spustite samočinný test terminála s razeniami (punches / terminal_test_2026-10.csv)."
    Else
        Pis rep, "1. Nanečisto"
        Pis rep, ImportujZneplatnenia(strCSV, True, False)
        odp = MsgBox("Nanečisto je hotové. Spustiť OSTRÝ import zneplatnení nad testovacími údajmi (osobné čísla 90000xx), prepočítať mesiac a uložiť výsledky?" & vbCrLf & vbCrLf & _
                     "Výsledky pred zneplatnením sa zachovajú v terminal_test_access_vysledky_pred_zneplatnenim.csv.", vbQuestion + vbYesNo, "Samočinný test zneplatnení")
        If odp = vbYes Then
            Set rs = db.OpenRecordset("SELECT OsobneCislo, Min(CasRazenia) AS MinCas, Max(CasRazenia) AS MaxCas FROM TerminalInbox WHERE OsobneCislo LIKE '90000??' GROUP BY OsobneCislo;", dbOpenSnapshot)
            dMin = DateSerial(2100, 1, 1): dMax = DateSerial(1990, 1, 1)
            Do While Not rs.EOF
                strZoznam = strZoznam & CStr(rs!OsobneCislo) & vbCrLf
                If Not IsNull(rs!MinCas) Then If DateValue(CDate(rs!MinCas)) < dMin Then dMin = DateValue(CDate(rs!MinCas))
                If Not IsNull(rs!MaxCas) Then If DateValue(CDate(rs!MaxCas)) > dMax Then dMax = DateValue(CDate(rs!MaxCas))
                rs.MoveNext
            Loop
            rs.Close
            If Len(strZoznam) = 0 Then
                Pis rep, "Vo fronte terminála nie sú testovacie razenia 90000xx - test sa končí."
                GoTo Koniec
            End If
            strRes = CurrentProject.Path & "\terminal_test_access_vysledky.csv"
            strPred = CurrentProject.Path & "\terminal_test_access_vysledky_pred_zneplatnenim.csv"
            ' stav PRED zneplatnením sa prepočíta znova, aby bol určite zhodný s tým, čo sa potom zneplatňuje
            Call PrepocitajAExportuj(rep, db, strZoznam, dMin, dMax)
            If Len(Dir(strPred)) > 0 Then Kill strPred
            FileCopy strRes, strPred
            Pis rep, "Výsledky pred zneplatnením uložené: " & strPred
            Pis rep, ""
            Pis rep, "2. Ostrý import a prepočet"
            Pis rep, ImportujZneplatnenia(strCSV, False, False)
            Call PrepocitajAExportuj(rep, db, strZoznam, dMin, dMax)
            Pis rep, "Porovnanie: terminal_test_access_vysledky_pred_zneplatnenim.csv (pred) a terminal_test_access_vysledky.csv (po zneplatnení)."
        Else
            Pis rep, "Ostrý import preskočený."
        End If
    End If
Koniec:
    strCestaRep = CurrentProject.Path & "\terminal_test_zneplatnenia_report.txt"
    Call mod_00_Common.UlozUTF8Sustor(strCestaRep, rep)
    SamoTestZneplatneni = rep & vbCrLf & "Report uložený: " & strCestaRep
    Exit Function
Chyba:
    rep = rep & "CHYBA testu zneplatnení: " & Err.Number & " " & Err.Description
    On Error Resume Next
    Call mod_00_Common.UlozUTF8Sustor(CurrentProject.Path & "\terminal_test_zneplatnenia_report.txt", rep)
    SamoTestZneplatneni = rep
End Function

'===============================================================================
' Samočinný test + export výsledkov na porovnanie
'===============================================================================
Private Function VektorSha(ByRef rep As String, ByVal strVstup As String, ByVal strOcak As String) As Boolean
    Dim strV As String
    strV = Sha256Text(strVstup)
    If strV = strOcak Then
        Pis rep, "  SHA-256 vektor OK: '" & Left$(strVstup, 20) & IIf(Len(strVstup) > 20, "...", "") & "'"
        VektorSha = True
    Else
        Pis rep, "  SHA-256 vektor CHYBA: '" & Left$(strVstup, 20) & "'  očakávané " & strOcak & "  vypočítané " & strV
    End If
End Function

Private Function ZoznamOsobnychCiselCSV(ByVal strCesta As String, ByRef dMin As Date, ByRef dMax As Date) As String
    ' osobné čísla a rozsah dní zo súboru (stĺpce podľa hlavičky); používa sa na vytvorenie testovacích zamestnancov
    Dim b() As Byte, lN As Long, s As String, riadky() As String, pole() As String, hl() As String, i As Long, nP As Long
    Dim ic As Long, il As Long, j As Long, nH As Long, dic As Object, d As Date, res As String, lStart As Long
    lN = CitajBajty(strCesta, b)
    If lN < 20 Then Exit Function
    If b(0) = &HEF And b(1) = &HBB And b(2) = &HBF Then lStart = 3
    s = Mid$(StrConv(b, vbUnicode), lStart + 1)
    riadky = Split(s, vbCrLf)
    nH = RozdelRiadok(riadky(0), hl)
    ic = -1: il = -1
    For j = 0 To nH - 1
        If Trim$(hl(j)) = "personnel_number" Then ic = j
        If Trim$(hl(j)) = "client_time_local" Then il = j
    Next j
    If ic < 0 Or il < 0 Then Exit Function
    Set dic = CreateObject("Scripting.Dictionary")
    dMin = DateSerial(2100, 1, 1): dMax = DateSerial(1990, 1, 1)
    For i = 1 To UBound(riadky)
        If Left$(riadky(i), 1) <> "#" And Len(Trim$(riadky(i))) > 0 Then
            nP = RozdelRiadok(riadky(i), pole)
            If nP > ic And nP > il Then
                If Not dic.Exists(Trim$(pole(ic))) Then
                    dic(Trim$(pole(ic))) = 1
                    res = res & Trim$(pole(ic)) & vbCrLf
                End If
                If ParsujLokalny(Trim$(pole(il)), d) Then
                    If DateValue(d) < dMin Then dMin = DateValue(d)
                    If DateValue(d) > dMax Then dMax = DateValue(d)
                End If
            End If
        End If
    Next i
    ZoznamOsobnychCiselCSV = res
End Function

Public Function SamoTestTerminalu(Optional ByVal strCSV As String = "") As String
    On Error GoTo Chyba
    Dim rep As String, db As DAO.Database, okVsetko As Boolean, mapa As Object
    Dim v As Variant, dMin As Date, dMax As Date, strZoznam As String, sz As String
    Dim kodDic As Object, strCestaRep As String, odp As VbMsgBoxResult
    Dim lZ As Long, lKK As Long

    Set db = CurrentDb
    okVsetko = True
    Pis rep, "SAMOČINNÝ TEST TERMINÁLU  (mod_19_TerminalImport 1.1.0)"
    Pis rep, "Databáza: " & CurrentProject.FullName
    Pis rep, "Čas testu: " & Format$(Now, "yyyy\-mm\-dd hh:nn:ss")
    Pis rep, ""
    Pis rep, "1. SHA-256 na známych vektoroch"
    If Not VektorSha(rep, "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") Then okVsetko = False
    If Not VektorSha(rep, "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") Then okVsetko = False
    If Not VektorSha(rep, "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1") Then okVsetko = False
    If Not VektorSha(rep, String$(200, "a"), "c2a908d98f5df987ade41b5fce213067efbcc21ef2240212a41e54b5e7c28ae5") Then okVsetko = False

    Pis rep, ""
    Pis rep, "2. Mapovanie kódov terminála na prerušenia Accessu"
    Call ZabezpecTabulky(db)
    Set mapa = NacitajMapuKodov(db)
    Set kodDic = CreateObject("Scripting.Dictionary")
    For Each v In Array("WORK", "DOCTOR", "TRIP", "FAMILY", "LEAVE", "SICK", "PRIV")
        If Not mapa.Exists(CStr(v)) Then
            Pis rep, "  " & CStr(v) & ": CHÝBA v TerminalMapaKodov"
            okVsetko = False
        Else
            lZ = KodRazeniaPre(CLng(mapa(CStr(v))), "Z", kodDic)
            lKK = KodRazeniaPre(CLng(mapa(CStr(v))), "K", kodDic)
            Pis rep, "  " & CStr(v) & " -> prerušenie č. " & mapa(CStr(v)) & "  kód Z " & lZ & "  kód K " & lKK & IIf(lZ = 0 Or lKK = 0, "   CHYBA: v KodyRazeni chýba kód", "")
            If lZ = 0 Or lKK = 0 Then okVsetko = False
        End If
    Next v
    Pis rep, "  WORK/OUT medzi príchodmi = " & mod_00_Common.GetNastavenie("TerminalOdchodBezDovodu", "OBED") & ", číslo obeda " & mod_00_Common.GetNastavenie("TerminalObedCislo", "7")
    If DCount("*", "KodyRazeni") = 0 Then
        Pis rep, "  CHYBA: číselník kódov razenia (KodyRazeni) je prázdny - najprv spustite predvolenú konfiguráciu prerušení (karta Prerušenia)."
        okVsetko = False
    Else
        Pis rep, "  Kódov razenia v číselníku: " & DCount("*", "KodyRazeni")
    End If

    Pis rep, ""
    Pis rep, "3. Testovací súbor z terminála"
    If Len(strCSV) = 0 Then strCSV = CurrentProject.Path & "\terminal_test_scenare.csv"
    If Len(Dir(strCSV)) = 0 Then
        With Application.FileDialog(3)
            .Title = "Vyberte testovací súbor z terminála (terminal_test_scenare.csv)"
            .AllowMultiSelect = False
            .Filters.Clear
            .Filters.Add "CSV", "*.csv"
            If .Show = -1 Then strCSV = .SelectedItems(1) Else strCSV = ""
        End With
    End If
    If Len(strCSV) = 0 Then
        Pis rep, "  Testovací súbor nevybraný - test sa končí po bode 2."
    Else
        Pis rep, ImportujSubor(strCSV, True, True)
        strZoznam = ZoznamOsobnychCiselCSV(strCSV, dMin, dMax)
        Pis rep, ""
        Pis rep, "4. Ostrý import a výpočet (len testovacie osobné čísla 90000xx)"
        If InStr(strZoznam, "90000") = 0 Then
            Pis rep, "  Súbor neobsahuje testovacie osobné čísla 90000xx - ostrý import sa nerobí."
        Else
            odp = MsgBox("Dry-run je hotový. Spustiť OSTRÝ import testovacích razení (osobné čísla 90000xx), prepočítať mesiac a uložiť výsledky?" & vbCrLf & vbCrLf & _
                         "Odporúčame testovaciu KÓPIU databázy. Údaje sa dajú odstrániť funkciou OdstranTestoveData.", vbQuestion + vbYesNo, "Samočinný test terminála")
            If odp = vbYes Then
                If TestoveDataExistuju(db) Then
                    If MsgBox("V databáze sú už testovacie údaje 90000xx z predošlého testu. Odstrániť ich pred novým importom?" & vbCrLf & vbCrLf & _
                              "Odporúčame Áno: inak by sa razenia z iného súboru (iné ID razení) pridali k starým a saldá by sa zdvojili.", _
                              vbQuestion + vbYesNo, "Samočinný test terminála") = vbYes Then
                        Pis rep, "  Odstránenie starých testovacích údajov:" & vbCrLf & Replace(OdstranBezOtazky(db), vbCrLf, " | ")
                    Else
                        Pis rep, "  Staré testovacie údaje ostali - výsledky môžu byť zdvojené."
                    End If
                End If
                ' testovací zamestnanci
                For Each v In Split(strZoznam, vbCrLf)
                    If Len(CStr(v)) > 0 Then
                        If Left$(CStr(v), 5) = "90000" Then sz = sz & CStr(v) & vbCrLf
                    End If
                Next v
                Pis rep, "  Zamestnanci: " & Replace(mod_11_ImportZamestnancov.ImportZamestnancovZTextu(sz, True, "TEST"), vbCrLf, " | ")
                Pis rep, ImportujSubor(strCSV, False, True)
                Call PrepocitajAExportuj(rep, db, strZoznam, dMin, dMax)
            Else
                Pis rep, "  Ostrý import preskočený."
            End If
        End If
    End If

    Pis rep, ""
    Pis rep, "VÝSLEDOK: " & IIf(okVsetko, "kontroly 1 a 2 prešli", "ASPOŇ JEDNA KONTROLA ZLYHALA - pozri vyššie")
    strCestaRep = CurrentProject.Path & "\terminal_test_report.txt"
    Call mod_00_Common.UlozUTF8Sustor(strCestaRep, rep)
    SamoTestTerminalu = rep & vbCrLf & "Report uložený: " & strCestaRep
    Exit Function
Chyba:
    rep = rep & "CHYBA testu: " & Err.Number & " " & Err.Description
    On Error Resume Next
    Call mod_00_Common.UlozUTF8Sustor(CurrentProject.Path & "\terminal_test_report.txt", rep)
    SamoTestTerminalu = rep
End Function

' Prepočíta mesiace zamestnancov zo zoznamu a uloží denné výsledky do terminal_test_access_vysledky.csv
Private Sub PrepocitajAExportuj(ByRef rep As String, ByRef db As DAO.Database, ByVal strZoznam As String, ByVal dMin As Date, ByVal dMax As Date)
    Dim v As Variant, strOc As String, y As Long, m As Long, ym As Long, ymOd As Long, ymDo As Long
    Dim rs As DAO.Recordset, out As String, dicAn As Object, dicIv As Object, k As String
    Dim dOd As Date, dDo As Date, nR As Long, oscDic As Object

    Set oscDic = CreateObject("Scripting.Dictionary")
    out = "osobne_cislo;datum;typ_dna;fond_min;odpracovane_min;saldo_min;intervaly;anomalie" & vbCrLf
    ymOd = Year(dMin) * 12 + Month(dMin) - 1
    ymDo = Year(dMax) * 12 + Month(dMax) - 1
    For Each v In Split(strZoznam, vbCrLf)
        If Len(CStr(v)) > 0 Then
            strOc = NajdiOsobneCislo(CStr(v), oscDic)
            For ym = ymOd To ymDo
                y = ym \ 12: m = (ym Mod 12) + 1
                Call modMesaatnaDochadzka.PrepocitajMesiac(db, strOc, CInt(y), CInt(m), False)
                dOd = DateSerial(y, m, 1): dDo = DateSerial(y, m + 1, 1)
                Set dicAn = CreateObject("Scripting.Dictionary")
                Set dicIv = CreateObject("Scripting.Dictionary")
                If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaAnomalie") Then
                    Set rs = db.OpenRecordset("SELECT Datum, TypAnomalie FROM DochadzkaAnomalie WHERE OsobneCislo = " & mod_00_Common.SqlText(strOc) & _
                                              " AND Rok = " & y & " AND Mesiac = " & m & " ORDER BY Datum;", dbOpenSnapshot)
                    Do While Not rs.EOF
                        k = Format$(DateValue(CDate(rs!Datum)), "yyyy\-mm\-dd")
                        dicAn(k) = dicAn(k) & IIf(Len(dicAn(k)) > 0, ",", "") & Nz(rs!TypAnomalie, "")
                        rs.MoveNext
                    Loop
                    rs.Close
                End If
                Set rs = db.OpenRecordset("SELECT Datum, CisloPreruseni, TrvanieMin FROM DochadzkaIntervaly WHERE OsobneCislo = " & mod_00_Common.SqlText(strOc) & _
                                          " AND Datum >= " & mod_00_Common.SqlDatum(dOd) & " AND Datum < " & mod_00_Common.SqlDatum(dDo) & " ORDER BY Datum, Poradie;", dbOpenSnapshot)
                Do While Not rs.EOF
                    k = Format$(DateValue(CDate(rs!Datum)), "yyyy\-mm\-dd")
                    dicIv(k) = dicIv(k) & IIf(Len(dicIv(k)) > 0, ",", "") & Nz(rs!CisloPreruseni, 0) & ":" & Nz(rs!TrvanieMin, 0)
                    rs.MoveNext
                Loop
                rs.Close
                Set rs = db.OpenRecordset("SELECT Datum, TypDna, DennyFondMin, OdpracovaneMin, SaldoMin FROM DochadzkaDni WHERE OsobneCislo = " & mod_00_Common.SqlText(strOc) & _
                                          " AND Datum >= " & mod_00_Common.SqlDatum(dOd) & " AND Datum < " & mod_00_Common.SqlDatum(dDo) & " ORDER BY Datum;", dbOpenSnapshot)
                Do While Not rs.EOF
                    k = Format$(DateValue(CDate(rs!Datum)), "yyyy\-mm\-dd")
                    out = out & strOc & ";" & k & ";" & Nz(rs!TypDna, "") & ";" & Nz(rs!DennyFondMin, 0) & ";" & Nz(rs!OdpracovaneMin, 0) & ";" & Nz(rs!SaldoMin, 0) & ";" & _
                          IIf(dicIv.Exists(k), dicIv(k), "") & ";" & IIf(dicAn.Exists(k), dicAn(k), "") & vbCrLf
                    nR = nR + 1
                    rs.MoveNext
                Loop
                rs.Close
            Next ym
        End If
    Next v
    Call mod_00_Common.UlozUTF8Sustor(CurrentProject.Path & "\terminal_test_access_vysledky.csv", out)
    Pis rep, "  Výsledky dní (" & nR & " riadkov) uložené: " & CurrentProject.Path & "\terminal_test_access_vysledky.csv"
End Sub

' Zmaže údaje testovacích zamestnancov 9000001 až 9000099 (iba tento rozsah!). Vráti textový report.
Public Function OdstranTestoveData() As String
    On Error GoTo Chyba
    If MsgBox("Zmazať všetky údaje testovacích zamestnancov 9000001 až 9000099 (razenia, výpočty, zamestnanci, fronta terminála)?" & vbCrLf & _
              "Ďalší zamestnanci sa nedotknú.", vbQuestion + vbYesNo, "Odstrániť testovacie údaje") <> vbYes Then
        OdstranTestoveData = "Zrušené."
        Exit Function
    End If
    OdstranTestoveData = "Odstránené riadky:" & vbCrLf & OdstranBezOtazky(CurrentDb)
    Exit Function
Chyba:
    OdstranTestoveData = "CHYBA: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_19_TerminalImport.OdstranTestoveData", "ERROR", Err.Description)
End Function

' True, ak sú v databáze údaje testovacích zamestnancov 90000xx.
Private Function TestoveDataExistuju(ByRef db As DAO.Database) As Boolean
    Dim v As Variant
    On Error Resume Next
    For Each v In Array("TerminalInbox", "DochadzkaImport", "Zamestnanci")
        If mod_00_Common.TabulkaExistujeDB(db, CStr(v)) Then
            If mod_00_Common.PoleExistujeDB(db, CStr(v), "OsobneCislo") Then
                If DCount("*", CStr(v), "OsobneCislo LIKE '90000??'") > 0 Then
                    TestoveDataExistuju = True
                    Exit Function
                End If
            End If
        End If
        Err.Clear
    Next v
End Function

' Zmaže údaje testovacích zamestnancov 90000xx bez otázky. Ak po zmazaní nezostanú vo fronte terminála žiadne razenia,
' vynuluje sa aj zapamätaná organizácia a posledné punch_id, aby sa dal import z inej organizácie spustiť znova.
Private Function OdstranBezOtazky(ByRef db As DAO.Database) As String
    Dim v As Variant, rep As String, n As Long, bZostali As Boolean
    On Error GoTo Chyba
    For Each v In Array("DochadzkaImport", "DochadzkaDni", "DochadzkaIntervaly", "DochadzkaMesiacSumar", "DochadzkaAnomalie", "DochadzkaAutoOpravy", "TerminalInbox", "TerminalZneplatnenia", "ZamestnanciFondy", "Zamestnanci")
        If mod_00_Common.TabulkaExistujeDB(db, CStr(v)) Then
            If mod_00_Common.PoleExistujeDB(db, CStr(v), "OsobneCislo") Then
                db.Execute "DELETE FROM " & CStr(v) & " WHERE OsobneCislo LIKE '90000??'", dbFailOnError
                n = db.RecordsAffected
                rep = rep & CStr(v) & ": " & n & vbCrLf
            End If
        End If
    Next v
    If mod_00_Common.TabulkaExistujeDB(db, "TerminalInbox") Then bZostali = (DCount("*", "TerminalInbox") > 0)
    If Not bZostali Then
        db.Execute "DELETE FROM NastaveniaSystemu WHERE Kluc IN ('TerminalOrganizationId', 'TerminalPoslednePunchId')", dbFailOnError
        rep = rep & "Zapamätaná organizácia a posledné punch_id terminála vynulované (fronta je prázdna)." & vbCrLf
    End If
    Call mod_00_Common.ZapisLog("mod_19_TerminalImport.OdstranTestoveData", "INFO", "Testovacie údaje 90000xx odstránené.")
    OdstranBezOtazky = rep
    Exit Function
Chyba:
    OdstranBezOtazky = rep & "CHYBA: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_19_TerminalImport.OdstranTestoveData", "ERROR", Err.Description)
End Function
