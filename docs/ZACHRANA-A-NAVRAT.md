# Záchrana: návrat k bezpečnému stavu

Čo robiť, ak po zásahu (Lovable, pull request, migrácia) aplikácia prestane fungovať. Kód a databáza sa vracajú zvlášť.

## Bezpečný bod

Commit **`8f1d9487d09b4aecffae04ce0c284641935f9412`** (zlúčenie PR #10, 3. 11. 2026) je stav, v ktorom prešlo CI a boli zlúčené zneplatnenie razení, overenie zariadení aj príprava vydaní.
História sa neprepisuje (pravidlo v `AGENTS.md`), takže tento commit v repozitári ostáva a dá sa k nemu kedykoľvek vrátiť.

## Kód (GitHub, Lovable)

1. Na GitHube pozri **Commits** na `main`: ktorý commit zmenu spôsobil, ktoré súbory sa zmenili a či je CI zelené. Najcitlivejšie sú `contract/`, `access/`, `.github/`, `AGENTS.md`, `drizzle/` a `supabase/`.
2. Vráť ho **novým commitom**, nikdy nie prepisovaním histórie (žiadny force push):
   ```
   git checkout -b navrat main
   git revert <commit>                      # zruší jeden commit
   git checkout 8f1d9487 -- cesta/k/suboru  # alebo obnoví súbor z bezpečného bodu
   git commit -m "Návrat ..." && git push -u origin navrat
   ```
   Potom pull request a zlúčenie. Rovnako to vie urobiť Claude.
3. Lovable zmenu prevezme z `main` sám. Do ostrej aplikácie sa dostane až po **Publish**.

Kód vrátiš tak, aby sedel s databázou. Kód po PR #6 stĺpce `voided_at` a `void_request_id` vyžaduje, takže bez migrácie 0006 by sa mesiac nenačítal.

## Databáza (Lovable Cloud)

Návrat kódu databázu **nevráti**: spustená migrácia ostáva. Ak je chyba v databáze, najprv skús opravu dopredu (nová migrácia, ktorú napíše Claude a spustí Lovable).

### Migrácia 0006 späť

Skript [`migracie/0006_spat_zachranny.sql`](migracie/0006_spat_zachranny.sql) vráti databázu do stavu pred migráciou 0006:

- zruší funkcie `request_punch_void` a `decide_punch_void`,
- vráti pôvodné pravidlo vkladania „punches own insert“ (z migrácie 0002),
- zmaže tabuľku `punch_void_requests` a stĺpce `punches.voided_at`, `punches.void_request_id`.

Čo to znamená: razenia aj ich hash reťaz ostanú, ale **stratíš informáciu, ktoré razenia boli zneplatnené**, a tie sa začnú znova počítať do dochádzky. Ak máš zneplatnenia, ktoré chceš zachovať, najprv si ich vyexportuj.
Kód od PR #6 stĺpce vyžaduje, takže po skripte treba kód vrátiť pred zneplatnenie razení (commit `890992d`, zlúčenie PR #5). Stratia sa tým aj zmeny z PR #6 až #10 v terminále. Preto je to krajné riešenie.

Spustenie v Lovable chate: „Spusti migráciu zo súboru docs/migracie/0006_spat_zachranny.sql presne tak, ako je, nič nemeň.“ (približne 1 kredit).

**Overené:** skript prešiel na lokálnom PostgreSQL 16 so zjednodušenými kópiami pomocných funkcií: po ňom zmizli stĺpce, tabuľka aj obe funkcie, text pravidla vkladania je rovnaký ako pred migráciou 0006, razenia a záznamy `audit_log` ostali, zamestnanec môže razenie vložiť a druhé spustenie nič nezmení.
**Neoverené:** beh na ostrej databáze Lovable Cloud.

### Migrácia 0007 späť

Skript [`migracie/0007_spat_zachranny.sql`](migracie/0007_spat_zachranny.sql) zruší funkcie `set_organization_test`, `test_organization_summary`, `purge_organization` a `delete_test_organization`, vráti pôvodnú funkciu `guard_last_admin` a zmaže stĺpec `organizations.is_test`. Údaje organizácií sa nemenia. **Už zrušené testovacie organizácie sa týmto neobnovia**, vráti ich len záloha ([`ZALOHA-DATABAZY.md`](ZALOHA-DATABAZY.md)).
Kód od PR s touto migráciou volá funkcie len z obrazovky Správa → Testovacia organizácia a stĺpec `is_test` číta nepovinne, preto sa po skripte ostatné obrazovky nezmenia. Spustenie: SQL editor v Lovable Cloud, alebo v chate *„Spusti migráciu zo súboru docs/migracie/0007_spat_zachranny.sql presne tak, ako je, nič nemeň.“*
**Overené:** na lokálnom PostgreSQL 16 (spustený dvakrát, po ňom platí pôvodná ochrana posledného správcu). **Neoverené:** beh na ostrej databáze Lovable Cloud.

### Migrácia 0016 späť

Skript [`migracie/0016_spat_zachranny.sql`](migracie/0016_spat_zachranny.sql) zruší spúšťače `a_punches_transfer_lock` (zámok razení pri prenose) a `a_organizations_transfer_guard` (ochrana pred predčasným zrušením), funkcie `org_export_begin`, `org_export_page`, `org_export_finish`, `org_transfer_status`, `org_transfer_cancel`, `org_transfer_confirm_and_delete` a schému `org_transfer` s históriou prenosov (ak v nej nie je súkromný balík 0015, vtedy schéma ostane). Údaje organizácií ani razenia sa nemenia. Skript **nevracia** označenie „testovacia organizácia“, ktoré nastavil prenos (vráťte ho tlačidlom v karte Servis alebo `set_organization_test(false)`). Aplikácia na týchto funkciách zatiaľ nezávisí. Spustenie: SQL editor v Lovable Cloud. Skript je opakovateľný. Popis prenosu: [`PRENOS-ORGANIZACIE.md`](PRENOS-ORGANIZACIE.md).
**Overené:** na lokálnom PostgreSQL 16 (stav funkcií, spúšťačov a počtov riadkov je po skripte rovnaký ako pred migráciou, aj opakovane a s nainštalovaným balíkom 0015). **Neoverené:** beh na ostrej databáze Lovable Cloud.

### Zálohy databázy

Lovable Cloud robí denné zálohy databázy (približne 14 dní) a ponúka Export celej databázy. Postup, overenie stiahnutého súboru a poistka pred ručným zásahom: [`ZALOHA-DATABAZY.md`](ZALOHA-DATABAZY.md). Kým sú v databáze len testovacie údaje, strata nie je riziko. Pred zapísaním reálnych osobných čísel treba u Lovable overiť, kde sa zálohy ukladajú a kto k nim má prístup.
