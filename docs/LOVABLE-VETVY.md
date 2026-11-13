# Vetvy a synchronizácia s Lovable (stav 13. 11. 2026)

Od 13. 11. 2026 má Lovable vlastnú vetvu, takže nič, čo pošle do repozitára, neprepíše `main`. Dôvod: Lovable pri automatických úpravách (napr. `src/integrations/supabase/types.ts`) píše do pripojenej vetvy a predtým to bol `main`.

## Dve vetvy

| Vetva     | Kto do nej píše                                         | Ochrana                                                                                               |
| --------- | ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `main`    | len pull requesty (vývojár, Claude, prenos z Lovable)   | ruleset „Ochrana main“: nedá sa zmazať, nedá sa force-push, zlúčenie len cez PR, len **merge commit** |
| `lovable` | Lovable (jej agent a `Publish` ju čítajú) a PR z `main` | bez ochrany, aby Lovable mohla zapisovať                                                              |

Pripojená vetva je v Lovable nastavená na `lovable`. Publikuje sa z nej.

## Tok zmien

1. **Zmena od vývojára alebo od Claude:** vetva z `main` (napr. `fix/…`, `chore/…`), PR do `main`, CI zelená, zlúči vlastník tlačidlom **Create a merge commit**.
2. **Doručenie do Lovable:** PR `main` → `lovable` (zdrojová vetva `main`, cieľ `lovable`), znova **Create a merge commit**, potom v Lovable **Publish**.
3. **Práca Lovable späť do `main`:** čas od času PR `lovable` → `main` (alebo z pomocnej vetvy `sync/…`, ak treba niečo opraviť, ako 13. 11. pri `types.ts`). Potom znova krok 2, aby mali obe vetvy rovnaký obsah.
4. **Kontrola:** `git rev-list --count origin/lovable..origin/main` (čo má `main` a Lovable nie) a naopak. Po synchronizácii ostane vždy jeden zlučovací commit navyše; to je v poriadku, ak `git diff origin/main origin/lovable` nevypíše nič.

## Pravidlá

- Nikdy force-push, rebase ani squash na `main` ani `lovable`. Vždy **Create a merge commit**.
- Súbory, ktoré spravuje Lovable (`src/integrations/supabase/types.ts`, `client.ts`, `previewAuthStorage.ts`), sa upravujú ručne len v nevyhnutnom prípade a v PR to treba napísať. `types.ts` sa generuje z databázy: Lovable ho môže pregenerovať skôr, než sa v SQL editore spustí nová migrácia, a potom mu chýbajú nové funkcie (13. 11. chýbal `_message` pri `delete_test_organization`). Doplní sa ručne v tvare, v akom ho vygeneruje databáza, a po ďalšom generovaní vyjde to isté.
- SQL migrácie z `docs/migracie/` sa nespúšťajú automaticky ani pri Publish. Spúšťa ich vlastník v SQL editore Lovable Cloud a na lokálnej databáze (Studio).
- Lokálne prostredie sa aktualizuje len z `main` (`git fetch origin`, `git switch main`, `git pull`), nikdy z `lovable`.
- Ak CI v PR zlyhá, najprv pozrieť, ktorý krok padol (v kroku „bun run test“ môže ísť o nestabilný test). Opakovanie jobu pomôže len dočasne; nestabilný test treba opraviť.

## Čo ostáva neoverené

Ochrana `main` je nastavená v GitHube (Settings → Rules), nie v repozitári. Ak ju niekto vypne, tento tok funguje ďalej, len `main` nie je chránená.
