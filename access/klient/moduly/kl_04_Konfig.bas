Attribute VB_Name = "kl_04_Konfig"
'@Verzia 1.0.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: kl_04_Konfig
' POPIS: Konfigurácia klienta: tlačidlá prerušení, ktoré HR zverejňuje v <zaklad>\konfiguracia\klient_konfig.txt
'        (mod_22_KlientRazenia.GenerujKonfiguraciuKlienta; UTF-8, s BOM aj bez, CRLF aj LF):
'          DOCHSKLIENT;1
'          vytvorene=RRRR-MM-DDTHH:MM:SS
'          odchod_bez_dovodu=OBED|ODCHOD
'          tlacidlo=poradie;KOD;text;ikona        (0 až n riadkov)
'          #END
'        Zdroj: server -> lokálna kópia (konfiguracia\klient_konfig.txt, pri nedostupnom serveri) -> predvolené (žiadne tlačidlá
'        prerušení; Príchod a Odchod fungujú vždy). Platná konfigurácia zo servera sa skopíruje do lokálnej kópie bajt po bajte.
'
'        Pravidlá rozboru (RozoberKonfig, čistá funkcia; zrkadlo tools/klient_protokol.py rozober_konfig, zhodu overuje
'        tools/test_klient_zhoda.py): prvý riadok presne DOCHSKLIENT;1 a posledný neprázdny presne #END, inak súbor nie je
'        konfigurácia. Riadok sa orezáva len o medzery, prázdny sa ignoruje, riadok bez "=" sa preskočí, neznámy kľúč sa ignoruje.
'        tlacidlo má presne 4 polia: poradie (1 až 4 číslice), KOD (DOCTOR TRIP FAMILY LEAVE SICK PRIV ERRAND), text 1 až 24
'        znakov, ikona (ignoruje sa). Chybný riadok sa preskočí a zaloguje, konfigurácia platí ďalej. Najviac 12 tlačidiel.
' ZOZNAM VEREJNÝCH PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - RozoberKonfig(text, kody, texty, odchod, vytvorene, preskocene) : ČISTÁ: vráti počet tlačidiel alebo -1 (nie je konfigurácia).
' - PredvolenyNazovKodu(kod)                  : ČISTÁ: slovenský názov kódu razenia, ak ho konfigurácia neuvádza.
' - NacitajKonfig()                           : Načíta konfiguráciu (server, kópia, predvolené); vráti zdroj.
' - PocetTlacidiel(), KodTlacidla(i), TextTlacidla(i) : Tlačidlá prerušení (i od 0).
' - NazovKodu(kod)                            : Text tlačidla pre kód, inak predvolený názov.
' - OdchodBezDovodu(), ZdrojKonfigu(), PopisZdrojaKonfigu() : Stav načítanej konfigurácie.
'===============================================================================

Public Const HLAVICKA_KONFIGU As String = "DOCHSKLIENT;1"
Public Const MAX_TLACIDIEL As Long = 12
Public Const MAX_TEXT_TLACIDLA As Long = 24
Public Const KONFIG_SERVER As String = "SERVER"
Public Const KONFIG_KOPIA As String = "KOPIA"
Public Const KONFIG_PREDVOLENE As String = "PREDVOLENE"
Private Const KODY_TLACIDIEL As String = "|DOCTOR|TRIP|FAMILY|LEAVE|SICK|PRIV|ERRAND|"
Private Const MAX_BAJTOV_KONFIGU As Long = 65536

Private mKody() As String
Private mTexty() As String
Private mPocet As Long
Private mOdchod As String
Private mVytvorene As String
Private mZdroj As String

'===============================================================================
' Čisté funkcie
'===============================================================================
Private Function JePoradie(ByVal s As String) As Boolean
    Dim i As Long, c As Long
    If Len(s) < 1 Or Len(s) > 4 Then Exit Function
    For i = 1 To Len(s)
        c = AscW(Mid$(s, i, 1))
        If c < 48 Or c > 57 Then Exit Function
    Next i
    JePoradie = True
End Function

Private Function MaRiadiaciZnak(ByVal s As String) As Boolean
    Dim i As Long, c As Long
    For i = 1 To Len(s)
        c = AscW(Mid$(s, i, 1))
        If c >= 0 And c < 32 Then
            MaRiadiaciZnak = True
            Exit Function
        End If
    Next i
End Function

' Vráti počet tlačidiel (0 až MAX_TLACIDIEL), alebo -1, ak text nie je konfigurácia. kody a texty sú (0 To počet - 1);
' strPreskocene sú čísla chybných riadkov oddelené čiarkou (od 1).
Public Function RozoberKonfig(ByVal strText As String, ByRef kody() As String, ByRef texty() As String, ByRef strOdchod As String, _
                              ByRef strVytvorene As String, ByRef strPreskocene As String) As Long
    Dim riadky() As String, n As Long, i As Long, r As String, p As Long, strKluc As String, strHodn As String
    Dim polia() As String, strKod As String, strPopis As String, nT As Long, bZle As Boolean

    Erase kody
    Erase texty
    strOdchod = "OBED"
    strVytvorene = ""
    strPreskocene = ""
    RozoberKonfig = -1
    If Len(strText) > 0 Then
        If AscW(Left$(strText, 1)) = &HFEFF Then strText = Mid$(strText, 2)
    End If
    riadky = kl_00_Spolocne.RozdelRiadky(strText)
    n = UBound(riadky) + 1
    Do While n > 0
        If Len(Trim$(riadky(n - 1))) > 0 Then Exit Do
        n = n - 1
    Loop
    If n < 2 Then Exit Function
    If StrComp(riadky(0), HLAVICKA_KONFIGU, vbBinaryCompare) <> 0 Then Exit Function
    If StrComp(riadky(n - 1), kl_02_Protokol.KONIEC_RZN, vbBinaryCompare) <> 0 Then Exit Function

    For i = 1 To n - 2
        r = Trim$(riadky(i))
        If Len(r) > 0 Then
            bZle = False
            p = InStr(1, r, "=", vbBinaryCompare)
            If p = 0 Then
                bZle = True
            Else
                strKluc = Trim$(Left$(r, p - 1))
                strHodn = Trim$(Mid$(r, p + 1))
                If StrComp(strKluc, "vytvorene", vbBinaryCompare) = 0 Then
                    strVytvorene = strHodn
                ElseIf StrComp(strKluc, "odchod_bez_dovodu", vbBinaryCompare) = 0 Then
                    If StrComp(strHodn, "OBED", vbBinaryCompare) = 0 Or StrComp(strHodn, "ODCHOD", vbBinaryCompare) = 0 Then
                        strOdchod = strHodn
                    Else
                        bZle = True
                    End If
                ElseIf StrComp(strKluc, "tlacidlo", vbBinaryCompare) = 0 Then
                    polia = Split(strHodn, ";")
                    If UBound(polia) <> 3 Then
                        bZle = True
                    Else
                        strKod = Trim$(polia(1))
                        strPopis = Trim$(polia(2))
                        If Not JePoradie(Trim$(polia(0))) Then
                            bZle = True
                        ElseIf Len(strKod) = 0 Or InStr(1, strKod, "|", vbBinaryCompare) > 0 Or InStr(1, KODY_TLACIDIEL, "|" & strKod & "|", vbBinaryCompare) = 0 Then
                            bZle = True
                        ElseIf Len(strPopis) < 1 Or Len(strPopis) > MAX_TEXT_TLACIDLA Then
                            bZle = True
                        ElseIf MaRiadiaciZnak(strPopis) Then
                            bZle = True
                        ElseIf nT < MAX_TLACIDIEL Then
                            ReDim Preserve kody(0 To nT)
                            ReDim Preserve texty(0 To nT)
                            kody(nT) = strKod
                            texty(nT) = strPopis
                            nT = nT + 1
                        End If
                    End If
                End If
            End If
            If bZle Then strPreskocene = strPreskocene & IIf(Len(strPreskocene) > 0, ",", "") & (i + 1)
        End If
    Next i
    RozoberKonfig = nT
End Function

Public Function PredvolenyNazovKodu(ByVal strKod As String) As String
    Select Case UCase$(strKod)
        Case "WORK"
            PredvolenyNazovKodu = "Práca"
        Case "DOCTOR"
            PredvolenyNazovKodu = "Lekár"
        Case "TRIP"
            PredvolenyNazovKodu = "Služobná cesta"
        Case "FAMILY"
            PredvolenyNazovKodu = "Sprevádzanie člena rodiny"
        Case "LEAVE"
            PredvolenyNazovKodu = "Dovolenka"
        Case "SICK"
            PredvolenyNazovKodu = "Práceneschopnosť"
        Case "PRIV"
            PredvolenyNazovKodu = "Súkromne"
        Case "ERRAND"
            PredvolenyNazovKodu = "Pracovná pochôdzka"
        Case Else
            PredvolenyNazovKodu = strKod
    End Select
End Function

'===============================================================================
' Načítanie
'===============================================================================
' Prečíta a rozoberie súbor konfigurácie; pri úspechu nastaví stav modulu a vráti True. strBajty = presný obsah súboru.
Private Function SkusSubor(ByVal strCesta As String, ByVal strZdroj As String, ByRef strBajty As String) As Boolean
    Dim kody() As String, texty() As String, strOdchod As String, strVytvorene As String, strPreskocene As String, n As Long
    strBajty = ""
    If Not kl_00_Spolocne.SuborExistuje(strCesta) Then Exit Function
    If Not kl_00_Spolocne.CitajBajty(strCesta, strBajty, MAX_BAJTOV_KONFIGU) Then
        Call kl_00_Spolocne.ZapisLog("WARN", "Konfigurácia (" & strZdroj & "): súbor sa nepodarilo prečítať.")
        Exit Function
    End If
    n = RozoberKonfig(kl_00_Spolocne.Utf8NaText(strBajty), kody, texty, strOdchod, strVytvorene, strPreskocene)
    If n < 0 Then
        Call kl_00_Spolocne.ZapisLog("WARN", "Konfigurácia (" & strZdroj & "): súbor nemá hlavičku " & HLAVICKA_KONFIGU & " alebo koniec #END, nepoužije sa.")
        Exit Function
    End If
    If Len(strPreskocene) > 0 Then Call kl_00_Spolocne.ZapisLog("WARN", "Konfigurácia (" & strZdroj & "): preskočené chybné riadky " & strPreskocene & ".")
    If n > 0 Then
        mKody = kody
        mTexty = texty
    Else
        Erase mKody
        Erase mTexty
    End If
    mPocet = n
    mOdchod = strOdchod
    mVytvorene = strVytvorene
    mZdroj = strZdroj
    SkusSubor = True
End Function

' Načíta konfiguráciu: server, potom lokálna kópia, potom predvolené. Vráti zdroj (KONFIG_*). Volá sa pri štarte a každých
' 10 minút; pri zmene zdroja zapíše riadok do logu.
Public Function NacitajKonfig() As String
    Dim strZaklad As String, strLok As String, strBajty As String, strPredtym As String
    On Error GoTo Chyba
    strPredtym = mZdroj
    strLok = kl_00_Spolocne.LokalnyPriecinok() & "\" & kl_00_Spolocne.PRIECINOK_KONFIG & "\" & kl_00_Spolocne.SUBOR_KONFIG
    strZaklad = kl_00_Spolocne.ZakladPriecinok()
    If Len(strZaklad) > 0 Then
        If SkusSubor(strZaklad & "\" & kl_00_Spolocne.PRIECINOK_KONFIG & "\" & kl_00_Spolocne.SUBOR_KONFIG, KONFIG_SERVER, strBajty) Then
            If kl_00_Spolocne.ZapisAsciiNovy(strLok, strBajty) <> 0 Then Call kl_00_Spolocne.ZapisLog("WARN", "Konfigurácia: nepodarilo sa uložiť lokálnu kópiu.")
            GoTo Hotovo
        End If
    End If
    If SkusSubor(strLok, KONFIG_KOPIA, strBajty) Then GoTo Hotovo
    Erase mKody
    Erase mTexty
    mPocet = 0
    mOdchod = "OBED"
    mVytvorene = ""
    mZdroj = KONFIG_PREDVOLENE
Hotovo:
    If mZdroj <> strPredtym Then Call kl_00_Spolocne.ZapisLog("INFO", "Konfigurácia: zdroj " & mZdroj & ", tlačidiel prerušení " & mPocet & IIf(Len(mVytvorene) > 0, ", vytvorená " & mVytvorene, "") & ".")
    NacitajKonfig = mZdroj
    Exit Function
Chyba:
    Call kl_00_Spolocne.ZapisLog("ERROR", "Načítanie konfigurácie skončilo chybou " & Err.Number & ": " & Err.Description)
    If Len(mZdroj) = 0 Then
        mPocet = 0
        mOdchod = "OBED"
        mZdroj = KONFIG_PREDVOLENE
    End If
    NacitajKonfig = mZdroj
End Function

Public Function PocetTlacidiel() As Long
    PocetTlacidiel = mPocet
End Function

Public Function KodTlacidla(ByVal i As Long) As String
    If i >= 0 And i < mPocet Then KodTlacidla = mKody(i)
End Function

Public Function TextTlacidla(ByVal i As Long) As String
    If i >= 0 And i < mPocet Then TextTlacidla = mTexty(i)
End Function

' Názov kódu razenia pre zoznam a stav dňa: text prvého tlačidla s týmto kódom, inak predvolený názov.
Public Function NazovKodu(ByVal strKod As String) As String
    Dim i As Long
    For i = 0 To mPocet - 1
        If StrComp(mKody(i), strKod, vbBinaryCompare) = 0 Then
            NazovKodu = mTexty(i)
            Exit Function
        End If
    Next i
    NazovKodu = PredvolenyNazovKodu(strKod)
End Function

Public Function OdchodBezDovodu() As String
    OdchodBezDovodu = IIf(mOdchod = "ODCHOD", "ODCHOD", "OBED")
End Function

Public Function ZdrojKonfigu() As String
    ZdrojKonfigu = IIf(Len(mZdroj) > 0, mZdroj, KONFIG_PREDVOLENE)
End Function

Public Function PopisZdrojaKonfigu() As String
    Select Case ZdrojKonfigu()
        Case KONFIG_SERVER
            PopisZdrojaKonfigu = "Konfigurácia zo servera" & IIf(Len(mVytvorene) > 0, " (" & Replace(mVytvorene, "T", " ") & ")", "")
        Case KONFIG_KOPIA
            PopisZdrojaKonfigu = "Konfigurácia z lokálnej kópie, server je nedostupný" & IIf(Len(mVytvorene) > 0, " (" & Replace(mVytvorene, "T", " ") & ")", "")
        Case Else
            PopisZdrojaKonfigu = "Konfigurácia nie je dostupná (len Príchod a Odchod)"
    End Select
End Function
