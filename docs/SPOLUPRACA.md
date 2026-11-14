# Spolupráca: Access (Claude) ⇄ terminál (Lovable agent) ⇄ vlastník

Stav: návrh v1 • autor: Claude (strana Access) • dátum: 2026-11-03
Repozitár terminála: https://github.com/kaleta76/offline-dochs (verejný, vetva `main`, 69 commitov, väčšina od `gpt-engineer-app[bot]`)

## 1. Zhrnutie v piatich vetách
1. Terminál (Lovable) je **zberač razení**: offline fronta, overenie zariadenia, pseudonymné osobné čísla SAP, hash reťaz. Je to presne tá časť, ktorú Access nemá a nemá ju duplikovať.
2. Access ostáva **systémom záznamov**: mená, pracovné fondy, pravidlá prerušení, výpočet, tlač, podpis a uzávierka mesiaca.
3. Medzi nimi je **jeden malý, verzovaný kontrakt** (priečinok `contract/`): CSV export razení s pätičkou SHA-256 a hash reťazou. Začíname **súborom** (žiadna sieť, žiadny problém s antivírom), HTTPS pull až keď súbor funguje.
4. Obaja agenti pracujú **v tom istom repozitári, ale v oddelených priečinkoch**: Claude v `contract/`, `docs/`, `.github/`; Lovable agent v `src/`, `drizzle/`. Zmenu kontraktu schvaľuje vlastník.
5. Najväčší problém nie je technický, ale **duplicita**: terminál má vlastný výpočet mesiaca, uzávierku, korekcie aj SAP export. Treba rozhodnúť, čo z toho sa v integrovanom režime vypne alebo označí ako orientačné (kap. 9).

## 2. Čo je overené a čo nie
Overené:
* Prečítal som celý zip aj klon GitHubu (identické, `main`), README, AGENTS.md, roadmap, plány, `src/lib/*`, trasy, migrácie `0000–0005`.
* Vzorec hash reťaze z triggera `punches_chain` som porovnal s **reálnym výrazom v PostgreSQL 16** (2 záznamy, s aj bez `device_id`) – hash sedí.
* Referenčný export v TypeScripte vyrobí **bajt po bajte rovnaký súbor** ako generátor v Pythone (zlatý súbor `contract/examples/punches_example.csv`); overovač `tools/verify_export.py` prejde na originále a zlyhá na upravenom.

Neoverené / nespravené:
* Aplikáciu terminála som nespúšťal (nemám prístup na Lovable ani do jeho databázy), nevidel som reálne dáta ani nasadenú verziu.
* Kontraktový test som spustil cez **minimálnu náhradu Vitestu** (npm register z tohto prostredia nie je dostupný); v repozitári pobeží pod skutočným Vitestom a treba to potvrdiť v CI.
* Nič som **nepushol** na GitHub (nemám zapisovacie právo) – všetko je v priloženom balíku, ktorý skopírujete do repozitára.
* Importný modul na strane Accessu (`mod_19_TerminalImport`) ešte nie je napísaný – je to ďalší krok po schválení kontraktu. Access kód som, ako zvyčajne, nemohol skúsiť v reálnom Accesse.

## 3. Zistenia o repozitári
Silné stránky: idempotentné razenie (`client_uuid`), hash reťaz po používateľovi, overenie zariadenia, pseudonymizácia (SAP číslo, syntetický e-mail zamestnanca), RLS + security-definer funkcie, testy výpočtu, PWA s offline frontou.

| # | Priorita | Zistenie | Odporúčanie |
|---|---|---|---|
| 1 | vysoká | **Duplicita logiky**: `engine.ts`, „Môj mesiac“, korekcie, uzávierka (`month_closures`), SAP export (exceljs) v administrácii | rozhodnúť rolu terminála v integrovanom režime (kap. 9) |
| 2 | vysoká | Trigger `punches_chain` pri uzavretom mesiaci hodí `Mesiac je uzavretý` – **razenie sa odmietne**. Offline fronta by ho opakovane odosielala/zahodila | v integrovanom režime nepoužívať uzávierku v terminále; razenie je fakt a vždy sa prijme, o uzavretí rozhoduje Access (`TerminalInbox` stav `UZAVRETY`) |
| 3 | vysoká | **Verejný repozitár + otvorená registrácia organizácie** (`handle_new_user`: ktokoľvek zadá názov firmy a vznikne organizácia s rolou admin) | registráciu organizácií v produkcii vypnúť/obmedziť (pozvánka od vlastníka); skontrolovať Supabase Auth nastavenia |
| 4 | stredná | `.env` je v gite. Obsahuje len 6 kľúčov (`SUPABASE_URL`, `*_PUBLISHABLE_KEY`, `*_PROJECT_ID`) – to sú verejné hodnoty, **ale** súbor tam nepatrí a raz tam skončí niečo tajné | `.env` do `.gitignore`, `git rm --cached`; tajné hodnoty len v Lovable/Supabase secrets; v CI kontrola `service_role` v repozitári |
| 5 | stredná | Žiadne CI; Lovable commituje priamo do `main` | CI (lint, test, build, kontraktový test) beží po každom pushi; od 13. 11. 2026 má Lovable vlastnú vetvu `lovable` a `main` je chránená (zmeny len cez PR), pozri [`LOVABLE-VETVY.md`](LOVABLE-VETVY.md) |
| 6 | stredná | Migrácie aplikuje Lovable, nie CLI; schéma v `drizzle/schema.ts` je prázdna | zmeny schémy, ktoré sa týkajú `punches`/`profiles`, musia v PR explicitne opísať dopad na kontrakt |
| 7 | nízka | Pri aktivácii účtu sa dá zadať voliteľný vlastný e-mail (`accounts.functions.ts`) – to je osobný údaj | v integrovanom režime políčko skryť, ostať pri syntetickom e-maile |
| 8 | nízka | Čas: `client_time` je z hodinky zariadenia (zachytáva sa `drift_minutes`), mesiac sa určuje v `Europe/Bratislava` | kontrakt nesie UTC aj lokálny čas; Access ukladá lokálny čas a pri zhode vyhodnotí podľa UTC |

## 4. Hranica zodpovednosti
| Oblasť | Terminál (Lovable) | Access (Claude) |
|---|---|---|
| Zachytenie razenia, offline, deduplikácia pri príjme | ✔ vlastní | – |
| Overenie zariadenia, schválenie neoverených | ✔ vlastní | zobrazí príznak |
| Identita | SAP číslo + pseudonymný účet | mená, mapovanie SAP ↔ OsobneCislo (`TerminalMapaOsob`) |
| Kódy razení | `code` + `direction` | `code-mapping.csv` → `KodyRazeni` (Ordata) |
| Pracovný fond, pravidlá prerušení, nadčasy | – (len orientačný náhľad) | ✔ vlastní (verzované „platné od mesiaca“) |
| Výpočet dochádzky a bilancie | orientačný (`engine.ts`) | ✔ záväzný |
| Korekcie | žiadosť zamestnanca / schválenie vedúcim → razenie `source=correction` | úprava v editore dňa, audit |
| Tlač, podpis, **uzávierka mesiaca** | – (v integrovanom režime vypnúť) | ✔ vlastní (verzia 2.9.0) |
| SAP export | rozhodnúť (kap. 9) | kandidát na jediný zdroj |

## 5. Tok dát
```
 zamestnanec ──▶ terminál (PWA, offline fronta) ──▶ Lovable Cloud (Postgres, hash reťaz)
                                                         │  správca: „Export pre Access“
                                                         ▼
                                           punches_YYYYMM.csv  (+ pätička SHA-256)
                                                         │  Fáza A: súbor (USB / zdieľaný priečinok / e-mail)
                                                         │  Fáza B: HTTPS pull s tokenom (voliteľne)
                                                         ▼
 Access: Import z terminálu → kontrola pätičky a reťaze → TerminalInbox → mapovanie ID a kódov
        → deduplikácia (ExterneID) → DochadzkaImport → výpočet → tlač → uzávierka
```
Prečo súbor ako prvá fáza: Access nemá prichádzajúce spojenie (len ťahá), firemný antivírus/EDR často blokuje makrá s HTTP, a súbor sa dá skontrolovať okom a archivovať. HTTPS pull pridáme, až keď je kontrakt stabilný.

## 6. Kľúčové pravidlá kontraktu (podrobne: `contract/README.md`)
1. **Identita:** `personnel_number` je text s možnými vedúcimi nulami; Access porovnáva po odstránení nulí a drží mapovaciu tabuľku (predvolene identita).
2. **Čas:** `client_time_utc` je záväzný, `client_time_local` je pre ľudí. Pri prechode na zimný čas existuje lokálny čas 02:30 dvakrát – preto rozhoduje UTC.
3. **Kódy sú kontextové:** terminál má `code + direction`, Ordata má *prerušenie č. + začiatok/koniec (Z/K)*. `X/OUT` začína prerušenie X, nasledujúce `WORK/IN` ho končí. Importér to páruje po zamestnancovi a dni; nespárované razenie ide do stavu `CHYBA` s textom, nič sa nestráca.
4. **Duplicity:** `external_id` (= `client_uuid`) → `DochadzkaImport.ExterneID`; opakovaný import je bezpečný.
5. **Prírastok:** kurzor `punch_id`; Access žiada s prekrytím (posledných 500 id), lebo `bigserial` môže byť zverejnený mimo poradia.
6. **Reťaz:** Access prepočíta `record_hash` a overí, že reťaz používateľa nadväzuje na posledný známy hash. Pri zlyhaní import zastaví a nahlási konkrétny `punch_id`.
7. **Uzavretý mesiac v Accesse:** razenie ide do `TerminalInbox` ako `UZAVRETY`, po otvorení mesiaca sa spracuje (už implementované v `mod_12`/`mod_18`).
8. **Neoverené zariadenie:** importuje sa s príznakom; potvrdenie robí vedúci v terminále a príde ako zmena `device_verification` pri ďalšom exporte (importér aktualizuje príznak, nie razenie).
9. **Neskoré razenia** (`drift_minutes` veľké): importujú sa normálne; ak patria do uzavretého mesiaca, platí bod 7.

## 7. Ako spolupracujú dvaja agenti
**Princíp:** každý vlastní svoje súbory, spoločné je len `contract/`. Komunikácia ide cez **issues a PR**, nie cez „zadné vrátka“ do cudzieho kódu.

| Kto | Smie meniť | Nesmie meniť |
|---|---|---|
| Lovable agent | `src/`, `drizzle/`, `public/`, `package.json` | `contract/` (iba na výslovný pokyn vlastníka), vzorec `punches_chain` |
| Claude | `contract/`, `docs/`, `.github/`, ukážkové dáta, prompty | `src/`, `drizzle/` – tu iba navrhuje cez prompt/issue |
| Vlastník (vy) | všetko, schvaľuje PR do `contract/` | – |

Postup pri zmene:
1. **Potreba z Accessu** (napr. nové pole) → Claude otvorí PR zmeny `contract/` (README, schéma, zlatý súbor, test) s verziou (`1.1`) a pripraví **prompt pre Lovable** v `prompts/`.
2. Vlastník PR zlúči, vloží prompt do Lovable. Lovable zmení `src/` tak, aby kontraktový test prešiel, a commitne (obojsmerná synchronizácia).
3. CI skontroluje test a lint; Claude upraví importér a zlatý súbor použije ako vstup testu v Accesse.
4. Tag `contract-v1.1.0`; Access importér zapíše do logu, ktorú verziu kontraktu videl.

Pravidlá pre vetvy (od 13. 11. 2026, podrobne v [`LOVABLE-VETVY.md`](LOVABLE-VETVY.md)): Lovable píše do vlastnej vetvy `lovable`, `main` je chránená a ide do nej všetko cez PR (Claude pracuje vo vetvách z `main`, napr. `fix/<téma>`); do Lovable sa zmeny dostanú PR `main` → `lovable`. **Nerobiť force-push ani prepisovať históriu** (AGENTS.md to už zakazuje). K ochrane `main` pristupuje aj CI + `CODEOWNERS` pre `contract/**`.

Definícia hotového (pre obe strany): lint a testy zelené, kontraktový test zelený, zmena kontraktu má verziu a záznam v `contract/CHANGELOG.md`, v PR je napísané, čo sa nevyskúšalo.

Testovacie prostredie: **samostatná testovacia organizácia** v Lovable (fiktívne SAP čísla 9000001–9000010), nikdy nie produkčné dáta. Zlatý súbor v repozitári obsahuje len vymyslené UUID a čísla.

## 8. Bezpečnosť verejného repozitára
* Do repozitára nepatrí nič, čo sa viaže na skutočné osoby: mená, reálne SAP čísla, e-maily, export z produkcie. `.gitignore`: `.env*`, `*.accdb`, `punches_*.csv` mimo `contract/examples/`.
* CI krok „no-secrets“ hľadá `service_role`, `BEGIN PRIVATE KEY`, `eyJ…` JWT s rolou `service_role`.
* Registráciu organizácie obmedziť (kap. 3, bod 3). Pull token (fáza B) uložiť len ako hash, s rotáciou a zápisom do `audit_log`.
* Export (`Export pre Access`) smie spustiť len admin danej organizácie; každý export sa zapíše do `audit_log`.

## 9. Rozhodnutia, ktoré potrebujem od vás
| # | Otázka | Odporúčanie |
|---|---|---|
| 1 | Má v integrovanom režime ostať v terminále **uzávierka mesiaca**? | Nie. Jediná uzávierka je podpísaná zostava v Accesse; terminál razenia vždy prijme. |
| 2 | **Korekcie** (žiadosť → schválenie vedúcim): ostávajú v terminále alebo len v Accesse? | Ostať v terminále (vedúci ich vidí hneď), do Accessu idú ako `source=correction`; Access ich zobrazí v audite. |
| 3 | **SAP export** v terminále | Nechať vypnutý/„orientačný“; záväzný export z Accessu po uzávierke. |
| 4 | **Náhľad „Môj mesiac“** pre zamestnanca | Ponechať s popiskom „orientačné, záväzný výpočet je v dochádzkovom systéme“; fondy do terminála neposielať (fáza C, voliteľne). |
| 5 | Prenos: iba súbor, alebo aj HTTPS pull? | Najprv súbor (fáza A), pull až po mesiaci bez problémov. |
| 6 | Dať mi **zapisovacie právo** na repozitár (pre PR z vetiev `claude/*`)? | Áno – cez pripojenie repozitára s právom push; inak ostáva balík, ktorý skopírujete vy. |
| 7 | Mapovanie kódov (`code-mapping.csv`) | Doplniť čísla prerušení z vášho Číselníka prerušení (v súbore sú označené `<doplniť>`). |

## 10. Plán krokov
| Krok | Kto | Výsledok |
|---|---|---|
| 0 | vlastník | Rozhodnutia z kap. 9 |
| 1 | vlastník + Claude | Skopírovať balík do repozitára, PR `claude/kontrakt-v1`, zlúčiť |
| 2 | Lovable (prompt 02) | CI + presun referenčného exportu do `src/lib/punch-export.ts`, kontraktový test zelený |
| 3 | Lovable (prompt 01) | Tlačidlo „Export pre Access“ (admin) – súbor presne podľa kontraktu |
| 4 | Lovable (prompt 03) | Bezpečnostné úpravy (`.env`, registrácia, e-mail) |
| 5 | Lovable (prompt 04) | Integrovaný režim: vypnutá uzávierka, popisky „orientačné“ |
| 6 | Claude | Access 2.10: `mod_19_TerminalImport` + okno „Import z terminálu“ na karte 6, tabuľka `TerminalMapaOsob`, mapovanie kódov, testy na zlatom súbore |
| 7 | spolu | Pilot jeden mesiac: paralelne starý systém a nový, porovnanie |
| 8 | voliteľne (prompt 05) | HTTPS pull s tokenom; fáza C – posielanie fondov a sviatkov do terminála |
