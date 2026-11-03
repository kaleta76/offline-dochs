# Kontrakt terminál ⇄ Access (verzia 1)

Tento priečinok je **jediné miesto, na ktorom sa dohodne rozhranie** medzi terminálom (tento repozitár, vyvíja ho Lovable agent)
a lokálnym dochádzkovým systémom v Accesse (vyvíja ho Claude). Zmena súborov tu = zmena dohody, preto ide **iba cez pull request**
a schvaľuje ju vlastník repozitára (pozri `.github/CODEOWNERS`).

## Zásady
1. Terminál posiela len **fakty** (kto, aký kód, smer, kedy, z akého zariadenia). Nepočíta mzdové ani fondové výsledky pre Access.
2. Osobné údaje (mená) nikdy neopúšťajú Access. Terminál pozná len **osobné číslo SAP** (pseudonym).
3. Prenos je **idempotentný**: ten istý záznam môže prísť viackrát, Access ho nespracuje dvakrát (`external_id`).
4. Prenos je **overiteľný**: súbor má pätičku so SHA-256 a každý záznam nesie hash reťaz (`prev_hash` → `record_hash`).
5. Zmena kontraktu = nová hlavná verzia (`contract_version`), stará verzia sa podporuje aspoň do ďalšieho mesačného uzatvorenia.

## Súbor `punches_YYYYMM.csv` (alebo `punches_YYYYMMDD_HHMM.csv` pre prírastok)
* UTF-8 s BOM, oddeľovač `;`, texty v `"..."`, čísla bez úvodzoviek, riadky končia `CRLF`.
* Prvý riadok = hlavička, posledný riadok = pätička `#END;rows=<počet>;sha256=<hex>`.
  SHA-256 sa počíta zo **všetkých bajtov od hlavičky po posledné `CRLF` pred pätičkou** (bez BOM).
* Riadky sú zoradené podľa `punch_id` vzostupne.

| stĺpec | typ | význam |
|---|---|---|
| `contract_version` | číslo | vždy `1` |
| `organization_id` | uuid | organizácia v terminále (Access má jednu a overuje ju pri prvom importe) |
| `punch_id` | číslo | `punches.id` – rastúce, slúži ako kurzor prírastkového importu |
| `external_id` | uuid | `punches.client_uuid` – kľúč na deduplikáciu (Access ho ukladá do `DochadzkaImport.ExterneID`) |
| `personnel_number` | text | osobné číslo SAP, **text** (môže mať vedúce nuly, Access porovnáva po odstránení nulí) |
| `code` | text | `WORK`, `TRIP`, `DOCTOR`, `FAMILY`, `LEAVE`, `SICK`, `PRIV` (rozšíriteľné, pozri `code-mapping.csv`) |
| `direction` | text | `IN` / `OUT` |
| `client_time_local` | text | čas na zariadení v `Europe/Bratislava`, `RRRR-MM-DD HH:MM:SS` |
| `client_time_utc` | text | rovnaký okamih v UTC, `RRRR-MM-DDTHH:MM:SSZ` (**záväzný**, lokálny je len na čítanie) |
| `server_time_utc` | text | kedy záznam prijal server |
| `drift_minutes` | číslo | `server_time − client_time` v minútach (veľké číslo = záznam prišiel neskoro/offline) |
| `source` | text | `terminal` (razil zamestnanec) / `correction` (schválená oprava vedúcim) |
| `device_verification` | text | `verified` / `unverified` / `confirmed` (neoverené potvrdil vedúci) |
| `device_id` | uuid alebo prázdne | zariadenie, z ktorého prišlo razenie (prázdne pri korekcii) |
| `user_uuid` | uuid | interný pseudonymný účet (len pre kontrolu reťaze) |
| `prev_hash`, `record_hash` | hex | hash reťaz po používateľovi (vzorec nižšie) |

### Hash reťaz
`record_hash = SHA-256( prev_hash | user_uuid | code | direction | client_time_utc(do sekundy, bez Z) | server_time_utc(do sekundy, bez Z) | external_id [| device_id] )`,
`prev_hash` úplne prvého záznamu používateľa je `GENESIS`. Reťaz ide podľa `punch_id`, ale súbor sa filtruje podľa času razenia, preto mesačný a prírastkový súbor obsahuje len jej časť: prvý záznam používateľa v súbore má `prev_hash` staršieho záznamu, ktorý v súbore nie je (nie je to chyba). Vzorec je presná kópia databázového triggera `punches_chain`
(`drizzle/migrations/0003_device_verification.sql`) a bol overený proti PostgreSQL 16. Overenie: `tools/verify_export.py`.

## Pravidlá, ktoré musí dodržať Access pri importe (zhrnutie, detail v dokumente `docs/SPOLUPRACA.md`)
* **Mapovanie kódov je kontextové.** `X/OUT` (okrem `WORK`) = *začiatok* prerušenia X, nasledujúce `WORK/IN` = *koniec* prerušenia X;
  prvé `WORK/IN` dňa = príchod, posledné `WORK/OUT` = odchod. Tabuľka je v `code-mapping.csv` a vlastní ju Access.
* **Mesiac uzavretý v Accesse:** razenie sa nezahodí, ostane v `TerminalInbox` so stavom `UZAVRETY` a spracuje sa po otvorení mesiaca.
* **Neoverené razenia** (`unverified`) sa importujú, ale Access ich označí na kontrolu; oprava/potvrdenie ide cez vedúceho v terminále.
* **Prírastok:** Access si pamätá posledné `punch_id` a pri ďalšom importe žiada `punch_id > posledné − 500` (prekrytie); duplicity vyradí `external_id`.

## Súbor `voids_YYYYMM.csv` (kontrakt 1.1, doplnok – formát `punches_*.csv` sa NEMENÍ)
Zamestnanec môže požiadať o zneplatnenie razenia (napr. duplicitné razenie), vedúci alebo správca žiadosť schváli. Razenie sa v databáze **nemaže** a jeho
hash reťaz sa nemení (`voided_at` nie je súčasťou `record_hash`). Preto zneplatnené razenie ostáva aj v `punches_*.csv` a Access ho dostane
v **samostatnom zozname** za rovnaký mesiac (podľa času zneplatneného razenia, nie podľa času schválenia).
* Formát súboru je rovnaký ako pri razeniach: UTF-8 s BOM, `;`, `CRLF`, hlavička, riadky podľa `punch_id`, pätička `#END;rows=N;sha256=...` (SHA-256 tela bez BOM).
* Dôvod zneplatnenia sa **neexportuje** (voľný text môže obsahovať osobné údaje); ostáva v terminále v audite.

| stĺpec | typ | význam |
|---|---|---|
| `contract_version` | číslo | vždy `1` (zmena 1.1 je spätne kompatibilná, nový je len tento súbor) |
| `organization_id` | uuid | rovnaká organizácia ako v `punches_*.csv` |
| `punch_id` | číslo | `punches.id` zneplatneného razenia |
| `external_id` | uuid | `punches.client_uuid` – podľa neho Access nájde riadok v `DochadzkaImport.ExterneID` |
| `personnel_number` | text | osobné číslo SAP |
| `user_uuid` | uuid | pseudonymný účet |
| `voided_at_utc` | text | kedy bolo zneplatnenie schválené, `RRRR-MM-DDTHH:MM:SSZ` |
| `record_hash` | hex | hash zneplatneného razenia (Access ním overí, že ide o to isté razenie, ktoré importoval) |

### Pravidlá pre Access
* **Idempotencia:** zoznam sa môže importovať opakovane; už zneplatnené razenie sa preskočí.
* **Poradie:** najprv `punches_*.csv`, potom `voids_*.csv` za ten istý mesiac. Ak `external_id` v Accesse ešte nie je, riadok sa nezahodí, ostane v čakaní a použije sa po importe razenia.
* **Zneplatnenie = `Platnost = False`, `DovodNeplatnosti = 'ZNEPLATNENE_V_TERMINALI'`;** riadok sa nemaže, deň a sald sa prepočítajú.
* **Nezhoda `record_hash`** (razenie s rovnakým `external_id` má iný hash) = chyba, nezneplatňuje sa, zapíše sa do protokolu.
* **Uzavretý mesiac v Accesse:** zneplatnenie sa neaplikuje, ostáva v čakaní do otvorenia mesiaca (rovnako ako razenia).
* Zlatý súbor: `examples/voids_example.csv`, test `tests/void-export.contract.test.ts`, referencia `reference/void-export.ts`.
