-- SNAPSHOT PRED ZÁSAHOM: kópia všetkých tabuliek aplikácie (schéma public) a prihlasovacích účtov (auth.users, auth.identities)
-- do novej schémy zaloha_RRRRMMDD_HHMM priamo v tejto databáze. Pozri docs/ZALOHA-DATABAZY.md.
--
-- Na čo slúži: rýchla poistka pred ručným zásahom do databázy (napr. mazanie testovacej organizácie). Ak sa zásah nepodarí,
-- chýbajúce riadky sa dajú z kópie vrátiť (porovnanie: docs/zaloha/porovnaj_so_snapshotom.sql).
-- Na čo NESLÚŽI: nie je to záloha pre prípad straty databázy ani chyby Lovable. Tú robí Export v Lovable (tools/over_zalohu.py).
--
-- Čo skript robí: len vytvára novú schému a v nej kópie tabuliek (CREATE TABLE ... AS). Žiadne existujúce údaje nemení ani nemaže.
-- Kópie nemajú práva pre anon/authenticated/service_role a majú zapnuté RLS bez pravidiel, cez aplikáciu sa k nim nik nedostane.
-- Kópia obsahuje aj odtlačky hesiel z auth.users: patrí do tej istej databázy ako originál, ale po skončení prác ju zmažte (príkaz je na konci).
-- Spustite celý skript naraz (SQL editor v Lovable Cloud). Ak editor odmietne zápis, požiadajte Lovable agenta o jednorazové spustenie
-- tohto SQL ako dotazu, NIE ako migrácie (migrácia sa zapíše do histórie projektu).
-- Skript je bezpečný na opakovanie: v tej istej minúte skončí chybou, v inej minúte vytvorí ďalšiu kópiu.

DO $zaloha$
DECLARE
  sch text := 'zaloha_' || to_char(now() AT TIME ZONE 'Europe/Bratislava', 'YYYYMMDD_HH24MI');
  t record;
  cielova text;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = sch) THEN
    RAISE EXCEPTION 'Snapshot % už existuje. Počkajte minútu alebo ho zmažte (DROP SCHEMA % CASCADE).', sch, sch;
  END IF;
  EXECUTE format('CREATE SCHEMA %I', sch);
  EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', sch);
  FOR t IN
    SELECT schemaname, tablename FROM pg_tables
     WHERE schemaname = 'public' OR (schemaname = 'auth' AND tablename IN ('users', 'identities'))
     ORDER BY schemaname, tablename
  LOOP
    cielova := CASE WHEN t.schemaname = 'public' THEN t.tablename ELSE 'auth_' || t.tablename END;
    EXECUTE format('CREATE TABLE %I.%I AS TABLE %I.%I', sch, cielova, t.schemaname, t.tablename);
    EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', sch, cielova);
  END LOOP;
  FOR t IN SELECT rolname FROM pg_roles WHERE rolname IN ('anon', 'authenticated', 'service_role') LOOP
    EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM %I', sch, t.rolname);
    EXECUTE format('REVOKE ALL ON SCHEMA %I FROM %I', sch, t.rolname);
  END LOOP;
  EXECUTE format('COMMENT ON SCHEMA %I IS %L', sch, 'Snapshot pred zásahom (docs/ZALOHA-DATABAZY.md). Po skončení prác zmazať.');
END
$zaloha$;

-- Výsledok: počty riadkov v najnovšom snapshote (po úspechu sa zobrazí zoznam tabuliek).
SELECT s.table_schema AS snapshot, s.table_name AS tabulka,
       (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', s.table_schema, s.table_name), false, true, '')))[1]::text::bigint AS riadkov
  FROM information_schema.tables s
 WHERE s.table_schema = (SELECT max(nspname) FROM pg_namespace WHERE nspname LIKE 'zaloha\_%')
 ORDER BY s.table_name;

-- Zmazanie snapshotu, keď ho už netreba (názov dosaďte z hlavičky výsledku, napr. zaloha_20261104_1030):
--   DROP SCHEMA zaloha_RRRRMMDD_HHMM CASCADE;
