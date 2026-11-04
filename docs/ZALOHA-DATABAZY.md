# Záloha a návrat databázy (Lovable Cloud)

Postup pred každým ručným zásahom do databázy (mazanie testovacej organizácie, oprava údajov, spúšťanie SQL z chatu). Platí od 4. 11. 2026.

## Skrátene

1. **Export v Lovable** a stiahnutie súboru (kap. 2). Raz za 24 hodín, trvá niekoľko minút.
2. **Overenie a uloženie** stiahnutého súboru skriptom `tools/over_zalohu.py` (kap. 3).
3. **Snapshot v databáze** skriptom `docs/zaloha/snapshot_pred_zasahom.sql` (kap. 4): rýchla poistka priamo v databáze.
4. Zásah.
5. **Porovnanie** so snapshotom: `docs/zaloha/porovnaj_so_snapshotom.sql`. Zmeniť sa smú len tabuľky, v ktorých ste zasahovali.
6. Keď je všetko v poriadku, **zmažte snapshot** (kap. 4). Súbor z Exportu si nechajte.

## 1. Čo Lovable Cloud poskytuje

Podľa dokumentácie Lovable ([Database backups](https://docs.lovable.dev/features/database-backups), stav k 4. 11. 2026):

| Možnosť | Kde | Poznámky |
|---|---|---|
| **Denné zálohy** | More → Database → Manage → Backups | Lovable ich robí sám, drží približne 14 dní, každá má časovú značku UTC. Zahŕňajú štruktúru aj údaje, nie súbory v Storage. |
| **Obnova zo zálohy** | tlačidlo „Restore to this backup“ pri zálohe | Vráti **celú databázu** (štruktúru aj údaje) a **zmaže všetko, čo vzniklo po záloze**. Databáza je pár minút nedostupná. Nedá sa vrátiť späť. Smie ju spraviť každý s právom upravovať projekt. |
| **Export celej databázy** | More → Database → Manage → Settings → Export data → Export → Start export | Komprimovaný archív PostgreSQL (štruktúra, údaje, prihlasovacie účty aj odtlačky hesiel), na načítanie cez `pg_restore`. Lovable pošle e-mail a súbor uloží do projektu (More → Storage). Jeden export za 24 hodín, databáza do 15 GB. Neobsahuje súbory zo Storage, tajné hodnoty ani nastavenia prihlásenia. |
| **CSV jednej tabuľky** | More → Database → pohľad na tabuľku | Len jedna tabuľka naraz, na rýchlu kontrolu. |

Názvy ponúk sa v Lovable menia; ak niečo nenájdete, hľadajte „Database“ → „Backups“ / „Export“.

## Prečo nie je skript, ktorý sa sám pripojí a stiahne databázu

Lovable Cloud **nedáva** používateľovi adresu databázy, heslo ani servisný kľúč, takže `pg_dump` ani skript s kľúčom použiť nemožno. Spôsob „vytvoriť v aplikácii tajný koncový bod, ktorý vydá celú databázu“ by cez jeden uniknutý token sprístupnil údaje **všetkých** firiem, preto ho do aplikácie nepridávame.
Stiahnutie preto robí tlačidlo Export a skript z repozitára robí to, čo sa s hotovým súborom dá: overí ho, spočíta SHA-256 a uloží.

## 2. Export a stiahnutie

1. V Lovable otvorte projekt: **More → Database → Manage → Settings → Export data → Export → Start export**.
2. Počkajte na e-mail od Lovable (databáza je malá, trvá to minúty).
3. **More → Storage**: stiahnite súbor so zálohou na počítač (napr. do `Stiahnuté`). Ak Lovable ponúka aj kontrolný súčet, poznačte si ho.

## 3. Overenie a uloženie stiahnutého súboru

Potrebný je Python 3 (na Windowse príkaz `py`, inštalácia z python.org alebo Microsoft Store). Voliteľne PostgreSQL (nástroj `pg_restore`): s ním skript overí aj zoznam tabuliek vo vnútri archívu.

V koreni repozitára (priečinok, kde je `README.md`):

```
py -3 -I tools\over_zalohu.py "C:\Users\vy\Downloads\export.dump"
```

(na Linuxe a macOS `python3 -I tools/over_zalohu.py ...`). Skript:

- skontroluje, že súbor nie je prázdny ani useknutý, a rozpozná formát (pg_dump, tar, gzip, zip, SQL),
- overí, že vo vnútri sú **údaje** všetkých tabuliek aplikácie (`organizations`, `profiles`, `user_roles`, `punches`, `devices`, `audit_log`, `organization_*`, `corrections`, `month_closures`, `punch_void_requests`, `personnel_requests`, `notification_preferences`) aj prihlasovacích účtov `auth.users`,
- vypíše SHA-256 (ak máte kontrolný súčet z Lovable, pridajte `--sha256 HEX`),
- uloží kópiu do `zalohy\RRRR-MM-DD_HHMM\` aj so súborom `.sha256` a `manifest.json`, kópia je len na čítanie.

Výsledok „V poriadku“ znamená, že archív je čitateľný a obsahuje očakávané tabuľky. **Problém** znamená: súbor ako zálohu nepoužívať a urobiť Export znova. Možnosti: `--iba-over` (nič neukladať), `--ulozit CESTA` (iný priečinok).

Bez Pythonu aspoň kontrolný súčet: `Get-FileHash -Algorithm SHA256 "C:\...\export.dump"` v PowerShelli.

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
3. **Lovable zálohy nestačia** (staršie ako 14 dní, chyba Lovable): z Exportu sa dá archív načítať `pg_restore` do **novej, prázdnej** databázy PostgreSQL na vlastnom počítači alebo vo vlastnom projekte a údaje sa z nej dajú vytiahnuť (`pg_restore --list` ukáže obsah). Do projektu v Lovable Cloud sa tak obnoviť nedá, to vie len Lovable.

Zrušená organizácia (migrácia 0007) sa dá obnoviť výlučne bodmi 2 a 3.

## 6. Uchovávanie a bezpečnosť

- Záloha obsahuje **prihlasovacie účty a odtlačky hesiel**. Ukladajte ju na šifrovaný disk (BitLocker) a nikdy ju nenahrávajte do repozitára ani do chatu. Repozitár je verejný; priečinok `zalohy/` a súbory `*.dump`, `*.backup`, `*.pgdump` sú v `.gitignore` a CI zlyhá, ak ich niekto pridá.
- Odporúčanie: pred každým ručným zásahom nový Export; staršie ponechať aspoň tri a jednu pred každým vydaním. Pravidelné zálohy dnes robí iba Lovable (14 dní).
- Pred zapísaním **reálnych** osobných čísel do ostrej organizácie overte u Lovable, kde sa zálohy ukladajú a kto k nim má prístup (otvorená úloha z `docs/ZACHRANA-A-NAVRAT.md`).

## Čo je overené a čo nie

Overené (lokálny PostgreSQL 16 s napodobeninou Supabase, `tools/sql_test/run.sh`): snapshot aj porovnanie prebehli, kópie majú rovnaké počty riadkov, rovnaký obsah `profiles`, zapnuté RLS a anon/authenticated k nim nemajú prístup. Skript `over_zalohu.py` prešiel testami (`tools/test_over_zalohu.py`) a skúškou na skutočných výpisoch `pg_dump` vo formátoch custom, tar, tar.gz (adresárový), SQL a SQL.gz; výpis bez údajov o razeniach správne odmietol.

**Neoverené:** presný formát súboru, ktorý Lovable vyrobí (preto skript rozpoznáva viac formátov); či Lovable SQL editor povolí zápis (`CREATE SCHEMA`); ako dlho trvá Export na ostrej databáze; obnova cez „Restore to this backup“ (nevyskúšaná, popis je z dokumentácie Lovable).
