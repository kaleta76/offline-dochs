DOCHADZKOVY SYSTEM - INSTALATOR (Microsoft Access + VBA)
=========================================================
Balik: pozri manifest.json (pole "balik"). Moduly maju vlastne verzie ('@Verzia na 2. riadku kazdeho modulu).

POZIADAVKY
  - Windows + plna verzia Microsoft Access 2010 alebo novsia (Access Runtime nestaci - nema editor VBA).
  - Slovensky region / "Jazyk pre programy bez Unicode" = slovencina (kodova stranka 1250), inak sa diakritika
    v texte rozhrania moze poskodit. Instalator to skontroluje a upozorni.
  - Pred spustenim zatvorte vsetky okna Accessu.

SPUSTENIE
  1) Rozbalte cely ZIP do priecinka (nie priamo z ZIP-u).
     Ak Windows hlasi "neznamy zdroj": pravy klik na ZIP > Vlastnosti > Odblokovat (Unblock) a rozbalte znova.
  2) Do toho isteho priecinka skopirujte doterajsiu databazu dochadzky (starsiu verziu alebo databazu z predchadzajuceho instalatora).
  3) Dvojklik na  Instaluj.cmd. Instalator sam najde databazy v priecinku a ponukne predvoleny postup - staci potvrdit Enterom:
       - nova databaza sa vola  dochadzka-<verzia balika>.accdb  (napr. dochadzka-2.9.0.accdb) a vznikne v tom istom priecinku,
       - najnovsia databaza z instalatora  -> jej KOPIA sa aktualizuje (prenesie sa vsetko vratane vypoctov, original ostane),
       - starsia databaza bez verzionovania -> nova databaza + IMPORT dat (zdroj sa iba cita),
       - databaza s nazvom aktualnej verzie uz existuje -> AKTUALIZACIA modulov na mieste (so zalohou),
       - ziadna databaza -> nova prazdna.
     Ak odpoviete "n" na otazku "Pouzit predvoleny postup?", mozete zmenit postup (N/I/K/A), zdrojovu databazu (cislo zo zoznamu)
     a nazov novej databazy.
  4) Po dokonceni sa databaza otvori sama a makro AutoExec vytvori hlavnu konzolu.

  Bez otazok:   Instaluj.cmd -Tiho                     (pouzije predvoleny postup)
                Instaluj.cmd -Tiho -Cesta "C:\Dochadzka\Dochadzka.accdb" -ZdrojovaDatabaza "C:\stare\dochadzka-1.2.2.accdb"
  Parametre:    -Cesta, -ZdrojovaDatabaza, -Tiho, -BezKompilacie, -BezDoveryhodnejLokality, -NeOtvarat, -VsetkyModuly, -IbaOtestuj
  Iba kontrola prostredia a balika (nic nemeni):  Instaluj.cmd -IbaOtestuj

CO INSTALATOR ROBI
  1. Overi, ze je dostupny Microsoft Access (inak to oznami a skonci s kodom 2).
  2. Overi integritu balika (SHA-256 kazdeho modulu podla manifest.json).
  3. Nova databaza: vytvori .accdb. Existujuca: urobi zalohu (*.zaloha_<cas>.accdb) a aktualizuje iba zmenene moduly.
  4. Dočasne zapne v Accesse "Doverit pristupu k objektovemu modelu projektu VBA" (po skonceni vrati povodnu hodnotu)
     a (ak suhlasite) prida priecinok databazy medzi doveryhodne umiestnenia (inak Access blokuje VBA a makra).
  5. Importuje moduly do VBA projektu (povodne verzie nahradenych modulov ulozi do zaloha_moduly_<cas>\).
     Zastarane moduly z manifestu ("zrusene") odstrani.
  6. SKOMPILUJE projekt - pri chybe sa zobrazi okno Accessu s chybnym riadkom, instalacia sa zastavi (Access ostane otvoreny).
  7. Zavola InstalacnaInicializacia: vytvori tabulky, doplni stlpce noveho datoveho modelu, voliteľne importuje starsiu DB,
     doplni predvolenu konfiguraciu prerusen a sviatkov (jednorazovo).
  8. Zapise nainstalovane verzie modulov do tabulky VerzieModulov.
  9. Vytvori makro AutoExec (RunCode AutoExecStart()). Ulozi a otvori databazu.
  Protokol: instalacia_<cas>.log v priecinku databazy.

VERZIOVANIE MODULOV
  - Kazdy modul: 2. riadok  '@Verzia X.Y.Z   (X = velka zmena, Y = nova funkcia, Z = oprava).
  - Pri KAZDEJ zmene obsahu modulu sa verzia zvysuje. Kontrolu robi  python tools/zostav_balik.py
    (zmena obsahu bez vyssej verzie = chyba). Prikaz  python tools/zostav_balik.py --bump mod_xx  zvysi patch verziu.
  - Instalator pri aktualizacii porovna verzie/hash s tabulkou VerzieModulov a nahra iba zmenene moduly.
  - Zoznam verzii v Accesse (okno Immediate, Ctrl+G):   ?mod_13_Instalacia.ZoznamVerziiModulov

IMPORT ZO STARSEJ VERZIE DATOVEHO MODELU
  - Pri instalacii: parameter -ZdrojovaDatabaza (alebo odpoved v sprievodcovi).
  - Neskor v aplikacii: karta "1. Import Dat" > tlacidlo "5. Importovat data zo starsej verzie databazy".
  - Zdroj sa iba cita. Stlpce sa parují podla nazvu (nove ostanu prazdne, zrusene sa ignoruju). Riadky sa iba DOPLNAJU
    (existujuce sa nemenia a nemazu). Cele kopirovanie bezi v jednej transakcii - pri chybe sa vrati spat.
  - Prenasa sa: NastaveniaSystemu, Zamestnanci, DochadzkaImport (razenia), TypyUdalosti, CiselnikPreruseni, KodyRazeni,
    CiselnikPravidielAnomalii, Sviatky, Kalendare, KalendarDni, PracovneFondy(+Dni), ParametrePreruseni, Sablony*, ZamestnanciFondy.
  - Neprenasa sa (prepocita sa): DochadzkaDni, DochadzkaIntervaly, DochadzkaMesiacSumar, anomalie; logy a prihlasenia.

RIESENIE PROBLEMOV
  - "Nie je mozne pracovat s VBA projektom": Access > Subor > Moznosti > Centrum zabezpecenia > Nastavenia Centra zabezpecenia >
    Nastavenia makier > zaskrtnut "Doverit pristupu k objektovemu modelu projektu VBA"; spustit instalator znova.
  - Po otvoreni sa nic nestane / zlta lista "Zablokovany obsah": priecinok nie je doveryhodny - Povolit obsah, alebo
    spustit instalator bez -BezDoveryhodnejLokality.
  - Chyba kompilacie: poznacte si nazov modulu, cislo riadku a text chyby a poslite ich (Access ostane otvoreny na chybnom riadku).
  - Makro AutoExec sa nevytvorilo: Vytvorit > Makro > akcia SpustitKod (RunCode) > funkcia  AutoExecStart()  > ulozit ako AutoExec.
  - Moduly mimo balika (stare verzie) mozu sposobit "Ambiguous name detected" - odstrante ich v editore VBA (Alt+F11).

OVERENIE (stav tohto balika)
  Instalator bol overeny syntakticky a simulaciou (mock COM) v PowerShell 7 na Linuxe: priebeh nova DB / aktualizacia /
  chyba kompilacie / chyba AutoExec / chybajuci Access. NEBOL spusteny so skutocnym Microsoft Access - prvy beh urobte na kopii.

KONZOLA, MENU A INFO OKNA (od baliku 2.7.0, upravene v 2.8.0)
  - Hlavicka konzoly je pevna (nescrolluje sa): tlacidla kariet 1-9 (Alt+1 az Alt+9), Pomocnik (Alt+P), Objekty (Alt+O), Menu (Alt+M).
    Karty: 1 Import, 2 Zamestnanci, 3 Kontrola, 4 Editor, 5 Preruseni, 6 Vypocet, 7 Exporty, 8 Admin, 9 Active Directory.
    Karta 9 (AD) sa zobrazi len ak pocitac vidi domenu (alebo ak ju zapnete: karta 8 > "Karta Active Directory": automaticky / vzdy / nikdy);
    cisla ostatnych kariet sa tym nemenia.
    Karta, ktora sa nevojde, ma zvisly a vodorovny posuvnik.
  - Pas kariet (ribbon) a lavy navigacny panel s objektmi databazy su pri starte SKRYTE. Tlacidlo Menu (Alt+M) zobrazi / skryje
    iba pas kariet, tlacidlo Objekty (Alt+O) iba lavy panel s objektmi.
    Zrusit skryvanie pri starte: karta 8 "Audit & Admin" > "Skryvanie menu pri starte". Vyvojarsky rezim (DevMode) menu neskryva.
    Pri zobrazeni zostavy sa pas kariet zobrazi sam (je v nom Tlac a Zavriet nahlad).
  - Info okno (Pomocnik) ku kazdej karte: opis postupu a moznosti. Samo sa ukaze, ak cinnost na karte este nebola vykonana
    (napr. prazdna databaza na karte Import) a nie je zaskrtnute "Nezobrazovat"; po vykonani cinnosti sa uz neukazuje.
    Vyvolate ho tlacidlom Pomocnik alebo Alt+P. Texty su v tabulkach PomocnikKarty a PomocnikTexty (riadok s Upravene = Ano
    sa pri aktualizacii neprepise), stav v tabulke PomocnikStav. Znovu zapnut okna: karta 8 > "Znovu zapnut info okna".
  - Ak by sa konzola alebo okno zobrazovalo chybne: karta 8 > "Znovu vytvorit konzolu".

ZAMESTNANCI, PRACOVNE FONDY A PRAVIDLA PRERUSENI (od baliku 2.8.0)
  Karta 2 "Zamestnanci" (zoznam pre zvoleny mesiac, hladanie, "aj vyradeni"):
  - Karta zamestnanca (dvojklik): osobne cislo, cislo karty, titul, meno, organizacia, stredisko, text na displeji, UVAZOK (%),
    blokovana karta, VYRADENY (od datumu), poznamka a pod tym fond / sablona prerusenia / kalendar platne od zvoleneho mesiaca.
  - Uvazok: 50 = polovicny; denny fond zamestnanca sa skrati v tomto pomere. Prazdne = 100 %.
  - Vyradeny zamestnanec ostane v databaze (razenia sa zachovaju), ale od mesiaca vyradenia sa nezobrazuje vo vypoctoch,
    zostavach a v analyze. Tlacidlo "Vratit do evidencie" ho zaradi spat.
  - Priradenie viacerym oznacenym naraz (Ctrl / Shift) vratane vytvorenia SKUPINY: z oznacenych sa vytvori vlastna kopia
    pracovneho fondu a pravidiel prerusenia, ktorych uprava sa tyka len ich.
  - Zmeny platia od zvoleneho mesiaca (starsie mesiace ostanu podla predosleho nastavenia; verzie sa ukladaju po mesiacoch).
  Editor pracovnych fondov (tlacidlo "Pracovne fondy..." na karte 2 a 5):
  - Typ fondu (1 pevna, 2 pruzna, 3 volna podla dennej dlzky, 4 volna s pevnym mesacnym fondom), denny a mesacny fond.
  - Rovnaky fond pre vsetky dni, alebo dlzka podla dna v tyzdni (prichod od, odchod do, fond, prestavka pre pondelok az nedelu).
  - "Novy fond..." vytvori kopiu zobrazeneho fondu alebo novy fond z predvolby (v okne sa vyberie Ano / Nie).
  - Od 2.9.0: zoznam "Zamestnanec" (skok na fond platny pre vybraneho zamestnanca v zvolenom mesiaci; z karty 2 sa editor otvori
    rovno na fonde oznaceneho zamestnanca), zoznam "Verzie" (historia: od ktorych mesiacov nastavenie plati), tlacidlo
    "Kto pouziva" (zamestnanci s tymto fondom v mesiaci a inokedy) a zoznam "Predvolba" + tlacidlo "Pouzit" (vyplni bezne
    hodnoty: pevna 7:30 / 8:00, pruzna, volna, volna s mesacnym fondom 165:00, dvanastohodinova zmena). Predvolba sa ulozi az
    tlacidlom "Ulozit od zvoleneho mesiaca". Ak by ulozenie zasiahlo uzavrety mesiac, okno to ukaze cervene a ulozenie sa zablokuje.
  Editor pravidiel prerusenia (tlacidlo "Pravidla prerusenii..."):
  - Povolene casove okno prerusenia (napr. obed 11:00 - 13:30), najdlhsie a najkratsie trvanie, "odpracovat pred zaciatkom"
    (napr. obed najskor po 180 minutach prace). Rovnake pre vsetky dni, alebo osobitne pre kazdy den v tyzdni.
  - Porusenie pravidla NEMENI vypocet: na karte 3 Kontrola (zoznam "Na rucne posudenie") pribudne upozornenie so znackou (!),
    zavaznost VAROVANIE (napr. "Obed 10:40-11:15 mimo povoleneho casu 11:00-13:30"). Pravidlo mozno vypnut; celu kontrolu
    vypnete nastavenim KontrolaPravidielPreruseni = 0 v NastaveniaSystemu.
  - "Nova sablona..." vytvori kopiu zobrazenej sablony prerusenia. Sablona sa priraduje zamestnancom na karte 2.
  - Od 2.9.0 rovnako ako pri fondoch: skok na zamestnanca (zobrazi sa jeho sablona), historia verzii, "Kto pouziva" a predvolby
    pravidla (bez kontroly, obed 11:30-13:30 / 11:00-14:00 po 3 hodinach prace, kratke prerusenie do 20 min, lekar / sukromne).
  - Platnost "od mesiaca": nastavenie sa NEKOPIRUJE mesiac po mesiaci (ako sablony v Ordata). Plati od zvoleneho mesiaca az do
    dalsej verzie; pre kazdy mesiac sa pouzije najnovsia verzia s mesiacom <= tento mesiac (ak taka nie je, najstarsia). Zmena od
    januara teda nemeni vypocet za december. Ulozenie od mesiaca M aktualizuje verziu v M a vsetky novsie verzie.
  Datovy model: fond a sablona su priradene KAZDEMU zamestnancovi (tabulka ZamestnanciFondy: osobne cislo, fond, sablona
  prerusenia, kalendar, zmeny, platnost od mesiaca). Nove stlpce: Zamestnanci.Vyradeny, VyradenyOd, UvazokPercent, TextDisplej,
  Poznamka; PracovneFondy.FondPodlaDna; ParametrePreruseni.MinOdpracovaneMin, MinTrvanieMin, PravidloVypnute.
  Doplnia sa automaticky pri instalacii / prvom spusteni (existujuce udaje sa nemenia).
  Poznamka: zamestnanec z vzorovej databazy 4002012 odkazuje na fond 8 a sablonu 2, ktore v databaze nie su; ziadny fond sa
  nedohada - treba ho priradit na karte 2 (alebo doplnit chybajuci fond v editore).

UZAVIERKA MESIACA A OCHRANA PARAMETROV (od baliku 2.9.0)
  Ucel: ked je zostava zamestnanca za mesiac vytlacena a podpisana, jej udaje sa uz nesmu zmenit (fond, pravidla, uvazok,
  razenia, upravy dna, prepocet). Postup na karte 6 "Vypocet a zostavy" > tlacidlo "Uzavierka mesiaca...":
  1) Prepocitajte mesiac a zobrazte tlacovu zostavu (pata: "NAVRH - mesiac nie je uzavrety | kontrolny kod ...").
  2) Vytlacte ju a nechajte podpisat. Podpisany papier ma kontrolny kod, ktory sa zhoduje s udajmi mesiaca.
  3) V okne Uzavierka mesiaca oznacte zamestnancov, zadajte kto zostavu potvrdil (podpisal) a stlacte "Uzavriet". Mesiac sa da
     uzavriet od posledneho dna mesiaca a len ak od vytvorenia zostavy neboli zmenene udaje (kontrolny kod sa musi zhodovat);
     inak treba zostavu zobrazit, vytlacit a podpisat znova. Odporuca sa uzatvarat mesiace po poradi (system poradie nevynucuje).
  4) Uzavrety mesiac nema povoleny prepocet, upravy v editore dna, prepis importom z Ordata ani zmenu fondu / pravidiel / uvazku /
     kalendara / vyradenia, ktora by ho zmenila (starsie nastavenia sa nemenia, lebo verzie su podla mesiacov). Pri uvazku a priradeni
     sa na starsie mesiace zalozi zakladna verzia, aby sa uzavrete mesiace nezmenili.
  5) "Otvorit..." vyzaduje dovod (aspon 5 znakov); zapisuje sa do tabulky DochadzkaUzavierkaLog (kto, kedy, dovod, kod).
     Po otvoreni treba zostavu znova vytlacit a podpisat. "Overit" porovna ulozene hodnoty s kontrolnym kodom.
  6) Razenia z terminalu do uzavreteho mesiaca ostanu v TerminalInbox so stavom UZAVRETY a spracuju sa po otvoreni mesiaca.
  7) Hromadny prepocet mesiaca uzavrete mesiace preskoci.
  Obmedzenia (poctivo): ide o ochranu na urovni aplikacie. Ten, kto ma pristup k suboru databazy (alebo ju otvori v Accesse bez
  konzoly), moze tabulky upravit; kontrolny kod to odhali pri tlaci zostavy a pri "Overit" (zostava sa vytlaci s upozornenim),
  ale zmene nezabrani. Na silnejsiu ochranu pouzite aj pravo zapisu do suboru, zalohy a archiv podpisanych zostav (PDF).
  NEBOLO overene v skutocnom Accesse: rozlozenie okna Uzavierka mesiaca, zoznam s polami z funkcii VBA, paticka zostavy
  a dotazy volajuce funkcie VBA (kontrola len kodom a simulaciou instalatora). Pri chybe poslite modul, riadok a text z okna.
