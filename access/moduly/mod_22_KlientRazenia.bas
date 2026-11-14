Attribute VB_Name = "mod_22_KlientRazenia"
'@Verzia 1.0.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_22_KlientRazenia
' POPIS: STRANA HR klienta na razenie v Accesse (docs/KLIENT-ACCESS.md). Zamestnanci razia z Accessu na svojom počítači; klient zapíše
'        každé razenie ako malý súbor .rzn do zdieľaného priečinka prijem (zamestnanec ho smie len vytvoriť). Tento modul súbory
'        skontroluje, prevedie na razenia Accessu a vloží ich do fronty TerminalInbox rovnako ako razenia z terminála, takže ďalej
'        ich spracuje SpracujInbox, výpočet dňa, editor, výkazy a uzávierka bez zmeny.
'
'        Zdieľaný priečinok (nastavenie KlientPriecinok), jeho podpriečinky:
'          prijem        zamestnanci len vytvárajú súbory; HR ich číta a po spracovaní presúva
'          konfiguracia  klient_konfig.txt (tlačidlá a texty klienta), zamestnanci len čítajú
'          spracovane    prijaté súbory podľa mesiaca (RRRR-MM), duplicity
'          chybne        odmietnuté súbory + súbor .dovod.txt s dôvodom
'
'        Kontrola súboru (rovnaké pravidlá ako referencia tools/klient_protokol.py):
'          tvar (hlavička DOCHSRZN;1, riadok #END, povinné kľúče, platné hodnoty, názov = čas + id), potom
'          účet: login v súbore patrí zamestnancovi s osobným číslom oc (Zamestnanci.LoginAD)      KlientKontrolaUctu
'          vlastník súboru v sieti je ten istý účet ako login v súbore                              KlientKontrolaVlastnika
'          čas razenia zodpovedá času vytvorenia súboru na serveri a nie je v budúcnosti            KlientMaxOdchylkaMin
'          razenia dnešného dňa čakajú (párovanie potrebuje celý deň)                               KlientAjDnesne
'        Razenie, ktoré neprejde "mäkkou" kontrolou, sa vloží ako NEOVERENÉ (TerminalInbox.Overenie = unverified, dôvod v
'        KlientRazenia.Poznamka a v reporte). Počíta sa ako ostatné. Odmietnutý súbor ide do chybne s dôvodom a dá sa po oprave
'        (napr. doplnení LoginAD) vrátiť do prijem.
'
'        Prevod na prerušenia a smer Z/K robí mod_19_TerminalImport.PrevedRazeniaKlienta (to isté párovanie ako pri termináli).
'        Súbor prijatý skôr (rovnaké id) sa nevloží druhýkrát.
' ZOZNAM VEREJNÝCH PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - ZabezpecTabulky(db)                      : Vytvorí tabuľku KlientRazenia.
' - NastavPredvolby()                        : Doplní chýbajúce nastavenia klienta (predvolené hodnoty).
' - PripravPriecinky()                       : Vytvorí podpriečinky v KlientPriecinok; vráti text s odporúčanými právami.
' - PrijmiKlientskeRazenia(nanecisto)        : Skontroluje a prevezme súbory z prijem; vráti textový report.
' - GenerujKonfiguraciuKlienta()             : Zapíše konfiguracia\klient_konfig.txt (tlačidlá podľa číselníka prerušení).
' - UkazVlastnika(cesta)                     : Pomôcka: ako Windows ukazuje vlastníka súboru (na zistenie, či sedí s prihlasovacím menom).
'===============================================================================

Private Const MAX_BAJTOV As Long = 2048
Private Const NEDOKONCENY_SEK As Long = 300
Private Const HLAVICKA_RZN As String = "DOCHSRZN;1"
Private Const KONIEC_RZN As String = "#END"
Private Const KODY_RZN As String = "|WORK|DOCTOR|TRIP|FAMILY|LEAVE|SICK|PRIV|ERRAND|"

Private Type TKlient
    Subor As String           ' názov súboru
    Cesta As String           ' úplná cesta v priečinku prijem
    ExterneID As String       ' id razenia (GUID)
    Osc As String             ' osobné číslo
    LoginWin As String        ' prihlasovacie meno
    Pocitac As String
    Kod As String             ' WORK, DOCTOR, ...
    Smer As String            ' IN / OUT
    Lokalny As Date           ' miestny čas razenia
    CasUtc As String          ' RRRR-MM-DDTHH:MM:SS
    Odlozene As Boolean
    Obsah As String           ' text súboru (do Payload)
    Vlastnik As String        ' vlastník súboru podľa Windows
    Overenie As String        ' verified / unverified
    Poznamka As String
    Stav As String            ' PRIJATE / ODMIETNUTE / CAKA / NEDOKONCENE / DUPLICITA / CHYBA
    KodRazenia As Long
End Type

Private mUcty As String
Private mVlastnik As String
Private mMaxOdchylkaMin As Long
Private mMaxOdlozenieDni As Long
Private mAjDnesne As Boolean
Private mTeraz As Date
Private mDicUcet As Object
Private mFso As Object
Private mFolderObj As Object

Private Sub Pis(ByRef rep As String, ByVal s As String)
    rep = rep & s & vbCrLf
End Sub

'===============================================================================
' Tabuľka a nastavenia
'===============================================================================
Public Sub ZabezpecTabulky(ByRef db As DAO.Database)
    If Not mod_00_Common.TabulkaExistujeDB(db, "KlientRazenia") Then
        db.Execute "CREATE TABLE KlientRazenia (ID AUTOINCREMENT PRIMARY KEY, PrijateKedy DATETIME, Subor TEXT(120), ExterneID TEXT(40), " & _
                   "OsobneCislo TEXT(20), LoginWindows TEXT(64), Pocitac TEXT(63), Kod TEXT(12), Smer TEXT(3), CasRazenia DATETIME, " & _
                   "CasUtc TEXT(20), Odlozene YESNO, Overenie TEXT(12), Stav TEXT(12), Poznamka TEXT(255), Vlastnik TEXT(100))", dbFailOnError
        db.Execute "CREATE INDEX idxKR_ExterneID ON KlientRazenia (ExterneID)", dbFailOnError
        db.Execute "CREATE INDEX idxKR_Stav ON KlientRazenia (Stav)", dbFailOnError
    End If
End Sub

Private Sub PredvolbaNastavenia(ByVal strKluc As String, ByVal strHodnota As String, ByVal strPopis As String)
    If Len(mod_00_Common.GetNastavenie(strKluc, "")) = 0 Then Call mod_00_Common.SetNastavenie(strKluc, strHodnota, strPopis)
End Sub

Public Sub NastavPredvolby()
    Call PredvolbaNastavenia("KlientKontrolaUctu", "PRISNE", "Klient: účet v súbore musí patriť zamestnancovi (PRISNE = odmietnuť, UPOZORNIT = neoverené, VYPNUTE)")
    Call PredvolbaNastavenia("KlientKontrolaVlastnika", "UPOZORNIT", "Klient: vlastník súboru v sieti musí byť ten istý účet (UPOZORNIT = neoverené, PRISNE = odmietnuť, VYPNUTE)")
    Call PredvolbaNastavenia("KlientMaxOdchylkaMin", "10", "Klient: najväčší rozdiel medzi časom razenia a časom vytvorenia súboru na serveri (minúty, 0 = nekontrolovať)")
    Call PredvolbaNastavenia("KlientMaxOdlozenieDni", "3", "Klient: najstaršie odložené razenie (dni), staršie je neoverené")
    Call PredvolbaNastavenia("KlientAjDnesne", "0", "Klient: 1 = prevziať aj razenia dnešného dňa (párovanie obeda a odchodu potrebuje celý deň)")
End Sub

' Základný priečinok bez záverečného lomítka; prázdny reťazec, ak nie je nastavený.
Private Function ZakladPriecinok() As String
    Dim s As String
    s = Trim$(mod_00_Common.GetNastavenie("KlientPriecinok", ""))
    Do While Len(s) > 3 And Right$(s, 1) = "\"
        s = Left$(s, Len(s) - 1)
    Loop
    ZakladPriecinok = s
End Function

Private Sub NacitajNastavenia()
    mUcty = UCase$(Trim$(mod_00_Common.GetNastavenie("KlientKontrolaUctu", "PRISNE")))
    If mUcty <> "UPOZORNIT" And mUcty <> "VYPNUTE" Then mUcty = "PRISNE"
    mVlastnik = UCase$(Trim$(mod_00_Common.GetNastavenie("KlientKontrolaVlastnika", "UPOZORNIT")))
    If mVlastnik <> "PRISNE" And mVlastnik <> "VYPNUTE" Then mVlastnik = "UPOZORNIT"
    mMaxOdchylkaMin = CLng(Val(mod_00_Common.GetNastavenie("KlientMaxOdchylkaMin", "10")))
    If mMaxOdchylkaMin < 0 Then mMaxOdchylkaMin = 0
    mMaxOdlozenieDni = CLng(Val(mod_00_Common.GetNastavenie("KlientMaxOdlozenieDni", "3")))
    If mMaxOdlozenieDni < 0 Then mMaxOdlozenieDni = 0
    mAjDnesne = (Val(mod_00_Common.GetNastavenie("KlientAjDnesne", "0")) = 1)
    mTeraz = Now
    Set mDicUcet = CreateObject("Scripting.Dictionary")
    Set mFso = CreateObject("Scripting.FileSystemObject")
End Sub

'===============================================================================
' Priečinky
'===============================================================================
Private Function VytvorPriecinok(ByVal strCesta As String) As Boolean
    Dim strRodic As String
    On Error GoTo Chyba
    If mFso Is Nothing Then Set mFso = CreateObject("Scripting.FileSystemObject")
    If Right$(strCesta, 1) = "\" Then strCesta = Left$(strCesta, Len(strCesta) - 1)
    If mFso.FolderExists(strCesta) Then
        VytvorPriecinok = True
        Exit Function
    End If
    strRodic = mFso.GetParentFolderName(strCesta)
    If Len(strRodic) > 0 Then
        If Not mFso.FolderExists(strRodic) Then
            If Not VytvorPriecinok(strRodic) Then Exit Function
        End If
    End If
    mFso.CreateFolder strCesta
    VytvorPriecinok = True
    Exit Function
Chyba:
    VytvorPriecinok = False
End Function

Public Function PripravPriecinky() As String
    Dim rep As String, strZaklad As String, v As Variant, strP As String
    On Error GoTo Chyba
    strZaklad = ZakladPriecinok()
    If Len(strZaklad) = 0 Then
        PripravPriecinky = "Nie je nastavený priečinok klienta (nastavenie KlientPriecinok)."
        Exit Function
    End If
    Set mFso = CreateObject("Scripting.FileSystemObject")
    If Not mFso.FolderExists(strZaklad) Then
        PripravPriecinky = "Priečinok " & strZaklad & " neexistuje. Vytvorí ho správca siete spolu s právami (pozri docs/KLIENT-ACCESS.md)."
        Exit Function
    End If
    Pis rep, "Priečinok klienta: " & strZaklad
    For Each v In Array("prijem", "konfiguracia", "spracovane", "chybne")
        strP = strZaklad & "\" & CStr(v)
        If mFso.FolderExists(strP) Then
            Pis rep, "  " & CStr(v) & ": existuje"
        ElseIf VytvorPriecinok(strP) Then
            Pis rep, "  " & CStr(v) & ": vytvorený"
        Else
            Pis rep, "  " & CStr(v) & ": NEPODARILO SA vytvoriť"
        End If
    Next v
    Pis rep, ""
    Pis rep, "Práva nastaví správca siete:"
    Pis rep, "  prijem        zamestnanci (skupina): vytvárať súbory a zapisovať údaje len pre tento priečinok, bez čítania, zmeny a mazania; HR: plný prístup"
    Pis rep, "  konfiguracia  zamestnanci: len čítanie; HR: zápis"
    Pis rep, "  spracovane, chybne  zamestnanci: bez prístupu; HR: plný prístup"
    PripravPriecinky = rep
    Exit Function
Chyba:
    PripravPriecinky = rep & "CHYBA: " & Err.Description
End Function

' Presunie súbor do priečinka (vytvorí ho); pri rovnakom názve pridá poradové číslo. Voliteľný dôvod sa uloží vedľa súboru.
Private Function PresunSubor(ByVal strZ As String, ByVal strDoPriecinka As String, ByVal strDovod As String) As Boolean
    Dim strNazov As String, strCiel As String, n As Long
    On Error GoTo Chyba
    If Right$(strDoPriecinka, 1) <> "\" Then strDoPriecinka = strDoPriecinka & "\"
    If Not VytvorPriecinok(strDoPriecinka) Then Exit Function
    strNazov = Mid$(strZ, InStrRev(strZ, "\") + 1)
    strCiel = strDoPriecinka & strNazov
    Do While mFso.FileExists(strCiel)
        n = n + 1
        strCiel = strDoPriecinka & Left$(strNazov, Len(strNazov) - 4) & "_" & n & ".rzn"
    Loop
    mFso.MoveFile strZ, strCiel
    If Len(strDovod) > 0 Then Call mod_00_Common.UlozUTF8Sustor(strCiel & ".dovod.txt", strDovod)
    PresunSubor = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_22_KlientRazenia.PresunSubor", "WARN", "Súbor " & strZ & " sa nepodarilo presunúť: " & Err.Description)
    PresunSubor = False
End Function

'===============================================================================
' Pomocné kontroly tvaru (zrkadlia tools/klient_protokol.py)
'===============================================================================
Private Function JeCislo(ByVal s As String) As Boolean
    Dim i As Long, c As Long
    If Len(s) = 0 Then Exit Function
    For i = 1 To Len(s)
        c = AscW(Mid$(s, i, 1))
        If c < 48 Or c > 57 Then Exit Function
    Next i
    JeCislo = True
End Function

' Písmená a číslice (ASCII) plus povolené znaky z strDalsie; dĺžka lMin až lMax.
Private Function PlatnyText(ByVal s As String, ByVal lMin As Long, ByVal lMax As Long, ByVal strDalsie As String) As Boolean
    Dim i As Long, c As Long
    If Len(s) < lMin Or Len(s) > lMax Then Exit Function
    For i = 1 To Len(s)
        c = AscW(Mid$(s, i, 1))
        If Not ((c >= 48 And c <= 57) Or (c >= 65 And c <= 90) Or (c >= 97 And c <= 122)) Then
            If InStr(1, strDalsie, Mid$(s, i, 1), vbBinaryCompare) = 0 Then Exit Function
        End If
    Next i
    PlatnyText = True
End Function

' GUID zapísaný veľkými písmenami: 8-4-4-4-12.
Private Function JeGuid(ByVal s As String) As Boolean
    Dim i As Long, c As Long
    If Len(s) <> 36 Then Exit Function
    For i = 1 To 36
        c = AscW(Mid$(s, i, 1))
        Select Case i
            Case 9, 14, 19, 24
                If c <> 45 Then Exit Function
            Case Else
                If Not ((c >= 48 And c <= 57) Or (c >= 65 And c <= 70)) Then Exit Function
        End Select
    Next i
    JeGuid = True
End Function

' Názov kľúča: malé písmená a podčiarkovník, 1 až 20 znakov.
Private Function JeKluc(ByVal s As String) As Boolean
    Dim i As Long, c As Long
    If Len(s) < 1 Or Len(s) > 20 Then Exit Function
    For i = 1 To Len(s)
        c = AscW(Mid$(s, i, 1))
        If Not ((c >= 97 And c <= 122) Or c = 95) Then Exit Function
    Next i
    JeKluc = True
End Function

' Verzia klienta: 1 až 4 skupiny po 1 až 3 číslice oddelené bodkou.
Private Function JeVerzia(ByVal s As String) As Boolean
    Dim p() As String, i As Long
    p = Split(s, ".")
    If UBound(p) < 0 Or UBound(p) > 3 Then Exit Function
    For i = 0 To UBound(p)
        If Len(p(i)) > 3 Then Exit Function
        If Not JeCislo(p(i)) Then Exit Function
    Next i
    JeVerzia = True
End Function

' RRRR-MM-DDTHH:MM:SS -> Date; platný kalendárny a časový údaj.
Private Function ParsujCasRzn(ByVal s As String, ByRef d As Date) As Boolean
    Dim y As Long, mo As Long, dd As Long, h As Long, mi As Long, se As Long, t As Date
    If Len(s) <> 19 Then Exit Function
    If Mid$(s, 5, 1) <> "-" Or Mid$(s, 8, 1) <> "-" Or Mid$(s, 14, 1) <> ":" Or Mid$(s, 17, 1) <> ":" Then Exit Function
    If StrComp(Mid$(s, 11, 1), "T", vbBinaryCompare) <> 0 Then Exit Function
    If Not (JeCislo(Mid$(s, 1, 4)) And JeCislo(Mid$(s, 6, 2)) And JeCislo(Mid$(s, 9, 2)) And JeCislo(Mid$(s, 12, 2)) And JeCislo(Mid$(s, 15, 2)) And JeCislo(Mid$(s, 18, 2))) Then Exit Function
    y = CLng(Mid$(s, 1, 4))
    mo = CLng(Mid$(s, 6, 2))
    dd = CLng(Mid$(s, 9, 2))
    h = CLng(Mid$(s, 12, 2))
    mi = CLng(Mid$(s, 15, 2))
    se = CLng(Mid$(s, 18, 2))
    If y < 1900 Or mo < 1 Or mo > 12 Or dd < 1 Or dd > 31 Or h > 23 Or mi > 59 Or se > 59 Then Exit Function
    t = DateSerial(y, mo, dd)
    If Year(t) <> y Or Month(t) <> mo Or Day(t) <> dd Then Exit Function
    d = t + TimeSerial(h, mi, se)
    ParsujCasRzn = True
End Function

'===============================================================================
' Rozbor súboru .rzn. Vráti dôvod odmietnutia ("" = v poriadku); strKod je stabilný kód chyby (VELKOST, ZNAKY, HLAVICKA, KONIEC,
' KLUC, HODNOTA, CAS, NAZOV). Pravidlá sú rovnaké ako v tools/klient_protokol.py (rozober).
'===============================================================================
Private Function RozoberObsah(ByRef b() As Byte, ByVal lN As Long, ByVal strNazov As String, ByRef r As TKlient, ByRef strKod As String) As String
    Dim lStart As Long, i As Long, strText As String, riadky() As String, nR As Long, dic As Object
    Dim strKluc As String, strHodn As String, p As Long, v As Variant, dCas As Date, dUtc As Date, lRozdiel As Long

    strKod = ""
    If lN > MAX_BAJTOV Then
        strKod = "VELKOST"
        RozoberObsah = "súbor má " & lN & " bajtov (najviac " & MAX_BAJTOV & ")"
        Exit Function
    End If
    If lN >= 3 Then
        If b(0) = &HEF And b(1) = &HBB And b(2) = &HBF Then lStart = 3
    End If
    If lN - lStart <= 0 Then
        strKod = "HLAVICKA"
        RozoberObsah = "prvý riadok musí byť " & HLAVICKA_RZN
        Exit Function
    End If
    For i = lStart To lN - 1
        If b(i) > 127 Then
            strKod = "ZNAKY"
            RozoberObsah = "súbor obsahuje znaky mimo ASCII"
            Exit Function
        End If
        If b(i) < 32 And b(i) <> 10 And b(i) <> 13 Then
            strKod = "ZNAKY"
            RozoberObsah = "súbor obsahuje riadiace znaky"
            Exit Function
        End If
    Next i
    strText = StrConv(b, vbUnicode)
    If lStart > 0 Then strText = Mid$(strText, lStart + 1)
    strText = Replace(strText, vbCr & vbLf, vbLf)
    strText = Replace(strText, vbLf & vbCr, vbLf)
    If InStr(1, strText, vbCr, vbBinaryCompare) > 0 Then
        strKod = "ZNAKY"
        RozoberObsah = "samotný znak CR v súbore"
        Exit Function
    End If
    riadky = Split(strText, vbLf)
    nR = UBound(riadky) + 1
    Do While nR > 0
        If Len(riadky(nR - 1)) > 0 Then Exit Do
        nR = nR - 1
    Loop
    If nR = 0 Then
        strKod = "HLAVICKA"
        RozoberObsah = "prvý riadok musí byť " & HLAVICKA_RZN
        Exit Function
    End If
    If StrComp(riadky(0), HLAVICKA_RZN, vbBinaryCompare) <> 0 Then
        strKod = "HLAVICKA"
        RozoberObsah = "prvý riadok musí byť " & HLAVICKA_RZN
        Exit Function
    End If
    If StrComp(riadky(nR - 1), KONIEC_RZN, vbBinaryCompare) <> 0 Then
        strKod = "KONIEC"
        RozoberObsah = "súbor nekončí riadkom " & KONIEC_RZN & " (nedopísaný alebo poškodený)"
        Exit Function
    End If
    For i = 1 To nR - 2
        If StrComp(riadky(i), KONIEC_RZN, vbBinaryCompare) = 0 Then
            strKod = "KONIEC"
            RozoberObsah = "riadok " & KONIEC_RZN & " sa nachádza pred koncom súboru"
            Exit Function
        End If
    Next i

    Set dic = CreateObject("Scripting.Dictionary")
    For i = 1 To nR - 2
        p = InStr(1, riadky(i), "=", vbBinaryCompare)
        If p = 0 Then
            strKod = "KLUC"
            RozoberObsah = "riadok " & (i + 1) & " nemá tvar kluc=hodnota"
            Exit Function
        End If
        strKluc = Left$(riadky(i), p - 1)
        strHodn = Mid$(riadky(i), p + 1)
        If Not JeKluc(strKluc) Then
            strKod = "KLUC"
            RozoberObsah = "riadok " & (i + 1) & ": neplatný názov kľúča"
            Exit Function
        End If
        If dic.Exists(strKluc) Then
            strKod = "KLUC"
            RozoberObsah = "kľúč " & strKluc & " je v súbore viackrát"
            Exit Function
        End If
        dic.Add strKluc, strHodn
    Next i
    For Each v In Array("id", "oc", "login", "pc", "kod", "smer", "cas", "utc", "odlozene", "klient")
        If Not dic.Exists(CStr(v)) Then
            strKod = "KLUC"
            RozoberObsah = "chýba povinný kľúč " & CStr(v)
            Exit Function
        End If
    Next v

    strKod = "HODNOTA"
    If Not JeGuid(CStr(dic("id"))) Then RozoberObsah = "id nie je GUID zapísaný veľkými písmenami": Exit Function
    If Not PlatnyText(CStr(dic("oc")), 1, 20, "") Then RozoberObsah = "oc má byť 1 až 20 písmen alebo číslic": Exit Function
    If Not PlatnyText(CStr(dic("login")), 1, 64, "._-") Then RozoberObsah = "login má neplatné znaky alebo dĺžku": Exit Function
    If Not PlatnyText(CStr(dic("pc")), 1, 63, "._-") Then RozoberObsah = "pc má neplatné znaky alebo dĺžku": Exit Function
    If Not PlatnyText(CStr(dic("kod")), 1, 20, "") Then RozoberObsah = "kód má neplatné znaky": Exit Function
    If InStr(1, KODY_RZN, "|" & CStr(dic("kod")) & "|", vbBinaryCompare) = 0 Then RozoberObsah = "kód '" & CStr(dic("kod")) & "' nie je zo zoznamu WORK, DOCTOR, TRIP, FAMILY, LEAVE, SICK, PRIV, ERRAND": Exit Function
    If StrComp(CStr(dic("smer")), "IN", vbBinaryCompare) <> 0 And StrComp(CStr(dic("smer")), "OUT", vbBinaryCompare) <> 0 Then RozoberObsah = "smer musí byť IN alebo OUT": Exit Function
    If StrComp(CStr(dic("odlozene")), "0", vbBinaryCompare) <> 0 And StrComp(CStr(dic("odlozene")), "1", vbBinaryCompare) <> 0 Then RozoberObsah = "odlozene musí byť 0 alebo 1": Exit Function
    If Not JeVerzia(CStr(dic("klient"))) Then RozoberObsah = "klient má neplatnú verziu": Exit Function
    strKod = "CAS"
    If Not ParsujCasRzn(CStr(dic("cas")), dCas) Then RozoberObsah = "cas nemá platný tvar RRRR-MM-DDTHH:MM:SS: '" & CStr(dic("cas")) & "'": Exit Function
    If Not ParsujCasRzn(CStr(dic("utc")), dUtc) Then RozoberObsah = "utc nemá platný tvar RRRR-MM-DDTHH:MM:SS: '" & CStr(dic("utc")) & "'": Exit Function
    lRozdiel = CLng(DateDiff("s", dUtc, dCas))
    If lRozdiel <> 3600 And lRozdiel <> 7200 Then RozoberObsah = "rozdiel cas - utc je " & lRozdiel & " s (v Bratislave je 3600 alebo 7200)": Exit Function

    ' názov súboru: RRRRMMDD-HHMMSS_<ID>.rzn
    strKod = "NAZOV"
    If Len(strNazov) <> 56 Then RozoberObsah = "názov súboru nemá tvar RRRRMMDD-HHMMSS_<ID>.rzn": Exit Function
    If Not (JeCislo(Left$(strNazov, 8)) And Mid$(strNazov, 9, 1) = "-" And JeCislo(Mid$(strNazov, 10, 6)) And Mid$(strNazov, 16, 1) = "_" And StrComp(Right$(strNazov, 4), ".rzn", vbBinaryCompare) = 0) Then
        RozoberObsah = "názov súboru nemá tvar RRRRMMDD-HHMMSS_<ID>.rzn"
        Exit Function
    End If
    If StrComp(Mid$(strNazov, 17, 36), CStr(dic("id")), vbBinaryCompare) <> 0 Then RozoberObsah = "ID v názve súboru sa nezhoduje s id v súbore": Exit Function
    If Left$(strNazov, 8) & Mid$(strNazov, 10, 6) <> Format$(dCas, "yyyymmddhhnnss") Then RozoberObsah = "čas v názve súboru sa nezhoduje s cas v súbore": Exit Function

    strKod = ""
    r.ExterneID = CStr(dic("id"))
    r.Osc = CStr(dic("oc"))
    r.LoginWin = CStr(dic("login"))
    r.Pocitac = CStr(dic("pc"))
    r.Kod = CStr(dic("kod"))
    r.Smer = CStr(dic("smer"))
    r.Lokalny = dCas
    r.CasUtc = CStr(dic("utc"))
    r.Odlozene = (CStr(dic("odlozene")) = "1")
    r.Obsah = Join(riadky, vbLf)
End Function

'===============================================================================
' Súbor, vlastník, čas
'===============================================================================
' Počet bajtov súboru; väčší než MAX_BAJTOV sa nečíta. -1 = súbor sa nepodarilo prečítať (používa ho iný proces).
Private Function CitajSubor(ByVal strCesta As String, ByRef b() As Byte) As Long
    Dim f As Integer, n As Long
    On Error GoTo Chyba
    n = FileLen(strCesta)
    If n > MAX_BAJTOV Then
        CitajSubor = n
        Exit Function
    End If
    If n > 0 Then
        f = FreeFile
        Open strCesta For Binary Access Read Shared As #f
        ReDim b(0 To n - 1)
        Get #f, 1, b
        Close #f
    End If
    CitajSubor = n
    Exit Function
Chyba:
    On Error Resume Next
    If f > 0 Then Close #f
    CitajSubor = -1
End Function

Private Function VekSuboruSek(ByVal strCesta As String) As Long
    On Error GoTo Chyba
    VekSuboruSek = CLng(DateDiff("s", FileDateTime(strCesta), mTeraz))
    Exit Function
Chyba:
    VekSuboruSek = 999999
End Function

' Čas vytvorenia súboru na serveri (0 = nezistený).
Private Function DatumVytvorenia(ByVal strCesta As String) As Date
    On Error GoTo Chyba
    DatumVytvorenia = mFso.GetFile(strCesta).DateCreated
    Exit Function
Chyba:
    DatumVytvorenia = 0
End Function

Private Sub OtvorPriecinokShell(ByVal strPriecinok As String)
    Dim sh As Object
    Set mFolderObj = Nothing
    If Right$(strPriecinok, 1) = "\" Then strPriecinok = Left$(strPriecinok, Len(strPriecinok) - 1)
    On Error Resume Next
    Set sh = CreateObject("Shell.Application")
    Set mFolderObj = sh.Namespace(CVar(strPriecinok))
    Err.Clear
End Sub

' Vlastník súboru ako ho ukazuje Windows (stĺpec "Vlastník" v Prieskumníkovi, funguje aj pre sieťové cesty). "" = nezistený.
Private Function VlastnikSuboru(ByVal strNazov As String) As String
    Dim it As Object
    On Error GoTo Chyba
    If mFolderObj Is Nothing Then Exit Function
    Set it = mFolderObj.ParseName(strNazov)
    If it Is Nothing Then Exit Function
    VlastnikSuboru = Trim$(CStr(mFolderObj.GetDetailsOf(it, 10)))
    Exit Function
Chyba:
    VlastnikSuboru = ""
End Function

Public Function UkazVlastnika(ByVal strCesta As String) As String
    Dim p As Long, strAdr As String
    p = InStrRev(strCesta, "\")
    If p = 0 Then
        UkazVlastnika = "Zadajte úplnú cestu k súboru."
        Exit Function
    End If
    strAdr = Left$(strCesta, p - 1)
    Call OtvorPriecinokShell(strAdr)
    UkazVlastnika = "Vlastník: '" & VlastnikSuboru(Mid$(strCesta, p + 1)) & "'  (prihlásený účet: " & Environ$("USERNAME") & ")"
End Function

Private Function KontrolaVlastnika(ByVal strVlastnik As String, ByVal strLogin As String) As String
    Dim s As String, p As Long
    If Len(strVlastnik) = 0 Then
        KontrolaVlastnika = "vlastníka súboru sa nepodarilo zistiť"
        Exit Function
    End If
    s = strVlastnik
    If Right$(s, 1) = ")" Then s = Left$(s, Len(s) - 1)
    p = InStrRev(s, "\")
    If p > 0 Then s = Mid$(s, p + 1)
    If StrComp(s, strLogin, vbTextCompare) <> 0 Then
        KontrolaVlastnika = "súbor vytvoril iný účet (" & strVlastnik & ") než je v súbore (" & strLogin & ")"
    End If
End Function

Private Function KontrolaUctu(ByVal strLogin As String, ByVal strOsc As String) As String
    Dim k As String, strVysl As String
    k = LCase$(strLogin) & "|" & strOsc
    If mDicUcet.Exists(k) Then
        KontrolaUctu = CStr(mDicUcet(k))
        Exit Function
    End If
    If DCount("*", "Zamestnanci", "LoginAD = " & mod_00_Common.SqlText(strLogin) & " AND OsobneCislo = " & mod_00_Common.SqlText(strOsc)) > 0 Then
        strVysl = ""
    ElseIf DCount("*", "Zamestnanci", "OsobneCislo = " & mod_00_Common.SqlText(strOsc)) = 0 Then
        strVysl = "osobné číslo " & strOsc & " nie je v zozname zamestnancov"
    ElseIf DCount("*", "Zamestnanci", "LoginAD = " & mod_00_Common.SqlText(strLogin)) = 0 Then
        strVysl = "účet " & strLogin & " nie je priradený žiadnemu zamestnancovi (Zamestnanci.LoginAD)"
    Else
        strVysl = "účet " & strLogin & " patrí inému osobnému číslu než " & strOsc
    End If
    mDicUcet(k) = strVysl
    KontrolaUctu = strVysl
End Function

' Prerušenie a smer, ktoré zodpovedajú kódu razenia Accessu (pre prehľad nanečisto), napríklad "č. 7 Z".
Private Function PopisKoduRazenia(ByVal lKod As Long) As String
    Dim rs As DAO.Recordset
    On Error GoTo Chyba
    Set rs = CurrentDb.OpenRecordset("SELECT CisloPreruseni, Smer FROM KodyRazeni WHERE KodRazenia = " & lKod & ";", dbOpenSnapshot)
    If Not rs.EOF Then PopisKoduRazenia = "č. " & CLng(Nz(rs!CisloPreruseni, 0)) & " " & CStr(Nz(rs!Smer, ""))
    rs.Close
    Exit Function
Chyba:
    PopisKoduRazenia = ""
End Function

Private Sub Neoverene(ByRef r As TKlient, ByVal strDovod As String)
    r.Overenie = "unverified"
    If Len(r.Poznamka) > 0 Then r.Poznamka = r.Poznamka & "; "
    r.Poznamka = Left$(r.Poznamka & strDovod, 255)
End Sub

'===============================================================================
' Príprava jedného súboru: rozbor a kontroly. Nastaví r.Stav (PRIJATE = kandidát na prevod, ODMIETNUTE, CAKA, NEDOKONCENE, DUPLICITA).
'===============================================================================
Private Sub PripravSubor(ByRef r As TKlient, ByVal strPrijem As String, ByVal strNazov As String)
    Dim b() As Byte, lN As Long, strKod As String, strChyba As String, dtVytv As Date, lRozdiel As Long
    r.Subor = strNazov
    r.Cesta = strPrijem & strNazov
    r.Overenie = "verified"
    r.Stav = ""

    lN = CitajSubor(r.Cesta, b)
    If lN < 0 Then
        r.Stav = "NEDOKONCENE"
        r.Poznamka = "súbor sa nepodarilo prečítať (používa ho iný proces), skúsi sa znova"
        Exit Sub
    End If
    strChyba = RozoberObsah(b, lN, strNazov, r, strKod)
    If Len(strChyba) > 0 Then
        If strKod = "KONIEC" Then
            ' nedopísaný súbor chvíľu počká (klient ho práve zapisuje)
            If VekSuboruSek(r.Cesta) < NEDOKONCENY_SEK Then
                r.Stav = "NEDOKONCENE"
                r.Poznamka = "súbor ešte nie je dopísaný, skúsi sa znova"
                Exit Sub
            End If
        End If
        r.Stav = "ODMIETNUTE"
        r.Poznamka = Left$(strKod & ": " & strChyba, 255)
        Exit Sub
    End If

    If DCount("*", "TerminalInbox", "ExterneID = " & mod_00_Common.SqlText("KL-" & r.ExterneID)) > 0 Then
        r.Stav = "DUPLICITA"
        r.Poznamka = "razenie s týmto id je už prijaté"
        Exit Sub
    End If

    If mUcty <> "VYPNUTE" Then
        strChyba = KontrolaUctu(r.LoginWin, r.Osc)
        If Len(strChyba) > 0 Then
            If mUcty = "PRISNE" Then
                r.Stav = "ODMIETNUTE"
                r.Poznamka = Left$("ÚČET: " & strChyba, 255)
                Exit Sub
            End If
            Call Neoverene(r, strChyba)
        End If
    End If

    If mVlastnik <> "VYPNUTE" Then
        r.Vlastnik = VlastnikSuboru(strNazov)
        strChyba = KontrolaVlastnika(r.Vlastnik, r.LoginWin)
        If Len(strChyba) > 0 Then
            If mVlastnik = "PRISNE" Then
                r.Stav = "ODMIETNUTE"
                r.Poznamka = Left$("VLASTNÍK: " & strChyba, 255)
                Exit Sub
            End If
            Call Neoverene(r, strChyba)
        End If
    End If

    ' razenie v budúcnosti (hodiny počítača) sa neprijme
    If r.Lokalny > DateAdd("n", IIf(mMaxOdchylkaMin < 5, 5, mMaxOdchylkaMin), mTeraz) Then
        r.Stav = "ODMIETNUTE"
        r.Poznamka = "ČAS: čas razenia je v budúcnosti (hodiny počítača zamestnanca)"
        Exit Sub
    End If
    If mMaxOdchylkaMin > 0 Then
        dtVytv = DatumVytvorenia(r.Cesta)
        If dtVytv = 0 Then
            Call Neoverene(r, "čas vytvorenia súboru na serveri sa nezistil")
        Else
            lRozdiel = CLng(DateDiff("n", r.Lokalny, dtVytv))
            If Not r.Odlozene Then
                If Abs(lRozdiel) > mMaxOdchylkaMin Then Call Neoverene(r, "čas razenia sa líši od času vytvorenia súboru o " & Abs(lRozdiel) & " min")
            Else
                If lRozdiel < -mMaxOdchylkaMin Then Call Neoverene(r, "odložené razenie je novšie než súbor o " & Abs(lRozdiel) & " min")
                If lRozdiel > mMaxOdlozenieDni * 1440 Then Call Neoverene(r, "odložené razenie je staré " & (lRozdiel \ 1440) & " dní")
            End If
        End If
    End If

    ' razenia dnešného dňa čakajú: párovanie príchodu, obeda a odchodu potrebuje celý deň
    If Not mAjDnesne Then
        If Int(r.Lokalny) >= Int(mTeraz) Then
            r.Stav = "CAKA"
            Exit Sub
        End If
    End If

    ' razenie za deň, ktorý sa už prevzal: poradie (obed alebo odchod) sa mohlo posunúť, treba skontrolovať
    If DCount("*", "KlientRazenia", "OsobneCislo = " & mod_00_Common.SqlText(r.Osc) & " AND Stav = 'PRIJATE' AND CasRazenia >= " & _
              mod_00_Common.SqlDatum(Int(r.Lokalny)) & " AND CasRazenia < " & mod_00_Common.SqlDatum(Int(r.Lokalny) + 1)) > 0 Then
        Call Neoverene(r, "doručené po prevzatí razení toho dňa, skontrolujte poradie v editore dňa")
    End If
    r.Stav = "PRIJATE"
End Sub

Private Sub ZapisKlientRazenia(ByRef db As DAO.Database, ByRef r As TKlient, ByVal strStav As String)
    Dim rs As DAO.Recordset
    On Error GoTo Chyba
    Set rs = db.OpenRecordset("KlientRazenia", dbOpenDynaset, dbAppendOnly)
    rs.AddNew
    rs!PrijateKedy = Now
    rs!Subor = Left$(r.Subor, 120)
    If Len(r.ExterneID) > 0 Then rs!ExterneID = Left$(r.ExterneID, 40)
    If Len(r.Osc) > 0 Then rs!OsobneCislo = Left$(r.Osc, 20)
    If Len(r.LoginWin) > 0 Then rs!LoginWindows = Left$(r.LoginWin, 64)
    If Len(r.Pocitac) > 0 Then rs!Pocitac = Left$(r.Pocitac, 63)
    If Len(r.Kod) > 0 Then rs!Kod = Left$(r.Kod, 12)
    If Len(r.Smer) > 0 Then rs!Smer = Left$(r.Smer, 3)
    If r.Lokalny > 0 Then rs!CasRazenia = r.Lokalny
    If Len(r.CasUtc) > 0 Then rs!CasUtc = Left$(r.CasUtc, 20)
    rs!Odlozene = r.Odlozene
    rs!Overenie = Left$(r.Overenie, 12)
    rs!Stav = Left$(strStav, 12)
    If Len(r.Poznamka) > 0 Then rs!Poznamka = Left$(r.Poznamka, 255)
    If Len(r.Vlastnik) > 0 Then rs!Vlastnik = Left$(r.Vlastnik, 100)
    rs.Update
    rs.Close
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_22_KlientRazenia.ZapisKlientRazenia", "ERROR", Err.Description)
End Sub

'===============================================================================
' Príjem razení z klientov
'===============================================================================
Public Function PrijmiKlientskeRazenia(Optional ByVal bNanecisto As Boolean = False) As String
    On Error GoTo Chyba
    Dim rep As String, db As DAO.Database, strZaklad As String, strPrijem As String
    Dim nazvy() As String, nSub As Long, strNazov As String, i As Long, j As Long
    Dim r() As TKlient
    Dim cOs() As String, cKod() As String, cSmer() As String, cLok() As Date, cUtc() As String, cIx() As Long, kodR() As Long, chyb() As String
    Dim nC As Long, nNeov As Long, nOdm As Long, nCaka As Long, nNedok As Long, nDup As Long, nPrijato As Long, nSpracChyb As Long
    Dim lID As Long, nBezPresunu As Long, nVlastnikNezist As Long, kolko As Long

    Pis rep, "Príjem razení z klientov: " & Format$(Now, "yyyy\-mm\-dd hh:nn:ss") & IIf(bNanecisto, "   [NANEČISTO - nič sa nezapíše ani nepresunie]", "")
    strZaklad = ZakladPriecinok()
    If Len(strZaklad) = 0 Then
        Pis rep, "CHYBA: nie je nastavený priečinok klienta (nastavenie KlientPriecinok)."
        PrijmiKlientskeRazenia = rep
        Exit Function
    End If
    Call NastavPredvolby
    Call NacitajNastavenia
    strPrijem = strZaklad & "\prijem\"
    If Not mFso.FolderExists(strPrijem) Then
        Pis rep, "CHYBA: priečinok " & strPrijem & " neexistuje alebo k nemu nie je prístup (PripravPriecinky ho vytvorí)."
        PrijmiKlientskeRazenia = rep
        Exit Function
    End If
    Set db = CurrentDb
    Call ZabezpecTabulky(db)
    Call mod_19_TerminalImport.ZabezpecTabulky(db)
    Call mod_12_TerminalPriprava.ZabezpecTabulky(db)

    ReDim nazvy(0 To 255)
    strNazov = Dir(strPrijem & "*.rzn")
    Do While Len(strNazov) > 0
        If nSub > UBound(nazvy) Then ReDim Preserve nazvy(0 To UBound(nazvy) + 256)
        nazvy(nSub) = strNazov
        nSub = nSub + 1
        strNazov = Dir
    Loop
    Pis rep, "Súborov .rzn v priečinku prijem: " & nSub
    Pis rep, "Nastavenia: kontrola účtu " & mUcty & ", vlastník súboru " & mVlastnik & ", odchýlka času " & IIf(mMaxOdchylkaMin = 0, "nekontroluje sa", mMaxOdchylkaMin & " min") & ", dnešné razenia " & IIf(mAjDnesne, "sa preberú", "čakajú")
    If nSub = 0 Then
        PrijmiKlientskeRazenia = rep
        Exit Function
    End If

    If mVlastnik <> "VYPNUTE" Then Call OtvorPriecinokShell(strPrijem)
    ReDim r(0 To nSub - 1)
    For i = 0 To nSub - 1
        Call PripravSubor(r(i), strPrijem, nazvy(i))
        If i Mod 100 = 99 Then DoEvents
    Next i

    ' prevod na prerušenia a kódy razenia (párovanie za deň, ako pri termináli)
    ReDim cOs(0 To nSub - 1)
    ReDim cKod(0 To nSub - 1)
    ReDim cSmer(0 To nSub - 1)
    ReDim cLok(0 To nSub - 1)
    ReDim cUtc(0 To nSub - 1)
    ReDim cIx(0 To nSub - 1)
    For i = 0 To nSub - 1
        If r(i).Stav = "PRIJATE" Then
            cOs(nC) = r(i).Osc
            cKod(nC) = r(i).Kod
            cSmer(nC) = r(i).Smer
            cLok(nC) = r(i).Lokalny
            cUtc(nC) = r(i).CasUtc
            cIx(nC) = i
            nC = nC + 1
        End If
    Next i
    If nC > 0 Then
        ReDim kodR(0 To nC - 1)
        ReDim chyb(0 To nC - 1)
        Call mod_19_TerminalImport.PrevedRazeniaKlienta(cOs, cKod, cSmer, cLok, cUtc, nC, kodR, chyb)
        For j = 0 To nC - 1
            If Len(chyb(j)) > 0 Then
                r(cIx(j)).Stav = "ODMIETNUTE"
                r(cIx(j)).Poznamka = Left$("PÁROVANIE: " & chyb(j), 255)
            Else
                r(cIx(j)).KodRazenia = kodR(j)
            End If
        Next j
    End If

    ' zápis (alebo len prehľad nanečisto)
    For i = 0 To nSub - 1
        Select Case r(i).Stav
            Case "PRIJATE"
                If bNanecisto Then
                    nPrijato = nPrijato + 1
                    If r(i).Overenie = "unverified" Then nNeov = nNeov + 1
                Else
                    lID = mod_12_TerminalPriprava.PrijmiRazenie("KL-" & r(i).ExterneID, r(i).Osc, r(i).Lokalny, r(i).KodRazenia, _
                                                               Left$("klient " & r(i).Pocitac, 30), r(i).Obsah, r(i).Overenie, r(i).Pocitac)
                    If lID < 0 Then
                        r(i).Stav = "CHYBA"
                        r(i).Poznamka = "razenie sa nepodarilo uložiť do fronty (pozri protokol), súbor ostal v priečinku prijem"
                        nSpracChyb = nSpracChyb + 1
                    Else
                        nPrijato = nPrijato + 1
                        If r(i).Overenie = "unverified" Then nNeov = nNeov + 1
                        Call ZapisKlientRazenia(db, r(i), "PRIJATE")
                        If Not PresunSubor(r(i).Cesta, strZaklad & "\spracovane\" & Format$(r(i).Lokalny, "yyyy\-mm"), "") Then nBezPresunu = nBezPresunu + 1
                    End If
                End If
            Case "ODMIETNUTE"
                nOdm = nOdm + 1
                If Not bNanecisto Then
                    Call ZapisKlientRazenia(db, r(i), "ODMIETNUTE")
                    If Not PresunSubor(r(i).Cesta, strZaklad & "\chybne", r(i).Poznamka) Then nBezPresunu = nBezPresunu + 1
                End If
            Case "DUPLICITA"
                nDup = nDup + 1
                If Not bNanecisto Then
                    If Not PresunSubor(r(i).Cesta, strZaklad & "\spracovane\duplicity", "") Then nBezPresunu = nBezPresunu + 1
                End If
            Case "CAKA"
                nCaka = nCaka + 1
            Case "NEDOKONCENE"
                nNedok = nNedok + 1
        End Select
        If Len(r(i).Vlastnik) = 0 And mVlastnik <> "VYPNUTE" And (r(i).Stav = "PRIJATE" Or r(i).Stav = "ODMIETNUTE") Then nVlastnikNezist = nVlastnikNezist + 1
    Next i

    Pis rep, "Výsledok: prijatých " & nPrijato & " (z toho neoverených " & nNeov & "), odmietnutých " & nOdm & ", čakajú na ďalší deň " & nCaka & _
             ", nedopísaných " & nNedok & ", duplicít " & nDup & IIf(nSpracChyb > 0, ", chýb zápisu " & nSpracChyb, "")
    If nBezPresunu > 0 Then Pis rep, "UPOZORNENIE: " & nBezPresunu & " súborov sa nepodarilo presunúť (práva na priečinky spracovane a chybne?). Pri ďalšom behu sa rozpoznajú ako duplicity."
    If nVlastnikNezist > 0 Then Pis rep, "UPOZORNENIE: vlastníka sa nepodarilo zistiť pri " & nVlastnikNezist & " súboroch (pozri UkazVlastnika). Ak sa to opakuje, nastavte KlientKontrolaVlastnika = VYPNUTE."
    If nNeov > 0 Then
        Pis rep, "NEOVERENÉ razenia (počítajú sa, ale skontrolujte ich pred uzávierkou mesiaca):"
        kolko = 0
        For i = 0 To nSub - 1
            If r(i).Stav = "PRIJATE" And r(i).Overenie = "unverified" Then
                kolko = kolko + 1
                If kolko <= 20 Then Pis rep, "  " & r(i).Osc & " " & Format$(r(i).Lokalny, "yyyy\-mm\-dd hh:nn:ss") & " " & r(i).Kod & "/" & r(i).Smer & ": " & r(i).Poznamka
            End If
        Next i
        If kolko > 20 Then Pis rep, "  ... ďalších " & (kolko - 20) & " (všetky sú v tabuľke KlientRazenia, Overenie = unverified)"
    End If
    If nOdm > 0 Then
        Pis rep, "ODMIETNUTÉ súbory (ostali v priečinku chybne s dôvodom; po oprave ich vráťte do prijem):"
        kolko = 0
        For i = 0 To nSub - 1
            If r(i).Stav = "ODMIETNUTE" Then
                kolko = kolko + 1
                If kolko <= 20 Then Pis rep, "  " & r(i).Subor & ": " & r(i).Poznamka
            End If
        Next i
        If kolko > 20 Then Pis rep, "  ... ďalších " & (kolko - 20)
    End If
    If bNanecisto Then
        Pis rep, "Prehľad prevodu (poradie: súbor):"
        kolko = 0
        For i = 0 To nSub - 1
            If r(i).Stav = "PRIJATE" Then
                kolko = kolko + 1
                If kolko <= 60 Then
                    Pis rep, "  " & r(i).Osc & " " & Format$(r(i).Lokalny, "yyyy\-mm\-dd hh:nn:ss") & "  " & r(i).Kod & "/" & r(i).Smer & "  ->  " & PopisKoduRazenia(r(i).KodRazenia) & _
                             "  kód razenia " & r(i).KodRazenia & IIf(r(i).Overenie = "unverified", "  NEOVERENÉ", "")
                End If
            End If
        Next i
        If kolko > 60 Then Pis rep, "  ... ďalších " & (kolko - 60) & " sa nevypisuje"
        Pis rep, "Nanečisto: do databázy sa nič nezapísalo a žiadny súbor sa nepresunul."
    ElseIf nPrijato > 0 Then
        Pis rep, mod_12_TerminalPriprava.SpracujInbox()
    End If
    PrijmiKlientskeRazenia = rep
    Exit Function
Chyba:
    PrijmiKlientskeRazenia = rep & "CHYBA príjmu: " & Err.Number & " " & Err.Description
    Call mod_00_Common.ZapisLog("mod_22_KlientRazenia.PrijmiKlientskeRazenia", "ERROR", Err.Description)
End Function

'===============================================================================
' Konfigurácia pre klienta: tlačidlá podľa číselníka prerušení (rovnaké ako v termináli) a kódy z TerminalMapaKodov.
' Súbor konfiguracia\klient_konfig.txt je text UTF-8 bez osobných údajov:
'   DOCHSKLIENT;1 / vytvorene=RRRR-MM-DDTHH:MM:SS / odchod_bez_dovodu=OBED|ODCHOD / tlacidlo=poradie;KOD;text;ikona / #END
' Príchod a odchod má klient vždy; tlačidlo prerušenia zapíše razenie KOD/OUT, jeho koniec je Príchod.
'===============================================================================
Public Function GenerujKonfiguraciuKlienta() As String
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset, strZaklad As String, s As String, strCesta As String
    Dim dicKod As Object, c As Long, strKod As String, strText As String, strIkona As String, n As Long, nBezKodu As Long, strBezKodu As String

    strZaklad = ZakladPriecinok()
    If Len(strZaklad) = 0 Then
        GenerujKonfiguraciuKlienta = "CHYBA: nie je nastavený priečinok klienta (nastavenie KlientPriecinok)."
        Exit Function
    End If
    Set mFso = CreateObject("Scripting.FileSystemObject")
    If Not mFso.FolderExists(strZaklad) Then
        GenerujKonfiguraciuKlienta = "CHYBA: priečinok " & strZaklad & " neexistuje."
        Exit Function
    End If
    Set db = CurrentDb
    Call mod_19_TerminalImport.ZabezpecTabulky(db)
    If Not mod_00_Common.PoleExistujeDB(db, "CiselnikPreruseni", "TerminalTlacidlo") Then
        GenerujKonfiguraciuKlienta = "CHYBA: číselník prerušení nemá stĺpce tlačidiel (spustite aktualizáciu dátového modelu)."
        Exit Function
    End If

    Set dicKod = CreateObject("Scripting.Dictionary")
    Set rs = db.OpenRecordset("SELECT Kod, CisloPreruseni FROM TerminalMapaKodov ORDER BY Kod;", dbOpenSnapshot)
    Do While Not rs.EOF
        c = CLng(Nz(rs!CisloPreruseni, 0))
        If Not dicKod.Exists(c) Then dicKod.Add c, UCase$(Trim$(CStr(Nz(rs!Kod, ""))))
        rs.MoveNext
    Loop
    rs.Close

    s = "DOCHSKLIENT;1" & vbCrLf
    s = s & "vytvorene=" & Format$(Now, "yyyy\-mm\-dd\Thh:nn:ss") & vbCrLf
    s = s & "odchod_bez_dovodu=" & IIf(UCase$(mod_00_Common.GetNastavenie("TerminalOdchodBezDovodu", "OBED")) = "ODCHOD", "ODCHOD", "OBED") & vbCrLf
    Set rs = db.OpenRecordset("SELECT Cislo, Nazov, TerminalText, TerminalPoradie, TerminalIkona FROM CiselnikPreruseni WHERE TerminalTlacidlo = True AND Cislo <> 1 " & _
                              "ORDER BY TerminalPoradie, Cislo;", dbOpenSnapshot)
    Do While Not rs.EOF
        c = CLng(Nz(rs!Cislo, 0))
        If dicKod.Exists(c) Then
            strKod = CStr(dicKod(c))
            strText = Replace(mod_10_Konfiguracia.TextTlacidla(CStr(Nz(rs!TerminalText, "")), CStr(Nz(rs!Nazov, ""))), ";", ",")
            strText = Left$(strText, 24)
            strIkona = LCase$(Trim$(CStr(Nz(rs!TerminalIkona, ""))))
            n = n + 1
            s = s & "tlacidlo=" & n & ";" & strKod & ";" & strText & ";" & strIkona & vbCrLf
        Else
            nBezKodu = nBezKodu + 1
            strBezKodu = strBezKodu & c & " "
        End If
        rs.MoveNext
    Loop
    rs.Close
    s = s & KONIEC_RZN & vbCrLf

    strCesta = strZaklad & "\konfiguracia"
    If Not VytvorPriecinok(strCesta) Then
        GenerujKonfiguraciuKlienta = "CHYBA: priečinok " & strCesta & " sa nepodarilo vytvoriť."
        Exit Function
    End If
    Call mod_00_Common.UlozUTF8Sustor(strCesta & "\klient_konfig.txt", s)
    GenerujKonfiguraciuKlienta = "Konfigurácia klienta uložená: " & strCesta & "\klient_konfig.txt (tlačidiel prerušení: " & n & ")." & _
        IIf(nBezKodu > 0, vbCrLf & "UPOZORNENIE: prerušenia " & Trim$(strBezKodu) & " majú tlačidlo, ale chýba im kód v TerminalMapaKodov, v klientovi nebudú.", "")
    Exit Function
Chyba:
    GenerujKonfiguraciuKlienta = "CHYBA konfigurácie klienta: " & Err.Number & " " & Err.Description
    Call mod_00_Common.ZapisLog("mod_22_KlientRazenia.GenerujKonfiguraciuKlienta", "ERROR", Err.Description)
End Function
