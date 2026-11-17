Attribute VB_Name = "kl_00_Spolocne"
'@Verzia 1.0.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: kl_00_Spolocne
' POPIS: Spoločné veci klienta na razenie (DochadzkaKlient.accdb): verzia, priečinky, čítanie a zápis súborov, protokol (log),
'        čas v UTC a nové ID razenia. Klient nezávisí od modulov HR. Do logu ani na obrazovku sa nikdy nepíšu mená, len osobné
'        číslo a účet.
'
'        Lokálny priečinok %LOCALAPPDATA%\DochadzkaKlient:
'          zaklad.txt  test.ini  identita.txt  konfiguracia\klient_konfig.txt  razenia\fronta  razenia\odoslane\RRRR-MM
'          log\klient.log (kódovanie Windows, do 200 kB, potom klient.log.old)  klient.lock
'
'        ČAS: UTC sa číta zo systému (kernel32 GetSystemTime; nezávisí od WMI, ktoré býva pomalé alebo vypnuté) a miestny čas sa
'        odvodí ako UTC + posun zaokrúhlený na minúty. Rozdiel cas - utc je tak vždy presne celé minúty (dve samostatné čítania
'        hodín by sa na hranici sekundy mohli líšiť o sekundu a razenie by neprešlo kontrolou 3600/7200 s).
'        ID: ole32 CoCreateGuid (Scriptlet.TypeLib po aktualizácii Office z roku 2017 často hlási chybu 70, je len záloha).
' ZOZNAM VEREJNÝCH PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - LokalnyPriecinok(), ZakladPriecinok()     : Lokálny priečinok klienta; základ na serveri zo zaklad.txt ("" = chýba).
' - JeLokalnaCesta(cesta)                     : Cesta nie je sieťová (nezačína \\ a nejde o namapovanú sieťovú jednotku).
' - PripravLokalnePriecinky()                 : Vytvorí chýbajúce lokálne priečinky; vráti "" alebo text chyby.
' - VytvorPriecinok(cesta)                    : Vytvorí priečinok aj s nadradenými.
' - SuborExistuje(cesta), PriecinokExistuje(cesta), VelkostSuboru(cesta)
' - CitajBajty(cesta, text, max)              : Prečíta súbor ako reťazec, v ktorom jeden znak = jeden bajt.
' - CitajTextUtf8(cesta, text)                : Prečíta textový súbor UTF-8 (s BOM aj bez) alebo ASCII.
' - Utf8NaText(bajty)                         : ČISTÁ: prevod bajtov UTF-8 (jeden znak = jeden bajt) na text.
' - TextNaUtf8(text)                          : ČISTÁ: prevod textu na bajty UTF-8 (jeden znak = jeden bajt).
' - ZapisAsciiNovy(cesta, text)               : Zapíše lokálny súbor naraz (znak = bajt; cez dočasný súbor a premenovanie); vráti číslo chyby.
' - ZmazSubor(cesta)                          : Zmaže lokálny súbor; vráti číslo chyby.
' - RozdelRiadky(text)                        : ČISTÁ: riadky textu (CRLF aj LF).
' - ZoznamSuborov(priecinok, maska, a)        : Názvy súborov zoradené podľa názvu; vráti počet.
' - ZapisLog(uroven, text)                    : Riadok do log\klient.log (INFO, WARN, ERROR); nikdy nevyhodí chybu.
' - UtcTeraz(), PosunMin(), CasTeraz(cas, utc, posunMin) : Čas v UTC, posun miestneho času v minútach, dvojica cas/utc pre razenie.
' - NoveGuid()                                : Nové ID razenia (GUID veľkými písmenami bez zátvoriek); "" pri zlyhaní.
'===============================================================================

Public Const VERZIA_KLIENTA As String = "1.0.0"
Public Const NAZOV_KLIENTA As String = "DochadzkaKlient"
Public Const SUBOR_ZAKLAD As String = "zaklad.txt"
Public Const SUBOR_TEST As String = "test.ini"
Public Const SUBOR_IDENTITA As String = "identita.txt"
Public Const SUBOR_KONFIG As String = "klient_konfig.txt"
Public Const SUBOR_ZAMOK As String = "klient.lock"
Public Const PRIECINOK_KONFIG As String = "konfiguracia"
Public Const PRIECINOK_PRIJEM As String = "prijem"
Public Const PRIECINOK_FRONTA As String = "razenia\fronta"
Public Const PRIECINOK_ODOSLANE As String = "razenia\odoslane"
Public Const PRIECINOK_LOG As String = "log"
Private Const MAX_LOG_BAJTOV As Long = 204800

Private Type TSystemovyCas
    wRok As Integer
    wMesiac As Integer
    wDenTyzdna As Integer
    wDen As Integer
    wHodina As Integer
    wMinuta As Integer
    wSekunda As Integer
    wMilisekundy As Integer
End Type

Private Type TGuid
    Data1 As Long
    Data2 As Integer
    Data3 As Integer
    Data4(0 To 7) As Byte
End Type

#If VBA7 Then
    Private Declare PtrSafe Sub GetSystemTime Lib "kernel32" (ByRef lpCas As TSystemovyCas)
    Private Declare PtrSafe Function CoCreateGuid Lib "ole32" (ByRef pGuid As TGuid) As Long
#Else
    Private Declare Sub GetSystemTime Lib "kernel32" (ByRef lpCas As TSystemovyCas)
    Private Declare Function CoCreateGuid Lib "ole32" (ByRef pGuid As TGuid) As Long
#End If

'===============================================================================
' Priečinky
'===============================================================================
Public Function LokalnyPriecinok() As String
    Dim s As String
    s = Trim$(Environ$("LOCALAPPDATA"))
    If Len(s) = 0 Then Exit Function
    If Right$(s, 1) = "\" Then s = Left$(s, Len(s) - 1)
    LokalnyPriecinok = s & "\" & NAZOV_KLIENTA
End Function

' Cesta je lokálna, ak nie je sieťová: nezačína dvoma spätnými lomkami a nejde o namapovanú sieťovú jednotku (Z:\).
' Prázdna cesta nie je lokálna. Ak sa typ jednotky nepodarí zistiť, cesta sa berie ako sieťová (testovací režim sa nepovolí).
Public Function JeLokalnaCesta(ByVal strCesta As String) As Boolean
    Dim fso As Object
    strCesta = Trim$(strCesta)
    If Len(strCesta) = 0 Then Exit Function
    If Left$(strCesta, 2) = "\\" Then Exit Function
    If Mid$(strCesta, 2, 1) = ":" Then
        On Error GoTo Chyba
        Set fso = CreateObject("Scripting.FileSystemObject")
        JeLokalnaCesta = (fso.GetDrive(Left$(strCesta, 2)).DriveType <> 3)    ' 3 = sieťová jednotka
        Exit Function
    End If
    JeLokalnaCesta = True
    Exit Function
Chyba:
    JeLokalnaCesta = False
End Function

' Základ na serveri: prvý neprázdny riadok súboru zaklad.txt (píše ho spúšťač), bez koncovej lomky. "" = súbor chýba.
Public Function ZakladPriecinok() As String
    Dim strText As String, riadky() As String, i As Long, s As String
    If Len(LokalnyPriecinok()) = 0 Then Exit Function
    If Not CitajTextUtf8(LokalnyPriecinok() & "\" & SUBOR_ZAKLAD, strText) Then Exit Function
    riadky = RozdelRiadky(strText)
    For i = LBound(riadky) To UBound(riadky)
        s = Trim$(riadky(i))
        If Len(s) > 0 Then Exit For
    Next i
    If Len(s) >= 2 Then
        If Left$(s, 1) = """" And Right$(s, 1) = """" Then s = Trim$(Mid$(s, 2, Len(s) - 2))
    End If
    Do While Len(s) > 3 And Right$(s, 1) = "\"
        s = Left$(s, Len(s) - 1)
    Loop
    ZakladPriecinok = s
End Function

Public Function PriecinokExistuje(ByVal strCesta As String) As Boolean
    On Error GoTo Chyba
    If Len(strCesta) = 0 Then Exit Function
    PriecinokExistuje = ((GetAttr(strCesta) And vbDirectory) = vbDirectory)
    Exit Function
Chyba:
    PriecinokExistuje = False
End Function

Public Function SuborExistuje(ByVal strCesta As String) As Boolean
    On Error GoTo Chyba
    If Len(strCesta) = 0 Then Exit Function
    SuborExistuje = ((GetAttr(strCesta) And vbDirectory) = 0)
    Exit Function
Chyba:
    SuborExistuje = False
End Function

' Veľkosť súboru v bajtoch; -1 = nedá sa zistiť.
Public Function VelkostSuboru(ByVal strCesta As String) As Long
    On Error GoTo Chyba
    VelkostSuboru = FileLen(strCesta)
    Exit Function
Chyba:
    VelkostSuboru = -1
End Function

' Vytvorí priečinok vrátane chýbajúcich nadradených (len lokálne cesty klienta).
Public Function VytvorPriecinok(ByVal strCesta As String) As Boolean
    Dim p As Long, strRodic As String
    On Error GoTo Chyba
    If PriecinokExistuje(strCesta) Then
        VytvorPriecinok = True
        Exit Function
    End If
    p = InStrRev(strCesta, "\")
    If p > 3 Then
        strRodic = Left$(strCesta, p - 1)
        If Not PriecinokExistuje(strRodic) Then
            If Not VytvorPriecinok(strRodic) Then Exit Function
        End If
    End If
    MkDir strCesta
    VytvorPriecinok = PriecinokExistuje(strCesta)
    Exit Function
Chyba:
    VytvorPriecinok = PriecinokExistuje(strCesta)
End Function

' Vytvorí lokálne priečinky klienta. Vráti "" pri úspechu, inak text chyby (razenie sa potom musí vypnúť).
Public Function PripravLokalnePriecinky() As String
    Dim strLok As String, v As Variant
    strLok = LokalnyPriecinok()
    If Len(strLok) = 0 Then
        PripravLokalnePriecinky = "Nepodarilo sa zistiť lokálny priečinok používateľa (LOCALAPPDATA)."
        Exit Function
    End If
    For Each v In Array("", PRIECINOK_KONFIG, PRIECINOK_FRONTA, PRIECINOK_ODOSLANE, PRIECINOK_LOG)
        If Not VytvorPriecinok(strLok & IIf(Len(CStr(v)) > 0, "\" & CStr(v), "")) Then
            PripravLokalnePriecinky = "Nepodarilo sa vytvoriť priečinok " & strLok & IIf(Len(CStr(v)) > 0, "\" & CStr(v), "") & "."
            Exit Function
        End If
    Next v
End Function

'===============================================================================
' Súbory
'===============================================================================
' Prečíta súbor ako reťazec, v ktorom jeden znak = jeden bajt (kódy 0 až 255). Súbor väčší než lMax bajtov sa nečíta.
Public Function CitajBajty(ByVal strCesta As String, ByRef strText As String, Optional ByVal lMax As Long = 1048576) As Boolean
    Dim f As Integer, n As Long, b() As Byte, w() As Byte, i As Long
    On Error GoTo Chyba
    strText = ""
    If Not SuborExistuje(strCesta) Then Exit Function
    n = FileLen(strCesta)
    If n > lMax Then Exit Function
    If n > 0 Then
        f = FreeFile
        Open strCesta For Binary Access Read Shared As #f
        ReDim b(0 To n - 1)
        Get #f, 1, b
        Close #f
        f = 0
        ReDim w(0 To 2 * n - 1)
        For i = 0 To n - 1
            w(2 * i) = b(i)
        Next i
        strText = w
    End If
    CitajBajty = True
    Exit Function
Chyba:
    On Error Resume Next
    If f > 0 Then Close #f
    strText = ""
    CitajBajty = False
End Function

' ČISTÁ. Bajty UTF-8 (jeden znak = jeden bajt) -> text. Úvodný BOM sa vynechá; neplatná postupnosť sa nahradí otáznikom.
Public Function Utf8NaText(ByVal strBajty As String) As String
    Dim i As Long, n As Long, c As Long, c2 As Long, c3 As Long, s As String
    n = Len(strBajty)
    i = 1
    If n >= 3 Then
        If AscW(Mid$(strBajty, 1, 1)) = &HEF And AscW(Mid$(strBajty, 2, 1)) = &HBB And AscW(Mid$(strBajty, 3, 1)) = &HBF Then i = 4
    End If
    Do While i <= n
        c = AscW(Mid$(strBajty, i, 1)) And &HFF
        If c < &H80 Then
            s = s & ChrW$(c)
            i = i + 1
        ElseIf c >= &HC2 And c <= &HDF And i + 1 <= n Then
            c2 = AscW(Mid$(strBajty, i + 1, 1)) And &HFF
            If (c2 And &HC0) = &H80 Then
                s = s & ChrW$((c And &H1F) * 64 + (c2 And &H3F))
                i = i + 2
            Else
                s = s & "?"
                i = i + 1
            End If
        ElseIf c >= &HE0 And c <= &HEF And i + 2 <= n Then
            c2 = AscW(Mid$(strBajty, i + 1, 1)) And &HFF
            c3 = AscW(Mid$(strBajty, i + 2, 1)) And &HFF
            If (c2 And &HC0) = &H80 And (c3 And &HC0) = &H80 Then
                s = s & ChrW$((c And &HF) * 4096 + (c2 And &H3F) * 64 + (c3 And &H3F))
                i = i + 3
            Else
                s = s & "?"
                i = i + 1
            End If
        Else
            s = s & "?"
            i = i + 1
        End If
    Loop
    Utf8NaText = s
End Function

' ČISTÁ. Text -> bajty UTF-8 (jeden znak výsledku = jeden bajt), bez BOM. Na zápis textu s diakritikou cez ZapisAsciiNovy.
Public Function TextNaUtf8(ByVal strText As String) As String
    Dim i As Long, c As Long, s As String
    For i = 1 To Len(strText)
        c = AscW(Mid$(strText, i, 1)) And &HFFFF&
        If c < &H80 Then
            s = s & ChrW$(c)
        ElseIf c < &H800 Then
            s = s & ChrW$(&HC0 Or (c \ 64)) & ChrW$(&H80 Or (c And &H3F))
        Else
            s = s & ChrW$(&HE0 Or (c \ 4096)) & ChrW$(&H80 Or ((c \ 64) And &H3F)) & ChrW$(&H80 Or (c And &H3F))
        End If
    Next i
    TextNaUtf8 = s
End Function

Public Function CitajTextUtf8(ByVal strCesta As String, ByRef strText As String) As Boolean
    Dim strBajty As String
    strText = ""
    If Not CitajBajty(strCesta, strBajty) Then Exit Function
    strText = Utf8NaText(strBajty)
    CitajTextUtf8 = True
End Function

' Zapíše lokálny súbor naraz: najprv do <cesta>.tmp, potom premenovanie (súbor s cieľovým názvom je vždy celý).
' Existujúci cieľ sa nahradí. Vráti 0 alebo číslo chyby. Jeden znak textu = jeden bajt súboru (kódy 0 až 255, bez prevodu
' kódovej stránky): pre text ASCII je to priamo text, pre bajty z CitajBajty presná kópia.
Public Function ZapisAsciiNovy(ByVal strCesta As String, ByVal strText As String) As Long
    Dim f As Integer, b() As Byte, strTmp As String, i As Long
    On Error GoTo Chyba
    strTmp = strCesta & ".tmp"
    If SuborExistuje(strTmp) Then Kill strTmp
    f = FreeFile
    Open strTmp For Binary Access Write Lock Read Write As #f
    If Len(strText) > 0 Then
        ReDim b(0 To Len(strText) - 1)
        For i = 1 To Len(strText)
            b(i - 1) = CByte(AscW(Mid$(strText, i, 1)) And &HFF)
        Next i
        Put #f, 1, b
    End If
    Close #f
    f = 0
    If VelkostSuboru(strTmp) <> Len(strText) Then Err.Raise 61
    If SuborExistuje(strCesta) Then Kill strCesta
    Name strTmp As strCesta
    ZapisAsciiNovy = 0
    Exit Function
Chyba:
    ZapisAsciiNovy = IIf(Err.Number <> 0, Err.Number, 5)
    On Error Resume Next
    If f > 0 Then Close #f
    If SuborExistuje(strTmp) Then Kill strTmp
End Function

Public Function ZmazSubor(ByVal strCesta As String) As Long
    On Error GoTo Chyba
    If SuborExistuje(strCesta) Then Kill strCesta
    Exit Function
Chyba:
    ZmazSubor = Err.Number
End Function

' ČISTÁ. Riadky textu; oddeľovač CRLF aj samotný LF (aj CR).
Public Function RozdelRiadky(ByVal strText As String) As String()
    strText = Replace(strText, vbCr & vbLf, vbLf)
    strText = Replace(strText, vbCr, vbLf)
    RozdelRiadky = Split(strText, vbLf)
End Function

' Názvy súborov v priečinku podľa masky (napr. *.rzn), zoradené podľa názvu. Vráti počet; a je (0 To počet - 1).
Public Function ZoznamSuborov(ByVal strPriecinok As String, ByVal strMaska As String, ByRef a() As String) As Long
    Dim s As String, n As Long, i As Long, j As Long, strTmp As String
    On Error GoTo Chyba
    Erase a
    If Not PriecinokExistuje(strPriecinok) Then Exit Function
    s = Dir$(strPriecinok & "\" & strMaska, vbNormal)
    Do While Len(s) > 0
        ReDim Preserve a(0 To n)
        a(n) = s
        n = n + 1
        s = Dir$()
    Loop
    For i = 1 To n - 1
        strTmp = a(i)
        j = i - 1
        Do While j >= 0
            If StrComp(a(j), strTmp, vbBinaryCompare) <= 0 Then Exit Do
            a(j + 1) = a(j)
            j = j - 1
        Loop
        a(j + 1) = strTmp
    Next i
    ZoznamSuborov = n
    Exit Function
Chyba:
    ZoznamSuborov = n
End Function

'===============================================================================
' Protokol (log). Bez mien: len osobné číslo, účet, čísla chýb a názvy súborov.
'===============================================================================
Public Sub ZapisLog(ByVal strUroven As String, ByVal strText As String)
    Dim f As Integer, strCesta As String
    On Error GoTo Chyba
    If Len(LokalnyPriecinok()) = 0 Then Exit Sub
    strCesta = LokalnyPriecinok() & "\" & PRIECINOK_LOG & "\klient.log"
    If VelkostSuboru(strCesta) > MAX_LOG_BAJTOV Then
        If SuborExistuje(strCesta & ".old") Then Kill strCesta & ".old"
        Name strCesta As strCesta & ".old"
    End If
    strText = Replace(Replace(strText, vbCr, " "), vbLf, " ")
    f = FreeFile
    Open strCesta For Append Access Write As #f
    Print #f, Format$(Now, "yyyy\-mm\-dd hh:nn:ss") & " " & Left$(strUroven & "     ", 5) & " " & strText
    Close #f
    Exit Sub
Chyba:
    On Error Resume Next
    If f > 0 Then Close #f
End Sub

'===============================================================================
' Čas a ID
'===============================================================================
' Aktuálny čas v UTC (na celé sekundy).
Public Function UtcTeraz() As Date
    Dim t As TSystemovyCas
    Call GetSystemTime(t)
    UtcTeraz = DateSerial(t.wRok, t.wMesiac, t.wDen) + TimeSerial(t.wHodina, t.wMinuta, t.wSekunda)
End Function

' Posun miestneho času oproti UTC v minútach (Bratislava: 60 v zime, 120 v lete).
Public Function PosunMin() As Long
    PosunMin = CLng(Round((Now - UtcTeraz()) * 1440, 0))
End Function

' Dvojica časov pre razenie: UTC zo systému a miestny čas = UTC + posun (rozdiel je presne celé minúty).
Public Sub CasTeraz(ByRef dtCas As Date, ByRef dtUtc As Date, ByRef lPosunMin As Long)
    dtUtc = UtcTeraz()
    lPosunMin = CLng(Round((Now - dtUtc) * 1440, 0))
    dtCas = DateAdd("n", lPosunMin, dtUtc)
End Sub

Private Function Hex0(ByVal lHodnota As Long, ByVal lDlzka As Long) As String
    Hex0 = Right$(String$(lDlzka, "0") & Hex$(lHodnota), lDlzka)
End Function

' Nové ID razenia: GUID veľkými písmenami bez zložených zátvoriek (8-4-4-4-12). "" = nepodarilo sa (razenie sa nezapíše).
Public Function NoveGuid() As String
    Dim g As TGuid, s As String, i As Long, strT As String
    On Error Resume Next
    If CoCreateGuid(g) = 0 Then
        s = Hex0(g.Data1, 8) & "-" & Right$("0000" & Hex$(g.Data2), 4) & "-" & Right$("0000" & Hex$(g.Data3), 4) & "-" & _
            Hex0(g.Data4(0), 2) & Hex0(g.Data4(1), 2) & "-"
        For i = 2 To 7
            s = s & Hex0(g.Data4(i), 2)
        Next i
    End If
    If Err.Number <> 0 Then
        Err.Clear
        s = ""
    End If
    If Not kl_02_Protokol.JeGuidRazenia(s) Then
        strT = CStr(CreateObject("Scriptlet.TypeLib").GUID)
        If Err.Number = 0 And Len(strT) >= 38 Then s = UCase$(Mid$(strT, 2, 36))
        Err.Clear
    End If
    If kl_02_Protokol.JeGuidRazenia(s) Then NoveGuid = s
End Function
