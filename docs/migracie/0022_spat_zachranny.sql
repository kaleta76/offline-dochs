-- 0022 SPÄŤ: ZÁCHRANNÝ skript, ktorý vráti databázu do stavu pred migráciou 0022 (verzie nastavení výpočtu).
-- Spúšťajte ho len ak migrácia 0022 niečo pokazila. PORADIE: najprv vráťte aplikáciu na verziu spred etapy 1a (nová aplikácia bez
-- funkcií settings_* neukáže Môj mesiac ani Správu), potom spustite tento skript.
--
-- Čo urobí:
--   1. vráti org_transfer.spec() a org_transfer.import_refs() do podoby z migrácií 0016 a 0017,
--   2. zruší pohľad public.access_config a vráti na jeho miesto pôvodnú tabuľku zo schémy settings_archive; zapíše do nej poslednú
--      verziu z Accessu prijatú po migrácii (ak nejaká je),
--   3. v employee_month_plan nechá len plán poslednej verzie z Accessu a vráti pôvodný kľúč (organizácia, osobné číslo, mesiac),
--   4. do organization_settings a organization_holidays zapíše pravidlá (zaokrúhlenia, obed, fond) a sviatky z terminálovej verzie
--      platnej pre aktuálny mesiac, ak mesiac patrí terminálu (aby sa úpravy urobené po migrácii nestratili),
--   5. vráti klientovi právo volať import_access_config a zapisovať sviatky, zruší spúšťače, funkcie a tabuľky tejto migrácie.
-- ČO SA STRATÍ (nedá sa vrátiť inak než zo zálohy): história verzií nastavení (staršie verzie z Accessu a ich plány, staršie terminálové
-- verzie, platnosti od mesiaca), snímky uzavretých mesiacov vrátane uložených výsledkov, obmedzenie „vrátiť len poslednú uzávierku“.
-- Uzávierky (month_closures), razenia, hash reťaz a záznamy auditu ostávajú. Skript je opakovateľný.

DO $spat$
DECLARE r record; own boolean;
BEGIN
  IF to_regclass('public.settings_versions') IS NULL THEN
    RAISE NOTICE '0022 SPÄŤ: tabuľka settings_versions neexistuje, údaje sa nevracajú (len upratanie).';
    RETURN;
  END IF;

  -- 4. pravidlá a sviatky z platnej terminálovej verzie späť do pôvodných tabuliek
  ALTER TABLE public.organization_settings DISABLE TRIGGER USER;
  FOR r IN SELECT v.organization_id, v.config FROM public.settings_versions v
            WHERE v.origin = 'terminal' AND v.id = public.settings_version_for(v.organization_id, public.settings_month_now()) LOOP
    UPDATE public.organization_settings s SET value = x.v
      FROM (VALUES ('ZAOKRUHLENIE_PRICHOD', r.config -> 'rules' ->> 'rounding_in_min'),
                   ('ZAOKRUHLENIE_ODCHOD', r.config -> 'rules' ->> 'rounding_out_min'),
                   ('OBED_PAUZA_MIN', r.config -> 'rules' ->> 'auto_lunch_deduct_min'),
                   ('OBED_PO_HODINACH', trim(trailing '.' FROM trim(trailing '0' FROM round((r.config -> 'rules' ->> 'auto_lunch_trigger_min')::numeric / 60, 4)::text))),
                   ('DENNY_FOND_HODIN', trim(trailing '.' FROM trim(trailing '0' FROM round((r.config -> 'rules' ->> 'default_daily_fund_min')::numeric / 60, 4)::text)))) x(k, v)
     WHERE s.organization_id = r.organization_id AND s.key = x.k AND x.v IS NOT NULL;
    DELETE FROM public.organization_holidays h WHERE h.organization_id = r.organization_id;
    INSERT INTO public.organization_holidays (organization_id, day, name)
    SELECT r.organization_id, (h ->> 'date')::date, h ->> 'name' FROM jsonb_array_elements(r.config -> 'holidays') h
    ON CONFLICT (organization_id, day) DO NOTHING;
  END LOOP;
  ALTER TABLE public.organization_settings ENABLE TRIGGER USER;

  -- 3. plán: ostane len plán poslednej verzie z Accessu, pôvodný kľúč
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'employee_month_plan' AND column_name = 'version_id') THEN
    DELETE FROM public.employee_month_plan e
     WHERE e.version_id IS DISTINCT FROM (SELECT v.id FROM public.settings_versions v
                                           WHERE v.organization_id = e.organization_id AND v.origin = 'access' ORDER BY v.ord DESC LIMIT 1);
    ALTER TABLE public.employee_month_plan DROP CONSTRAINT IF EXISTS employee_month_plan_version_fk;
    ALTER TABLE public.employee_month_plan DROP CONSTRAINT IF EXISTS employee_month_plan_pkey;
    ALTER TABLE public.employee_month_plan DROP COLUMN version_id;
    ALTER TABLE public.employee_month_plan ADD CONSTRAINT employee_month_plan_pkey PRIMARY KEY (organization_id, personnel_number, month);
  END IF;

  -- 2. access_config späť ako tabuľka s poslednou verziou z Accessu
  IF (SELECT c.relkind FROM pg_class c WHERE c.oid = to_regclass('public.access_config')) = 'v' THEN
    DROP VIEW public.access_config;
  END IF;
  IF to_regclass('settings_archive.access_config') IS NOT NULL AND to_regclass('public.access_config') IS NULL THEN
    ALTER TABLE settings_archive.access_config SET SCHEMA public;
  END IF;
  IF to_regclass('public.access_config') IS NOT NULL THEN
    INSERT INTO public.access_config (organization_id, config_version, period_from, period_to, config, employees_count, employee_months_count, imported_at, imported_by)
    SELECT v.organization_id, v.config_version, v.period_from, v.period_to, v.config, v.employees_count, v.employee_months_count, v.created_at,
           (SELECT p.id FROM public.profiles p WHERE p.id = v.created_by)
      FROM public.settings_versions v
     WHERE v.origin = 'access' AND v.ord = (SELECT max(x.ord) FROM public.settings_versions x WHERE x.organization_id = v.organization_id AND x.origin = 'access')
    ON CONFLICT (organization_id) DO UPDATE
      SET config_version = EXCLUDED.config_version, period_from = EXCLUDED.period_from, period_to = EXCLUDED.period_to, config = EXCLUDED.config,
          employees_count = EXCLUDED.employees_count, employee_months_count = EXCLUDED.employee_months_count,
          imported_at = EXCLUDED.imported_at, imported_by = EXCLUDED.imported_by;
  END IF;
END
$spat$;

-- 1. prenos organizácie: zoznam tabuliek a odkazov ako v 0016 a 0017
CREATE OR REPLACE FUNCTION org_transfer.spec()
RETURNS TABLE(ord int, rel text, key_col text, filter text, order_by text, mode text, digest_exclude text[], null_cols text[])
LANGUAGE sql IMMUTABLE AS $$
SELECT * FROM (VALUES
 ( 1, 'public.organizations'           , 'id'                 , 'id = $1'                        , 'id'                              , 'rows', '{}'::text[]       , '{}'::text[]),
 ( 2, 'public.organization_settings'   , NULL::text           , 'organization_id = $1'           , 'key'                             , 'rows', '{}'               , '{}'),
 ( 3, 'public.organization_codes'      , NULL                 , 'organization_id = $1'           , 'code'                            , 'rows', '{}'               , '{}'),
 ( 4, 'public.organization_holidays'   , NULL                 , 'organization_id = $1'           , 'day'                             , 'rows', '{}'               , '{}'),
 ( 5, 'public.organization_invites'    , NULL                 , 'organization_id = $1'           , 'code'                            , 'rows', '{}'               , '{}'),
 ( 6, 'public.employee_month_plan'     , NULL                 , 'organization_id = $1'           , 'personnel_number, month'         , 'rows', '{}'               , '{}'),
 ( 7, 'auth.users'                     , 'id'                 , 'id = ANY({M})'                  , 'id'                              , 'ids' , '{}'               , '{}'),
 ( 8, 'auth.identities'                , 'id'                 , 'user_id = ANY({M})'             , 'id'                              , 'ids' , '{}'               , '{}'),
 ( 9, 'public.profiles'                , 'id'                 , 'organization_id = $1'           , 'id'                              , 'rows', '{}'               , '{manager_id}'),
 (10, 'public.access_config'           , NULL                 , 'organization_id = $1'           , 'organization_id'                 , 'rows', '{}'               , '{}'),
 (11, 'public.user_roles'              , NULL                 , 'user_id = ANY({M})'             , 'user_id, role::text'             , 'rows', '{}'               , '{}'),
 (12, 'public.devices'                 , 'id'                 , 'organization_id = $1'           , 'created_at, id'                  , 'rows', '{}'               , '{replaces_device_id}'),
 (13, 'public.punches'                 , 'id'                 , 'user_id = ANY({M})'             , 'id'                              , 'rows', '{id}'             , '{}'),
 (14, 'public.corrections'             , NULL                 , 'user_id = ANY({M})'             , 'created_at, id'                  , 'rows', '{punch_id}'       , '{}'),
 (15, 'public.punch_void_requests'     , NULL                 , 'user_id = ANY({M})'             , 'created_at, id'                  , 'rows', '{punch_id}'       , '{}'),
 (16, 'public.month_closures'          , NULL                 , 'user_id = ANY({M})'             , 'user_id, year, month'            , 'rows', '{}'               , '{}'),
 (17, 'public.personnel_requests'      , NULL                 , 'user_id = ANY({M})'             , 'created_at, id'                  , 'rows', '{}'               , '{}'),
 (18, 'public.notification_preferences', NULL                 , 'user_id = ANY({M})'             , 'user_id'                         , 'rows', '{}'               , '{}'),
 (19, 'public.correction_auto_approvals', NULL                , 'user_id = ANY({M})'             , 'user_id'                         , 'rows', '{}'               , '{}'),
 (20, 'public.audit_log'               , NULL                 , 'actor = ANY({M})'               , 'id'                              , 'rows', '{id}'             , '{}')
) v(ord, rel, key_col, filter, order_by, mode, digest_exclude, null_cols) ORDER BY ord
$$;

CREATE OR REPLACE FUNCTION org_transfer.import_refs() RETURNS TABLE(rel text, col text, kind text) LANGUAGE sql IMMUTABLE AS $$
SELECT * FROM (VALUES
 ('public.organizations', 'id', 'own'), ('public.organizations', 'created_by', 'user_loose'),
 ('public.organization_settings', 'organization_id', 'org'),
 ('public.organization_codes', 'organization_id', 'org'),
 ('public.organization_holidays', 'organization_id', 'org'),
 ('public.organization_invites', 'organization_id', 'org'),
 ('public.employee_month_plan', 'organization_id', 'org'),
 ('auth.identities', 'user_id', 'owner'),
 ('public.profiles', 'id', 'own'), ('public.profiles', 'organization_id', 'org'), ('public.profiles', 'manager_id', 'user'),
 ('public.access_config', 'organization_id', 'org'), ('public.access_config', 'imported_by', 'user'),
 ('public.user_roles', 'id', 'own'), ('public.user_roles', 'user_id', 'owner'),
 ('public.devices', 'id', 'own'), ('public.devices', 'organization_id', 'org'), ('public.devices', 'user_id', 'owner'),
 ('public.devices', 'replaces_device_id', 'device'), ('public.devices', 'approved_by', 'user_loose'), ('public.devices', 'revoked_by', 'user_loose'),
 ('public.punches', 'client_uuid', 'own'), ('public.punches', 'user_id', 'owner'), ('public.punches', 'device_id', 'device'),
 ('public.punches', 'void_request_id', 'void'),
 ('public.corrections', 'id', 'own'), ('public.corrections', 'user_id', 'owner'), ('public.corrections', 'decided_by', 'user_loose'),
 ('public.corrections', 'punch_id', 'punch'),
 ('public.punch_void_requests', 'id', 'own'), ('public.punch_void_requests', 'user_id', 'owner'), ('public.punch_void_requests', 'punch_id', 'punch'),
 ('public.punch_void_requests', 'requested_by', 'user_loose'), ('public.punch_void_requests', 'decided_by', 'user_loose'),
 ('public.month_closures', 'user_id', 'owner'), ('public.month_closures', 'closed_by', 'user_loose'),
 ('public.personnel_requests', 'id', 'own'), ('public.personnel_requests', 'user_id', 'owner'), ('public.personnel_requests', 'decided_by', 'user_loose'),
 ('public.notification_preferences', 'user_id', 'owner'),
 ('public.correction_auto_approvals', 'user_id', 'owner'), ('public.correction_auto_approvals', 'manager_id', 'owner'),
 ('public.audit_log', 'actor', 'owner')
) v(rel, col, kind)
$$;

-- 5. práva, spúšťače, funkcie, tabuľky
DO $prava$
BEGIN
  IF to_regprocedure('public.import_access_config(jsonb, boolean)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.import_access_config(jsonb, boolean) TO authenticated, service_role;
  END IF;
END
$prava$;
GRANT INSERT, DELETE ON public.organization_holidays TO authenticated;

DROP TRIGGER IF EXISTS settings_legacy_calc_guard ON public.organization_settings;
DROP TRIGGER IF EXISTS settings_default_version ON public.organizations;
DROP TRIGGER IF EXISTS month_closure_snapshot ON public.month_closures;
DROP TRIGGER IF EXISTS month_closure_only_last ON public.month_closures;

DROP FUNCTION IF EXISTS public.close_month(uuid, int, int, jsonb);
DROP FUNCTION IF EXISTS public.month_closure_store_result(uuid, int, int, jsonb);
DROP FUNCTION IF EXISTS public.month_result_problem(int, int, jsonb);
DROP FUNCTION IF EXISTS public.settings_unpair(date, text, boolean);
DROP FUNCTION IF EXISTS public.settings_import_access(jsonb, boolean, date, boolean);
DROP FUNCTION IF EXISTS public.settings_terminal_save(jsonb, date);
DROP FUNCTION IF EXISTS public.settings_validate_model(uuid, jsonb, date);
DROP FUNCTION IF EXISTS public.settings_insert_version(uuid, text, date, text, jsonb, text, date, date, int, int);
DROP FUNCTION IF EXISTS public.settings_version_config(uuid);
DROP FUNCTION IF EXISTS public.settings_timeline();
DROP FUNCTION IF EXISTS public.settings_for_month(date, uuid);
DROP FUNCTION IF EXISTS public.settings_version_meta(uuid);
DROP FUNCTION IF EXISTS public.settings_admin_org();
DROP FUNCTION IF EXISTS public.settings_check_valid_from(uuid, date);
DROP FUNCTION IF EXISTS public.settings_oldest_open(uuid);
DROP FUNCTION IF EXISTS public.settings_open_months(uuid);
DROP FUNCTION IF EXISTS public.settings_on_organization_insert();
DROP FUNCTION IF EXISTS public.settings_default_config(uuid, date);
DROP FUNCTION IF EXISTS public.settings_num(text, int, int, int, int);
DROP FUNCTION IF EXISTS public.settings_legacy_calc_guard();
DROP FUNCTION IF EXISTS public.month_closure_snapshot_insert();
DROP FUNCTION IF EXISTS public.month_closure_only_last();
DROP TABLE IF EXISTS public.month_closure_snapshots;
DROP FUNCTION IF EXISTS public.month_closure_snapshot_guard();
DROP FUNCTION IF EXISTS public.month_punch_fingerprint(uuid, int, int);
DROP FUNCTION IF EXISTS public.settings_version_for(uuid, date);
DROP FUNCTION IF EXISTS public.settings_month_now();
DROP TABLE IF EXISTS public.settings_versions;
DROP FUNCTION IF EXISTS public.settings_versions_immutable();
DROP SCHEMA IF EXISTS settings_archive;

NOTIFY pgrst, 'reload schema';
