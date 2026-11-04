(Použiť až po schválení kontraktu 1.2.0 vlastníkom a po overení prvého súboru `dochs_config.json` z Accessu 2.12.0.)

Prečítaj si `AGENTS.md` (sekcia „Integrácia s dochádzkovým systémom“), `contract/README.md` (sekcia o `dochs_config.json`), `docs/KONFIGURACIA-Z-ACCESSU.md` a `docs/SPOLUPRACA.md`. Potom zaveď **prijatie konfigurácie a výpočtového plánu z Accessu** a nechaj saldo počítať podľa nej. Najprv mi stručne napíš plán (čo sa mení v databáze a v `engine.ts`) a počkaj na potvrdenie; návrh tabuliek, politík a funkcií vypracuj ty, v repozitári ho nerozpisuj ďalej, než je nutné.

**Čo má terminál vedieť** (bez osobných údajov, zamestnanec je len osobné číslo):
* verziu konfigurácie organizácie (`config_version`) a jej obsah; vždy platí **najnovšia prijatá verzia**, staršia sa neprijme;
* číselník prerušení vrátane výkladu `calc` (`WORK`, `LUNCH`, `COUNTED`), mapovanie kódov terminála na prerušenia Accessu a pravidlá (`rules`, hranica celodennej prekážky, okno práce, automatický obed);
* **plán zamestnanca na každý deň** mesiaca (`day_types`, `expected_min`, `employment_pct`) pre mesiace okna `period`;
* pravidlá prerušení po mesiacoch (`templates`) sa len uložia, upozornenia z nich zatiaľ nezobrazuj.

**Prijatie (import)**:
* smie ho spraviť len správca vlastnej organizácie, cez server funkciu s kontrolou oprávnenia a organizácie (RLS, nie service role). Nahrá sa súbor `dochs_config.json` (alebo vložený text) a UI ukáže **náhľad bez zápisu**: verziu, okno, počty zamestnancov a mesiacov, osobné čísla bez účtu v termináli, upozornenia;
* validácia je rovnaká ako `contract/tools/verify_config.py` (prenes ju do `src/lib` ako čistú funkciu s testami; zlatý súbor `contract/examples/config_example.json` je vstup testu a `contract/tools/test_verify_config.py` ukazuje, čo má odmietnuť): `schema_version` 2, povolené len známe kľúče, **žiadne osobné údaje**, typ dňa zodpovedá dňu v týždni a sviatkom, fond je 0 v nepracovné dni, správne počty dní, `counts`, odkazy na prerušenia, fondy a šablóny;
* zápis je **atómový, všetko alebo nič**; pri chybe ostáva platná predchádzajúca konfigurácia. Do auditu sa zapíše kto, kedy, verzia a počty (nie obsah);
* osobné čísla bez účtu v termináli sa uložia (plán pre budúceho zamestnanca), ale v prehľadoch sa nezobrazujú;
* opakovaný import tej istej verzie nič nezmení; plán jedného zamestnanca a mesiaca sa nahrádza celý, nikdy po dňoch.

**Výpočet (`src/lib/engine.ts`, jediné miesto s dochádzkovou matematikou)**: ak má zamestnanec na daný deň plán z Accessu, počítaj **tak, ako Access** (referencia `access/moduly/mod_08_UdalostiDna.bas`: `SpracujDen`, `TrvanieIntervalu`, `SumarDna`):
* práca (č. 1) sa oreže oknom práce; obed (č. 7) sa počíta skutočným trvaním; každé iné prerušenie skutočným trvaním, a ak trvá `full_day_obstacle_min` a viac, započíta sa `expected_min` dňa (`calc` rozhoduje, nie pevný zoznam kódov);
* automatický obed sa odpočíta celý (`auto_lunch_deduct_min`), keď je zapnutý, deň má fond, práca presiahne `auto_lunch_trigger_min` a v dni nebol obed;
* rovnaký kód a smer do `duplicate_punch_window_min` sa ignoruje; dopĺňanie do fondu a zaokrúhľovanie príchodu a odchodu sa pri dni s plánom **nepoužíva**;
* denné saldo = odpracované + započítané prekážky − `expected_min`; deň bez plánu (mesiac mimo okna, osobné číslo bez plánu) sa **nepočíta po starom potichu**, ale ukáže sa ako „bez plánu z Accessu, nepotvrdené“;
* neznáma hodnota `calc` alebo neznámy kód terminála = saldo dňa nepotvrdené a upozornenie pre správcu, nie odhad.
Kódy razení terminála preveď na prerušenia cez `terminal_code_map`. Existujúce testy `engine.test.ts` ostávajú pre dni bez plánu; pridaj testy pre deň s plánom (lekár s návratom a bez návratu, služobná cesta, dovolenka, celodenná prekážka, obed, duplicita, otvorený deň).

**UI**: v administrácii sekcia „Konfigurácia z Accessu“ (import s náhľadom, aktuálna verzia, okno, kedy a kto naposledy importoval, počet zamestnancov bez plánu); v prehľadoch salda označenie „orientačné“ (podľa integrovaného režimu) a „bez plánu z Accessu“ tam, kde plán chýba. Nikde nezobrazuj ID organizácie ani technické údaje.

**Prijatie hotovo, keď**: kontraktový test s `config_example.json` je zelený; scenár október 2026 (`docs/TESTOVANIE-S-ACCESSOM.md`, postup B) s importovanou konfiguráciou dá v `fond_min` aj `saldo_min` rovnaké hodnoty ako Access (`contract/scenare/porovnaj.py`); rozdiely, ktoré ostanú, vypíš v odpovedi s dôvodom. Spusti `bun run lint`, `bun run test`, `bun run build` a bezpečnostné kontroly z `AGENTS.md`.
