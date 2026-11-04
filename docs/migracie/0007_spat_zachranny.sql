-- 0007 SPÄŤ: ZÁCHRANNÝ skript, ktorý vráti databázu do stavu pred migráciou 0007 (zrušenie testovacej organizácie).
-- NESPÚŠŤAJTE ho, kým nečítate docs/ZACHRANA-A-NAVRAT.md. Spúšťa sa len ak migrácia 0007 niečo pokazila a oprava dopredu nejde.
--
-- Čo urobí:
--   1. zruší funkcie delete_test_organization, purge_organization, test_organization_summary a set_organization_test,
--   2. vráti pôvodnú funkciu guard_last_admin (z migrácie 0002),
--   3. zmaže stĺpec organizations.is_test (zmaže sa informácia, ktoré organizácie boli označené ako testovacie).
-- Dáta organizácií sa nemenia. POZOR: už zrušené testovacie organizácie sa týmto NEOBNOVIA (vráti ich len záloha, docs/ZALOHA-DATABAZY.md).
-- Kód terminálu od PR s touto migráciou volá tieto funkcie len z obrazovky Správa → Testovacia organizácia, ostatné obrazovky nie sú dotknuté.
-- Skript je opakovateľný (pri druhom spustení nič nezmení).

DROP FUNCTION IF EXISTS public.delete_test_organization(text);
DROP FUNCTION IF EXISTS public.purge_organization(uuid);
DROP FUNCTION IF EXISTS public.test_organization_summary();
DROP FUNCTION IF EXISTS public.set_organization_test(boolean);

-- pôvodné znenie z drizzle/migrations/0002_organization_registration_and_isolation.sql
CREATE OR REPLACE FUNCTION public.guard_last_admin() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ DECLARE org uuid; BEGIN IF OLD.role='admin' THEN SELECT organization_id INTO org FROM public.profiles WHERE id=OLD.user_id; PERFORM pg_advisory_xact_lock(hashtext(org::text)); IF NOT EXISTS(SELECT 1 FROM public.user_roles r JOIN public.profiles p ON p.id=r.user_id WHERE r.role='admin' AND p.organization_id=org AND r.id<>OLD.id) THEN RAISE EXCEPTION 'Organizácia musí mať aspoň jedného správcu'; END IF; END IF; RETURN OLD; END $$;

ALTER TABLE public.organizations DROP COLUMN IF EXISTS is_test;
