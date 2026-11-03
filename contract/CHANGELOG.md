# Zmeny kontraktu
## 1.0.0 – 2026-11-03
* Prvá verzia: CSV export razení (`punches_YYYYMM.csv`), pätička `#END` so SHA-256, hash reťaz po používateľovi.
* Zlatý súbor `examples/punches_example.csv`, vstup `examples/punches_example.input.json`, schéma `punch-export.schema.json`.
* Referenčná implementácia `reference/punch-export.ts`, kontraktový test `tests/punch-export.contract.test.ts`, overovač `tools/verify_export.py`.
