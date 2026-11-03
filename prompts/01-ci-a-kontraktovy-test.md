Prečítaj si `AGENTS.md` (sekcia „Integrácia s dochádzkovým systémom“), `contract/README.md` a `docs/SPOLUPRACA.md`. Potom urob presne toto, nič iné:

1. Skopíruj `contract/reference/punch-export.ts` do `src/lib/punch-export.ts`. Vo vnútri nahraď vlastnú funkciu `sha256Hex` importom existujúcej z `./device` (kvôli kompatibilite s jsdom). Spusti `bun run format`, aby súbor spĺňal prettier (šírka 100).
2. Skopíruj `contract/tests/punch-export.contract.test.ts` do `src/lib/punch-export.contract.test.ts`. Uprav importy: `./punch-export`, a zlaté súbory čítaj z `contract/examples/` cez `fileURLToPath(new URL("../../contract/examples/…", import.meta.url))`. Prettier aj tu.
3. Do `eslint.config.js` pridaj `contract` do `ignores` (ten priečinok je dokumentácia/referencia, nie kód aplikácie).
4. Over, že `.github/workflows/ci.yml` existuje a zodpovedá skriptom v `package.json` (`lint`, `test`, `build`). Ak sa názvy líšia, uprav len workflow.
5. Spusti `bun run lint`, `bun run test`, `bun run build`.

Pravidlá: **nemeň** nič v `contract/` ani vzorec `punches_chain`; testy neupravuj tak, aby prešli. Ak nejaký test zlyhá, zastav sa a napíš presnú chybu.
Na konci napíš: čo si zmenil (zoznam súborov), výsledok troch príkazov, a čo si nemohol overiť.
