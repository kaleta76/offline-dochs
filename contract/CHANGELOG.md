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
