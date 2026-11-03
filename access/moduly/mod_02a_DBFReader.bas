Attribute VB_Name = "mod_02a_DBFReader"
'@Verzia 2.5.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_02a_DBFReader
' POPIS: Univerzálny binárny čítač DBF súborov (dBase III/IV aj dBase 7 / Visual dBase).
'        Nepoužíva DAO/ISAM ovládače, takže zvláda aj súbory s poľami typu "O" (double),
'        preskakuje zmazané záznamy (*) a dekóduje texty podľa kódovej stránky (default 1250).
'===============================================================================

#If VBA7 Then
    Private Declare PtrSafe Sub dbfMoveMem Lib "kernel32" Alias "RtlMoveMemory" ( _
        ByRef Dest As Any, ByRef Src As Any, ByVal cb As LongPtr)
    Private Declare PtrSafe Function dbfMB2WC Lib "kernel32" Alias "MultiByteToWideChar" ( _
        ByVal CodePage As Long, ByVal dwFlags As Long, ByRef lpMultiByteStr As Any, _
        ByVal cchMultiByte As Long, ByVal lpWideCharStr As LongPtr, ByVal cchWideChar As Long) As Long
#Else
    Private Declare Sub dbfMoveMem Lib "kernel32" Alias "RtlMoveMemory" ( _
        ByRef Dest As Any, ByRef Src As Any, ByVal cb As Long)
    Private Declare Function dbfMB2WC Lib "kernel32" Alias "MultiByteToWideChar" ( _
        ByVal CodePage As Long, ByVal dwFlags As Long, ByRef lpMultiByteStr As Any, _
        ByVal cchMultiByte As Long, ByVal lpWideCharStr As Long, ByVal cchWideChar As Long) As Long
#End If

Private Const BLOK_ZAZNAMOV As Long = 2000

Public Type DbfTab
    cesta As String
    Cislo As Integer          ' číslo súboru (FreeFile)
    Otvoreny As Boolean
    Format7 As Boolean        ' True = dBase 7 (48-bajtové popisy polí)
    PocetZaznamov As Long     ' počet záznamov vrátane zmazaných
    DlzkaHlavicky As Long
    DlzkaZaznamu As Long
    PocetPoli As Long
    nazov() As String         ' 0..PocetPoli-1
    Typ() As String
    Dlzka() As Long
    Posun() As Long           ' posun poľa v zázname (0 = príznak zmazania)
    Mapa As Object            ' Scripting.Dictionary: názov poľa -> index
    CodePage As Long
    buf() As Byte             ' blok záznamov
    BufZaznamov As Long
    BufPozicia As Long
    Nacitanych As Long        ' koľko záznamov bolo načítaných do blokov
    Prejdenych As Long        ' koľko záznamov (aj zmazaných) sme prešli - pre progress
    Off As Long               ' posun aktuálneho záznamu v Buf
End Type

'-------------------------------------------------------------------------------
' Otvorí DBF súbor, načíta štruktúru polí a pripraví binárny čítací buffer.
'-------------------------------------------------------------------------------
Public Function DbfOtvor(ByVal cesta As String, ByRef t As DbfTab) As Boolean
    Dim f As Integer, hdr32(0 To 31) As Byte, hdr() As Byte
    Dim hl As Long, rl As Long, nrec As Long, dN As Double
    Dim i As Long, j As Long, n As Long, pos As Long, stride As Long, start As Long
    Dim nameLen As Long, running As Long, lofPocet As Long, nm As String, cpSet As String
    Dim typeOffset As Long, lenOffset As Long, fLen As Long

    On Error GoTo Chyba
    t.Otvoreny = False
    If Len(Dir(cesta)) = 0 Then
        Call mod_00_Common.ZapisLog("DbfOtvor", "WARN", "Súbor neexistuje: " & cesta)
        Exit Function
    End If

    f = FreeFile
    Open cesta For Binary Access Read Shared As #f
    If LOF(f) < 33 Then GoTo Neplatny

    Get #f, 1, hdr32
    dN = CDbl(hdr32(4)) + CDbl(hdr32(5)) * 256# + CDbl(hdr32(6)) * 65536# + CDbl(hdr32(7)) * 16777216#
    If dN > 2147483647# Then dN = 2147483647#
    nrec = CLng(dN)
    hl = CLng(hdr32(8)) + CLng(hdr32(9)) * 256&
    rl = CLng(hdr32(10)) + CLng(hdr32(11)) * 256&
    If hl < 33 Or rl < 2 Or hl > LOF(f) Then GoTo Neplatny

    ReDim hdr(0 To hl - 1)
    Get #f, 1, hdr

    ' dBase 7: popisy polí začínajú na 68 a majú 48 bajtov; dBase III/IV: od 32, po 32 bajtov
    t.Format7 = False
    If hl > 69 Then
        If ((hl - 69) Mod 48) = 0 And ((hl - 33) Mod 32) <> 0 Then
            If hdr(hl - 1) = 13 Then t.Format7 = True
        End If
    End If

    If t.Format7 Then
        start = 68: stride = 48: nameLen = 32
        typeOffset = 32: lenOffset = 33
    Else
        start = 32: stride = 32: nameLen = 11
        typeOffset = 11: lenOffset = 16
    End If

    ' spočítanie polí
    n = 0: pos = start
    Do While pos + stride <= hl
        If hdr(pos) = 13 Then Exit Do
        n = n + 1
        pos = pos + stride
    Loop
    If n = 0 Then GoTo Neplatny

    ReDim t.nazov(0 To n - 1)
    ReDim t.Typ(0 To n - 1)
    ReDim t.Dlzka(0 To n - 1)
    ReDim t.Posun(0 To n - 1)
    Set t.Mapa = CreateObject("Scripting.Dictionary")
    t.Mapa.CompareMode = 1          ' bez rozlišovania veľkosti písmen

    running = 1
    pos = start
    For i = 0 To n - 1
        nm = ""
        For j = 0 To nameLen - 1
            If hdr(pos + j) = 0 Then Exit For
            nm = nm & Chr$(hdr(pos + j))
        Next j
        t.nazov(i) = nm
        t.Typ(i) = Chr$(hdr(pos + typeOffset))
        
        ' Načítanie dĺžky poľa zo správneho offsetu
        fLen = CLng(hdr(pos + lenOffset))
        
        ' Poistka pre prípad nulovej dĺžky
        If fLen = 0 Then
            Select Case UCase$(t.Typ(i))
                Case "C": fLen = 10
                Case "N": fLen = 10
                Case "L": fLen = 1
                Case "D": fLen = 8
                Case Else: fLen = 10
            End Select
        End If

        t.Dlzka(i) = fLen
        t.Posun(i) = running
        running = running + t.Dlzka(i)
        t.Mapa(UCase$(nm)) = i
        pos = pos + stride
    Next i
    If running > rl Then GoTo Neplatny

    ' kódová stránka
    cpSet = Trim$(mod_00_Common.GetNastavenie("DBFKodovanie", "AUTO"))
    If UCase$(cpSet) = "AUTO" Or Val(cpSet) <= 0 Then
        Select Case hdr(29)
            Case &H64: t.CodePage = 852
            Case &H2:  t.CodePage = 850
            Case Else: t.CodePage = 1250
        End Select
    Else
        t.CodePage = CLng(Val(cpSet))
    End If

    ' počet záznamov: header vs. skutočná veľkosť súboru
    lofPocet = (LOF(f) - hl) \ rl
    If lofPocet < 0 Then lofPocet = 0
    If nrec <= 0 Or nrec > lofPocet Then nrec = lofPocet

    Seek #f, hl + 1
    t.cesta = cesta
    t.Cislo = f
    t.PocetPoli = n
    t.DlzkaHlavicky = hl
    t.DlzkaZaznamu = rl
    t.PocetZaznamov = nrec
    t.BufZaznamov = 0
    t.BufPozicia = -1
    t.Nacitanych = 0
    t.Prejdenych = 0
    t.Off = 0
    t.Otvoreny = True
    DbfOtvor = True
    Exit Function

Neplatny:
    Close #f
    Call mod_00_Common.ZapisLog("DbfOtvor", "ERROR", "Neplatná alebo poškodená hlavička DBF: " & cesta)
    Exit Function
Chyba:
    Dim popis As String
    popis = Err.Description
    On Error Resume Next
    Close #f
    Call mod_00_Common.ZapisLog("DbfOtvor", "ERROR", "Chyba otvorenia DBF " & cesta & ": " & popis)
End Function

'-------------------------------------------------------------------------------
' Bezpečne uzatvorí otvorený DBF súbor.
'-------------------------------------------------------------------------------
Public Sub DbfZatvor(ByRef t As DbfTab)
    Dim f As Integer
    On Error Resume Next
    If t.Otvoreny Then
        f = t.Cislo
        Close #f
        t.Otvoreny = False
    End If
End Sub

'-------------------------------------------------------------------------------
' Načíta nasledujúci blok záznamov z DBF súboru do pamäťového buffera.
'-------------------------------------------------------------------------------
Private Function NacitajBlok(ByRef t As DbfTab) As Boolean
    Dim zostava As Long, n As Long, f As Integer, b() As Byte
    zostava = t.PocetZaznamov - t.Nacitanych
    If zostava <= 0 Then Exit Function
    n = zostava
    If n > BLOK_ZAZNAMOV Then n = BLOK_ZAZNAMOV
    f = t.Cislo
    ReDim b(0 To n * t.DlzkaZaznamu - 1)
    Get #f, , b
    t.buf = b
    t.Nacitanych = t.Nacitanych + n
    t.BufZaznamov = n
    NacitajBlok = True
End Function

'-------------------------------------------------------------------------------
' Posunie ukazovateľ na ďalší nezmazaný záznam v DBF súbore (vracia False pri konci súboru).
'-------------------------------------------------------------------------------
Public Function DbfDalsi(ByRef t As DbfTab) As Boolean
    Dim c As Byte
    If Not t.Otvoreny Then Exit Function
    Do
        t.BufPozicia = t.BufPozicia + 1
        If t.BufPozicia >= t.BufZaznamov Then
            If Not NacitajBlok(t) Then Exit Function
            t.BufPozicia = 0
        End If
        t.Off = t.BufPozicia * t.DlzkaZaznamu
        t.Prejdenych = t.Prejdenych + 1
        c = t.buf(t.Off)
        If c = 26 Then Exit Function            ' koncová značka súboru
        If c <> 42 Then                          ' 42 = '*' = zmazaný záznam
            DbfDalsi = True
            Exit Function
        End If
    Loop
End Function

'-------------------------------------------------------------------------------
' Vráti index poľa podľa jeho názvu alebo zoznamu alternatívnych názvov (oddelených |).
'-------------------------------------------------------------------------------
Public Function DbfIdx(ByRef t As DbfTab, ByVal nazov As String) As Long
    Dim p() As String, i As Long
    DbfIdx = -1
    If Not t.Otvoreny Then Exit Function
    If InStr(nazov, "|") = 0 Then
        If t.Mapa.Exists(nazov) Then DbfIdx = CLng(t.Mapa(nazov))
    Else
        p = Split(nazov, "|")
        For i = 0 To UBound(p)
            If t.Mapa.Exists(p(i)) Then
                DbfIdx = CLng(t.Mapa(p(i)))
                Exit Function
            End If
        Next i
    End If
End Function

'-------------------------------------------------------------------------------
' Rýchle načítanie textovej hodnoty poľa podľa jeho číselného indexu.
'-------------------------------------------------------------------------------
Public Function DbfTextI(ByRef t As DbfTab, ByVal iIdx As Long) As String
    If iIdx < 0 Or iIdx >= t.PocetPoli Then Exit Function
    Dim dLen As Long, p As Long
    dLen = t.Dlzka(iIdx)
    If dLen <= 0 Then dLen = 10 ' Ochrana pred 0 dĺžkou

    p = t.Off + t.Posun(iIdx)
    
    ' Dekódovanie bajtov pomocou vstavanej funkcie DekodujBajty
    DbfTextI = DekodujBajty(t, p, dLen)
End Function

'-------------------------------------------------------------------------------
' Rýchle načítanie hodnoty akéhokoľvek typu poľa prekonvertovanej na text podľa indexu.
'-------------------------------------------------------------------------------
Public Function DbfHodnotaStrI(ByRef t As DbfTab, ByVal iIdx As Long) As String
    If iIdx < 0 Or iIdx >= t.PocetPoli Then Exit Function
    
    Dim c As String
    c = t.Typ(iIdx)
    
    Select Case c
        Case "C", "c", "D", "d"
            DbfHodnotaStrI = DbfTextI(t, iIdx)
            
        Case "L", "l"
            DbfHodnotaStrI = IIf(DbfBoolI(t, iIdx), "True", "False")
            
        Case "N", "n", "F", "f", "O", "o", "I", "i", "+"
            Dim d As Double
            d = DbfCisloI(t, iIdx)
            If d = 0 Then
                DbfHodnotaStrI = "0"
            ElseIf d = Fix(d) Then
                DbfHodnotaStrI = Trim$(Str$(Fix(d)))
            Else
                DbfHodnotaStrI = Trim$(Str$(d))
            End If
            
        Case Else
            DbfHodnotaStrI = DbfTextI(t, iIdx)
    End Select
End Function

'-------------------------------------------------------------------------------
' Rýchle načítanie číselnej hodnoty (Double) podľa indexu poľa.
'-------------------------------------------------------------------------------
Public Function DbfCisloI(ByRef t As DbfTab, ByVal idx As Long) As Double
    Dim p As Long
    If idx < 0 Then Exit Function
    p = t.Off + t.Posun(idx)
    Select Case t.Typ(idx)
        Case "N", "F", "C"
            DbfCisloI = AsciiCislo(t.buf, p, t.Dlzka(idx))
        Case "O"
            If t.Dlzka(idx) >= 8 Then DbfCisloI = DvojitaBE(t.buf, p)
        Case "I", "+"
            If t.Dlzka(idx) >= 4 Then DbfCisloI = Int32BE(t.buf, p)
        Case "L"
            If DbfBoolI(t, idx) Then DbfCisloI = 1
        Case Else
            DbfCisloI = 0
    End Select
End Function

'-------------------------------------------------------------------------------
' Rýchle načítanie celej číselnej hodnoty (Long) podľa indexu poľa.
'-------------------------------------------------------------------------------
Public Function DbfLongI(ByRef t As DbfTab, ByVal idx As Long) As Long
    Dim d As Double
    d = DbfCisloI(t, idx)
    If d <> d Then Exit Function
    If d > 2147483647# Or d < -2147483648# Then Exit Function
    DbfLongI = CLng(Fix(d))
End Function

'-------------------------------------------------------------------------------
' Rýchle načítanie logickej hodnoty (Boolean) podľa indexu poľa.
'-------------------------------------------------------------------------------
Public Function DbfBoolI(ByRef t As DbfTab, ByVal idx As Long, Optional ByVal Predvolene As Boolean = False) As Boolean
    Dim c As Long
    DbfBoolI = Predvolene
    If idx < 0 Then Exit Function
    If t.Typ(idx) <> "L" Then
        DbfBoolI = (DbfCisloI(t, idx) <> 0)
        Exit Function
    End If
    c = t.buf(t.Off + t.Posun(idx))
    Select Case c
        Case 84, 116, 89, 121: DbfBoolI = True      ' T t Y y
        Case 70, 102, 78, 110: DbfBoolI = False     ' F f N n
        Case Else: DbfBoolI = Predvolene            ' ' ' ? = nezadané
    End Select
End Function

'-------------------------------------------------------------------------------
' Načíta dátum v číselnom tvare YYYYMMDD podľa indexu poľa pre bleskové filtrovanie.
'-------------------------------------------------------------------------------
Public Function DbfYmdI(ByRef t As DbfTab, ByVal idx As Long) As Long
    Dim p As Long, i As Long, c As Long, v As Long
    If idx < 0 Then Exit Function
    If t.Dlzka(idx) <> 8 Then Exit Function
    p = t.Off + t.Posun(idx)
    For i = 0 To 7
        c = t.buf(p + i)
        If c < 48 Or c > 57 Then Exit Function
        v = v * 10 + (c - 48)
    Next i
    DbfYmdI = v
End Function

'-------------------------------------------------------------------------------
' Načíta dátumovú hodnotu (Variant Date / Null) podľa indexu poľa.
'-------------------------------------------------------------------------------
Public Function DbfDatumI(ByRef t As DbfTab, ByVal idx As Long) As Variant
    Dim ymd As Long, y As Long, m As Long, d As Long
    DbfDatumI = Null
    ymd = DbfYmdI(t, idx)
    If ymd = 0 Then Exit Function
    y = ymd \ 10000: m = (ymd \ 100) Mod 100: d = ymd Mod 100
    If y < 1900 Or m < 1 Or m > 12 Or d < 1 Or d > 31 Then Exit Function
    DbfDatumI = DateSerial(y, m, d)
End Function

'-------------------------------------------------------------------------------
' Pohodlné načítanie textovej hodnoty poľa podľa názvu poľa (alebo zoznamu názvov).
'-------------------------------------------------------------------------------
Public Function DbfText(ByRef t As DbfTab, ByVal nazov As String, Optional ByVal Predvolene As String = "") As String
    Dim idx As Long
    idx = DbfIdx(t, nazov)
    If idx < 0 Then DbfText = Predvolene Else DbfText = DbfTextI(t, idx)
End Function

'-------------------------------------------------------------------------------
' Pohodlné načítanie číselnej hodnoty (Double) podľa názvu poľa.
'-------------------------------------------------------------------------------
Public Function DbfCislo(ByRef t As DbfTab, ByVal nazov As String, Optional ByVal Predvolene As Double = 0) As Double
    Dim idx As Long
    idx = DbfIdx(t, nazov)
    If idx < 0 Then DbfCislo = Predvolene Else DbfCislo = DbfCisloI(t, idx)
End Function

'-------------------------------------------------------------------------------
' Pohodlné načítanie celej číselnej hodnoty (Long) podľa názvu poľa.
'-------------------------------------------------------------------------------
Public Function DbfLong(ByRef t As DbfTab, ByVal nazov As String) As Long
    DbfLong = DbfLongI(t, DbfIdx(t, nazov))
End Function

'-------------------------------------------------------------------------------
' Pohodlné načítanie logickej hodnoty (Boolean) podľa názvu poľa.
'-------------------------------------------------------------------------------
Public Function DbfBool(ByRef t As DbfTab, ByVal nazov As String, Optional ByVal Predvolene As Boolean = False) As Boolean
    DbfBool = DbfBoolI(t, DbfIdx(t, nazov), Predvolene)
End Function

'-------------------------------------------------------------------------------
' Pohodlné načítanie dátumovej hodnoty podľa názvu poľa.
'-------------------------------------------------------------------------------
Public Function DbfDatum(ByRef t As DbfTab, ByVal nazov As String) As Variant
    DbfDatum = DbfDatumI(t, DbfIdx(t, nazov))
End Function

'-------------------------------------------------------------------------------
' Sostaví reťazec zvyšných namapovaných polí vo formáte "POLE=hodnota;" pre archiváciu.
'-------------------------------------------------------------------------------
Public Function DbfSurove(ByRef t As DbfTab, ByVal vynimky As String) As String
    Dim i As Long, v As String, vyn As String, r As String
    vyn = "|" & UCase$(vynimky) & "|"
    For i = 0 To t.PocetPoli - 1
        If InStr(vyn, "|" & UCase$(t.nazov(i)) & "|") = 0 Then
            v = HodnotaPola(t, i)
            If Len(v) > 0 Then r = r & t.nazov(i) & "=" & v & ";"
        End If
    Next i
    DbfSurove = r
End Function

'-------------------------------------------------------------------------------
' Pomocná privátna funkcia na získanie textovej reprezentácie nenulovej hodnoty poľa.
'-------------------------------------------------------------------------------
Private Function HodnotaPola(ByRef t As DbfTab, ByVal i As Long) As String
    Dim d As Double, s As String
    Select Case t.Typ(i)
        Case "C", "D"
            s = DbfTextI(t, i)
            If s <> "0" Then HodnotaPola = s
        Case "L"
            If DbfBoolI(t, i) Then HodnotaPola = "T"
        Case "N", "F", "O", "I", "+"
            d = DbfCisloI(t, i)
            If d <> 0 Then HodnotaPola = Trim$(Str$(d))
    End Select
End Function

'-------------------------------------------------------------------------------
' Nízkoúrovňové dekódovanie bajtov z buffera podľa nastavenej kódovej stránky (Win32 API).
'-------------------------------------------------------------------------------
Private Function DekodujBajty(ByRef t As DbfTab, ByVal p As Long, ByVal n As Long) As String
    Dim s As String, r As Long
    Do While n > 0
        If t.buf(p + n - 1) = 32 Or t.buf(p + n - 1) = 0 Then n = n - 1 Else Exit Do
    Loop
    If n = 0 Then Exit Function
    s = Space$(n)
    r = dbfMB2WC(t.CodePage, 0, t.buf(p), n, StrPtr(s), n)
    If r > 0 Then DekodujBajty = Trim$(Left$(s, r))
End Function

'-------------------------------------------------------------------------------
' Parsovanie ASCII čísla z bajtov dBase (správa sa ako Val, ignoruje medzery).
'-------------------------------------------------------------------------------
Private Function AsciiCislo(ByRef buf() As Byte, ByVal p As Long, ByVal n As Long) As Double
    Dim i As Long, c As Long, neg As Boolean, v As Double, sc As Double
    Dim desat As Boolean, zac As Boolean
    sc = 1#
    For i = p To p + n - 1
        c = buf(i)
        If c >= 48 And c <= 57 Then
            zac = True
            If desat Then
                sc = sc / 10#
                v = v + (c - 48) * sc
            Else
                v = v * 10# + (c - 48)
            End If
        ElseIf c = 32 Or c = 0 Then
            If zac Then Exit For
        ElseIf c = 45 And Not zac Then
            neg = True
        ElseIf (c = 46 Or c = 44) And Not desat Then
            desat = True
        Else
            Exit For
        End If
    Next i
    If neg Then v = -v
    AsciiCislo = v
End Function

'-------------------------------------------------------------------------------
' Dekódovanie dBase 7 8-bajtového typu "O" (Double, Big-Endian).
'-------------------------------------------------------------------------------
Private Function DvojitaBE(ByRef buf() As Byte, ByVal p As Long) As Double
    Dim tmp(0 To 7) As Byte, i As Long, nuly As Boolean, d As Double
    nuly = True
    For i = 0 To 7
        If buf(p + i) <> 0 Then nuly = False: Exit For
    Next i
    If nuly Then Exit Function                 ' nikdy nezadané pole = 0
    If (buf(p) And &H80) <> 0 Then
        For i = 0 To 7: tmp(i) = buf(p + 7 - i): Next i
        tmp(7) = tmp(7) And &H7F
    Else
        For i = 0 To 7: tmp(i) = buf(p + 7 - i) Xor &HFF: Next i
    End If
    dbfMoveMem d, tmp(0), 8
    If d <> d Then d = 0
    DvojitaBE = d
End Function

'-------------------------------------------------------------------------------
' Dekódovanie dBase 7 4-bajtového typu "I" / "+" (32-bit Integer, Big-Endian).
'-------------------------------------------------------------------------------
Private Function Int32BE(ByRef buf() As Byte, ByVal p As Long) As Double
    Dim i As Long, nuly As Boolean, v As Double
    nuly = True
    For i = 0 To 3
        If buf(p + i) <> 0 Then nuly = False: Exit For
    Next i
    If nuly Then Exit Function
    v = CDbl(buf(p) Xor &H80) * 16777216# + CDbl(buf(p + 1)) * 65536# + CDbl(buf(p + 2)) * 256# + CDbl(buf(p + 3))
    Int32BE = v - 2147483648#
End Function


