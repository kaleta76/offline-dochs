Prečítaj si `AGENTS.md` (sekcia „Integrácia s dochádzkovým systémom“) a `docs/SPOLUPRACA.md` (kap. 3 a 8). Repozitár je verejný, preto uprav:

1. `.env` je v gite. Pridaj `.env` a `.env.*` do `.gitignore` (výnimka `.env.example`), vytvor `.env.example` s názvami kľúčov bez hodnôt a odstráň `.env` z indexu (`git rm --cached .env`). Hodnoty, ktoré Lovable potrebuje, nechaj v nastaveniach Lovable/Cloud, nie v repozitári. Over, že `service_role` kľúč nikde nie je v klientskom kóde.
2. Registrácia novej organizácie: navrhni a implementuj nastavenie, ktorým sa **v produkcii vypne samoregistrácia organizácie** (`handle_new_user` vetva s `organization_name`) – nová organizácia vznikne len na pozvánku/ručne vlastníkom. Najprv mi popíš zvolené riešenie a dopad na existujúci registračný formulár; migráciu urob až potom.
3. Pri aktivácii účtu zamestnanca (`accounts.functions.ts`) skry voliteľné pole „vlastný e-mail“ (osobný údaj). Existujúce účty nemeň.
4. Skontroluj, že žiadna route ani server funkcia nevracia mená, e-maily či iné osobné údaje iným používateľom, ako to dovoľuje RLS.

Nemeň nič v `contract/`. Spusti `bun run lint`, `bun run test`, `bun run build`. Na konci vypíš, čo je hotové a čo musím nastaviť ručne v Lovable/Supabase (Auth nastavenia).
