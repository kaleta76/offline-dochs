# Dochádzka – hybridný dochádzkový systém

Náhrada starej dochádzkovej aplikácie (Ordata, dáta v DBF, zastaraná knižnica) **hybridným modelom**:

* **Terminál** (tento repozitár, webová aplikácia): zbiera razenia v prehliadači na Windows 11 alebo mobile, funguje aj bez siete a **nepozná žiadne osobné údaje**, len osobné čísla SAP.
* **Dochádzkový systém** (Microsoft Access + VBA, priečinok [`access/`](access/)): beží lokálne, obsahuje mená, pracovné fondy, pravidlá prerušení, výpočet, tlač, podpis a uzávierku mesiaca a vie importovať dáta zo starého systému.
* Medzi nimi je **malý verzovaný kontrakt** v [`contract/`](contract/): CSV súbor s razeniami (pätička SHA-256, hash reťaz po zamestnancovi).
  Dochádzkový systém môže zbierať razenia aj snímačmi SKE cez sériový port (bez terminála). Modul na to je zatiaľ **len pre organizáciu vlastníka** a vo verejnom repozitári nie je.

**Živá aplikácia (terminál):** <https://offline-dochs.lovable.app> • **Úprava v Lovable:** [editor projektu](https://lovable.dev/projects/4ede2192-c080-47fb-994b-e1c0f41fb77a)

## Ako to funguje

```
 zamestnanec ──► Terminál (Lovable, Supabase)                  Access + VBA (lokálne)
                  • razenie aj offline (IndexedDB)               • mená, fondy, pravidlá prerušení
                  • iba osobné číslo SAP, bez mien               • výpočet dňa a mesiaca, anomálie
                  • serverový čas a hash reťaz                   • tlač, podpis, uzávierka mesiaca
                  • overenie zariadenia, schvaľovanie            • import zo starého systému (DBF)
                          │                                             ▲
                          └──── punches_RRRRMM.csv  (kontrakt v1) ──────┤
                          └──── voids_RRRRMM.csv    (kontrakt v1.1) ────┘
                                (zneplatnené razenia, napr. duplicity)
```

Zásady:

1. Terminál posiela len **fakty** (kto, aký kód, smer, kedy, z akého zariadenia). Mzdové a fondové výsledky pre Access nepočíta.
2. Mená neopúšťajú Access. Terminál identifikuje zamestnanca osobným číslom SAP, e-mail sa nezbiera.
3. Prenos je **idempotentný** (`external_id`) a **overiteľný** (SHA-256 pätička súboru, hash reťaz).
4. Razenie sa **nemaže**: oprava ide novým razením cez schválenú korekciu, duplicita sa zneplatní schválenou žiadosťou ([`docs/ZNEPLATNENIE-RAZENI.md`](docs/ZNEPLATNENIE-RAZENI.md)).

## Čo terminál robí

* Virtuálny terminál (príchod, odchod, lekár, služobná cesta, súkromné prerušenie …) s offline frontou a synchronizáciou po pripojení; PWA.
* Overenie zariadení (párovací kód, schválenie, zrušenie, záchranný kód, náhrada) a audit.
* Môj mesiac, Môj tím (korekcie, schvaľovanie, uzávierka), výkaz A4 na podpis, administrácia (nastavenia, číselník, sviatky, export do SAP .xlsx).
* Registrácia firiem a zamestnancov bez e-mailu: stály registračný kód od vlastníka, jednorazový PIN od správcu ([`docs/REGISTRACIA.md`](docs/REGISTRACIA.md)).
* **Export razení pre Access** a **zoznam zneplatnených razení** (Administrácia → Export).
* **Testovacia prevádzka**: import razení z CSV a stiahnutie sald na porovnanie s Accessom ([`docs/TESTOVANIE-S-ACCESSOM.md`](docs/TESTOVANIE-S-ACCESSOM.md)).

## Čo robí dochádzkový systém (Access)

Import razení z terminála (overenie pätičky a reťaze, mapovanie kódov na prerušenia, párovanie príchod/odchod), import zneplatnených razení, editor dochádzky, automatické opravy,
pracovné fondy a pravidlá „platné od mesiaca“, uzávierka mesiaca, synchronizácia zamestnancov z Active Directory, import zo starého systému (DBF) a z predchádzajúcej verzie databázy,
komunikácia so snímačmi SKE cez sériový port (tento modul nie je vo verejnom repozitári). Inštalácia a obsah: [`access/README.md`](access/README.md).

## Štruktúra repozitára

| Cesta | Obsah |
|---|---|
| `src/` | terminál: React + TanStack Start, výpočtový motor `src/lib/engine.ts`, offline fronta, export pre Access |
| `drizzle/migrations/` | migrácie databázy terminála `0000`–`0006` (aplikuje ich Lovable) |
| `docs/migracie/` | texty migrácií a záchranné skripty (`0006` zneplatnenie razení je spustená, `0007` zrušenie testovacej organizácie čaká na spustenie) |
| `docs/zaloha/` | SQL na snapshot databázy pred zásahom a na porovnanie po ňom |
| `tools/` | kontroly balíka Access a zálohy databázy, `tools/sql_test/` = lokálny test SQL migrácií na PostgreSQL |
| `contract/` | **kontrakt terminál ⇄ Access**: popis, zlaté súbory, referenčná implementácia, testy, overovač, testovacie scenáre. Mení sa iba cez PR so schválením vlastníka |
| `access/` | dochádzkový systém v Accesse: inštalátor, moduly VBA, testy |
| `docs/` | spolupráca, registrácia, kredity v Lovable, testovanie, zneplatnenie razení |
| `prompts/`, `AGENTS.md` | pokyny pre agentov (Lovable, Claude) |
| `.github/` | CI (lint a testy kontraktu, build, kontrola tajných hodnôt) |

## Vývoj a testy terminála

Projekt používa [Bun](https://bun.sh).

```sh
bun install
bun run dev        # vývojový server
bun run test       # testy (vrátane kontraktových v contract/tests)
bun run lint
bun run build
```

CI na GitHube (`.github/workflows/ci.yml`) spúšťa po každom PR a pushi do `main` lint kontraktu, typovú kontrolu súborov registrácie, testy, build, overenie zlatého súboru exportu a kontrolu,
že v repozitári nie sú tajné hodnoty (`.env` smie obsahovať len verejné kľúče).

## Nasadenie a Lovable

* Zmeny v `main` sa synchronizujú do Lovable a po **Publish** sú na živej adrese. História sa neprepisuje (žiadny force-push, rebase ani squash publikovaných commitov).
* **Migrácie databázy sa spúšťajú cez chat v Lovable (približne 1 kredit), nie z CI.** Migráciu treba spustiť **pred** Publish kódu, ktorý ju používa, inak sa príslušné obrazovky pokazia.
  Postup a kredity: [`docs/LOVABLE-KREDITY.md`](docs/LOVABLE-KREDITY.md).
* Kód zmenený mimo Lovable (napríklad cez PR) kredity nespotrebuje.

## Dokumentácia

| Dokument | O čom |
|---|---|
| [`contract/README.md`](contract/README.md) | formát `punches_*.csv` a `voids_*.csv`, hash reťaz, pravidlá importu |
| [`docs/SPOLUPRACA.md`](docs/SPOLUPRACA.md) | rozdelenie rolí terminál / Access / vlastník, zistenia, rozhodnutia |
| [`docs/ZNEPLATNENIE-RAZENI.md`](docs/ZNEPLATNENIE-RAZENI.md) | žiadosť o zneplatnenie duplicity, schválenie, prenos do Accessu, poradie nasadenia |
| [`docs/TESTOVANIE-S-ACCESSOM.md`](docs/TESTOVANIE-S-ACCESSOM.md) | scenár na celý mesiac a porovnanie sald terminál / Access |
| [`docs/REGISTRACIA.md`](docs/REGISTRACIA.md) | registrácia firiem a zamestnancov bez e-mailu |
| [`docs/OVERENIE-ZARIADENI.md`](docs/OVERENIE-ZARIADENI.md) | čo overenie zariadenia zaručuje a čo nie, neoverené razenia, záchranný kód, zmeny zariadení |
| [`docs/LOVABLE-KREDITY.md`](docs/LOVABLE-KREDITY.md) | čo míňa kredity, synchronizácia s GitHubom |
| [`docs/ZACHRANA-A-NAVRAT.md`](docs/ZACHRANA-A-NAVRAT.md) | návrat k bezpečnému stavu: kód, databáza, záchranné skripty k migráciám 0006 a 0007 |
| [`docs/ZALOHA-DATABAZY.md`](docs/ZALOHA-DATABAZY.md) | záloha a návrat databázy v Lovable Cloud: Export, overenie súboru, snapshot pred zásahom |
| [`docs/ZRUSENIE-TESTOVACEJ-ORGANIZACIE.md`](docs/ZRUSENIE-TESTOVACEJ-ORGANIZACIE.md) | označenie a zrušenie testovacej organizácie správcom, ručné zrušenie |
| [`access/README.md`](access/README.md), [`access/CHANGELOG.md`](access/CHANGELOG.md) | inštalácia a zmeny dochádzkového systému v Accesse |
| [`roadmap.md`](roadmap.md) | hotové a otvorené úlohy |

## Stav a čo nie je overené

Projekt je **prototyp v testovacej prevádzke**. Súčasti, ktoré som neoveril spustením v ostrom prostredí:

* Kód VBA v Accesse sa nedá spustiť mimo Accessu; overené sú iba lint, modely algoritmov a kontrakt na zlatých súboroch.
* Test, že **terminál a Access vyjdú v saldách rovnako** (scenár október 2026), ešte nebol spustený v živom prostredí.
* Migrácia `0006` (zneplatnenie razení) je v databáze spustená od 3. 11. 2026. Migrácia `docs/migracie/0007_zrusenie_testovacej_organizacie.sql` (zrušenie testovacej organizácie) je overená lokálne na PostgreSQL, na ostrej databáze ešte nie.
* Mapovanie niektorých kódov terminála na prerušenia Accessu (služobná cesta, súkromné prerušenie, ošetrenie člena rodiny) čaká na rozhodnutie vlastníka (`contract/code-mapping.csv`).

## Bezpečnosť a súkromie

Repozitár je **verejný**. Nepatria doň mená zamestnancov, e-maily, heslá, tajné serverové kľúče ani databázy `.accdb`. Súbor `.env` obsahuje len verejné hodnoty (adresa a verejný kľúč backendu);
CI to kontroluje. Testovacie údaje (osobné čísla 9000001 až 9000099) sú vymyslené.

## Podpora a kontakt

Projekt vzniká bez dotácie a vo voľnom čase. Ak ho chcete podporiť, môžete poslať dar cez [PayPal](https://www.paypal.me/kaleta7) (tlačidlo **Sponsor** v hornej časti repozitára vedie na ten istý odkaz).
Dar nezakladá nárok na funkcie, podporu ani záruku. Aplikácia je prototyp v testovacej prevádzke.

Na sponzoring, spoluprácu, nápady alebo chyby napíšte cez [Issues](https://github.com/kaleta76/offline-dochs/issues). Zápis je verejný, preto v ňom neuvádzajte osobné údaje, skutočné osobné čísla ani prístupové údaje.
