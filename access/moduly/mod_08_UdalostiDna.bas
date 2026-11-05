Attribute VB_Name = "mod_08_UdalostiDna"
'@Verzia 1.4.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_08_UdalostiDna
' POPIS: Jediné jadro spracovania denných razení. Používa ho výpočtový engine
'        (modMesaatnaDochadzka), automatické opravy (mod_09_AutoOprava) aj editor.
'        Obsahuje:
'          - načítanie razení (skutočné + schválené automatické opravy),
'          - stavový automat dňa (SpracujDen): páruje príchod/odchod a prerušenia,
'            vytvára intervaly a zoznam anomálií,
'          - denný kontext mesiaca (kalendár, sviatky, pracovný fond),
'          - parametre výpočtu (okno práce, obed, duplicity, razený obed, zaokrúhľovanie).
' PRAVIDLÁ PÁROVANIA (Smer Z = začiatok, K = koniec; Číslo 1 = pracovná doba):
'   - Z1 otvorí prácu, K1 ju uzavrie. Z prerušenia uzavrie prácu a otvorí prerušenie,
'     K prerušenia ho uzavrie a práca sa obnoví (návrat do práce).
'   - Dvojica Z1+Zx v rovnakej minúte (mzdová šablóna z Ordata) = celodenné prerušenie,
'     práca sa nezapisuje, nepočíta sa dvakrát.
'   - Otvorené prerušenie sa implicitne uzavrie príchodom, odchodom alebo iným prerušením.
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - ObnovParametre()                     : Zahodí cache parametrov (po zmene pravidiel/nastavení).
' - PrmOknoOd/PrmOknoDo/PrmObedMin/...   : Parametre výpočtu (nastavenia + pravidlá).
' - NacitajUdalosti(...)                 : Načíta a zoradí razenia obdobia (vrátane schválených opráv).
' - HranicaDna(u, n, i0)                 : Posledný index rovnakého dňa v poli udalostí.
' - SpracujDen(u, i0, i1, r)             : Stavový automat dňa -> intervaly + anomálie.
' - TrvanieIntervalu(...)                : Započítané trvanie intervalu (okno práce, celodenná prekážka).
' - SumarDna(r, fond, odpr, prek)        : Odpracované a započítané prekážky dňa (vrátane auto-obeda a režimu razeného obeda).
' - UplatniZaokruhlenie(r)               : Zaokrúhli prvý razený príchod a posledný razený odchod dňa (ak je zapnuté).
' - ZaokruhliCas(cas, krok, smer)        : Zaokrúhli minúty od polnoci na násobok kroku (nahor / nadol / najbližší).
' - NacitajKontextMesiaca(...)           : Typ dňa a fond pre každý deň mesiaca.
' - NastaveniaZamestnanca(...)           : Priradený fond/šablóna/kalendár platný pre mesiac.
' - FondZamestnanca(...)                 : Priemerný denný fond zamestnanca v mesiaci (vrátane úväzku).
' - DlzkaFonduDna(...)                   : Priemerná dĺžka dňa pracovného fondu (min) platná pre mesiac.
' - PridajAnomaliuDna(r, ...)             : Pridá anomáliu do výsledku dňa (kontrola pravidiel prerušení).
'   Fond zamestnanca: priradený fond (ZamestnanciFondy) x úväzok zamestnanca (%). Fond môže mať rôznu dĺžku podľa
'   dňa v týždni (FondPodlaDna) alebo pevný mesačný fond (typ 4: Voľná s pevným mesačným fondom spolu za mesiac).
'===============================================================================

Public Type TUdalost
    Datum As Date
    Cas As Long           ' minúty od polnoci
    Smer As String        ' "Z" / "K"
    Cislo As Long         ' číslo prerušenia (1 = pracovná doba)
    Zdroj As Long         ' 0 = razenie, 1 = automatická oprava, 2 = automatický koniec prerušenia (bez návratu do práce)
    ID As Long            ' ID v DochadzkaImport (alebo v DochadzkaAutoOpravy pre Zdroj > 0)
End Type

Public Type TInterval
    Cislo As Long
    Zac As Long
    Kon As Long
    ZacAuto As Boolean    ' začiatok pochádza z automatickej opravy (nie zo skutočného razenia)
    KonAuto As Boolean    ' koniec pochádza z automatickej opravy
    ZacRezum As Boolean   ' začiatok práce = návrat z prerušenia (nie príchod)
    KonOdchod As Boolean  ' koniec práce = odchod (nie začiatok prerušenia)
End Type

Public Type TAnomalia
    Kod As String
    Cas As Long
    Cislo As Long
    Info As String
End Type

Public Type TVysledokDna
    nIv As Long
    Iv() As TInterval
    nAn As Long
    An() As TAnomalia
    Praca As Boolean          ' na konci dňa je práca otvorená
    PracaZac As Long
    PracaObnovena As Boolean  ' práca bola obnovená návratom z prerušenia (nie príchodom)
    PrerOtvorene As Boolean   ' na konci dňa je prerušenie otvorené
    PrerCislo As Long
    PrerZac As Long
End Type

Public Type TKontextMesiaca
    Fond(1 To 31) As Long     ' denný fond v minútach (0 = nepracovný deň/sviatok)
    Typ(1 To 31) As String    ' typ dňa: PP, PV, VN, SP, ...
    Sviatok(1 To 31) As Boolean
    PocetDni As Long
End Type

' --- cache parametrov ---
Private mNacitane As Boolean
Private mOknoOd As Long
Private mOknoDo As Long
Private mObedMin As Long
Private mObedLimit As Long
Private mObedAktivny As Boolean
Private mCelodenna As Long
Private mDuplLimit As Long
Private mObedRezim As Long        ' razený obed: 0 skutočný čas, 1 najmenej mObedMinZazn, 2 vždy presne mObedMinZazn
Private mObedMinZazn As Long
Private mZaokrPrichod As Long     ' krok zaokrúhlenia prvého príchodu dňa (min, 0 = nezaokrúhľuje)
Private mZaokrOdchod As Long      ' krok zaokrúhlenia posledného odchodu dňa (min, 0 = nezaokrúhľuje)
Private mZaokrSmer As Long        ' 0 príchod nahor a odchod nadol, 1 oba nahor, 2 oba nadol, 3 najbližší
Private mNezapocitane As Object   ' čísla prerušení, ktorých interval sa nezapočíta (príznak NezapocitavatInterval)

'-------------------------------------------------------------------------------
' Zahodí cache parametrov (volať po zmene nastavení alebo pravidiel).
'-------------------------------------------------------------------------------
Public Sub ObnovParametre()
    mNacitane = False
End Sub

'-------------------------------------------------------------------------------
' Načíta parametre výpočtu z NastaveniaSystemu a CiselnikPravidielAnomalii (s bezpečnými predvolenými hodnotami).
'-------------------------------------------------------------------------------
Private Sub NacitajParametre()
    Dim m As Long, db As DAO.Database, rsN As DAO.Recordset
    If mNacitane Then Exit Sub
    On Error Resume Next
    m = mod_00_Common.CasNaMinuty(mod_00_Common.GetNastavenie("OknoPraceOd", "06:00"))
    If m < 0 Then m = 360
    mOknoOd = m
    m = mod_00_Common.CasNaMinuty(mod_00_Common.GetNastavenie("OknoPraceDo", "17:00"))
    If m <= 0 Then m = 1020
    mOknoDo = m
    mCelodenna = CLng(Val(mod_00_Common.GetNastavenie("CelodennaPrekazkaMin", "360")))
    If mCelodenna <= 0 Then mCelodenna = 360

    mObedAktivny = Not mod_00_Common.PravidloVypnute("AUTO_OBED_NAD_6H")
    mObedLimit = mod_00_Common.LimitPravidla("AUTO_OBED_NAD_6H", 360)
    mObedMin = CLng(Val(mod_00_Common.ParamPravidla("AUTO_OBED_NAD_6H", "TrvanieObedaMin", "30")))
    If mObedMin <= 0 Then mObedMin = 30
    mDuplLimit = mod_00_Common.LimitPravidla("DUPLICITA_DO_10MIN", 10)
    If mDuplLimit < 0 Then mDuplLimit = 10

    ' pravidlá výpočtu z karty 5 (kontrakt 1.4.0); bez nastavenia platia hodnoty zodpovedajúce doterajšiemu výpočtu
    mObedRezim = CLng(Val(mod_00_Common.GetNastavenie("ObedZaznamenanyRezim", "0")))
    If mObedRezim < 0 Or mObedRezim > 2 Then mObedRezim = 0
    mObedMinZazn = CLng(Val(mod_00_Common.GetNastavenie("ObedZaznamenanyMin", "30")))
    If mObedMinZazn < 0 Or mObedMinZazn > 600 Then mObedMinZazn = 30
    mZaokrPrichod = CLng(Val(mod_00_Common.GetNastavenie("ZaokruhleniePrichodMin", "0")))
    If mZaokrPrichod < 0 Or mZaokrPrichod > 60 Then mZaokrPrichod = 0
    mZaokrOdchod = CLng(Val(mod_00_Common.GetNastavenie("ZaokruhlenieOdchodMin", "0")))
    If mZaokrOdchod < 0 Or mZaokrOdchod > 60 Then mZaokrOdchod = 0
    mZaokrSmer = CLng(Val(mod_00_Common.GetNastavenie("ZaokruhlenieSmer", "0")))
    If mZaokrSmer < 0 Or mZaokrSmer > 3 Then mZaokrSmer = 0

    ' prerušenia s príznakom "nezapočítať" (kontrakt 1.4.0 calc UNPAID); bez stĺpca alebo príznaku je zoznam prázdny = doterajšie správanie
    Set mNezapocitane = CreateObject("Scripting.Dictionary")
    Set db = CurrentDb
    If mod_00_Common.TabulkaExistujeDB(db, "CiselnikPreruseni") Then
        If mod_00_Common.PoleExistujeDB(db, "CiselnikPreruseni", "NezapocitavatInterval") Then
            Set rsN = db.OpenRecordset("SELECT Cislo FROM CiselnikPreruseni WHERE NezapocitavatInterval = True AND Cislo <> 1 AND Cislo <> 7;", dbOpenSnapshot)
            Do While Not rsN.EOF
                mNezapocitane(CLng(rsN!Cislo)) = True
                rsN.MoveNext
            Loop
            rsN.Close
        End If
    End If
    mNacitane = True
End Sub

'-------------------------------------------------------------------------------
' Interval tohto prerušenia sa nezapočíta ani do práce, ani do prekážok dňa (neplatený odchod, kontrakt calc UNPAID).
'-------------------------------------------------------------------------------
Public Function JeNezapocitavane(ByVal lCislo As Long) As Boolean
    Call NacitajParametre
    If mNezapocitane Is Nothing Then Exit Function
    JeNezapocitavane = mNezapocitane.Exists(lCislo)
End Function

Public Function PrmOknoOd() As Long
    Call NacitajParametre
    PrmOknoOd = mOknoOd
End Function

Public Function PrmOknoDo() As Long
    Call NacitajParametre
    PrmOknoDo = mOknoDo
End Function

Public Function PrmObedMin() As Long
    Call NacitajParametre
    PrmObedMin = mObedMin
End Function

Public Function PrmObedLimit() As Long
    Call NacitajParametre
    PrmObedLimit = mObedLimit
End Function

Public Function PrmCelodennaPrekazka() As Long
    Call NacitajParametre
    PrmCelodennaPrekazka = mCelodenna
End Function

Public Function PrmDuplicitaLimit() As Long
    Call NacitajParametre
    PrmDuplicitaLimit = mDuplLimit
End Function

Public Function PrmObedRezim() As Long
    Call NacitajParametre
    PrmObedRezim = mObedRezim
End Function

Public Function PrmObedMinZaznamenany() As Long
    Call NacitajParametre
    PrmObedMinZaznamenany = mObedMinZazn
End Function

Public Function PrmZaokruhleniePrichod() As Long
    Call NacitajParametre
    PrmZaokruhleniePrichod = mZaokrPrichod
End Function

Public Function PrmZaokruhlenieOdchod() As Long
    Call NacitajParametre
    PrmZaokruhlenieOdchod = mZaokrOdchod
End Function

Public Function PrmZaokruhlenieSmer() As Long
    Call NacitajParametre
    PrmZaokruhlenieSmer = mZaokrSmer
End Function

'-------------------------------------------------------------------------------
' Načíta platné razenia zamestnanca za obdobie [dOd, dDoExkl) a pridá schválené automatické opravy.
' Výsledok je zoradený podľa (Datum, Cas, Zdroj, ID). Vracia počet udalostí (0 = žiadne).
'-------------------------------------------------------------------------------
Public Function NacitajUdalosti(ByRef db As DAO.Database, ByVal strOC As String, ByVal dOd As Date, ByVal dDoExkl As Date, _
                                ByRef u() As TUdalost, Optional ByVal bVratAutoOpravy As Boolean = True) As Long
    On Error GoTo Chyba
    Dim rs As DAO.Recordset, n As Long, sSmer As String, lC As Long, lK As Long, lCas As Long
    Dim dicKod As Object, strSQL As String

    ReDim u(1 To 64)
    n = 0
    Set dicKod = NacitajMapuKodov(db)

    strSQL = "SELECT ID, Datum, Cas, Smer, CisloPreruseni, KodPrerusenia FROM DochadzkaImport " & _
             "WHERE OsobneCislo = " & mod_00_Common.SqlText(strOC) & _
             " AND Datum >= " & mod_00_Common.SqlDatum(dOd) & " AND Datum < " & mod_00_Common.SqlDatum(dDoExkl) & _
             " AND " & mod_00_Common.SqlPlatne() & " ORDER BY Datum, Cas, ID;"
    Set rs = db.OpenRecordset(strSQL, dbOpenSnapshot)
    Do While Not rs.EOF
        sSmer = UCase$(Trim$(CStr(Nz(rs!Smer, ""))))
        lC = CLng(Nz(rs!CisloPreruseni, 0))
        lK = CLng(Nz(rs!KodPrerusenia, 0))
        If lC = 0 And lK > 0 Then
            If dicKod.Exists(lK) Then
                lC = CLng(dicKod(lK) \ 10)
                If Len(sSmer) = 0 Then sSmer = IIf(CLng(dicKod(lK)) Mod 10 = 1, "K", "Z")
            End If
        End If
        If lC > 0 And (sSmer = "Z" Or sSmer = "K") Then
            lCas = CLng(Nz(rs!Cas, 0))
            If lCas > 1440 Then lCas = lCas \ 60         ' obrana: čas uložený v sekundách
            n = n + 1
            If n > UBound(u) Then ReDim Preserve u(1 To UBound(u) * 2)
            u(n).Datum = CDate(rs!Datum)
            u(n).Cas = lCas
            u(n).Smer = sSmer
            u(n).Cislo = lC
            u(n).Zdroj = 0
            u(n).ID = CLng(rs!ID)
        End If
        rs.MoveNext
    Loop
    rs.Close

    If bVratAutoOpravy And mod_00_Common.TabulkaExistujeDB(db, "DochadzkaAutoOpravy") Then
        strSQL = "SELECT ID, Datum, Cas, Smer, CisloPreruseni, Zdroj FROM DochadzkaAutoOpravy " & _
                 "WHERE OsobneCislo = " & mod_00_Common.SqlText(strOC) & _
                 " AND Datum >= " & mod_00_Common.SqlDatum(dOd) & " AND Datum < " & mod_00_Common.SqlDatum(dDoExkl) & _
                 " AND Stav = 'UPLATNENE';"
        Set rs = db.OpenRecordset(strSQL, dbOpenSnapshot)
        Do While Not rs.EOF
            n = n + 1
            If n > UBound(u) Then ReDim Preserve u(1 To UBound(u) * 2)
            u(n).Datum = CDate(rs!Datum)
            u(n).Cas = CLng(Nz(rs!Cas, 0))
            u(n).Smer = UCase$(CStr(Nz(rs!Smer, "K")))
            u(n).Cislo = CLng(Nz(rs!CisloPreruseni, 1))
            u(n).Zdroj = IIf(CLng(Nz(rs!Zdroj, 1)) = 2, 2, 1)
            u(n).ID = CLng(rs!ID)
            rs.MoveNext
        Loop
        rs.Close
    End If

    If n > 0 Then Call ZoradUdalosti(u, n)
    NacitajUdalosti = n
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_08_UdalostiDna.NacitajUdalosti", "ERROR", Err.Description, "OC=" & strOC)
    NacitajUdalosti = 0
End Function

'-------------------------------------------------------------------------------
' Mapa KodRazenia -> (CisloPreruseni * 10 + 0/1), kde 1 = koniec (K), 0 = začiatok (Z).
'-------------------------------------------------------------------------------
Private Function NacitajMapuKodov(ByRef db As DAO.Database) As Object
    Dim dic As Object, rs As DAO.Recordset
    Set dic = CreateObject("Scripting.Dictionary")
    On Error Resume Next
    Set rs = db.OpenRecordset("SELECT KodRazenia, CisloPreruseni, Smer FROM KodyRazeni;", dbOpenSnapshot)
    If Not rs Is Nothing Then
        Do While Not rs.EOF
            dic(CLng(rs!KodRazenia)) = CLng(Nz(rs!CisloPreruseni, 0)) * 10 + IIf(UCase$(CStr(Nz(rs!Smer, "Z"))) = "K", 1, 0)
            rs.MoveNext
        Loop
        rs.Close
    End If
    Set NacitajMapuKodov = dic
End Function

'-------------------------------------------------------------------------------
' Stabilné zoradenie poľa udalostí podľa (Datum, Cas, Zdroj, ID) - vkladací algoritmus (vstup je takmer zoradený).
'-------------------------------------------------------------------------------
Private Sub ZoradUdalosti(ByRef u() As TUdalost, ByVal n As Long)
    Dim i As Long, j As Long, t As TUdalost
    For i = 2 To n
        t = u(i)
        j = i - 1
        Do While j >= 1
            If PoradieMensie(t, u(j)) Then
                u(j + 1) = u(j)
                j = j - 1
            Else
                Exit Do
            End If
        Loop
        u(j + 1) = t
    Next i
End Sub

Private Function PoradieMensie(ByRef a As TUdalost, ByRef b As TUdalost) As Boolean
    If a.Datum <> b.Datum Then PoradieMensie = (a.Datum < b.Datum): Exit Function
    If a.Cas <> b.Cas Then PoradieMensie = (a.Cas < b.Cas): Exit Function
    If a.Zdroj <> b.Zdroj Then PoradieMensie = (a.Zdroj < b.Zdroj): Exit Function
    PoradieMensie = (a.ID < b.ID)
End Function

'-------------------------------------------------------------------------------
' Vráti index poslednej udalosti rovnakého dňa ako u(i0).
'-------------------------------------------------------------------------------
Public Function HranicaDna(ByRef u() As TUdalost, ByVal n As Long, ByVal i0 As Long) As Long
    Dim i As Long
    i = i0
    Do While i < n
        If u(i + 1).Datum <> u(i0).Datum Then Exit Do
        i = i + 1
    Loop
    HranicaDna = i
End Function

Private Sub PridajInterval(ByRef r As TVysledokDna, ByVal lC As Long, ByVal lZ As Long, ByVal lK As Long, ByVal bZA As Boolean, ByVal bKA As Boolean, Optional ByVal bRezum As Boolean = False, Optional ByVal bOdchod As Boolean = False)
    If r.nIv >= UBound(r.Iv) Then ReDim Preserve r.Iv(1 To UBound(r.Iv) + 8)
    r.nIv = r.nIv + 1
    r.Iv(r.nIv).Cislo = lC
    r.Iv(r.nIv).Zac = lZ
    r.Iv(r.nIv).Kon = lK
    r.Iv(r.nIv).ZacAuto = bZA
    r.Iv(r.nIv).KonAuto = bKA
    r.Iv(r.nIv).ZacRezum = bRezum
    r.Iv(r.nIv).KonOdchod = bOdchod
End Sub

Private Sub PridajAnomaliu(ByRef r As TVysledokDna, ByVal strKod As String, ByVal lCas As Long, ByVal lC As Long, Optional ByVal strInfo As String = "")
    If r.nAn >= UBound(r.An) Then ReDim Preserve r.An(1 To UBound(r.An) + 8)
    r.nAn = r.nAn + 1
    r.An(r.nAn).Kod = strKod
    r.An(r.nAn).Cas = lCas
    r.An(r.nAn).Cislo = lC
    r.An(r.nAn).Info = strInfo
End Sub

'-------------------------------------------------------------------------------
' Pridá anomáliu do výsledku dňa (pre kontroly mimo stavového automatu, napr. pravidlá prerušení).
'-------------------------------------------------------------------------------
Public Sub PridajAnomaliuDna(ByRef r As TVysledokDna, ByVal strKod As String, ByVal lCas As Long, ByVal lC As Long, Optional ByVal strInfo As String = "")
    Call PridajAnomaliu(r, strKod, lCas, lC, strInfo)
End Sub

'-------------------------------------------------------------------------------
' Stavový automat jedného dňa: spracuje udalosti u(i0..i1) a naplní intervaly a anomálie do r.
'-------------------------------------------------------------------------------
Public Sub SpracujDen(ByRef u() As TUdalost, ByVal i0 As Long, ByVal i1 As Long, ByRef r As TVysledokDna)
    Dim i As Long, k As Long, idx As Long, lim As Long
    Dim cas As Long, c As Long, smer As String, zd As Long, bAuto As Boolean
    Dim bPraca As Boolean, lWz As Long, bWzAuto As Boolean, bWret As Boolean, bWzRes As Boolean
    Dim bPr As Boolean, lPrC As Long, lPrZ As Long, bPrAuto As Boolean
    Dim lastSet(0 To 255) As Boolean, lastCas(0 To 255) As Long, lastSmer(0 To 255) As String
    Dim sh(1 To 16) As Long, nSh As Long, bNasiel As Boolean

    lim = PrmDuplicitaLimit()
    ReDim r.Iv(1 To (i1 - i0 + 1) * 2 + 4)
    ReDim r.An(1 To (i1 - i0 + 1) + 4)
    r.nIv = 0: r.nAn = 0

    For i = i0 To i1
        cas = u(i).Cas: c = u(i).Cislo: smer = u(i).Smer: zd = u(i).Zdroj
        bAuto = (zd <> 0)
        idx = c
        If idx < 0 Or idx > 255 Then idx = 255

        ' --- duplicita: rovnaký kód a smer do limitu bez opačného razenia medzitým ---
        If zd = 0 And lastSet(idx) Then
            If lastSmer(idx) = smer And (cas - lastCas(idx)) >= 0 And (cas - lastCas(idx)) <= lim Then
                Call PridajAnomaliu(r, "DUPLICITA", cas, c)
                GoTo Dalsi
            End If
        End If
        lastSet(idx) = True: lastSmer(idx) = smer: lastCas(idx) = cas

        If c = 1 And smer = "Z" Then
            ' ---------------- PRÍCHOD ----------------
            If bPraca And bWret Then
                lWz = cas: bWzAuto = bAuto: bWret = False: bWzRes = False   ' skutočný príchod prepíše obnovenú prácu
            ElseIf bPraca Then
                Call PridajAnomaliu(r, "DVOJITY_PRICHOD", cas, 1)
            Else
                If bPr And cas > lPrZ Then
                    Call PridajAnomaliu(r, "PRICHOD_V_PRERUSENI", cas, lPrC)
                    Call PridajInterval(r, lPrC, lPrZ, cas, bPrAuto, bAuto)
                    bPr = False
                End If
                bPraca = True: lWz = cas: bWzAuto = bAuto: bWret = False: bWzRes = False
            End If

        ElseIf c = 1 And smer = "K" Then
            ' ---------------- ODCHOD ----------------
            If bPraca Then
                If Not (bPr And lPrZ = lWz) Then
                    Call PridajInterval(r, 1, lWz, cas, bWzAuto, bAuto, bWzRes, True)
                End If
                bPraca = False: bWret = False
            ElseIf bPr Then
                If cas > lPrZ Then Call PridajAnomaliu(r, "ODCHOD_V_PRERUSENI", cas, lPrC)
                Call PridajInterval(r, lPrC, lPrZ, cas, bPrAuto, bAuto)
                bPr = False
            Else
                Call PridajAnomaliu(r, "ODCHOD_BEZ_PRICHODU", cas, 1)
            End If

        ElseIf smer = "Z" Then
            ' ---------------- ZAČIATOK PRERUŠENIA ----------------
            If bPr And cas = lPrZ And lPrC <> c Then
                ' paralelné prerušenie v rovnakej minúte (napr. dve šablóny z Ordata) - nepočíta sa dvakrát
                If nSh < 16 Then
                    nSh = nSh + 1
                    sh(nSh) = c
                End If
                GoTo Dalsi
            End If
            If bPr And cas > lPrZ Then
                Call PridajAnomaliu(r, "PREKRYV_PRERUSENI", cas, lPrC, CStr(c))
                Call PridajInterval(r, lPrC, lPrZ, cas, bPrAuto, bAuto)
                bPr = False
            End If
            If Not bPr Then
                If bPraca Then
                    If cas > lWz Then
                        Call PridajInterval(r, 1, lWz, cas, bWzAuto, bAuto, bWzRes)
                        bPraca = False
                    End If
                End If
                bPr = True: lPrC = c: lPrZ = cas: bPrAuto = bAuto
            End If

        Else
            ' ---------------- KONIEC PRERUŠENIA ----------------
            If bPr And lPrC = c Then
                Call PridajInterval(r, c, lPrZ, cas, bPrAuto, bAuto)
                If zd <> 2 Then
                    If Not bPraca Then
                        bPraca = True: lWz = cas: bWzAuto = bAuto: bWret = True: bWzRes = True
                    ElseIf lPrZ = lWz Then
                        lWz = cas: bWzAuto = bAuto: bWret = True: bWzRes = True
                    End If
                Else
                    bPraca = False: bWret = False
                End If
                bPr = False
            Else
                bNasiel = False
                For k = 1 To nSh
                    If sh(k) = c Then
                        bNasiel = True
                        sh(k) = sh(nSh): nSh = nSh - 1
                        Exit For
                    End If
                Next k
                If Not bNasiel Then
                    Call PridajAnomaliu(r, "KONIEC_BEZ_ZACIATKU", cas, c, IIf(bPr, CStr(lPrC), ""))
                End If
            End If
        End If
Dalsi:
    Next i

    r.Praca = bPraca: r.PracaZac = lWz: r.PracaObnovena = bWret
    r.PrerOtvorene = bPr: r.PrerCislo = lPrC: r.PrerZac = lPrZ
    If bPraca And Not bWret Then Call PridajAnomaliu(r, "NEUKONCENA_PRACA", lWz, 1)
    If bPr Then Call PridajAnomaliu(r, "NEUKONCENE_PRERUSENIE", lPrZ, lPrC)
End Sub

'-------------------------------------------------------------------------------
' Započítané trvanie intervalu: práca sa oreže oknom práce; celodenná prekážka sa započíta ako denný fond.
'-------------------------------------------------------------------------------
Public Function TrvanieIntervalu(ByVal lCislo As Long, ByVal lZ As Long, ByVal lK As Long, ByVal lFond As Long) As Long
    Dim a As Long, b As Long, t As Long
    If lK <= lZ Then Exit Function
    If lCislo = 1 Then
        a = lZ: b = lK
        If a < PrmOknoOd() Then a = PrmOknoOd()
        If b > PrmOknoDo() Then b = PrmOknoDo()
        If b > a Then TrvanieIntervalu = b - a
    ElseIf lCislo = 7 Then
        TrvanieIntervalu = lK - lZ
    ElseIf JeNezapocitavane(lCislo) Then
        TrvanieIntervalu = 0
    Else
        t = lK - lZ
        If t >= PrmCelodennaPrekazka() Then t = lFond
        TrvanieIntervalu = t
    End If
End Function

'-------------------------------------------------------------------------------
' Súčty dňa podľa pravidiel enginu: odpracované (po odpočte auto-obeda) a započítané prekážky.
'-------------------------------------------------------------------------------
Public Sub SumarDna(ByRef r As TVysledokDna, ByVal lFond As Long, ByRef lOdpr As Long, ByRef lPrek As Long)
    Dim i As Long, bObed As Boolean, lObedSkut As Long
    lOdpr = 0: lPrek = 0
    For i = 1 To r.nIv
        Select Case r.Iv(i).Cislo
            Case 1
                lOdpr = lOdpr + TrvanieIntervalu(1, r.Iv(i).Zac, r.Iv(i).Kon, lFond)
            Case 7
                bObed = True
                If r.Iv(i).Kon > r.Iv(i).Zac Then lObedSkut = lObedSkut + (r.Iv(i).Kon - r.Iv(i).Zac)
            Case Else
                lPrek = lPrek + TrvanieIntervalu(r.Iv(i).Cislo, r.Iv(i).Zac, r.Iv(i).Kon, lFond)
        End Select
    Next i
    Call NacitajParametre
    If mObedAktivny And lFond > 0 And lOdpr > mObedLimit And Not bObed Then lOdpr = lOdpr - mObedMin
    ' razený obed (kontrakt lunch_recorded_mode): 0 = skutočný čas (obed nie je práca, nič sa neupravuje),
    ' 1 = najmenej mObedMinZazn (kratší obed sa dorovná odpočtom), 2 = vždy presne mObedMinZazn
    If bObed And mObedRezim > 0 Then
        If mObedRezim = 1 Then
            If lObedSkut < mObedMinZazn Then lOdpr = lOdpr - (mObedMinZazn - lObedSkut)
        Else
            lOdpr = lOdpr + lObedSkut - mObedMinZazn
        End If
        If lOdpr < 0 Then lOdpr = 0
    End If
End Sub

'-------------------------------------------------------------------------------
' Zaokrúhli minúty od polnoci na násobok kroku. lSmer: 1 nahor, -1 nadol, 0 na najbližší (polovica nahor).
' Krok 0 alebo 1 čas nemení.
'-------------------------------------------------------------------------------
Public Function ZaokruhliCas(ByVal lCas As Long, ByVal lKrok As Long, ByVal lSmer As Long) As Long
    Dim lZv As Long
    If lKrok <= 1 Then ZaokruhliCas = lCas: Exit Function
    lZv = lCas Mod lKrok
    If lZv = 0 Then ZaokruhliCas = lCas: Exit Function
    If lSmer > 0 Then
        ZaokruhliCas = lCas - lZv + lKrok
    ElseIf lSmer < 0 Then
        ZaokruhliCas = lCas - lZv
    ElseIf lZv * 2 >= lKrok Then
        ZaokruhliCas = lCas - lZv + lKrok
    Else
        ZaokruhliCas = lCas - lZv
    End If
End Function

'-------------------------------------------------------------------------------
' Zaokrúhlenie podľa pravidiel výpočtu: prvý razený príchod dňa a posledný razený odchod dňa (rovnako ako terminál).
' Netýka sa času z automatickej opravy ani návratu z prerušenia. Volá sa po SpracujDen a pred zápisom intervalov
' a súčtov, takže interval, zostava aj súčty dňa majú rovnaký (zaokrúhlený) čas. Bez zapnutého zaokrúhlenia nič nemení.
'-------------------------------------------------------------------------------
Public Sub UplatniZaokruhlenie(ByRef r As TVysledokDna)
    Dim i As Long, iPrv As Long, iPos As Long, lSmerP As Long, lSmerO As Long, bPoslednyOdchod As Boolean
    Call NacitajParametre
    If mZaokrPrichod <= 1 And mZaokrOdchod <= 1 Then Exit Sub
    Select Case mZaokrSmer
        Case 1: lSmerP = 1: lSmerO = 1
        Case 2: lSmerP = -1: lSmerO = -1
        Case 3: lSmerP = 0: lSmerO = 0
        Case Else: lSmerP = 1: lSmerO = -1
    End Select
    For i = 1 To r.nIv
        If r.Iv(i).Cislo = 1 Then
            If iPrv = 0 Then
                iPrv = i
            ElseIf r.Iv(i).Zac < r.Iv(iPrv).Zac Then
                iPrv = i
            End If
            If iPos = 0 Then
                iPos = i
            ElseIf r.Iv(i).Kon > r.Iv(iPos).Kon Then
                iPos = i
            End If
        End If
    Next i
    If iPrv = 0 Then Exit Sub

    If mZaokrPrichod > 1 Then
        If Not r.Iv(iPrv).ZacAuto And Not r.Iv(iPrv).ZacRezum Then
            r.Iv(iPrv).Zac = ZaokruhliCas(r.Iv(iPrv).Zac, mZaokrPrichod, lSmerP)
        End If
    End If

    If mZaokrOdchod > 1 Then
        bPoslednyOdchod = (r.Iv(iPos).KonOdchod And Not r.Iv(iPos).KonAuto)
        If bPoslednyOdchod Then
            For i = 1 To r.nIv
                If r.Iv(i).Cislo <> 1 And r.Iv(i).Zac >= r.Iv(iPos).Kon Then bPoslednyOdchod = False
            Next i
        End If
        If bPoslednyOdchod Then r.Iv(iPos).Kon = ZaokruhliCas(r.Iv(iPos).Kon, mZaokrOdchod, lSmerO)
    End If
End Sub

'-------------------------------------------------------------------------------
' Vráti priradený pracovný fond, šablónu prerušení a kalendár zamestnanca platné pre mesiac (Rok*12+Mesiac).
'-------------------------------------------------------------------------------
Public Sub NastaveniaZamestnanca(ByRef db As DAO.Database, ByVal strOC As String, ByVal iRok As Integer, ByVal iMesiac As Integer, _
                                 ByRef lFond As Long, ByRef lSablona As Long, ByRef lKalendar As Long)
    On Error GoTo Chyba
    Dim rs As DAO.Recordset, strSQL As String
    lFond = 1: lSablona = 1: lKalendar = 1
    If Not mod_00_Common.TabulkaExistujeDB(db, "ZamestnanciFondy") Then Exit Sub

    strSQL = "SELECT TOP 1 PracFondKod, ParPrerKod, KalendarKod FROM ZamestnanciFondy " & _
             "WHERE OsobneCislo = " & mod_00_Common.SqlText(strOC) & " AND (Rok * 12 + Mesiac) <= " & (CLng(iRok) * 12 + iMesiac) & _
             " ORDER BY (Rok * 12 + Mesiac) DESC;"
    Set rs = db.OpenRecordset(strSQL, dbOpenSnapshot)
    If rs.EOF Then
        rs.Close
        strSQL = "SELECT TOP 1 PracFondKod, ParPrerKod, KalendarKod FROM ZamestnanciFondy " & _
                 "WHERE OsobneCislo = " & mod_00_Common.SqlText(strOC) & " ORDER BY (Rok * 12 + Mesiac);"
        Set rs = db.OpenRecordset(strSQL, dbOpenSnapshot)
    End If
    If Not rs.EOF Then
        lFond = CLng(Val(Nz(rs!PracFondKod, 1)))
        lSablona = CLng(Val(Nz(rs!ParPrerKod, 1)))
        lKalendar = CLng(Val(Nz(rs!KalendarKod, 1)))
        If lFond <= 0 Then lFond = 1
        If lKalendar <= 0 Then lKalendar = 1
    End If
    rs.Close
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_08_UdalostiDna.NastaveniaZamestnanca", "ERROR", Err.Description, "OC=" & strOC)
End Sub

'-------------------------------------------------------------------------------
' Priemerná dĺžka pracovného dňa (min) fondu pre mesiac; pri chýbajúcom nastavení 450.
'-------------------------------------------------------------------------------
Public Function DlzkaFonduDna(ByRef db As DAO.Database, ByVal lFondID As Long, ByVal iRok As Integer, ByVal iMesiac As Integer) As Long
    Dim lDen As Long, lMes As Long, bPodla As Boolean, aTyz(1 To 7) As Long
    Call NacitajFondDna(db, lFondID, iRok, iMesiac, lDen, lMes, bPodla, aTyz)
    DlzkaFonduDna = lDen
End Function

'-------------------------------------------------------------------------------
' Parametre fondu platné pre mesiac (najnovšia verzia <= mesiac, inak najstaršia):
'   lDen    = priemerná dĺžka dňa (min), predvolene 450,
'   lMesiac = pevný mesačný fond (min) pri type 4 "Voľná s pevným mesačným fondom spolu za mesiac", inak 0,
'   bPodla  = fond má rôznu dĺžku podľa dňa v týždni; aTyz(1..7) = dĺžka v pondelok až nedeľu (min).
'-------------------------------------------------------------------------------
Private Sub NacitajFondDna(ByRef db As DAO.Database, ByVal lFondID As Long, ByVal iRok As Integer, ByVal iMesiac As Integer, _
                           ByRef lDen As Long, ByRef lMesiac As Long, ByRef bPodla As Boolean, ByRef aTyz() As Long)
    On Error GoTo Chyba
    Dim ym As Long, vBest As Variant, rs As DAO.Recordset, d As Long, strKrit As String
    lDen = 450: lMesiac = 0: bPodla = False
    For d = 1 To 7
        aTyz(d) = 0
    Next d
    If Not mod_00_Common.TabulkaExistujeDB(db, "PracovneFondy") Then Exit Sub
    ym = CLng(iRok) * 12 + iMesiac
    vBest = DMax("Rok * 12 + Mesiac", "PracovneFondy", "Cislo = " & lFondID & " AND (Rok * 12 + Mesiac) <= " & ym)
    If IsNull(vBest) Then vBest = DMin("Rok * 12 + Mesiac", "PracovneFondy", "Cislo = " & lFondID)
    If IsNull(vBest) Then Exit Sub
    strKrit = "Cislo = " & lFondID & " AND (Rok * 12 + Mesiac) = " & CLng(vBest)
    Set rs = db.OpenRecordset("SELECT * FROM PracovneFondy WHERE " & strKrit & ";", dbOpenSnapshot)
    If Not rs.EOF Then
        If CLng(Nz(rs!PriemernaDlzkaMin, 0)) > 0 Then lDen = CLng(rs!PriemernaDlzkaMin)
        If CLng(Nz(rs!TypFondu, 0)) = 4 Then lMesiac = CLng(Nz(rs!DlzkaMesiacaMin, 0))
        If mod_00_Common.PoleExistujeDB(db, "PracovneFondy", "FondPodlaDna") Then bPodla = CBool(Nz(rs!FondPodlaDna, False))
    End If
    rs.Close
    If bPodla And mod_00_Common.TabulkaExistujeDB(db, "PracovneFondyDni") Then
        ' dni 1 až 7 = pondelok až nedeľa; dĺžka bez prestávky (ak chýba, dĺžka s prestávkou)
        Set rs = db.OpenRecordset("SELECT Den, DlzkaBezPrestavkyMin, DlzkaSPrestavkouMin FROM PracovneFondyDni WHERE " & strKrit & _
                                  " AND Den >= 1 AND Den <= 7;", dbOpenSnapshot)
        Do While Not rs.EOF
            d = CLng(rs!Den)
            If CLng(Nz(rs!DlzkaBezPrestavkyMin, 0)) > 0 Then
                aTyz(d) = CLng(rs!DlzkaBezPrestavkyMin)
            Else
                aTyz(d) = CLng(Nz(rs!DlzkaSPrestavkouMin, 0))
            End If
            rs.MoveNext
        Loop
        rs.Close
    End If
    Exit Sub
Chyba:
    lDen = 450: lMesiac = 0: bPodla = False
End Sub

'-------------------------------------------------------------------------------
' Priemerný denný fond zamestnanca v mesiaci (používa editor na započítanie sviatkov).
'-------------------------------------------------------------------------------
Public Function FondZamestnanca(ByRef db As DAO.Database, ByVal strOC As String, ByVal iRok As Integer, ByVal iMesiac As Integer) As Long
    Dim lF As Long, lS As Long, lK As Long
    Call NastaveniaZamestnanca(db, strOC, iRok, iMesiac, lF, lS, lK)
    FondZamestnanca = CLng(DlzkaFonduDna(db, lF, iRok, iMesiac) * mod_15_Zamestnanci.UvazokZamestnanca(db, strOC, iRok, iMesiac) / 100)
End Function

'-------------------------------------------------------------------------------
' Pre každý deň mesiaca určí typ dňa (kalendár + sviatky + víkend) a denný fond zamestnanca.
' Typ dňa: prvé písmeno = kalendár (P pracovný, V voľný, S sviatok), druhé = deň v týždni (P pracovný, V sobota, N nedeľa).
'-------------------------------------------------------------------------------
Public Sub NacitajKontextMesiaca(ByRef db As DAO.Database, ByVal strOC As String, ByVal iRok As Integer, ByVal iMesiac As Integer, ByRef k As TKontextMesiaca)
    On Error GoTo Chyba
    Dim lFond As Long, lSab As Long, lKal As Long, lDlzkaDna As Long, lMesFond As Long, bPodlaDna As Boolean, aTyz(1 To 7) As Long
    Dim lUvazok As Long, nPrac As Long
    Dim rs As DAO.Recordset, d As Date, i As Long, iDen As Integer
    Dim kalZnak(1 To 31) As String, bSv(1 To 31) As Boolean
    Dim dOd As Date, dDoExkl As Date, strPref As String, strSuf As String, strTyp As String

    dOd = DateSerial(iRok, iMesiac, 1)
    dDoExkl = DateSerial(iRok, iMesiac + 1, 1)
    k.PocetDni = Day(DateSerial(iRok, iMesiac + 1, 0))

    Call NastaveniaZamestnanca(db, strOC, iRok, iMesiac, lFond, lSab, lKal)
    Call NacitajFondDna(db, lFond, iRok, iMesiac, lDlzkaDna, lMesFond, bPodlaDna, aTyz)
    lUvazok = mod_15_Zamestnanci.UvazokZamestnanca(db, strOC, iRok, iMesiac)

    If mod_00_Common.TabulkaExistujeDB(db, "KalendarDni") Then
        Set rs = db.OpenRecordset("SELECT Datum, TypDna FROM KalendarDni WHERE Kalendar = " & lKal & _
                                  " AND Datum >= " & mod_00_Common.SqlDatum(dOd) & " AND Datum < " & mod_00_Common.SqlDatum(dDoExkl) & ";", dbOpenSnapshot)
        Do While Not rs.EOF
            i = Day(CDate(rs!Datum))
            kalZnak(i) = UCase$(Left$(Trim$(CStr(Nz(rs!TypDna, ""))), 1))
            rs.MoveNext
        Loop
        rs.Close
    End If

    If mod_00_Common.TabulkaExistujeDB(db, "Sviatky") Then
        Dim strRokPod As String
        If mod_00_Common.PoleExistujeDB(db, "Sviatky", "Rok") Then strRokPod = " AND (Rok IS NULL OR Rok = " & iRok & ")"
        Set rs = db.OpenRecordset("SELECT Den FROM Sviatky WHERE Mesiac = " & iMesiac & strRokPod & ";", dbOpenSnapshot)
        Do While Not rs.EOF
            i = CLng(rs!Den)
            If i >= 1 And i <= 31 Then bSv(i) = True
            rs.MoveNext
        Loop
        rs.Close
    End If

    For i = 1 To 31
        k.Fond(i) = 0: k.Typ(i) = "": k.Sviatok(i) = False
    Next i
    For i = 1 To k.PocetDni
        d = DateSerial(iRok, iMesiac, i)
        iDen = Weekday(d, vbMonday)
        If Len(kalZnak(i)) = 0 Then kalZnak(i) = IIf(iDen >= 6, "V", "P")
        strPref = IIf(bSv(i), "S", kalZnak(i))
        strSuf = IIf(iDen = 7, "N", IIf(iDen = 6, "V", "P"))
        strTyp = strPref & strSuf
        k.Typ(i) = strTyp
        k.Sviatok(i) = bSv(i)
        If strPref = "P" And Not bSv(i) Then
            If bPodlaDna Then k.Fond(i) = aTyz(iDen) Else k.Fond(i) = lDlzkaDna
            nPrac = nPrac + 1
        Else
            k.Fond(i) = 0
        End If
    Next i
    ' pevný mesačný fond (typ 4): denný fond = mesačný fond / počet pracovných dní mesiaca
    If lMesFond > 0 And nPrac > 0 Then
        For i = 1 To k.PocetDni
            If k.Fond(i) > 0 Then k.Fond(i) = lMesFond \ nPrac
        Next i
    End If
    ' úväzok zamestnanca (napr. 50 % = polovičný denný fond)
    If lUvazok <> 100 Then
        For i = 1 To k.PocetDni
            If k.Fond(i) > 0 Then k.Fond(i) = CLng(k.Fond(i) * lUvazok / 100)
        Next i
    End If
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_08_UdalostiDna.NacitajKontextMesiaca", "ERROR", Err.Description, "OC=" & strOC)
End Sub
