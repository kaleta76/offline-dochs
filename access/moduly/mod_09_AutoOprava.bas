Attribute VB_Name = "mod_09_AutoOprava"
'@Verzia 1.3.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_09_AutoOprava
' POPIS: Inteligentná automatická oprava chýbajúcich / chybných pípnutí tak, aby
'        sekretárka nemusela pred tlačou výkazov opravovať hodiny ručne.
'
' PRINCÍP (pôvodné razenia sa NIKDY nemenia):
'   - Analýza prejde dni mesiaca stavovým automatom (mod_08_UdalostiDna), nájde
'     anomálie a pre opraviteľné vygeneruje "virtuálne razenie" do tabuľky
'     DochadzkaAutoOpravy. Výpočet (engine) tieto razenia berie do úvahy len ak majú
'     stav UPLATNENE. Opravu možno kedykoľvek zamietnuť -> výkaz sa vráti do pôvodného stavu.
'   - Dni, ktoré už sekretárka upravila ručne (editor), sa preskakujú.
'   - Analýza je opakovateľná: ak sa doplní skutočné razenie (napr. z terminálu),
'     nepotrebná oprava sa automaticky označí ako ZASTARANÁ.
'
' TRIEDY OPRÁV:
'   A - isté opravy (napr. chýbajúci návrat z obeda = štandardný obed 30 min).
'   B - odhad podľa fondu (chýbajúci odchod; prerušenie bez návratu do konca fondu).
'   Ostatné anomálie (odchod bez príchodu, koniec bez začiatku...) ostanú na posúdenie.
' REŽIM (NastaveniaSystemu "AutoOpravaRezim"):
'   0 = nič negenerovať, 1 = A automaticky, B ako návrh na schválenie (predvolené),
'   2 = A aj B automaticky (v zozname ostanú na kontrolu).
'   CIEĽ (NastaveniaSystemu "AutoOpravaCiel", kontrakt auto_repair_target): 0 = doplniť tak, aby sa deň vyrovnal na denný
'   fond (predvolené, ako doteraz), 1 = doplniť na koniec okna práce.
'   PRÍPADY (NastaveniaSystemu "AutoOpravaPripady", kontrakt auto_repair_cases, súčet bitov): 1 = zabudnutý odchod z práce,
'   2 = zabudnutý návrat z prerušenia (nie z obeda); predvolene 3 (oba). Opravy obeda (trieda A) tým nie sú dotknuté.
' STAVY: NAVRH, UPLATNENE, ZAMIETNUTE, ZASTARANE.
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - RezimAutoOpravy()/NastavRezim()        : Čítanie / zápis režimu.
' - ZabezpecTabulky(db)                    : Vytvorí DochadzkaAutoOpravy a doplní stĺpce anomálií.
' - AnalyzujMesiacZamestnanca(...)         : Analýza a zosúladenie opráv zamestnanca za mesiac.
' - AnalyzujObdobie(rok, mesiac, oc)       : Analýza viacerých zamestnancov; vráti počet nevyriešených anomálií.
' - PripravAOveriMesiac(...)               : Analýza + dotaz na schválenie pred tlačou výkazu.
' - SchvalNavrhy / ZamietniNavrh / VratNavrh : Rozhodnutia používateľa.
' - PocetNavrhov(...)                      : Počet opráv v stave.
' - AO_*                                   : Obslužné funkcie pre záložku (mod_UI_Tab_AutoOprava).
'===============================================================================

Private Const TBL As String = "DochadzkaAutoOpravy"

Public Type TNavrh
    Trieda As String
    Kod As String
    Cas As Long
    Smer As String
    Cislo As Long
    Zdroj As Long
    Popis As String
End Type

Private mSumar As String
Private mAutoKoniec As Object

'-------------------------------------------------------------------------------
' Režim automatických opráv (0/1/2).
'-------------------------------------------------------------------------------
Public Function RezimAutoOpravy() As Long
    Dim l As Long
    l = CLng(Val(mod_00_Common.GetNastavenie("AutoOpravaRezim", "1")))
    If l < 0 Or l > 2 Then l = 1
    RezimAutoOpravy = l
End Function

'-------------------------------------------------------------------------------
' Cieľ doplnenia zabudnutého razenia: 0 = denný fond, 1 = koniec okna práce.
'-------------------------------------------------------------------------------
Public Function CielAutoOpravy() As Long
    Dim l As Long
    l = CLng(Val(mod_00_Common.GetNastavenie("AutoOpravaCiel", "0")))
    If l < 0 Or l > 1 Then l = 0
    CielAutoOpravy = l
End Function

'-------------------------------------------------------------------------------
' Prípady opráv (súčet bitov): 1 odchod z práce, 2 návrat z prerušenia. Mimo 1 až 3 platí 3.
'-------------------------------------------------------------------------------
Public Function PripadyAutoOpravy() As Long
    Dim l As Long
    l = CLng(Val(mod_00_Common.GetNastavenie("AutoOpravaPripady", "3")))
    If l < 1 Or l > 3 Then l = 3
    PripadyAutoOpravy = l
End Function

Public Sub NastavRezim(ByVal lRezim As Long)
    If lRezim < 0 Or lRezim > 2 Then lRezim = 1
    Call mod_00_Common.SetNastavenie("AutoOpravaRezim", CStr(lRezim), "Režim automatických opráv: 0=vypnuté, 1=isté automaticky + odhady na schválenie, 2=všetko automaticky")
End Sub

'-------------------------------------------------------------------------------
' Vytvorí tabuľku DochadzkaAutoOpravy a doplní stĺpce pre anomálie (ak chýbajú).
'-------------------------------------------------------------------------------
Public Sub ZabezpecTabulky(ByRef db As DAO.Database)
    On Error GoTo Chyba
    If Not mod_00_Common.TabulkaExistujeDB(db, TBL) Then
        db.Execute "CREATE TABLE " & TBL & " (ID AUTOINCREMENT PRIMARY KEY, OsobneCislo TEXT(20), Datum DATETIME, Cas LONG, Smer TEXT(1), " & _
                   "CisloPreruseni LONG, Zdroj LONG, Typ TEXT(40), Trieda TEXT(1), Popis TEXT(255), Stav TEXT(15), " & _
                   "DatumVzniku DATETIME, DatumRozhodnutia DATETIME, Uzivatel TEXT(50))", dbFailOnError
        db.Execute "CREATE INDEX idxAutoOpr_OC_Datum ON " & TBL & " (OsobneCislo, Datum)", dbFailOnError
        db.TableDefs.Refresh
    End If
    If Not mod_00_Common.TabulkaExistujeDB(db, "DochadzkaAnomalie") Then Call mod_04_DataConsolidation.VytvorTabulkuAnomalii(db)
    If mod_00_Common.TabulkaExistujeDB(db, "DochadzkaAnomalie") Then
        If Not mod_00_Common.PoleExistujeDB(db, "DochadzkaAnomalie", "Zavaznost") Then db.Execute "ALTER TABLE DochadzkaAnomalie ADD COLUMN Zavaznost TEXT(10)", dbFailOnError
        If Not mod_00_Common.PoleExistujeDB(db, "DochadzkaAnomalie", "Cas") Then db.Execute "ALTER TABLE DochadzkaAnomalie ADD COLUMN Cas LONG", dbFailOnError
    End If
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_09_AutoOprava.ZabezpecTabulky", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Určuje, či sa prerušenie s daným číslom má na konci dňa automaticky ukončiť (do naplnenia fondu).
' Zdroj: CiselnikPreruseni.AutoKoniecDoKoncaSmeny; ak stĺpec chýba, platí predvolená sada.
'-------------------------------------------------------------------------------
Private Function JeAutoKoniec(ByVal lCislo As Long) As Boolean
    Dim rs As DAO.Recordset, db As DAO.Database
    If mAutoKoniec Is Nothing Then
        Set mAutoKoniec = CreateObject("Scripting.Dictionary")
        On Error Resume Next
        Set db = CurrentDb
        If mod_00_Common.PoleExistujeDB(db, "CiselnikPreruseni", "AutoKoniecDoKoncaSmeny") Then
            Set rs = db.OpenRecordset("SELECT Cislo, AutoKoniecDoKoncaSmeny FROM CiselnikPreruseni;", dbOpenSnapshot)
            Do While Not rs.EOF
                mAutoKoniec(CLng(rs!Cislo)) = CBool(Nz(rs!AutoKoniecDoKoncaSmeny, False))
                rs.MoveNext
            Loop
            rs.Close
        Else
            Dim v As Variant
            For Each v In Array(4, 8, 11, 12, 13, 14, 15, 16, 17)
                mAutoKoniec(CLng(v)) = True
            Next v
        End If
        On Error GoTo 0
    End If
    If mAutoKoniec.Exists(lCislo) Then JeAutoKoniec = CBool(mAutoKoniec(lCislo))
End Function

'-------------------------------------------------------------------------------
' Zahodí cache (po zmene číselníka prerušení).
'-------------------------------------------------------------------------------
Public Sub ObnovCache()
    Set mAutoKoniec = Nothing
End Sub

'-------------------------------------------------------------------------------
' Pridá udalosť do poľa na správne miesto podľa (Cas, Zdroj) - zachová zoradenie.
'-------------------------------------------------------------------------------
Private Sub VlozUdalost(ByRef ev() As TUdalost, ByRef n As Long, ByRef e As TUdalost)
    Dim j As Long
    n = n + 1
    If n > UBound(ev) Then ReDim Preserve ev(1 To UBound(ev) + 8)
    j = n - 1
    Do While j >= 1
        If ev(j).Cas > e.Cas Or (ev(j).Cas = e.Cas And ev(j).Zdroj > e.Zdroj) Then
            ev(j + 1) = ev(j)
            j = j - 1
        Else
            Exit Do
        End If
    Loop
    ev(j + 1) = e
End Sub

'-------------------------------------------------------------------------------
' Nájde jednu ďalšiu opravu pre deň (po zohľadnení už navrhnutých). Vráti False, ak už nič opraviteľné nezostalo.
'-------------------------------------------------------------------------------
Private Function JedenNavrh(ByRef ev() As TUdalost, ByVal n As Long, ByVal lFond As Long, ByRef nav As TNavrh) As Boolean
    Dim r As TVysledokDna, lOdpr As Long, lPrek As Long, lRem As Long, lNeed As Long, lKon As Long, i As Long
    Dim bObed As Boolean, lObedMin As Long, lWin As Long, lCiel As Long, lPripady As Long

    Call mod_08_UdalostiDna.SpracujDen(ev, 1, n, r)
    Call mod_08_UdalostiDna.UplatniZaokruhlenie(r)
    Call mod_08_UdalostiDna.SumarDna(r, lFond, lOdpr, lPrek)
    lObedMin = mod_08_UdalostiDna.PrmObedMin()
    lWin = mod_08_UdalostiDna.PrmOknoDo()
    lCiel = CielAutoOpravy()
    lPripady = PripadyAutoOpravy()

    ' 1) otvorené prerušenie na konci dňa
    If r.PrerOtvorene Then
        If r.PrerCislo = 7 Then
            nav.Trieda = "A": nav.Kod = "DOPLN_KONIEC_OBEDA"
            nav.Cas = r.PrerZac + lObedMin: nav.Smer = "K": nav.Cislo = 7: nav.Zdroj = 1
            nav.Popis = "Chýbal návrat z obeda - doplnený štandardný obed (" & lObedMin & " min)"
            JedenNavrh = True
            Exit Function
        End If
        If JeAutoKoniec(r.PrerCislo) And (lPripady And 2) <> 0 Then
            lRem = lFond - lOdpr - lPrek
            If lRem < 0 Then lRem = 0
            lKon = r.PrerZac + lRem
            If lCiel = 1 And lWin > r.PrerZac Then
                lKon = lWin
            ElseIf lKon > lWin And lWin > r.PrerZac Then
                lKon = lWin
            End If
            nav.Trieda = "B": nav.Kod = "DOPLN_KONIEC_PRERUSENIA"
            nav.Cas = lKon: nav.Smer = "K": nav.Cislo = r.PrerCislo: nav.Zdroj = 2
            If lCiel = 1 Then
                nav.Popis = "Prerušenie bez návratu - ukončené na konci okna práce (" & mod_00_Common.MinutyNaCasText(lKon) & ")"
            Else
                nav.Popis = "Prerušenie bez návratu - ukončené do naplnenia denného fondu (" & mod_00_Common.MinutyNaCasText(lKon) & ")"
            End If
            JedenNavrh = True
        End If
        Exit Function         ' ostatné otvorené prerušenia ostávajú na ručné posúdenie
    End If

    ' 2) chýbajúci začiatok obeda (koniec obeda bez začiatku)
    For i = 1 To r.nAn
        If r.An(i).Kod = "KONIEC_BEZ_ZACIATKU" And r.An(i).Cislo = 7 Then
            nav.Trieda = "A": nav.Kod = "DOPLN_ZACIATOK_OBEDA"
            nav.Cas = r.An(i).Cas - lObedMin: If nav.Cas < 0 Then nav.Cas = 0
            nav.Smer = "Z": nav.Cislo = 7: nav.Zdroj = 1
            nav.Popis = "Chýbal odchod na obed - doplnený štandardný obed (" & lObedMin & " min)"
            JedenNavrh = True
            Exit Function
        End If
    Next i

    ' 3) otvorená práca (chýba odchod) - odhad podľa fondu
    If r.Praca And Not r.PracaObnovena And (lPripady And 1) <> 0 Then
        lRem = lFond - lOdpr - lPrek
        If lRem < 0 Then lRem = 0
        lNeed = lRem
        For i = 1 To r.nIv
            If r.Iv(i).Cislo = 7 Then bObed = True
        Next i
        If lFond > 0 And Not bObed And (lOdpr + lRem) > mod_08_UdalostiDna.PrmObedLimit() Then lNeed = lNeed + lObedMin
        lKon = r.PracaZac + lNeed
        If lCiel = 1 And lWin > r.PracaZac Then lKon = lWin
        If lKon > lWin And lWin > r.PracaZac Then lKon = lWin
        If lKon < r.PracaZac Then lKon = r.PracaZac
        nav.Trieda = "B": nav.Kod = "DOPLN_ODCHOD"
        nav.Cas = lKon: nav.Smer = "K": nav.Cislo = 1: nav.Zdroj = 1
        If lCiel = 1 Then
            nav.Popis = "Chýbal odchod - doplnený na koniec okna práce (" & mod_00_Common.MinutyNaCasText(lKon) & ")"
        Else
            nav.Popis = "Chýbal odchod - odhad podľa denného fondu (" & mod_00_Common.MinutyNaCasText(lKon) & ")"
        End If
        JedenNavrh = True
    End If
End Function

'-------------------------------------------------------------------------------
' Kľúč opravy pre porovnanie s existujúcimi záznamami.
'-------------------------------------------------------------------------------
Private Function KluzOpravy(ByVal dDen As Date, ByRef nav As TNavrh) As String
    KluzOpravy = Format$(dDen, "yyyymmdd") & "|" & nav.Kod & "|" & nav.Cas & "|" & nav.Smer & "|" & nav.Cislo
End Function

'-------------------------------------------------------------------------------
' Načíta existujúce opravy zamestnanca za mesiac: kľúč -> "ID|STAV".
'-------------------------------------------------------------------------------
Private Function NacitajExistujuce(ByRef db As DAO.Database, ByVal strOC As String, ByVal iRok As Integer, ByVal iMes As Integer) As Object
    Dim dic As Object, rs As DAO.Recordset
    Set dic = CreateObject("Scripting.Dictionary")
    Set rs = db.OpenRecordset("SELECT ID, Datum, Typ, Cas, Smer, CisloPreruseni, Stav FROM " & TBL & _
            " WHERE OsobneCislo = " & mod_00_Common.SqlText(strOC) & _
            " AND Datum >= " & mod_00_Common.SqlDatum(DateSerial(iRok, iMes, 1)) & " AND Datum < " & mod_00_Common.SqlDatum(DateSerial(iRok, iMes + 1, 1)) & ";", dbOpenSnapshot)
    Do While Not rs.EOF
        dic(Format$(CDate(rs!Datum), "yyyymmdd") & "|" & CStr(rs!Typ) & "|" & CLng(rs!Cas) & "|" & CStr(rs!Smer) & "|" & CLng(rs!CisloPreruseni)) = CStr(rs!ID) & "|" & CStr(Nz(rs!Stav, ""))
        rs.MoveNext
    Loop
    rs.Close
    Set NacitajExistujuce = dic
End Function

'-------------------------------------------------------------------------------
' Slovenský popis anomálie a jej závažnosť (INFO = vyriešené automaticky / bez vplyvu, CHYBA = vyžaduje posúdenie).
'-------------------------------------------------------------------------------
Private Function PopisAnomalie(ByRef a As TAnomalia, ByRef strZavaznost As String) As String
    Dim s As String
    strZavaznost = "CHYBA"
    Select Case a.Kod
        Case "DUPLICITA"
            s = "Opakované razenie (kód " & a.Cislo & ") v krátkom čase - ignorované": strZavaznost = "INFO"
        Case "PRICHOD_V_PRERUSENI"
            s = "Príchod počas otvoreného prerušenia " & a.Cislo & " - prerušenie ukončené príchodom": strZavaznost = "INFO"
        Case "ODCHOD_V_PRERUSENI"
            s = "Odchod počas otvoreného prerušenia " & a.Cislo & " - prerušenie ukončené odchodom": strZavaznost = "INFO"
        Case "PREKRYV_PRERUSENI"
            s = "Prerušenie " & a.Cislo & " bez návratu pred ďalším prerušením (" & a.Info & ") - ukončené začiatkom nasledujúceho": strZavaznost = "INFO"
        Case "DVOJITY_PRICHOD"
            s = "Dvojitý príchod bez odchodu"
        Case "ODCHOD_BEZ_PRICHODU"
            s = "Odchod bez príchodu"
        Case "KONIEC_BEZ_ZACIATKU"
            s = "Koniec prerušenia " & a.Cislo & " bez jeho začiatku"
        Case "NEUKONCENA_PRACA"
            s = "Chýba odchod"
        Case "NEUKONCENE_PRERUSENIE"
            s = "Prerušenie " & a.Cislo & " bez návratu"
        Case "PRERUSENIE_MIMO_INTERVALU", "PRERUSENIE_PRILIS_DLHE", "PRERUSENIE_PRIKRATKE", "PRERUSENIE_PRED_MINIMOM"
            s = a.Info
            strZavaznost = "VAROVANIE"
        Case Else
            s = a.Kod
    End Select
    PopisAnomalie = s & " (" & mod_00_Common.MinutyNaCasText(a.Cas) & ")"
End Function

'-------------------------------------------------------------------------------
' Analyzuje mesiac zamestnanca, zosúladí opravy v DochadzkaAutoOpravy a prepíše zoznam anomálií v DochadzkaAnomalie.
'-------------------------------------------------------------------------------
Public Sub AnalyzujMesiacZamestnanca(ByRef db As DAO.Database, ByVal strOC As String, ByVal iRok As Integer, ByVal iMes As Integer)
    On Error GoTo Chyba
    Dim lRezim As Long, u() As TUdalost, ev() As TUdalost, n As Long, m As Long
    Dim i As Long, i1 As Long, j As Long, it As Long, k As TKontextMesiaca
    Dim dDen As Date, lFond As Long, nav As TNavrh, e As TUdalost, r As TVysledokDna
    Dim dicEx As Object, dicNew As Object, strKey As String, v As Variant, strStav As String
    Dim rsOpr As DAO.Recordset, rsAn As DAO.Recordset, bStop As Boolean, strZav As String
    Dim lF0 As Long, lSabl As Long, lK0 As Long

    ' uzavretý (podpísaný) mesiac sa nemení: bez analýzy, bez zmeny opráv a anomálií
    If mod_18_Uzavierka.JeUzavrety(strOC, iRok, iMes) Then Exit Sub
    lRezim = RezimAutoOpravy()
    Call ZabezpecTabulky(db)
    Set dicEx = NacitajExistujuce(db, strOC, iRok, iMes)
    Set dicNew = CreateObject("Scripting.Dictionary")
    Set rsOpr = db.OpenRecordset("SELECT * FROM " & TBL & " WHERE ID = 0;", dbOpenDynaset, dbAppendOnly)

    db.Execute "DELETE FROM DochadzkaAnomalie WHERE OsobneCislo = " & mod_00_Common.SqlText(strOC) & _
               " AND Rok = " & iRok & " AND Mesiac = " & iMes & ";", dbFailOnError
    Set rsAn = db.OpenRecordset("SELECT * FROM DochadzkaAnomalie WHERE ID = 0;", dbOpenDynaset, dbAppendOnly)

    n = mod_08_UdalostiDna.NacitajUdalosti(db, strOC, DateSerial(iRok, iMes, 1), DateSerial(iRok, iMes + 1, 1), u, False)
    If n > 0 Then
        Call mod_08_UdalostiDna.NacitajKontextMesiaca(db, strOC, iRok, iMes, k)
        Call mod_08_UdalostiDna.NastaveniaZamestnanca(db, strOC, iRok, iMes, lF0, lSabl, lK0)
        i = 1
        Do While i <= n
            i1 = mod_08_UdalostiDna.HranicaDna(u, n, i)
            dDen = u(i).Datum
            If Not mod_05_UI_AttendanceEditor.Ed_JeDenUpraveny(strOC, dDen) Then
                lFond = k.Fond(Day(dDen))
                ' kópia udalostí dňa
                m = i1 - i + 1
                ReDim ev(1 To m + 8)
                For j = 1 To m
                    ev(j) = u(i + j - 1)
                Next j

                bStop = False
                For it = 1 To 6
                    If Not JedenNavrh(ev, m, lFond, nav) Then Exit For
                    strKey = KluzOpravy(dDen, nav)
                    If dicEx.Exists(strKey) Then
                        strStav = Split(CStr(dicEx(strKey)), "|")(1)
                        dicNew(strKey) = True
                        If strStav = "ZAMIETNUTE" Then Exit For          ' používateľ opravu zamietol - nepokračuj
                        If strStav = "ZASTARANE" Then
                            Call ObnovitStav(db, CLng(Split(CStr(dicEx(strKey)), "|")(0)), IIf(nav.Trieda = "A" Or lRezim >= 2, "UPLATNENE", "NAVRH"))
                        End If
                    ElseIf lRezim > 0 Then
                        rsOpr.AddNew
                        rsOpr!OsobneCislo = strOC
                        rsOpr!Datum = dDen
                        rsOpr!Cas = nav.Cas
                        rsOpr!Smer = nav.Smer
                        rsOpr!CisloPreruseni = nav.Cislo
                        rsOpr!Zdroj = nav.Zdroj
                        rsOpr!Typ = nav.Kod
                        rsOpr!Trieda = nav.Trieda
                        rsOpr!Popis = Left$(nav.Popis, 255)
                        rsOpr!Stav = IIf(nav.Trieda = "A" Or lRezim >= 2, "UPLATNENE", "NAVRH")
                        rsOpr!DatumVzniku = Now
                        rsOpr!Uzivatel = "SYSTEM"
                        rsOpr.Update
                        dicNew(strKey) = True
                    Else
                        Exit For
                    End If
                    ' predpokladaj uplatnenie opravy pre ďalší krok analýzy
                    e.Datum = dDen: e.Cas = nav.Cas: e.Smer = nav.Smer: e.Cislo = nav.Cislo: e.Zdroj = nav.Zdroj: e.ID = 0
                    Call VlozUdalost(ev, m, e)
                Next it

                ' zostávajúce anomálie dňa
                Call mod_08_UdalostiDna.SpracujDen(ev, 1, m, r)
                Call mod_16_PravidlaPreruseni.VyhodnotDen(db, r, dDen, lSabl)
                For j = 1 To r.nAn
                    rsAn.AddNew
                    rsAn!OsobneCislo = strOC
                    rsAn!rok = iRok
                    rsAn!Mesiac = iMes
                    rsAn!Datum = dDen
                    rsAn!TypAnomalie = Left$(r.An(j).Kod, 50)
                    rsAn!PopisAnomalie = Left$(PopisAnomalie(r.An(j), strZav), 255)
                    rsAn!Zavaznost = strZav
                    rsAn!Cas = r.An(j).Cas
                    rsAn!DatumZaznamu = Now
                    rsAn.Update
                Next j
            End If
            i = i1 + 1
        Loop
    End If
    rsOpr.Close: rsAn.Close

    ' opravy, ktoré už nie sú potrebné (doplnilo sa skutočné razenie / zmenili sa dáta)
    For Each v In dicEx.Keys
        If Not dicNew.Exists(CStr(v)) Then
            strStav = Split(CStr(dicEx(v)), "|")(1)
            If strStav = "NAVRH" Or strStav = "UPLATNENE" Then Call ObnovitStav(db, CLng(Split(CStr(dicEx(v)), "|")(0)), "ZASTARANE")
        End If
    Next v
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_09_AutoOprava.AnalyzujMesiacZamestnanca", "ERROR", Err.Description, "OC=" & strOC & " " & iMes & "/" & iRok)
End Sub

Private Sub ObnovitStav(ByRef db As DAO.Database, ByVal lID As Long, ByVal strStav As String)
    On Error Resume Next
    db.Execute "UPDATE " & TBL & " SET Stav = " & mod_00_Common.SqlText(strStav) & ", DatumRozhodnutia = Now(), Uzivatel = " & _
               mod_00_Common.SqlText(IIf(strStav = "ZASTARANE", "SYSTEM", mod_00_Common.Uzivatel())) & " WHERE ID = " & lID & ";", dbFailOnError
End Sub

'-------------------------------------------------------------------------------
' Analyzuje mesiac pre všetkých (alebo jedného) zamestnancov s razeniami. Vráti počet nevyriešených anomálií (CHYBA).
' Súhrn je k dispozícii cez PoslednySumar().
'-------------------------------------------------------------------------------
Public Function AnalyzujObdobie(ByVal iRok As Integer, ByVal iMes As Integer, Optional ByVal strOC As String = "") As Long
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset, strSQL As String, lEmp As Long
    Set db = CurrentDb
    Call ZabezpecTabulky(db)

    strSQL = "SELECT DISTINCT OsobneCislo FROM DochadzkaImport WHERE Datum >= " & mod_00_Common.SqlDatum(DateSerial(iRok, iMes, 1)) & _
             " AND Datum < " & mod_00_Common.SqlDatum(DateSerial(iRok, iMes + 1, 1)) & " AND OsobneCislo IS NOT NULL"
    If Len(strOC) > 0 Then
        strSQL = strSQL & " AND OsobneCislo = " & mod_00_Common.SqlText(strOC)
    Else
        strSQL = strSQL & mod_15_Zamestnanci.SqlVynechVyradenych("OsobneCislo", DateSerial(iRok, iMes, 1))
    End If
    Set rs = db.OpenRecordset(strSQL & ";", dbOpenSnapshot)
    Do While Not rs.EOF
        Call AnalyzujMesiacZamestnanca(db, CStr(rs!OsobneCislo), iRok, iMes)
        lEmp = lEmp + 1
        rs.MoveNext
        DoEvents
    Loop
    rs.Close

    AnalyzujObdobie = PocetAnomalii(iRok, iMes, strOC, "CHYBA")
    mSumar = "Zamestnancov: " & lEmp & vbCrLf & _
             "Opravy uplatnené: " & PocetNavrhov(iRok, iMes, "UPLATNENE", strOC) & vbCrLf & _
             "Návrhy na schválenie: " & PocetNavrhov(iRok, iMes, "NAVRH", strOC) & vbCrLf & _
             "Zamietnuté: " & PocetNavrhov(iRok, iMes, "ZAMIETNUTE", strOC) & vbCrLf & _
             "Anomálie na ručné posúdenie: " & AnalyzujObdobie
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_09_AutoOprava.AnalyzujObdobie", "ERROR", Err.Description)
    AnalyzujObdobie = -1
End Function

Public Function PoslednySumar() As String
    PoslednySumar = mSumar
End Function

'-------------------------------------------------------------------------------
' Počet anomálií za mesiac podľa závažnosti ("" = všetky).
'-------------------------------------------------------------------------------
Public Function PocetAnomalii(ByVal iRok As Integer, ByVal iMes As Integer, Optional ByVal strOC As String = "", Optional ByVal strZav As String = "") As Long
    On Error Resume Next
    Dim s As String
    s = "Rok = " & iRok & " AND Mesiac = " & iMes
    If Len(strOC) > 0 Then s = s & " AND OsobneCislo = " & mod_00_Common.SqlText(strOC)
    If Len(strZav) > 0 Then s = s & " AND Zavaznost = " & mod_00_Common.SqlText(strZav)
    PocetAnomalii = CLng(DCount("*", "DochadzkaAnomalie", s))
End Function

'-------------------------------------------------------------------------------
' Počet opráv v danom stave za mesiac ("" = všetky stavy), voliteľne pre zamestnanca alebo zoznam OC v SQL tvare.
'-------------------------------------------------------------------------------
Public Function PocetNavrhov(ByVal iRok As Integer, ByVal iMes As Integer, ByVal strStav As String, Optional ByVal strOC As String = "", Optional ByVal strOcSQL As String = "") As Long
    On Error Resume Next
    Dim s As String
    s = "Datum >= " & mod_00_Common.SqlDatum(DateSerial(iRok, iMes, 1)) & " AND Datum < " & mod_00_Common.SqlDatum(DateSerial(iRok, iMes + 1, 1))
    If Len(strStav) > 0 Then s = s & " AND Stav = " & mod_00_Common.SqlText(strStav)
    If Len(strOC) > 0 Then s = s & " AND OsobneCislo = " & mod_00_Common.SqlText(strOC)
    If Len(strOcSQL) > 0 Then s = s & " AND OsobneCislo IN (" & strOcSQL & ")"
    s = s & mod_18_Uzavierka.SqlNeuzavrete(iRok, iMes, "OsobneCislo")
    PocetNavrhov = CLng(DCount("*", TBL, s))
End Function

'-------------------------------------------------------------------------------
' Patrí oprava (podľa ID) do uzavretého mesiaca zamestnanca?
'-------------------------------------------------------------------------------
Private Function NavrhUzavrety(ByVal lID As Long) As Boolean
    Dim vOC As Variant, vD As Variant
    On Error Resume Next
    If Not mod_18_Uzavierka.ExistujeUzavrety() Then Exit Function
    vOC = DLookup("OsobneCislo", TBL, "ID = " & lID)
    vD = DLookup("Datum", TBL, "ID = " & lID)
    If Not IsNull(vOC) And Not IsNull(vD) Then NavrhUzavrety = mod_18_Uzavierka.JeUzavretyDen(CStr(vOC), vD)
End Function

'-------------------------------------------------------------------------------
' Schváli (UPLATNENE) všetky návrhy mesiaca / zamestnanca / jednu opravu (lID > 0). Vráti počet schválených.
'-------------------------------------------------------------------------------
Public Function SchvalNavrhy(ByVal iRok As Integer, ByVal iMes As Integer, Optional ByVal strOC As String = "", _
                             Optional ByVal lID As Long = 0, Optional ByVal strOcSQL As String = "") As Long
    On Error GoTo Chyba
    Dim s As String, n As Long
    If lID > 0 Then
        s = "ID = " & lID & " AND Stav IN ('NAVRH','ZAMIETNUTE','ZASTARANE')"
    Else
        s = "Stav = 'NAVRH' AND Datum >= " & mod_00_Common.SqlDatum(DateSerial(iRok, iMes, 1)) & " AND Datum < " & mod_00_Common.SqlDatum(DateSerial(iRok, iMes + 1, 1))
        If Len(strOC) > 0 Then s = s & " AND OsobneCislo = " & mod_00_Common.SqlText(strOC)
        If Len(strOcSQL) > 0 Then s = s & " AND OsobneCislo IN (" & strOcSQL & ")"
    End If
    If lID > 0 Then
        If NavrhUzavrety(lID) Then
            MsgBox "Oprava patrí do uzavretého (podpísaného) mesiaca - nedá sa schváliť. Mesiac najprv otvorte (záložka 6 Výpočet - Uzávierka mesiaca).", vbExclamation, "Uzavretý mesiac"
            Exit Function
        End If
    Else
        s = s & mod_18_Uzavierka.SqlNeuzavrete(iRok, iMes, "OsobneCislo")
    End If
    n = CLng(DCount("*", TBL, s))
    CurrentDb.Execute "UPDATE " & TBL & " SET Stav = 'UPLATNENE', DatumRozhodnutia = Now(), Uzivatel = " & mod_00_Common.SqlText(mod_00_Common.Uzivatel()) & " WHERE " & s & ";", dbFailOnError
    If n > 0 Then Call mod_00_Common.ZapisLog("Auto-oprava", "INFO", "Schválené opravy: " & n, "Mesiac " & iMes & "/" & iRok & " " & strOC)
    SchvalNavrhy = n
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_09_AutoOprava.SchvalNavrhy", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Zamietne opravu (výkaz sa vráti do pôvodného stavu; oprava sa už pri analýze znova nenavrhne).
'-------------------------------------------------------------------------------
Public Function ZamietniNavrh(ByVal lID As Long) As Boolean
    On Error GoTo Chyba
    If NavrhUzavrety(lID) Then
        MsgBox "Oprava patrí do uzavretého (podpísaného) mesiaca - nedá sa zmeniť. Mesiac najprv otvorte (záložka 6 Výpočet - Uzávierka mesiaca).", vbExclamation, "Uzavretý mesiac"
        Exit Function
    End If
    CurrentDb.Execute "UPDATE " & TBL & " SET Stav = 'ZAMIETNUTE', DatumRozhodnutia = Now(), Uzivatel = " & mod_00_Common.SqlText(mod_00_Common.Uzivatel()) & " WHERE ID = " & lID & ";", dbFailOnError
    Call mod_00_Common.ZapisLog("Auto-oprava", "INFO", "Zamietnutá oprava ID " & lID)
    ZamietniNavrh = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_09_AutoOprava.ZamietniNavrh", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Vráti opravu do stavu NAVRH (napr. po omylom zamietnutí).
'-------------------------------------------------------------------------------
Public Function VratNavrh(ByVal lID As Long) As Boolean
    On Error GoTo Chyba
    If NavrhUzavrety(lID) Then
        MsgBox "Oprava patrí do uzavretého (podpísaného) mesiaca - nedá sa zmeniť. Mesiac najprv otvorte (záložka 6 Výpočet - Uzávierka mesiaca).", vbExclamation, "Uzavretý mesiac"
        Exit Function
    End If
    CurrentDb.Execute "UPDATE " & TBL & " SET Stav = 'NAVRH', DatumRozhodnutia = Now(), Uzivatel = " & mod_00_Common.SqlText(mod_00_Common.Uzivatel()) & " WHERE ID = " & lID & ";", dbFailOnError
    VratNavrh = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_09_AutoOprava.VratNavrh", "ERROR", Err.Description)
End Function

'-------------------------------------------------------------------------------
' Pred tlačou výkazu: spraví analýzu a ak existujú neschválené návrhy, opýta sa (Áno = schváliť, Nie = bez nich, Zrušiť = zastaviť).
' Vráti False, ak používateľ zvolil Zrušiť.
'-------------------------------------------------------------------------------
Public Function PripravAOveriMesiac(ByVal strOC As String, ByVal iRok As Integer, ByVal iMes As Integer, Optional ByVal strOcSQL As String = "") As Boolean
    On Error GoTo Chyba
    Dim db As DAO.Database, rs As DAO.Recordset, lNav As Long, strSQL As String
    Dim lVolba As VbMsgBoxResult

    PripravAOveriMesiac = True
    Set db = CurrentDb
    If Len(strOC) > 0 Then
        Call AnalyzujMesiacZamestnanca(db, strOC, iRok, iMes)
    Else
        strSQL = "SELECT DISTINCT OsobneCislo FROM DochadzkaImport WHERE Datum >= " & mod_00_Common.SqlDatum(DateSerial(iRok, iMes, 1)) & _
                 " AND Datum < " & mod_00_Common.SqlDatum(DateSerial(iRok, iMes + 1, 1)) & " AND OsobneCislo IS NOT NULL"
        If Len(strOcSQL) > 0 Then strSQL = strSQL & " AND OsobneCislo IN (" & strOcSQL & ")"
        Set rs = db.OpenRecordset(strSQL & ";", dbOpenSnapshot)
        Do While Not rs.EOF
            Call AnalyzujMesiacZamestnanca(db, CStr(rs!OsobneCislo), iRok, iMes)
            rs.MoveNext
        Loop
        rs.Close
    End If

    lNav = PocetNavrhov(iRok, iMes, "NAVRH", strOC, strOcSQL)
    If lNav = 0 Then Exit Function

    lVolba = MsgBox("Systém našiel " & lNav & " návrhov automatických opráv chýbajúcich pípnutí (napr. doplnený odchod podľa fondu)." & vbCrLf & vbCrLf & _
                    "Áno = schváliť opravy a pokračovať" & vbCrLf & _
                    "Nie = pokračovať bez opráv (výkaz podľa skutočných pípnutí)" & vbCrLf & _
                    "Zrušiť = nepokračovať" & vbCrLf & vbCrLf & _
                    "Opravy je možné kedykoľvek zamietnuť v záložke Kontrola & Auto-oprava.", _
                    vbYesNoCancel + vbQuestion, "Automatické opravy dochádzky")
    Select Case lVolba
        Case vbYes
            Call SchvalNavrhy(iRok, iMes, strOC, 0, strOcSQL)
        Case vbCancel
            PripravAOveriMesiac = False
    End Select
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_09_AutoOprava.PripravAOveriMesiac", "ERROR", Err.Description)
End Function

'===============================================================================
' OBSLUŽNÉ FUNKCIE PRE ZÁLOŽKU (volané z mod_UI_Tab_AutoOprava)
'===============================================================================

Public Function AO_Obdobie(ByRef iRok As Integer, ByRef iMes As Integer) As Boolean
    On Error GoTo Chyba
    Dim frm As Form
    Set frm = Forms!frmHlavnaKonzola
    Dim lR As Long, lM As Long
    If mod_UI_Spolocne.ObdobieZVyberu(frm!cboAoObdobie, lR, lM) Then
        iRok = CInt(lR): iMes = CInt(lM)
        AO_Obdobie = True
    Else
        MsgBox "Vyberte mesiac zo zoznamu.", vbExclamation, "Kontrola dochádzky"
    End If
    Exit Function
Chyba:
    AO_Obdobie = False
End Function

Public Function AO_Analyzuj() As Boolean
    Dim iRok As Integer, iMes As Integer, l As Long
    If Not AO_Obdobie(iRok, iMes) Then Exit Function
    Screen.MousePointer = 11
    l = AnalyzujObdobie(iRok, iMes)
    Screen.MousePointer = 0
    Call AO_Obnov
    MsgBox "Analýza obdobia " & iMes & "/" & iRok & " dokončená." & vbCrLf & vbCrLf & PoslednySumar(), vbInformation, "Kontrola dochádzky"
    AO_Analyzuj = True
End Function

Public Function AO_SchvalVsetky() As Boolean
    Dim iRok As Integer, iMes As Integer, n As Long
    If Not AO_Obdobie(iRok, iMes) Then Exit Function
    n = SchvalNavrhy(iRok, iMes)
    Call AO_Obnov
    MsgBox "Schválených opráv: " & n & vbCrLf & "Výpočet sa zohľadní pri ďalšom prepočte / tlači výkazu.", vbInformation, "Kontrola dochádzky"
    AO_SchvalVsetky = True
End Function

Private Function AO_VybraneID() As Long
    On Error Resume Next
    Dim frm As Form
    Set frm = Forms!frmHlavnaKonzola
    If IsNull(frm!lstAoOpravy.Value) Then Exit Function
    AO_VybraneID = CLng(frm!lstAoOpravy.Value)
End Function

Public Function AO_SchvalVybranu() As Boolean
    Dim l As Long
    l = AO_VybraneID()
    If l = 0 Then MsgBox "Označte opravu v zozname.", vbExclamation, "Kontrola dochádzky": Exit Function
    Call SchvalNavrhy(0, 0, "", l)
    Call AO_Obnov
    AO_SchvalVybranu = True
End Function

Public Function AO_ZamietniVybranu() As Boolean
    Dim l As Long
    l = AO_VybraneID()
    If l = 0 Then MsgBox "Označte opravu v zozname.", vbExclamation, "Kontrola dochádzky": Exit Function
    Call ZamietniNavrh(l)
    Call AO_Obnov
    AO_ZamietniVybranu = True
End Function

Public Function AO_VratVybranu() As Boolean
    Dim l As Long
    l = AO_VybraneID()
    If l = 0 Then MsgBox "Označte opravu v zozname.", vbExclamation, "Kontrola dochádzky": Exit Function
    Call VratNavrh(l)
    Call AO_Obnov
    AO_VratVybranu = True
End Function

Public Function AO_ZmenRezim() As Boolean
    On Error Resume Next
    Dim frm As Form
    Set frm = Forms!frmHlavnaKonzola
    Call NastavRezim(CLng(Val(Nz(frm!cboAoRezim.Value, 1))))
    AO_ZmenRezim = True
End Function

'-------------------------------------------------------------------------------
' Obnoví zoznamy opráv a anomálií podľa zvoleného obdobia a filtra stavu.
'-------------------------------------------------------------------------------
Public Function AO_Obnov() As Boolean
    On Error GoTo Chyba
    Dim frm As Form, iRok As Integer, iMes As Integer, strStav As String, strSQL As String, strWhere As String
    If Not mod_00_Common.FormIsOpen("frmHlavnaKonzola") Then Exit Function
    Set frm = Forms!frmHlavnaKonzola
    If Not AO_Obdobie(iRok, iMes) Then Exit Function
    Call ZabezpecTabulky(CurrentDb)

    strStav = CStr(Nz(frm!cboAoStav.Value, "NAVRH"))
    strWhere = "A.Datum >= " & mod_00_Common.SqlDatum(DateSerial(iRok, iMes, 1)) & " AND A.Datum < " & mod_00_Common.SqlDatum(DateSerial(iRok, iMes + 1, 1))
    If strStav <> "VSETKY" Then strWhere = strWhere & " AND A.Stav = " & mod_00_Common.SqlText(strStav)

    strSQL = "SELECT A.ID, A.OsobneCislo AS [Os. číslo], Format(A.Datum,'dd.mm.yyyy') AS [Deň], Format(A.Cas \ 60,'00') & ':' & Format(A.Cas Mod 60,'00') AS [Čas], " & _
             "A.Trieda AS [Trieda], A.Stav AS [Stav], A.Popis AS [Popis opravy] FROM " & TBL & " AS A WHERE " & strWhere & " ORDER BY A.OsobneCislo, A.Datum, A.Cas;"
    frm!lstAoOpravy.RowSourceType = "Table/Query"
    frm!lstAoOpravy.RowSource = strSQL

    strSQL = "SELECT OsobneCislo AS [Os. číslo], Format(Datum,'dd.mm.yyyy') AS [Deň], IIf(Zavaznost = 'VAROVANIE','(!) ','') & Replace(TypAnomalie,'_',' ') AS [Typ anomálie], PopisAnomalie AS [Popis] FROM DochadzkaAnomalie " & _
             "WHERE Rok = " & iRok & " AND Mesiac = " & iMes & " AND (Zavaznost = 'CHYBA' OR Zavaznost = 'VAROVANIE') ORDER BY OsobneCislo, Datum, Cas;"
    frm!lstAoAnomalie.RowSourceType = "Table/Query"
    frm!lstAoAnomalie.RowSource = strSQL

    frm!lblAoStav.Caption = "Opravy: uplatnené " & PocetNavrhov(iRok, iMes, "UPLATNENE") & ", návrhy " & PocetNavrhov(iRok, iMes, "NAVRH") & _
                            ", zamietnuté " & PocetNavrhov(iRok, iMes, "ZAMIETNUTE") & "   |   na ručné posúdenie: " & PocetAnomalii(iRok, iMes, "", "CHYBA") & _
                            ", upozornení (!): " & PocetAnomalii(iRok, iMes, "", "VAROVANIE")
    AO_Obnov = True
    Exit Function
Chyba:
    Call mod_00_Common.ZapisLog("mod_09_AutoOprava.AO_Obnov", "ERROR", Err.Description)
End Function
