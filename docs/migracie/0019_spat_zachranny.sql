-- 0019 SPÄŤ: ZÁCHRANNÝ skript, ktorý vráti databázu do stavu pred migráciou 0019 (razenia po presťahovaní organizácie).
-- Spúšťajte ho len ak migrácia 0019 niečo pokazila alebo tieto funkcie nechcete používať. Aplikácia bez 0019 beží ďalej: terminál sa
-- o presťahovaní nedozvie (správanie ako pred 0019) a karta „Neskoré razenia“ v Servise len oznámi, že funkcia v databáze chýba.
-- Ak chcete vrátiť aj 0017 alebo 0016, spustite NAJPRV tento súbor, potom 0017_spat_zachranny.sql a až potom 0016_spat_zachranny.sql.
--
-- Čo urobí:
--   1. zruší spúšťač transfers_move_notice na tabuľke prenosov a jeho funkciu,
--   2. zruší funkcie punch_move_notice, org_transfer_set_destination, org_transfer_get_destination a late_punches_import,
--   3. zmaže tabuľku org_transfer.move_notices (oznamy o presťahovaní vrátane uložených nových adries) a pomocné funkcie.
-- Čo NErobí: nemaže razenia, ktoré už boli zo súboru nahraté (sú to bežné neoverené razenia v hash reťazi), ani riadky v audit_log.
-- Prenosy (0016) a importy (0017) ostávajú bez zmeny. Skript je opakovateľný.

DROP FUNCTION IF EXISTS public.punch_move_notice(uuid[]);
DROP FUNCTION IF EXISTS public.org_transfer_set_destination(text);
DROP FUNCTION IF EXISTS public.org_transfer_get_destination();
DROP FUNCTION IF EXISTS public.late_punches_import(jsonb, boolean);

DO $$
BEGIN
  IF to_regnamespace('org_transfer') IS NULL THEN RETURN; END IF;
  IF to_regclass('org_transfer.transfers') IS NOT NULL THEN
    DROP TRIGGER IF EXISTS transfers_move_notice ON org_transfer.transfers;
  END IF;
  DROP FUNCTION IF EXISTS org_transfer.transfers_move_notice();
  DROP TABLE IF EXISTS org_transfer.move_notices;
  DROP FUNCTION IF EXISTS org_transfer.user_hash(uuid);
  DROP FUNCTION IF EXISTS org_transfer.valid_destination(text);
  DROP FUNCTION IF EXISTS org_transfer.move_limits();
  DROP FUNCTION IF EXISTS org_transfer.move_version();
END $$;
