# Záloha a návrat databázy (Lovable Cloud)

Postup pred každým ručným zásahom do databázy (mazanie testovacej organizácie, oprava údajov, spúšťanie SQL z chatu). Platí od 4. 11. 2026.

## Skrátene

1. **Export v Lovable** a stiahnutie súboru (kap. 2). Raz za 24 hodín, trvá niekoľko minút.
2. **Overenie a uloženie** stiahnutého súboru skriptom `tools/over_zalohu.py` (kap. 3).
3. **Snapshot v databáze** skriptom `docs/zaloha/snapshot_pred_zasahom.sql` (kap. 4): rýchla poistka priamo v databáze.
4. Zásah.
5. **Porovnanie** so snapshotom: `docs/zaloha/porovnaj_so_snapshotom.sql`. Zmeniť sa smú len tabuľky, v ktorých ste zasahovali.
6. Keď je všetko v poriadku, **zmažte snapshot** (kap. 4). Súbor z Exportu si nechajte.

Samostatne od zálohy: ak má Claude vedieť, **ako databáza vyzerá práve teraz**, spustite dotaz zo kapitoly 7 (`docs/zaloha/stav_databazy.sql`) a výsledok priložte do chatu.

## 1. Čo Lovable Cloud poskytuje

Podľa dokumentácie Lovable ([Database backups](https://docs.lovable.dev/features/database-backups), stav k 4. 11. 2026):

| Možnosť | Kde | Poznámky |
|---|---|---|
| **Denné zálohy** | More → Database → Manage → Backups | Lovable ich robí sám, drží približne 14 dní, každá má časovú značku UTC. Zahŕňajú štruktúru aj údaje, nie súbory v Storage. |
| **Obnova zo zálohy** | tlačidlo „Restore to this backup“ pri zálohe | Vráti **celú databázu** (štruktúru aj údaje) a **zmaže všetko, čo vzniklo po záloze**. Databáza je pár minút nedostupná. Nedá sa vrátiť späť. Smie ju spraviť každý s právom upravovať projekt. |
| **Export celej databázy** | More → Database → Manage → Settings → Export data → Export → Start export | Súbor `NAZOV_RRMMDD.backup.zip` s jedným súborom `NAZOV_RRMMDD.backup`: archív `pg_dump` (štruktúra, údaje, prihlasovacie účty aj odtlačky hesiel) na načítanie cez `pg_restore`. Overené na skutočnom exporte zo 4. 11. 2026: formát archívu 1.16, databáza PostgreSQL 17.11, `pg_dump` 18.6, údaje stlačené zstd, 57 tabuliek s údajmi. Lovable pošle e-mail a súbor uloží do projektu (More → Storage). Jeden export za 24 hodín, databáza do 15 GB. Neobsahuje súbory zo Storage, tajné hodnoty ani nastavenia prihlásenia. |
| **CSV jednej tabuľky** | More → Database → pohľad na tabuľku | Len jedna tabuľka naraz, na rýchlu kontrolu. |

Názvy ponúk sa v Lovable menia; ak niečo nenájdete, hľadajte „Database“ → „Backups“ / „Export“.

## Prečo nie je skript, ktorý sa sám pripojí a stiahne databázu

Lovable Cloud **nedáva** používateľovi adresu databázy, heslo ani servisný kľúč, takže `pg_dump` ani skript s kľúčom použiť nemožno. Spôsob „vytvoriť v aplikácii tajný koncový bod, ktorý vydá celú databázu“ by cez jeden uniknutý token sprístupnil údaje **všetkých** firiem, preto ho do aplikácie nepridávame.
Stiahnutie preto robí tlačidlo Export a skript z repozitára robí to, čo sa s hotovým súborom dá: overí ho, spočíta SHA-256 a uloží.

## 2. Export a stiahnutie

1. V Lovable otvorte projekt: **More → Database → Manage → Settings → Export data → Export → Start export**.
2. Počkajte na e-mail od Lovable (databáza je malá, trvá to minúty).
3. **More → Storage**: stiahnite súbor so zálohou (`…backup.zip`) na počítač (napr. do `Stiahnuté`). **Nerozbaľujte ho**, skript číta priamo zip. Ak Lovable ponúka aj kontrolný súčet, poznačte si ho.

## 3. Overenie a uloženie stiahnutého súboru

Potrebný je Python 3 (na Windowse príkaz `py`, inštalácia z python.org alebo Microsoft Store). PostgreSQL netreba: skript archív `pg_dump` prečíta sám.

V koreni repozitára (priečinok, kde je `README.md`):

```
py -3 -I tools\over_zalohu.py "C:\Users\vy\Downloads\offline-dochs_261104.backup.zip"
```

(na Linuxe a macOS `python3 -I tools/over_zalohu.py ...`). Skript:

- skontroluje, že súbor nie je prázdny ani useknutý, a rozpozná formát (zip, pg_dump, tar, gzip, SQL),
- prečíta archív `pg_dump` (verzie 1.14 až 1.16, teda PostgreSQL 12 až 18) a overí, že každý blok údajov je celý a nepoškodený,
- overí, že vo vnútri sú **údaje** všetkých tabuliek aplikácie (`organizations`, `profiles`, `user_roles`, `punches`, `devices`, `audit_log`, `organization_*`, `corrections`, `month_closures`, `punch_void_requests`, `personnel_requests`, `notification_preferences`) aj prihlasovacích účtov `auth.users`, a pri každej vypíše, či je **prázdna**. Prázdne `organizations`, `profiles`, `user_roles` alebo `auth.users` skript odmietne ako chybný export. Prázdne razenia, uzávierky a žiadosti sú v poriadku, ak ich aplikácia ešte nepoužila,
- vypíše verziu archívu, verziu databázy a čas vytvorenia,
- vypíše SHA-256 (ak máte kontrolný súčet z Lovable, pridajte `--sha256 HEX`),
- uloží kópiu do `zalohy\RRRR-MM-DD_HHMM\` aj so súborom `.sha256` a `manifest.json`, kópia je len na čítanie.

Ukážka výstupu (skutočný export zo 4. 11. 2026, skrátené):

```
Formát:       zip → pg_custom
Archív pg_dump 1.16.0: server PostgreSQL 17.11, pg_dump 18.6 (Debian 18.6-3), kompresia zstd, vytvorený 2026-11-04 08:35:10 (čas na stroji, kde sa export robil)
Tabuľky s údajmi: 57, z toho očakávaných 16 z 16
  public.organizations               obsahuje údaje (počet riadkov sa pri tejto kompresii nezisťuje)
  public.month_closures              prázdna
  auth.users                         obsahuje údaje (počet riadkov sa pri tejto kompresii nezisťuje)
V poriadku (nič sa neukladalo).
```

**Počty riadkov.** Export z Lovable je stlačený zstd, ktorý Python bez doplnkov nerozbalí, preto skript povie len „obsahuje údaje“ alebo „prázdna“. Presné počty riadkov dá snapshot (kap. 4) zo živej databázy. Archív sa pritom nerozbaľuje do databázy, takže **skutočnú obnoviteľnosť** potvrdí iba pg_restore.

**Obnova cez pg_restore.** Archív verzie 1.16 prečíta len `pg_restore` z PostgreSQL **17 alebo novšieho**. Starší (napríklad 16) skončí s `unsupported version (1.16) in file header`. Skript v takom prípade vypíše upozornenie, že archív je podľa vlastnej kontroly v poriadku, ale nainštalovaný `pg_restore` je príliš starý. Na obnovu si nainštalujte PostgreSQL 17 alebo novší.

Výsledok „V poriadku“ znamená, že archív je čitateľný a obsahuje očakávané tabuľky. **Problém** znamená: súbor ako zálohu nepoužívať a urobiť Export znova. Možnosti: `--iba-over` (nič neukladať), `--ulozit CESTA` (iný priečinok).

Bez Pythonu aspoň kontrolný súčet: `Get-FileHash -Algorithm SHA256 "C:\...\offline-dochs_261104.backup.zip"` v PowerShelli.

## 4. Snapshot priamo v databáze (poistka pred zásahom)

Skript `docs/zaloha/snapshot_pred_zasahom.sql` vytvorí v databáze novú schému `zaloha_RRRRMMDD_HHMM` s kópiami všetkých tabuliek (`public.*`, `auth.users`, `auth.identities`). Nič existujúce nemení. Kópie nie sú dostupné cez aplikáciu (žiadne práva pre prihlásených používateľov, zapnuté RLS).

1. Otvorte SQL editor v Lovable Cloud, vložte **celý** obsah súboru a spustite. Výsledkom je zoznam tabuliek s počtom riadkov.
2. Po zásahu spustite `docs/zaloha/porovnaj_so_snapshotom.sql`. Ukáže počty v snapshote a v živej databáze a rozdiel; riadky so zmenou sú hore.
3. Keď je všetko v poriadku, snapshot zmažte (názov je v prvom stĺpci výsledku):
   ```sql
   DROP SCHEMA zaloha_20261104_1030 CASCADE;
   ```

Snapshot **nie je záloha pre prípad straty databázy**: je v tej istej databáze, takže zaniká pri obnove z Lovable zálohy a nechráni pred chybou Lovable. Je to rýchla poistka proti vlastnej chybe pri ručnom zásahu. Obsahuje aj odtlačky hesiel z `auth.users`, preto ho po skončení prác zmažte.
Ak SQL editor odmietne zápis (`CREATE SCHEMA`), požiadajte Lovable agenta o **jednorazové spustenie** SQL (ako dotaz, nie ako migráciu), alebo sa spoľahnite na Export z kap. 2.

## 5. Návrat, keď sa zásah nepodaril

Od najmenšieho zásahu po najväčší:

1. **Chýbajú riadky v jednej tabuľke** (napr. omylom zmazaný riadok v `organization_settings`): dá sa vrátiť zo snapshotu, napríklad
   ```sql
   INSERT INTO public.organization_settings
   SELECT s.* FROM zaloha_20261104_1030.organization_settings s
    WHERE NOT EXISTS (SELECT 1 FROM public.organization_settings p WHERE p.organization_id = s.organization_id AND p.key = s.key);
   ```
   **Neplatí pre `punches`, `profiles`, `auth.users`** ani pre tabuľky s väzbami: razenia prechádzajú spúšťačom `punches_chain`, ktorý prepíše čas a hash (reťaz by sa porušila), a účty majú väzby na prihlásenie. Také veci nevracajte ručne, použite bod 2.
2. **Zásah pokazil viac vecí**: v Lovable **Backups → Restore to this backup** a vybrať najnovšiu zálohu pred zásahom. Stratíte všetko, čo vzniklo po nej (razenia, registrácie). Schéma sa vráti tiež, takže po obnove požiadajte Lovable agenta, aby otestoval aplikáciu a opravil prípadný nesúlad s kódom.
3. **Lovable zálohy nestačia** (staršie ako 14 dní, chyba Lovable): z Exportu sa dá archív načítať `pg_restore` (verzia 17 alebo novšia, pozri kap. 3) do **novej, prázdnej** databázy PostgreSQL na vlastnom počítači alebo vo vlastnom projekte a údaje sa z nej dajú vytiahnuť (`pg_restore --list` ukáže obsah). Do projektu v Lovable Cloud sa tak obnoviť nedá, to vie len Lovable.

Zrušená organizácia (migrácia 0007) sa dá obnoviť výlučne bodmi 2 a 3.

## 6. Uchovávanie a bezpečnosť

- Záloha obsahuje **prihlasovacie účty a odtlačky hesiel**. Ukladajte ju na šifrovaný disk (BitLocker) a nikdy ju nenahrávajte do repozitára ani do chatu. Repozitár je verejný; priečinok `zalohy/` a súbory `*.dump`, `*.backup`, `*.pgdump` sú v `.gitignore` a CI zlyhá, ak ich niekto pridá.
- Odporúčanie: pred každým ručným zásahom nový Export; staršie ponechať aspoň tri a jednu pred každým vydaním. Pravidelné zálohy dnes robí iba Lovable (14 dní).
- Pred zapísaním **reálnych** osobných čísel do ostrej organizácie overte u Lovable, kde sa zálohy ukladajú a kto k nim má prístup (otvorená úloha z `docs/ZACHRANA-A-NAVRAT.md`).

## 7. Aktuálny stav databázy pre Claude

Claude nemá prístup do databázy v Lovable Cloud (kap. 1), takže o aktuálnych dátach nevie nič, kým mu ich neukážete. Najjednoduchší spôsob je dotaz `docs/zaloha/stav_databazy.sql`: jeden SELECT, ktorý **len číta**, nič nezapisuje ani nevytvára a trvá sekundy.

1. Na GitHube otvorte `docs/zaloha/stav_databazy.sql` → **Raw** → skopírujte celý obsah.
2. V Lovable Cloud otvorte SQL editor, vložte a spustite (nič nezmení, netreba zálohu).
3. Výsledok uložte ako **CSV** (rovnako ako pri iných dotazoch) a priložte do chatu.

Výsledok má stĺpce `sekcia`, `polozka`, `hodnota` a obsahuje:

| Sekcia | Čo ukazuje |
|---|---|
| `00_prostredie` | čas, verzia servera, ako sa dotaz prihlásil, či vidí `auth.users` |
| `01_migracie` | ktoré zmeny (0003 až 0007) databáza naozaj obsahuje; nie čo je v repozitári |
| `02_tabulky` | každá tabuľka: počet riadkov, zapnuté RLS, počet pravidiel |
| `03_stlpce`, `04_funkcie`, `05_spustace`, `06_pravidla_rls` | štruktúra: stĺpce a typy, funkcie (oprávnenie a práva EXECUTE pre anon/authenticated), spúšťače, pravidlá RLS |
| `07_organizacie` | každá organizácia: identifikátor, názov, `is_test`, počet účtov, správcov, razení, zariadení, posledné razenie |
| `08_razenia`, `09_audit` | počty razení (celkom, neoverené, zneplatnené, po mesiacoch) a názvy akcií v audite s počtami |
| `10_kontroly` | súvislosti: profily bez roly, razenia bez hashu, organizácia bez správcu, účty bez profilu a opačne. `OK` alebo `POZOR n` |

**Čo vo výsledku nie je:** mená, e-maily, osobné čísla, odtlačky hesiel, tokeny zariadení, obsah razení ani podrobnosti auditu. **Čo v ňom je:** názvy a identifikátory organizácií a názvy stĺpcov. Do chatu ho poslať môžete, do verejného repozitára nepatrí.

Kedy ho spustiť: **pred zásahom do databázy a po ňom**, po každej migrácii a vždy, keď sa pýtate „čo je teraz v databáze“. Ak editor nemá právo čítať `auth.users`, dotaz nespadne, uvedie „bez práva“ a príslušné kontroly vynechá.

## Čo je overené a čo nie

Overené (lokálny PostgreSQL 16 s napodobeninou Supabase, `tools/sql_test/run.sh`): snapshot aj porovnanie prebehli, kópie majú rovnaké počty riadkov, rovnaký obsah `profiles`, zapnuté RLS a anon/authenticated k nim nemajú prístup.

**Skutočný export z Lovable (4. 11. 2026, `offline-dochs_261104.backup.zip`, 0,5 MB):** skript ho prečítal, všetkých 16 očakávaných tabuliek má údaje, `month_closures`, `punch_void_requests`, `personnel_requests` a `notification_preferences` sú prázdne. Nezávisle som údaje rozbalil (zstd) a spočítal riadky v jednotlivých tabuľkách: prázdne tabuľky sa zhodujú, `auth.users` a `profiles` majú rovnaký počet záznamov. Skript `over_zalohu.py` má testy (`tools/test_over_zalohu.py`: archívy 1.14, 1.15 a 1.16 zložené bajt po bajte, poškodený, useknutý a neúplný gzip, prázdne tabuľky, zip) a bol porovnaný s výpismi `pg_dump` 16 vo všetkých kompresiách (gzip, bez, zstd, lz4, výpis cez rúru): počty riadkov sa zhodujú s `COUNT(*)`, zoznam tabuliek so zoznamom z `pg_restore --list`.

**Dotaz `stav_databazy.sql`** má automatické testy (`tools/sql_test/stav_pred_0007.sql`, `stav_po_0007.sql`; spúšťa ich `tools/sql_test/run.sh` spolu s `0007_priprava.sql`): beží v transakcii READ ONLY, výstup neobsahuje e-maily ani osobné čísla, počty sedia s priamym počítaním, kontrola súvislostí vie hlásiť `POZOR`, beží pred aj po migrácii 0007 aj po zrušení organizácie a pri používateľovi bez práva na schému `auth`. **Neoverené:** správanie v skutočnom SQL editore Lovable (limit počtu riadkov a veľkosti výsledku, tlačidlo exportu).

**Neoverené:** skutočná obnova exportu do databázy (potrebuje `pg_restore` 17+, ktorý tu nebol k dispozícii); archívy s kompresiou lz4 a archívy zapísané do rúry skript číta len čiastočne (zoznam tabuliek áno, prázdnosť a počty nie); či Lovable SQL editor povolí zápis (`CREATE SCHEMA`); ako dlho trvá Export na väčšej databáze; obnova cez „Restore to this backup“ (nevyskúšaná, popis je z dokumentácie Lovable).
