Attribute VB_Name = "mod_UI_Tab_ADSync"
'@Verzia 2.8.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_UI_Tab_ADSync
' POPIS: Sub-modul pre kartu 9 UI - zamestnanci a hierarchia (vedúci, oddelenie) z Active Directory.
'        Karta je voliteľná: zobrazí sa len v doméne (LDAP). Nastavenie ADKartaZobraz: auto (predvolené), 1 = vždy, 0 = nikdy.
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - IsAvailable()                  : Karta je dostupná len v doméne (LDAP), ak nastavenie ADKartaZobraz nehovorí inak.
' - GetTabCaption()                : "9. Active Directory".
' - BuildUI(strFrmName, strPage)   : Ovládacie prvky záložky.
' - InitDefaults(frm)              : Načíta uložené nastavenia a stav.
' - SpustiADSyncUI()               : Doplní údaje existujúcim zamestnancom.
' - SpustiADNacitajUI()            : Načíta zamestnancov z domény vrátane nových.
' - SpustiSyncVeducichUI()         : Prepočíta hierarchiu a roly.
'===============================================================================

Public Function IsAvailable() As Boolean
    On Error Resume Next
    Dim objRoot As Object, strVolba As String
    strVolba = LCase$(Trim$(mod_00_Common.GetNastavenie("ADKartaZobraz", "auto")))
    Err.Clear
    If strVolba = "1" Then IsAvailable = True: Exit Function
    If strVolba = "0" Then Exit Function
    Set objRoot = GetObject("LDAP://RootDSE")
    IsAvailable = (Err.Number = 0 And Not objRoot Is Nothing)
    Err.Clear
End Function

Public Function GetTabCaption() As String
    GetTabCaption = "9. Active Directory"
End Function

Public Sub BuildUI(ByVal strFrmName As String, ByVal strPageName As String)
    On Error GoTo ChybaHandler
    Dim ctl As Control, btn As Control

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 1100, 9500, 300)
    ctl.Caption = "Zamestnanci a hierarchia z doménového Active Directory (LDAP)"
    ctl.FontBold = True: ctl.FontSize = 10: ctl.ForeColor = RGB(15, 30, 90)

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 1450, 9500, 800)
    ctl.Caption = "Systém prečíta účty z domény, nájde zamestnancov podľa osobného čísla (presná zhoda v zvolenom atribúte), " & _
                  "doplní login, e-mail, oddelenie a nadriadeného. Z väzieb 'nadriadený - podriadený' určí vedúcich. " & _
                  "Ručne nastavené roly (napr. ADMIN) sa nemenia."
    ctl.ForeColor = RGB(80, 80, 80)

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 2400, 2400, 300)
    ctl.Caption = "Atribút s osobným číslom:"
    Set ctl = CreateControl(strFrmName, acTextBox, acDetail, strPageName, "", 2900, 2350, 2200, 330)
    ctl.Name = "txtADAtribut"

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 5300, 2400, 1500, 300)
    ctl.Caption = "Kontajner (OU):"
    Set ctl = CreateControl(strFrmName, acTextBox, acDetail, strPageName, "", 6800, 2350, 3200, 330)
    ctl.Name = "txtADKontajner"

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 2750, 9500, 300)
    ctl.Caption = "Kontajner je nepovinný, napr. OU=Zamestnanci,DC=firma,DC=local (prázdne = celá doména)."
    ctl.FontSize = 8: ctl.ForeColor = RGB(100, 100, 100)

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 3150, 9500, 550)
    btn.Name = "btnSpustitADSync"
    btn.Caption = "SYNCHRONIZOVAŤ EXISTUJÚCICH ZAMESTNANCOV S AD"
    btn.FontBold = True: btn.FontSize = 10: btn.ForeColor = RGB(15, 30, 90)
    btn.OnClick = "=SpustiADSyncUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 3850, 9500, 550)
    btn.Name = "btnADNacitaj"
    btn.Caption = "NAČÍTAŤ ZAMESTNANCOV Z DOMÉNY (pridá aj nových s osobným číslom)"
    btn.FontBold = True: btn.FontSize = 10: btn.ForeColor = RGB(0, 100, 0)
    btn.OnClick = "=SpustiADNacitajUI()"

    Set btn = CreateControl(strFrmName, acCommandButton, acDetail, strPageName, "", 500, 4550, 4600, 420)
    btn.Name = "btnAktualizujVeducich"
    btn.Caption = "Prepočítať hierarchiu a roly vedúcich"
    btn.OnClick = "=SpustiSyncVeducichUI()"

    Set ctl = CreateControl(strFrmName, acLabel, acDetail, strPageName, "", 500, 5150, 9500, 600)
    ctl.Name = "lblADStav"
    ctl.Caption = ""
    ctl.ForeColor = RGB(15, 30, 90)

    Exit Sub
ChybaHandler:
    Call mod_00_Common.ZapisLog("mod_UI_Tab_ADSync.BuildUI", "ERROR", Err.Description)
End Sub

Public Sub InitDefaults(ByRef frm As Form)
    On Error Resume Next
    frm!txtADAtribut = mod_00_Common.GetNastavenie("ADAtributOC", "employeeID")
    frm!txtADKontajner = mod_00_Common.GetNastavenie("ADZakladnyKontajner", "")
    Call ObnovStavADUI
End Sub

Private Sub UlozNastavenia()
    On Error Resume Next
    Dim frm As Form
    Set frm = Forms!frmHlavnaKonzola
    Call mod_00_Common.SetNastavenie("ADAtributOC", Trim$(Nz(frm!txtADAtribut, "employeeID")), "Atribút AD s osobným číslom zamestnanca")
    Call mod_00_Common.SetNastavenie("ADZakladnyKontajner", Trim$(Nz(frm!txtADKontajner, "")), "DN kontajnera (OU) pre čítanie používateľov z AD; prázdne = celá doména")
End Sub

Private Sub ObnovStavADUI()
    On Error Resume Next
    Dim frm As Form
    Set frm = Forms!frmHlavnaKonzola
    frm!lblADStav.Caption = "Zamestnancov: " & DCount("*", "Zamestnanci") & ", s nadriadeným: " & DCount("*", "Zamestnanci", "ManagerOC Is Not Null OR ManagerLogin Is Not Null") & _
                            ", vedúcich: " & DCount("*", "Zamestnanci", "Rola = 'VEDUCI'")
End Sub

Public Function SpustiADSyncUI() As Boolean
    On Error GoTo ChybaHandler
    If mod_00_Common.JeImportZamknuty() Then
        MsgBox "Import je uzamknutý.", vbExclamation, "Upozornenie"
        Exit Function
    End If
    Call UlozNastavenia
    Call mod_03_ADSync.SynchronizujZAD(False, False)
    Call ObnovStavADUI
    Call mod_UI_Pomocnik.OznacCinnost("AD")
    SpustiADSyncUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri synchronizácii s AD: " & Err.Description, vbCritical
End Function

Public Function SpustiADNacitajUI() As Boolean
    On Error GoTo ChybaHandler
    If mod_00_Common.JeImportZamknuty() Then
        MsgBox "Import je uzamknutý.", vbExclamation, "Upozornenie"
        Exit Function
    End If
    If MsgBox("Načítať zamestnancov z domény? Do tabuľky sa pridajú všetky aktívne účty, ktoré majú osobné číslo v zvolenom atribúte.", _
              vbYesNo + vbQuestion, "Active Directory") <> vbYes Then Exit Function
    Call UlozNastavenia
    Call mod_03_ADSync.SynchronizujZAD(True, False)
    Call ObnovStavADUI
    Call mod_UI_Pomocnik.OznacCinnost("AD")
    SpustiADNacitajUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri načítaní z AD: " & Err.Description, vbCritical
End Function

Public Function SpustiSyncVeducichUI() As Boolean
    On Error GoTo ChybaHandler
    Call mod_03_ADSync.PrepocitajHierarchiu
    Call ObnovStavADUI
    MsgBox "Hierarchia a role vedúcich boli prepočítané.", vbInformation, "Hotovo"
    Call mod_UI_Pomocnik.OznacCinnost("AD")
    SpustiSyncVeducichUI = True
    Exit Function
ChybaHandler:
    MsgBox "Chyba pri aktualizácii rolí: " & Err.Description, vbCritical
End Function
