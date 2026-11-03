Prečítaj si `AGENTS.md` (sekcia „Integrácia s dochádzkovým systémom“), `contract/README.md` a `docs/SPOLUPRACA.md`. Potom pridaj do administrácie funkciu **Export pre Access**:

* V `src/routes/_authenticated/admin.tsx` pridaj sekciu „Export pre Access“: výber mesiaca (rok + mesiac v `Europe/Bratislava`), voliteľne „od ID“ (`since_id`) pre prírastok, tlačidlo „Stiahnuť“.
* Server funkcia (`createServerFn`) `exportPunches({ year, month, sinceId })`: povolená len pre rolu admin vlastnej organizácie; číta `punches` spojené s `profiles.sap_id` **len vlastnej organizácie** (RLS, nie service role); mesiac určuje podľa `Europe/Bratislava` (od 1. dňa 00:00 po koniec mesiaca); pri `sinceId` vráti `id > sinceId`.
* Súbor vyrob **výlučne** funkciou `buildPunchExportCsv` zo `src/lib/punch-export.ts`; názov `punches_RRRRMM.csv` (pri prírastku `punches_RRRRMMDD_HHMM.csv`), kódovanie UTF-8 s BOM, `Content-Type: text/csv; charset=utf-8`.
* Do `audit_log` zapíš `export.access` (actor, rok, mesiac, počet riadkov, najvyššie `punch_id`).
* Nepridávaj mená, e-maily ani iné osobné údaje; nemeň schému databázy.
* Pridaj test pre server funkciu (zlý používateľ → odmietnutie; iná organizácia → žiadne riadky) a skontroluj, že kontraktový test ostáva zelený.

Spusti `bun run lint`, `bun run test`, `bun run build`. Na konci uveď zoznam zmenených súborov, výsledky príkazov a čo si nevyskúšal (napr. skutočné stiahnutie na publikovanej verzii).
