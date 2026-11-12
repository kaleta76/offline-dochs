Attribute VB_Name = "mod_UI_PomocnikTexty"
'@Verzia 1.3.3
Option Compare Database
Option Explicit

'===============================================================================
' MODUL: mod_UI_PomocnikTexty
' POPIS: Predvolené texty Pomocníka (info okná kariet konzoly). NaplnTexty zapíše karty do tabuľky
'        PomocnikKarty a riadky okien do tabuľky PomocnikTexty. Riadky, ktoré používateľ upravil
'        (v tabuľke zaškrtnuté Upravene), sa pri obnove nemenia.
'
' DRUHY RIADKOV (stĺpec Typ):
'   UCEL     - čo karta robí            KROK     - číslovaný krok postupu        MOZNOST - voliteľná možnosť
'   TIP      - užitočná rada            POZOR    - upozornenie                   DALEJ   - čo nasleduje
'
' V TEXTOCH sa používajú značky (zdroj je len v kódovaní cp1250): {>} šípka, {.} bodka v strede, {-} pomlčka, {*} odrážka.
' ZOZNAM PROCEDÚR A FUNKCIÍ:
' ------------------------------------------------------------------------------
' - NaplnTexty(db, verzia)   : Zapíše karty a predvolené texty (zachová upravené riadky).
'===============================================================================

Private mRs As DAO.Recordset
Private mKarty As DAO.Recordset
Private mKarta As String
Private mPoradie As Long
Private mKrok As Long
Private mVerzia As String
Private mUpravene As String

'-------------------------------------------------------------------------------
' Zapíše predvolené karty a texty Pomocníka. Upravené riadky (Upravene = Áno) ostávajú, ostatné sa vymenia.
'-------------------------------------------------------------------------------
Public Sub NaplnTexty(ByRef db As DAO.Database, ByVal strVerzia As String)
    On Error GoTo Chyba
    Dim rs As DAO.Recordset
    mVerzia = strVerzia
    mUpravene = "|"
    Set rs = db.OpenRecordset("SELECT Karta, Poradie FROM PomocnikTexty WHERE Upravene = True;", dbOpenSnapshot)
    Do While Not rs.EOF
        mUpravene = mUpravene & rs!Karta & ":" & rs!Poradie & "|"
        rs.MoveNext
    Loop
    rs.Close
    db.Execute "DELETE FROM PomocnikTexty WHERE Upravene = False OR Upravene Is Null;", dbFailOnError

    Set mRs = db.OpenRecordset("SELECT * FROM PomocnikTexty;", dbOpenDynaset)
    Set mKarty = db.OpenRecordset("SELECT * FROM PomocnikKarty;", dbOpenDynaset)

    Call SeedProces
    Call SeedImport
    Call SeedZamestnanci
    Call SeedKontrola
    Call SeedEditor
    Call SeedPrerusenia
    Call SeedVypocet
    Call SeedExport
    Call SeedAdmin
    Call SeedAD

    mRs.Close
    mKarty.Close
    Set mRs = Nothing
    Set mKarty = Nothing
    Exit Sub
Chyba:
    Call mod_00_Common.ZapisLog("mod_UI_PomocnikTexty.NaplnTexty", "ERROR", Err.Description)
End Sub

'-------------------------------------------------------------------------------
' Nahradí značky v texte znakmi, ktoré nie sú v kódovaní zdrojového súboru.
'-------------------------------------------------------------------------------
Private Function Sym(ByVal s As String) As String
    s = Replace(s, "{>}", ChrW(8594))
    s = Replace(s, "{.}", ChrW(183))
    s = Replace(s, "{-}", ChrW(8211))
    s = Replace(s, "{*}", ChrW(8226))
    Sym = s
End Function

'-------------------------------------------------------------------------------
' Zapíše (alebo aktualizuje) kartu; používateľom zmenené AutoZobraz sa zachová.
'-------------------------------------------------------------------------------
Private Sub NovaKarta(ByVal strKluc As String, ByVal lPoradie As Long, ByVal strKratky As String, ByVal strNazov As String, _
                      ByVal strPodtitul As String, ByVal bAuto As Boolean)
    mKarty.FindFirst "Karta = '" & strKluc & "'"
    If mKarty.NoMatch Then
        mKarty.AddNew
        mKarty!Karta = strKluc
        mKarty!AutoZobraz = bAuto
    Else
        mKarty.Edit
    End If
    mKarty!Poradie = lPoradie
    If lPoradie >= 1 Then mKarty!Cislo = CStr(lPoradie) Else mKarty!Cislo = Null
    mKarty!Kratky = strKratky
    mKarty!Nazov = strNazov
    mKarty!Podtitul = Left$(Sym(strPodtitul), 255)
    mKarty!Verzia = mVerzia
    mKarty.Update
    mKarta = strKluc
    mPoradie = 0
    mKrok = 0
End Sub

'-------------------------------------------------------------------------------
' Pridá riadok do okna aktuálnej karty (Poradie sa zvyšuje po desiatkach, aby sa dali vkladať vlastné riadky).
'-------------------------------------------------------------------------------
Private Sub Riadok(ByVal strTyp As String, ByVal strNadpis As String, ByVal strPopis As String)
    Dim strStitok As String
    mPoradie = mPoradie + 10
    Select Case strTyp
        Case "UCEL": strStitok = "ČO TO JE"
        Case "KROK": mKrok = mKrok + 1: strStitok = "KROK " & mKrok
        Case "MOZNOST": strStitok = "MOŽNOSŤ"
        Case "TIP": strStitok = "TIP"
        Case "POZOR": strStitok = "POZOR"
        Case "DALEJ": strStitok = "ĎALEJ"
        Case Else: strStitok = strTyp
    End Select
    If InStr(mUpravene, "|" & mKarta & ":" & mPoradie & "|") > 0 Then Exit Sub
    mRs.AddNew
    mRs!Karta = mKarta
    mRs!Poradie = mPoradie
    mRs!Typ = strTyp
    mRs!Stitok = strStitok
    mRs!Nadpis = Left$(Sym(strNadpis), 150)
    mRs!Popis = Sym(strPopis)
    mRs!Upravene = False
    mRs!Verzia = mVerzia
    mRs.Update
End Sub

'===============================================================================
' 0  PREHĽAD CELÉHO POSTUPU
'===============================================================================
Private Sub SeedProces()
    Call NovaKarta("PROCES", 0, "Postup", "Prehľad celého postupu", _
        "Od prevzatia dát z Ordata až po zostavy a export pre terminál. Karty 1 až 9 sú zoradené v odporúčanom poradí.", False)
    Riadok "UCEL", "Na čo systém slúži", "Lokálny dochádzkový systém: prevezme razenia z Ordata, skontroluje ich, doplní chýbajúce pípnutia, prepočíta odpracovaný čas a salda a vytlačí mesačné zostavy. Terminál (lovable.app) dostane len pravidlá a číselníky, bez osobných údajov."
    Riadok "KROK", "1  Import dát", "Prevezmite zamestnancov a razenia z Ordata (DBF), zo staršej databázy, z CSV alebo zadaním osobných čísel. Robí sa pri prvom spustení a potom podľa potreby, napríklad raz za mesiac."
    Riadok "KROK", "2  Zamestnanci", "Skontrolujte zoznam zamestnancov a podľa potreby upravte kartu zamestnanca, úväzok (napríklad 50 % pre polovičný úväzok) a vyraďte tých, ktorí už v zostavách nemajú byť. Každému zamestnancovi, alebo vybranej skupine, možno priradiť vlastný pracovný fond, pravidlá prerušení a kalendár."
    Riadok "KROK", "3  Kontrola a automatické opravy", "Overte pripravenosť dát a nechajte nájsť chýbajúce pípnutia (odchod, návrat z obeda). Opravy sú len virtuálne - pôvodné razenia sa nemenia a každú opravu môžete schváliť alebo zamietnuť."
    Riadok "KROK", "4  Editor dochádzky", "Dni, ktoré auto-oprava nevyrieši, opravíte ručne: pridáte alebo zrušíte razenie či prerušenie. Pôvodný deň sa dá vždy obnoviť a každá zmena sa zapíše do auditu."
    Riadok "KROK", "5  Prerušenia a nastavenia", "Jednorazové nastavenie pravidiel: číselník prerušení, kódy razení terminálu, parametre výpočtu a časový profil strediska. Najlepšie pred prvým výpočtom."
    Riadok "KROK", "6  Výpočet a zostavy", "Prepočítajte mesiac pre vybraných alebo všetkých zamestnancov (fond, odpracovaný čas, saldo, nadčas), zobrazte zostavu Záznam o dochádzke a vytlačte ju. Keď je zostava podpísaná, mesiac zamestnanca uzavrite tlačidlom Uzávierka mesiaca - parametre výpočtu a razenia sa potom nedajú omylom zmeniť."
    Riadok "KROK", "7  Exporty a terminál", "Pripravte konfiguráciu pre terminál (JSON bez osobných údajov) a spracujte pípnutia prijaté z terminálu do dochádzky."
    Riadok "KROK", "8  Audit a administrácia", "Anonymizácia, čistenie pomocných tabuliek, zámok importu, skrývanie menu a info okná. Bežne ich nepotrebujete."
    Riadok "KROK", "9  Active Directory (voliteľné)", "Ak firma používa doménu, doplňte z nej prihlasovacie mená, e-maily, oddelenia a nadriadených. Karta sa zobrazí len pri prístupe k doméne (alebo ak ju zapnete na karte 8) a môžete ju preskočiť."
    Riadok "TIP", "Poradie nie je povinné", "Karty prepnete tlačidlami v hlavičke alebo klávesmi Alt+1 až Alt+9, v ľubovoľnom poradí. Každá má info okno: tlačidlo Pomocník alebo Alt+P. Po vykonaní činnosti sa okno už samo neukáže."
    Riadok "TIP", "Menu a objekty Accessu", "Pás kariet (Menu) a ľavý navigačný panel s objektmi databázy sú pri štarte skryté, aby nerušili. Tlačidlo Menu v hlavičke (Alt+M) zobrazí a skryje len pás kariet, tlačidlo Objekty (Alt+O) len ľavý panel s objektmi. Či sa majú pri štarte skrývať, nastavíte na karte 8. Zostavy pás kariet zobrazia samy."
    Riadok "POZOR", "Kópia databázy", "Pred hromadným importom, anonymizáciou alebo čistením si uložte kópiu súboru databázy. Inštalátor vždy vytvorí novú verziu a pôvodný súbor ostane nezmenený."
End Sub

'===============================================================================
' 1  IMPORT
'===============================================================================
Private Sub SeedImport()
    Call NovaKarta("IMPORT", 1, "Import", "Import dát", _
        "Naplnenie databázy zamestnancami a razeniami: z Ordata (DBF), zo staršej databázy, z CSV alebo zadaním osobných čísel.", True)
    Riadok "UCEL", "Čo karta robí", "Nová databáza je prázdna - potrebuje zamestnancov a ich razenia (pípnutia). Táto karta ich prevezme z Ordata, zo staršej verzie databázy, z CSV/TXT, alebo si osobné čísla zadáte sami. Import môžete kedykoľvek zopakovať."
    Riadok "TIP", "Ktorú cestu zvoliť", "A) Máte export z Ordata (súbory DBF): kroky 1 až 4. B) Máte staršiu databázu dochádzky: možnosť 5 v spodnej časti karty. C) Nemáte nič: zadáte osobné čísla a razenia prídu neskôr z terminálu."
    Riadok "KROK", "Adresár s DBF súbormi", "Do poľa Adresár DBF súborov zadajte priečinok s exportom z Ordata (musia v ňom byť cis_zamestnanec.dbf a cis_dochdata.dbf) alebo ho vyberte tlačidlom Prehľadávať... Cesta sa zapamätá."
    Riadok "KROK", "Obdobie importu", "Mesiac Od a Do vyberiete v zoznamoch. Tlačidlo Tento rok nastaví január až aktuálny mesiac, Minulý mesiac nastaví celý predošlý mesiac (Od aj Do je ten istý mesiac). Posledná voľba sa zapamätá."
    Riadok "KROK", "Osobné čísla (nepovinné)", "Prázdne pole = všetci zamestnanci. Na obmedzenie zadajte čísla s ľubovoľným oddeľovačom (čiarka, bodkočiarka, medzera, nový riadok) alebo rozsah, napríklad 1001-1010. Import razení sa obmedzí len na ne."
    Riadok "KROK", "Spustiť import", "Tlačidlo SPUSTIŤ KOMPLETNÝ DÁVKOVÝ IMPORT načíta zamestnancov aj razenia. Najprv zobrazí zhrnutie (obdobie, osobné čísla) na potvrdenie. Razenia z DBF sa v období načítajú znova, ručné úpravy ostanú."
    Riadok "MOZNOST", "Čiastkové operácie", "Tlačidlá 1 a 2 importujú samostatne len zamestnancov alebo len razenia. Tlačidlo 4 skontroluje, či majú všetky razenia platný kód prerušenia, a chýbajúce kódy doplní - spustite ho po importe razení."
    Riadok "MOZNOST", "Osobné čísla bez Ordata", "Zadajte osobné čísla do poľa Osobné čísla a kliknite na Pridať ako zamestnancov. Mená a oddelenia doplníte neskôr importom z CSV (tlačidlo 3) alebo synchronizáciou s AD (karta 9)."
    Riadok "MOZNOST", "Import z CSV alebo TXT", "Tlačidlo 3 načíta zamestnancov zo súboru (osobné číslo, meno, oddelenie, vedúci). Stĺpce rozpozná samo a zobrazí report: počty, rozpoznané stĺpce a zamietnuté riadky."
    Riadok "MOZNOST", "Zo staršej databázy", "Tlačidlo 5 vyberie starší súbor .accdb a doplní z neho zamestnancov, razenia a číselníky, ktoré tu ešte nie sú. Nič sa nemaže ani neprepisuje a opakovaný import nič nezdvojí. Denné výpočty sa potom prepočítajú."
    Riadok "TIP", "Databáza z inštalátora", "Ak ste pri inštalácii prevzali databázu z predošlej verzie, údaje sú v nej už prenesené a tento krok nepotrebujete. Okno sa v takom prípade ani neukáže."
    Riadok "POZOR", "Zámok importu", "Ak je import uzamknutý (karta 8, Prepnúť zámok importu), dávkový import sa odmietne s upozornením."
    Riadok "DALEJ", "Čo potom", "Po importe skontrolujte na karte 2 Zamestnanci zoznam, úväzky a priradený pracovný fond a pokračujte kartou 3 Kontrola a automatické opravy. Ak firma používa doménu, môžete najprv na karte 9 doplniť prihlasovacie mená a nadriadených."
End Sub

'===============================================================================
' 2  ZAMESTNANCI
'===============================================================================
Private Sub SeedZamestnanci()
    Call NovaKarta("ZAMESTNANCI", 2, "Zamestnanci", "Zamestnanci a ich pracovný fond", _
        "Ručná úprava zamestnancov: karta, úväzok, vyradenie a vlastný pracovný fond a pravidlá prerušení pre jednotlivcov alebo skupiny.", True)
    Riadok "UCEL", "Čo karta robí", "Každý zamestnanec môže mať vlastný úväzok, pracovný fond, šablónu pravidiel prerušení a kalendár. Stĺpce zoznamu ukazujú, čo platí pre vybraný mesiac. Karta slúži aj na pridanie nových zamestnancov a vyradenie tých, ktorí už nemajú byť v zostavách."
    Riadok "KROK", "Zobraziť zoznam", "Hore vyberte mesiac (alebo tlačidlami < a >) a prípadne hľadajte podľa osobného čísla, mena alebo oddelenia. Pri zapnutom políčku aj vyradení zoznam obsahuje aj vyradených zamestnancov; stĺpec Stav ukazuje dátum vyradenia."
    Riadok "KROK", "Karta zamestnanca", "Dvojklik na riadok alebo tlačidlo Karta zamestnanca... otvorí okno s osobným číslom, číslom karty, menom, titulom, organizáciou, strediskom, textom na displeji, úväzkom, blokovaním karty, vyradením a poznámkou. Dolu v okne vyberiete pracovný fond, šablónu prerušení a kalendár platné od zvoleného mesiaca."
    Riadok "KROK", "Nový zamestnanec", "Tlačidlo Nový zamestnanec... otvorí prázdnu kartu. Povinné je osobné číslo; pracovný fond, šablónu prerušení a kalendár vyberiete v dolnej časti okna a uložíte tlačidlom Uložiť."
    Riadok "MOZNOST", "Úväzok", "Úväzok v percentách (napríklad 50 pre polovičný úväzok) skráti fond zamestnanca v daný deň v rovnakom pomere. Prázdne pole znamená 100 %."
    Riadok "MOZNOST", "Vyradiť zamestnanca", "Tlačidlo Vyradiť označených... zadá dátum vyradenia. Vyradený zamestnanec sa od mesiaca, ktorý začína v ten deň alebo po ňom, nezobrazuje vo výpočte, zostavách ani v analýze. Údaje a razenia ostanú v databáze a tlačidlo Vrátiť do evidencie ho znova zaradí."
    Riadok "KROK", "Priradiť fond, pravidlá a úväzok", "Označte jedného alebo viacerých zamestnancov (Ctrl alebo Shift) a kliknite na Priradiť fond, pravidlá a úväzok označeným... Pre každú vec vyberiete hodnotu alebo ponecháte (nemeniť). Zmena platí od zvoleného mesiaca; staršie mesiace ostanú podľa predošlého nastavenia."
    Riadok "MOZNOST", "Nová skupina", "V okne priradenia zapnite Vytvoriť z označených novú skupinu, zadajte názov a vyberte, či sa má vytvoriť vlastná kópia pracovného fondu a pravidiel prerušení. Kópia sa priradí všetkým označeným, takže jej úprava sa týka len ich. Hodí sa napríklad pre zamestnancov s inou pracovnou dobou."
    Riadok "MOZNOST", "Pracovné fondy a pravidlá", "Tlačidlo Pracovné fondy... otvorí editor fondu, tlačidlo Pravidlá prerušení... editor pravidiel. Ak je v zozname označený zamestnanec, editor sa otvorí na fonde alebo šablóne, ktorá platí pre neho. V editore: zoznam Zamestnanec prepne na fond alebo šablónu platnú pre iného zamestnanca, zoznam Verzie ukáže históriu (platné od mesiaca), tlačidlo Kto používa vypíše zamestnancov a zoznam Predvoľba vyplní bežné hodnoty (pevná 7:30, pružná, dvanásťhodinová zmena, obed ...). Vyplnenie sa uloží až tlačidlom Uložiť. Nový fond vznikne ako kópia alebo z predvoľby."
    Riadok "TIP", "Zmeny podľa mesiacov", "Fond, pravidlá aj priradenie zamestnanca platia od zvoleného mesiaca a platia ďalej, kým ich nezmeníte - nekopírujú sa mesiac po mesiaci (ako šablóny v Ordata). Zmenou od januára sa výpočet za december nezmení; pre mesiac sa vždy použije najnovšia verzia platná k nemu. Zoznam Verzie v editore ukáže, od ktorých mesiacov nastavenie platí. Po zmene mesiac prepočítajte na karte 6."
    Riadok "POZOR", "Prepočet po zmene", "Zmena úväzku, fondu alebo vyradenia sa prejaví až po novom prepočte mesiaca na karte 6 Výpočet a zostavy."
    Riadok "POZOR", "Uzavretý mesiac", "Ak je mesiac zamestnanca uzavretý (karta 6, Uzávierka mesiaca), zmena fondu, pravidiel, úväzku, kalendára alebo vyradenia, ktorá by tento mesiac zmenila, sa neuloží. V editoroch sa to ukáže červeným upozornením ešte pred uložením. Mesiac najprv otvorte s uvedením dôvodu, alebo zvoľte platnosť od neskoršieho mesiaca."
    Riadok "DALEJ", "Čo potom", "Pokračujte kartou 3 Kontrola a automatické opravy. Číselníky prerušení, kódy razení a parametre výpočtu nastavíte na karte 5."
End Sub

'===============================================================================
' 9  ACTIVE DIRECTORY (voliteľná karta)
'===============================================================================
Private Sub SeedAD()
    Call NovaKarta("AD", 9, "AD", "Active Directory", _
        "Doplnenie zamestnancov, prihlasovacích údajov a nadriadených z doménového Active Directory (voliteľné).", True)
    Riadok "UCEL", "Čo karta robí", "Systém prečíta účty z domény (LDAP), nájde zamestnancov podľa osobného čísla a doplní prihlasovacie meno, e-mail, oddelenie a nadriadeného. Z väzieb nadriadený {-} podriadený určí vedúcich. Karta je voliteľná."
    Riadok "KROK", "Atribút s osobným číslom", "V poli Atribút s osobným číslom je názov atribútu AD, v ktorom je uložené osobné číslo (predvolene employeeID). Zamestnanec sa páruje len pri presnej zhode."
    Riadok "KROK", "Kontajner (OU)", "Pole Kontajner je nepovinné. Zadajte ho, ak chcete čítať len časť domény, napríklad OU=Zamestnanci,DC=firma,DC=local. Prázdne pole = celá doména."
    Riadok "KROK", "Synchronizovať existujúcich", "Tlačidlo SYNCHRONIZOVAŤ EXISTUJÚCICH ZAMESTNANCOV S AD doplní údaje len zamestnancom, ktorí už sú v databáze (po importe na karte 1)."
    Riadok "MOZNOST", "Načítať z domény", "Tlačidlo NAČÍTAŤ ZAMESTNANCOV Z DOMÉNY pridá aj nových zamestnancov, ktorí majú v AD osobné číslo. Hodí sa, ak nemáte export z Ordata alebo chcete doplniť nových."
    Riadok "MOZNOST", "Prepočítať hierarchiu", "Tlačidlo Prepočítať hierarchiu a roly vedúcich znova určí vedúcich z väzieb nadriadený {-} podriadený. Ručne nastavené roly (napríklad ADMIN) sa nemenia."
    Riadok "TIP", "Kedy sa karta zobrazí", "Karta sa zobrazí sama len vtedy, keď počítač vidí doménu. Bez domény ju môžete trvalo zapnúť alebo skryť na karte 8 (Karta Active Directory: automaticky / vždy / nikdy)."
    Riadok "TIP", "Stav synchronizácie", "Riadok pod tlačidlami ukazuje počet zamestnancov, počet s nadriadeným a počet vedúcich. Podľa neho poznáte, či synchronizácia zabrala."
    Riadok "POZOR", "Potrebná doména", "Počítač musí vidieť doménu (firemná sieť alebo VPN). Ak nie, operácia zlyhá - dôvod uvidíte v stavovom riadku dole a v tabuľke LogImportu."
    Riadok "DALEJ", "Čo potom", "Pokračujte kartou 2 Zamestnanci alebo kartou 3 Kontrola a automatické opravy."
End Sub

'===============================================================================
' 3  KONTROLA A AUTOMATICKÉ OPRAVY
'===============================================================================
Private Sub SeedKontrola()
    Call NovaKarta("KONTROLA", 3, "Kontrola", "Kontrola a automatické opravy", _
        "Overenie pripravenosti dát a návrh opráv chýbajúcich pípnutí - pôvodné razenia sa nikdy nemenia.", True)
    Riadok "UCEL", "Čo karta robí", "Nájde dni s chýbajúcimi alebo chybnými pípnutiami (chýba odchod, návrat z obeda, koniec prerušenia) a navrhne virtuálne opravy, aby ste pred tlačou nemuseli opravovať hodiny ručne. Pôvodné razenia sa nikdy nemenia."
    Riadok "KROK", "Overiť pripravenosť dát", "Tlačidlo OVERIŤ PRIPRAVENOSŤ DÁT zobrazí, či sú v databáze zamestnanci, kódy razení a razenia, a čo prípadne chýba."
    Riadok "KROK", "Mesiac a režim", "Vyberte Mesiac a Režim opráv. Predvolený režim: isté opravy (trieda A, napríklad chýbajúci návrat z obeda) sa uplatnia sami, odhady (trieda B, napríklad chýbajúci odchod) čakajú na schválenie."
    Riadok "MOZNOST", "Režimy opráv", "Vypnuté (len kontrola) {.} Isté opravy automaticky, odhady na schválenie {.} Všetko automaticky (odhady ostanú v zozname na kontrole). Voľba sa uloží."
    Riadok "KROK", "Analyzovať mesiac", "Tlačidlo ANALYZOVAŤ MESIAC prejde dni mesiaca a vytvorí zoznam opráv. Môžete ho spustiť opakovane: ak sa doplní skutočné razenie, nepotrebná oprava sa označí ako zastaraná."
    Riadok "KROK", "Schváliť alebo zamietnuť", "Označte opravu v zozname a použite Schváliť vybranú alebo Zamietnuť vybranú, prípadne Schváliť všetky. Tlačidlo Vrátiť na návrh rozhodnutie zruší. Filter Zobraziť opravy prepína zoznam podľa stavu."
    Riadok "MOZNOST", "Konsolidácia obdobia", "Tlačidlo SPUSTIŤ KONSOLIDÁCIU OBDOBIA spustí dátovú hygienu a kontrolu razení podľa pravidiel anomálií. Použite ho po importe a po väčších zmenách dát."
    Riadok "KROK", "Na ručné posúdenie", "Dolný zoznam ukazuje dni, ktoré sa automaticky opraviť nedajú (napríklad odchod bez príchodu). Opravte ich ručne v karte 4 Editor dochádzky."
    Riadok "MOZNOST", "Upozornenia z pravidiel prerušení", "Riadky so značkou (!) sú upozornenia z pravidiel prerušení: napríklad obed mimo povoleného času alebo pred odpracovaním minimálneho času. Výpočet sa nemení; upozornenie je len na posúdenie. Pravidlá nastavíte na karte 2 (Pravidlá prerušení...) alebo 5."
    Riadok "TIP", "Opravy sa dajú vrátiť", "Zamietnutím opravy sa výkaz vráti do pôvodného stavu. Dni, ktoré ste už upravili ručne v editore, auto-oprava preskakuje."
    Riadok "DALEJ", "Čo potom", "Zvyšné dni opravte v karte 4 Editor dochádzky, alebo pokračujte výpočtom na karte 6."
End Sub

'===============================================================================
' 4  EDITOR DOCHÁDZKY
'===============================================================================
Private Sub SeedEditor()
    Call NovaKarta("EDITOR", 4, "Editor", "Editor dochádzky", _
        "Ručná oprava dní zamestnanca: razenia, prerušenia, návrat na pôvodný stav, prepočet a tlač.", True)
    Riadok "UCEL", "Čo karta robí", "Zobrazí mesiac jedného zamestnanca po dňoch (razenia, odpracovaný čas, saldo) a umožní ručne opraviť razenia a prerušenia. Pôvodné razenia sa zachovajú, každá zmena sa zapíše do auditu a mesiac sa prepočíta."
    Riadok "KROK", "Vybrať zamestnanca", "V zozname Zamestnanec vyberte osobu. Tlačidlá < a > prechádzajú zamestnancov po jednom."
    Riadok "KROK", "Vybrať mesiac", "Mesiac vyberte v zozname alebo tlačidlami < a >. Tlačidlo Načítať / Prepočítať zobrazí a prepočíta zvolený mesiac."
    Riadok "KROK", "Prečítať výsledky", "Vľavo sú súčty mesiaca (fond, odpracované, sviatky, nadčas, stav) a rozpis prerušení. V tabuľke dní značka ! znamená nezrovnalosť v razeniach a upr. ručne upravený deň."
    Riadok "KROK", "Upraviť deň", "Dvojklik na deň alebo tlačidlo Upraviť deň (prerušenia) otvorí okno dňa so zoznamom razení, upozorneniami a vypočítanými intervalmi."
    Riadok "MOZNOST", "V okne dňa", "Pridať razenie (kód a čas), Opraviť označené, Zrušiť označené, Stav platnosti (platné alebo neplatné) a Pridať prerušenie (pár od {-} do). Pri oprave najprv označte riadok v zozname."
    Riadok "TIP", "Klávesy v okne dňa", "Stlačením Alt sa zvýraznia písmená skratiek: Alt+písmeno stlačí príslušné tlačidlo. Klávesom Esc zavriete okno dňa."
    Riadok "MOZNOST", "Pôvodný deň a prepočet", "Pôvodný deň vráti razenia dňa do stavu pred vašimi úpravami (snímka sa uloží pri prvej úprave). Prepočítať znova vypočíta deň a mesiac."
    Riadok "MOZNOST", "Tlač zostavy", "Tlačidlo Tlač zostavy zobrazí mesačnú zostavu Záznam o dochádzke vrátane vašich ručných úprav."
    Riadok "TIP", "Opakovaný import", "Upravené dni sa pri opakovanom importe z DBF neprepíšu. Zoznam zmien (kto, kedy, čo) je v tabuľke DochadzkaAudit."
    Riadok "DALEJ", "Čo potom", "Po opravách pokračujte kartou 6 Výpočet a zostavy."
End Sub

'===============================================================================
' 5  PRERUŠENIA A NASTAVENIA
'===============================================================================
Private Sub SeedPrerusenia()
    Call NovaKarta("PRERUSENIA", 5, "Prerušenia", "Prerušenia a nastavenia", _
        "Číselník prerušení, kódy razení terminálu, parametre výpočtu a časový profil strediska.", True)
    Riadok "UCEL", "Čo karta robí", "Jednorazové nastavenie pravidiel, podľa ktorých sa pípnutia vyhodnocujú: číselník prerušení (obed, lekár, služobná cesta ...), kódy razení terminálu, parametre výpočtu a časový profil strediska (pružný čas)."
    Riadok "KROK", "Predvolená konfigurácia", "Pri prvom použití kliknite na INICIALIZOVAŤ PREDVOLENÚ KONFIGURÁCIU. Doplní len to, čo chýba, a nič neprepíše. V databáze bez fondov vytvorí aj pracovný fond 7:30, šablónu pravidiel bez kontroly a kalendár a priradí ich zamestnancom bez priradenia (fondy zo staršej databázy najprv preneste na karte 1). Riadok pod tlačidlom ukazuje počet prerušení a kódov razení."
    Riadok "KROK", "Číselník prerušení", "V zozname vyberte prerušenie a upravte Číslo, Názov, Skratku, Kód začiatku a Kód konca (kódy, ktoré pípne terminál). Nové vytvoríte tlačidlom Nové, uložíte tlačidlom Uložiť a odstránite tlačidlom Zmazať."
    Riadok "MOZNOST", "Auto-ukončenie prerušenia", "Políčko Pri chýbajúcom návrate ukončiť do konca smeny určuje, že auto-oprava ukončí prerušenie bez návratu do konca fondu (ako odhad na schválenie)."
    Riadok "MOZNOST", "Tlačidlo pre terminál", "Blok Tlačidlo a príznaky pre terminál platí pre vybrané prerušenie. Zapnuté Tlačidlo v termináli dá zamestnancovi vlastné tlačidlo odchodu s týmto dôvodom (Príchod a Odchod sú vždy). Zadajte text (najviac 24 znakov, inak sa použije názov), poradie 1 až 99 a ikonu zo zoznamu. Tlačidiel môže byť najviac 12 a každé potrebuje práve jeden kód terminála (ak žiadny nie je, vznikne PRER a číslo prerušenia). Prerušenie 1 (práca) tlačidlo nemá. Nastavenie sa prenesie exportom konfigurácie (karta 7). Ak ho nezapnete, terminál sa správa ako doteraz."
    Riadok "MOZNOST", "Príznaky prerušenia", "Môže požiadať vopred: zamestnanec ho vie v termináli naplánovať. Schvaľuje vedúci: deň s týmto dôvodom je nepotvrdený, kým ho vedúci neschváli. Len na celý deň: dovolenka alebo PN, nemá tlačidlo. Nezapočíta sa do práce: neplatený odchod, interval sa nepočíta ani do práce, ani do prekážok dňa (obed č. 7 a práca č. 1 sa tak označiť nedajú). Príznaky sa uložia tlačidlom Uložiť a ovplyvnia až nový prepočet."
    Riadok "KROK", "Parametre výpočtu", "V časti 2 nastavte okno práce (od {-} do), dĺžku obeda a limit práce, od ktorého sa obed odpočíta, ak nebol pípnutý. Uložte tlačidlom Uložiť parametre."
    Riadok "KROK", "Pravidlá výpočtu", "V časti 2b nastavte razený obed (skutočný čas, najmenej alebo vždy presne zadané minúty), či odchod bez dôvodu z terminálu znamená obed alebo odchod, zaokrúhlenie prvého príchodu a posledného odchodu a kam sa dopĺňa zabudnuté razenie. Razený obed (najmenej alebo vždy presne) sa upraví len v dni, keď práca spolu s obedom dosiahne limit Obed od z časti 2 (predvolene 360 minút, teda od 6:00 vrátane); kratšia zmena nárok na prestávku nemá a obed sa počíta skutočným časom. Tlačidlá Predvoľba len vyplnia polia; uložíte ich tlačidlom Uložiť pravidlá. Predvolené hodnoty dávajú doterajší výpočet; uzavreté mesiace sa neprepočítajú."
    Riadok "KROK", "Časový profil strediska", "V časti 3 nastavte základný čas, pružný čas ráno a popoludní, službu cestou a obedné okno (od {-} do, trvanie v minútach). Uložte tlačidlom Uložiť časový profil strediska."
    Riadok "KROK", "Pracovné fondy a pravidlá prerušení", "Tlačidlo Pracovné fondy... otvorí editor fondov (dĺžka dňa, pružný čas, rôzne dni v týždni), tlačidlo Pravidlá prerušení... editor pravidiel, napríklad obed najskôr o 11:00 a najdlhšie 30 minút. V oboch oknách môžete vybrať zamestnanca, pozrieť históriu verzií (platné od mesiaca), zistiť, kto nastavenie používa, a použiť predvolené hodnoty."
    Riadok "TIP", "Komu sa fond a pravidlá priraďujú", "Editory menia číselníky. Ktorý zamestnanec má ktorý fond a ktorú šablónu pravidiel, nastavíte na karte 2 Zamestnanci, aj pre vybranú skupinu."
    Riadok "TIP", "Kedy to robiť", "Stačí raz pred prvým výpočtom, potom len pri zmene pravidiel. Zmena parametrov sa prejaví pri novom prepočte (karta 6)."
    Riadok "TIP", "Súvis s terminálom", "Kódy začiatku a konca prerušení sa exportom (karta 7) dostanú do konfigurácie terminálu. Musia sa zhodovať s kódmi, ktoré terminál pípa."
    Riadok "DALEJ", "Čo potom", "Pokračujte kartou 6 Výpočet a zostavy."
End Sub

'===============================================================================
' 6  VÝPOČET A ZOSTAVY
'===============================================================================
Private Sub SeedVypocet()
    Call NovaKarta("VYPOCET", 6, "Výpočet", "Výpočet a zostavy", _
        "Mesačný prepočet fondu, odpracovaného času a salda a tlač zostavy Záznam o dochádzke.", True)
    Riadok "UCEL", "Čo karta robí", "Prepočíta mesiac: z razení určí intervaly práce a prerušení, odpracovaný čas, fond, sviatky, nadčas a priebežné saldo. Potom zobrazí zostavu Záznam o dochádzke, ktorú môžete vytlačiť."
    Riadok "KROK", "Vybrať mesiac", "Mesiac vyberte v zozname alebo prepínajte tlačidlami < a >. Predvolený je predošlý mesiac."
    Riadok "KROK", "Koho prepočítať", "Označte zamestnancov v zozname (Ctrl alebo Shift pre viacerých) alebo zadajte osobné čísla do poľa (čiarka, bodkočiarka, medzera, rozsah 1001-1010). Poradie: zadané čísla, potom označení v zozname, inak všetci."
    Riadok "KROK", "Spustiť prepočet", "Tlačidlo SPUSTIŤ PREPOČET DOCHÁDZKY A SALDA vypočíta zvolený mesiac. Berú sa do úvahy ručne upravené dni aj schválené auto-opravy."
    Riadok "KROK", "Zobraziť zostavu", "Tlačidlo ZOBRAZIŤ TLAČOVÚ ZOSTAVU zobrazí Záznam o dochádzke. Pás kariet sa pri tom zobrazí sám: vytlačíte ju tlačidlom Tlač (Ctrl+P) a náhľad zatvoríte tlačidlom Zavrieť náhľad."
    Riadok "KROK", "Uzávierka mesiaca", "Po vytlačení a podpise zostavy kliknite na Uzávierka mesiaca... Okno ukáže zamestnancov zvoleného mesiaca: stav (uzavretý / otvorený), kedy sa vytvorila zostava a kto mesiac uzavrel. Označte zamestnancov s podpísanou zostavou, uveďte, kto zostavu potvrdil, a stlačte Uzavrieť. Systém uloží kontrolný kód výpočtu. Uzavrieť sa dá od posledného dňa mesiaca a len po zobrazení zostavy z aktuálnych údajov."
    Riadok "MOZNOST", "Otvoriť uzavretý mesiac", "Tlačidlo Otvoriť... vyžaduje dôvod (aspoň 5 znakov), ktorý sa zapíše do protokolu uzávierok spolu s dátumom a používateľom. Po oprave mesiac znova prepočítajte, vytlačte novú zostavu a uzavrite ho."
    Riadok "MOZNOST", "Overiť údaje", "Tlačidlo Overiť porovná uložené hodnoty uzavretých mesiacov s kontrolným kódom. Nezhoda znamená, že niekto zmenil údaje mimo aplikácie (napríklad priamo v tabuľke); zostava takého mesiaca sa vytlačí s upozornením."
    Riadok "TIP", "Úväzok a vyradení zamestnanci", "Prepočet berie fond každého zamestnanca podľa jeho pracovného fondu a úväzku (karta 2). Vyradení zamestnanci sa v zozname ani v zostavách nezobrazujú od mesiaca, ktorý začína v deň vyradenia alebo po ňom."
    Riadok "TIP", "Päta zostavy a podpis", "Zostava vytlačená pred uzavretím nesie v päte text NÁVRH - mesiac nie je uzavretý a kontrolný kód. Tú dáte podpísať. Tlačidlo Uzavrieť ju prijme len vtedy, ak sa údaje mesiaca od jej vytvorenia nezmenili (kontrolný kód sedí); inak treba zostavu zobraziť, vytlačiť a podpísať znova. Po uzavretí sa v päte zostavy ukáže MESIAC JE UZAVRETÝ s dátumom, menom potvrdzujúceho a rovnakým kontrolným kódom - podľa neho sa podpísaný papier spáruje s uzavretým mesiacom."
    Riadok "TIP", "Poradie mesiacov", "Odporúča sa uzatvárať mesiace postupne od najstaršieho. Systém poradie nevynucuje, no uzavretý mesiac chráni len seba."
    Riadok "POZOR", "Čo uzavretie chráni", "Uzavretý mesiac sa nedá prepočítať, upraviť v editore dňa ani prepísať importom z Ordata a nedá sa zmeniť fondom, pravidlami, úväzkom ani vyradením. Ochrana je na úrovni aplikácie; kontrolný kód odhalí zmenu hodnôt mimo aplikácie, ale nezabráni jej. Razenia z terminálu za uzavretý mesiac počkajú v príjme, kým mesiac neotvoríte."
    Riadok "TIP", "Vždy aktuálne údaje", "Po každej oprave v editore alebo schválení auto-opravy je dobré mesiac znova prepočítať, aby zostava ukazovala najnovší stav."
    Riadok "DALEJ", "Čo potom", "Ak používate terminál, pokračujte kartou 7 Exporty a terminál."
End Sub

'===============================================================================
' 7  EXPORTY A TERMINÁL
'===============================================================================
Private Sub SeedExport()
    Call NovaKarta("EXPORT", 7, "Exporty", "Exporty a terminál", _
        "Konfigurácia pre terminál (lovable.app) bez osobných údajov a spracovanie pípnutí prijatých z terminálu.", True)
    Riadok "UCEL", "Čo karta robí", "Pripraví súbory pre terminál a cloud (lovable.app) a spracuje pípnutia prijaté z terminálu. Terminál dostane len pravidlá, fondy a číselníky, bez osobných údajov."
    Riadok "KROK", "Cesta a obdobie", "Vyberte priečinok pre súbory (Prehľadávať...), mesiac a prípadne osobné čísla (prázdne = všetci)."
    Riadok "KROK", "Exportovať konfiguráciu", "Tlačidlo EXPORTOVAŤ KONFIGURÁCIU A TESTOVACIE DÁTA vytvorí dochs_config.json (pravidlá, fondy, číselníky) a dochs_test_sample.json (surové razenia a očakávané výsledky na overenie logiky)."
    Riadok "MOZNOST", "Konfigurácia pre terminál", "Tlačidlo Vytvoriť verziu konfigurácie prerušení pre terminál vytvorí JSON bez osobných údajov. Terminál ho použije s rovnakými kódmi, aké má tento systém."
    Riadok "MOZNOST", "Prijaté pípnutia", "Tlačidlo Spracovať prijaté pípnutia z terminálu prevedie záznamy z fronty TerminalInbox do dochádzky. Potom ich skontrolujte a prepočítajte (karty 3 až 6)."
    Riadok "MOZNOST", "Klient na razenie v Accesse", "Zamestnanci razia z Accessu na svojom počítači; každé razenie je malý súbor v zdieľanom priečinku prijem. Tlačidlo Klient na razenie v Accesse: nastaviť priečinok vytvorí podpriečinky a zapíše konfiguráciu tlačidiel (rovnaké ako v termináli). Práva na priečinky nastaví správca siete (zamestnanci v prijem len vytvárajú súbory)."
    Riadok "MOZNOST", "Prijať razenia z klientov", "Tlačidlo Prijať razenia z klientov skontroluje súbory (tvar, účet zamestnanca, vlastníka súboru, čas) a prevedie ich na razenia rovnako ako pri termináli. Najprv ho spustite nanečisto. Razenia dnešného dňa čakajú na ďalší deň. Neoverené razenia sa počítajú, ale skontrolujte ich v reporte pred uzávierkou mesiaca."
    Riadok "POZOR", "Komunikácia s terminálom", "Priama komunikácia s terminálom zatiaľ nie je zapnutá. Pripravený je prenos súborom a front TerminalInbox. Karty 1 až 6 fungujú aj bez terminálu."
    Riadok "DALEJ", "Čo potom", "Po spracovaní pípnutí sa vráťte ku karte 3 Kontrola a automatické opravy."
End Sub

'===============================================================================
' 8  AUDIT A ADMINISTRÁCIA
'===============================================================================
Private Sub SeedAdmin()
    Call NovaKarta("ADMIN", 8, "Admin", "Audit a administrácia", _
        "Anonymizácia, čistenie pomocných tabuliek, zámok importu, nastavenie okna konzoly a info okien.", False)
    Riadok "UCEL", "Čo karta robí", "Údržbové nástroje pre správcu. Bežný používateľ ich nepotrebuje. Zmeny v editore dochádzky sa zapisujú do tabuľky DochadzkaAudit a udalosti systému do tabuľky LogImportu."
    Riadok "MOZNOST", "Anonymizácia", "Tlačidlo ANONYMIZOVAŤ ACCESS TABUĽKY nahradí mená, priezviská, tituly a kontakty anonymnými hodnotami (GDPR, testovanie), logika výpočtu ostane. Zmena je nevratná."
    Riadok "MOZNOST", "Vymazať pomocné tabuľky", "Vymaže vygenerované denné a mesačné sumáre a intervaly (DochadzkaIntervaly, DochadzkaDni, DochadzkaMesiacSumar). Surové razenia ostanú a údaje vzniknú znova pri prepočte."
    Riadok "MOZNOST", "Zámok importu", "Tlačidlo PREPNÚŤ ZÁMOK IMPORTU zapne alebo vypne uzamknutie dávkového importu. Chráni pred omylom po dokončení importu."
    Riadok "MOZNOST", "Skrývanie menu pri štarte", "Prepínač určuje, či sa pri spustení skryje pás kariet a ľavý navigačný panel s objektmi databázy. Pás kariet zobrazíte tlačidlom Menu v hlavičke konzoly (Alt+M), panel s objektmi tlačidlom Objekty (Alt+O). Zmena sa prejaví pri ďalšom spustení."
    Riadok "MOZNOST", "Karta Active Directory", "Tlačidlo Karta Active Directory: prepína voľby automaticky (karta je vidieť len v doméne), vždy a nikdy. Zmena sa prejaví po tlačidle Znovu vytvoriť konzolu alebo pri ďalšom štarte; karta AD je vždy posledná, číslo 9."
    Riadok "MOZNOST", "Info okná", "Znovu zapnúť info okná zruší voľby Nezobrazovať. Obnoviť predvolené texty vráti texty okien; riadky, ktoré ste upravili v tabuľke PomocnikTexty (Upravene = Áno), ostanú."
    Riadok "MOZNOST", "Znovu vytvoriť konzolu", "Zahodí uloženú podobu okna konzoly a vygeneruje ju nanovo. Použite, ak sa niektoré okno zobrazuje chybne."
    Riadok "MOZNOST", "Vývojárske nástroje", "Vývojársky a testovací režim sú určené na ladenie. Počas nich ostanú pás kariet a panel objektov Accessu pri štarte viditeľné."
    Riadok "POZOR", "Kópia databázy", "Pred anonymizáciou a čistením tabuliek si uložte kópiu súboru databázy."
End Sub
