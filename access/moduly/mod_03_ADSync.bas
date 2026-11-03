Attribute VB_Name = "mod_03_ADSync"
'@Verzia 2.5.1
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_03_ADSync
' POPIS: Zamestnanci a hierarchia (vedúci / oddelenie) z doménového Active Directory (LDAP).
'        Dva režimy:
'          a) SYNCHRONIZÁCIA - doplní údaje existujúcim zamestnancom (podľa osobného čísla),
'          b) NAČÍTANIE Z DOMÉNY - navyše pridá aj nových zamestnancov nájdených v AD.
'        Zamestnanec sa v AD hľadá PRESNOU zhodou osobného čísla v atribúte (predvolene
'        employeeID, potom employeeNumber; ako posledná možnosť číselný sAMAccountName).
'        Celá doména sa prečíta jedným stránkovaným dotazom (bez dotazu na každého zamestnanca)
'        a nadriadený sa nachádza v pamäti podľa DN - rýchle aj pre tisíce účtov.
'        Roly sa NEPREPISUJÚ: ADMIN ostáva; VEDUCI sa priraďuje podľa väzieb nadriadený -> podriadený.
' NASTAVENIA (NastaveniaSystemu):
'        ADAtributOC       - atribút s osobným číslom (predvolené employeeID)
'        ADZakladnyKontajner - DN organizačnej jednotky, od ktorej sa číta (prázdne = celá doména)
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - AktualizujZamestnancovZAD()          : Synchronizácia existujúcich zamestnancov (kompatibilný vstup).
' - SynchronizujZAD(bPridatNovych, ...)  : Hlavná procedúra; vráti textový report.
' - PrepocitajHierarchiu()               : Doplní údaje vedúcich a prepočíta roly (aj pre CSV import).
' - AktualizujRoleVeducich()             : Priradí / odoberie rolu VEDUCI podľa hierarchie.
' - PocetPodriadenych(strOC)             : Pomocná funkcia pre zostavy a schvaľovanie.
'===============================================================================

' indexy hodnôt používateľa AD v poli
Private Const U_LOGIN As Long = 0
Private Const U_OC As Long = 1
Private Const U_MENO As Long = 2
Private Const U_PRIEZ As Long = 3
Private Const U_DISPLAY As Long = 4
Private Const U_MAIL As Long = 5
Private Const U_TEL As Long = 6
Private Const U_MOBIL As Long = 7
Private Const U_ODD As Long = 8
Private Const U_FIRMA As Long = 9
Private Const U_KANC As Long = 10
Private Const U_MGRDN As Long = 11
Private Const U_AKTIVNY As Long = 12
Private Const U_DN As Long = 13
Private Const U_POCET As Long = 14

Private Function AdHodnota(ByVal rst As Object, ByVal strPole As String) As String
    On Error Resume Next
    Dim v As Variant
    v = rst.Fields(strPole).Value
    If IsNull(v) Or IsEmpty(v) Then Exit Function
    If IsArray(v) Then AdHodnota = CStr(v(LBound(v))) Else AdHodnota = CStr(v)
End Function

'-------------------------------------------------------------------------------
' Osobné číslo používateľa z AD: nastavený atribút, potom employeeID, employeeNumber, nakoniec číselný login.
'-------------------------------------------------------------------------------
Private Function OsobneCisloZAD(ByVal rst As Object, ByVal strAtribut As String) As String
    Dim s As String, v As Variant
    For Each v In Array(strAtribut, "employeeID", "employeeNumber")
        If Len(CStr(v)) > 0 Then
            s = mod_11_ImportZamestnancov.NormalizujOC(AdHodnota(rst, CStr(v)))
            If mod_11_ImportZamestnancov.JePlatneOC(s) Then OsobneCisloZAD = s: Exit Function
        End If
    Next v
    s = mod_11_ImportZamestnancov.NormalizujOC(AdHodnota(rst, "sAMAccountName"))
    If mod_11_ImportZamestnancov.JePlatneOC(s) And IsNumeric(s) Then OsobneCisloZAD = s
End Function

'-------------------------------------------------------------------------------
' Načíta všetkých používateľov z AD (stránkovane). dicDN: DN(malé písmená) -> pole hodnôt; dicOC: osobné číslo -> DN.
' Vráti počet načítaných účtov alebo -1 pri nedostupnom LDAP.
'-------------------------------------------------------------------------------
Private Function NacitajPouzivatelovAD(ByRef dicDN As Object, ByRef dicOC As Object, ByRef strDuplicity As String) As Long
    On Error GoTo Chyba
    Dim conn As Object, cmd As Object, rst As Object, sBase As String, sKont As String, sAtr As String
    Dim a() As Variant, strDN As String, strOC As String, n As Long

    Set dicDN = CreateObject("Scripting.Dictionary")
    Set dicOC = CreateObject("Scripting.Dictionary")
    dicDN.CompareMode = 1
    dicOC.CompareMode = 1

    sKont = Trim$(mod_00_Common.GetNastavenie("ADZakladnyKontajner", ""))
    sAtr = Trim$(mod_00_Common.GetNastavenie("ADAtributOC", "employeeID"))
    If Len(sKont) > 0 Then
        sBase = sKont
    Else
        sBase = GetObject("LDAP://RootDSE").Get("defaultNamingContext")
    End If

    Set conn = CreateObject("ADODB.Connection")
    conn.Provider = "ADsDSOObject"
    conn.Open "Active Directory Provider"
    Set cmd = CreateObject("ADODB.Command")
    Set cmd.ActiveConnection = conn
    cmd.Properties("Page size") = 1000
    cmd.Properties("Timeout") = 120
    cmd.CommandText = "<LDAP://" & sBase & ">;(&(objectCategory=person)(objectClass=user));" & _
                      "sAMAccountName,employeeID,employeeNumber,givenName,sn,displayName,mail,telephoneNumber,mobile," & _
                      "department,company,physicalDeliveryOfficeName,manager,userAccountControl,distinguishedName;subtree"
    Set rst = cmd.Execute

    Do While Not rst.EOF
        ReDim a(0 To U_POCET - 1)
        strDN = AdHodnota(rst, "distinguishedName")
        a(U_DN) = strDN
        a(U_LOGIN) = AdHodnota(rst, "sAMAccountName")
        a(U_MENO) = AdHodnota(rst, "givenName")
        a(U_PRIEZ) = AdHodnota(rst, "sn")
        a(U_DISPLAY) = AdHodnota(rst, "displayName")
        a(U_MAIL) = AdHodnota(rst, "mail")
        a(U_TEL) = AdHodnota(rst, "telephoneNumber")
        a(U_MOBIL) = AdHodnota(rst, "mobile")
        a(U_ODD) = Left$(AdHodnota(rst, "department"), 150)
        a(U_FIRMA) = AdHodnota(rst, "company")
        a(U_KANC) = AdHodnota(rst, "physicalDeliveryOfficeName")
        a(U_MGRDN) = AdHodnota(rst, "manager")
        a(U_AKTIVNY) = ((CLng(Val(AdHodnota(rst, "userAccountControl"))) And 2) = 0)
        strOC = OsobneCisloZAD(rst, sAtr)
        a(U_OC) = strOC
        If Len(strDN) > 0 Then
            dicDN(strDN) = a
            If Len(strOC) > 0 Then
                If dicOC.Exists(strOC) Then
                    strDuplicity = strDuplicity & strOC & " (" & a(U_LOGIN) & "), "
                Else
                    dicOC(strOC) = strDN
                End If
            End If
            n = n + 1
        End If
        rst.MoveNext
        If n Mod 200 = 0 Then DoEvents
    Loop
    rst.Close: conn.Close
    NacitajPouzivatelovAD = n
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_03_ADSync.NacitajPouzivatelovAD", "ERROR", Err.Description)
    NacitajPouzivatelovAD = -1
End Function

'-------------------------------------------------------------------------------
' Zapíše údaje z AD do záznamu zamestnanca. Prázdne hodnoty z AD existujúce údaje neprepisujú.
'-------------------------------------------------------------------------------
Private Sub ZapisUdajeAD(ByRef rs As DAO.Recordset, ByRef u As Variant, ByRef dicDN As Object)
    Dim sMgr As Variant, sCele As String, bPrepis As Boolean

    If Len(u(U_LOGIN)) > 0 Then rs!LoginAD = u(U_LOGIN)
    If Len(u(U_MAIL)) > 0 Then rs!Email = u(U_MAIL)
    If Len(u(U_TEL)) > 0 Then rs!Telefon = u(U_TEL)
    If Len(u(U_MOBIL)) > 0 Then rs!Mobil = u(U_MOBIL)
    If Len(u(U_FIRMA)) > 0 Then rs!Organizacia = Left$(u(U_FIRMA), 255)
    If Len(u(U_KANC)) > 0 Then rs!Pracovisko = Left$(u(U_KANC), 255)
    If Len(u(U_ODD)) > 0 Then rs!Oddelenie = u(U_ODD)

    ' meno: doplň ak chýba; ak existuje, prepíš len pri vysokej podobnosti (oprava preklepov / diakritiky)
    sCele = Trim$(Nz(rs!Meno, "") & " " & Nz(rs!Priezvisko, ""))
    bPrepis = (Len(sCele) = 0)
    If Not bPrepis And Len(u(U_DISPLAY)) > 0 Then bPrepis = (mod_00_Common.SimilarityPercent(sCele, CStr(u(U_DISPLAY))) >= 75)
    If bPrepis And (Len(u(U_MENO)) > 0 Or Len(u(U_PRIEZ)) > 0) Then
        rs!Meno = u(U_MENO)
        rs!Priezvisko = u(U_PRIEZ)
        If Len(u(U_DISPLAY)) > 0 Then rs!CeleMeno = Left$(u(U_DISPLAY), 255)
    End If

    ' nadriadený
    If Len(u(U_MGRDN)) > 0 Then
        rs!ManagerDN = Left$(u(U_MGRDN), 255)
        If dicDN.Exists(u(U_MGRDN)) Then
            sMgr = dicDN(u(U_MGRDN))
            rs!ManagerOC = IIf(Len(sMgr(U_OC)) > 0, sMgr(U_OC), Null)
            rs!ManagerLogin = sMgr(U_LOGIN)
            rs!ManagerMeno = Left$(IIf(Len(sMgr(U_DISPLAY)) > 0, sMgr(U_DISPLAY), Trim$(sMgr(U_MENO) & " " & sMgr(U_PRIEZ))), 255)
            rs!ManagerEmail = sMgr(U_MAIL)
        End If
    End If

    rs!ADAktivny = CBool(u(U_AKTIVNY))
    rs!DatumImportu = Now()
End Sub

'-------------------------------------------------------------------------------
' Kompatibilný vstup: synchronizácia existujúcich zamestnancov s AD.
'-------------------------------------------------------------------------------
Public Sub AktualizujZamestnancovZAD()
    Call SynchronizujZAD(False, True)
End Sub

'-------------------------------------------------------------------------------
' Hlavná procedúra. bPridatNovych = True pridá aj zamestnancov, ktorí v tabuľke ešte nie sú (aktívne účty s osobným číslom).
' Vráti textový report; pri bTicho = False ho aj zobrazí.
'-------------------------------------------------------------------------------
Public Function SynchronizujZAD(Optional ByVal bPridatNovych As Boolean = False, Optional ByVal bTicho As Boolean = False) As String
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset, dicDN As Object, dicOC As Object
    Dim nAD As Long, nNajdenych As Long, nNenajdenych As Long, nNovych As Long, strDup As String, strOC As String, strRep As String
    Dim u As Variant, dicVTabulke As Object

    Set db = CurrentDb
    Call mod_11_ImportZamestnancov.ZabezpecTabulkuZamestnancov(db)

    nAD = NacitajPouzivatelovAD(dicDN, dicOC, strDup)
    If nAD < 0 Then
        strRep = "Active Directory (LDAP) nie je dostupné - skontrolujte pripojenie do domény."
        If Not bTicho Then MsgBox strRep, vbExclamation, "Active Directory"
        SynchronizujZAD = strRep
        Exit Function
    End If

    Set dicVTabulke = CreateObject("Scripting.Dictionary")
    Set rs = db.OpenRecordset("SELECT * FROM Zamestnanci;", dbOpenDynaset)
    Do While Not rs.EOF
        strOC = Trim$(Nz(rs!OsobneCislo, ""))
        If Len(strOC) > 0 Then
            dicVTabulke(strOC) = True
            If dicOC.Exists(strOC) Then
                u = dicDN(dicOC(strOC))
                rs.Edit
                Call ZapisUdajeAD(rs, u, dicDN)
                rs.Update
                nNajdenych = nNajdenych + 1
            ElseIf nAD > 0 Then
                rs.Edit
                rs!ADAktivny = False
                rs.Update
                nNenajdenych = nNenajdenych + 1
            End If
        End If
        rs.MoveNext
        If (nNajdenych + nNenajdenych) Mod 100 = 0 Then DoEvents
    Loop

    If bPridatNovych Then
        Dim k As Variant
        For Each k In dicOC.Keys
            strOC = CStr(k)
            If Not dicVTabulke.Exists(strOC) Then
                u = dicDN(dicOC(strOC))
                If CBool(u(U_AKTIVNY)) Then
                    rs.AddNew
                    rs!OsobneCislo = strOC
                    rs!Rola = "USER"
                    Call ZapisUdajeAD(rs, u, dicDN)
                    rs!ZdrojZaznamu = "AD"
                    rs.Update
                    nNovych = nNovych + 1
                End If
            End If
        Next k
    End If
    rs.Close

    Call PrepocitajHierarchiu
    If nNajdenych + nNovych > 0 Then Call mod_00_Common.SetPoslednyKrok(3)

    strRep = "Účtov v AD: " & nAD & vbCrLf & "Aktualizovaných zamestnancov: " & nNajdenych & vbCrLf & _
             "Nenájdených v AD (označení neaktívni): " & nNenajdenych
    If bPridatNovych Then strRep = strRep & vbCrLf & "Pridaných nových zamestnancov: " & nNovych
    If Len(strDup) > 0 Then strRep = strRep & vbCrLf & "Upozornenie - osobné číslo je v AD viackrát: " & Left$(strDup, Len(strDup) - 2)
    If dicOC.Count = 0 Then strRep = strRep & vbCrLf & "Upozornenie: v AD sa nenašlo žiadne osobné číslo v atribúte '" & _
                                      mod_00_Common.GetNastavenie("ADAtributOC", "employeeID") & "'."
    Call mod_00_Common.ZapisLog("SynchronizujZAD", "INFO", Replace(strRep, vbCrLf, "; "))
    If Not bTicho Then MsgBox strRep, vbInformation, "Active Directory"
    SynchronizujZAD = strRep
    Exit Function
Chyba:
    strRep = "Chyba synchronizácie AD: " & Err.Description
    Call mod_00_Common.ZapisLog("mod_03_ADSync.SynchronizujZAD", "ERROR", Err.Description)
    On Error Resume Next
    rs.Close
    If Not bTicho Then MsgBox strRep, vbCritical, "Active Directory"
    SynchronizujZAD = strRep
End Function

'-------------------------------------------------------------------------------
' Doplní údaje vedúceho (login, meno, e-mail) podľa jeho osobného čísla / loginu v tabuľke zamestnancov
' a následne prepočíta roly. Použiteľné po importe z CSV aj z AD.
'-------------------------------------------------------------------------------
Public Sub PrepocitajHierarchiu()
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset, dicOC As Object, dicLogin As Object, m As Variant, strMOC As String, strMLogin As String
    Set db = CurrentDb
    Set dicOC = CreateObject("Scripting.Dictionary")
    Set dicLogin = CreateObject("Scripting.Dictionary")
    dicLogin.CompareMode = 1

    Set rs = db.OpenRecordset("SELECT OsobneCislo, LoginAD, Meno, Priezvisko, CeleMeno, Email FROM Zamestnanci;", dbOpenSnapshot)
    Do While Not rs.EOF
        m = Array(CStr(Nz(rs!OsobneCislo, "")), CStr(Nz(rs!LoginAD, "")), _
                  IIf(Len(Nz(rs!CeleMeno, "")) > 0, CStr(Nz(rs!CeleMeno, "")), Trim$(Nz(rs!Meno, "") & " " & Nz(rs!Priezvisko, ""))), CStr(Nz(rs!Email, "")))
        If Len(m(0)) > 0 Then dicOC(m(0)) = m
        If Len(m(1)) > 0 Then dicLogin(m(1)) = m
        rs.MoveNext
    Loop
    rs.Close

    Set rs = db.OpenRecordset("SELECT OsobneCislo, ManagerOC, ManagerLogin, ManagerMeno, ManagerEmail FROM Zamestnanci;", dbOpenDynaset)
    Do While Not rs.EOF
        strMOC = Trim$(Nz(rs!ManagerOC, ""))
        strMLogin = Trim$(Nz(rs!ManagerLogin, ""))
        m = Empty
        If Len(strMOC) > 0 Then
            If dicOC.Exists(strMOC) Then m = dicOC(strMOC)
        ElseIf Len(strMLogin) > 0 Then
            If dicLogin.Exists(strMLogin) Then m = dicLogin(strMLogin)
        End If
        If IsArray(m) Then
            rs.Edit
            If Len(strMOC) = 0 And Len(m(0)) > 0 Then rs!ManagerOC = m(0)
            If Len(strMLogin) = 0 And Len(m(1)) > 0 Then rs!ManagerLogin = m(1)
            If Len(Nz(rs!ManagerMeno, "")) = 0 And Len(m(2)) > 0 Then rs!ManagerMeno = Left$(m(2), 255)
            If Len(Nz(rs!ManagerEmail, "")) = 0 And Len(m(3)) > 0 Then rs!ManagerEmail = m(3)
            rs.Update
        End If
        rs.MoveNext
    Loop
    rs.Close
    Call AktualizujRoleVeducich
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_03_ADSync.PrepocitajHierarchiu", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Priradí rolu VEDUCI každému, kto je niekomu nadriadený (podľa ManagerOC alebo ManagerLogin), a odoberie ju tým,
' ktorí už nikoho nevedú. Rola ADMIN (a iné ručne nastavené roly) sa nemení.
'-------------------------------------------------------------------------------
Public Sub AktualizujRoleVeducich()
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset, dicOC As Object, dicLogin As Object, strRola As String
    Set db = CurrentDb
    Set dicOC = CreateObject("Scripting.Dictionary")
    Set dicLogin = CreateObject("Scripting.Dictionary")
    dicLogin.CompareMode = 1

    Set rs = db.OpenRecordset("SELECT ManagerOC, ManagerLogin FROM Zamestnanci;", dbOpenSnapshot)
    Do While Not rs.EOF
        If Len(Trim$(Nz(rs!ManagerOC, ""))) > 0 Then dicOC(Trim$(CStr(rs!ManagerOC))) = True
        If Len(Trim$(Nz(rs!ManagerLogin, ""))) > 0 Then dicLogin(Trim$(CStr(rs!ManagerLogin))) = True
        rs.MoveNext
    Loop
    rs.Close

    Set rs = db.OpenRecordset("SELECT OsobneCislo, LoginAD, Rola FROM Zamestnanci;", dbOpenDynaset)
    Do While Not rs.EOF
        strRola = UCase$(Trim$(Nz(rs!Rola, "")))
        If strRola = "" Or strRola = "USER" Or strRola = "VEDUCI" Then
            Dim bVeduci As Boolean
            bVeduci = dicOC.Exists(Trim$(Nz(rs!OsobneCislo, ""))) Or (Len(Nz(rs!LoginAD, "")) > 0 And dicLogin.Exists(Trim$(CStr(Nz(rs!LoginAD, "")))))
            If (bVeduci And strRola <> "VEDUCI") Or (Not bVeduci And strRola <> "USER") Then
                rs.Edit
                rs!Rola = IIf(bVeduci, "VEDUCI", "USER")
                rs.Update
            End If
        End If
        rs.MoveNext
    Loop
    rs.Close
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_03_ADSync.AktualizujRoleVeducich", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Počet priamych podriadených zamestnanca (podľa osobného čísla vedúceho).
'-------------------------------------------------------------------------------
Public Function PocetPodriadenych(ByVal strOC As String) As Long
    On Error Resume Next
    PocetPodriadenych = CLng(DCount("*", "Zamestnanci", "ManagerOC = " & mod_00_Common.SqlText(strOC)))
End Function
