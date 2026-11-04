-- Testy docs/zaloha/stav_databazy.sql PRED migráciou 0007 (spustené po 0007_priprava.sql, bez migrácie 0007).
-- Skript sa načíta zo súboru (premenná prostredia ZALOHA_DIR nastavuje tools/sql_test/run.sh).
\set q `cat "$ZALOHA_DIR/stav_databazy.sql"`
SELECT length(:'q') > 5000 AS nacitane \gset
SELECT t.ok(:'nacitane'::boolean, 'skript stav_databazy.sql sa načítal (neprázdny)');

-- 1. Dotaz je len na čítanie: v transakcii READ ONLY prejde bez chyby.
BEGIN READ ONLY;
:q
COMMIT;

CREATE TABLE t.stav AS :q

SELECT t.ok((SELECT count(*) FROM t.stav) > 100, 'výstup má stovky riadkov (schéma, funkcie, pravidlá, organizácie)');
SELECT t.ok((SELECT count(DISTINCT sekcia) FROM t.stav) = 11, 'všetkých 11 sekcií (00 až 10)');

-- 2. Pred 0007: značky migrácie 0007 hlásia "nie", staršie "ano"; stĺpec is_test chýba, dotaz napriek tomu prejde.
SELECT t.ok((SELECT count(*) FROM t.stav WHERE sekcia = '01_migracie' AND polozka LIKE '0007 %' AND hodnota = 'nie') = 5, 'päť značiek 0007 je "nie"');
SELECT t.ok((SELECT count(*) FROM t.stav WHERE sekcia = '01_migracie' AND polozka ~ '^000[356] ' AND hodnota = 'ano') = 5, 'značky 0003, 0005, 0006 sú "ano"');
SELECT t.ok((SELECT count(*) FROM t.stav WHERE sekcia = '07_organizacie' AND hodnota LIKE 'is_test=stlpec chyba;%') = 3, 'organizácie bez stĺpca is_test');

-- 3. Počty organizácií, účtov a razení sedia s priamym počítaním.
SELECT t.ok(NOT EXISTS (
  SELECT 1 FROM public.organizations o
   WHERE NOT EXISTS (
     SELECT 1 FROM t.stav s
      WHERE s.sekcia = '07_organizacie' AND s.polozka = o.id::text || ' ' || o.name
        AND s.hodnota LIKE '%; ucty=' || (SELECT count(*) FROM public.profiles p WHERE p.organization_id = o.id) || '; %'
        AND s.hodnota LIKE '%; razenia=' || (SELECT count(*) FROM public.punches x JOIN public.profiles p ON p.id = x.user_id WHERE p.organization_id = o.id) || '; %')
), 'každá organizácia má správny počet účtov a razení');
SELECT t.ok((SELECT hodnota FROM t.stav WHERE sekcia = '08_razenia' AND polozka = 'celkom') = (SELECT count(*)::text FROM public.punches), 'počet razení celkom');
SELECT t.ok((SELECT count(*) FROM t.stav WHERE sekcia = '02_tabulky' AND polozka LIKE 'public.%') = (SELECT count(*) FROM pg_tables WHERE schemaname = 'public'), 'každá tabuľka public je vo výpise');
SELECT t.ok((SELECT hodnota FROM t.stav WHERE sekcia = '02_tabulky' AND polozka = 'public.punches') LIKE 'riadkov=' || (SELECT count(*) FROM public.punches) || ';%', 'počet riadkov tabuľky punches');
SELECT t.ok(NOT EXISTS (SELECT 1 FROM t.stav WHERE sekcia = '02_tabulky' AND polozka LIKE 'public.%' AND hodnota LIKE '%rls=VYPNUTE%'), 'všetky tabuľky public majú zapnuté RLS');

-- 4. Výstup neobsahuje osobné údaje (v údajoch prípravy sú e-maily a osobné čísla 9000001 a podobne).
SELECT t.ok(NOT EXISTS (SELECT 1 FROM t.stav WHERE polozka || ' ' || hodnota ~* '(@|9000|passw|hesl)'), 'výstup neobsahuje e-maily, osobné čísla ani heslá');
-- Názvy stĺpcov a argumentov so slovom token sú v poriadku (sú to názvy), hodnoty tokenov sa nikde nečítajú.
SELECT t.ok(NOT EXISTS (SELECT 1 FROM t.stav WHERE sekcia NOT IN ('03_stlpce', '04_funkcie') AND polozka || ' ' || hodnota ~* 'token'), 'mimo schémy sa slovo token nevyskytuje');
SELECT t.ok(NOT EXISTS (SELECT 1 FROM t.stav WHERE sekcia = '09_audit' AND polozka ~ '[0-9a-f]{8}-[0-9a-f]{4}-'), 'audit neobsahuje identifikátory autorov ani cieľov');

-- 5. Dotaz je opakovateľný: dva behy dajú rovnaký výstup (okrem času).
CREATE TABLE t.stav_b AS :q
SELECT t.ok((SELECT md5(string_agg(sekcia || polozka || hodnota, '|' ORDER BY sekcia, polozka)) FROM t.stav WHERE sekcia <> '00_prostredie')
          = (SELECT md5(string_agg(sekcia || polozka || hodnota, '|' ORDER BY sekcia, polozka)) FROM t.stav_b WHERE sekcia <> '00_prostredie'), 'dva behy dajú rovnaký výstup');

-- 6. Kontroly súvislostí vedia hlásiť problém: organizácia bez správcu.
BEGIN;
INSERT INTO public.organizations (name) VALUES ('BEZ SPRAVCU');
CREATE TEMP TABLE stav_c AS :q
SELECT t.ok((SELECT hodnota FROM stav_c WHERE sekcia = '10_kontroly' AND polozka = 'organizácie bez správcu') = 'POZOR 1', 'organizácia bez správcu sa ohlási ako POZOR 1');
SELECT t.ok((SELECT count(*) FROM stav_c WHERE sekcia = '07_organizacie') = 4, 'nová organizácia je vo výpise');
ROLLBACK;
SELECT t.ok((SELECT count(*) FROM public.organizations) = 3, 'skúšobná organizácia sa vrátila späť');

-- 7. Používateľ bez práva na schému auth (napr. obmedzený editor): dotaz nespadne a uvedie "bez práva".
CREATE ROLE editor_sql NOLOGIN BYPASSRLS;
GRANT USAGE ON SCHEMA public TO editor_sql;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO editor_sql;
SET ROLE editor_sql;
CREATE TEMP TABLE stav_o AS :q
RESET ROLE;
SELECT t.ok((SELECT hodnota FROM stav_o WHERE sekcia = '00_prostredie' AND polozka = 'cita_auth_users') LIKE 'nie%', 'obmedzený používateľ: auth.users sa nečíta');
SELECT t.ok((SELECT hodnota FROM stav_o WHERE sekcia = '02_tabulky' AND polozka = 'auth.users') LIKE 'riadkov=bez práva%', 'obmedzený používateľ: auth.users je "bez práva"');
SELECT t.ok((SELECT hodnota FROM stav_o WHERE sekcia = '10_kontroly' AND polozka = 'profily bez účtu v auth.users') = 'nezistene (bez práva)', 'obmedzený používateľ: kontrola auth je "nezistene"');
SELECT t.ok((SELECT hodnota FROM stav_o WHERE sekcia = '10_kontroly' AND polozka = 'profily bez roly') = 'OK', 'obmedzený používateľ: ostatné kontroly bežia');
SELECT t.ok((SELECT count(*) FROM stav_o WHERE sekcia = '07_organizacie') = 3, 'obmedzený používateľ: organizácie sú vo výpise');
DROP TABLE t.stav_b;
DROP OWNED BY editor_sql;
DROP ROLE editor_sql;
