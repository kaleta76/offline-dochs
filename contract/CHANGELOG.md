# Zmeny kontraktu
## 1.0.0 – 2026-11-03
* Prvá verzia: CSV export razení (`punches_YYYYMM.csv`), pätička `#END` so SHA-256, hash reťaz po používateľovi.
* Zlatý súbor `examples/punches_example.csv`, vstup `examples/punches_example.input.json`, schéma `punch-export.schema.json`.
* Referenčná implementácia `reference/punch-export.ts`, kontraktový test `tests/punch-export.contract.test.ts`, overovač `tools/verify_export.py`.

## 1.0.1 – 2026-11-03 (spresnenie, formát súboru sa nemení)
* Prvý skutočný export z terminálu ukázal, že mesačný súbor nemusí obsahovať začiatok reťaze: filtruje sa podľa času razenia, reťaz ide podľa `punch_id`.
  Overovač preto už nevyžaduje `GENESIS` na začiatku súboru. Záznam, ktorého predchodca v súbore nie je, je upozornenie (s `--strict` chyba).
  Chyby ostávajú: nesedí pätička, nedá sa prepočítať `record_hash`, vetvenie reťaze, odkaz na iného používateľa alebo na neskorší záznam.
* Úplnú kontrolu súvislosti reťaze robí Access nad všetkými importovanými razeniami (chýbajúci predchodca = razenie sa importuje a označí na kontrolu).
* Pridané testy overovača `tools/test_verify_export.py`.

## 1.1.0 – 2026-11-03 (doplnok, `punches_*.csv` sa nemení)
* Nový súbor `voids_YYYYMM.csv` so zoznamom zneplatnených razení (žiadosť zamestnanca schválená vedúcim/správcom). Razenia a ich hash reťaz ostávajú nezmenené,
  zneplatnenie ide v samostatnom zozname; dôvod sa neexportuje. Pravidlá pre Access sú v `README.md`.
* Zlatý súbor `examples/voids_example.csv` (+ `voids_example.input.json`), referencia `reference/void-export.ts`, kontraktový test `tests/void-export.contract.test.ts`.
* Access verzie 1.0 súbor `voids_*.csv` jednoducho ignoruje: zneplatnené razenia sa v ňom budú naďalej počítať, kým Access nepodporí 1.1 (importér Accessu 2.11.0).

## 1.2.0 – 2026-11-04 (doplnok, `punches_*.csv` ani `voids_*.csv` sa nemenia)
* Súbor `dochs_config.json` v schéme 2 (smer Access → terminál) nesie **výpočtový plán**: pre každého zamestnanca a mesiac okna typ dňa a denný fond v minútach, úväzok,
  priradenie fondu a šablóny, k tomu výklad, ako sa ktoré prerušenie počíta (`calc`), mapovanie kódov terminála na prerušenia Accessu a pravidlá prerušení po mesiacoch.
  Nadmnožina schémy 1 (všetky kľúče ostávajú). Zamestnanec je len osobné číslo.
* Schéma `config-export.schema.json`, zlatý súbor `examples/config_example.json` (+ vymyslený vstup `config_example.input.json`), referenčný výpočet plánu
  `tools/build_config_example.py`, overovač `tools/verify_config.py` a testy `tools/test_verify_config.py`.
* Access: balík 2.12.0 (`mod_20_KonfiguraciaExport`). Terminál zatiaľ konfiguráciu neprijíma; návrh a zadanie pre aplikačnú časť sú v `docs/KONFIGURACIA-Z-ACCESSU.md`.
* Schválenie vlastníkom repozitára je potrebné (zmena `contract/`).

## 1.3.0 – 2026-11-04 (doplnok, `punches_*.csv` ani `voids_*.csv` sa nemenia; `schema_version` ostáva 2)
* Prerušenia v `dochs_config.json` môžu mať tri voliteľné kľúče pre **tlačidlá terminálu**: `terminal_button`, `terminal_label`, `terminal_order`.
  Rozhoduje Access (príznak, text alebo skratka, poradie); terminál tlačidlá zostaví z konfigurácie, bez nej ostanú predvolené.
* Nové kontroly v `tools/verify_config.py` (a rovnaké v `src/lib/access-config.ts`): typy a rozsahy, text a poradie len s príznakom, č. 1 a č. 7 bez tlačidla,
  práve jeden kód v `terminal_code_map`, jedinečný text, najviac 12 tlačidiel. Súbor bez týchto kľúčov ostáva platný a nezmenený.
* Zlatý súbor `examples/config_example.json` (+ vstup) má štyri tlačidlá (Lekár, Sprievod, Služobná cesta, Služobné vzdialenie) a kód `ERRAND` → č. 4; pridaných 11 testov v oboch jazykoch.
* Nasadenie: Access kľúče vkladá, len ak je príznak niekde nastavený. Pred tým treba, aby terminál a databáza prijímali nové kľúče (databázová časť je súkromný SQL balík); inak by sa súbor odmietol.
  Access (stĺpce v číselníku prerušení, okno Prerušenia a export `mod_20`) sa upraví samostatným balíkom po schválení tohto kontraktu.
* Schválenie vlastníkom repozitára je potrebné (zmena `contract/`).

