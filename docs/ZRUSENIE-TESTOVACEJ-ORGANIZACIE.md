# Zrušenie testovacej organizácie

Správca môže skúšobnú firmu natrvalo zrušiť aj s jej razeniami, zamestnancami a prihlasovacími účtami. Migrácia `docs/migracie/0007_zrusenie_testovacej_organizacie.sql`, obrazovka *Správa → Servis a testovanie → Testovacia organizácia*.

## Ako sa to používa

1. Prihláste sa ako **správca** testovacej organizácie, otvorte **Správa** a kartu **Servis a testovanie** so sekciou **Testovacia organizácia**. V testovacej organizácii je karta vždy vidieť; v organizácii, ktorú ešte neoznačíte ako testovaciu, ju odkryje `?servis=1` pridané k adrese Správy (napr. `…/admin?servis=1`). Karta nie je určená pre bežnú prevádzku a skrytie nie je ochrana: oprávnenia a ochranu pôvodnej organizácie vynucuje databáza.
2. **Označiť „názov“ ako testovaciu.** V hlavičke sa zobrazí odznak „Testovacia organizácia“. Označenie sa dá kedykoľvek vrátiť tlačidlom „Vrátiť: nie je testovacia“.
3. Sekcia ukáže, čo sa zmaže (počet účtov, razení a zariadení). Na potvrdenie napíšte **názov organizácie presne tak, ako je zapísaný** (rozlišujú sa veľké a malé písmená aj pomlčky; názov je v poli ako nápoveda).
4. **Zrušiť organizáciu natrvalo.** Aplikácia vás odhlási a organizácia aj všetky jej účty prestanú existovať.

Pred zrušením, ak chcete údaje zachovať, urobte zálohu: [`ZALOHA-DATABAZY.md`](ZALOHA-DATABAZY.md). Po zrušení sa organizácia vráti len obnovou zálohy.

## Ochrany

- Zrušiť sa dá **len organizácia, ktorú správca predtým označil ako testovaciu** (stĺpec `organizations.is_test`). Ostrú firmu databáza zrušiť odmietne (`Zrušiť sa dá len organizácia označená ako testovacia`), aj keby niekto obišiel obrazovku.
- **„Pôvodná organizácia“** (`00000000-0000-4000-8000-000000000001`, údaje prevzaté z pôvodnej aplikácie) sa nedá označiť ani zrušiť. V ostrej databáze ju vlastník 4. 11. 2026 zrušil jednorazovým SQL skriptom (rovnaký postup ako `purge_organization` bez tejto ochrany, mimo repozitára), pretože išlo len o skúšobné údaje. Ochrana ostáva v kóde, iná organizácia s týmto ID už v databáze nie je.
- Správca môže zrušiť **iba vlastnú** organizáciu. Cudzie nevidí ani nezmení (testované s dvoma organizáciami: cudzia ostala po zrušení bajt po bajte rovnaká).
- Je potrebné presné potvrdenie názvom a všetko prebehne v jednej transakcii: pri chybe sa nezmení nič.
- Zrušenie zanechá v `audit_log` jediný záznam `organization.deleted` (názov, počty, kto). Ostatné záznamy auditu zrušených účtov sa zmažú.

Je to vedomá **výnimka z pravidla „razenia sa nemažú“** (`AGENTS.md`): platí iba pre organizáciu označenú ako testovaciu. Hash reťaz a spúšťač `punches_chain` sa nemenia; zmazaná organizácia nemá reťaz, ktorú by bolo treba zachovať.

## Čo sa zmaže

Razenia (`punches`) a žiadosti o zneplatnenie, opravy, uzávierky mesiacov, žiadosti o osobné číslo, nastavenie upozornení, zariadenia, nastavenia, číselník, sviatky a pozývací kód organizácie, role, profily, samotná organizácia a **prihlasovacie účty** (`auth.users`, spolu s reláciami a identitami). Posledného správcu systém inak zmazať nedovolí, pri zrušení celej testovacej organizácie to povolí.

## Nasadenie (poradie je dôležité)

1. **Záloha** podľa [`ZALOHA-DATABAZY.md`](ZALOHA-DATABAZY.md).
2. **Kontrola pred migráciou**: v SQL editore spustite `docs/zaloha/kontrola_0007.sql` (jeden dotaz len na čítanie, jeden riadok). Migrácia je pripravená, keď `smie_vytvarat_v_public`, `vlastni_organizations`, `vlastni_guard_last_admin` aj `smie_mazat_auth_users` sú `true` a `stlpec_is_test` je `false`. Ak je niečo `false`, migráciu nespúšťajte a pošlite výsledok.
3. **Migrácia 0007** v databáze. Dve možnosti:
   - SQL editor v Lovable Cloud: otvorte súbor `docs/migracie/0007_zrusenie_testovacej_organizacie.sql` na GitHube (Raw), skopírujte celý a spustite. Skript len pridáva stĺpec a funkcie, žiadne údaje nemení.
   - Lovable agent (kredity): v chate napíšte *„Spusti migráciu z tohto SQL presne tak, ako je, nič iné nemeň“* a **vložte SQL priamo do správy** (agent má niekedy zastaraný náhľad repozitára).
4. **Kontrola po migrácii**: znova `kontrola_0007.sql` (čakáte `stlpec_is_test = true`, `funkcie_0007 = 4`, `purge_pre_authenticated = false`, `purge_pre_service_role = true`), prípadne `stav_databazy.sql` (päť značiek „0007 …“ = `ano`).
5. Zlúčiť PR a **Publish**. Kód funguje aj pred migráciou: sekcia ukáže, že migrácia ešte nebola spustená, a nič iné sa nepokazí. Pred zlúčením PR však migráciu spustiť netreba.

Ak by migrácia padla, zmení sa podľa očakávania nič (skript je jedna transakcia; či ho SQL editor Lovable naozaj spúšťa ako celok, nie je overené, preto kontrola po migrácii). Návrat: [`migracie/0007_spat_zachranny.sql`](migracie/0007_spat_zachranny.sql) (zruší funkcie a stĺpec, už zrušené organizácie nevráti).

## Organizácia, do ktorej sa nikto nevie prihlásiť

Testovacia firma bez prístupu správcu (stratené heslá) sa dá zrušiť ručne v SQL editore. Najprv záloha (`snapshot_pred_zasahom.sql`), potom:

```sql
-- 1. Nájsť organizáciu (id, názov, počet účtov)
SELECT o.id, o.name, o.is_test, count(p.id) AS ucty
  FROM public.organizations o LEFT JOIN public.profiles p ON p.organization_id = o.id
 GROUP BY o.id ORDER BY o.created_at;

-- 2. Označiť VÝLUČNE testovaciu a zrušiť (dosaďte id z kroku 1)
UPDATE public.organizations SET is_test = true WHERE id = '00000000-0000-0000-0000-000000000000';
SELECT public.purge_organization('00000000-0000-0000-0000-000000000000');
```

Funkcia `purge_organization` nekontroluje oprávnenia a spustiť ju môže len správca databázy (nie používateľ aplikácie). Odmietne neoznačenú a „Pôvodnú organizáciu“. Pri ručnom spustení nie je prihlásený používateľ, preto v audite ostanú aj záznamy bez autora (úpravy rolí a profilov z tohto mazania).

Záznam o zrušení (`organization.deleted`) má od migrácie [`0018`](migracie/0018_audit_zrusenia_organizacie.sql) `actor = NULL`, ak organizáciu zrušil jej vlastný správca (jeho účet zrušením zanikol); jeho id je v `details.by`. Predtým ostával v audite záznam s id neexistujúceho účtu, ktorý po opätovnom importe tej istej organizácie pokazil počet riadkov auditu pri overení prenosu. Staré záznamy sa nemenia (import ich odpojí sám). Návrat: [`migracie/0018_spat_zachranny.sql`](migracie/0018_spat_zachranny.sql).

## Čo je overené a čo nie

Overené na lokálnom PostgreSQL 16 s napodobeninou Supabase (`tools/sql_test/run.sh` s `0007_priprava.sql`, `0007_testy.sql`, záchranným skriptom dvakrát a `0007_po_navrate.sql`; 67 kontrol): práva funkcií (anon nič, používateľ nevolá pracovnú funkciu), zamestnanec nič nezmení, neoznačená a pôvodná organizácia sa nedajú zrušiť, zlý názov sa odmietne, po zrušení nezostanú siroty (účty, identity, relácie, role, razenia, zariadenia, žiadosti), cudzie organizácie sa nezmenia, ochrana posledného správcu platí ďalej, ručné zrušenie, návrat a jeho opakovanie. Logika potvrdenia v prehliadači má jednotkové testy (`src/lib/organization-delete.test.ts`).

**Neoverené:** beh na ostrej databáze Lovable Cloud (hlavne právo funkcie mazať z `auth.users`; ak ho vlastník funkcie nemá, zrušenie skončí hneď na začiatku chybou *„Databáza nedovoľuje mazať prihlasovacie účty“* a nič sa nezmení), vzhľad obrazovky v prehliadači a typová kontrola (overí CI na GitHube).
