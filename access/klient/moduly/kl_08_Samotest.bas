Attribute VB_Name = "kl_08_Samotest"
'@Verzia 1.0.1
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: kl_08_Samotest
' POPIS: Samotest klienta. Spúšťa ho zostavovač (Instaluj-Klienta.ps1) po zostavení a dá sa spustiť aj ručne z okna priamych
'        príkazov:  ? kl_08_Samotest.SamoTestKlienta()
'        Výsledok "OK n, ZLE m" vypíše do okna priamych príkazov a do log\samotest.txt (UTF-8) v lokálnom priečinku klienta.
'        Samotest NIKDY nezapisuje do priečinka prijem na serveri ani do lokálnej fronty razení.
'
'        ZLATÉ VEKTORY: volania OverVektor nižšie obsahujú vstupy a očakávaný súbor .rzn (každý riadok súboru jedna položka Array
'        v poradí). Ten istý zoznam číta tools/test_klient_zhoda.py a porovnáva ho bajt po bajte s tools/klient_protokol.py
'        (zostav). Tvar volaní OverVektor a OverZlyVzor preto NEMEŇ (jedno volanie = jeden logický riadok, len reťazce
'        v úvodzovkách a čísla); ak sa zmení pravidlo protokolu, zmeň vektor tu aj pravidlo v Pythone naraz.
' ZOZNAM VEREJNÝCH PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - SamoTestKlienta()   : Spustí všetky kontroly; vráti počet ZLE (0 = v poriadku).
' - VypisSamotestu()    : Text posledného samotestu.
'===============================================================================

Private mOk As Long
Private mZle As Long
Private mVypis As String

Private Sub Pis(ByVal s As String)
    mVypis = mVypis & s & vbCrLf
    Debug.Print s
End Sub

Private Sub Zaznam(ByVal bOk As Boolean, ByVal strCo As String)
    If bOk Then
        mOk = mOk + 1
        Call Pis("OK    " & strCo)
    Else
        mZle = mZle + 1
        Call Pis("ZLE   " & strCo)
    End If
End Sub

Public Function VypisSamotestu() As String
    VypisSamotestu = mVypis
End Function

'===============================================================================
' Zlatý vektor: zo vstupov zostaví text a porovná ho s očakávanými riadkami; potom ho skontroluje a overí, že kontrola vrátila
' tie isté hodnoty (zostav -> rozober).
'===============================================================================
Private Sub OverVektor(ByVal strMeno As String, ByVal strId As String, ByVal strOc As String, ByVal strLogin As String, ByVal strPc As String, _
                       ByVal strKod As String, ByVal strSmer As String, ByVal strCas As String, ByVal strUtc As String, _
                       ByVal lOdlozene As Long, ByVal strKlient As String, ByVal vRiadky As Variant)
    Dim dCas As Date, dUtc As Date, strText As String, strOcak As String, i As Long
    Dim strKodChyby As String, strDovod As String, r As TRazenie, bRovnake As Boolean

    If Not kl_02_Protokol.CasZTextu(strCas, dCas) Or Not kl_02_Protokol.CasZTextu(strUtc, dUtc) Then
        Call Zaznam(False, "vektor " & strMeno & ": neplatný čas vo vstupe")
        Exit Sub
    End If
    For i = LBound(vRiadky) To UBound(vRiadky)
        strOcak = strOcak & CStr(vRiadky(i)) & vbCrLf
    Next i
    strText = kl_02_Protokol.ZostavRazenie(strId, strOc, strLogin, strPc, strKod, strSmer, dCas, dUtc, (lOdlozene <> 0), strKlient)
    Call Zaznam(StrComp(strText, strOcak, vbBinaryCompare) = 0, "vektor " & strMeno & ": zostavený text sa zhoduje (" & Len(strText) & " bajtov)")

    strDovod = kl_02_Protokol.RozoberRazenie(strText, kl_02_Protokol.NazovSuboru(dCas, strId), strKodChyby, r)
    Call Zaznam(Len(strDovod) = 0, "vektor " & strMeno & ": kontrola prijala text" & IIf(Len(strDovod) > 0, " (" & strKodChyby & ": " & strDovod & ")", ""))
    bRovnake = (StrComp(r.Id, strId, vbBinaryCompare) = 0) And (StrComp(r.Oc, strOc, vbBinaryCompare) = 0) And (StrComp(r.Login, strLogin, vbBinaryCompare) = 0)
    bRovnake = bRovnake And (StrComp(r.Pc, strPc, vbBinaryCompare) = 0) And (StrComp(r.Kod, strKod, vbBinaryCompare) = 0) And (StrComp(r.Smer, strSmer, vbBinaryCompare) = 0)
    bRovnake = bRovnake And (r.Cas = dCas) And (r.Utc = dUtc) And (r.Odlozene = (lOdlozene <> 0)) And (StrComp(r.Klient, strKlient, vbBinaryCompare) = 0)
    Call Zaznam(bRovnake, "vektor " & strMeno & ": zostav -> rozober vráti tie isté hodnoty")
End Sub

'===============================================================================
' Zlý vzor (zrkadlo klient_protokol.zle_vzory): v dobrom súbore (vektor "zima") sa nahradí strHladaj za strNahrad (znak ~ znamená
' koniec riadka CRLF) a kontrola ho musí odmietnuť s kódom strOcakavany. Pri neprázdnom strNazov sa použije tento názov súboru.
'===============================================================================
Private Sub OverZlyVzor(ByVal strMeno As String, ByVal strHladaj As String, ByVal strNahrad As String, ByVal strNazov As String, ByVal strOcakavany As String)
    Dim dCas As Date, dUtc As Date, strText As String, strKodChyby As String, strDovod As String, r As TRazenie
    Const ID_VZORU As String = "00000000-0000-0000-0000-00000000000A"

    Call kl_02_Protokol.CasZTextu("2026-11-03T07:31:12", dCas)
    Call kl_02_Protokol.CasZTextu("2026-11-03T06:31:12", dUtc)
    strText = kl_02_Protokol.ZostavRazenie(ID_VZORU, "9000001", "test.zam1", "PC-TEST", "WORK", "IN", dCas, dUtc, False, "1.0.0")
    If Len(strHladaj) > 0 Then
        If InStr(1, strText, Replace(strHladaj, "~", vbCrLf), vbBinaryCompare) = 0 Then
            Call Zaznam(False, "zlý vzor " & strMeno & ": hľadaný text vo vzore nie je")
            Exit Sub
        End If
        strText = Replace(strText, Replace(strHladaj, "~", vbCrLf), Replace(strNahrad, "~", vbCrLf), 1, -1, vbBinaryCompare)
    End If
    If Len(strNazov) = 0 Then strNazov = kl_02_Protokol.NazovSuboru(dCas, ID_VZORU)
    strDovod = kl_02_Protokol.RozoberRazenie(strText, strNazov, strKodChyby, r)
    Call Zaznam(Len(strDovod) > 0 And StrComp(strKodChyby, strOcakavany, vbBinaryCompare) = 0, _
                "zlý vzor " & strMeno & ": odmietnutý s kódom " & strOcakavany & IIf(strKodChyby <> strOcakavany, " (vrátil '" & strKodChyby & "')", ""))
End Sub

Private Sub OverOdoslanie(ByVal lCisloChyby As Long, ByVal strOcakavany As String)
    Call Zaznam(kl_03_Fronta.VysledokOdoslania(lCisloChyby) = strOcakavany, "chyba odoslania " & lCisloChyby & " -> " & strOcakavany)
End Sub

Private Sub OverNeuspechy(ByVal lDoteraz As Long, ByVal strVysledok As String, ByVal lOcakavany As Long)
    Call Zaznam(kl_03_Fronta.NovyPocetNeuspechov(lDoteraz, strVysledok) = lOcakavany, "počítadlo neúspechov " & lDoteraz & " + " & strVysledok & " -> " & lOcakavany)
End Sub

' Tabuľka mapovania chýb odoslania (zrkadlo klient_protokol.vysledok_odoslania a novy_pocet_neuspechov).
Private Sub TestOdoslania()
    Dim dCas As Date, dUtc As Date, strFronta As String, strText As String, strNazov As String, d As Date, strDovod As String, bOk As Boolean
    Const ID_VZORU As String = "00000000-0000-0000-0000-00000000000A"

    Call Pis("--- odosielanie: mapovanie chýb")
    Call OverOdoslanie(0, "DORUCENE")
    Call OverOdoslanie(58, "EXISTUJE")
    Call OverOdoslanie(52, "NEDOSTUPNY")
    Call OverOdoslanie(53, "NEDOSTUPNY")
    Call OverOdoslanie(57, "NEDOSTUPNY")
    Call OverOdoslanie(67, "NEDOSTUPNY")
    Call OverOdoslanie(68, "NEDOSTUPNY")
    Call OverOdoslanie(71, "NEDOSTUPNY")
    Call OverOdoslanie(75, "NEDOSTUPNY")
    Call OverOdoslanie(76, "NEDOSTUPNY")
    Call OverOdoslanie(70, "PRISTUP")
    Call OverOdoslanie(5, "INA")
    Call OverOdoslanie(61, "INA")
    Call OverOdoslanie(-2147024891, "INA")
    Call OverNeuspechy(0, "PRISTUP", 1)
    Call OverNeuspechy(4, "PRISTUP", 5)
    Call OverNeuspechy(4, "INA", 5)
    Call OverNeuspechy(3, "NEDOSTUPNY", 3)
    Call OverNeuspechy(7, "DORUCENE", 0)
    Call OverNeuspechy(7, "EXISTUJE", 0)
    Call OverNeuspechy(2, "POSKODENE", 2)
    Call Zaznam(kl_03_Fronta.JeDorucene("DORUCENE") And kl_03_Fronta.JeDorucene("EXISTUJE") And Not kl_03_Fronta.JeDorucene("PRISTUP") And Not kl_03_Fronta.JeDorucene("NEDOSTUPNY"), "doručené je len DORUCENE a EXISTUJE")

    Call Pis("--- odosielanie: odlozene pri opakovanom pokuse")
    Call kl_02_Protokol.CasZTextu("2026-11-03T07:31:12", dCas)
    Call kl_02_Protokol.CasZTextu("2026-11-03T06:31:12", dUtc)
    strNazov = kl_02_Protokol.NazovSuboru(dCas, ID_VZORU)
    strFronta = kl_02_Protokol.ZostavRazenie(ID_VZORU, "9000001", "test.zam1", "PC-TEST", "WORK", "IN", dCas, dUtc, False, "1.0.0")
    strDovod = kl_03_Fronta.TextPreOdoslanie(strFronta, strNazov, False, strText)
    Call Zaznam(Len(strDovod) = 0 And StrComp(strText, strFronta, vbBinaryCompare) = 0, "pokus pri razení posiela text z fronty (odlozene=0)")
    strDovod = kl_03_Fronta.TextPreOdoslanie(strFronta, strNazov, True, strText)
    Call Zaznam(Len(strDovod) = 0 And StrComp(strText, kl_02_Protokol.ZostavRazenie(ID_VZORU, "9000001", "test.zam1", "PC-TEST", "WORK", "IN", dCas, dUtc, True, "1.0.0"), vbBinaryCompare) = 0, _
                "pokus z časovača posiela ten istý text s odlozene=1")
    strDovod = kl_03_Fronta.TextPreOdoslanie(Replace(strFronta, "#END", "#KON"), strNazov, True, strText)
    Call Zaznam(Len(strDovod) > 0 And Len(strText) = 0, "poškodený text z fronty sa neodošle")
    bOk = kl_03_Fronta.DatumZNazvu(strNazov, d)
    Call Zaznam(bOk And kl_02_Protokol.CasNaText(d) = "2026-11-03T07:31:12", "deň a čas z názvu súboru")
End Sub

Private Sub OverIdentitu(ByVal strMeno As String, ByVal strLogin As String, ByVal lLokalny As Long, ByVal strTestIni As String, ByVal strOcAd As String, _
                         ByVal strIdentitaTxt As String, ByVal strOcakOc As String, ByVal strOcakZdroj As String)
    Dim strOc As String, strZdroj As String, strChyba As String
    strChyba = kl_01_Identita.RozhodniIdentitu(strLogin, (lLokalny <> 0), Replace(strTestIni, "~", vbCrLf), strOcAd, Replace(strIdentitaTxt, "~", vbCrLf), strOc, strZdroj)
    Call Zaznam(strOc = strOcakOc And strZdroj = strOcakZdroj And ((Len(strChyba) = 0) = (Len(strOcakOc) > 0)), _
                "identita " & strMeno & ": zdroj '" & strOcakZdroj & "'" & IIf(strZdroj <> strOcakZdroj, " (vrátil '" & strZdroj & "')", ""))
End Sub

' Rozhodnutie o identite na pevných vstupoch (znak ~ znamená koniec riadka; TESTB je vymyslená hodnota odlišná od 9000001). Posledné dva argumenty: očakávané osobné číslo a zdroj.
Private Sub TestIdentity()
    Call Pis("--- identita: poradie zdrojov")
    Call OverIdentitu("z AD", "test.zam1", 0, "", "9000001", "", "9000001", "AD")
    Call OverIdentitu("AD má prednosť pred uloženou", "test.zam1", 0, "", "9000001", "login=test.zam1~oc=TESTB~", "9000001", "AD")
    Call OverIdentitu("uložená pri nedostupnom AD", "test.zam1", 0, "", "", "login=test.zam1~oc=9000001~cas=2026-11-03T07:00:00~", "9000001", "CACHE")
    Call OverIdentitu("uložená, účet inou veľkosťou písmen", "Test.Zam1", 0, "", "", "login=test.zam1~oc=9000001~", "9000001", "CACHE")
    Call OverIdentitu("uložená pre iný účet sa nepoužije", "iny.ucet", 0, "", "", "login=test.zam1~oc=9000001~", "", "")
    Call OverIdentitu("bez AD aj bez uloženej", "test.zam1", 0, "", "", "", "", "")
    Call OverIdentitu("test pri lokálnej ceste", "test.zam1", 1, "oc_test=9000001~", "", "", "9000001", "TEST")
    Call OverIdentitu("test má pri lokálnej ceste prednosť pred AD", "test.zam1", 1, "oc_test=9000001", "TESTB", "", "9000001", "TEST")
    Call OverIdentitu("test.ini sa pri sieťovej ceste ignoruje", "test.zam1", 0, "oc_test=9000001~", "", "", "", "")
    Call OverIdentitu("test.ini pri sieťovej ceste nemení AD", "test.zam1", 0, "oc_test=9000001~", "TESTB", "", "TESTB", "AD")
    Call OverIdentitu("neplatné oc_test, lokálna cesta, AD", "test.zam1", 1, "oc_test=90 00~", "TESTB", "", "TESTB", "AD")
    Call OverIdentitu("neplatné osobné číslo z AD", "test.zam1", 0, "", "90-00/1", "", "", "")
    Call OverIdentitu("účet s nepovoleným znakom", "test zam1", 0, "", "9000001", "", "", "")
    Call Zaznam(kl_01_Identita.OcZIdentity(kl_01_Identita.TextIdentity("test.zam1", "9000001", DateSerial(2026, 11, 3)), "test.zam1") = "9000001", "identita.txt: zápis a spätné čítanie")
    Call Zaznam(kl_00_Spolocne.JeLokalnaCesta("C:\dochadzka-test") And Not kl_00_Spolocne.JeLokalnaCesta("\\server\dochadzka") And Not kl_00_Spolocne.JeLokalnaCesta(""), "lokálna a sieťová cesta základu")
End Sub

Private Sub OverKonfig(ByVal strMeno As String, ByVal strObsah As String, ByVal lOcakPocet As Long, ByVal strOcakTlacidla As String, _
                       ByVal strOcakOdchod As String, ByVal strOcakVytvorene As String, ByVal strOcakPreskocene As String)
    Dim kody() As String, texty() As String, strOdchod As String, strVytvorene As String, strPreskocene As String, n As Long, i As Long, s As String
    n = kl_04_Konfig.RozoberKonfig(Replace(strObsah, "~", vbCrLf), kody, texty, strOdchod, strVytvorene, strPreskocene)
    For i = 0 To n - 1
        s = s & IIf(i > 0, "|", "") & kody(i) & "=" & texty(i)
    Next i
    If n < 0 Then
        Call Zaznam(lOcakPocet = -1, "konfigurácia " & strMeno & ": nie je konfigurácia")
    Else
        Call Zaznam(n = lOcakPocet And StrComp(s, strOcakTlacidla, vbBinaryCompare) = 0 And strOdchod = strOcakOdchod And strVytvorene = strOcakVytvorene And strPreskocene = strOcakPreskocene, _
                    "konfigurácia " & strMeno & ": tlačidiel " & lOcakPocet & ", preskočené riadky '" & strOcakPreskocene & "'" & IIf(strPreskocene <> strOcakPreskocene, " (vrátil '" & strPreskocene & "')", ""))
    End If
End Sub

' Rozbor konfigurácie (zrkadlo klient_protokol.rozober_konfig). Znak ~ znamená koniec riadka. Vektor "vzor" je obsah súboru
' access/klient/testy/klient_konfig_vzor.txt. Argumenty: meno, obsah, počet tlačidiel (-1 = nie je konfigurácia),
' tlačidlá KOD=text oddelené |, odchod_bez_dovodu, vytvorene, čísla preskočených riadkov.
Private Sub TestKonfigu()
    Call Pis("--- konfigurácia: rozbor klient_konfig.txt")
    Call OverKonfig("vzor", "DOCHSKLIENT;1~vytvorene=2026-11-15T08:00:00~odchod_bez_dovodu=OBED~tlacidlo=1;DOCTOR;Lekár;stethoscope~tlacidlo=2;TRIP;Služobne;briefcase~tlacidlo=3;NIECO;Neznámy kód;x~tlacidlo=4;FAMILY;Tento text je dlhší než dvadsaťštyri znakov;x~tlacidlo=5;PRIV~buduci_kluc=hodnota~riadok bez rovnitka~tlacidlo=6;DOCTOR;Lekár druhýkrát;x~tlacidlo=7;ERRAND;Pochôdzka;~tlacidlo=x;SICK;Choroba;x~tlacidlo=8;WORK;Práca;x~#END~", _
        4, "DOCTOR=Lekár|TRIP=Služobne|DOCTOR=Lekár druhýkrát|ERRAND=Pochôdzka", "OBED", "2026-11-15T08:00:00", "6,7,8,10,13,14")
    Call OverKonfig("bez tlačidiel", "DOCHSKLIENT;1~vytvorene=2026-11-15T08:00:00~odchod_bez_dovodu=ODCHOD~#END~", 0, "", "ODCHOD", "2026-11-15T08:00:00", "")
    Call OverKonfig("len hlavička a koniec, bez posledného konca riadka", "DOCHSKLIENT;1~#END", 0, "", "OBED", "", "")
    Call OverKonfig("neznáma hodnota odchod_bez_dovodu", "DOCHSKLIENT;1~odchod_bez_dovodu=NIECO~tlacidlo=1;SICK;PN;x~#END~", 1, "SICK=PN", "OBED", "", "2")
    Call OverKonfig("medzery a prázdne riadky", "DOCHSKLIENT;1~~  tlacidlo = 10 ; PRIV ; Súkromne ; x  ~~#END~~~", 1, "PRIV=Súkromne", "OBED", "", "")
    Call OverKonfig("text presne 24 znakov", "DOCHSKLIENT;1~tlacidlo=1;LEAVE;123456789012345678901234;~tlacidlo=2;LEAVE;1234567890123456789012345;~#END~", 1, "LEAVE=123456789012345678901234", "OBED", "", "3")
    Call OverKonfig("najviac 12 tlačidiel", "DOCHSKLIENT;1~tlacidlo=1;DOCTOR;A1;~tlacidlo=2;DOCTOR;A2;~tlacidlo=3;DOCTOR;A3;~tlacidlo=4;DOCTOR;A4;~tlacidlo=5;DOCTOR;A5;~tlacidlo=6;DOCTOR;A6;~tlacidlo=7;DOCTOR;A7;~tlacidlo=8;DOCTOR;A8;~tlacidlo=9;DOCTOR;A9;~tlacidlo=10;DOCTOR;A10;~tlacidlo=11;DOCTOR;A11;~tlacidlo=12;DOCTOR;A12;~tlacidlo=13;DOCTOR;A13;~tlacidlo=14;TRIP;A14;~#END~", _
        12, "DOCTOR=A1|DOCTOR=A2|DOCTOR=A3|DOCTOR=A4|DOCTOR=A5|DOCTOR=A6|DOCTOR=A7|DOCTOR=A8|DOCTOR=A9|DOCTOR=A10|DOCTOR=A11|DOCTOR=A12", "OBED", "", "")
    Call OverKonfig("zlá hlavička", "DOCHSKLIENT;2~tlacidlo=1;DOCTOR;Lekár;x~#END~", -1, "", "", "", "")
    Call OverKonfig("hlavička malými písmenami", "dochsklient;1~#END~", -1, "", "", "", "")
    Call OverKonfig("bez konca (nedopísaný súbor)", "DOCHSKLIENT;1~tlacidlo=1;DOCTOR;Lekár;x~", -1, "", "", "", "")
    Call OverKonfig("prázdny súbor", "", -1, "", "", "", "")
    Call OverKonfig("kód malými písmenami sa preskočí", "DOCHSKLIENT;1~tlacidlo=1;doctor;Lekár;x~TLACIDLO=2;TRIP;Cesta;x~#END~", 0, "", "OBED", "", "2")
    Call Zaznam(kl_00_Spolocne.Utf8NaText(ChrW$(&HEF) & ChrW$(&HBB) & ChrW$(&HBF) & "Lek" & ChrW$(&HC3) & ChrW$(&HA1) & "r " & ChrW$(&HC5) & ChrW$(&HBE)) = "Lek" & ChrW$(225) & "r " & ChrW$(382), "prevod UTF-8 s BOM na text (á, ž)")
End Sub

Private Sub OverStav(ByVal strMeno As String, ByVal strRazenia As String, ByVal strOcakStav As String, ByVal strNazovPrerusenia As String, ByVal strOcakPopis As String)
    Dim strStav As String
    strStav = kl_05_Razenie.StavDna(strRazenia)
    Call Zaznam(StrComp(strStav, strOcakStav, vbBinaryCompare) = 0 And StrComp(kl_05_Razenie.PopisStavu(strStav, strNazovPrerusenia), strOcakPopis, vbBinaryCompare) = 0, _
                "stav dňa " & strMeno & ": " & strOcakStav & IIf(strStav <> strOcakStav, " (vrátil '" & strStav & "')", ""))
End Sub

Private Sub OverOtazku(ByVal strMeno As String, ByVal strRazenia As String, ByVal strKod As String, ByVal strSmer As String, ByVal strUtcTeraz As String, ByVal strOcakavana As String)
    Dim s As String
    s = kl_05_Razenie.OtazkaPredRazenim(strRazenia, strKod, strSmer, strUtcTeraz)
    Call Zaznam(StrComp(s, strOcakavana, vbBinaryCompare) = 0, "otázka pred razením " & strMeno & ": '" & strOcakavana & "'" & IIf(s <> strOcakavana, " (vrátil '" & s & "')", ""))
End Sub

' Stav dňa a otázky pred razením (zrkadlo klient_protokol.stav_dna, popis_stavu, otazka_pred_razenim).
' Razenia dňa: položky oddelené |, položka utc;cas;KOD;SMER.
Private Sub TestStavuDna()
    Call Pis("--- razenie: stav dňa")
    Call OverStav("bez razení", "", "ZIADNE", "", "Dnes ešte bez razenia")
    Call OverStav("príchod", "2026-11-03T06:31:12;2026-11-03T07:31:12;WORK;IN", "PRACA;07:31", "", "V práci od 07:31")
    Call OverStav("odchod", "2026-11-03T06:31:12;2026-11-03T07:31:12;WORK;IN|2026-11-03T10:30:05;2026-11-03T11:30:05;WORK;OUT", "MIMO;11:30", "", "Mimo práce od 11:30")
    Call OverStav("prerušenie s textom z konfigurácie", "2026-11-03T06:31:12;2026-11-03T07:31:12;WORK;IN|2026-11-03T12:15:00;2026-11-03T13:15:00;DOCTOR;OUT", "PRERUSENIE;DOCTOR;13:15", "Lekár", "Prerušenie: Lekár od 13:15")
    Call OverStav("prerušenie bez textu", "2026-11-03T12:15:00;2026-11-03T13:15:00;TRIP;OUT", "PRERUSENIE;TRIP;13:15", "", "Prerušenie: TRIP od 13:15")
    Call OverStav("návrat z prerušenia", "2026-11-03T12:15:00;2026-11-03T13:15:00;DOCTOR;OUT|2026-11-03T12:58:30;2026-11-03T13:58:30;WORK;IN", "PRACA;13:58", "", "V práci od 13:58")
    Call OverStav("koniec prerušenia jeho kódom", "2026-11-03T12:15:00;2026-11-03T13:15:00;DOCTOR;OUT|2026-11-03T12:58:30;2026-11-03T13:58:30;DOCTOR;IN", "PRACA;13:58", "", "V práci od 13:58")
    Call OverStav("rozhoduje utc, nie poradie v zozname", "2026-11-03T10:30:05;2026-11-03T11:30:05;WORK;OUT|2026-11-03T06:31:12;2026-11-03T07:31:12;WORK;IN", "MIMO;11:30", "", "Mimo práce od 11:30")
    Call OverStav("zmena času: rozhoduje utc", "2026-10-25T00:50:00;2026-10-25T02:50:00;WORK;IN|2026-10-25T01:10:00;2026-10-25T02:10:00;WORK;OUT", "MIMO;02:10", "", "Mimo práce od 02:10")
    Call OverStav("rovnaké utc: neskoršie v zozname", "2026-11-03T06:31:12;2026-11-03T07:31:12;WORK;IN|2026-11-03T06:31:12;2026-11-03T07:31:12;WORK;OUT", "MIMO;07:31", "", "Mimo práce od 07:31")
    Call OverStav("neplatné položky sa ignorujú", "nieco|2026-11-03T06:31:12;2026-11-03T07:31:12;NIECO;IN|2026-13-03T06:31:12;2026-11-03T07:31:12;WORK;IN|2026-11-03T06:31:12;2026-11-03T07:31:12;WORK;VON", "ZIADNE", "", "Dnes ešte bez razenia")

    Call Pis("--- razenie: otázky pred razením")
    Call OverOtazku("prvý príchod", "", "WORK", "IN", "2026-11-03T06:31:12", "")
    Call OverOtazku("odchod bez príchodu", "", "WORK", "OUT", "2026-11-03T14:36:02", "BEZ_PRICHODU")
    Call OverOtazku("odchod po príchode", "2026-11-03T06:31:12;2026-11-03T07:31:12;WORK;IN", "WORK", "OUT", "2026-11-03T14:36:02", "")
    Call OverOtazku("rovnaké razenie po 119 s", "2026-11-03T06:31:12;2026-11-03T07:31:12;WORK;IN", "WORK", "IN", "2026-11-03T06:33:11", "OPAKOVANE")
    Call OverOtazku("rovnaké razenie po 120 s", "2026-11-03T06:31:12;2026-11-03T07:31:12;WORK;IN", "WORK", "IN", "2026-11-03T06:33:12", "")
    Call OverOtazku("iné razenie hneď po predošlom", "2026-11-03T06:31:12;2026-11-03T07:31:12;WORK;IN", "DOCTOR", "OUT", "2026-11-03T06:31:20", "")
    Call OverOtazku("druhý odchod hneď po prvom", "2026-11-03T06:31:12;2026-11-03T07:31:12;WORK;IN|2026-11-03T14:36:02;2026-11-03T15:36:02;WORK;OUT", "WORK", "OUT", "2026-11-03T14:36:30", "OPAKOVANE")
    Call OverOtazku("odchod, dnes len prerušenie", "2026-11-03T12:15:00;2026-11-03T13:15:00;DOCTOR;OUT", "WORK", "OUT", "2026-11-03T14:36:02", "BEZ_PRICHODU")
    Call OverOtazku("prerušenie bez príchodu sa nepýta", "", "DOCTOR", "OUT", "2026-11-03T12:15:00", "")
    Call OverOtazku("hodiny posunuté späť", "2026-11-03T06:31:12;2026-11-03T07:31:12;WORK;IN", "WORK", "IN", "2026-11-03T06:30:00", "OPAKOVANE")

    Call Pis("--- razenie: ostatné pravidlá")
    Call Zaznam(kl_05_Razenie.PlatnyPosun(60) And kl_05_Razenie.PlatnyPosun(120) And Not kl_05_Razenie.PlatnyPosun(0) And Not kl_05_Razenie.PlatnyPosun(180) And Not kl_05_Razenie.PlatnyPosun(-300), "posun oproti UTC: len 60 a 120 minút")
    Call Zaznam(kl_05_Razenie.PovoleneRazenie("WORK", "IN") And kl_05_Razenie.PovoleneRazenie("WORK", "OUT") And kl_05_Razenie.PovoleneRazenie("DOCTOR", "OUT") And _
                Not kl_05_Razenie.PovoleneRazenie("DOCTOR", "IN") And Not kl_05_Razenie.PovoleneRazenie("NIECO", "OUT") And Not kl_05_Razenie.PovoleneRazenie("WORK", "VON"), "povolené dvojice kód/smer")
    Call Zaznam(kl_05_Razenie.NazovRazenia("WORK", "IN", "") = "Príchod" And kl_05_Razenie.NazovRazenia("WORK", "OUT", "") = "Odchod" And kl_05_Razenie.NazovRazenia("DOCTOR", "OUT", "Lekár") = "Lekár", "názvy razení pre zoznam Dnes")
End Sub

' Súbory v lokálnom priečinku klienta (nikdy nie na serveri) a informatívny výpis prostredia.
Private Sub TestProstredia()
    Dim strChyba As String, strCesta As String, strText As String, strSpat As String, dtCas As Date, dtUtc As Date, lPosun As Long, strId As String
    Dim strOc As String, strLogin As String, strPc As String, strZdroj As String, bOk As Boolean

    Call Pis("--- lokálny priečinok a súbory")
    strChyba = kl_00_Spolocne.PripravLokalnePriecinky()
    Call Zaznam(Len(strChyba) = 0, "lokálne priečinky klienta existujú" & IIf(Len(strChyba) > 0, " (" & strChyba & ")", ""))
    If Len(strChyba) = 0 Then
        strCesta = kl_00_Spolocne.LokalnyPriecinok() & "\" & kl_00_Spolocne.PRIECINOK_LOG & "\samotest_skuska.txt"
        strText = "DOCHSRZN;1" & vbCrLf & "skuska=1" & vbCrLf & "#END" & vbCrLf
        Call Zaznam(kl_00_Spolocne.ZapisAsciiNovy(strCesta, strText) = 0, "zápis skúšobného súboru")
        bOk = kl_00_Spolocne.CitajBajty(strCesta, strSpat)
        Call Zaznam(bOk And StrComp(strSpat, strText, vbBinaryCompare) = 0, "čítanie skúšobného súboru vráti zapísaný text")
        Call Zaznam(kl_00_Spolocne.VelkostSuboru(strCesta) = Len(strText), "veľkosť skúšobného súboru v bajtoch")
        bOk = (kl_00_Spolocne.ZmazSubor(strCesta) = 0)
        Call Zaznam(bOk And Not kl_00_Spolocne.SuborExistuje(strCesta), "zmazanie skúšobného súboru")
    End If
    strText = "Príchod " & ChrW$(382) & ChrW$(318) & ChrW$(8230)
    Call Zaznam(StrComp(kl_00_Spolocne.Utf8NaText(kl_00_Spolocne.TextNaUtf8(strText)), strText, vbBinaryCompare) = 0, "prevod textu do UTF-8 a späť")
    strId = kl_00_Spolocne.NoveGuid()
    Call Zaznam(kl_02_Protokol.JeGuidRazenia(strId) And strId <> kl_00_Spolocne.NoveGuid(), "nové ID razenia má tvar GUID a neopakuje sa")
    Call kl_00_Spolocne.CasTeraz(dtCas, dtUtc, lPosun)
    Call Zaznam(DateDiff("s", dtUtc, dtCas) = lPosun * 60 And Abs(DateDiff("s", dtCas, Now)) <= 2, "miestny čas = UTC + posun v celých minútach")

    Call Pis("--- informácie (nehodnotí sa)")
    Call Pis("INFO  verzia klienta " & kl_00_Spolocne.VERZIA_KLIENTA)
    Call Pis("INFO  lokálny priečinok: " & kl_00_Spolocne.LokalnyPriecinok())
    Call Pis("INFO  základ na serveri (zaklad.txt): " & IIf(Len(kl_00_Spolocne.ZakladPriecinok()) > 0, kl_00_Spolocne.ZakladPriecinok(), "nie je nastavený"))
    Call Pis("INFO  čas " & kl_02_Protokol.CasNaText(dtCas) & ", UTC " & kl_02_Protokol.CasNaText(dtUtc) & ", posun " & lPosun & " min" & IIf(kl_05_Razenie.PlatnyPosun(lPosun), "", " (MIMO pásma Bratislava: razenie by sa nezapísalo)"))
    If kl_01_Identita.ZistiIdentitu(strOc, strLogin, strPc, strZdroj, strChyba) Then
        Call Pis("INFO  identita: osobné číslo " & strOc & ", účet " & strLogin & ", zdroj " & strZdroj)
    Else
        Call Pis("INFO  identita nezistená: " & strChyba)
    End If
End Sub

Private Sub TestProtokolu()
    Dim strKodChyby As String, r As TRazenie, strDovod As String

    Call Pis("--- protokol: zlaté vektory")
    Call OverVektor("leto", "3F2A9C1E-7B64-4D0A-9E85-1C2D3E4F5A6B", "9000001", "test.zam1", "PC-TEST", "WORK", "IN", "2026-07-01T07:31:12", "2026-07-01T05:31:12", 0, "1.0.0", _
        Array("DOCHSRZN;1", "id=3F2A9C1E-7B64-4D0A-9E85-1C2D3E4F5A6B", "oc=9000001", "login=test.zam1", "pc=PC-TEST", "kod=WORK", _
              "smer=IN", "cas=2026-07-01T07:31:12", "utc=2026-07-01T05:31:12", "odlozene=0", "klient=1.0.0", "#END"))
    Call OverVektor("zima", "00000000-0000-0000-0000-00000000000A", "9000001", "test.zam1", "PC-TEST", "WORK", "IN", "2026-11-03T07:31:12", "2026-11-03T06:31:12", 0, "1.0.0", _
        Array("DOCHSRZN;1", "id=00000000-0000-0000-0000-00000000000A", "oc=9000001", "login=test.zam1", "pc=PC-TEST", "kod=WORK", _
              "smer=IN", "cas=2026-11-03T07:31:12", "utc=2026-11-03T06:31:12", "odlozene=0", "klient=1.0.0", "#END"))
    Call OverVektor("odlozene", "A1B2C3D4-0001-4000-8000-0123456789AB", "9000001", "test.zam1", "PC-TEST", "WORK", "OUT", "2026-11-03T15:36:02", "2026-11-03T14:36:02", 1, "1.0.0", _
        Array("DOCHSRZN;1", "id=A1B2C3D4-0001-4000-8000-0123456789AB", "oc=9000001", "login=test.zam1", "pc=PC-TEST", "kod=WORK", _
              "smer=OUT", "cas=2026-11-03T15:36:02", "utc=2026-11-03T14:36:02", "odlozene=1", "klient=1.0.0", "#END"))
    Call OverVektor("prerusenie", "FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF", "9000001", "test.zam1", "PC-TEST", "DOCTOR", "OUT", "2026-11-03T13:15:00", "2026-11-03T12:15:00", 0, "1.0.0", _
        Array("DOCHSRZN;1", "id=FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF", "oc=9000001", "login=test.zam1", "pc=PC-TEST", "kod=DOCTOR", _
              "smer=OUT", "cas=2026-11-03T13:15:00", "utc=2026-11-03T12:15:00", "odlozene=0", "klient=1.0.0", "#END"))
    Call OverVektor("polnoc", "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9", "9000001", "test.zam1", "PC-TEST", "WORK", "OUT", "2026-01-01T00:30:00", "2025-12-31T23:30:00", 0, "1.0.0", _
        Array("DOCHSRZN;1", "id=0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9", "oc=9000001", "login=test.zam1", "pc=PC-TEST", "kod=WORK", _
              "smer=OUT", "cas=2026-01-01T00:30:00", "utc=2025-12-31T23:30:00", "odlozene=0", "klient=1.0.0", "#END"))

    Call Pis("--- protokol: zlé vzory (kontrola ich musí odmietnuť)")
    Call OverZlyVzor("bez_konca", "#END~", "", "", "KONIEC")
    Call OverZlyVzor("hlavicka", "DOCHSRZN;1", "DOCHSRZN;2", "", "HLAVICKA")
    Call OverZlyVzor("kod", "kod=WORK", "kod=NIECO", "", "HODNOTA")
    Call OverZlyVzor("smer", "smer=IN", "smer=VON", "", "HODNOTA")
    Call OverZlyVzor("cas", "cas=2026-11-03T07:31:12", "cas=2026-13-03T07:31:12", "", "CAS")
    Call OverZlyVzor("utc_posun", "utc=2026-11-03T06:31:12", "utc=2026-11-03T04:31:12", "", "CAS")
    Call OverZlyVzor("dvojity_kluc", "pc=PC-TEST", "pc=PC-TEST~pc=PC-INY", "", "KLUC")
    Call OverZlyVzor("nazov_inak", "", "", "zle_nazov_inak.rzn", "NAZOV")

    Call Pis("--- protokol: ďalšie hranice")
    strDovod = kl_02_Protokol.RozoberRazenie(String$(2049, "A"), "", strKodChyby, r)
    Call Zaznam(Len(strDovod) > 0 And strKodChyby = "VELKOST", "text dlhší než 2048 bajtov je odmietnutý (VELKOST)")
    strDovod = kl_02_Protokol.RozoberRazenie("DOCHSRZN;1" & vbCrLf & "oc=" & ChrW$(225) & vbCrLf & "#END" & vbCrLf, "", strKodChyby, r)
    Call Zaznam(Len(strDovod) > 0 And strKodChyby = "ZNAKY", "znak mimo ASCII je odmietnutý (ZNAKY)")
    Call Zaznam(kl_02_Protokol.NazovSuboru(DateSerial(2026, 11, 3) + TimeSerial(7, 31, 12), "00000000-0000-0000-0000-00000000000A") = "20261103-073112_00000000-0000-0000-0000-00000000000A.rzn", "názov súboru má tvar RRRRMMDD-HHMMSS_<id>.rzn")
End Sub

' Texty okna (kl_06_Okno): čisté funkcie bez prístupu k formuláru.
Private Sub TestOkna()
    Call Pis("--- okno: texty")
    Call Zaznam(kl_06_Okno.TextTlacidlaPreOkno("Lekár & ošetrenie") = "Lekár && ošetrenie", "znak & v texte tlačidla sa zdvojí")
    Call Zaznam(kl_06_Okno.TextCakajucich(0, True) = "Čaká na odoslanie: 0", "bez čakajúcich sa server nespomína")
    Call Zaznam(kl_06_Okno.TextCakajucich(3, True) = "Čaká na odoslanie: 3 (server nedostupný)", "čakajúce a server nedostupný")
    Call Zaznam(kl_06_Okno.TextCakajucich(3, False) = "Čaká na odoslanie: 3", "čakajúce, server dostupný")
    Call Zaznam(Len(kl_06_Okno.TextUpozornenia(False, 0)) = 0 And Len(kl_06_Okno.TextUpozornenia(False, 1)) = 0, "bez upozornenia do 1 dňa čakania")
    Call Zaznam(kl_06_Okno.TextUpozornenia(False, 2) = "Razenie čaká už 2 dni, HR ho nemusí prijať.", "upozornenie od 2 dní (2 dni)")
    Call Zaznam(kl_06_Okno.TextUpozornenia(False, 5) = "Razenie čaká už 5 dní, HR ho nemusí prijať.", "upozornenie od 2 dní (5 dní)")
    Call Zaznam(Left$(kl_06_Okno.TextUpozornenia(True, 4), 20) = "Problém s právami na", "problém s právami má prednosť")
    Call Zaznam(kl_06_Okno.DruhSpravy("") = "" And kl_06_Okno.DruhSpravy("Zapísané a odoslané 07:31") = "OK", "druh správy: prázdna a odoslané")
    Call Zaznam(kl_06_Okno.DruhSpravy("Zapísané 07:31 (server nedostupný)") = "CAKA" And kl_06_Okno.DruhSpravy("Razenie sa nezapísalo") = "CHYBA", "druh správy: čaká a chyba")
    Call Zaznam(kl_06_Okno.RiadokIdentity("", "", "") = "Osobné číslo: nezistené", "identita: nezistená")
    Call Zaznam(kl_06_Okno.RiadokIdentity("9000001", "test.zam1", "AD") = "Osobné číslo 9000001 · účet test.zam1", "identita: z Active Directory")
    Call Zaznam(InStr(kl_06_Okno.RiadokIdentity("9000001", "test.zam1", "CACHE"), "vyrovnávacej pamäte") > 0, "identita: z vyrovnávacej pamäte sa označí")
    Call Zaznam(Len(kl_06_Okno.TextPriKonci(0)) = 0 And Left$(kl_06_Okno.TextPriKonci(1), 8) = "1 razeni", "upozornenie pri konci: 0 a 1 razenie")
    Call Zaznam(Left$(kl_06_Okno.TextPriKonci(3), 28) = "3 razenia čakajú na odoslani" And Left$(kl_06_Okno.TextPriKonci(7), 22) = "7 razení čaká na odosl", "upozornenie pri konci: 3 a 7 razení")
    Call Zaznam(kl_06_Okno.NazovPrichodu(False) = "Príchod" And kl_06_Okno.NazovPrichodu(True) = "Návrat do práce", "názov tlačidla Príchod")
    Call Zaznam(kl_06_Okno.VelkostPismaSpravy("Zapísané 07:31") = 11 And kl_06_Okno.VelkostPismaSpravy(String$(60, "x")) = 11 And kl_06_Okno.VelkostPismaSpravy(String$(61, "x")) = 9, "veľkosť písma správy podľa dĺžky")
    Call Zaznam(kl_06_Okno.TextSpravyPreOkno(String$(76, "x")) = String$(76, "x") And kl_06_Okno.TextSpravyPreOkno(String$(77, "x")) = String$(73, "x") & "...", "dlhá správa sa skráti na 76 znakov")
    Call Zaznam(Len(kl_01_Identita.CHYBA_OC) <= 60 And Len(kl_01_Identita.CHYBA_UCET) <= 60 And Len(kl_01_Identita.CHYBA_PC) <= 60 And Len(kl_07_Spustenie.SPRAVA_BEZ_ZAKLADU) <= 60, "základné chybové texty sa zmestia do riadku okna")
    Call Zaznam(kl_06_Okno.PomocnyTextOdchodu("OBED") <> kl_06_Okno.PomocnyTextOdchodu("ODCHOD"), "pomocný text odchodu podľa konfigurácie")
    Call Zaznam(Left$(kl_06_Okno.RiadokDnes("07:31", "Príchod", True), 10) = "07:31   Pr" And Right$(kl_06_Okno.RiadokDnes("07:31", "Príchod", True), 8) = "odoslané", "riadok Dnes: odoslané")
    Call Zaznam(Right$(kl_06_Okno.RiadokDnes("14:36", "Odchod", False), 17) = "čaká na odoslanie", "riadok Dnes: čaká")
End Sub

'===============================================================================
' Hlavný vstup. Vráti počet ZLE.
'===============================================================================
Public Function SamoTestKlienta() As Long
    mOk = 0
    mZle = 0
    mVypis = ""
    Call Pis("SAMOTEST KLIENTA " & Format$(Now, "yyyy\-mm\-dd hh:nn:ss"))
    On Error GoTo Chyba
    Call TestProtokolu
    Call TestOdoslania
    Call TestIdentity
    Call TestKonfigu
    Call TestStavuDna
    Call TestOkna
    Call TestProstredia
Koniec:
    Call Pis("SÚHRN: OK " & mOk & ", ZLE " & mZle)
    SamoTestKlienta = mZle
    On Error Resume Next
    If Len(kl_00_Spolocne.LokalnyPriecinok()) > 0 Then
        If kl_00_Spolocne.VytvorPriecinok(kl_00_Spolocne.LokalnyPriecinok() & "\" & kl_00_Spolocne.PRIECINOK_LOG) Then
            Call kl_00_Spolocne.ZapisAsciiNovy(kl_00_Spolocne.LokalnyPriecinok() & "\" & kl_00_Spolocne.PRIECINOK_LOG & "\samotest.txt", ChrW$(&HEF) & ChrW$(&HBB) & ChrW$(&HBF) & kl_00_Spolocne.TextNaUtf8(mVypis))
        End If
    End If
    Exit Function
Chyba:
    mZle = mZle + 1
    Call Pis("ZLE   samotest skončil chybou " & Err.Number & ": " & Err.Description)
    Resume Koniec
End Function
