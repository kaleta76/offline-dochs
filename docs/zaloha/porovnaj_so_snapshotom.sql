-- POROVNANIE ŽIVEJ DATABÁZY S NAJNOVŠÍM SNAPSHOTOM (docs/ZALOHA-DATABAZY.md). Nič nemení, len číta.
-- Po zásahu ukáže, v ktorých tabuľkách sa počet riadkov zmenil. Očakávajte zmeny len tam, kde ste zasahovali
-- (napr. po zrušení testovacej organizácie: profiles, user_roles, punches, devices, organization_*, auth_users ...).
-- Stĺpec rozdiel = živých minus v snapshote (záporné číslo = riadky ubudli).

SELECT p.snapshot, p.tabulka, p.v_snapshote, p.zive, p.zive - p.v_snapshote AS rozdiel
  FROM (
    SELECT s.table_schema AS snapshot, s.table_name AS tabulka,
           (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', s.table_schema, s.table_name), false, true, '')))[1]::text::bigint AS v_snapshote,
           (xpath('/row/c/text()', query_to_xml(
              format('SELECT count(*) AS c FROM %s',
                     CASE WHEN s.table_name LIKE 'auth\_%' THEN 'auth.' || substr(s.table_name, 6) ELSE 'public.' || quote_ident(s.table_name) END),
              false, true, '')))[1]::text::bigint AS zive
      FROM information_schema.tables s
     WHERE s.table_schema = (SELECT max(nspname) FROM pg_namespace WHERE nspname LIKE 'zaloha\_%')
  ) p
 ORDER BY (p.zive <> p.v_snapshote) DESC, p.tabulka;
