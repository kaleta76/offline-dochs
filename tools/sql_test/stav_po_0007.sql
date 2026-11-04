-- Testy docs/zaloha/stav_databazy.sql PO migrácii 0007 (spustené po 0007_priprava.sql, stav_pred_0007.sql a migrácii 0007).
\set q `cat "$ZALOHA_DIR/stav_databazy.sql"`
SELECT length(:'q') > 5000 AS nacitane \gset
SELECT t.ok(:'nacitane'::boolean, 'skript stav_databazy.sql sa načítal (neprázdny)');

BEGIN READ ONLY;
:q
COMMIT;

CREATE TABLE t.stav2 AS :q

-- 1. Po 0007: všetkých päť značiek hlási "ano", organizácie majú príznak is_test = false.
SELECT t.ok((SELECT count(*) FROM t.stav2 WHERE sekcia = '01_migracie' AND polozka LIKE '0007 %' AND hodnota = 'ano') = 5, 'päť značiek 0007 je "ano"');
SELECT t.ok((SELECT count(*) FROM t.stav2 WHERE sekcia = '07_organizacie' AND hodnota LIKE 'is_test=false;%') = 3, 'organizácie majú is_test=false');
SELECT t.ok((SELECT count(*) FROM t.stav2 WHERE sekcia = '04_funkcie' AND polozka LIKE 'purge_organization(%') = 1, 'funkcia purge_organization je vo výpise');
-- purge_organization smie volať len správca databázy: anon ani authenticated nemajú EXECUTE.
SELECT t.ok((SELECT hodnota FROM t.stav2 WHERE sekcia = '04_funkcie' AND polozka LIKE 'purge_organization(%') LIKE '%anon_exec=false; authenticated_exec=false;%', 'výpis ukazuje, že purge_organization nie je pre anon ani authenticated');
SELECT t.ok((SELECT hodnota FROM t.stav2 WHERE sekcia = '04_funkcie' AND polozka LIKE 'delete_test_organization(%') LIKE '%authenticated_exec=true;%', 'delete_test_organization je pre authenticated');

-- 2. Označenie testovacej organizácie sa prejaví vo výpise.
UPDATE public.organizations SET is_test = true WHERE name = 'TEST A';
CREATE TABLE t.stav3 AS :q
SELECT t.ok((SELECT count(*) FROM t.stav3 WHERE sekcia = '07_organizacie' AND polozka LIKE '% TEST A' AND hodnota LIKE 'is_test=true;%') = 1, 'TEST A je vo výpise označená ako testovacia');
SELECT t.ok((SELECT count(*) FROM t.stav3 WHERE sekcia = '07_organizacie' AND hodnota LIKE 'is_test=false;%') = 2, 'ostatné organizácie ostali is_test=false');

-- 3. Po zrušení organizácie zmizne z výpisu a kontroly súvislostí ostanú v poriadku (žiadne siroty).
SELECT id AS org_a FROM public.organizations WHERE name = 'TEST A' \gset
SELECT public.purge_organization(:'org_a'::uuid);
CREATE TABLE t.stav4 AS :q
SELECT t.ok((SELECT count(*) FROM t.stav4 WHERE sekcia = '07_organizacie') = 2, 'po zrušení sú vo výpise dve organizácie');
SELECT t.ok(NOT EXISTS (SELECT 1 FROM t.stav4 WHERE sekcia = '07_organizacie' AND polozka LIKE '% TEST A'), 'TEST A už vo výpise nie je');
SELECT t.ok(NOT EXISTS (SELECT 1 FROM t.stav4 WHERE sekcia = '10_kontroly' AND hodnota <> 'OK'), 'po zrušení nezostali žiadne siroty (všetky kontroly OK)');
SELECT t.ok((SELECT hodnota FROM t.stav4 WHERE sekcia = '02_tabulky' AND polozka = 'auth.users') LIKE 'riadkov=3;%', 'v auth.users ostali 3 účty (B1, B2, pôvodná organizácia)');
SELECT t.ok(NOT EXISTS (SELECT 1 FROM t.stav4 WHERE polozka || ' ' || hodnota ~* '(@|9000|passw|hesl)'), 'ani po 0007 výstup neobsahuje osobné údaje');
-- organization.deleted je v audite len ako názov akcie s počtom, bez podrobností
SELECT t.ok((SELECT hodnota FROM t.stav4 WHERE sekcia = '09_audit' AND polozka = 'organization.deleted') LIKE 'celkom=1;%', 'zrušenie je v audite ako jedna akcia');
-- 4. docs/zaloha/kontrola_0007.sql po migrácii.
\set k `cat "$ZALOHA_DIR/kontrola_0007.sql"`
CREATE TABLE t.kontrola2 AS :k
SELECT t.ok((SELECT stlpec_is_test AND funkcie_0007 = 4 AND NOT purge_pre_authenticated AND purge_pre_service_role FROM t.kontrola2), 'po migrácii: stĺpec aj 4 funkcie existujú, purge_organization nie je pre authenticated, je pre service_role');
SELECT t.ok((SELECT smie_vytvarat_v_public AND vlastni_organizations AND vlastni_guard_last_admin AND smie_mazat_auth_users FROM t.kontrola2), 'po migrácii: práva správcu databázy ostali');
DROP TABLE t.kontrola2;
DROP TABLE t.stav2, t.stav3, t.stav4, t.stav;
