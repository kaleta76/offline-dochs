Attribute VB_Name = "mod_16_PravidlaPreruseni"
'@Verzia 1.0.0
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_16_PravidlaPreruseni
' POPIS: Kontrola prerušení podľa pravidiel šablóny prerušení zamestnanca (tabuľka ParametrePreruseni; pravidlá
'        z pôvodnej aplikácie Ordata). Kontrola NEMENÍ vypočítaný čas, iba pridá upozornenie do zoznamu anomálií
'        (závažnosť VAROVANIE), napr. "Obed 10:40-11:15 mimo povoleného času 11:00-13:30".
'
'   Pravidlá prerušenia (pre každú šablónu a číslo prerušenia, platné od mesiaca):
'     - povolený interval (od - do): jedna dvojica pre všetky dni alebo osobitne pre každý deň v týždni,
'     - najdlhšie trvanie: jedna hodnota alebo osobitne pre každý deň v týždni (1440 = bez obmedzenia),
'     - najmenej odpracovať pred začiatkom prerušenia (napr. obed až po 3 hodinách práce),
'     - najkratšie trvanie prerušenia,
'     - pravidlo možno vypnúť (PravidloVypnute); celú kontrolu vypnete nastavením KontrolaPravidielPreruseni = 0.
'   Kontrolujú sa iba skutočné prerušenia krátke ako celodenná prekážka; intervaly doplnené automatickou opravou sa
'   nekontrolujú (čas je odhad).
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - ObnovPravidla()                        : Zahodí vyrovnávaciu pamäť pravidiel (po úprave pravidiel).
' - VyhodnotDen(db, r, dDen, lSablona)     : Pridá upozornenia dňa do r (po SpracujDen).
'===============================================================================

Public Const ZAV_VAROVANIE As String = "VAROVANIE"
Public Const KOD_MIMO_INTERVALU As String = "PRERUSENIE_MIMO_INTERVALU"
Public Const KOD_PRILIS_DLHE As String = "PRERUSENIE_PRILIS_DLHE"
Public Const KOD_PRIKRATKE As String = "PRERUSENIE_PRIKRATKE"
Public Const KOD_PRED_MINIMOM As String = "PRERUSENIE_PRED_MINIMOM"

Private mCache As Object
Private mNacitane As Boolean
Private mVypnute As Boolean

Public Sub ObnovPravidla()
    Set mCache = Nothing
    mNacitane = False
End Sub

Private Function KontrolaZapnuta() As Boolean
    If Not mNacitane Then
        mVypnute = (mod_00_Common.GetNastavenie("KontrolaPravidielPreruseni", "1") = "0")
        mNacitane = True
    End If
    KontrolaZapnuta = Not mVypnute
End Function

'-------------------------------------------------------------------------------
' Pravidlo z riadka tabuľky: slovník krátkych kľúčov (čísla v minútach; príznaky -1 / 0).
'-------------------------------------------------------------------------------
Private Function PravidloZRiadka(ByRef rs As DAO.Recordset) As Object
    Dim x As Object, d As Long
    Set x = CreateObject("Scripting.Dictionary")
    On Error Resume Next
    x("Nazov") = CStr(Nz(rs.Fields("NazovPreruseni").Value, ""))
    x("IntOdM") = CLng(Nz(rs.Fields("IntervalMesiacOdMin").Value, 0))
    x("IntDoM") = CLng(Nz(rs.Fields("IntervalMesiacDoMin").Value, 0))
    x("IntDni") = CLng(Nz(rs.Fields("IntervalDniTyzdna").Value, 0))
    x("MaxM") = CLng(Nz(rs.Fields("MaxTrvanieMesiacMin").Value, 0))
    x("MaxDni") = CLng(Nz(rs.Fields("MaxTrvanieDniTyzdna").Value, 0))
    x("MinO") = CLng(Nz(rs.Fields("MinOdpracovaneMin").Value, 0))
    x("MinT") = CLng(Nz(rs.Fields("MinTrvanieMin").Value, 0))
    x("Vypnute") = CLng(Nz(rs.Fields("PravidloVypnute").Value, 0))
    For d = 1 To 7
        x("IntOd" & d) = CLng(Nz(rs.Fields("IntervalDen" & d & "OdMin").Value, 0))
        x("IntDo" & d) = CLng(Nz(rs.Fields("IntervalDen" & d & "DoMin").Value, 0))
        x("Max" & d) = CLng(Nz(rs.Fields("MaxTrvanieDen" & d & "Min").Value, 0))
    Next d
    Set PravidloZRiadka = x
End Function

'-------------------------------------------------------------------------------
' Pravidlá šablóny platné pre mesiac ym (Rok*12+Mesiac): pre každé prerušenie najnovšia verzia <= ym,
' ak taká nie je, najstaršia. Výsledok: slovník číslo prerušenia -> pravidlo.
'-------------------------------------------------------------------------------
Private Function Pravidla(ByRef db As DAO.Database, ByVal lSab As Long, ByVal ym As Long) As Object
    Dim key As String, dic As Object, rs As DAO.Recordset, c As Long, yr As Long
    If mCache Is Nothing Then Set mCache = CreateObject("Scripting.Dictionary")
    key = lSab & "|" & ym
    If mCache.Exists(key) Then
        Set Pravidla = mCache.Item(key)
        Exit Function
    End If
    Set dic = CreateObject("Scripting.Dictionary")
    If mod_00_Common.TabulkaExistujeDB(db, "ParametrePreruseni") Then
        Set rs = db.OpenRecordset("SELECT * FROM ParametrePreruseni WHERE Sablona = " & lSab & " ORDER BY (Rok * 12 + Mesiac);", dbOpenSnapshot)
        Do While Not rs.EOF
            c = CLng(Nz(rs!CisloPreruseni, 0))
            yr = CLng(Nz(rs!Rok, 0)) * 12 + CLng(Nz(rs!Mesiac, 0))
            If c > 0 Then
                If yr <= ym Then
                    If dic.Exists(c) Then dic.Remove c
                    dic.Add c, PravidloZRiadka(rs)
                ElseIf Not dic.Exists(c) Then
                    dic.Add c, PravidloZRiadka(rs)
                End If
            End If
            rs.MoveNext
        Loop
        rs.Close
    End If
    mCache.Add key, dic
    Set Pravidla = dic
End Function

Private Function Cas(ByVal lMin As Long) As String
    Cas = mod_00_Common.MinutyNaCasText(lMin)
End Function

'-------------------------------------------------------------------------------
' Odpracované minúty pred okamihom lCas (súčet intervalov práce, číslo 1).
'-------------------------------------------------------------------------------
Private Function OdpracovanePred(ByRef r As TVysledokDna, ByVal lCas As Long) As Long
    Dim j As Long, lKon As Long, lSuma As Long
    For j = 1 To r.nIv
        If r.Iv(j).Cislo = 1 Then
            lKon = r.Iv(j).Kon
            If lKon > lCas Then lKon = lCas
            If lKon > r.Iv(j).Zac Then lSuma = lSuma + (lKon - r.Iv(j).Zac)
        End If
    Next j
    OdpracovanePred = lSuma
End Function

'-------------------------------------------------------------------------------
' Vyhodnotí prerušenia dňa podľa šablóny lSablona a pridá upozornenia do r (volať po SpracujDen).
'-------------------------------------------------------------------------------
Public Sub VyhodnotDen(ByRef db As DAO.Database, ByRef r As TVysledokDna, ByVal dDen As Date, ByVal lSablona As Long)
    On Error GoTo Chyba
    Dim rul As Object, x As Object, i As Long, c As Long, zac As Long, kon As Long, dur As Long, wd As Long
    Dim lOd As Long, lDo As Long, lMax As Long, lMinO As Long, lMinT As Long, lOdpr As Long, lCelo As Long
    Dim strN As String

    If Not KontrolaZapnuta() Then Exit Sub
    If r.nIv <= 0 Then Exit Sub
    Set rul = Pravidla(db, lSablona, CLng(Year(dDen)) * 12 + Month(dDen))
    If rul.Count = 0 Then Exit Sub
    wd = Weekday(dDen, vbMonday)
    lCelo = mod_08_UdalostiDna.PrmCelodennaPrekazka()

    For i = 1 To r.nIv
        c = r.Iv(i).Cislo
        If c <> 1 Then
            If rul.Exists(c) And Not r.Iv(i).ZacAuto And Not r.Iv(i).KonAuto Then
                zac = r.Iv(i).Zac
                kon = r.Iv(i).Kon
                dur = kon - zac
                If dur > 0 And dur < lCelo Then
                    Set x = rul.Item(c)
                    If CLng(x.Item("Vypnute")) = 0 Then
                        strN = CStr(x.Item("Nazov"))
                        If Len(strN) = 0 Then strN = "Prerušenie " & c

                        ' povolený interval
                        If CLng(x.Item("IntDni")) <> 0 Then
                            lOd = CLng(x.Item("IntOd" & wd))
                            lDo = CLng(x.Item("IntDo" & wd))
                        Else
                            lOd = CLng(x.Item("IntOdM"))
                            lDo = CLng(x.Item("IntDoM"))
                        End If
                        If lDo > lOd And Not (lOd <= 0 And lDo >= 1440) Then
                            If zac < lOd Or kon > lDo Then
                                Call mod_08_UdalostiDna.PridajAnomaliuDna(r, KOD_MIMO_INTERVALU, zac, c, _
                                    strN & " " & Cas(zac) & "-" & Cas(kon) & " mimo povoleného času " & Cas(lOd) & "-" & Cas(lDo))
                            End If
                        End If

                        ' najdlhšie trvanie
                        If CLng(x.Item("MaxDni")) <> 0 Then lMax = CLng(x.Item("Max" & wd)) Else lMax = CLng(x.Item("MaxM"))
                        If lMax > 0 And lMax < 1440 And dur > lMax Then
                            Call mod_08_UdalostiDna.PridajAnomaliuDna(r, KOD_PRILIS_DLHE, zac, c, _
                                strN & " trvalo " & dur & " min, povolené najviac " & lMax & " min")
                        End If

                        ' najkratšie trvanie
                        lMinT = CLng(x.Item("MinT"))
                        If lMinT > 0 And dur < lMinT Then
                            Call mod_08_UdalostiDna.PridajAnomaliuDna(r, KOD_PRIKRATKE, zac, c, _
                                strN & " trvalo " & dur & " min, požadované najmenej " & lMinT & " min")
                        End If

                        ' najmenej odpracovať pred začiatkom
                        lMinO = CLng(x.Item("MinO"))
                        If lMinO > 0 Then
                            lOdpr = OdpracovanePred(r, zac)
                            If lOdpr < lMinO Then
                                Call mod_08_UdalostiDna.PridajAnomaliuDna(r, KOD_PRED_MINIMOM, zac, c, _
                                    strN & " začalo po " & lOdpr & " min práce, požadované najmenej " & lMinO & " min")
                            End If
                        End If
                    End If
                End If
            End If
        End If
    Next i
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_16_PravidlaPreruseni.VyhodnotDen", "ERROR", Err.Description)
End Sub
