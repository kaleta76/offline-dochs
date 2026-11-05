# Konfigurácia a výpočtový plán z Accessu do terminálu

Otázka vlastníka (4. 11. 2026): *prerušenia, ich parametre a všetko potrebné pre výpočet by sa malo dať exportovať z Accessu; je na to pripravený dátový model?*

**Odpoveď: nebol.** Tento dokument opisuje, čo chýbalo, čo sa pripravilo (kontrakt 1.2.0, balík Access 2.12.0, zadanie pre aplikačnú časť),
aké rozdiely vo výpočte treba rozhodnúť a v akom poradí to nasadiť. **Stav (4. 11. 2026):** kontrakt 1.2.0 a balík Access 2.12.0 sú zlúčené, databázová časť je u vlastníka nasadená a skontrolovaná.
Etapa 1 aplikačnej časti (kontrola súboru, náhľad a prijatie v Správe) je v PR `claude/import-konfiguracie`; etapa 2 (výpočet salda podľa plánu) čaká na rozhodnutie D1 z kapitoly 4.

Zistenia pochádzajú **z čítania kódu** (Access: `mod_08`, `mod_12`, `mod_16`, `mod_17`, `mod_15`; terminál: `src/lib/engine.ts`). Nič z toho nebolo spustené v živom Accesse.
Spoľahlivo to ukáže až porovnanie sald (`docs/TESTOVANIE-S-ACCESSOM.md`).

## 1. Čo chýbalo

| Čo treba pre rovnaký výsledok | Access pred 2.12.0 | Terminál dnes |
|---|---|---|
| Číselník prerušení a kódy razení | exportoval (`schema_version` 1) | pevných 7 kódov v `engine.ts` (WORK, TRIP, DOCTOR, FAMILY, LEAVE, SICK, PRIV) |
| **Ako sa ktoré prerušenie počíta** | nikde nevyjadrené (je v kóde `mod_08`) | pevné pravidlá podľa kódu, iné než v Accesse (pozri nižšie) |
| Mapovanie kódov terminála na prerušenia Accessu | tabuľka `TerminalMapaKodov`, neexportovala sa | nepozná |
| Pracovný fond (dĺžka dňa, podľa dňa v týždni, pevný mesačný fond, verzie od mesiaca) | len predvolený denný fond | jeden denný fond pre všetkých (`DENNY_FOND_HODIN`) |
| Úväzok, priradenie fondu, šablóny a kalendára zamestnancovi od mesiaca | neexportovalo sa | nepozná |
| Kalendár (voľné dni mimo víkendu, firemné voľno), sviatky | sviatky exportoval | víkend a sviatky z vlastného zoznamu |
| Parametre pravidiel prerušení (povolený čas, najdlhšie a najkratšie trvanie, minimum odpracovaného) | neexportovalo sa (pravidlá dávajú len upozornenia) | nepozná |
| Prijatie a overenie konfigurácie | exportovalo sa bez kontroly a bez kontraktu | žiadny import |

Dátový model Accessu **je** na export pripravený (všetko je v tabuľkách), chýbal výber, kontrakt a overenie. Dátový model terminálu pripravený **nebol**.

## 2. Princíp: Access rozhoduje, terminál preberá

Access je systém, v ktorom sa fondy, kalendáre a pravidlá spravujú, a ktorý robí záväzný výpočet (`docs/SPOLUPRACA.md`). Terminál preto **nedostane pravidlá**, ale **ich výsledok**:

* pre každého zamestnanca a deň **typ dňa** a **denný fond v minútach** (už po zohľadnení fondu, dňa v týždni, pevného mesačného fondu, kalendára, sviatkov a úväzku);
* pre každé prerušenie **výklad, ako sa počíta** (`calc`: `WORK`, `LUNCH`, `COUNTED`) a hranicu celodennej prekážky;
* **mapovanie kódov** terminála na prerušenia Accessu a parametre pravidiel prerušení (na upozornenia).

Výhoda: keď sa v Accesse zmení algoritmus fondu, terminál sa nemusí meniť; stačí nová konfigurácia. Plán sa počíta tou istou funkciou ako vo výpočte mesiaca
(`mod_08.NacitajKontextMesiaca`), takže sa nemôže rozísť s Accessom. Formát: `contract/README.md`, schéma `contract/config-export.schema.json`,
príklad `contract/examples/config_example.json`.

## 3. Rozdiely vo výpočte, ktoré konfigurácia sama nevyrieši

Terminál dnes počíta inak než Access. Po zavedení konfigurácie sa má riadiť Accessom (rozhodnutie D1), preto treba terminál prispôsobiť. Zistené čítaním kódu:

| Oblasť | Access (záväzný) | Terminál (`engine.ts`) |
|---|---|---|
| Iné prerušenie než práca a obed (lekár, služobná cesta, osobné prekážky, …) | započíta sa skutočné trvanie; od hranice celodennej prekážky (predvolene 6 h) sa započíta denný fond dňa | lekár a rodina sa kreditujú, služobná cesta ako práca; **súkromné prerušenie sa nezapočíta** |
| Doplnenie do fondu, keď deň končí lekárom, rodinou alebo služobnou cestou | **žiadne** | dopĺňa do fondu |
| Okno práce | práca sa oreže na okno (predvolene 6:00 až 17:00) | bez okna |
| Obed | automaticky sa odpočíta celých 30 min, ak práca (v okne práce, bez služobnej cesty) dosiahne 6 h vrátane a v dni nebol obed (č. 7); v dni bez fondu sa neodpočíta. Razený obed sa dá nastaviť na „najmenej“ alebo „vždy presne“ zadané minúty (balík 2.15.1) | rovnako od PR #34: celých 30 min od 6 h vrátane, ak zamestnanec obed nevyrazil (Odchod bez dôvodu a neskôr Príchod). Zostáva rozdiel v tom, čo sa do 6 h počíta: terminál nerežie prácu oknom, počíta aj služobnú cestu a odpočíta aj v dni bez fondu; razený obed „najmenej“ a „vždy presne“ nepozná |
| Zaokrúhlenie príchodu a odchodu | v tomto výpočte nie | nastavenia `ZAOKRUHLENIE_*` |
| Duplicitné razenie | rovnaký kód a smer do 10 min sa ignoruje (anomália) | nerieši |
| Párovanie razení | stavový automat dňa (`mod_08.SpracujDen`): príchod, odchod, prerušenie, návrat, paralelné prerušenia, otvorené prerušenie, automatický koniec prerušenia | jednoduché páry IN/OUT |
| Fond dňa | podľa plánu zamestnanca (fond, deň v týždni, úväzok, kalendár) | jeden `DENNY_FOND_HODIN` |

Niektoré kódy v mapovaní sú v Accesse označené „overiť“ (`FAMILY` → 16, `PRIV` → 13). Zlý odkaz tu znamená zlé saldo, takže mapovanie treba pred nasadením potvrdiť
(riadok `terminal_code_map` v exporte ho ukazuje).

## 4. Rozhodnutia pre vlastníka

| # | Otázka | Odporúčanie |
|---|---|---|
| D1 | Ktorý výpočet je pravda? | **Access** (zásada v `docs/SPOLUPRACA.md`). Terminál sa prispôsobí. Dôsledok: súkromný odchod sa v saldo započíta tak, ako to robí Access dnes (ak to nechcete, mení sa pravidlo v Accesse a v exporte pribudne nová hodnota `calc`, nie terminál) |
| D2 | Ako často sa konfigurácia posiela? | ručne po každej zmene fondu, úväzku, kalendára alebo pravidiel a vždy na začiatku mesiaca; okno plánu je predchádzajúci až nasledujúci mesiac. Neskôr možno automatizovať (HTTPS, prompt 05) |
| D3 | Čo ukáže terminál za mesiac bez plánu? | saldo označené „bez plánu z Accessu, nepotvrdené“, nie tichý odhad |
| D4 | Stav vyradeného zamestnanca | Access ho do mesiaca nezahrnie; terminál ostatné mesiace ponechá a nový plán nevytvára |
| D5 | Upozornenia z pravidiel prerušení v termináli | v prvej verzii len uložiť; zobrazenie neskôr, ak to bude treba |
| D6 | Šablóny a fondy zamestnancov | spravujú sa len v Accesse; terminál ich nezobrazuje na úpravu |

## 5. Čo sa pripravilo

* **Kontrakt 1.2.0** (`contract/`): schéma, zlatý súbor s vymyslenými údajmi, referenčný výpočet plánu `tools/build_config_example.py`, overovač `tools/verify_config.py`,
  44 testov, krok v CI. Zmenu kontraktu schvaľuje vlastník repozitára.
* **Access 2.12.0** (`access/`): modul `mod_20_KonfiguraciaExport`, tlačidlá „Vytvoriť verziu konfigurácie prerušení pre terminál“ a „Exportovať konfiguráciu a testovacie dáta (JSON)“ zapisujú nový súbor (popisy tlačidiel sa nemenia). Výpočet dňa sa nemení.
  *Neoverené v skutočnom Accesse.*
* **Zadanie pre aplikačnú časť** (kapitola 9): prijatie konfigurácie, výpočet podľa nej, zobrazenie stavu plánu. Implementuje ho Claude v samostatnom PR, agent Lovable sa na tom nepodieľa.
* **Databázová časť** je súkromný SQL balík (kontrola pred, migrácia, kontrola po, návrat, postup), ktorý spúšťa vlastník ručne v SQL editore. Nie je v repozitári, lebo schému databázy
  zámerne nezverejňujeme podrobne. Ostatné kapitoly opisujú, čo terminál musí vedieť a zaručiť, nie ako sú tabuľky navrhnuté.

## 6. Postup nasadenia

1. Vlastník schváli PR s kontraktom 1.2.0 (`contract/`).
2. Nainštalovať balík Access **2.12.1 alebo novší** (`docs/VYDANIA-ACCESS.md`; 2.12.0 sa nedá skompilovať, pozri `access/CHANGELOG.md`). Karta 7 Exporty, tlačidlo **Vytvoriť verziu konfigurácie prerušení pre terminál**: vznikne `dochs_config.json` v zvolenom priečinku; správa ukáže počty zamestnancov a mesiacov.
3. Skontrolovať súbor: `python3 -I contract/tools/verify_config.py dochs_config.json` (kontroluje typy dní voči kalendáru, sviatky, počty, odkazy a že v súbore nie sú osobné údaje).
   Súbor neposielať ďalej, kým overovač nehlási „V poriadku“.
4. Potvrdiť riadky `terminal_code_map` (rozhodnutie o `FAMILY`, `PRIV`).
5. Vlastník spustí súkromný SQL balík databázovej časti (kontrola pred, migrácia, kontrola po). Potom Claude pripraví PR s kódom aplikácie (kapitola 9). Po jeho zlúčení a Publish **importujte súbor v termináli** (správca organizácie).
6. **Test zhody**: scenár október 2026 (`docs/TESTOVANIE-S-ACCESSOM.md`) s importovanou konfiguráciou. Terminál a Access majú vyjsť rovnako v `fond_min` aj `saldo_min`;
   rozdiely sa riešia podľa tabuľky v kapitole 3.
7. Až potom ostrá prevádzka. Do uzavretia mesiaca v Accesse ostáva saldo v termináli **orientačné**.

## 7. Čo je neoverené

* Celý nový kód v Accesse (VBA sa tu nedá spustiť; kontroloval sa len párovaním blokov a odkazov medzi modulmi).
* Hodnoty pre skutočné údaje (počet zamestnancov, veľkosť súboru, čas exportu). Odhad: 100 zamestnancov a 3 mesiace sú desiatky kilobajtov.
* Že `calc` vystihuje všetky prípady v skutočných údajoch (napr. prerušenie, ktoré sa v Accesse počíta inak než v `mod_08.TrvanieIntervalu`).
* Správanie terminálu: import je napísaný a otestovaný len proti zlatému súboru a lokálnej databáze (obrazovka sa v prehliadači a s databázou Lovable Cloud ešte nevyskúšala); výpočet podľa konfigurácie ešte nie je napísaný.
* Databázová časť (súkromný balík) je otestovaná len v lokálnom PostgreSQL s napodobeninou Supabase. V skutočnom Lovable Cloud sa zatiaľ nespúšťala.

## 8. Ďalšie kroky (nie sú súčasťou tejto prípravy)

* Referenčný výpočet dňa v TypeScripte podľa `mod_08.SpracujDen` s overením proti skutočným výstupom Accessu (zlatý súbor z reálneho mesiaca).
* Automatický prenos konfigurácie (HTTPS, prompt 05) po mesiaci bezproblémového súborového prenosu.
* Zobrazenie upozornení z pravidiel prerušení v termináli.
* PR s aplikačnou časťou (kapitola 9): až keď vlastník schváli kontrakt 1.2.0, spustí databázovú časť a overí prvý súbor z Accessu 2.12.0.

## 9. Zadanie pre aplikačnú časť

Pripravuje Claude v samostatných PR (nie agent Lovable). Etapa 1 (import) nasleduje po schválení kontraktu 1.2.0 a spustení databázovej časti (kapitola 5), obe sú hotové; etapa 2 (výpočet) čaká na rozhodnutie D1 a na prvý skutočný súbor z Accessu 2.12.0.
Platia `AGENTS.md` (sekcia o integrácii s Accessom) a `docs/SPOLUPRACA.md`. Návrh tabuliek tu nie je, je súčasťou súkromného SQL balíka.

**Tlačidlá na obrazovke Terminál** (rozhodnutie vlastníka 4. 11. 2026): dnes sú pevné v kóde (`src/routes/_authenticated/terminal.tsx`): Príchod, Odchod, Lekár, Sprievod, Službka, Súkromne. Dovolenka a Nemoc sú celodenné a zadávajú sa v Môj mesiac ako oprava, ktorú schváli vedúci.
Z 15 prerušení Accessu majú kód terminála len 7 (`terminal_code_map`); ostatné sa zadávajú len v Accesse.
**Rozhodnutie vlastníka (4. 11. 2026, 21:36):** tlačidlá sa mapujú podľa Accessu: prerušenie má tlačidlo, ak má v Accesse príznak, s presným textom alebo skratkou z Accessu (kontrakt 1.3.0, kľúče `terminal_button`, `terminal_label`, `terminal_order`).
Ak pravidlá z Accessu nie sú prijaté, ostávajú predvolené tlačidlá: Lekár, Sprievod, Služobná cesta, Služobné vzdialenie (nové) a Súkromne; text „Službka“ sa nahradí textom „Služobná cesta“.
Služobná cesta aj služobné vzdialenie sa môžu zapísať aj uprostred dňa (napr. o 11:00), nemusia byť celodenné. Plánovaná služobná cesta („zajtra mám služobku“) ide žiadosťou o opravu na zajtrajší deň, ktorú schváli vedúci; prerušenie bez návratu sa v Accesse dopočíta do konca smeny (č. 12 má automatický koniec smeny) a skorší Príchod ho ukončí.
Nový kód razenia pre služobné vzdialenie a čítanie tlačidiel z konfigurácie vyžadujú databázovú zmenu (súkromný SQL balík), preto sa urobia naraz s etapou 2.

**Čo má terminál vedieť** (bez osobných údajov, zamestnanec je len osobné číslo):
* verziu konfigurácie organizácie (`config_version`) a jej obsah; vždy platí **najnovšia prijatá verzia**, staršia sa neprijme;
* číselník prerušení vrátane výkladu `calc` (`WORK`, `LUNCH`, `COUNTED`), mapovanie kódov terminála na prerušenia Accessu a pravidlá (`rules`, hranica celodennej prekážky, okno práce, automatický obed);
* **plán zamestnanca na každý deň** mesiaca (`day_types`, `expected_min`, `employment_pct`) pre mesiace okna `period`;
* pravidlá prerušení po mesiacoch (`templates`) sa len uložia, upozornenia z nich zatiaľ nezobrazovať.

**Prijatie (import)**:
* smie ho spraviť len správca vlastnej organizácie. Obrazovka v Správe volá databázovú funkciu priamo pod prihlásením správcu (nie service role): o oprávnení rozhoduje databáza, nie aplikácia. Nahrá sa súbor `dochs_config.json` (alebo vložený text) a obrazovka ukáže **náhľad bez zápisu**: verziu, okno, počty zamestnancov a mesiacov, počet odstránených mesiacov, osobné čísla bez účtu v termináli, upozornenia;
* validácia v aplikácii je rovnaká ako `contract/tools/verify_config.py` (čistá funkcia v `src/lib` s testami; zlatý súbor `contract/examples/config_example.json` je vstup testu a `contract/tools/test_verify_config.py` ukazuje, čo má odmietnuť): `schema_version` 2, povolené len známe kľúče, **žiadne osobné údaje**, typ dňa zodpovedá dňu v týždni a sviatkom, fond je 0 v nepracovné dni, správne počty dní, `counts`, odkazy na prerušenia, fondy a šablóny. Databáza tú istú kontrolu opakuje, preto je aplikačná kontrola len pohodlie pre správcu;
* zápis je **atómový, všetko alebo nič**; pri chybe ostáva platná predchádzajúca konfigurácia. Do auditu sa zapíše kto, kedy, verzia a počty (nie obsah);
* osobné čísla bez účtu v termináli sa uložia (plán pre budúceho zamestnanca), ale v prehľadoch sa nezobrazujú;
* opakovaný import tej istej verzie nič nezmení; plán jedného zamestnanca a mesiaca sa nahrádza celý, nikdy po dňoch.

**Výpočet (`src/lib/engine.ts`, jediné miesto s dochádzkovou matematikou)**: ak má zamestnanec na daný deň plán z Accessu, počíta sa **tak, ako Access** (referencia `access/moduly/mod_08_UdalostiDna.bas`: `SpracujDen`, `TrvanieIntervalu`, `SumarDna`):
* práca (č. 1) sa oreže oknom práce; obed (č. 7) sa počíta skutočným trvaním; každé iné prerušenie skutočným trvaním, a ak trvá `full_day_obstacle_min` a viac, započíta sa `expected_min` dňa (`calc` rozhoduje, nie pevný zoznam kódov);
* automatický obed sa odpočíta celý (`auto_lunch_deduct_min`), keď je zapnutý, deň má fond, práca presiahne `auto_lunch_trigger_min` a v dni nebol obed;
* rovnaký kód a smer do `duplicate_punch_window_min` sa ignoruje; dopĺňanie do fondu a zaokrúhľovanie príchodu a odchodu sa pri dni s plánom **nepoužíva**;
* denné saldo = odpracované + započítané prekážky − `expected_min`; deň bez plánu (mesiac mimo okna, osobné číslo bez plánu) sa **nepočíta po starom potichu**, ale ukáže sa ako „bez plánu z Accessu, nepotvrdené“;
* neznáma hodnota `calc` alebo neznámy kód terminála = saldo dňa nepotvrdené a upozornenie pre správcu, nie odhad.

Kódy razení terminála sa menia na prerušenia cez `terminal_code_map`. Existujúce testy `engine.test.ts` ostávajú pre dni bez plánu; pribudnú testy pre deň s plánom (lekár s návratom a bez návratu, služobná cesta, dovolenka, celodenná prekážka, obed, duplicita, otvorený deň).

**Obrazovky**: v administrácii sekcia „Konfigurácia z Accessu“ (etapa 1, hotová: kontrola súboru, náhľad z databázy, prijatie, osobné čísla bez účtu v termináli; platná verzia sa ukáže v náhľade ako „Teraz platí“. Trvalé zobrazenie platnej verzie, okna a času posledného importu pri otvorení stránky by vyžadovalo čítanie tabuľky alebo samostatnú čítaciu funkciu, preto je zatiaľ vynechané, aby sa názvy tabuliek nedostali do verejného kódu); v prehľadoch salda označenie „orientačné“ (podľa integrovaného režimu) a „bez plánu z Accessu“ tam, kde plán chýba. Nikde sa nezobrazuje ID organizácie ani technické údaje. Texty z číselníkov (názvy prerušení, sviatkov, fondov) sa zobrazujú len ako text.

**Hotovo, keď**: kontraktový test s `config_example.json` je zelený; scenár október 2026 (`docs/TESTOVANIE-S-ACCESSOM.md`, postup B) s importovanou konfiguráciou dá v `fond_min` aj `saldo_min` rovnaké hodnoty ako Access (`contract/scenare/porovnaj.py`); rozdiely, ktoré ostanú, sú vypísané s dôvodom. Prejdú `bun run lint`, `bun run test`, `bun run build` a bezpečnostné kontroly z `AGENTS.md`.
