-- 0017 SPÄŤ: ZÁCHRANNÝ skript, ktorý vráti databázu do stavu pred migráciou 0017 (prenos organizácie, strana importu).
-- Spúšťajte ho len ak migrácia 0017 niečo pokazila alebo import tlačidlom nechcete používať. Aplikácia bez 0017 beží ďalej bez zmeny
-- (karta importu v Servise len oznámi, že funkcia v databáze chýba). Export (0016) ostáva.
-- Ak chcete vrátiť aj 0016, spustite NAJPRV tento súbor a až potom 0016_spat_zachranny.sql.
--
-- Čo urobí:
--   1. zruší funkcie org_import_status, org_import_begin, org_import_chunk, org_import_check, org_import_commit, org_import_cancel,
--   2. zmaže odkladacie tabuľky org_transfer.import_rows a org_transfer.imports (rozpracované importy a história importov),
--   3. zruší pomocné funkcie importu v schéme org_transfer; funkcie spoločné so súkromným balíkom 0015 (check_environment,
--      suspend_triggers, resume_triggers) zruší len vtedy, ak balík 0015 nainštalovaný nie je.
-- Čo NErobí: nemaže organizácie, ktoré už boli importované, ani riadky v audit_log. Skript je opakovateľný.

DROP FUNCTION IF EXISTS public.org_import_status();
DROP FUNCTION IF EXISTS public.org_import_begin(text);
DROP FUNCTION IF EXISTS public.org_import_chunk(uuid, text, integer, text);
DROP FUNCTION IF EXISTS public.org_import_check(uuid);
DROP FUNCTION IF EXISTS public.org_import_commit(uuid, text);
DROP FUNCTION IF EXISTS public.org_import_cancel();

DO $$
BEGIN
  IF to_regnamespace('org_transfer') IS NULL THEN RETURN; END IF;
  DROP FUNCTION IF EXISTS org_transfer.import_target_problems(uuid, boolean);
  DROP FUNCTION IF EXISTS org_transfer.import_eligibility(uuid, uuid);
  DROP FUNCTION IF EXISTS org_transfer.import_insert(uuid, text, jsonb, text[], text, bigint);
  DROP FUNCTION IF EXISTS org_transfer.import_insert_auth(uuid, uuid);
  DROP TABLE IF EXISTS org_transfer.import_rows;
  DROP TABLE IF EXISTS org_transfer.imports;
  DROP FUNCTION IF EXISTS org_transfer.import_unclassified();
  DROP FUNCTION IF EXISTS org_transfer.import_refs();
  DROP FUNCTION IF EXISTS org_transfer.import_app_meta_keys();
  DROP FUNCTION IF EXISTS org_transfer.import_limits();
  DROP FUNCTION IF EXISTS org_transfer.import_version();
  -- spoločné so súkromným balíkom 0015: ak je nainštalovaný, patria jemu a ostávajú
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'org_transfer' AND p.proname IN ('import_organization', 'export_organization', 'analyze', 'remove_organization')) THEN
    DROP FUNCTION IF EXISTS org_transfer.check_environment();
    DROP FUNCTION IF EXISTS org_transfer.suspend_triggers();
    DROP FUNCTION IF EXISTS org_transfer.resume_triggers(jsonb);
  END IF;
END $$;
