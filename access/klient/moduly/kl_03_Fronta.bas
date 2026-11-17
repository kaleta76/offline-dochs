Attribute VB_Name = "kl_03_Fronta"
'@Verzia 1.0.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: kl_03_Fronta
' POPIS: Lokálny záznam razení a ich odosielanie na server. Razenie je súbor .rzn: najprv sa zapíše do lokálnej fronty
'        (razenia\fronta), potom sa klient pokúsi vytvoriť rovnomenný súbor v <zaklad>\prijem. Po doručení sa odoslaný text uloží
'        do razenia\odoslane\RRRR-MM a až potom sa zmaže z fronty. Ak program padne medzi tým, ďalší pokus dostane chybu 58
'        (súbor už existuje) a razenie sa zaradí ako doručené; nezdvojí sa (HR navyše pozná id).
'
'        PRAVIDLÁ, KTORÉ SA NESMÚ PORUŠIŤ:
'          - súbor na serveri sa vytvára LEN AKO NOVÝ (CreateTextFile bez prepísania) a celý jedným zápisom; nikdy sa neprepisuje,
'            nedopĺňa po riadkoch a z prijem sa nič nemaže;
'          - fronta sa nikdy nemaže automaticky (maže sa len súbor, ktorý je doručený a uložený v odoslane);
'          - pokus priamo pri razení má odlozene=0, každý ďalší pokus (časovač, štart) odlozene=1; text sa zostaví znova
'            z rovnakého id, cas a utc, súbor vo fronte ostáva s odlozene=0.
'
'        Výsledok pokusu podľa čísla chyby (VysledokOdoslania, čistá funkcia; tabuľku overuje tools/test_klient_zhoda.py):
'          0 DORUCENE | 58 EXISTUJE (doručené skôr) | 52 53 57 67 68 71 75 76 NEDOSTUPNY (server, sieť, cesta) |
'          70 PRISTUP (práva alebo existujúci súbor, nejasné) | iné INA
'        Po 5 po sebe idúcich výsledkoch PRISTUP alebo INA má okno ukázať upozornenie (ProblemSOdoslanim).
'        Skutočné čísla chýb pri právach "odkladacia schránka" sú NEOVERENÉ; preto sa každé číslo chyby loguje.
'
'        Poškodený súbor vo fronte (neprejde kontrolou protokolu) sa premenuje na <nazov>.zle, ostane vo fronte a zaloguje sa;
'        neodosiela sa a neblokuje ostatné. Ak zápis na server zlyhá až po vytvorení súboru (na serveri môže ostať nedopísaný
'        súbor), poznačí sa to súborom <nazov>.ciastocne: ďalšia chyba 58 sa potom NEBERIE ako doručenie.
' ZOZNAM VEREJNÝCH PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - VysledokOdoslania(cisloChyby)             : ČISTÁ: mapovanie čísla chyby na výsledok.
' - JeDorucene(vysledok)                      : ČISTÁ: DORUCENE alebo EXISTUJE.
' - NovyPocetNeuspechov(doteraz, vysledok)    : ČISTÁ: počítadlo po sebe idúcich neúspechov (PRISTUP, INA).
' - TextPreOdoslanie(textFronty, nazov, odlozene, text) : ČISTÁ: text na odoslanie z textu vo fronte; vráti "" alebo dôvod.
' - DatumZNazvu(nazov, d)                     : ČISTÁ: deň razenia z názvu súboru.
' - CestaFronty(), CestaOdoslanych(), CestaPrijmu()
' - UlozDoFronty(nazov, text)                 : Zapíše razenie do lokálnej fronty; vráti 0 alebo číslo chyby.
' - OdosliSubor(nazov, odlozene)              : Jeden pokus o doručenie jedného súboru z fronty; vráti výsledok.
' - OdosliCakajuce(odlozene)                  : Odošle čakajúce v poradí názvov; vráti počet doručených.
' - PocetVoFronte(), NajstarsieCakanieDni(teraz), ProblemSOdoslanim(), ServerNedostupny(), PoslednaChybaOdoslania()
' - RazeniaDna(den, r, odoslane)              : Razenia dňa z lokálneho záznamu zoradené podľa utc; vráti počet.
' - UpracOdoslane(teraz)                      : Zmaže odoslané staršie ako 90 dní; vráti počet zmazaných.
'===============================================================================

Public Const VYSL_DORUCENE As String = "DORUCENE"
Public Const VYSL_EXISTUJE As String = "EXISTUJE"
Public Const VYSL_NEDOSTUPNY As String = "NEDOSTUPNY"
Public Const VYSL_PRISTUP As String = "PRISTUP"
Public Const VYSL_INA As String = "INA"
Public Const VYSL_POSKODENE As String = "POSKODENE"
Public Const VYSL_ZANEPRAZDNENE As String = "ZANEPRAZDNENE"
Public Const PRAH_NEUSPECHOV As Long = 5
Public Const DNI_ODOSLANE As Long = 90
Private Const PRIPONA_ZLE As String = ".zle"
Private Const PRIPONA_CIASTOCNE As String = ".ciastocne"

Private mNeuspechov As Long          ' po sebe idúce výsledky PRISTUP / INA
Private mStavServera As String       ' "" (neznámy), "OK", "NEDOSTUPNY"
Private mPoslednaChyba As Long       ' číslo chyby posledného neúspešného pokusu
Private mOdosielam As Boolean        ' ochrana pred súbehom (časovač počas razenia)

'===============================================================================
' Čisté funkcie
'===============================================================================
Public Function VysledokOdoslania(ByVal lCisloChyby As Long) As String
    Select Case lCisloChyby
        Case 0
            VysledokOdoslania = VYSL_DORUCENE
        Case 58
            VysledokOdoslania = VYSL_EXISTUJE
        Case 52, 53, 57, 67, 68, 71, 75, 76
            VysledokOdoslania = VYSL_NEDOSTUPNY
        Case 70
            VysledokOdoslania = VYSL_PRISTUP
        Case Else
            VysledokOdoslania = VYSL_INA
    End Select
End Function

Public Function JeDorucene(ByVal strVysledok As String) As Boolean
    JeDorucene = (strVysledok = VYSL_DORUCENE Or strVysledok = VYSL_EXISTUJE)
End Function

' Doručenie počítadlo nuluje, PRISTUP a INA ho zvyšujú, nedostupný server (a ostatné) ho nemení.
Public Function NovyPocetNeuspechov(ByVal lDoteraz As Long, ByVal strVysledok As String) As Long
    Select Case strVysledok
        Case VYSL_DORUCENE, VYSL_EXISTUJE
            NovyPocetNeuspechov = 0
        Case VYSL_PRISTUP, VYSL_INA
            NovyPocetNeuspechov = lDoteraz + 1
        Case Else
            NovyPocetNeuspechov = lDoteraz
    End Select
End Function

' Text na odoslanie: rovnaké id, cas, utc a ostatné hodnoty ako vo fronte, len odlozene podľa pokusu. Výsledok sa znova
' skontroluje spolu s názvom súboru. Vráti "" alebo dôvod, prečo sa text nedá odoslať.
Public Function TextPreOdoslanie(ByVal strTextFronty As String, ByVal strNazov As String, ByVal bOdlozene As Boolean, ByRef strText As String) As String
    Dim r As TRazenie, r2 As TRazenie, strKodChyby As String, strDovod As String
    strText = ""
    strDovod = kl_02_Protokol.RozoberRazenie(strTextFronty, strNazov, strKodChyby, r)
    If Len(strDovod) > 0 Then
        TextPreOdoslanie = strKodChyby & ": " & strDovod
        Exit Function
    End If
    strText = kl_02_Protokol.ZostavRazenie(r.Id, r.Oc, r.Login, r.Pc, r.Kod, r.Smer, r.Cas, r.Utc, bOdlozene, r.Klient)
    strDovod = kl_02_Protokol.RozoberRazenie(strText, strNazov, strKodChyby, r2)
    If Len(strDovod) > 0 Then
        strText = ""
        TextPreOdoslanie = strKodChyby & ": " & strDovod
    End If
End Function

' Deň razenia z názvu RRRRMMDD-HHMMSS_<id>.rzn (miestny čas).
Public Function DatumZNazvu(ByVal strNazov As String, ByRef d As Date) As Boolean
    Dim t As Date
    If Len(strNazov) < 15 Then Exit Function
    If Not kl_02_Protokol.CasZTextu(Mid$(strNazov, 1, 4) & "-" & Mid$(strNazov, 5, 2) & "-" & Mid$(strNazov, 7, 2) & "T" & _
                                    Mid$(strNazov, 10, 2) & ":" & Mid$(strNazov, 12, 2) & ":" & Mid$(strNazov, 14, 2), t) Then Exit Function
    If Mid$(strNazov, 9, 1) <> "-" Then Exit Function
    d = t
    DatumZNazvu = True
End Function

'===============================================================================
' Cesty a stav
'===============================================================================
Public Function CestaFronty() As String
    CestaFronty = kl_00_Spolocne.LokalnyPriecinok() & "\" & kl_00_Spolocne.PRIECINOK_FRONTA
End Function

Public Function CestaOdoslanych() As String
    CestaOdoslanych = kl_00_Spolocne.LokalnyPriecinok() & "\" & kl_00_Spolocne.PRIECINOK_ODOSLANE
End Function

' <zaklad>\prijem; "" ak základ nie je známy.
Public Function CestaPrijmu() As String
    Dim s As String
    s = kl_00_Spolocne.ZakladPriecinok()
    If Len(s) > 0 Then CestaPrijmu = s & "\" & kl_00_Spolocne.PRIECINOK_PRIJEM
End Function

Public Function PocetVoFronte() As Long
    Dim a() As String
    PocetVoFronte = kl_00_Spolocne.ZoznamSuborov(CestaFronty(), "*" & kl_02_Protokol.PRIPONA_RZN, a)
End Function

' Koľko celých dní čaká najstaršie razenie vo fronte (0 = fronta je prázdna alebo čaká menej než deň).
Public Function NajstarsieCakanieDni(ByVal dtTeraz As Date) As Long
    Dim a() As String, d As Date
    If kl_00_Spolocne.ZoznamSuborov(CestaFronty(), "*" & kl_02_Protokol.PRIPONA_RZN, a) = 0 Then Exit Function
    If Not DatumZNazvu(a(0), d) Then Exit Function
    If dtTeraz > d Then NajstarsieCakanieDni = CLng(Int(dtTeraz - d))
End Function

Public Function ProblemSOdoslanim() As Boolean
    ProblemSOdoslanim = (mNeuspechov >= PRAH_NEUSPECHOV)
End Function

Public Function ServerNedostupny() As Boolean
    ServerNedostupny = (mStavServera = VYSL_NEDOSTUPNY)
End Function

Public Function PoslednaChybaOdoslania() As Long
    PoslednaChybaOdoslania = mPoslednaChyba
End Function

'===============================================================================
' Zápis
'===============================================================================
Public Function UlozDoFronty(ByVal strNazov As String, ByVal strText As String) As Long
    UlozDoFronty = kl_00_Spolocne.ZapisAsciiNovy(CestaFronty() & "\" & strNazov, strText)
End Function

' Vytvorí súbor na serveri len ako nový a zapíše celý text jedným zápisom. Vráti 0 alebo číslo chyby; bVytvoreny = súbor sa
' podarilo vytvoriť (ak potom zlyhal zápis, na serveri mohol ostať nedopísaný súbor).
Private Function ZapisNaServer(ByVal strCesta As String, ByVal strText As String, ByRef bVytvoreny As Boolean, ByRef strPopis As String) As Long
    Dim fso As Object, ts As Object
    bVytvoreny = False
    strPopis = ""
    On Error GoTo Chyba
    Set fso = CreateObject("Scripting.FileSystemObject")
    Set ts = fso.CreateTextFile(strCesta, False, False)
    bVytvoreny = True
    ts.Write strText
    ts.Close
    Set ts = Nothing
    ZapisNaServer = 0
    Exit Function
Chyba:
    ZapisNaServer = IIf(Err.Number <> 0, Err.Number, 5)
    strPopis = Err.Description
    On Error Resume Next
    If Not ts Is Nothing Then ts.Close
End Function

Private Sub ZaznamenajStavServera(ByVal strVysledok As String)
    Dim strNovy As String
    If strVysledok = VYSL_NEDOSTUPNY Then
        strNovy = VYSL_NEDOSTUPNY
    ElseIf JeDorucene(strVysledok) Then
        strNovy = "OK"
    Else
        Exit Sub
    End If
    If strNovy <> mStavServera Then
        If strNovy = VYSL_NEDOSTUPNY Then
            Call kl_00_Spolocne.ZapisLog("WARN", "Server je nedostupný, razenia čakajú vo fronte.")
        ElseIf mStavServera = VYSL_NEDOSTUPNY Then
            Call kl_00_Spolocne.ZapisLog("INFO", "Server je znova dostupný.")
        End If
        mStavServera = strNovy
    End If
End Sub

'===============================================================================
' Jeden pokus o doručenie jedného súboru z fronty. bOdlozene = False len pri pokuse priamo pri razení.
'===============================================================================
Public Function OdosliSubor(ByVal strNazov As String, ByVal bOdlozene As Boolean) As String
    Dim strLok As String, strTextFronty As String, strText As String, strDovod As String, strPrijem As String
    Dim lChyba As Long, bVytvoreny As Boolean, strPopis As String, strVysledok As String, strMesiac As String, lVelkost As Long

    If mOdosielam Then
        OdosliSubor = VYSL_ZANEPRAZDNENE
        Exit Function
    End If
    mOdosielam = True
    On Error GoTo Chyba

    strLok = CestaFronty() & "\" & strNazov
    If Not kl_00_Spolocne.CitajBajty(strLok, strTextFronty, kl_02_Protokol.MAX_BAJTOV_RZN) Then
        ' súbor sa nedá prečítať (zamknutý, zmizol, priveľký): nič sa nepremenúva, skúsi sa nabudúce
        Call kl_00_Spolocne.ZapisLog("WARN", "Súbor vo fronte sa nepodarilo prečítať: " & strNazov)
        mNeuspechov = NovyPocetNeuspechov(mNeuspechov, VYSL_INA)
        strVysledok = VYSL_INA
        GoTo Koniec
    End If
    strDovod = TextPreOdoslanie(strTextFronty, strNazov, bOdlozene, strText)
    If Len(strDovod) > 0 Then
        Call kl_00_Spolocne.ZapisLog("ERROR", "Súbor vo fronte je poškodený a neodošle sa: " & strNazov & " (" & strDovod & "). Premenovaný na " & PRIPONA_ZLE & ".")
        On Error Resume Next
        Name strLok As strLok & PRIPONA_ZLE
        On Error GoTo Chyba
        strVysledok = VYSL_POSKODENE
        GoTo Koniec
    End If

    strPrijem = CestaPrijmu()
    If Len(strPrijem) = 0 Then
        lChyba = 76
        strPopis = "základný priečinok nie je nastavený"
    Else
        lChyba = ZapisNaServer(strPrijem & "\" & strNazov, strText, bVytvoreny, strPopis)
    End If
    strVysledok = VysledokOdoslania(lChyba)

    If lChyba <> 0 And bVytvoreny Then
        ' súbor vznikol, ale zápis zlyhal: na serveri môže byť nedopísaný súbor, ďalšia chyba 58 nie je doručenie
        Call kl_00_Spolocne.ZapisAsciiNovy(strLok & PRIPONA_CIASTOCNE, "chyba=" & lChyba & vbCrLf)
        strVysledok = VYSL_INA
    ElseIf strVysledok = VYSL_EXISTUJE And kl_00_Spolocne.SuborExistuje(strLok & PRIPONA_CIASTOCNE) Then
        strVysledok = VYSL_INA
        strPopis = "na serveri je nedopísaný súbor z predošlého pokusu (HR ho pri príjme presunie do chybne)"
    End If

    Call kl_00_Spolocne.ZapisLog(IIf(JeDorucene(strVysledok), "INFO", "WARN"), "Odoslanie " & strNazov & " odlozene=" & IIf(bOdlozene, "1", "0") & ": " & strVysledok & _
                                 ", chyba " & lChyba & IIf(lChyba = 58 And strVysledok = VYSL_EXISTUJE, " (už existovalo)", "") & IIf(Len(strPopis) > 0, " (" & strPopis & ")", ""))
    If lChyba <> 0 Then mPoslednaChyba = lChyba
    mNeuspechov = NovyPocetNeuspechov(mNeuspechov, strVysledok)
    Call ZaznamenajStavServera(strVysledok)

    If JeDorucene(strVysledok) Then
        If lChyba = 0 Then
            lVelkost = kl_00_Spolocne.VelkostSuboru(strPrijem & "\" & strNazov)
            If lVelkost >= 0 And lVelkost <> Len(strText) Then
                Call kl_00_Spolocne.ZapisLog("WARN", "Súbor na serveri má inú veľkosť (" & lVelkost & ") než odoslaný text (" & Len(strText) & "): " & strNazov & ". Nič sa nemaže.")
            End If
        End If
        ' najprv kópia do odoslane, až potom zmazanie z fronty
        strMesiac = CestaOdoslanych() & "\" & Mid$(strNazov, 1, 4) & "-" & Mid$(strNazov, 5, 2)
        If Not kl_00_Spolocne.VytvorPriecinok(strMesiac) Then
            Call kl_00_Spolocne.ZapisLog("ERROR", "Nepodarilo sa vytvoriť priečinok odoslaných; razenie ostáva vo fronte: " & strNazov)
        ElseIf kl_00_Spolocne.ZapisAsciiNovy(strMesiac & "\" & strNazov, strText) <> 0 Then
            Call kl_00_Spolocne.ZapisLog("ERROR", "Nepodarilo sa uložiť kópiu odoslaného razenia; ostáva vo fronte: " & strNazov)
        Else
            If kl_00_Spolocne.ZmazSubor(strLok) <> 0 Then Call kl_00_Spolocne.ZapisLog("WARN", "Odoslané razenie sa nepodarilo zmazať z fronty: " & strNazov)
            Call kl_00_Spolocne.ZmazSubor(strLok & PRIPONA_CIASTOCNE)
        End If
    End If

Koniec:
    mOdosielam = False
    OdosliSubor = strVysledok
    Exit Function
Chyba:
    Call kl_00_Spolocne.ZapisLog("ERROR", "Odoslanie " & strNazov & " skončilo chybou " & Err.Number & ": " & Err.Description)
    mPoslednaChyba = Err.Number
    mNeuspechov = NovyPocetNeuspechov(mNeuspechov, VYSL_INA)
    strVysledok = VYSL_INA
    Resume Koniec
End Function

' Odošle čakajúce razenia v poradí názvov (čas razenia). Pri prvom neúspechu kolo končí (server je nedostupný); poškodený súbor
' sa preskočí. Vráti počet doručených.
Public Function OdosliCakajuce(Optional ByVal bOdlozene As Boolean = True) As Long
    Dim a() As String, n As Long, i As Long, strVysledok As String
    n = kl_00_Spolocne.ZoznamSuborov(CestaFronty(), "*" & kl_02_Protokol.PRIPONA_RZN, a)
    For i = 0 To n - 1
        strVysledok = OdosliSubor(a(i), bOdlozene)
        If JeDorucene(strVysledok) Then
            OdosliCakajuce = OdosliCakajuce + 1
        ElseIf strVysledok <> VYSL_POSKODENE Then
            Exit For
        End If
    Next i
End Function

'===============================================================================
' Lokálny záznam
'===============================================================================
Private Sub PridajRazenia(ByVal strPriecinok As String, ByVal strDen As String, ByVal bZOdoslanych As Boolean, _
                          ByRef r() As TRazenie, ByRef bOdoslane() As Boolean, ByRef n As Long)
    Dim a() As String, lPocet As Long, i As Long, j As Long, strText As String, strKodChyby As String, t As TRazenie, bMam As Boolean
    lPocet = kl_00_Spolocne.ZoznamSuborov(strPriecinok, strDen & "-*" & kl_02_Protokol.PRIPONA_RZN, a)
    For i = 0 To lPocet - 1
        If kl_00_Spolocne.CitajBajty(strPriecinok & "\" & a(i), strText, kl_02_Protokol.MAX_BAJTOV_RZN) Then
            If Len(kl_02_Protokol.RozoberRazenie(strText, a(i), strKodChyby, t)) = 0 Then
                bMam = False
                For j = 0 To n - 1
                    If r(j).Id = t.Id Then
                        bMam = True
                        If bZOdoslanych Then bOdoslane(j) = True
                    End If
                Next j
                If Not bMam Then
                    ReDim Preserve r(0 To n)
                    ReDim Preserve bOdoslane(0 To n)
                    r(n) = t
                    bOdoslane(n) = bZOdoslanych
                    n = n + 1
                End If
            End If
        End If
    Next i
End Sub

' Razenia dňa (miestny dátum) z fronty a z odoslaných, zoradené podľa utc. bOdoslane(i) = razenie je doručené. Vráti počet.
Public Function RazeniaDna(ByVal dtDen As Date, ByRef r() As TRazenie, ByRef bOdoslane() As Boolean) As Long
    Dim n As Long, strDen As String, i As Long, j As Long, t As TRazenie, b As Boolean
    On Error GoTo Chyba
    Erase r
    Erase bOdoslane
    strDen = Format$(Year(dtDen), "0000") & Format$(Month(dtDen), "00") & Format$(Day(dtDen), "00")
    Call PridajRazenia(CestaFronty(), strDen, False, r, bOdoslane, n)
    Call PridajRazenia(CestaOdoslanych() & "\" & Left$(strDen, 4) & "-" & Mid$(strDen, 5, 2), strDen, True, r, bOdoslane, n)
    For i = 1 To n - 1
        t = r(i)
        b = bOdoslane(i)
        j = i - 1
        Do While j >= 0
            If r(j).Utc <= t.Utc Then Exit Do
            r(j + 1) = r(j)
            bOdoslane(j + 1) = bOdoslane(j)
            j = j - 1
        Loop
        r(j + 1) = t
        bOdoslane(j + 1) = b
    Next i
    RazeniaDna = n
    Exit Function
Chyba:
    Call kl_00_Spolocne.ZapisLog("ERROR", "Čítanie lokálneho záznamu razení skončilo chybou " & Err.Number & ": " & Err.Description)
    RazeniaDna = n
End Function

' Zmaže kópie odoslaných razení staršie ako DNI_ODOSLANE dní (podľa dátumu v názve) a prázdne priečinky mesiacov.
' Fronty sa nedotýka. Vráti počet zmazaných súborov.
Public Function UpracOdoslane(ByVal dtTeraz As Date) As Long
    Dim strKoren As String, mesiace() As String, nM As Long, s As String, i As Long, a() As String, n As Long, j As Long, d As Date
    On Error GoTo Chyba
    strKoren = CestaOdoslanych()
    If Not kl_00_Spolocne.PriecinokExistuje(strKoren) Then Exit Function
    s = Dir$(strKoren & "\????-??", vbDirectory)
    Do While Len(s) > 0
        If kl_00_Spolocne.PriecinokExistuje(strKoren & "\" & s) Then
            ReDim Preserve mesiace(0 To nM)
            mesiace(nM) = s
            nM = nM + 1
        End If
        s = Dir$()
    Loop
    For i = 0 To nM - 1
        n = kl_00_Spolocne.ZoznamSuborov(strKoren & "\" & mesiace(i), "*" & kl_02_Protokol.PRIPONA_RZN, a)
        For j = 0 To n - 1
            If DatumZNazvu(a(j), d) Then
                If dtTeraz - d > DNI_ODOSLANE Then
                    If kl_00_Spolocne.ZmazSubor(strKoren & "\" & mesiace(i) & "\" & a(j)) = 0 Then UpracOdoslane = UpracOdoslane + 1
                End If
            End If
        Next j
        If Len(Dir$(strKoren & "\" & mesiace(i) & "\*.*")) = 0 Then
            On Error Resume Next
            RmDir strKoren & "\" & mesiace(i)
            On Error GoTo Chyba
        End If
    Next i
    If UpracOdoslane > 0 Then Call kl_00_Spolocne.ZapisLog("INFO", "Upratanie: zmazaných " & UpracOdoslane & " odoslaných razení starších ako " & DNI_ODOSLANE & " dní.")
    Exit Function
Chyba:
    Call kl_00_Spolocne.ZapisLog("WARN", "Upratanie odoslaných skončilo chybou " & Err.Number & ": " & Err.Description)
End Function
