# Dochádzkový systém (Microsoft Access + VBA) – inštalátor

Lokálna časť hybridného systému **Dochádzka**: tu sú mená zamestnancov, pracovné fondy, pravidlá prerušení, výpočet mesiaca, tlač, podpis a uzávierka mesiaca.
Terminál (webová aplikácia v koreňovom `src/`) pozná len osobné čísla SAP a posiela sem razenia súborom podľa kontraktu v `../contract/`.
Prehľad celého projektu je v [koreňovom README](../README.md).

## Čo tu je
| Cesta | Obsah |
|---|---|
| `Instaluj.cmd`, `Instaluj-Dochadzku.ps1` | inštalátor: vytvorí alebo aktualizuje databázu `.accdb`, overí SHA-256 modulov podľa `manifest.json`, importuje moduly VBA, skompiluje a inicializuje |
| `moduly/*.bas` | zdrojový kód VBA (každý modul má na 2. riadku `'@Verzia X.Y.Z`) |
| `manifest.json` | verzia balíka a SHA-256 každého modulu |
| `README.txt` | podrobný návod na inštaláciu, parametre inštalátora, import zo starej verzie |
| `CHANGELOG.md` | zmeny podľa balíkov |
| `testy/terminal/` | vymyslené testovacie dáta a postupy na test spolupráce s terminálom (bez osobných údajov) |
| `tools/zostav_balik.py` | kontrola verzií modulov, zápis `manifest.json` a zostavenie ZIP |

## Ako to nainštalovať
1. Stiahnite repozitár (**Code → Download ZIP**) alebo ho naklonujte a použite priečinok `access/`. Súbory sa nesmú meniť (konverzia koncov riadkov rozbije kontrolu SHA-256, preto je v tomto priečinku `.gitattributes` s `-text`).
2. Postupujte podľa [`README.txt`](README.txt): do priečinka s inštalátorom dajte doterajšiu databázu dochádzky (ak nejakú máte) a spustite `Instaluj.cmd`.
3. Potrebujete Windows a plnú verziu Microsoft Access 2010 alebo novšiu (Access Runtime nestačí, nemá editor VBA).

Nový ZIP balíka (pre ďalší počítač) vytvoríte v priečinku `access/` príkazom `python tools/zostav_balik.py --zip`.

## Čo tu zámerne nie je
Modul komunikácie so snímačmi SKE cez sériový port sa vo verejnom repozitári zatiaľ nezverejňuje (rozhodnutie vlastníka). `manifest.json` ho preto neobsahuje a **inštalátor ho nijako neodstraňuje**
z databázy, v ktorej už je. Ostatné moduly ho nepotrebujú. Súbor `moduly/mod_07_SKE.bas` je v `.gitignore` tohto priečinka, aby sa pri kopírovaní nového balíka sem omylom nepridal.
Balík, ktorý dostáva organizácia vlastníka, ho obsahuje, takže čísla verzií balíka sa oboch zostáv zhodujú, no verejná zostava má o modul menej.

## Čo je overené
Kód VBA sa **nedá spustiť mimo Accessu**, takže ho nemám otestovaný v živom prostredí. Kontrolovali sa: lint (párovanie blokov, krížové odkazy medzi modulmi), model algoritmov v Pythone
(SHA-256, párovanie razení, hash reťaz) a kontrakt na zlatých súboroch. Čo konkrétne je a nie je overené, je pri každom balíku v [`CHANGELOG.md`](CHANGELOG.md).
Pri chybe pošlite text chyby s názvom procedúry a súbory `instalacia_*.log` alebo `terminal_test_report.txt`.

## Čo sem nepatrí
Databáza `.accdb`, zálohy, protokoly inštalácie a skutočné osobné údaje. Repozitár je verejný.
