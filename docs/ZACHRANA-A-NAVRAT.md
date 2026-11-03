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

### Zálohy databázy

Nie je overené, či Lovable Cloud robí zálohy databázy ani ako sa z nich obnovuje. Kým sú v databáze len testovacie údaje, nie je to riziko. Pred zapísaním reálnych osobných čísel to treba zistiť u Lovable.
