Attribute VB_Name = "kl_01_Identita"
'@Verzia 1.0.1
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: kl_01_Identita
' POPIS: Kto razí. Účet (login) a názov počítača sú zo Windows, osobné číslo z Active Directory (atribút employeeID, potom
'        employeeNumber, rovnako ako mod_03_ADSync na strane HR). Osobné číslo sa NIKDY nezadáva ručne.
'
'        Poradie (RozhodniIdentitu, čistá funkcia):
'          1. TEST: základ v zaklad.txt je lokálna cesta (nezačína \\) a test.ini obsahuje oc_test=<číslo>. Pri sieťovej ceste
'             sa test.ini ignoruje.
'          2. AD: osobné číslo prihláseného používateľa; pri úspechu sa uloží do identita.txt (login, oc, cas).
'          3. CACHE: AD je nedostupné (mimo domény, bez spojenia) a identita.txt je pre TEN ISTÝ login.
'          4. inak chyba a razenie je vypnuté.
'        Meno zamestnanca sa nečíta, nezobrazuje ani neloguje (len osobné číslo a účet).
' ZOZNAM VEREJNÝCH PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - ZistiIdentitu(oc, login, pc, zdroj, chyba) : Zistí identitu; False = razenie musí byť vypnuté (dôvod v chyba).
' - RozhodniIdentitu(login, lokalnyZaklad, testIni, ocAd, identitaTxt, oc, zdroj) : ČISTÁ: rozhodnutie podľa poradia vyššie; vráti "" alebo text chyby.
' - OcZTestIni(text), OcZIdentity(text, login), TextIdentity(login, oc, cas) : ČISTÉ: rozbor a zápis pomocných súborov.
' - PopisZdroja(zdroj)                         : ČISTÁ: text zdroja identity pre okno.
'===============================================================================

Public Const ZDROJ_AD As String = "AD"
Public Const ZDROJ_CACHE As String = "CACHE"
Public Const ZDROJ_TEST As String = "TEST"
Public Const CHYBA_OC As String = "Osobné číslo sa nepodarilo zistiť z AD. Napíšte HR."
Public Const CHYBA_UCET As String = "Účet Windows nemožno použiť v razení. Napíšte HR."
Public Const CHYBA_PC As String = "Názov počítača nemožno použiť v razení. Napíšte IT."

'===============================================================================
' Čisté funkcie
'===============================================================================
' Hodnota kľúča z textu s riadkami kluc=hodnota (prvý výskyt; kľúč bez ohľadu na veľkosť písmen). "" = chýba.
Private Function HodnotaKluca(ByVal strText As String, ByVal strKluc As String) As String
    Dim riadky() As String, i As Long, s As String, p As Long
    riadky = kl_00_Spolocne.RozdelRiadky(strText)
    For i = LBound(riadky) To UBound(riadky)
        s = Trim$(riadky(i))
        p = InStr(1, s, "=", vbBinaryCompare)
        If p > 1 Then
            If StrComp(Trim$(Left$(s, p - 1)), strKluc, vbTextCompare) = 0 Then
                HodnotaKluca = Trim$(Mid$(s, p + 1))
                Exit Function
            End If
        End If
    Next i
End Function

' Osobné číslo z test.ini (riadok oc_test=...). "" = súbor ho neobsahuje alebo hodnota nevyhovuje vzoru osobného čísla.
Public Function OcZTestIni(ByVal strText As String) As String
    Dim s As String
    s = HodnotaKluca(strText, "oc_test")
    If kl_02_Protokol.PlatneOc(s) Then OcZTestIni = s
End Function

' Osobné číslo z identita.txt, len ak je uložené pre ten istý účet (bez ohľadu na veľkosť písmen). Inak "".
Public Function OcZIdentity(ByVal strText As String, ByVal strLogin As String) As String
    Dim s As String
    If Len(strLogin) = 0 Then Exit Function
    If StrComp(HodnotaKluca(strText, "login"), strLogin, vbTextCompare) <> 0 Then Exit Function
    s = HodnotaKluca(strText, "oc")
    If kl_02_Protokol.PlatneOc(s) Then OcZIdentity = s
End Function

Public Function TextIdentity(ByVal strLogin As String, ByVal strOc As String, ByVal dtCas As Date) As String
    TextIdentity = "login=" & strLogin & vbCrLf & "oc=" & strOc & vbCrLf & "cas=" & kl_02_Protokol.CasNaText(dtCas) & vbCrLf
End Function

' Rozhodnutie o osobnom čísle. strOcAd je hodnota z AD ("" = AD nedostupné alebo atribút prázdny), strTestIni a strIdentitaTxt
' sú obsahy súborov ("" = súbor nie je). Vráti "" a naplní strOc a strZdroj, alebo vráti text chyby.
Public Function RozhodniIdentitu(ByVal strLogin As String, ByVal bLokalnyZaklad As Boolean, ByVal strTestIni As String, ByVal strOcAd As String, _
                                 ByVal strIdentitaTxt As String, ByRef strOc As String, ByRef strZdroj As String) As String
    strOc = ""
    strZdroj = ""
    If Not kl_02_Protokol.PlatnyLogin(strLogin) Then
        RozhodniIdentitu = CHYBA_UCET
        Exit Function
    End If
    If bLokalnyZaklad Then
        strOc = OcZTestIni(strTestIni)
        If Len(strOc) > 0 Then
            strZdroj = ZDROJ_TEST
            Exit Function
        End If
    End If
    strOcAd = Trim$(strOcAd)
    If kl_02_Protokol.PlatneOc(strOcAd) Then
        strOc = strOcAd
        strZdroj = ZDROJ_AD
        Exit Function
    End If
    strOc = OcZIdentity(strIdentitaTxt, strLogin)
    If Len(strOc) > 0 Then
        strZdroj = ZDROJ_CACHE
        Exit Function
    End If
    RozhodniIdentitu = CHYBA_OC
End Function

Public Function PopisZdroja(ByVal strZdroj As String) As String
    Select Case strZdroj
        Case ZDROJ_AD
            PopisZdroja = "Active Directory"
        Case ZDROJ_CACHE
            PopisZdroja = "vyrovnávacia pamäť (Active Directory je nedostupné)"
        Case ZDROJ_TEST
            PopisZdroja = "TESTOVACÍ REŽIM (test.ini)"
        Case Else
            PopisZdroja = "nezistené"
    End Select
End Function

'===============================================================================
' Active Directory
'===============================================================================
' Osobné číslo prihláseného používateľa z AD (employeeID, potom employeeNumber). "" = nezistené; strPopis je dôvod pre log.
Private Function OcZAd(ByRef strPopis As String) As String
    Dim objInfo As Object, objUser As Object, strDn As String, v As Variant, vAtr As Variant, s As String
    strPopis = ""
    On Error GoTo Chyba
    Set objInfo = CreateObject("ADSystemInfo")
    strDn = CStr(objInfo.UserName)
    Set objUser = GetObject("LDAP://" & Replace(strDn, "/", "\/"))
    For Each vAtr In Array("employeeID", "employeeNumber")
        s = ""
        On Error Resume Next
        v = objUser.Get(CStr(vAtr))
        If Err.Number = 0 Then
            If Not IsNull(v) And Not IsEmpty(v) And Not IsArray(v) Then s = Trim$(CStr(v))
        End If
        Err.Clear
        On Error GoTo Chyba
        If Len(s) > 0 Then
            If kl_02_Protokol.PlatneOc(s) Then
                OcZAd = s
            Else
                strPopis = "atribút " & CStr(vAtr) & " nemá tvar osobného čísla (1 až 20 písmen alebo číslic)"
            End If
            Exit Function
        End If
    Next vAtr
    strPopis = "atribúty employeeID a employeeNumber sú prázdne"
    Exit Function
Chyba:
    strPopis = "Active Directory je nedostupné (chyba " & Err.Number & ")"
    OcZAd = ""
End Function

'===============================================================================
' Hlavný vstup
'===============================================================================
Public Function ZistiIdentitu(ByRef strOc As String, ByRef strLogin As String, ByRef strPc As String, ByRef strZdroj As String, _
                              Optional ByRef strChyba As String) As Boolean
    Dim strLok As String, strTestIni As String, strIdentitaTxt As String, strOcAd As String, strPopisAd As String, bLokalny As Boolean, strT As String

    strOc = ""
    strZdroj = ""
    strChyba = ""
    strLogin = Trim$(Environ$("USERNAME"))
    strPc = Trim$(Environ$("COMPUTERNAME"))
    If Not kl_02_Protokol.PlatnyLogin(strLogin) Then
        strChyba = CHYBA_UCET
        Call kl_00_Spolocne.ZapisLog("ERROR", "Identita: účet Windows nevyhovuje vzoru protokolu.")
        Exit Function
    End If
    If Not kl_02_Protokol.PlatnyPocitac(strPc) Then
        strChyba = CHYBA_PC
        Call kl_00_Spolocne.ZapisLog("ERROR", "Identita: názov počítača nevyhovuje vzoru protokolu.")
        Exit Function
    End If

    strLok = kl_00_Spolocne.LokalnyPriecinok()
    bLokalny = kl_00_Spolocne.JeLokalnaCesta(kl_00_Spolocne.ZakladPriecinok())
    If bLokalny Then
        If kl_00_Spolocne.CitajTextUtf8(strLok & "\" & kl_00_Spolocne.SUBOR_TEST, strT) Then strTestIni = strT
    End If
    ' AD sa nepýta, ak rozhodol test (na skúšobnom počítači mimo domény by sa zbytočne čakalo)
    If Not (bLokalny And Len(OcZTestIni(strTestIni)) > 0) Then strOcAd = OcZAd(strPopisAd)
    If kl_00_Spolocne.CitajTextUtf8(strLok & "\" & kl_00_Spolocne.SUBOR_IDENTITA, strT) Then strIdentitaTxt = strT

    strChyba = RozhodniIdentitu(strLogin, bLokalny, strTestIni, strOcAd, strIdentitaTxt, strOc, strZdroj)
    If Len(strChyba) > 0 Then
        Call kl_00_Spolocne.ZapisLog("ERROR", "Identita: osobné číslo nezistené pre účet " & strLogin & IIf(Len(strPopisAd) > 0, " (" & strPopisAd & ")", "") & ".")
        Exit Function
    End If
    If strZdroj = ZDROJ_AD Then
        If kl_00_Spolocne.ZapisAsciiNovy(strLok & "\" & kl_00_Spolocne.SUBOR_IDENTITA, TextIdentity(strLogin, strOc, Now)) <> 0 Then
            Call kl_00_Spolocne.ZapisLog("WARN", "Identita: nepodarilo sa uložiť identita.txt.")
        End If
    End If
    Call kl_00_Spolocne.ZapisLog("INFO", "Identita: osobné číslo " & strOc & ", účet " & strLogin & ", zdroj " & strZdroj & _
                                 IIf(strZdroj = ZDROJ_CACHE And Len(strPopisAd) > 0, " (" & strPopisAd & ")", "") & ".")
    ZistiIdentitu = True
End Function
