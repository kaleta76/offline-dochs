# Konfigurácia a výpočtový plán z Accessu do terminálu

Otázka vlastníka (4. 11. 2026): *prerušenia, ich parametre a všetko potrebné pre výpočet by sa malo dať exportovať z Accessu; je na to pripravený dátový model?*

**Odpoveď: nebol.** Tento dokument opisuje, čo chýbalo, čo sa pripravilo (kontrakt 1.2.0, balík Access 2.12.0, zadanie pre agenta v Lovable),
aké rozdiely vo výpočte treba rozhodnúť a v akom poradí to nasadiť. Je to **príprava**: terminál konfiguráciu zatiaľ neprijíma.

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
| Obed | automaticky sa odpočíta celých 30 min, ak práca presiahne 6 h a v dni nebol obed (č. 7) | odpočíta najviac 30 min a len prebytok nad 6 h (6 h 10 min práce = 10 min) |
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
* **Zadanie pre agenta v Lovable** (`prompts/06-konfiguracia-z-accessu.md`): prijatie a uloženie konfigurácie, výpočet podľa nej, zobrazenie stavu plánu. Schému databázy tu
  **zámerne nezverejňujeme podrobne**: prompt opisuje, čo terminál musí vedieť a zaručiť, a návrh tabuliek a politík vypracuje agent v `drizzle/`.

## 6. Postup nasadenia

1. Vlastník schváli PR s kontraktom 1.2.0 (`contract/`).
2. Nainštalovať balík Access 2.12.0 (`docs/VYDANIA-ACCESS.md`). Karta 7 Exporty, tlačidlo **Vytvoriť verziu konfigurácie prerušení pre terminál**: vznikne `dochs_config.json` v zvolenom priečinku; správa ukáže počty zamestnancov a mesiacov.
3. Skontrolovať súbor: `python3 -I contract/tools/verify_config.py dochs_config.json` (kontroluje typy dní voči kalendáru, sviatky, počty, odkazy a že v súbore nie sú osobné údaje).
   Súbor neposielať ďalej, kým overovač nehlási „V poriadku“.
4. Potvrdiť riadky `terminal_code_map` (rozhodnutie o `FAMILY`, `PRIV`).
5. Vložiť prompt 06 agentovi v Lovable a po jeho dokončení **importovať súbor v termináli** (správca organizácie).
6. **Test zhody**: scenár október 2026 (`docs/TESTOVANIE-S-ACCESSOM.md`) s importovanou konfiguráciou. Terminál a Access majú vyjsť rovnako v `fond_min` aj `saldo_min`;
   rozdiely sa riešia podľa tabuľky v kapitole 3.
7. Až potom ostrá prevádzka. Do uzavretia mesiaca v Accesse ostáva saldo v termináli **orientačné**.

## 7. Čo je neoverené

* Celý nový kód v Accesse (VBA sa tu nedá spustiť; kontroloval sa len párovaním blokov a odkazov medzi modulmi).
* Hodnoty pre skutočné údaje (počet zamestnancov, veľkosť súboru, čas exportu). Odhad: 100 zamestnancov a 3 mesiace sú desiatky kilobajtov.
* Že `calc` vystihuje všetky prípady v skutočných údajoch (napr. prerušenie, ktoré sa v Accesse počíta inak než v `mod_08.TrvanieIntervalu`).
* Správanie terminálu: import a výpočet podľa konfigurácie ešte nie sú napísané.

## 8. Ďalšie kroky (nie sú súčasťou tejto prípravy)

* Referenčný výpočet dňa v TypeScripte podľa `mod_08.SpracujDen` s overením proti skutočným výstupom Accessu (zlatý súbor z reálneho mesiaca).
* Automatický prenos konfigurácie (HTTPS, prompt 05) po mesiaci bezproblémového súborového prenosu.
* Zobrazenie upozornení z pravidiel prerušení v termináli.
