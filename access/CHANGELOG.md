# Dochádzka – zmeny

## Balík 2.18.0
Strana HR klienta na razenie v Accesse: zamestnanci razia z Accessu na svojom pracovnom počítači, razenia prídu ako malé súbory do zdieľaného priečinka a HR ich prevezme jedným tlačidlom. Terminál (Lovable) pri tom nie je potrebný. Balík obsahuje aj všetko z 2.17.0. **Samotný klient (okno s tlačidlami na počítači zamestnanca) ešte nie je**, v tomto balíku je len príjem.
- **Súvislosť**: v práci sa smie používať len Access a Excel (odpoveď SOC z 12. 11. 2026), preto razenie nejde cez webový terminál. Návrh, protokol, práva na priečinky a hranice riešenia sú v `docs/KLIENT-ACCESS.md`.
- **Nový modul `mod_22_KlientRazenia` 1.0.0**: číta súbory `.rzn` z `<KlientPriecinok>\prijem`, skontroluje ich a vloží razenia do fronty `TerminalInbox` (id `KL-<id>`), odkiaľ ich spracuje `SpracujInbox` ako razenia z terminála. Prijaté súbory sa presunú do `spracovane\RRRR-MM`, odmietnuté do `chybne` s dôvodom v súbore `.dovod.txt` (po oprave ich možno vrátiť do `prijem`).
  - **Kontroly**: tvar súboru (rovnaké pravidlá ako `tools/klient_protokol.py`), účet (`login` v súbore patrí zamestnancovi s osobným číslom `oc` podľa `Zamestnanci.LoginAD`; `KlientKontrolaUctu` PRISNE/UPOZORNIT/VYPNUTE, predvolene PRISNE), vlastník súboru v sieti je ten istý účet (`KlientKontrolaVlastnika`, predvolene UPOZORNIT), čas razenia voči času vytvorenia súboru na serveri (`KlientMaxOdchylkaMin` 10, `KlientMaxOdlozenieDni` 3) a razenie v budúcnosti sa odmietne. Razenie, ktoré neprejde „mäkkou“ kontrolou, sa vloží ako **neoverené** (`TerminalInbox.Overenie = unverified`), počíta sa ako ostatné a je uvedené v reporte a v tabuľke `KlientRazenia`.
  - **Razenia dnešného dňa čakajú** na ďalší deň (párovanie príchodu, obeda a odchodu potrebuje celý deň; `KlientAjDnesne` = 1 to zmení). Nedopísaný súbor (chýba `#END`) počká 5 minút. Razenie doručené po prevzatí razení toho dňa sa vloží ako neoverené („skontrolujte poradie“).
  - Tabuľka `KlientRazenia` (každý súbor, stav, dôvod, vlastník) sa vytvorí pri prvom behu. Opakovaný príjem toho istého `id` nevloží razenie druhýkrát.
  - `GenerujKonfiguraciuKlienta` zapíše `konfiguracia\klient_konfig.txt` (text UTF-8 bez osobných údajov): tlačidlá prerušení podľa číselníka a kódov terminála (`TerminalMapaKodov`), ako ich má terminál.
- **`mod_19_TerminalImport` 1.4.0**: nová verejná `PrevedRazeniaKlienta`, ktorá použije to isté párovanie ako terminál (príchod, obed, odchod, prerušenia), takže výpočet dňa, editor, výkazy a uzávierka sa správajú rovnako. Import súboru z terminála sa nemení.
- **Karta 7 Exporty**: tlačidlá „Klient na razenie v Accesse: nastaviť priečinok a konfiguráciu tlačidiel“ a „Prijať razenia z klientov v Accesse“ (najprv sa ponúkne beh nanečisto; report sa uloží do `klient_prijem_report.txt`). `mod_UI_Tab_Export` 2.12.0, `mod_UI_PomocnikTexty` 1.3.3. Tlačidlá pribudnú po znovuvytvorení konzoly (inštalácia ju vytvorí, alebo karta 8 Znovu vytvoriť konzolu).
- **Nástroje**: `tools/klient_protokol.py` (zapisovač a kontrola `.rzn`, skúšobné súbory) a `tools/test_klient_protokol.py` (25 testov, bežia v CI). `contract/` sa nemení.
- **Čo ešte nie je**: klient (okno razenia na počítači zamestnanca, lokálny záznam, odloženie pri výpadku siete, inštalátor), prehľad vlastného mesiaca, označenie neoverených razení priamo v editore dňa (zatiaľ len report a tabuľka `KlientRazenia`; `ZdrojZapisu` je ako pri termináli `TERMINAL`), externý snímač a karty (neskôr, samostatne).
- **Obmedzenia**: párovanie obeda a odchodu vidí len razenia z jedného behu príjmu; razenie, ktoré dorazí po prevzatí dňa, sa nepáruje nanovo (označí sa neoverené). Zistenie vlastníka súboru používa stĺpec „Vlastník“ v Prieskumníkovi (Shell.Application) a v prostredí s obmedzeniami nemusí fungovať; vtedy sa razenia označia neoverené, alebo sa kontrola vypne.
- **Neoverené v skutočnom Accesse**: kód prešiel `tools/kontrola_vba.py` (0 nálezov), ale nespúšťal sa. Skúška na kópii databázy (miestny priečinok stačí, napr. `C:\dochadzka-test`):
  1. V okne priamych príkazov doplňte testovacieho zamestnanca: `CurrentDb.Execute "INSERT INTO Zamestnanci (OsobneCislo, LoginAD, Meno, Priezvisko) VALUES ('9000001','test.zam1','Test','Klient')"` (ak tabuľka vyžaduje ďalšie polia, doplňte ich).
  2. Karta 7, „Klient na razenie v Accesse: nastaviť priečinok…“, zadajte `C:\dochadzka-test`. Vzniknú `prijem`, `konfiguracia`, `spracovane`, `chybne` a `konfiguracia\klient_konfig.txt`; riadky `tlacidlo=` zodpovedajú tlačidlám prerušení z karty 5 a majú kód z `TerminalMapaKodov`.
  3. Skúšobné súbory (kdekoľvek, kde je Python): `python3 -I tools/klient_protokol.py vzor C:\dochadzka-test\prijem --den 2026-11-10 --zle`. Do `prijem` príde 6 súborov (príchod, obed, návrat, lekár, návrat, odchod) a do `prijem\zle` 8 neplatných.
  4. Súbory ste skopírovali vy, preto v tabuľke `NastaveniaSystemu` nastavte `KlientKontrolaVlastnika` = `VYPNUTE` a `KlientMaxOdchylkaMin` = `0`. „Prijať razenia z klientov“, **Nie (nanečisto)**: report hlási 6 prijatých a prehľad `7:31 WORK/IN -> č. 1 Z`, `11:30 WORK/OUT -> č. 7 Z`, `12:02 WORK/IN -> č. 7 K`, `13:15 DOCTOR/OUT -> č. 2 Z`, `13:58 DOCTOR/IN -> č. 2 K`, `15:36 WORK/OUT -> č. 1 K`. Nič sa nezapíše a súbory ostanú.
  5. To isté s **Áno**: „prijatých 6 (z toho neoverených 0)“, „Prenesené razenia: 6“, súbory sú v `spracovane\2026-11`, v `DochadzkaImport` má 9000001 šesť razení v uvedenom poradí. Druhý beh hlási 0 súborov. Skopírujte tie isté súbory znova: „duplicít 6“ a súbory idú do `spracovane\duplicity`.
  6. Skopírujte súbory z `prijem\zle` do `prijem`: 7 sa odmietne hneď (hlavička, kód, smer, dva časy, dvojitý kľúč, názov súboru) a leží v `chybne` s `.dovod.txt`; súbor `zle_bez_konca_*` sa po 5 minútach odmietne pre chýbajúci `#END`.
  7. Účet: zmeňte `LoginAD` testovacieho zamestnanca na `iny`, vráťte súbory z `spracovane\2026-11` do `prijem` (a vymažte riadky `TerminalInbox` s `ExterneID` začínajúcim `KL-`): pri PRISNE sa odmietnu „účet iny patrí inému osobnému číslu“, pri `KlientKontrolaUctu` = `UPOZORNIT` sa vložia ako neoverené a report ich vypíše.
  8. Dnešné razenia: súbory s `--den` dnešným dňom čakajú („čakajú na ďalší deň 6“); s `KlientAjDnesne` = `1` sa prevezmú.
  9. Vlastník: `?mod_22_KlientRazenia.UkazVlastnika("C:\dochadzka-test\spracovane\2026-11\<súbor>")` ukáže, ako Windows hlási vlastníka (napríklad `DOMENA\meno`); s `KlientKontrolaVlastnika` = `UPOZORNIT` majú súbory, ktoré vytvoril iný účet než `login`, príznak neoverené.
  10. Upratanie: `?mod_19_TerminalImport.OdstranTestoveData()`, riadky `TerminalInbox` s `KL-%` a tabuľku `KlientRazenia` vymažte ručne.

## Balík 2.17.0
Režim výpočtu sa uplatní vo výpočte dňa a v exporte podľa kontraktu 1.5.0. Bez nastavených režimov a vlastností prerušení sa výpočet ani export nemenia. Balík obsahuje aj všetko z 2.16.0.
- **Ako to funguje**: pred výpočtom každého dňa zamestnanca sa nastaví režim, ktorý mu v ten deň platí (`ZamestnanciRezimy`). Mimo obdobia platia základné nastavenia; v období sa vymenia hodnoty, ktoré režim prepisuje, ostatné ostanú základné. Výpočet dňa (`SpracujDen`, `SumarDna`, zaokrúhlenie) ostáva ten istý, mení sa len sada hodnôt, s ktorou beží.
  - Režim prepisuje: okno práce, hranicu celodennej prekážky, automatický obed (zapnutie, prah, odpočet), razený obed (režim, minúty), zaokrúhlenie (príchod, odchod, smer) a automatické opravy (režim, cieľ, prípady). Úprava prerušenia v režime: výpočet `COUNTED` / `UNPAID`, hranica celého dňa, pripočítanie k základu obeda.
  - **Hranica celého dňa prerušenia** (`PrahCelyDenMin`, kontrakt `full_day_min`): ak je nastavená, použije sa namiesto spoločnej hranice z nastavení. Rovnakú hranicu používa aj kontrola pravidiel prerušení (`mod_16`).
  - **Do základu obeda** (`DoZakladuObeda`, kontrakt `counts_to_lunch_base`): započítaný čas prerušenia sa pripočíta k odpracovanému času pri porovnaní s prahom „Obed od“ (automatický aj razený obed). Odpočet obeda sa stále berie z odpracovaného času, nie z prerušenia.
  - **Neplatný režim sa neuplatní**: ak režim nie je použiteľný (`ChybaRezimu`), deň sa počíta so základnými nastaveniami a do protokolu sa zapíše upozornenie. Export takýto režim preskočí a vypíše to v správe.
- **Moduly**: `mod_08_UdalostiDna` 1.5.1 (`NastavRezimVypoctu`, `RezimPrepisuje`, `PrmPrahPrerusenia`, `JeDoZakladuObeda`, sady parametrov vo vyrovnávacej pamäti), `modMesaatnaDochadzka` 2.9.0 a `mod_09_AutoOprava` 1.4.0 (režim sa nastaví pred každým dňom, na konci cyklu aj pri chybe sa vráti na základné nastavenia), `mod_16_PravidlaPreruseni` 1.1.1, `mod_20_KonfiguraciaExport` 1.3.0, `mod_21_RezimyVypoctu` 1.1.0 (`RezimyMesiaca`).
- **Export (kontrakt 1.5.0)**: `interruptions[]` dostane `full_day_min` a `counts_to_lunch_base` (len keď sú nastavené a len pre započítavané prerušenia); pribudnú `regimes[]` (len použiteľné režimy) a `employees[].months[].regime_ids` (číslo režimu pre každý deň mesiaca, kľúč sa vynechá, keď v mesiaci žiaden režim nie je). Bez režimov je súbor rovnaký ako v 2.16.0. Pred prvým súborom s týmito kľúčmi musí byť rozšírená súkromná databázová časť terminála; inak ho terminál odmietne.
- **Čo ešte nie je**: okno na nastavenie režimov a vlastností prerušení (zatiaľ len funkcie v okne priamych príkazov, ďalej), príručka pre správcov, zápis režimu do dňa (`DochadzkaDni`) a na zostavu, rozšírenie snímky uzávierky o režimy. Terminál režim zatiaľ vo výpočte neuplatňuje (etapa 2).
- **Obmedzenia**: pravidlo `unlabeled_out_is_lunch` (odchod bez dôvodu) v režime sa exportuje, ale pri importe z terminála ho Access zatiaľ neuplatňuje, tam platí základné nastavenie „Odchod bez dôvodu“. `auto_repair_mode` v režime je 0 až 2 (kontrakt pripúšťa 0 až 9, Access pozná len tieto). Režim použitý v uzavretom mesiaci nemožno meniť.
- **Neoverené v skutočnom Accesse**: kód prešiel `tools/kontrola_vba.py` (0 nálezov), ale nespúšťal sa. Skúška na kópii databázy, pracovný deň s fondom 8:00, obed 30 min od 6:00, okno práce 6:00 až 17:00:
  1. Bez režimov: prepočet mesiaca dá rovnaké súčty ako v 2.16.0 a export neobsahuje `regimes`.
  2. Režim bez automatického obeda: v okne priamych príkazov `?mod_21_RezimyVypoctu.UlozRezim(CurrentDb, 1, "Skúška")`, `?mod_21_RezimyVypoctu.UlozPravidloRezimu(CurrentDb, 1, "auto_lunch_enabled", 0)`, `?mod_21_RezimyVypoctu.UlozObdobie(CurrentDb, "<osobné číslo>", 1, #11/2/2026#, #11/6/2026#)` (každé vráti prázdny text). Deň 7:00 až 15:00 bez obeda dá v období 8:00, mimo neho 7:30; po zmazaní obdobia (`OdstranObdobie`) sa vráti 7:30.
  3. Základ obeda: v číselníku nastaviť prerušeniu `DoZakladuObeda` (`?mod_21_RezimyVypoctu.UlozVlastnostiPreruseni(CurrentDb, <č.>, Null, True)`). Deň práca 7:00 až 10:00 a prerušenie 10:00 až 14:00 dá 7:00 (práca 3:00 + prerušenie 4:00) bez príznaku; s príznakom základ 7:00 dosiahne prah, odpočíta sa 30 min z práce a výsledok je 6:30.
  4. Hranica celého dňa: prerušenie s intervalom 400 min dá bez vlastnej hranice celý denný fond (nad 360 min); s `PrahCelyDenMin` 480 sa počíta 400 min.
  5. Export zo záložky Export: súbor s režimom prejde `python3 contract/tools/verify_config.py <súbor> --strict` a `regime_ids` majú v období číslo režimu, inde 0.

## Balík 2.16.0
Dátová vrstva režimov výpočtu (kontrakt 1.5.0). **Výpočet sa nemení**: nové tabuľky sú prázdne a nové vlastnosti prerušení prázdne, kým ich správca nenastaví, a nič ich zatiaľ nečíta. Balík obsahuje aj všetko z 2.15.1.
- **Princíp**: či a ako sa prerušenie počíta, určujú parametre v Accesse, ktoré nastavuje správca (HR); my dodávame len počiatočné hodnoty podľa organizácie. Krízová situácia sa rieši režimom výpočtu priradeným zamestnancovi na obdobie, nie pevným pravidlom.
- **Nový modul `mod_21_RezimyVypoctu` 1.0.0**: tabuľky `RezimyVypoctu` (najviac 20 režimov, čísla 1 až 99), `RezimyPravidla` (prepísané pravidlá), `RezimyPreruseni` (úpravy prerušení) a `ZamestnanciRezimy` (obdobia od – do vrátane oboch dní). Vytvoria sa pri otvorení databázy (`mod_01_SystemInit` 2.9.2), existujúce údaje sa nedotknú.
  - Zoznam pravidiel, ktoré režim smie prepísať, je zatvorený a rovnaký ako v kontrakte 1.5.0 (okno práce, hranica celodennej prekážky, obed a jeho prah, razený obed, odchod bez dôvodu, zaokrúhlenie, automatické opravy). Každá hodnota sa pri uložení overí v rovnakých medziach ako v termináli; nepovolené pravidlo sa neuloží.
  - Úprava prerušenia v režime: výpočet (`COUNTED` alebo `UNPAID`), hranica celého dňa a pripočítanie k základu obeda. Prácu (č. 1) a obed (č. 7) režim nemení. Hranica a pripočítanie patria len prerušeniu, ktorého čas sa započítava.
  - Obdobia jedného zamestnanca sa nesmú prekrývať; zamestnanec aj režim musia existovať a režim musí byť použiteľný (`ChybaRezimu`). Režim priradený zamestnancovi sa nedá zmazať.
  - **Uzavretý mesiac sa nemení**: obdobie ani parametre režimu, ktoré by zasiahli uzavretý mesiac zamestnanca, sa neuložia (rovnaká zásada ako pri pracovnom fonde a pravidlách prerušení). Režim použitý v uzavretom mesiaci preto nemožno meniť; založí sa nový, alebo sa mesiac najprv otvorí.
- **`mod_10_Konfiguracia` 1.4.2**: dva nové stĺpce číselníka prerušení: `PrahCelyDenMin` (od akej dĺžky jedného intervalu sa započíta celý denný fond; prázdne = spoločná hranica z nastavení) a `DoZakladuObeda` (čas prerušenia sa pripočíta k základu pre prah obeda). Prerušenie č. 1, č. 7 a prerušenie, ktorého interval sa nezapočíta, ich mať nemôže (`UlozVlastnostiPreruseni`).
- **Čo ešte nie je**: režim sa vo výpočte dňa neuplatní a export podľa kontraktu 1.5.0 ho neobsahuje (ďalšia dávka); okno na nastavenie režimov a príručka pre správcov tiež ešte nie sú, hodnoty sa zatiaľ zapisujú len cez funkcie modulu. Rozšírenie snímky uzávierky o režimy príde s oknom.
- **Neoverené v skutočnom Accesse**: kód prešiel `tools/kontrola_vba.py` (0 nálezov), ale nespúšťal sa. Vyskúšajte na kópii: (1) po otvorení databázy existujú tabuľky `RezimyVypoctu`, `RezimyPravidla`, `RezimyPreruseni`, `ZamestnanciRezimy` a v `CiselnikPreruseni` stĺpce `PrahCelyDenMin` a `DoZakladuObeda`; (2) prepočet mesiaca dá rovnaké súčty ako v 2.15.1; (3) v okne priamych príkazov `?mod_21_RezimyVypoctu.UlozRezim(CurrentDb, 1, "Krízový režim")` vráti prázdny text a druhé volanie s iným číslom a rovnakým názvom vráti chybu; (4) `?mod_21_RezimyVypoctu.UlozPravidloRezimu(CurrentDb, 1, "rounding_mode", 9)` vráti chybu rozsahu.

## Balík 2.15.1
Prah obeda sa počíta od uvedenej hodnoty vrátane a razený obed (najmenej alebo vždy presne) sa uplatní len v dňoch, ktoré prah dosiahnu. Balík obsahuje aj všetko z 2.15.0 (ten sa nenasadzoval).
- **Prah „Obed od“ vrátane**: predvolená hodnota 360 min znamená, že automatický obed sa odpočíta už pri 6:00 odpracovaných; pri 5:59 ešte nie. Doteraz sa odpočítal až nad 6:00 (presne 6:00 sa neodpočítalo nič). Rovnaké porovnanie používa odhad zabudnutého odchodu v automatickej oprave.
- **Razený obed len nad prahom**: režim 1 (najmenej zadané minúty) a 2 (vždy presne) sa uplatnia, len ak odpracovaný čas spolu s razeným obedom dosiahne „Obed od“. Kratšia zmena nárok na prestávku nemá, obed v nej sa počíta skutočným časom. Predvolený režim 0 sa nemení.
- **Zmeny modulov**: `mod_08_UdalostiDna` 1.4.1 (`SumarDna`), `mod_09_AutoOprava` 1.3.1, `mod_10_Konfiguracia` 1.4.1 (text prehľadu), `mod_UI_Tab_Prerusenia` 2.11.1 a `mod_UI_PomocnikTexty` 1.3.2 (popisy), `mod_01_SystemInit` 2.9.1 (popis pravidla pri novej inštalácii; už vytvorený riadok pravidla v tabuľke ostáva s pôvodným textom „viac ako 6 hodín“, výpočet sa riadi hodnotou, nie textom).
- **Kontrakt**: len text `contract/README.md` (kľúč `lunch_recorded_mode` a výklad `auto_lunch_trigger_min` „od hodnoty vrátane“). Schéma, kľúče ani zlatý súbor sa nemenia. Terminál zatiaľ prah z exportu nepoužíva (vlastné nastavenie `OBED_PO_HODINACH`), takže sa v ňom nič nezmení, kým sa nenapíše výpočet podľa plánu z Accessu.
- **Dôsledok pre dni presne 6:00**: deň s presne 360 min práce bez pípnutého obeda má teraz odpočítaných 30 min (predtým nič).
- **Neoverené v skutočnom Accesse**: kód prešiel `tools/kontrola_vba.py`, ale nespúšťal sa. Vyskúšajte na kópii (pracovný deň s fondom, obed 30 min, okno práce 6:00 až 17:00): (1) príchod 7:00, odchod 13:00 bez obeda dá 5:30 (predtým 6:00); odchod 12:59 dá 5:59; (2) razený obed s režimom 1 a 30 min: príchod 7:00, obed 12:00 až 12:20, návrat do 13:10 je spolu 6:10 (práca 5:50 a obed 0:20), výsledok je 5:40; (3) príchod 7:00, obed 10:00 až 10:20, odchod 12:00 je spolu 5:00 (práca 4:40 a obed 0:20), pod prahom, režim 1 nič nedorovná a odpracované je 4:40; (4) pri predvolenom režime 0 ostáva všetko ako v 2.15.0.

## Balík 2.15.0
Pravidlá výpočtu na karte 5 (časť 2): razený obed, odchod bez dôvodu, zaokrúhlenie a doplnenie zabudnutých razení. Predvolené hodnoty dávajú rovnaký výsledok ako doteraz.
- **Súvislosť**: kontrakt 1.4.0 má voliteľné kľúče pravidiel (`lunch_recorded_mode`, `lunch_min_min`, `unlabeled_out_is_lunch`, `rounding_in_min`, `rounding_out_min`, `rounding_mode`, `auto_repair_target`, `auto_repair_cases`). Access ich zatiaľ nepoznal, takže ich nemal čo vyexportovať. Teraz ich Access naozaj používa vo vlastnom výpočte a exportuje, ak sa líšia od predvolených.
- **Karta 5, nová sekcia 2b „Pravidlá výpočtu“** (pod parametrami výpočtu; časový profil strediska je o kúsok nižšie):
  - **Razený obed** (`ObedZaznamenanyRezim`, `ObedZaznamenanyMin`): 0 skutočný čas (ako doteraz), 1 najmenej zadané minúty (kratší obed sa dorovná odpočtom z práce), 2 vždy presne zadané minúty (dlhší obed sa nepočíta ako práca navyše, kratší sa dorovná). Platí pre dni, v ktorých je obed odrazený. Automatický obed bez razenia sa nemení (parametre „Obed“ a „Obed od“ v sekcii 2).
  - **Odchod bez dôvodu** (`TerminalOdchodBezDovodu`, ako doteraz): obed alebo odchod; teraz sa dá nastaviť aj tu.
  - **Zaokrúhlenie** (`ZaokruhleniePrichodMin`, `ZaokruhlenieOdchodMin`, `ZaokruhlenieSmer`): prvý razený príchod a posledný razený odchod dňa na násobok zadaných minút od polnoci (0 = bez). Smer 0 príchod nahor a odchod nadol (ako dnes v termináli), 1 oba nahor, 2 oba nadol, 3 na najbližší (polovica nahor). Nezaokrúhľuje sa čas z automatickej opravy, návrat z prerušenia ani razenia upravené v editore dňa.
  - **Doplnenie opráv** (`AutoOpravaCiel`, `AutoOpravaPripady`): cieľ 0 do denného fondu (ako doteraz) alebo 1 na koniec okna práce; prípady 3 odchod aj návrat z prerušenia (ako doteraz), 1 len zabudnutý odchod, 2 len zabudnutý návrat. Opravy obeda tým nie sú dotknuté. Platí, ak je automatická oprava zapnutá (karta Automatické opravy).
  - Tlačidlá **Predvoľba: dnešný stav** (všetko ako doteraz) a **Predvoľba: odporúčané** (razený obed najmenej 30 minút, inak ako dnes) len vyplnia polia; uloží ich až **Uložiť pravidlá**. „Odporúčané“ je môj návrh, potvrďte ho s HR; po vyplnení dotazníkov sa upraví.
- **`mod_08_UdalostiDna` 1.4.0**: nové parametre v cache, `SumarDna` rešpektuje režim razeného obeda, nová `UplatniZaokruhlenie` a `ZaokruhliCas`; interval práce si pamätá, či skončil odchodom (`KonOdchod`). Pri predvolených hodnotách sa nič nezmení.
- **`modMesaatnaDochadzka` 2.8.0**: zaokrúhlenie sa uplatní hneď po spracovaní dňa, takže intervaly, zostava aj súčty dňa majú rovnaký čas. **`mod_09_AutoOprava` 1.3.0**: odhady používajú rovnaké súčty (aj zaokrúhlenie a razený obed), cieľ a prípady opráv. Opravy, ktoré vznikli podľa starého pravidla, sa po zmene pri ďalšej analýze označia ako zastarané a vzniknú nové návrhy.
- **`mod_10_Konfiguracia` 1.4.0**: `UlozPravidlaVypoctu`, `PredvolbaPravidielVypoctu`, `PravidlaVypoctuSucasne`; inicializácia doplní chýbajúce kľúče s predvolenými hodnotami. **`mod_20_KonfiguraciaExport` 1.2.0**: do `rules` pridá len kľúče, ktorých hodnota nie je predvolená (`lunch_min_min` len pri režime 1 alebo 2, `rounding_mode` len pri zapnutom zaokrúhlení); bez nastavenia je súbor rovnaký ako v 2.14.2. **`mod_UI_Tab_Prerusenia` 2.11.0** a **`mod_UI_PomocnikTexty` 1.3.1**: nová sekcia a jej nápoveda.
- **Čo Access nepoužíva**: `correction_deadline_day` a `early_return_ends_interruption` Access nevkladá (platia predvolené hodnoty kontraktu); patria do politiky terminálu.
- **Uzavreté mesiace**: nové pravidlá sa neuplatnia na mesiace, ktoré sa neprepočítajú; uzavretý mesiac sa neprepočíta. Rozšírenie snímky uzávierky o tieto pravidlá príde s ďalšou časťou.
- **Nasadenie**: súbor s novými kľúčmi `rules` terminál zatiaľ len prijme a overí, neuplatní ich. Skôr než ho prijmete v produkčnom termináli, musí byť nasadená databázová časť (krok 5, rozšírená kontrola súboru). Pri predvolených hodnotách sa v súbore nové kľúče nevyskytujú.
- **Nástroj `tools/kontrola_vba.py`**: nová kontrola 9, deklarácia na úrovni modulu (`Const`, premenná, `Type`) za prvou procedúrou je chyba (Access: „Only comments may appear after End Sub“); testy pridané.
- **Neoverené v skutočnom Accesse**: kód prešiel `tools/kontrola_vba.py` (0 nálezov), ale nespúšťal sa. Vyskúšajte na kópii: (1) predvolené hodnoty, prepočet mesiaca dáva rovnaké súčty ako v 2.14.2; (2) obed 12:00 až 12:20, deň 7:00 až 15:00: režim 1 aj 2 s 30 min dá 7:30 (450 min) namiesto 7:40; (3) zaokrúhlenie 15 min, príchod 7:03 a odchod 15:10 s predvoľbou smeru 0 počíta 7:15 až 15:00; (4) zabudnutý odchod po príchode o 7:00 pri fonde 7:30: cieľ 0 navrhne odchod 15:00, cieľ 1 17:00; (5) export konfigurácie s nastaveným razeným obedom obsahuje `lunch_recorded_mode` a `lunch_min_min` a prejde overovačom.

## Balík 2.14.2
Bezpečný import číselníka a parametrov prerušení z Ordata: nič sa neprepíše ani nezmaže bez výslovného súhlasu.
- **Súvislosť**: dávkový import z Ordata prepisoval číselník prerušení bez otázky (názov, skratku, texty aj kódy razení existujúceho čísla) a parametre prerušení zmazal a nahral nanovo.
  Názvy z Ordata sú bez diakritiky („Sluzobna cesta“), takže import by vrátil opravené názvy späť. Teraz sa najprv porovná a rozhoduje sa raz.
- **`mod_02_DBFImport` 2.7.0, číselník prerušení**: súbor sa načíta do pamäte a porovná so súčasným číselníkom. Prerušenia, ktoré v Accesse chýbajú, sa pridajú. Ak sa niektoré existujúce líši
  (názov, skratka, predvoľba, texty, kódy alebo funkcie razení), okno ukáže rozdiely (úplný zoznam je v logu) a opýta sa raz: Áno = prepísať hodnotami z Ordata, Nie (predvolené) = ponechať súčasné.
  Pri Nie sa nové prerušenie, ktorého kód razenia už patrí inému prerušeniu, nepridá (kolízia sa uvedie v zozname). Ak sa líšia kódy razení, okno na to upozorní: razenia z Ordata s inými kódmi
  sa k prerušeniu nepriradia. Bez rozdielov sa nepýta. Stĺpce tlačidla a príznakov (2.14.0) import nikdy nemení.
- **`mod_02_DBFImport` 2.7.0, parametre prerušení**: preberajú sa len na výslovné Áno (predvolené je Nie). Súčasné riadky sa nemažú ani neprepisujú, doplnia sa len chýbajúce kombinácie
  šablóna, rok, mesiac, prerušenie. Okno vysvetlí, že parametre slúžia na upozornenia a posielajú sa terminálu ako šablóny, vypočítaný čas nemenia. Pri uzavretých mesiacoch sa import nevykoná ako doteraz.
- **`mod_18_Uzavierka` 1.0.1**: `PrepisNastaveniPovoleny` má voliteľný parameter `bLenDopln`: import, ktorý len dopĺňa, kontroluje uzavreté mesiace, ale nepýta sa na prepis ručných úprav
  (nič sa neprepisuje). Fondy, kalendáre a priradenia sa importujú ako doteraz.
- Na konci dávkového importu sa vypíše, čo sa rozhodlo (rozdiely v číselníku, parametre).
- **Čo to nerieši**: samotné razenia z Ordata (kódy, ktoré Access nepozná, sa ako doteraz doplnia ako „NEZNÁME“), fondy, kalendár a priradenia zamestnancov (tie majú ochranu pri ručných úpravách a uzavretých mesiacoch).
- **Nástroj `tools/kontrola_vba.py`**: nová kontrola znakov mimo kódovej stránky Windows 1250. Inštalátor zapisuje moduly v ANSI kódovej stránke a modul s takým znakom (napríklad šípka) odmietne.
- **Neoverené v skutočnom Accesse**: nový kód prešiel `tools/kontrola_vba.py` (0 nálezov), ale nespúšťal sa. Overte dávkový import na kópii databázy: číselník s rozdielmi (obe odpovede), parametre (Áno aj Nie).

## Balík 2.14.1
Predvolené tlačidlá a príznaky prerušení pre terminál sa nastavia pri inštalácii; hlavičky stĺpcov zoznamu prerušení sú čitateľné.
- **Súvislosť**: po 2.14.0 sa tlačidlá a príznaky museli prerušenie po prerušení nastaviť ručne na karte 5. Teraz sa nastavia samy, zatiaľ podľa doterajších tlačidiel terminálu;
  po vyplnení dotazníkov sa predvoľba upraví podľa odpovedí.
- **Čo sa nastaví**: tlačidlá Lekár (č. 2, poradie 1), Sprievod (č. 16, 2), Služobná cesta (č. 12, 3, aj žiadosť vopred), Súkromné (č. 13, 4), Služobné vzdialenie (č. 4, 5, ikona errand,
  kód terminála `ERRAND`); Dovolenka (č. 8) a Nemoc (č. 11) bez tlačidla ako žiadosť len na celý deň so schválením vedúcim. „Nezapočíta sa do práce“ sa nenastavuje (rozhodnutie o výpočte).
- **Kedy sa to uplatní**: pri inštalácii novej databázy, pri aktualizácii databázy (jednorazovo, kľúč `PredvolbaTlacidielPouzita` v nastaveniach systému) a tlačidlom INICIALIZOVAŤ PREDVOLENÚ KONFIGURÁCIU.
  Uplatní sa len na prerušenia, v ktorých správca nikdy nič z tlačidla a príznakov nenastavil. Nastavené prerušenia (napríklad č. 13 s vlastným tlačidlom) sa nemenia a po prvom uplatnení sa predvoľba
  na existujúce prerušenia nevracia, takže vypnuté tlačidlo sa samo nezapne. Nové prerušenie, ktoré inicializácia vytvorí, dostane predvoľbu vždy.
- **`mod_10_Konfiguracia` 1.3.0**: `UplatniPredvolenyTlacidla`, predvoľba v `PredvolenePriznakyDef`, kód terminála pre tlačidlo sa doplní podľa názvu (`DOCTOR`, `FAMILY`, `TRIP`, `PRIV`, `ERRAND`),
  ak ho už nemá iné prerušenie (inak vznikne `PRER` a číslo prerušenia). Prehľad stavu konfigurácie ukazuje počet tlačidiel. Hlavičky stĺpcov zoznamu prerušení: Číslo, Názov, Skratka, Kód Z, Kód K, Auto, Tlačidlo.
- **`mod_13_Instalacia` 1.0.4**: inštalátor uplatní predvoľbu aj v databáze, ktorá už predvolenú konfiguráciu má, a vypíše, čo nastavil.
- **`mod_UI_Tab_Prerusenia` 2.10.1**: stĺpce zoznamu prerušení majú šírky podľa nových hlavičiek (nič sa neorezáva), okno INICIALIZOVAŤ vypíše, ktoré prerušenia dostali tlačidlo alebo príznaky.
- **Čo to nerieši**: kontrakt, terminál ani databáza sa nemenia. Kód `ERRAND` pre Služobné vzdialenie terminálová databáza zatiaľ nepozná (nový kód razenia je súčasť databázovej dávky, krok 5);
  do tej dávky sa súbor s ním do terminálu neimportuje. Import z Ordata sa v tomto balíku nemení.
- **Neoverené v skutočnom Accesse**: nový kód prešiel `tools/kontrola_vba.py`, ale nespúšťal sa. Po inštalácii skontrolujte kartu 5 a exportujte konfiguráciu (karta 7).

## Balík 2.14.0
Karta 5 vie nastaviť tlačidlo pre terminál a príznaky prerušení; konfigurácia pre terminál ich prenáša (kontrakt 1.3.0 a 1.4.0, strana Accessu, 1. časť).
- **Súvislosť**: kontrakt vo verziách 1.3.0 a 1.4.0 opisuje tlačidlá odchodu v termináli (text, poradie, ikona) a príznaky prerušenia (žiadosť vopred, schvaľovanie, len celý deň, nezapočítaný interval),
  ale Access ich nemal kde nastaviť ani exportovať. Všetko je voliteľné: prerušenie bez príznakov sa počíta a exportuje presne ako doteraz.
- **`mod_UI_Tab_Prerusenia` 2.10.0**: nový blok „Tlačidlo a príznaky pre terminál“ pod číselníkom prerušení (platí pre prerušenie vybrané v zozname, ukladá ho tlačidlo Uložiť):
  Tlačidlo v termináli, Text (najviac 24 znakov), Poradie 1 až 99, Ikona (zoznam doctor, family, trip, errand, private, lunch, home, other),
  Môže požiadať vopred, Schvaľuje vedúci, Len na celý deň, Nezapočíta sa do práce. Zoznam prerušení má nový stĺpec „Tlačidlo“. Príznaky sa pred uložením prerušenia skontrolujú,
  takže chyba v nich nenechá prerušenie uložené len čiastočne. Karta je o 2100 twipov vyššia (sekcie 2 a 3 sú nižšie); na malej obrazovke sa formulár posúva.
- **`mod_10_Konfiguracia` 1.2.0**: osem nových voliteľných stĺpcov v číselníku prerušení (doplnia sa samy), `UlozPriznakyPrerusenia`, `ChybaPriznakov`, `ChybaTlacidiel`.
  Pravidlá zodpovedajú kontraktu: č. 1 nemá tlačidlo ani príznaky, najviac 12 tlačidiel, rôzne texty, každé tlačidlo práve jeden kód terminála
  (ak nemá žiadny, vznikne `PRER` a číslo prerušenia v tabuľke TerminalMapaKodov), „Len na celý deň“ sa nedá spojiť s tlačidlom, „Nezapočíta sa do práce“ sa nedá dať obedu (č. 7).
- **`mod_20_KonfiguraciaExport` 1.1.0**: do prerušení pribudnú kľúče `terminal_button`, `terminal_label`, `terminal_order`, `terminal_icon`, `terminal_request`, `needs_approval`, `full_day_only`
  a `calc` = `UNPAID` – vždy len tie, ktoré správca nastavil. Pred zostavením súboru sa všetky prerušenia skontrolujú; pri chybe súbor nevznikne a správa povie, ktoré prerušenie opraviť
  (terminál by nezhodný súbor aj tak odmietol).
- **`mod_08_UdalostiDna` 1.3.0**: prerušenie s príznakom „Nezapočíta sa do práce“ má trvanie 0, takže sa nezapočíta ani do práce, ani do prekážok dňa (neplatený odchod). Prerušenia č. 1 a č. 7 to neovplyvní,
  bez príznaku sa výpočet nemení.
- **`mod_UI_PomocnikTexty` 1.3.0**: pomocník karty 5 opisuje tlačidlo a príznaky. Dva nové riadky posunú poradie nasledujúcich riadkov pomocníka; riadok, ktorý ste v tabuľke PomocnikTexty upravili ručne
  (Upravene = Áno), môže po obnove textov skončiť pri inom riadku.
- **Čo to nerieši**: terminál zatiaľ nové kľúče len prijme a overí; zobrazenie tlačidiel a výpočet `UNPAID` v termináli sa doplnia po rozhodnutí o spoločnom výpočte (D1).
  Pravidlá výpočtu (obed, zaokrúhľovanie, auto-oprava) a okno práce po mesiacoch a fondoch sú ďalšie časti (2.15.0 a ďalej). Pred prvým exportom s tlačidlami musí byť overenie konfigurácie
  na strane databázy terminálu rozšírené o nové kľúče (balík, ktorý spúšťa vlastník).
- **Neoverené v skutočnom Accesse**: nový kód prešiel `tools/kontrola_vba.py` (0 nálezov), ale nespúšťal sa. Chýba overenie vzhľadu a výšky karty 5, ukladania príznakov a exportu na reálnych údajoch.
  Pri chybe pošlite text hlásenia s názvom procedúry.

## Balík 2.13.0
Tlačidlo INICIALIZOVAŤ PREDVOLENÚ KONFIGURÁCIU (karta 5) vytvorí aj pracovný fond, šablónu pravidiel a kalendár a priradí ich zamestnancom.
- **Súvislosť**: v novej prázdnej databáze (nainštalovanej bez importu zo staršej) neboli žiadne fondy, šablóny ani kalendáre, takže dialóg „Priradiť fond, pravidlá a úväzok označeným…“
  nemal čo ponúknuť („Nie je čo zmeniť“) a karta Zamestnanci ukazovala „1 - (chyba v číselníku)“. Výpočet pritom fungoval: zamestnanec bez priradenia dostane fond, šablónu a kalendár č. 1
  a pri chýbajúcom fonde denný fond 450 min. Nastavenie bolo len neviditeľné a v exporte pre terminál bez názvu fondu.
- **`mod_17_FondyPravidla` 1.2.0**: nová `DoplnPredvolenyFondASablonu`. Nič neprepisuje:
  - pracovný fond vznikne len v databáze bez fondov (pružný, denný fond z nastavenia `PredvolenyFondMin`, predvolene 7:30, bez časového okna),
  - šablóna „Základná (bez kontroly)“ (jedno vypnuté pravidlo pre prácu, aby šablóna existovala; pravidlá prerušení sa nekontrolujú) len v databáze bez šablón,
  - kalendár „Pracovné dni Po-Pi, sviatky SR“ (bez vlastných dní, platí pracovný týždeň a tabuľka sviatkov) len v databáze bez kalendárov,
  - priradenie (fond, šablóna a kalendár č. 1, doterajší úväzok) dostanú len zamestnanci bez akéhokoľvek priradenia. Je to to isté, čo výpočet pre nich používal aj bez riadku,
    **výsledky výpočtu sa nemenia**; nastavenie je len viditeľné a exportuje sa s názvom,
  - platnosť začína mesiacom najstaršieho razenia (ak je starší ako január aktuálneho roka), inak januárom aktuálneho roka; staršie mesiace aj tak berú najstaršiu verziu,
  - opakované kliknutie doplní len nových zamestnancov bez priradenia.
- **`mod_10_Konfiguracia` 1.1.0**: `InicializujPracovneNastavenia` (obálka); `StavKonfiguracie` ukazuje aj počet šablón, kalendárov, zamestnancov s priradením a parametre výpočtu
  (okno práce, obed). `InicializujPredvolenuKonfiguraciu`, ktorú volá inštalátor, sa **nemení**: fond sa tam zámerne nevytvára, lebo inštalátor importuje zo staršej databázy a fond č. 1
  by sa zmiešal s fondom č. 1 zo starej databázy.
- **`mod_UI_Tab_Prerusenia` 2.9.0**: tlačidlo po potvrdení doplní konfiguráciu a pracovné nastavenia a vypíše, čo sa vytvorilo.
- **`mod_UI_Tab_Import` 2.8.0**: import zo staršej databázy upozorní (predvolené Nie), ak v tejto databáze už vznikol predvolený fond, šablóna alebo kalendár: fond č. 1 zo starej databázy
  sa zmieša s predvoleným a priradenia z inicializácie môžu prekryť priradenia zo starej databázy. **Poradie**: najprv import zo starej databázy, potom INICIALIZOVAŤ.
- **`mod_UI_PomocnikTexty` 1.2.1**: pomocník karty 5 opisuje nové správanie.
- **Čo to nerieši**: predvolený fond platí pre všetkých rovnako (100 % úväzok). Zamestnanci s iným fondom, úväzkom alebo kalendárom sa nastavia ručne („Priradiť…“) alebo prenesú zo starej databázy.
- **Neoverené v skutočnom Accesse**: nový kód prešiel `tools/kontrola_vba.py` (0 nálezov), ale nespúšťal sa. Pri chybe pošlite text hlásenia s názvom procedúry.

## Balík 2.12.1
Oprava chyby kompilácie v module konfigurácie pre terminál (balík 2.12.0 sa v Accesse nedal skompilovať).
- **Chyba**: Ladenie > Kompilovať hlásilo `Compile error: Expected array` v `mod_20_KonfiguraciaExport`, procedúra `SekciaSablony`.
  Príčina: premenná cyklu `j` a pomocná funkcia modulu `J()` (zápis textu do JSON) majú pre VBA rovnaké meno (veľkosť písmen sa nerozlišuje),
  premenná funkciu zatieni a `J(strNazov)` sa chápe ako indexovanie poľa.
- **`mod_20_KonfiguraciaExport` 1.0.1**: premenná cyklu v `SekciaSablony` sa volá `iMes`. Nič iné sa nemení, výstup je rovnaký.
- **Ručná oprava bez nového balíka**: v `SekciaSablony` premenovať `j` na `iMes` (6 riadkov: deklarácia v `Dim`, `For`, tri riadky v tele cyklu a `Next`).
- **Kontrola v repozitári**: `tools/kontrola_vba.py` (CI ju spúšťa pri každej zmene) hľadá túto chybu a príbuzné: zatienenie funkcie lokálnou premennou,
  nedeklarované premenné, volanie neexistujúceho alebo súkromného člena modulu, zlý počet argumentov, nezhodu typu pri ByRef a nespárované bloky.
  Všetkých 37 modulov balíka 2.12.1 prechádza bez nálezu. Nie je to náhrada kompilácie v Accesse (typy výrazov a členy objektov DAO nekontroluje).
- **Neoverené v skutočnom Accesse**: samotná oprava (kompilácia ani export sa tu nespúšťali). Pri ďalšej chybe pošlite snímku okna s názvom procedúry.

## Balík 2.12.0
Konfigurácia pre terminál s výpočtovým plánom (kontrakt 1.2.0, `dochs_config.json` v schéme 2).
- **Súvislosť**: dovtedajší export niesol len číselník prerušení, kódy razení a sviatky. Terminál tak nemohol počítať saldo rovnako ako Access
  (nepoznal fondy, úväzky ani kalendáre; prerušenia mal pevne v kóde). Teraz Access vypočíta pre každého zamestnanca a deň typ dňa a denný fond a pošle ich
  hotové, spolu s výkladom, ako sa ktoré prerušenie počíta, a s parametrami pravidiel prerušení. Terminál nemusí poznať pravidlá fondov.
- **Nový modul `mod_20_KonfiguraciaExport` 1.0.0**: `GenerujKonfiguraciuV2JSON`. Súbor je nadmnožina pôvodnej konfigurácie; pribúda `interruptions[].calc`
  (WORK / LUNCH / COUNTED podľa `mod_08.TrvanieIntervalu`), `terminal_code_map` (z `TerminalMapaKodov`), `funds`, `templates` (pravidlá prerušení po mesiacoch)
  a `employees[].months[]` s `day_types` a `expected_min` z `mod_08.NacitajKontextMesiaca`. Zamestnanec je len osobné číslo (číslo SAP z `TerminalMapaOsob`, ak je zadané).
  Okno plánu: predchádzajúci až nasledujúci mesiac (nastavenia `PlanMesiacovDozadu`, `PlanMesiacovDopredu`, predvolene 1 a 1, najviac 14 mesiacov).
  Pri chybe sa súbor nezapíše (nikdy čiastočný). Vyradený zamestnanec sa do mesiaca nezahrnie (rovnako ako vo výpočte).
- **`mod_12_TerminalPriprava` 1.3.0**: `ExportujKonfiguraciuDoSuboru` a `VytvorVerziuKonfiguracie` ukladajú novú konfiguráciu (v1 zostáva ako záloha).
- **`mod_16_PravidlaPreruseni` 1.1.0**: nová verejná `PravidlaSablonyPreMesiac` (export berie pravidlá tým istým výkladom ako kontrola dňa). Kontrola sa nemení.
- **`mod_06_AdminTools` 2.6.1**, **`mod_UI_Tab_Export` 2.11.1**: „Export pre Lovable“ aj tlačidlo exportu konfigurácie zapisujú novú konfiguráciu; správa ukáže počty.
- **Overenie súboru**: `python3 -I contract/tools/verify_config.py dochs_config.json` (v repozitári, bez Accessu). Čo kontroluje a ako sa plán počíta: `contract/README.md`.
- **Čo to nerobí**: výpočet dňa v Accesse sa NEMENÍ. Nezmenené ostáva aj to, že všetky prerušenia okrem práce a obeda sa započítavajú (nepoužíva sa `ZapocitavatDoFondu`);
  pravidlá prerušení dávajú len upozornenia.
- **Neoverené v skutočnom Accesse**: celý nový kód (kontrola párovania blokov a odkazov medzi modulmi; spustené nebolo). Pri chybe pošlite text chyby s názvom procedúry.

## Balík 2.11.1
Overenie zariadení z terminála: Access príznak ukladá a hlási pri importe.
- **Súvislosť**: terminál označuje razenia z neschválených zariadení (`device_verification = unverified`). Kontrakt hovorí, že Access ich má označiť na kontrolu,
  importér však príznak načítal a zahodil. Teraz sa ukladá a hlási. Razenia sa počítajú ako doteraz, import sa pre ne nezastavuje.
- **`mod_12_TerminalPriprava` 1.2.0**: tabuľka `TerminalInbox` dostane stĺpce `Overenie` (verified / unverified / confirmed) a `ZariadenieID` (celé ID zariadenia);
  doplnia sa samy v existujúcej databáze (jeden pokus za reláciu, pri neúspechu sa razenia prijímajú aj bez príznaku a zapíše sa varovanie do logu).
  `PrijmiRazenie` má dva nepovinné parametre navyše (staré volania fungujú). Nová `AktualizujOverenie` zmení iba príznak už prijatého razenia.
- **`mod_19_TerminalImport` 1.3.0**: report importu (aj nanečisto) uvádza počet a zamestnancov s razeniami z neschválených zariadení a zamestnancov, ktorí razili
  z viac než jedného overeného zariadenia v súbore (možná výmena zariadenia). Ak vedúci neoverené razenie medzitým potvrdil v termináli, pri opakovanom importe tej istej
  dávky sa zmení iba príznak (razenie sa nevkladá znova). Nič sa nemaže ani neprepočítava.
- **Test**: `testy/terminal/mesiac-2026-10/` doplnený o `overenie_test_2026-10.csv`, `overenie_test_potvrdene_2026-10.csv`, `make_overenie.py` a postup E v `POSTUP.txt`.
  Súbory prešli kontraktovým overovačom (`verify_export.py`).
- **Čo to nerobí**: neoverené razenie sa v editore dňa nijako nefarbí a nezablokuje uzávierku mesiaca. Hlásenie je v reporte importu a údaj je v tabuľke `TerminalInbox`.
- **Neoverené v skutočnom Accesse**: celý nový kód (kontrola párovania blokov a odkazov medzi modulmi; spustené nebolo). Pri chybe pošlite text chyby s názvom procedúry.

## Balík 2.11.0
Zneplatnené razenia z terminála (kontrakt 1.1, súbor `voids_RRRRMM.csv`).
- **Súvislosť**: zamestnanec (alebo vedúci / správca vo výkaze) môže v terminále požiadať o zneplatnenie razenia, napr. duplicity; vedúci alebo správca ju
  schváli. V terminále sa razenie nemaže ani nemení jeho hash. Terminál ho posiela v exporte razení ďalej a zneplatnenia v samostatnom súbore.
- **`mod_19_TerminalImport` 1.2.0**: `ImportujZneplatnenia` overí súbor (pätička, SHA-256, počet riadkov, hlavička, verzia, jedna organizácia), uloží zneplatnenia do novej
  tabuľky `TerminalZneplatnenia` (idempotentne podľa `external_id`) a použije ich: riadok `DochadzkaImport` dostane `Platnost = Nie` a `DovodNeplatnosti = ZNEPLATNENE_V_TERMINALI`.
  Razenie sa nemaže. Kontroluje sa `record_hash` (z pôvodného riadku vo fronte) a osobné číslo; pri nezhode sa nezneplatní (stav `NEZHODA`).
  Ak razenie ešte nie je importované, zneplatnenie čaká (`CAKA`) a použije sa po importe razení; pri uzavretom mesiaci čaká (`UZAVRETY`) a použije sa po jeho otvorení
  pri ďalšom spracovaní. Nové tlačidlá nie sú: súbor `voids_*.csv` sa vyberie v tom istom tlačidle „Importovať súbor z terminála“, ktoré ho podľa hlavičky rozpozná.
- **Samočinný test zneplatnení** (`SamoTestZneplatneni`; karta 7 > Samočinný test terminála > Nie): nanečisto, ostrý import nad testovacími údajmi 90000xx, výsledky pred a po
  (`terminal_test_access_vysledky_pred_zneplatnenim.csv`, `terminal_test_access_vysledky.csv`) a `terminal_test_zneplatnenia_report.txt`.
- **`mod_UI_Tab_Export` 2.11.0**: rozpoznanie `voids_*.csv`, voľba, ktorý samočinný test spustiť.
- **Test**: `testy/terminal/mesiac-2026-10/` doplnený o `voids_test_2026-10.csv` a `voids_test_negativne_2026-10.csv` a postupy C a D v `POSTUP.txt`.
- **Upozornenie k párovaniu**: kódy razení (príchod / odchod, obed) sa určujú pri importe z poradia razení za deň. Po zneplatnení sa nepárujú znova. U bežnej duplicity (rovnaké
  razenie dvakrát) je výsledok správny. Ak sa zneplatní prvé z dvoch rôzne spárovaných razení (napr. príchod, ktorý ukončil obed), skontrolujte deň v editore dochádzky.
- **Neoverené v skutočnom Accesse**: celý nový kód (lint, kontrola párovania blokov a modelová kontrola súborov; spustené nebolo). Pri chybe pošlite
  `terminal_test_zneplatnenia_report.txt` a text chyby s názvom procedúry.

## Balík 2.10.2
Opakovateľný test terminála a scenár na celý mesiac.
- **`mod_19_TerminalImport` 1.1.0**: samočinný test sa pred ostrým importom opýta, či odstrániť staré testovacie údaje 90000xx (inak by sa razenia z iného
  súboru pridali k starým a saldá by sa zdvojili). Po odstránení, ak vo fronte terminála nezostane nič, sa vynuluje zapamätaná organizácia a posledné punch_id,
  takže sa dá importovať súbor z inej organizácie terminála bez ručného zásahu.
- **Test na celý mesiac**: `testy/terminal/mesiac-2026-10/` (október 2026, zamestnanci 9000001 až 9000004, 237 razení, aj prechod na zimný čas,
  duplicity, otvorený deň a deň bez razenia), očakávané saldá z enginu terminálu a skript `porovnaj.py` na porovnanie terminál / Access. Postup je v `POSTUP.txt`.
- Neoverené v skutočnom Accesse.

## Balík 2.10.1
Oprava okna Pomocník: políčko „Nezobrazovať pri otvorení karty“ sa nedalo zaškrtnúť.
- **Príčina**: formulár `frmPomocnik` mal `AllowEdits = Nie`. V spojitom formulári to zamkne aj nesviazané ovládacie prvky v hlavičke a päte,
  takže sa nedalo zmeniť ani políčko, ani kliknutím na text vedľa neho (zmena hodnoty zlyhala potichu).
- **Oprava** (`mod_UI_Pomocnik` 1.2.1): `AllowEdits = Áno`, podklad okna je snapshot (`RecordsetType = 2`) a textové polia ostávajú `Locked`, takže texty sa
  stále nedajú prepísať. Stav sa pri kliknutí na text zapíše do `PomocnikStav` ako prvý a až potom do políčka; zmena sa zapíše do protokolu (`INFO`).
  Verzia formulára 1.2, takže sa okno pri najbližšom otvorení vytvorí znova (nič netreba mazať).
- Neoverené v skutočnom Accesse (príčina sa potvrdila zo správania Accessu v spojitých formulároch, nie spustením). Ak by to nepomohlo, pošlite riadky
  `mod_UI_Pomocnik` z tabuľky protokolu.

## Balík 2.10.0
Import súboru z terminála (kontrakt v1) a samočinný test spolupráce Access <-> terminál.
- **Nový modul `mod_19_TerminalImport` 1.0.0**: načíta `punches_*.csv`, overí pätičku (počet riadkov, SHA-256) a hash reťaz po používateľovi
  (čistý VBA, bez .NET), prevedie kódy terminála na prerušenia a kódy razenia Accessu (tabuľka `TerminalMapaKodov`, predvolené mapovanie siedmich kódov),
  spáruje odchod / príchod za deň, zapíše razenia do `TerminalInbox` (idempotentne) a spracuje ich do `DochadzkaImport` cez `SpracujInbox`.
  Zamestnanec sa hľadá cez `TerminalMapaOsob` alebo zhodou po odstránení / doplnení úvodných núl. Beh nanečisto nič nezapíše.
- **Karta 7 Exporty**: tlačidlá „Importovať súbor z terminála“ a „Samočinný test terminála“ (`mod_UI_Tab_Export` 2.10.0).
- **Samočinný test**: SHA-256 na známych vektoroch, kontrola mapovania a číselníka kódov razenia, beh nanečisto, voliteľne ostrý import testovacích
  zamestnancov 9000001 až 9000099, prepočet mesiaca a zápis `terminal_test_report.txt` a `terminal_test_access_vysledky.csv` (denné výsledky, intervaly, anomálie).
  Testovacie údaje: `testy/terminal/`. Upratanie: `mod_19_TerminalImport.OdstranTestoveData()`.
- **Neoverené v skutočnom Accesse**: celý modul (len lint, krížová kontrola a model algoritmov v Pythone: SHA-256 na 211 vstupoch zhodný s referenčnou
  implementáciou vrátane kontroly pretečenia 32-bitových Long, párovanie a hash reťaz na zlatom súbore kontraktu a na testovacom súbore).
  Pri chybe pošlite `terminal_test_report.txt` a text chyby s názvom procedúry.
- Nekontroluje sa zatiaľ nadväznosť reťaze na predchádzajúci import (posledný hash používateľa) a nespracúvajú sa celodenné udalosti dňa
  (LEAVE / SICK sa vedú ako začiatok prerušenia č. 8 / 11, ktoré sa ukončí podľa pravidla „koniec do konca smeny“).

## Balík 2.9.0
Uzávierka mesiaca (ochrana podpísaných zostáv), verzie fondov a pravidiel „platné od mesiaca“ s históriou, skok na zamestnanca a predvolené hodnoty v editoroch.
- **Uzávierka mesiaca** (`mod_18_Uzavierka`, `mod_UI_Uzavierka`, karta 6 > Uzávierka mesiaca…): postup návrh → tlač → podpis → Uzavrieť. Uzavrieť sa dá od posledného
  dňa mesiaca a len ak sa údaje od vytvorenia zostavy nezmenili (kontrolný kód zostavy musí sedieť s aktuálnym); zapíše sa, kto zostavu potvrdil.
  Uzavretý mesiac zamestnanca sa neprepočítava (aj hromadný prepočet ho preskočí), nedá sa meniť v editore dňa, nemažú sa jeho razenia ani výpočty (čistenie pomocných
  tabuliek), neprepíše ho import z Ordata ani import z modelu a nedá sa zmeniť fondom, pravidlami, úväzkom, kalendárom ani vyradením, ktoré by ho zasiahli.
  Razenia z terminálu do uzavretého mesiaca ostanú v `TerminalInbox` (stav UZAVRETY) a spracujú sa po otvorení. Otvorenie vyžaduje dôvod a zapíše sa do
  `DochadzkaUzavierkaLog`. „Overiť“ porovná uložené hodnoty s kontrolným kódom. Päta zostavy ukazuje NÁVRH alebo MESIAC JE UZAVRETÝ (dátum, kto potvrdil, kód),
  prípadne upozornenie, ak sa údaje po uzavretí zmenili. Ochrana je na úrovni aplikácie; kontrolný kód zmenu mimo aplikácie odhalí, ale nezabráni jej.
- **Editor fondov a pravidiel prerušení** (`mod_UI_Sablony` 1.1.0, `mod_17_FondyPravidla` 1.1.0): zoznam Zamestnanec (skok na fond / šablónu platnú pre neho
  v zvolenom mesiaci; z karty 2 sa editor otvorí na označenom zamestnancovi), zoznam Verzie (história „platné od mesiaca“), tlačidlo Kto používa, zoznam
  Predvoľba + Použiť (pevná 7:30 / 8:00, pružná, voľná, mesačný fond 165:00, dvanásťhodinová zmena; pravidlá: bez kontroly, obed, krátke prerušenie, lekár),
  nový fond z predvoľby, červené upozornenie pred uložením, ak by zmena zasiahla uzavretý mesiac.
- **Platnosť od mesiaca, bez kopírovania**: fond, pravidlá aj priradenie zamestnanca platia od zvoleného mesiaca až do ďalšej verzie. Nekopírujú sa po mesiacoch (ako
  šablóny v Ordata). Úväzok je súčasťou verzie priradenia (`ZamestnanciFondy.UvazokPercent`), takže zmena úväzku od mesiaca nemení minulosť.
- **Karta zamestnanca** (`mod_UI_ZamKarta` 1.1.0): zmena mesiaca zobrazí priradenie platné pre zamestnanca v tom mesiaci vrátane úväzku; uloženie zapíše verziu priradenia.
- **Ochrana pri importe a údržbe**: `mod_02_DBFImport`, `mod_14_ImportModelu`, `mod_06_AdminTools` (čistenie výpočtov), `mod_09_AutoOprava`, `mod_12_TerminalPriprava`
  nemenia uzavreté mesiace.
- **Pomocník 1.2.0**: texty o uzávierke, päte zostavy, verziách a predvoľbách v editoroch.
- Moduly: mod_UI_Core 2.9.0, mod_01_SystemInit 2.9.0, mod_UI_Tab_Vypocet 2.9.0, mod_06_AdminTools 2.6.0, mod_02_DBFImport 2.6.0, modMesaatnaDochadzka 2.7.0,
  mod_05_UI_AttendanceEditor 2.7.0, mod_08_UdalostiDna 1.2.0, mod_09_AutoOprava 1.2.0, mod_12_TerminalPriprava 1.1.0, mod_14_ImportModelu 1.1.0,
  mod_15_Zamestnanci 1.1.0, mod_17_FondyPravidla 1.1.0, mod_UI_Sablony 1.1.0, mod_UI_ZamKarta 1.1.0, mod_UI_Tab_Zamestnanci 1.1.0, mod_UI_Pomocnik 1.2.0,
  mod_UI_PomocnikTexty 1.2.0; nové: mod_18_Uzavierka 1.0.0, mod_UI_Uzavierka 1.0.0.
- **Neoverené v skutočnom Accesse** (len kontrola kódom, lint a simulácia inštalátora): rozloženie okien Uzávierka mesiaca, Pracovné fondy a Pravidlá prerušení, zoznam
  s poľami z funkcií VBA (`Uz_PoleZoznamu`), päta zostavy (`Uz_TextZostavy`), zoznam Zamestnanec (Table/Query) a dotazy volajúce funkcie VBA. Pri chybe pošlite
  inštalačný protokol alebo snímku s názvom modulu, riadkom a textom chyby.

## Balík 2.8.0
Oprava číslovania kariet, nová karta Zamestnanci, individuálne fondy/úväzky/vyradenie a pravidlá prerušení s upozorneniami.
- **Oprava posunu kariet**: karta Active Directory sa pri chýbajúcej doméne nevytvárala, no navigácia mapovala tlačidlá na strany podľa
  pozície – po jej zapnutí sa všetko posunulo a pod „2 AD“ sa zobrazil obsah Kontroly. Teraz majú karty pevné čísla (1 Import, 2 Zamestnanci,
  3 Kontrola, 4 Editor, 5 Prerušenia, 6 Výpočet, 7 Exporty, 8 Admin, 9 Active Directory – voliteľná, len v doméne alebo podľa nastavenia
  `ADKartaZobraz` = auto/1/0). Strana nesie svoj kľúč (Tag) a konzola sa prestaví, keď sa zmení zoznam kariet (`UIKonzolaKarty`).
- **„Invalid use of Null“ v `PomocnikAutoZobraz`**: `TVGet` spracuje neexistujúcu TempVar (Null) a nepoužije `CLng(Null)`.
- **Nová karta 2 Zamestnanci** (`mod_UI_Tab_Zamestnanci`, `mod_UI_ZamKarta`): zoznam pre zvolený mesiac (úväzok, pracovný fond, šablóna prerušení,
  stav), hľadanie, „aj vyradení“, karta zamestnanca (nový / úprava), úväzok v %, vyradenie od dátumu a vrátenie do evidencie,
  hromadné priradenie fondu, pravidiel, kalendára a úväzku vybraným zamestnancom vrátane vytvorenia novej skupiny (kópia fondu a šablóny).
- **Dátový model** (`mod_15_Zamestnanci`): nové stĺpce `Zamestnanci.Vyradeny`, `VyradenyOd`, `UvazokPercent`, `TextDisplej`, `Poznamka`.
  Fond a šablóna prerušení už boli viazané na zamestnanca (`ZamestnanciFondy`, platnosť od mesiaca), no chýbalo UI; `ParametrePreruseni` sa
  importovali, ale nepoužívali. Teraz sa používajú. Vyradení sa vynechajú z výpočtov, zostáv a analýzy; úväzok skracuje denný fond (`mod_08_UdalostiDna`).
- **Editor pracovných fondov** (`mod_UI_Sablony`, `mod_17_FondyPravidla`): typ fondu (1–4), denný/mesačný fond, voliteľne dĺžka podľa dňa v týždni
  (príchod od, odchod do, fond, prestávka). Ukladá sa od zvoleného mesiaca; nový fond vzniká kópiou.
- **Editor pravidiel prerušení**: povolený čas, najdlhšie/najkratšie trvanie, „odpracovať pred začiatkom“ (napr. obed najskôr po 3 h práce
  a v okne 11:00–13:30), voliteľne po dňoch v týždni, možnosť pravidlo vypnúť. Kontrola (`mod_16_PravidlaPreruseni`) pri porušení pridá anomáliu
  so závažnosťou VAROVANIE (v zozname „Na ručné posúdenie“ so značkou „(!)“); výpočet sa nemení. Celú kontrolu vypne `KontrolaPravidielPreruseni` = 0.
- **Menu a objekty**: tlačidlo Menu (Alt+M) ovláda len pás kariet, nové tlačidlo Objekty (Alt+O) ľavý navigačný panel s objektmi. Panel sa pri štarte
  skrýva spoľahlivejšie (`StartupShowDBWindow` + `NavigateTo` + `acCmdWindowHide`); konzola sa po skrytí vždy vráti do popredia.
- **Karta 5 Prerušenia**: tlačidlá „Pracovné fondy…“ a „Pravidlá prerušení…“ (sekcie 2 a 3 sa posunuli nižšie).
- **Pomocník 1.1.0**: texty pre 9 kariet, nová karta Zamestnanci, upozornenia z pravidiel, tlačidlo Objekty.
- Moduly: mod_UI_Core 2.8.0, mod_UI_Spolocne 1.2.0 (okná `Dlg*`), mod_UI_Pomocnik 1.1.0, mod_UI_PomocnikTexty 1.1.0, mod_UI_Tab_ADSync/Admin/Prerusenia 2.8.0,
  mod_UI_Tab_Vypocet 2.7.1, mod_01_SystemInit 2.8.0, mod_00_Common 2.7.0, mod_08_UdalostiDna 1.1.0, mod_09_AutoOprava 1.1.0, modMesaatnaDochadzka 2.6.0;
  nové: mod_15_Zamestnanci, mod_16_PravidlaPreruseni, mod_17_FondyPravidla, mod_UI_Tab_Zamestnanci, mod_UI_ZamKarta, mod_UI_Sablony (všetky 1.0.0).
- **Neoverené v skutočnom Accesse**: rozloženie nových okien, skrývanie navigačného panelu a dotazy volajúce funkcie VBA (`Zam_FondText`) bolo
  overené len kontrolou kódu a simuláciou inštalátora. Pri chybe pošlite modul, riadok a text z okna / protokolu.

## Balík 2.7.0
Opravy rozloženia konzoly, skrytie menu Accessu a kontextové info okná (Pomocník).
- **Navigácia kariet**: pevná hlavička konzoly s tlačidlami kariet 1–8 (Alt+1 … Alt+8), záložky tab-ovládača sú skryté, takže
  navigácia nezmizne ani pri posúvaní dlhej karty (napr. 3. Kontrola & Auto-oprava). Obsah konzoly má zvislý aj vodorovný
  posuvník; stavový riadok je v pevnej päte. Ak Access nepustí hlavičku/pätu formulára, použije sa záložné rozloženie s viditeľnými záložkami.
- **Menu a objekty Accessu**: pás kariet a navigačný panel sa pri štarte skryjú; tlačidlo Menu (Alt+M) ich zobrazí aj skryje,
  nastavenie `UIPriStarteSkryMenu` (karta 8). Vývojársky režim a skúšobný štart inštalátora menu neskrývajú. Pri zobrazení zostavy sa pás kariet zobrazí sám.
- **Pomocník (info okná kariet)**: nový `mod_UI_Pomocnik` + `mod_UI_PomocnikTexty`. Pre každú kartu (a prehľad celého postupu) okno s tabuľkou
  Druh | Čo | Popis (ČO TO JE, KROK, MOŽNOSŤ, TIP, POZOR, ĎALEJ), farebne formátované. Samo sa ukáže, ak činnosť na karte ešte nebola vykonaná
  (prázdna databáza → postup importu z Ordata / zadania osobných čísel; kontrola → ak nie sú opravy; …), nie je zaškrtnuté „Nezobrazovať“
  a v relácii sa pre kartu ešte neukázalo. Vyvolanie: tlačidlo Pomocník / Alt+P. Texty sú v tabuľkách `PomocnikKarty`, `PomocnikTexty`
  (upravený riadok sa neprepíše), stav v `PomocnikStav`.
- **Rozloženie okien**: roztiahnutie obsahu kariet na šírku konzoly, písmo Segoe UI, zmenšenie písma tam, kde by sa text orezal
  (`mod_UI_Spolocne 1.1.0`: `NormalizujFormular`), odstránenie pripojených popiskov polí; názvy stĺpcov v zoznamoch auto-opráv („Os. číslo“, „Typ anomálie“ …).
  Okno úpravy dňa: širšie stĺpce, Esc = Koniec, opravené popisy tlačidiel a klávesové skratky (skryté `[Ins]`/`[Del]` nefungovali). Okno priebehu má popisky polí.
- **Chyby „Invalid use of Null“**: `mod_03_ADSync.PrepocitajHierarchiu` (IIf vyhodnocuje oba argumenty → `CStr(Null)`) a
  `mod_05_UI_AttendanceEditor` (`Ed_PosunZamestnanca`, `Ed_ObnovZoznamZamestnancov` – `ItemData` s Null).
- **Import**: tlačidlá „Tento rok“ a „Minulý mesiac“ majú popisok (aké obdobie nastavia) a zapíšu ho do stavového riadka; tlačidlo „Pridať ako zamestnancov“ je širšie.
  „Minulý mesiac“ nastaví Od aj Do na celý predošlý mesiac (v novembri 2026 = október 2026) – správne.
- **Inštalátor / diagnostika**: skúšobný štart (`InstalacnyTestStartu`) neskrýva menu a nezobrazuje info okná, vždy vygeneruje konzolu nanovo,
  vypíše diagnostiku rozloženia a odlíši chyby z tohto štartu od starších záznamov v logu.
- Moduly: mod_UI_Core 2.7.0, mod_UI_Spolocne 1.1.0, mod_UI_Pomocnik 1.0.0 (nový), mod_UI_PomocnikTexty 1.0.0 (nový), mod_01_SystemInit 2.7.0,
  mod_13_Instalacia 1.0.3, mod_00_Common 2.6.0, mod_05_UI_AttendanceEditor 2.6.0, mod_09_AutoOprava 1.0.2, mod_03_ADSync 2.5.1,
  modMesaatnaDochadzka 2.5.2, mod_UI_Tab_Import/Export/ADSync/Prerusenia/Admin 2.7.0.

## Balík 2.6.5
- **Inštalátor**: hľadá databázy v priečinku inštalátora (rozlíši databázu z inštalátora a staršiu bez verzionovania),
  novú databázu vytvára v tom istom priečinku ako `dochadzka-<verzia>.accdb` a ponúkne predvolený postup
  (N = nová, I = nová + import, K = kópia + aktualizácia, A = aktualizácia na mieste) – stačí potvrdiť Enterom.
- **mod_UI_Spolocne 1.0.0 (nový)** – výber mesiaca rozbaľovacím zoznamom (dá sa písať aj názov mesiaca), zadávanie osobných
  čísel textom s automatickým rozpoznaním oddeľovača a rozsahov (1001-1010).
- **mod_02_DBFImport 2.5.1** – import už neignoruje obdobie z karty Import (čítal ho zo starého formulára sprievodcu
  a pýtal sa cez InputBox); nový filter osobných čísel pre import zamestnancov aj razení.
- **mod_UI_Tab_Import 2.6.1** – obdobie od–do zo zoznamu mesiacov + rýchle voľby (Tento rok, Minulý mesiac), pole Osobné čísla,
  tlačidlo „Pridať ako zamestnancov“, potvrdenie volieb pred importom, zapamätanie posledného obdobia.
- **mod_UI_Tab_Vypocet 2.6.0** – výber mesiaca zo zoznamu (+ tlačidlá < >), zadanie osobných čísel textom, priebeh v stavovom riadku.
- **mod_UI_Tab_Export 2.5.1, mod_UI_Tab_Konsolidacia 2.5.1, mod_05_UI_AttendanceEditor 2.5.1, mod_09_AutoOprava 1.0.1** – výber mesiaca zo zoznamu;
  export: osobné čísla s ľubovoľným oddeľovačom, vlastný dialóg priečinka (už neprepisuje cestu k DBF).
- **mod_14_ImportModelu 1.0.1** – opakovaný import zo staršej databázy sa „zacyklil“: doplňovanie do neprázdnej tabuľky porovnávalo
  kľúče cez Nz(), čo vylúčilo index (pri 60 000 razeniach miliardy porovnaní). Teraz sa porovnáva priamo (s indexom), v stavovom
  riadku je vidieť priebeh a pri opakovanom importe toho istého súboru sa zobrazí upozornenie.
- **mod_00_Common 2.5.1** – správy z logu sa zobrazujú v stavovom riadku konzoly; dialógy DBF čítajú cestu z konzoly.
- **mod_13_Instalacia 1.0.2** – `NastavVerziuBalika` (inštalátor zapisuje verziu balíka do databázy).
- **mod_UI_Core 2.6.1** – verzia UI 2.6.1 (konzola sa pri štarte prestaví s novými ovládacími prvkami).

## Balík 2.6.4
- **mod_13_Instalacia 1.0.1** – `InstalacnyTestStartu()` a `PoslednyChybyLog(n)` (diagnostika štartu aplikácie).
- Inštalátor: po vytvorení makra AutoExec sa jeho obsah znovu načíta (SaveAsText) a overí, že volá `AutoExecStart()` (inak sa skúsi iný formát makra); potom sa skúšobne spustí `AutoExecStart()` a do protokolu sa vypíšu posledné chyby z `LogImportu`.

## Balík 2.6.3
- **mod_10_Konfiguracia 1.0.1** – oprava chyby „Syntax error“: premenná `mOd` je v VBA nerozlíšiteľná od operátora `Mod` (premenované na `lOdMin`/`lDoMin`).

## Balík 2.6.2
- **modMesaatnaDochadzka 2.5.1** – oprava chyby kompilácie „Variable not defined“ (deklarácia `mDicNazvy` bola až za prvou procedúrou, presunutá na začiatok modulu).
- Inštalátor: spoľahlivá detekcia chyby kompilácie (príkaz Ladenie > Kompilovať projekt v editore VBA; po chybe inštalácia zastaví a nechá Access otvorený).

## Balík 2.6.1
- Inštalátor: oprava volania `Application.Run` z PowerShellu (argumenty sa odovzdávajú cez `[ref]`; chyba „Argument: '2' should be a PSReference“ po kompilácii). Moduly VBA sa nezmenili.
- Pri neúspechu inštalátor vypíše, ako pokračovať (zmazať rozpracovanú databázu alebo spustiť znova nad ňou).

## Balík 2.6.0
Prvý balík s inštalátorom a verzionovanými modulmi. Zahŕňa revíziu 2.5.0 (auto-oprava pípnutí, konfigurácia, import CSV/AD,
príprava terminálu) a:

- **Inštalátor** `Instaluj-Dochadzku.ps1` (+ `Instaluj.cmd`), manifest s SHA-256, selektívna aktualizácia modulov, záloha DB aj modulov.
- **mod_13_Instalacia 1.0.0** – inštalačná inicializácia, evidencia verzií (`VerzieModulov`).
- **mod_14_ImportModelu 1.0.0** – import dát zo staršej verzie databázy (nedeštruktívne dopĺňanie, jedna transakcia).
- **mod_01_SystemInit 2.6.0** – `AutoExecStart` vždy dorovná štruktúru; tabuľky so starou štruktúrou sa už nemažú, ale premenúvajú na `old_<čas>_<názov>`.
- **mod_UI_Core 2.6.0** – verzia UI 2.6.0 (konzola sa pri štarte prestaví).
- **mod_UI_Tab_Import 2.6.0** – tlačidlo „Importovať dáta zo staršej verzie databázy“.
- Zrušené moduly: `modExportLovableConfig`, `mod_UI_Tab_AutoOprava`.

### Pravidlo verzií
Zmena obsahu modulu ⇒ vyššia `'@Verzia X.Y.Z` (inak `tools/zostav_balik.py` zostavenie odmietne).
