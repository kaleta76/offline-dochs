# Lovable: kredity, synchronizácia s GitHubom a postup s minimom kreditov (stav 2026-11-03)

Zdroje sú oficiálna dokumentácia Lovable (odkazy na konci). Čo dokumentácia nehovorí, je označené „neoverené“.

## Čo míňa kredity
- Jeden zostatok pokrýva: build (Build/Plan mode), chat, hosting a vstavaný backend (Cloud), AI funkcie nasadenej aplikácie, konektory.
- Build mode sa účtuje podľa náročnosti (príklady z dokumentácie: 0,5 až 2 kredity za požiadavku). Plan mode: 1 kredit + prípadný výskum.
- Chat mode a Chaty: zlomok kreditu za správu (dočasná cena do 31. 10. 2026, overiť aktuálny stav).
- Každý účet má 10 bezplatných „Try to fix“ (každá sa uvoľní 24 h po použití).
- Bezplatné granty: denne 5 build kreditov (Free max 30 mesačne), mesačne Cloud, AI a konektory (v tabuľke dokumentácie 20 / 4 / 1), denný chat. Granty sa neprenášajú.

## Čo sa stane pri nulovom zostatku
- Publikované stránky sa naďalej servírujú.
- Cloud backend (databáza, autentifikácia, úložisko) sa pozastaví, keď sú vyčerpané mesačný Cloud grant aj všeobecné kredity. Denné build kredity ho neudržia. Dáta ostanú, ale nedajú sa čítať ani exportovať, kým služba nebeží.
- Pre terminál to znamená: razenia sa nedajú synchronizovať do cloudu, kým sa backend nezobudí („More → Database → Wake up“ po doplnení kreditov).
- Dôsledok: zostávajúce všeobecné kredity treba držať ako rezervu pre Cloud, nie ich míňať na prompty agenta.

## GitHub sync
- Commity do synchronizovanej vetvy (od 13. 11. 2026 `lovable`, predtým `main`; pozri [`LOVABLE-VETVY.md`](LOVABLE-VETVY.md)) sa objavia v Lovable automaticky. Dokumentácia: úprava a commit kódu mimo Lovable nespotrebuje kredity.
- Iné vetvy sa nesynchronizujú, kým sa nezlúčia do synchronizovanej vetvy.
- Nikdy force-push, rebase ani squash už existujúcich commitov na `main` ani `lovable`. Bežné zlúčenie pull requestu je v poriadku.
- Sync nespúšťa migrácie ani nenasadzuje edge funkcie (treba požiadať Lovable, alebo SQL spustiť samostatne). Sync nikdy nepublikuje: publikuje sa až z Lovable.
- Neoverené: či samotné tlačidlo Publish míňa build kredity (pozrieť Workspace settings → Plans & credit usage → Usage details).

## Odporúčaný postup (minimum kreditov)
1. Práca na vetve mimo `main` (napr. `claude/kontrakt-v1`), potom pull request. Lovable sa ho nedotkne, 0 kreditov.
2. Testy a build bežia v GitHub Actions (verejný repozitár). Lokálne v tejto relácii sa nedajú nainštalovať npm balíky (registry je zablokovaný), preto je CI jediný test.
3. Zlúčenie PR do `main` robí používateľ v GitHube. Do Lovable sa dostane až PR `main` → `lovable` (a potom Publish).
4. Publikovanie z Lovable (tlačidlo Publish).
5. Databázové zmeny naraz v jednej dávke na konci (jediný SQL súbor):
   - vlastný SQL v Cloud/Database (0 build kreditov, ak to rozhranie umožňuje), alebo
   - jedna správa Lovable agentovi „spusti migráciu zo súboru …“ (odhad zhruba 1 kredit; môže sa zmestiť do denných 5 build kreditov).
6. Ak po zlúčení padne build v náhľade Lovable, použiť bezplatné „Try to fix“ (10 kusov).

## Čo z kontraktu potrebuje migráciu
- Prompty 01 (CI a kontraktový test) a 02 (Export pre Access): čistý kód, bez zmeny schémy, 0 kreditov.
- Prompt 03 (bezpečnosť): väčšinou kód a konfigurácia; vypnutie samoregistrácie organizácie môže vyžadovať zmenu `handle_new_user` (migrácia).
- Prompt 04 (integračný režim, razenie sa neodmieta v uzavretom mesiaci): jedna migrácia triggera `punches_chain`.
- Prompt 05 (HTTPS pull, tajné hodnoty): zatiaľ nerobiť.

## Alternatívy
- Riešenie od Anthropic: Artifact (publikovaná stránka) má zdieľanú databázu a vie, kto ju zobrazuje, ale používatelia musia byť prihlásení do claude.ai (člen organizácie alebo pozvaný hosť). Pre terminál, kde razia zamestnanci bez účtu, offline fronta, párovanie zariadení a hash reťaz v databáze to nie je vhodné. Vhodné skôr na manažérsky prehľad z exportu.
- Odpojenie od Lovable (strednodobo): repozitár je štandardný TanStack Start + Supabase + PWA a schéma je v `drizzle/migrations/0000–0005`. Vlastný Supabase projekt a hosting (napr. Cloudflare, Netlify, Vercel) by odstránili závislosť od kreditov. Treba vymeniť `SUPABASE_*` hodnoty, overiť balík `@lovable.dev/vite-tanstack-config` (neoverené, či funguje mimo Lovable) a dáta z Cloudu vyexportovať skôr, než zostatok klesne na nulu.

## Zdroje
- https://docs.lovable.dev/introduction/faq
- https://docs.lovable.dev/introduction/credits-and-usage.md
- https://docs.lovable.dev/introduction/out-of-credits.md
- https://docs.lovable.dev/integrations/git-sync-overview.md
- https://docs.lovable.dev/integrations/github.md
