-- 0016 SPÄŤ: ZÁCHRANNÝ skript, ktorý vráti databázu do stavu pred migráciou 0016 (prenos organizácie, strana exportu).
-- Spúšťajte ho len ak migrácia 0016 niečo pokazila alebo prenos nechcete používať. Aplikácia bez 0016 beží ďalej bez zmeny
-- (obrazovka prenosu tieto funkcie potrebuje, kým nie je v kóde, nič iné od nich nezávisí).
--
-- Čo urobí:
--   1. zruší spúšťače a_punches_transfer_lock (zámok razení) a a_organizations_transfer_guard (ochrana pred predčasným zrušením),
--   2. zruší funkcie org_export_begin, org_export_page, org_export_finish, org_transfer_status, org_transfer_cancel,
--      org_transfer_confirm_and_delete a pomocné funkcie v schéme org_transfer,
--   3. zmaže tabuľku org_transfer.transfers (história prenosov),
--   4. zmaže schému org_transfer, ak v nej nezostalo nič iné (ak je nainštalovaný súkromný balík 0015, schéma a jeho funkcie ostanú).
-- Čo NErobí: nevracia označenie „testovacia organizácia“, ktoré nastavil prenos (vráťte ho tlačidlom v karte Servis alebo
-- set_organization_test(false)), a nemaže riadky v audit_log. Razenia ani údaje organizácií sa nemenia.
-- Zámok razení sa odstráni hneď spolu so spúšťačom. Skript je opakovateľný.

DROP TRIGGER IF EXISTS a_punches_transfer_lock ON public.punches;
DROP TRIGGER IF EXISTS a_organizations_transfer_guard ON public.organizations;
DROP FUNCTION IF EXISTS public.punches_transfer_lock();
DROP FUNCTION IF EXISTS public.organizations_transfer_guard();
DROP FUNCTION IF EXISTS public.org_export_begin(boolean);
DROP FUNCTION IF EXISTS public.org_export_page(uuid, text, integer, integer);
DROP FUNCTION IF EXISTS public.org_export_finish(uuid, jsonb);
DROP FUNCTION IF EXISTS public.org_transfer_status();
DROP FUNCTION IF EXISTS public.org_transfer_cancel();
DROP FUNCTION IF EXISTS public.org_transfer_confirm_and_delete(text, text, boolean);

DROP TABLE IF EXISTS org_transfer.transfers;
DROP FUNCTION IF EXISTS org_transfer.caller_org();
DROP FUNCTION IF EXISTS org_transfer.drift(uuid, jsonb);
DROP FUNCTION IF EXISTS org_transfer.drift_fp(uuid);
DROP FUNCTION IF EXISTS org_transfer.drift_cols();
DROP FUNCTION IF EXISTS org_transfer.receipt(jsonb);

-- Schéma sa zmaže len vtedy, ak neobsahuje funkcie súkromného balíka 0015 (import, odstránenie organizácie, kontroly).
DO $$
BEGIN
  IF to_regnamespace('org_transfer') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                     WHERE n.nspname = 'org_transfer' AND p.proname IN ('import_organization', 'export_organization', 'analyze', 'remove_organization')) THEN
    DROP SCHEMA org_transfer CASCADE;
  END IF;
END $$;
