-- 0022: nastavenia výpočtu ako verzie s platnosťou od mesiaca (etapa 1a, docs/ARCHITEKTURA.md kapitola 5, docs/VERZIE-NASTAVENI.md).
--
-- Čo táto migrácia robí:
--   1. Nová tabuľka settings_versions: každá verzia nastavení výpočtu organizácie (terminálová alebo z Accessu) je jeden NEMENNÝ riadok
--      s modelom v tvare kontraktu 1.5.0 (bez zamestnancov) a s „platí od mesiaca“ (valid_from). Úprava = nový riadok, nič sa neprepisuje.
--      Pre mesiac platí verzia s najvyšším poradím (ord) spomedzi tých, ktorých valid_from nie je neskôr než mesiac. Pôvod tej verzie
--      (terminal / access) určuje, komu mesiac patrí.
--   2. Dnešné úložisko poslednej konfigurácie z Accessu (tabuľka access_config) sa presunie do schémy settings_archive (ostane celé, kvôli
--      návratu) a pod pôvodným menom public.access_config vznikne POHĽAD s rovnakými stĺpcami: ukazuje verziu z Accessu platnú pre aktuálny
--      mesiac. Čítajú ho automatické schvaľovanie opráv (request_correction) a staršia aplikácia v zariadeniach; obe ostávajú bez zmeny.
--   3. employee_month_plan dostane stĺpec version_id a kľúč (organizácia, verzia, osobné číslo, mesiac): plán patrí verzii, s ktorou prišiel.
--      Nový import už starší plán neprepíše ani nezmaže.
--   4. Každá organizácia dostane terminálovú verziu zo svojich dnešných hodnôt (organization_settings, organization_codes,
--      organization_holidays); nová organizácia ju dostane pri registrácii (spúšťač na organizations, tá istá transakcia).
--      Tieto tri tabuľky sa NEMAŽÚ ani nemenia. Výpočtové kľúče a sviatky sa z nich už nečítajú; ich priamu zmenu zo staršej aplikácie
--      databáza odmietne (inak by sa zmena ticho stratila).
--   5. Uzavretý mesiac: pri vložení uzávierky (month_closures) databáza sama uloží snímku (month_closure_snapshots): verziu nastavení,
--      denný fond zamestnanca a odtlačok razení. Výsledok mesiaca do nej raz zapíše ten, kto uzatvára (close_month). Uzavretý mesiac sa
--      číta zo snímky, nikdy z časovej osi. Vrátiť sa dá len POSLEDNÁ uzávierka zamestnanca (potom sa dá uzavrieť znova s novým výpočtom).
--   6. Funkcie pre aplikáciu (malé RPC s pevnými kľúčmi): settings_for_month, settings_timeline, settings_version_config,
--      settings_terminal_save, settings_import_access, settings_unpair, close_month.
--   7. Prenos organizácie: nové tabuľky sú v org_transfer.spec() a ich odkazy v org_transfer.import_refs().
--
-- Čo sa NEMENÍ: tabuľky punches a profiles, spúšťač punches_chain a vzorec hash reťaze, export razení, prijatie razenia do uzavretého
-- mesiaca (is_closed, month_closures ako doteraz), kto smie mesiac uzavrieť (politiky month_closures), kontrola súboru z Accessu
-- (import_access_config sa volá nanečisto a ostáva jedinou kontrolou; jej telo sa tu nemení ani neopakuje).
--
-- Bezpečnosť: do settings_versions a month_closure_snapshots klient nezapisuje ani nečíta priamo (žiadne práva; RLS zapnuté bez politík).
-- Zapisujú len funkcie SECURITY DEFINER s prázdnym search_path, ktoré overia prihlásenie, rolu správcu a vlastnú organizáciu. Nemennosť
-- verzií stráži spúšťač (platí aj pre funkcie). Všetky zmeny idú do audit_log (bez obsahu nastavení).
--
-- Predpoklady: 0000 až 0021 vrátane súkromných balíkov 0008, 0009, 0013, 0014 (access_config, employee_month_plan, import_access_config).
-- Skript je opakovateľný. Spúšťa sa celý naraz v novej prázdnej karte SQL editora. PORADIE NASADENIA: najprv táto migrácia, potom
-- aplikácia. Pred spustením urobte zálohu: docs/ZALOHA-DATABAZY.md. Návrat: 0022_spat_zachranny.sql.
-- Súkromný balík 0015 (operátorský prenos cez psql) má vlastnú kópiu org_transfer.spec(): po tejto migrácii ho neinštalujte znova
-- v staršej verzii, prepísal by zoznam tabuliek (export by sa potom odmietol s hlásením o neznámych tabuľkách, nič by sa nestratilo).

DO $predpoklady$
BEGIN
  IF to_regclass('public.organizations') IS NULL OR to_regclass('public.profiles') IS NULL OR to_regclass('public.audit_log') IS NULL
     OR to_regclass('public.month_closures') IS NULL OR to_regclass('public.employee_month_plan') IS NULL
     OR to_regclass('public.organization_settings') IS NULL OR to_regclass('public.organization_holidays') IS NULL
     OR to_regclass('public.access_config') IS NULL
     OR to_regprocedure('public.my_organization()') IS NULL OR to_regprocedure('public.has_role(uuid, public.app_role)') IS NULL
     OR to_regprocedure('public.can_see(uuid)') IS NULL OR to_regprocedure('public.import_access_config(jsonb, boolean)') IS NULL THEN
    RAISE EXCEPTION '0022: chýbajú objekty aplikácie (migrácie 0000 až 0014 vrátane balíkov 0008 a 0009). Nič sa nezmenilo.';
  END IF;
  IF to_regprocedure('org_transfer.spec()') IS NULL OR to_regprocedure('org_transfer.import_refs()') IS NULL THEN
    RAISE EXCEPTION '0022: chýbajú migrácie 0016 a 0017 (prenos organizácie). Nič sa nezmenilo.';
  END IF;
END
$predpoklady$;

-- ===================================================================================================== 1. verzie nastavení
CREATE TABLE IF NOT EXISTS public.settings_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  ord integer NOT NULL CHECK (ord > 0),
  origin text NOT NULL CHECK (origin IN ('terminal', 'access')),
  valid_from date CHECK (valid_from = date_trunc('month', valid_from)::date),
  reason text NOT NULL CHECK (reason IN ('registration', 'backfill', 'edit', 'import', 'unpair_access', 'unpair_terminal')),
  config jsonb NOT NULL CHECK (jsonb_typeof(config) = 'object'),
  config_version text,
  period_from date,
  period_to date,
  employees_count integer,
  employee_months_count integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  UNIQUE (organization_id, ord),
  UNIQUE (organization_id, id),
  CHECK ((origin = 'access') = (config_version IS NOT NULL)),
  CHECK (origin = 'access' OR valid_from IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS settings_versions_access_version_idx ON public.settings_versions (organization_id, config_version) WHERE origin = 'access';
COMMENT ON TABLE public.settings_versions IS
  'Verzie nastavení výpočtu organizácie (terminálové a z Accessu), model v tvare kontraktu 1.5.0 bez zamestnancov. Riadky sú nemenné; zapisujú len funkcie settings_*.';
COMMENT ON COLUMN public.settings_versions.valid_from IS 'Platí od mesiaca (prvý deň). NULL = verzia z Accessu uložená bez platnosti (na časovej osi nie je).';
COMMENT ON COLUMN public.settings_versions.ord IS 'Poradie vzniku v organizácii. Pre mesiac platí verzia s najvyšším ord spomedzi tých, kde valid_from <= mesiac.';

ALTER TABLE public.settings_versions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.settings_versions FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.settings_versions TO service_role;

-- Nemennosť: verzia sa nikdy neupraví; zmazať ju smie len zrušenie celej organizácie (purge_organization nastavuje app.purging_organization).
CREATE OR REPLACE FUNCTION public.settings_versions_immutable() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF TG_OP = 'DELETE' AND COALESCE(current_setting('app.purging_organization', true), '') = OLD.organization_id::text THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'Verzia nastavení sa nedá zmeniť ani zmazať. Zmena je vždy nová verzia.';
END $$;
REVOKE ALL ON FUNCTION public.settings_versions_immutable() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS settings_versions_immutable ON public.settings_versions;
CREATE TRIGGER settings_versions_immutable BEFORE UPDATE OR DELETE ON public.settings_versions
  FOR EACH ROW EXECUTE FUNCTION public.settings_versions_immutable();

-- Aktuálny mesiac v pásme organizácie (rovnaké pásmo ako is_closed a export razení).
CREATE OR REPLACE FUNCTION public.settings_month_now() RETURNS date
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT date_trunc('month', now() AT TIME ZONE 'Europe/Bratislava')::date
$$;

-- Platná verzia pre mesiac: najvyššie poradie spomedzi verzií s valid_from <= mesiac. Mesiac pred prvou verziou dostane najstaršiu.
CREATE OR REPLACE FUNCTION public.settings_version_for(_org uuid, _month date) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE(
    (SELECT v.id FROM public.settings_versions v
      WHERE v.organization_id = _org AND v.valid_from IS NOT NULL AND v.valid_from <= date_trunc('month', _month)::date
      ORDER BY v.ord DESC LIMIT 1),
    (SELECT v.id FROM public.settings_versions v
      WHERE v.organization_id = _org AND v.valid_from IS NOT NULL
      ORDER BY v.valid_from, v.ord LIMIT 1))
$$;
REVOKE ALL ON FUNCTION public.settings_version_for(uuid, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.settings_month_now() FROM PUBLIC, anon, authenticated;

-- Predvolený terminálový model: dnešné hodnoty organizácie (alebo spoločné predvolené, ak organizácia ešte vlastné nemá) v tvare kontraktu.
-- Kde dnešný terminál pravidlo nemá (okno práce, hranica celodennej prekážky, duplicita), je hodnota „vypnuté“. Hodnoty sú orientačné,
-- určí ich smernica; mechanizmus od nich nezávisí.
CREATE OR REPLACE FUNCTION public.settings_default_config(_org uuid, _from date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  own boolean := EXISTS (SELECT 1 FROM public.organization_settings s WHERE s.organization_id = _org);
  own_h boolean := EXISTS (SELECT 1 FROM public.organization_holidays h WHERE h.organization_id = _org);
  kv jsonb; hol jsonb; names jsonb;
  r_in int; r_out int; lunch int; trig int; fund int;
  m text := to_char(_from, 'YYYY-MM');
BEGIN
  IF own THEN SELECT COALESCE(jsonb_object_agg(s.key, s.value), '{}') INTO kv FROM public.organization_settings s WHERE s.organization_id = _org;
  ELSE SELECT COALESCE(jsonb_object_agg(s.key, s.value), '{}') INTO kv FROM public.settings s; END IF;
  IF own_h THEN SELECT COALESCE(jsonb_agg(jsonb_build_object('date', to_char(h.day, 'YYYY-MM-DD'), 'name', left(h.name, 200)) ORDER BY h.day), '[]') INTO hol
                  FROM public.organization_holidays h WHERE h.organization_id = _org;
  ELSE SELECT COALESCE(jsonb_agg(jsonb_build_object('date', to_char(h.day, 'YYYY-MM-DD'), 'name', left(h.name, 200)) ORDER BY h.day), '[]') INTO hol FROM public.holidays h; END IF;
  SELECT COALESCE(jsonb_object_agg(c.code, left(c.name, 200)), '{}') INTO names FROM public.organization_codes c WHERE c.organization_id = _org;
  r_in := public.settings_num(kv ->> 'ZAOKRUHLENIE_PRICHOD', 1, 0, 60, 0);
  r_out := public.settings_num(kv ->> 'ZAOKRUHLENIE_ODCHOD', 1, 0, 60, 0);
  lunch := public.settings_num(kv ->> 'OBED_PAUZA_MIN', 1, 0, 600, 30);
  trig := public.settings_num(kv ->> 'OBED_PO_HODINACH', 60, 0, 1440, 360);
  fund := public.settings_num(kv ->> 'DENNY_FOND_HODIN', 60, 0, 1440, 450);
  RETURN jsonb_build_object(
    'schema_version', 2,
    'config_version', to_char(now() AT TIME ZONE 'Europe/Bratislava', 'YYYY.MM.DD.HH24MI'),
    'rok', extract(year FROM _from)::int,
    'period', jsonb_build_object('from_month', m, 'to_month', m),
    'rules', jsonb_build_object(
      'work_window_start_min', 0, 'work_window_end_min', 1440, 'full_day_obstacle_min', 1440,
      'auto_lunch_enabled', lunch > 0, 'auto_lunch_trigger_min', trig, 'auto_lunch_deduct_min', lunch,
      'duplicate_punch_window_min', 0, 'default_daily_fund_min', fund, 'auto_repair_mode', 0,
      'rounding_in_min', r_in, 'rounding_out_min', r_out, 'rounding_mode', 0, 'unlabeled_out_is_lunch', true),
    'interruptions', jsonb_build_array(
      jsonb_build_object('code', 1, 'name', COALESCE(names ->> 'WORK', 'Práca na pracovisku'), 'short_name', 'WORK', 'start_punch_code', 100, 'end_punch_code', 101,
                         'is_work', true, 'is_lunch', false, 'auto_end_of_shift', false, 'calc', 'WORK'),
      jsonb_build_object('code', 2, 'name', COALESCE(names ->> 'DOCTOR', 'Lekár / ošetrenie'), 'short_name', 'DOCTOR', 'start_punch_code', 102, 'end_punch_code', 103,
                         'is_work', false, 'is_lunch', false, 'auto_end_of_shift', true, 'calc', 'COUNTED',
                         'terminal_button', true, 'terminal_label', 'Lekár', 'terminal_order', 1, 'terminal_icon', 'doctor'),
      jsonb_build_object('code', 4, 'name', 'Služobné vzdialenie', 'short_name', 'ERRAND', 'start_punch_code', 106, 'end_punch_code', 107,
                         'is_work', false, 'is_lunch', false, 'auto_end_of_shift', true, 'calc', 'COUNTED',
                         'terminal_button', true, 'terminal_label', 'Služobné vzdialenie', 'terminal_order', 4, 'terminal_icon', 'errand'),
      jsonb_build_object('code', 7, 'name', 'Obed', 'short_name', 'OBED', 'start_punch_code', 110, 'end_punch_code', 111,
                         'is_work', false, 'is_lunch', true, 'auto_end_of_shift', false, 'calc', 'LUNCH'),
      jsonb_build_object('code', 8, 'name', COALESCE(names ->> 'LEAVE', 'Dovolenka'), 'short_name', 'LEAVE', 'start_punch_code', 116, 'end_punch_code', 117,
                         'is_work', false, 'is_lunch', false, 'auto_end_of_shift', true, 'calc', 'COUNTED',
                         'terminal_request', true, 'full_day_only', true),
      jsonb_build_object('code', 11, 'name', COALESCE(names ->> 'SICK', 'PN / práceneschopnosť'), 'short_name', 'SICK', 'start_punch_code', 120, 'end_punch_code', 121,
                         'is_work', false, 'is_lunch', false, 'auto_end_of_shift', true, 'calc', 'COUNTED',
                         'terminal_request', true, 'full_day_only', true),
      jsonb_build_object('code', 12, 'name', COALESCE(names ->> 'TRIP', 'Služobná cesta'), 'short_name', 'TRIP', 'start_punch_code', 122, 'end_punch_code', 123,
                         'is_work', false, 'is_lunch', false, 'auto_end_of_shift', true, 'calc', 'COUNTED',
                         'terminal_button', true, 'terminal_label', 'Služobná cesta', 'terminal_order', 3, 'terminal_icon', 'trip', 'counts_to_lunch_base', true),
      jsonb_build_object('code', 13, 'name', COALESCE(names ->> 'PRIV', 'Súkromné prerušenie'), 'short_name', 'PRIV', 'start_punch_code', 124, 'end_punch_code', 125,
                         'is_work', false, 'is_lunch', false, 'auto_end_of_shift', false, 'calc', 'UNPAID',
                         'terminal_button', true, 'terminal_label', 'Súkromne', 'terminal_order', 5, 'terminal_icon', 'private'),
      jsonb_build_object('code', 16, 'name', COALESCE(names ->> 'FAMILY', 'Sprievod rodinného príslušníka'), 'short_name', 'FAMILY', 'start_punch_code', 130, 'end_punch_code', 131,
                         'is_work', false, 'is_lunch', false, 'auto_end_of_shift', true, 'calc', 'COUNTED',
                         'terminal_button', true, 'terminal_label', 'Sprievod', 'terminal_order', 2, 'terminal_icon', 'family')),
    'punch_codes', '[]'::jsonb,
    'terminal_code_map', jsonb_build_array(
      jsonb_build_object('code', 'WORK', 'interruption', 1), jsonb_build_object('code', 'DOCTOR', 'interruption', 2),
      jsonb_build_object('code', 'ERRAND', 'interruption', 4), jsonb_build_object('code', 'LEAVE', 'interruption', 8),
      jsonb_build_object('code', 'SICK', 'interruption', 11), jsonb_build_object('code', 'TRIP', 'interruption', 12),
      jsonb_build_object('code', 'PRIV', 'interruption', 13), jsonb_build_object('code', 'FAMILY', 'interruption', 16)),
    'holidays', hol,
    'funds', jsonb_build_array(jsonb_build_object('id', 1, 'name', 'Denný fond zamestnanca', 'type', 1)),
    'templates', '[]'::jsonb);
END $$;

-- Číslo z textovej hodnoty nastavenia (čiarka aj bodka), násobené a orezané do rozsahu; neplatná hodnota = predvolená.
CREATE OR REPLACE FUNCTION public.settings_num(_v text, _mult int, _lo int, _hi int, _default int) RETURNS int
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE t text := replace(btrim(COALESCE(_v, '')), ',', '.');
BEGIN
  IF t !~ '^[0-9]{1,6}(\.[0-9]{1,4})?$' THEN RETURN _default; END IF;
  RETURN LEAST(_hi, GREATEST(_lo, round(t::numeric * _mult)::int));
END $$;
REVOKE ALL ON FUNCTION public.settings_default_config(uuid, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.settings_num(text, int, int, int, int) FROM PUBLIC, anon, authenticated;

-- Spätné doplnenie: každá organizácia bez verzie dostane terminálovú verziu zo svojich dnešných hodnôt, platnú od mesiaca jej
-- najstaršieho razenia (inak od mesiaca vzniku organizácie).
INSERT INTO public.settings_versions (organization_id, ord, origin, valid_from, reason, config)
SELECT o.id, 1, 'terminal', f.m, 'backfill', public.settings_default_config(o.id, f.m)
  FROM public.organizations o
  CROSS JOIN LATERAL (
    SELECT date_trunc('month', LEAST(
             COALESCE((SELECT min(p.client_time) FROM public.punches p JOIN public.profiles pr ON pr.id = p.user_id WHERE pr.organization_id = o.id), o.created_at),
             o.created_at) AT TIME ZONE 'Europe/Bratislava')::date AS m) f
 WHERE NOT EXISTS (SELECT 1 FROM public.settings_versions v WHERE v.organization_id = o.id);

-- Nová organizácia: terminálová verzia od mesiaca registrácie, v tej istej transakcii ako založenie organizácie.
CREATE OR REPLACE FUNCTION public.settings_on_organization_insert() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.settings_versions (organization_id, ord, origin, valid_from, reason, config, created_by)
  VALUES (NEW.id, 1, 'terminal', public.settings_month_now(), 'registration',
          public.settings_default_config(NEW.id, public.settings_month_now()), NEW.created_by);
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.settings_on_organization_insert() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS settings_default_version ON public.organizations;
CREATE TRIGGER settings_default_version AFTER INSERT ON public.organizations
  FOR EACH ROW EXECUTE FUNCTION public.settings_on_organization_insert();

-- ===================================================================================================== 2. access_config: tabuľka -> pohľad
DO $access$
DECLARE r record; vid uuid; n int;
BEGIN
  IF (SELECT c.relkind FROM pg_class c WHERE c.oid = to_regclass('public.access_config')) = 'r' THEN
    -- Prijatý import (ak nejaký je) sa stane verziou z Accessu BEZ platnosti: organizácia ostáva nespárovaná, kým správca import
    -- neprijme znova s potvrdením. Plán sa pripojí k tejto verzii.
    FOR r IN SELECT * FROM public.access_config LOOP
      SELECT COALESCE(max(v.ord), 0) + 1 INTO n FROM public.settings_versions v WHERE v.organization_id = r.organization_id;
      INSERT INTO public.settings_versions (organization_id, ord, origin, valid_from, reason, config, config_version, period_from, period_to,
                                            employees_count, employee_months_count, created_at, created_by)
      VALUES (r.organization_id, n, 'access', NULL, 'import', r.config, r.config_version, r.period_from, r.period_to,
              r.employees_count, r.employee_months_count, r.imported_at, r.imported_by);
    END LOOP;
    CREATE SCHEMA IF NOT EXISTS settings_archive;
    REVOKE ALL ON SCHEMA settings_archive FROM PUBLIC;
    ALTER TABLE public.access_config SET SCHEMA settings_archive;
  END IF;
END
$access$;
COMMENT ON SCHEMA settings_archive IS 'Pôvodná tabuľka access_config spred migrácie 0022 (len pre návratový skript). Aplikácia ju nepoužíva.';

CREATE OR REPLACE VIEW public.access_config AS
  SELECT v.organization_id, v.config_version, v.period_from, v.period_to, v.config, v.employees_count, v.employee_months_count,
         v.created_at AS imported_at, v.created_by AS imported_by
    FROM public.settings_versions v
   WHERE v.origin = 'access'
     AND v.organization_id = public.my_organization()
     AND v.id = (SELECT x.id FROM public.settings_versions x
                  WHERE x.organization_id = v.organization_id AND x.valid_from IS NOT NULL
                    AND x.valid_from <= date_trunc('month', now() AT TIME ZONE 'Europe/Bratislava')::date
                  ORDER BY x.ord DESC LIMIT 1);
COMMENT ON VIEW public.access_config IS
  'Spätná kompatibilita (od 0022): verzia z Accessu platná pre aktuálny mesiac vlastnej organizácie. Údaje sú v settings_versions.';
REVOKE ALL ON public.access_config FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.access_config TO authenticated, service_role;

-- ===================================================================================================== 3. plán patrí verzii
ALTER TABLE public.employee_month_plan ADD COLUMN IF NOT EXISTS version_id uuid;
DO $plan$
DECLARE pk text; n bigint;
BEGIN
  UPDATE public.employee_month_plan e SET version_id = v.id
    FROM public.settings_versions v
   WHERE e.version_id IS NULL AND v.organization_id = e.organization_id AND v.origin = 'access' AND v.config_version = e.config_version;
  SELECT count(*) INTO n FROM public.employee_month_plan WHERE version_id IS NULL;
  IF n > 0 THEN
    RAISE EXCEPTION '0022: % riadkov plánu nemá prijatú konfiguráciu rovnakej verzie. Nič sa nezmenilo; napíšte to do PR.', n;
  END IF;
  ALTER TABLE public.employee_month_plan ALTER COLUMN version_id SET NOT NULL;
  SELECT c.conname INTO pk FROM pg_constraint c WHERE c.conrelid = 'public.employee_month_plan'::regclass AND c.contype = 'p';
  IF pk IS NOT NULL AND (SELECT count(*) FROM pg_constraint c, unnest(c.conkey) k WHERE c.conrelid = 'public.employee_month_plan'::regclass AND c.contype = 'p') = 3 THEN
    EXECUTE format('ALTER TABLE public.employee_month_plan DROP CONSTRAINT %I', pk);
    pk := NULL;
  END IF;
  IF pk IS NULL THEN
    ALTER TABLE public.employee_month_plan ADD CONSTRAINT employee_month_plan_pkey PRIMARY KEY (organization_id, version_id, personnel_number, month);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.employee_month_plan'::regclass AND conname = 'employee_month_plan_version_fk') THEN
    ALTER TABLE public.employee_month_plan ADD CONSTRAINT employee_month_plan_version_fk
      FOREIGN KEY (organization_id, version_id) REFERENCES public.settings_versions (organization_id, id) ON DELETE CASCADE;
  END IF;
END
$plan$;
COMMENT ON COLUMN public.employee_month_plan.version_id IS 'Verzia z Accessu (settings_versions), s ktorou plán prišiel. Výpočet číta plán verzie platnej pre mesiac.';

-- ===================================================================================================== 4. otvorené mesiace
-- Prehľad posledných 12 mesiacov a aktuálneho: koľko zamestnancov s razeniami má mesiac uzavretý a koľko nie.
-- Zamestnanec bez razenia v mesiaci sa nepočíta (nemá čo prepočítať).
CREATE OR REPLACE FUNCTION public.settings_open_months(_org uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('month', to_char(g.m, 'YYYY-MM'), 'open', s.n_open, 'closed', s.n_closed) ORDER BY g.m), '[]'::jsonb)
    FROM generate_series(public.settings_month_now() - interval '12 months', public.settings_month_now(), interval '1 month') AS g(m)
    CROSS JOIN LATERAL (
      SELECT count(*) FILTER (WHERE c.user_id IS NULL) AS n_open, count(*) FILTER (WHERE c.user_id IS NOT NULL) AS n_closed
        FROM (SELECT DISTINCT p.user_id
                FROM public.punches p JOIN public.profiles pr ON pr.id = p.user_id
               WHERE pr.organization_id = _org AND p.voided_at IS NULL
                 AND p.client_time >= (g.m::date)::timestamp AT TIME ZONE 'Europe/Bratislava'
                 AND p.client_time < ((g.m + interval '1 month')::date)::timestamp AT TIME ZONE 'Europe/Bratislava') u
        LEFT JOIN public.month_closures c ON c.user_id = u.user_id AND c.year = extract(year FROM g.m)::int AND c.month = extract(month FROM g.m)::int) s
$$;
REVOKE ALL ON FUNCTION public.settings_open_months(uuid) FROM PUBLIC, anon, authenticated;

-- Najstarší mesiac, od ktorého smie nová verzia platiť: najstarší mesiac s neuzavretým zamestnancom (v posledných 12), inak aktuálny.
CREATE OR REPLACE FUNCTION public.settings_oldest_open(_org uuid) RETURNS date
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE((SELECT min(((x ->> 'month') || '-01')::date) FROM jsonb_array_elements(public.settings_open_months(_org)) x WHERE (x ->> 'open')::int > 0),
                  public.settings_month_now())
$$;
REVOKE ALL ON FUNCTION public.settings_oldest_open(uuid) FROM PUBLIC, anon, authenticated;

-- Kontrola „platí od“: prvý deň mesiaca, nie skôr než najstarší neuzavretý mesiac, najviac 12 mesiacov dopredu. Vráti mesiac.
CREATE OR REPLACE FUNCTION public.settings_check_valid_from(_org uuid, _valid_from date) RETURNS date
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE vf date := COALESCE(_valid_from, public.settings_month_now()); lo date := public.settings_oldest_open(_org);
BEGIN
  IF vf <> date_trunc('month', vf)::date THEN RAISE EXCEPTION 'Platnosť musí začínať prvým dňom mesiaca'; END IF;
  IF vf < LEAST(lo, public.settings_month_now()) THEN
    RAISE EXCEPTION 'Platnosť od % nie je možná: najstarší neuzavretý mesiac je %', to_char(vf, 'MM/YYYY'), to_char(LEAST(lo, public.settings_month_now()), 'MM/YYYY');
  END IF;
  IF vf > public.settings_month_now() + interval '12 months' THEN RAISE EXCEPTION 'Platnosť môže začať najviac 12 mesiacov dopredu'; END IF;
  RETURN vf;
END $$;
REVOKE ALL ON FUNCTION public.settings_check_valid_from(uuid, date) FROM PUBLIC, anon, authenticated;

-- Spoločný začiatok zapisujúcich funkcií: prihlásený správca vlastnej organizácie; vráti organizáciu.
CREATE OR REPLACE FUNCTION public.settings_admin_org() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE org uuid := public.my_organization();
BEGIN
  IF auth.uid() IS NULL OR org IS NULL THEN RAISE EXCEPTION 'Prihlásenie je potrebné'; END IF;
  IF NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Nemáte oprávnenie'; END IF;
  RETURN org;
END $$;
REVOKE ALL ON FUNCTION public.settings_admin_org() FROM PUBLIC, anon, authenticated;

-- ===================================================================================================== 5. snímka uzavretého mesiaca
CREATE TABLE IF NOT EXISTS public.month_closure_snapshots (
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  year int NOT NULL,
  month int NOT NULL,
  settings_version_id uuid NOT NULL,
  daily_fund numeric(5,2),
  punches_count integer NOT NULL DEFAULT 0,
  last_record_hash text,
  result jsonb CHECK (result IS NULL OR jsonb_typeof(result) = 'object'),
  result_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, year, month),
  FOREIGN KEY (user_id, year, month) REFERENCES public.month_closures (user_id, year, month) ON DELETE CASCADE,
  FOREIGN KEY (organization_id, settings_version_id) REFERENCES public.settings_versions (organization_id, id)
);
COMMENT ON TABLE public.month_closure_snapshots IS
  'Snímka uzavretého mesiaca zamestnanca: verzia nastavení, denný fond a odtlačok razení (ukladá databáza pri uzávierke) a výsledok mesiaca (raz ho zapíše close_month). Uzavretý mesiac sa číta odtiaľto.';
ALTER TABLE public.month_closure_snapshots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.month_closure_snapshots FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.month_closure_snapshots TO service_role;

-- Odtlačok razení mesiaca: počet platných razení a hash posledného razenia mesiaca v reťazi (vzorec reťaze sa nemení, len sa číta).
CREATE OR REPLACE FUNCTION public.month_punch_fingerprint(_user uuid, _year int, _month int, OUT n integer, OUT last_hash text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH b AS (SELECT make_date(_year, _month, 1)::timestamp AT TIME ZONE 'Europe/Bratislava' AS a,
                    (make_date(_year, _month, 1) + interval '1 month')::timestamp AT TIME ZONE 'Europe/Bratislava' AS z)
  SELECT (SELECT count(*)::int FROM public.punches p, b WHERE p.user_id = _user AND p.voided_at IS NULL AND p.client_time >= b.a AND p.client_time < b.z),
         (SELECT p.record_hash FROM public.punches p, b WHERE p.user_id = _user AND p.client_time >= b.a AND p.client_time < b.z ORDER BY p.id DESC LIMIT 1)
$$;
REVOKE ALL ON FUNCTION public.month_punch_fingerprint(uuid, int, int) FROM PUBLIC, anon, authenticated;

-- Pri každej uzávierke (aj zo staršej aplikácie, ktorá vkladá priamo) databáza pripne verziu, fond a odtlačok razení.
-- Spúšťač je AFTER INSERT: o tom, či sa uzávierka prijme, nerozhoduje.
CREATE OR REPLACE FUNCTION public.month_closure_snapshot_insert() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE org uuid; fund numeric; fp record; vid uuid;
BEGIN
  SELECT p.organization_id, p.daily_fund INTO org, fund FROM public.profiles p WHERE p.id = NEW.user_id;
  IF org IS NULL THEN RETURN NEW; END IF;
  vid := public.settings_version_for(org, make_date(NEW.year, NEW.month, 1));
  IF vid IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO fp FROM public.month_punch_fingerprint(NEW.user_id, NEW.year, NEW.month);
  INSERT INTO public.month_closure_snapshots (organization_id, user_id, year, month, settings_version_id, daily_fund, punches_count, last_record_hash)
  VALUES (org, NEW.user_id, NEW.year, NEW.month, vid, fund, fp.n, fp.last_hash)
  ON CONFLICT (user_id, year, month) DO NOTHING;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.month_closure_snapshot_insert() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS month_closure_snapshot ON public.month_closures;
CREATE TRIGGER month_closure_snapshot AFTER INSERT ON public.month_closures
  FOR EACH ROW EXECUTE FUNCTION public.month_closure_snapshot_insert();

-- Vrátiť sa dá len posledná uzávierka zamestnanca (rozhodnutie vlastníčky 13. 11. 2026). Zrušenie celej organizácie je výnimka.
CREATE OR REPLACE FUNCTION public.month_closure_only_last() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE org uuid;
BEGIN
  SELECT p.organization_id INTO org FROM public.profiles p WHERE p.id = OLD.user_id;
  IF org IS NULL OR COALESCE(current_setting('app.purging_organization', true), '') = org::text THEN RETURN OLD; END IF;
  IF EXISTS (SELECT 1 FROM public.month_closures c WHERE c.user_id = OLD.user_id AND (c.year, c.month) > (OLD.year, OLD.month)) THEN
    RAISE EXCEPTION 'Vrátiť sa dá len posledná uzávierka zamestnanca. Najprv vráťte neskoršie mesiace.';
  END IF;
  RETURN OLD;
END $$;
REVOKE ALL ON FUNCTION public.month_closure_only_last() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS month_closure_only_last ON public.month_closures;
CREATE TRIGGER month_closure_only_last BEFORE DELETE ON public.month_closures
  FOR EACH ROW EXECUTE FUNCTION public.month_closure_only_last();

-- Snímka sa po vzniku nemení; jediná dovolená zmena je prvé zapísanie výsledku.
CREATE OR REPLACE FUNCTION public.month_closure_snapshot_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF OLD.result IS NOT NULL OR NEW.result IS NULL
     OR (to_jsonb(NEW) - 'result' - 'result_at') IS DISTINCT FROM (to_jsonb(OLD) - 'result' - 'result_at') THEN
    RAISE EXCEPTION 'Snímka uzavretého mesiaca sa nedá zmeniť. Vráťte poslednú uzávierku a uzavrite mesiac znova.';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.month_closure_snapshot_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS month_closure_snapshot_guard ON public.month_closure_snapshots;
CREATE TRIGGER month_closure_snapshot_guard BEFORE UPDATE ON public.month_closure_snapshots
  FOR EACH ROW EXECUTE FUNCTION public.month_closure_snapshot_guard();

-- Existujúce uzávierky: pripnú sa na verziu platnú pre ich mesiac (spätne doplnená terminálová), s dnešným fondom a odtlačkom razení.
INSERT INTO public.month_closure_snapshots (organization_id, user_id, year, month, settings_version_id, daily_fund, punches_count, last_record_hash)
SELECT p.organization_id, c.user_id, c.year, c.month, public.settings_version_for(p.organization_id, make_date(c.year, c.month, 1)), p.daily_fund, f.n, f.last_hash
  FROM public.month_closures c
  JOIN public.profiles p ON p.id = c.user_id
  CROSS JOIN LATERAL public.month_punch_fingerprint(c.user_id, c.year, c.month) f
 WHERE p.organization_id IS NOT NULL AND c.month BETWEEN 1 AND 12
   AND NOT EXISTS (SELECT 1 FROM public.month_closure_snapshots s WHERE s.user_id = c.user_id AND s.year = c.year AND s.month = c.month);

-- Kontrola tvaru a rozumnosti výsledku mesiaca (čísla počíta prehliadač, databáza ich neprepočíta, ale nezmyselné nepustí).
-- Vráti NULL, ak je výsledok v poriadku, inak krátky dôvod. Platí pre tvar výsledku `engine` = 1 (RESULT_ENGINE v settings-model.ts):
-- pri zmene tvaru výsledku v etape 1b treba túto funkciu upraviť spolu s hodnotou `engine`, inak sa uzávierka s novým tvarom odmietne.
-- Kontroluje: presne známe kľúče; denné hodnoty v rozsahu 0 až 2880 minút (zostatok −2880 až 2880); každý deň je ten istý deň
-- mesiaca v poradí; v každom dni súčet = práca + kredit a zostatok = súčet − fond; súčty mesiaca = súčet dní.
CREATE OR REPLACE FUNCTION public.month_result_problem(_year int, _month int, _result jsonb) RETURNS text
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE
  n int := extract(day FROM (make_date(_year, _month, 1) + interval '1 month' - interval '1 day'))::int;
  top_keys constant text[] := ARRAY['engine', 'punches', 'totals', 'byCode', 'days'];
  tot_keys constant text[] := ARRAY['work', 'credit', 'total', 'expected', 'balance'];
  day_keys constant text[] := ARRAY['d', 'workMin', 'creditMin', 'privMin', 'breakMin', 'totalMin', 'expectedMin', 'balanceMin', 'byCode', 'open'];
  day_nums constant text[] := ARRAY['workMin', 'creditMin', 'privMin', 'breakMin', 'totalMin', 'expectedMin', 'balanceMin'];
  lim constant numeric := 2880;
  keys text[]; day jsonb; i int; k text; v numeric; lo numeric; w numeric; c numeric; t numeric; e numeric; b numeric;
  s_work numeric := 0; s_credit numeric := 0; s_total numeric := 0; s_exp numeric := 0; s_bal numeric := 0;
BEGIN
  IF jsonb_typeof(_result) IS DISTINCT FROM 'object' OR octet_length(_result::text) > 200000 THEN RETURN 'nie je objekt alebo je príliš veľký'; END IF;
  SELECT coalesce(array_agg(x), '{}') INTO keys FROM jsonb_object_keys(_result) x;
  IF NOT (keys @> top_keys AND keys <@ top_keys) THEN RETURN 'neznáme alebo chýbajúce kľúče'; END IF;
  IF jsonb_typeof(_result -> 'engine') IS DISTINCT FROM 'number' OR (_result ->> 'engine') <> '1' THEN RETURN 'neznáma verzia výsledku (engine)'; END IF;
  IF jsonb_typeof(_result -> 'punches') IS DISTINCT FROM 'number' OR (_result ->> 'punches') !~ '^[0-9]{1,6}$' THEN RETURN 'počet razení'; END IF;

  IF jsonb_typeof(_result -> 'totals') IS DISTINCT FROM 'object' THEN RETURN 'súčty mesiaca'; END IF;
  SELECT coalesce(array_agg(x), '{}') INTO keys FROM jsonb_object_keys(_result -> 'totals') x;
  IF NOT (keys @> tot_keys AND keys <@ tot_keys) THEN RETURN 'súčty mesiaca: neznáme alebo chýbajúce kľúče'; END IF;
  FOREACH k IN ARRAY tot_keys LOOP
    IF jsonb_typeof(_result -> 'totals' -> k) IS DISTINCT FROM 'number' THEN RETURN 'súčty mesiaca: ' || k || ' nie je číslo'; END IF;
    v := (_result -> 'totals' ->> k)::numeric;
    IF abs(v) > lim * n OR (k <> 'balance' AND v < 0) THEN RETURN 'súčty mesiaca: ' || k || ' mimo rozsahu'; END IF;
  END LOOP;

  IF jsonb_typeof(_result -> 'byCode') IS DISTINCT FROM 'object' OR (SELECT count(*) FROM jsonb_object_keys(_result -> 'byCode')) > 100 THEN RETURN 'byCode mesiaca'; END IF;
  FOR k, v IN SELECT x.key, CASE WHEN jsonb_typeof(x.value) = 'number' THEN (x.value #>> '{}')::numeric END FROM jsonb_each(_result -> 'byCode') x LOOP
    IF length(k) NOT BETWEEN 1 AND 64 OR v IS NULL OR v NOT BETWEEN 0 AND lim * n THEN RETURN 'byCode mesiaca: ' || left(k, 20); END IF;
  END LOOP;

  IF jsonb_typeof(_result -> 'days') IS DISTINCT FROM 'array' OR jsonb_array_length(_result -> 'days') <> n THEN RETURN 'počet dní'; END IF;
  FOR i IN 1..n LOOP
    day := _result -> 'days' -> (i - 1);
    IF jsonb_typeof(day) IS DISTINCT FROM 'object' THEN RETURN 'deň ' || i || ' nie je objekt'; END IF;
    SELECT coalesce(array_agg(x), '{}') INTO keys FROM jsonb_object_keys(day) x;
    IF NOT (keys @> day_keys AND keys <@ day_keys) THEN RETURN 'deň ' || i || ': neznáme alebo chýbajúce kľúče'; END IF;
    IF jsonb_typeof(day -> 'd') IS DISTINCT FROM 'string' OR (day ->> 'd') <> to_char(make_date(_year, _month, i), 'YYYY-MM-DD') THEN RETURN 'deň ' || i || ': dátum'; END IF;
    IF jsonb_typeof(day -> 'open') IS DISTINCT FROM 'boolean' THEN RETURN 'deň ' || i || ': open'; END IF;
    FOREACH k IN ARRAY day_nums LOOP
      IF jsonb_typeof(day -> k) IS DISTINCT FROM 'number' THEN RETURN 'deň ' || i || ': ' || k || ' nie je číslo'; END IF;
      v := (day ->> k)::numeric;
      lo := CASE WHEN k = 'balanceMin' THEN -lim ELSE 0 END;
      IF v > lim OR v < lo THEN RETURN 'deň ' || i || ': ' || k || ' mimo rozsahu'; END IF;
    END LOOP;
    IF jsonb_typeof(day -> 'byCode') IS DISTINCT FROM 'object' OR (SELECT count(*) FROM jsonb_object_keys(day -> 'byCode')) > 100 THEN RETURN 'deň ' || i || ': byCode'; END IF;
    FOR k, v IN SELECT x.key, CASE WHEN jsonb_typeof(x.value) = 'number' THEN (x.value #>> '{}')::numeric END FROM jsonb_each(day -> 'byCode') x LOOP
      IF length(k) NOT BETWEEN 1 AND 64 OR v IS NULL OR v NOT BETWEEN 0 AND lim THEN RETURN 'deň ' || i || ': byCode ' || left(k, 20); END IF;
    END LOOP;
    w := (day ->> 'workMin')::numeric; c := (day ->> 'creditMin')::numeric; t := (day ->> 'totalMin')::numeric;
    e := (day ->> 'expectedMin')::numeric; b := (day ->> 'balanceMin')::numeric;
    IF abs(t - (w + c)) > 0.01 THEN RETURN 'deň ' || i || ': súčet nie je práca + kredit'; END IF;
    IF abs(b - (t - e)) > 0.01 THEN RETURN 'deň ' || i || ': zostatok nie je súčet − fond'; END IF;
    s_work := s_work + w; s_credit := s_credit + c; s_total := s_total + t; s_exp := s_exp + e; s_bal := s_bal + b;
  END LOOP;

  IF abs((_result -> 'totals' ->> 'work')::numeric - s_work) > 0.01 OR abs((_result -> 'totals' ->> 'credit')::numeric - s_credit) > 0.01
     OR abs((_result -> 'totals' ->> 'total')::numeric - s_total) > 0.01 OR abs((_result -> 'totals' ->> 'expected')::numeric - s_exp) > 0.01
     OR abs((_result -> 'totals' ->> 'balance')::numeric - s_bal) > 0.01 THEN
    RETURN 'súčty mesiaca nesedia so súčtom dní';
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.month_result_problem(int, int, jsonb) FROM PUBLIC, anon, authenticated;

-- Zápis výsledku: len ten, kto mesiac práve uzavrel (closed_by), len raz, len rozumný tvar. Čísla počíta engine.ts v prehliadači
-- uzatvárajúceho; databáza ich neprepočítava (výpočet je v TypeScripte), preto ukladá aj vlastný odtlačok razení a fond na kontrolu
-- a stráži ich rozumnosť (month_result_problem).
CREATE OR REPLACE FUNCTION public.month_closure_store_result(_user uuid, _year int, _month int, _result jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE problem text; n_db int;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Prihlásenie je potrebné'; END IF;
  IF _result IS NULL THEN RETURN; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.month_closures c WHERE c.user_id = _user AND c.year = _year AND c.month = _month AND c.closed_by = auth.uid()) THEN
    RAISE EXCEPTION 'Výsledok smie uložiť len ten, kto mesiac uzavrel';
  END IF;
  problem := public.month_result_problem(_year, _month, _result);
  IF problem IS NOT NULL THEN
    RAISE EXCEPTION 'Výsledok mesiaca má neplatný tvar (%)', problem;
  END IF;
  -- výsledok musí byť spočítaný z tých istých razení, aké databáza vidí pri uzávierke (inak sa uzávierka nevykoná)
  SELECT s.punches_count INTO n_db FROM public.month_closure_snapshots s WHERE s.user_id = _user AND s.year = _year AND s.month = _month;
  IF n_db IS NOT NULL AND n_db <> (_result ->> 'punches')::int THEN
    RAISE EXCEPTION 'Razenia mesiaca sa medzitým zmenili (výsledok počíta s % razeniami, databáza ich má %). Načítajte mesiac znova a uzavrite ho ešte raz.', _result ->> 'punches', n_db;
  END IF;
  UPDATE public.month_closure_snapshots s SET result = _result, result_at = now()
   WHERE s.user_id = _user AND s.year = _year AND s.month = _month AND s.result IS NULL;
END $$;
REVOKE ALL ON FUNCTION public.month_closure_store_result(uuid, int, int, jsonb) FROM PUBLIC, anon, authenticated;

-- Uzavretie mesiaca s výsledkom v jednej transakcii. SECURITY INVOKER: vloženie uzávierky ide s právami volajúceho, takže o tom,
-- kto smie mesiac uzavrieť, rozhodujú tie isté politiky month_closures ako doteraz.
CREATE OR REPLACE FUNCTION public.close_month(_user uuid, _year int, _month int, _result jsonb DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.month_closures (user_id, year, month, closed_by) VALUES (_user, _year, _month, auth.uid());
  PERFORM public.month_closure_store_result(_user, _year, _month, _result);
END $$;
REVOKE ALL ON FUNCTION public.close_month(uuid, int, int, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.close_month(uuid, int, int, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.month_closure_store_result(uuid, int, int, jsonb) TO authenticated;

-- ===================================================================================================== 6. čítanie
-- Popis verzie bez obsahu (pevné kľúče).
CREATE OR REPLACE FUNCTION public.settings_version_meta(_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('id', v.id, 'ord', v.ord, 'origin', v.origin, 'valid_from', to_char(v.valid_from, 'YYYY-MM'), 'reason', v.reason,
                            'config_version', v.config_version, 'period_from', to_char(v.period_from, 'YYYY-MM'), 'period_to', to_char(v.period_to, 'YYYY-MM'),
                            'created_at', v.created_at)
    FROM public.settings_versions v WHERE v.id = _id
$$;
REVOKE ALL ON FUNCTION public.settings_version_meta(uuid) FROM PUBLIC, anon, authenticated;

-- PLATNÉ NASTAVENIA PRE MESIAC: jediné čítanie nastavení výpočtu pre aplikáciu (výpočet, tlačidlá, Správa).
--   _month: ľubovoľný deň mesiaca; NULL = aktuálny mesiac.
--   _user:  ak je zadaný a jeho mesiac je uzavretý, vráti sa verzia PRIPNUTÁ pri uzávierke a snímka (fond, odtlačok, výsledok).
-- Model nenesie osobné údaje (kontrakt), preto ho smie čítať každý prihlásený člen organizácie.
CREATE OR REPLACE FUNCTION public.settings_for_month(_month date DEFAULT NULL, _user uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  org uuid := public.my_organization();
  m date := date_trunc('month', COALESCE(_month, public.settings_month_now()))::date;
  vid uuid; snap public.month_closure_snapshots; closed_at timestamptz; cfg jsonb;
BEGIN
  IF auth.uid() IS NULL OR org IS NULL THEN RAISE EXCEPTION 'Prihlásenie je potrebné'; END IF;
  IF _user IS NOT NULL THEN
    IF NOT public.can_see(_user) THEN RAISE EXCEPTION 'Nemáte oprávnenie'; END IF;
    SELECT c.closed_at INTO closed_at FROM public.month_closures c
     WHERE c.user_id = _user AND c.year = extract(year FROM m)::int AND c.month = extract(month FROM m)::int;
    IF closed_at IS NOT NULL THEN
      SELECT * INTO snap FROM public.month_closure_snapshots s
       WHERE s.user_id = _user AND s.year = extract(year FROM m)::int AND s.month = extract(month FROM m)::int AND s.organization_id = org;
      vid := snap.settings_version_id;
    END IF;
  END IF;
  IF vid IS NULL THEN vid := public.settings_version_for(org, m); END IF;
  IF vid IS NULL THEN RAISE EXCEPTION 'Organizácia nemá nastavenia výpočtu (spustite migráciu 0022 celú)'; END IF;
  SELECT v.config INTO cfg FROM public.settings_versions v WHERE v.id = vid AND v.organization_id = org;
  RETURN jsonb_build_object(
    'month', to_char(m, 'YYYY-MM'),
    'version', public.settings_version_meta(vid),
    'config', cfg,
    -- nevýpočtové nastavenie terminálu (od akej odchýlky času sa razenie označí); ostáva v organization_settings
    'max_drift_min', public.settings_num((SELECT s.value FROM public.organization_settings s WHERE s.organization_id = org AND s.key = 'MAX_ODCHYLKA_CASU_MIN'), 1, 0, 1440, 10),
    'closure', CASE WHEN closed_at IS NULL THEN NULL ELSE jsonb_build_object(
      'closed_at', closed_at, 'pinned', snap.user_id IS NOT NULL, 'daily_fund', snap.daily_fund,
      'punches_count', snap.punches_count, 'last_record_hash', snap.last_record_hash, 'result', snap.result) END);
END $$;
REVOKE ALL ON FUNCTION public.settings_for_month(date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.settings_for_month(date, uuid) TO authenticated;

-- Časová os pre Správu (len správca): verzie bez obsahu, komu patrí aktuálny mesiac, otvorené mesiace, kandidáti odpárovania.
CREATE OR REPLACE FUNCTION public.settings_timeline() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE org uuid := public.settings_admin_org(); cur uuid;
BEGIN
  cur := public.settings_version_for(org, public.settings_month_now());
  RETURN jsonb_build_object(
    'month_now', to_char(public.settings_month_now(), 'YYYY-MM'),
    'current', public.settings_version_meta(cur),
    'oldest_open', to_char(public.settings_oldest_open(org), 'YYYY-MM'),
    'open_months', public.settings_open_months(org),
    'last_access', (SELECT public.settings_version_meta(v.id) FROM public.settings_versions v
                     WHERE v.organization_id = org AND v.origin = 'access' AND v.valid_from IS NOT NULL ORDER BY v.ord DESC LIMIT 1),
    'last_terminal', (SELECT public.settings_version_meta(v.id) FROM public.settings_versions v
                       WHERE v.organization_id = org AND v.origin = 'terminal' ORDER BY v.ord DESC LIMIT 1),
    'versions', (SELECT COALESCE(jsonb_agg(public.settings_version_meta(v.id) ORDER BY v.ord DESC), '[]'::jsonb)
                   FROM public.settings_versions v WHERE v.organization_id = org));
END $$;
REVOKE ALL ON FUNCTION public.settings_timeline() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.settings_timeline() TO authenticated;

-- Obsah jednej verzie vlastnej organizácie (len správca): na zobrazenie a na rozdiel pred odpárovaním.
CREATE OR REPLACE FUNCTION public.settings_version_config(_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE org uuid := public.settings_admin_org(); res jsonb;
BEGIN
  SELECT jsonb_build_object('version', public.settings_version_meta(v.id), 'config', v.config) INTO res
    FROM public.settings_versions v WHERE v.id = _id AND v.organization_id = org;
  IF res IS NULL THEN RAISE EXCEPTION 'Verzia neexistuje'; END IF;
  RETURN res;
END $$;
REVOKE ALL ON FUNCTION public.settings_version_config(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.settings_version_config(uuid) TO authenticated;

-- ===================================================================================================== 7. zápis
-- Vloženie verzie (vnútorná funkcia): poradie v organizácii pod zámkom.
CREATE OR REPLACE FUNCTION public.settings_insert_version(_org uuid, _origin text, _valid_from date, _reason text, _config jsonb,
  _config_version text DEFAULT NULL, _period_from date DEFAULT NULL, _period_to date DEFAULT NULL, _emp int DEFAULT NULL, _emp_months int DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int; vid uuid;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('settings_versions:' || _org::text, 0));
  SELECT COALESCE(max(v.ord), 0) + 1 INTO n FROM public.settings_versions v WHERE v.organization_id = _org;
  INSERT INTO public.settings_versions (organization_id, ord, origin, valid_from, reason, config, config_version, period_from, period_to,
                                        employees_count, employee_months_count, created_by)
  VALUES (_org, n, _origin, _valid_from, _reason, _config, _config_version, _period_from, _period_to, _emp, _emp_months, auth.uid())
  RETURNING id INTO vid;
  RETURN vid;
END $$;
REVOKE ALL ON FUNCTION public.settings_insert_version(uuid, text, date, text, jsonb, text, date, date, int, int) FROM PUBLIC, anon, authenticated;

-- Kontrola terminálového modelu tou istou kontrolou ako súbor z Accessu (import_access_config nanečisto, bez zamestnancov).
-- Vráti model v podobe, v akej sa uloží (bez employees a counts).
CREATE OR REPLACE FUNCTION public.settings_validate_model(_org uuid, _config jsonb, _valid_from date) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE doc jsonb; stamp text; cur text; m text := to_char(_valid_from, 'YYYY-MM');
BEGIN
  IF _config IS NULL OR jsonb_typeof(_config) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Nastavenia musia byť objekt'; END IF;
  stamp := to_char(now() AT TIME ZONE 'Europe/Bratislava', 'YYYY.MM.DD.HH24MI');
  -- kontrola súboru porovnáva verziu s práve platnou verziou z Accessu; terminálová verzia nesmie na tom zlyhať
  SELECT a.config_version INTO cur FROM public.access_config a WHERE a.organization_id = _org;
  IF cur IS NOT NULL AND cur > stamp THEN stamp := cur; END IF;
  doc := (_config - 'employees' - 'counts' - 'generated_at')
         || jsonb_build_object('schema_version', 2, 'config_version', stamp, 'rok', extract(year FROM _valid_from)::int);
  IF NOT doc ? 'period' THEN doc := doc || jsonb_build_object('period', jsonb_build_object('from_month', m, 'to_month', m)); END IF;
  PERFORM public.import_access_config(doc || jsonb_build_object('employees', '[]'::jsonb, 'counts', jsonb_build_object('employees', 0, 'employee_months', 0)), true);
  RETURN doc;
END $$;
REVOKE ALL ON FUNCTION public.settings_validate_model(uuid, jsonb, date) FROM PUBLIC, anon, authenticated;

-- Úprava terminálových nastavení: vždy nová terminálová verzia platná od zvoleného mesiaca. Dovolená len vtedy, keď od toho mesiaca
-- ďalej všetky mesiace patria terminálu (inak by úprava potichu odpárovala Access; na to je settings_unpair).
CREATE OR REPLACE FUNCTION public.settings_terminal_save(_config jsonb, _valid_from date DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE org uuid := public.settings_admin_org(); vf date; doc jsonb; vid uuid; brk date;
BEGIN
  vf := public.settings_check_valid_from(org, _valid_from);
  PERFORM pg_advisory_xact_lock(hashtextextended('settings_versions:' || org::text, 0));
  FOR brk IN SELECT vf UNION SELECT v.valid_from FROM public.settings_versions v WHERE v.organization_id = org AND v.valid_from > vf LOOP
    IF (SELECT v.origin FROM public.settings_versions v WHERE v.id = public.settings_version_for(org, brk)) <> 'terminal' THEN
      RAISE EXCEPTION 'Mesiac % patrí Accessu: nastavenia výpočtu sa v termináli nemenia. Zmena je možná novým importom alebo odpárovaním.', to_char(brk, 'MM/YYYY');
    END IF;
  END LOOP;
  doc := public.settings_validate_model(org, _config, vf);
  vid := public.settings_insert_version(org, 'terminal', vf, 'edit', doc);
  INSERT INTO public.audit_log (actor, action, target, details)
  VALUES (auth.uid(), 'settings.terminal_saved', org::text, jsonb_build_object('version_id', vid, 'valid_from', to_char(vf, 'YYYY-MM')));
  RETURN public.settings_version_meta(vid);
END $$;
REVOKE ALL ON FUNCTION public.settings_terminal_save(jsonb, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.settings_terminal_save(jsonb, date) TO authenticated;

-- Prijatie súboru z Accessu = nová verzia z Accessu a spárovanie od zvoleného mesiaca.
--   _dry_run = true: len kontrola a náhľad (komu mesiac patrí dnes, otvorené mesiace); nič sa nezapíše.
--   _valid_from: NULL = aktuálny mesiac; skorší mesiac len po výslovnej voľbe správcu („použiť Access aj pre október“).
--   _confirm: ostrý import vyžaduje výslovné potvrdenie upozornenia o spárovaní.
-- Súbor kontroluje jediná kontrola import_access_config (nanečisto); táto funkcia len zapíše verziu a plán.
CREATE OR REPLACE FUNCTION public.settings_import_access(_payload jsonb, _dry_run boolean DEFAULT true, _valid_from date DEFAULT NULL, _confirm boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  org uuid := public.settings_admin_org();
  base jsonb; ver text; latest text; st text; vf date; vid uuid; owner_now jsonb; p_from date; p_to date; n_plan bigint := 0;
BEGIN
  base := public.import_access_config(_payload, true);
  ver := _payload ->> 'config_version';
  p_from := ((_payload -> 'period' ->> 'from_month') || '-01')::date;
  p_to := ((_payload -> 'period' ->> 'to_month') || '-01')::date;
  IF NOT COALESCE(_dry_run, true) THEN PERFORM pg_advisory_xact_lock(hashtextextended('settings_versions:' || org::text, 0)); END IF;
  SELECT max(v.config_version) INTO latest FROM public.settings_versions v WHERE v.organization_id = org AND v.origin = 'access';
  IF latest IS NOT NULL AND latest > ver THEN
    RAISE EXCEPTION 'Súbor je starší (verzia %) než už prijatá verzia %. Vytvorte nový súbor v Accesse.', ver, latest;
  END IF;
  vf := public.settings_check_valid_from(org, _valid_from);
  owner_now := public.settings_version_meta(public.settings_version_for(org, vf));
  st := CASE WHEN latest = ver THEN 'unchanged' WHEN COALESCE(_dry_run, true) THEN 'preview' ELSE 'imported' END;

  IF st = 'imported' THEN
    IF NOT COALESCE(_confirm, false) THEN
      RAISE EXCEPTION 'Import nebol potvrdený: od zvoleného mesiaca platia nastavenia z Accessu a nastavenia výpočtu v termináli sa zamknú.';
    END IF;
    vid := public.settings_insert_version(org, 'access', vf, 'import', _payload - 'employees', ver, p_from, p_to,
                                          (base ->> 'employees')::int, (base ->> 'employee_months')::int);
    INSERT INTO public.employee_month_plan (organization_id, version_id, personnel_number, month, employment_pct, fund_id, template_id, calendar_id,
                                            day_types, expected_min, window_start_min, window_end_min, regime_ids, config_version)
    SELECT org, vid, e ->> 'personnel_number', ((mo ->> 'month') || '-01')::date,
           (mo ->> 'employment_pct')::smallint, (mo ->> 'fund_id')::int, (mo ->> 'template_id')::int, (mo ->> 'calendar_id')::int,
           ARRAY(SELECT t.x FROM jsonb_array_elements_text(mo -> 'day_types') WITH ORDINALITY t(x, i) ORDER BY t.i),
           ARRAY(SELECT t.x::smallint FROM jsonb_array_elements_text(mo -> 'expected_min') WITH ORDINALITY t(x, i) ORDER BY t.i),
           (mo ->> 'window_start_min')::smallint, (mo ->> 'window_end_min')::smallint,
           CASE WHEN mo ? 'regime_ids' AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(mo -> 'regime_ids') z WHERE z <> '0')
                THEN ARRAY(SELECT t.x::smallint FROM jsonb_array_elements_text(mo -> 'regime_ids') WITH ORDINALITY t(x, i) ORDER BY t.i) END,
           ver
      FROM jsonb_array_elements(_payload -> 'employees') e, jsonb_array_elements(e -> 'months') mo;
    GET DIAGNOSTICS n_plan = ROW_COUNT;
    INSERT INTO public.audit_log (actor, action, target, details)
    VALUES (auth.uid(), 'access_config_imported', org::text,
            jsonb_build_object('config_version', ver, 'previous_version', latest, 'version_id', vid, 'valid_from', to_char(vf, 'YYYY-MM'),
                               'previous_owner', owner_now -> 'origin', 'period_from', p_from, 'period_to', p_to,
                               'employees', (base ->> 'employees')::int, 'employee_months', n_plan));
  END IF;

  RETURN (base - 'removed_months' - 'previous_version' - 'status' - 'dry_run')
         || jsonb_build_object('status', st, 'dry_run', COALESCE(_dry_run, true), 'previous_version', latest,
                               'valid_from', to_char(vf, 'YYYY-MM'), 'month_now', to_char(public.settings_month_now(), 'YYYY-MM'),
                               'owner_now', owner_now, 'oldest_open', to_char(public.settings_oldest_open(org), 'YYYY-MM'),
                               'open_months', public.settings_open_months(org), 'version', public.settings_version_meta(vid));
END $$;
REVOKE ALL ON FUNCTION public.settings_import_access(jsonb, boolean, date, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.settings_import_access(jsonb, boolean, date, boolean) TO authenticated;

-- Staršia aplikácia volala import_access_config priamo; spárovala by bez upozornenia a zapisovala by do pohľadu. Klientovi sa preto
-- odoberá (funkcia ostáva, volá ju settings_import_access a settings_validate_model nanečisto).
REVOKE ALL ON FUNCTION public.import_access_config(jsonb, boolean) FROM PUBLIC, anon, authenticated;

-- Odpárovanie: od zvoleného mesiaca platí nová terminálová verzia. _choice: 'access' = kópia posledných nastavení z Accessu
-- (predvolené), 'terminal' = kópia poslednej terminálovej verzie. Verzie z Accessu ostávajú v histórii. Opätovné spárovanie = nový import.
CREATE OR REPLACE FUNCTION public.settings_unpair(_valid_from date DEFAULT NULL, _choice text DEFAULT 'access', _confirm boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE org uuid := public.settings_admin_org(); vf date; src public.settings_versions; vid uuid; m text; brk date; paired boolean := false;
BEGIN
  IF _choice IS NULL OR _choice NOT IN ('access', 'terminal') THEN RAISE EXCEPTION 'Neplatná voľba'; END IF;
  IF NOT COALESCE(_confirm, false) THEN RAISE EXCEPTION 'Odpárovanie nebolo potvrdené'; END IF;
  vf := public.settings_check_valid_from(org, _valid_from);
  PERFORM pg_advisory_xact_lock(hashtextextended('settings_versions:' || org::text, 0));
  FOR brk IN SELECT vf UNION SELECT v.valid_from FROM public.settings_versions v WHERE v.organization_id = org AND v.valid_from > vf LOOP
    paired := paired OR (SELECT v.origin FROM public.settings_versions v WHERE v.id = public.settings_version_for(org, brk)) = 'access';
  END LOOP;
  IF NOT paired THEN RAISE EXCEPTION 'Od mesiaca % už nastavenia patria terminálu, nie je čo odpárovať', to_char(vf, 'MM/YYYY'); END IF;
  IF _choice = 'access' THEN
    SELECT * INTO src FROM public.settings_versions v WHERE v.organization_id = org AND v.origin = 'access' AND v.valid_from IS NOT NULL ORDER BY v.ord DESC LIMIT 1;
  ELSE
    SELECT * INTO src FROM public.settings_versions v WHERE v.organization_id = org AND v.origin = 'terminal' ORDER BY v.ord DESC LIMIT 1;
  END IF;
  IF src.id IS NULL THEN RAISE EXCEPTION 'Zvolená verzia neexistuje'; END IF;
  m := to_char(vf, 'YYYY-MM');
  vid := public.settings_insert_version(org, 'terminal', vf, CASE _choice WHEN 'access' THEN 'unpair_access' ELSE 'unpair_terminal' END, src.config);
  INSERT INTO public.audit_log (actor, action, target, details)
  VALUES (auth.uid(), 'settings.unpaired', org::text,
          jsonb_build_object('version_id', vid, 'valid_from', m, 'choice', _choice, 'copied_from', src.id, 'copied_config_version', src.config_version));
  RETURN public.settings_version_meta(vid);
END $$;
REVOKE ALL ON FUNCTION public.settings_unpair(date, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.settings_unpair(date, text, boolean) TO authenticated;

-- ===================================================================================================== 8. staré zápisy
-- Výpočtové kľúče v organization_settings sa už nečítajú. Zmenu z prihlásenej (staršej) aplikácie databáza odmietne, aby sa ticho nestratila.
CREATE OR REPLACE FUNCTION public.settings_legacy_calc_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon')
     AND NEW.key IN ('ZAOKRUHLENIE_PRICHOD', 'ZAOKRUHLENIE_ODCHOD', 'OBED_PAUZA_MIN', 'OBED_PO_HODINACH', 'DENNY_FOND_HODIN')
     AND NEW.value IS DISTINCT FROM OLD.value THEN
    RAISE EXCEPTION 'Pravidlá výpočtu sa od tejto verzie ukladajú ako verzie nastavení. Obnovte aplikáciu (zatvorte ju a otvorte znova).';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.settings_legacy_calc_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS settings_legacy_calc_guard ON public.organization_settings;
CREATE TRIGGER settings_legacy_calc_guard BEFORE UPDATE ON public.organization_settings
  FOR EACH ROW EXECUTE FUNCTION public.settings_legacy_calc_guard();
-- Sviatky sú súčasťou verzie nastavení; priamy zápis zo staršej aplikácie by sa do výpočtu nedostal.
REVOKE INSERT, DELETE ON public.organization_holidays FROM authenticated;

-- ===================================================================================================== 9. prenos organizácie
-- Zoznam prenášaných tabuliek: access_config (teraz pohľad) nahrádza settings_versions; pribúda month_closure_snapshots.
-- Poradie = poradie vkladania (cudzie kľúče): verzie pred plánom, uzávierky pred snímkami.
CREATE OR REPLACE FUNCTION org_transfer.spec()
RETURNS TABLE(ord int, rel text, key_col text, filter text, order_by text, mode text, digest_exclude text[], null_cols text[])
LANGUAGE sql IMMUTABLE AS $$
SELECT * FROM (VALUES
 ( 1, 'public.organizations'           , 'id'                 , 'id = $1'                        , 'id'                              , 'rows', '{}'::text[]       , '{}'::text[]),
 ( 2, 'public.organization_settings'   , NULL::text           , 'organization_id = $1'           , 'key'                             , 'rows', '{}'               , '{}'),
 ( 3, 'public.organization_codes'      , NULL                 , 'organization_id = $1'           , 'code'                            , 'rows', '{}'               , '{}'),
 ( 4, 'public.organization_holidays'   , NULL                 , 'organization_id = $1'           , 'day'                             , 'rows', '{}'               , '{}'),
 ( 5, 'public.organization_invites'    , NULL                 , 'organization_id = $1'           , 'code'                            , 'rows', '{}'               , '{}'),
 ( 6, 'public.settings_versions'       , 'id'                 , 'organization_id = $1'           , 'ord'                             , 'rows', '{}'               , '{}'),
 ( 7, 'auth.users'                     , 'id'                 , 'id = ANY({M})'                  , 'id'                              , 'ids' , '{}'               , '{}'),
 ( 8, 'auth.identities'                , 'id'                 , 'user_id = ANY({M})'             , 'id'                              , 'ids' , '{}'               , '{}'),
 ( 9, 'public.profiles'                , 'id'                 , 'organization_id = $1'           , 'id'                              , 'rows', '{}'               , '{manager_id}'),
 (10, 'public.employee_month_plan'     , NULL                 , 'organization_id = $1'           , 'version_id, personnel_number, month', 'rows', '{}'            , '{}'),
 (11, 'public.user_roles'              , NULL                 , 'user_id = ANY({M})'             , 'user_id, role::text'             , 'rows', '{}'               , '{}'),
 (12, 'public.devices'                 , 'id'                 , 'organization_id = $1'           , 'created_at, id'                  , 'rows', '{}'               , '{replaces_device_id}'),
 (13, 'public.punches'                 , 'id'                 , 'user_id = ANY({M})'             , 'id'                              , 'rows', '{id}'             , '{}'),
 (14, 'public.corrections'             , NULL                 , 'user_id = ANY({M})'             , 'created_at, id'                  , 'rows', '{punch_id}'       , '{}'),
 (15, 'public.punch_void_requests'     , NULL                 , 'user_id = ANY({M})'             , 'created_at, id'                  , 'rows', '{punch_id}'       , '{}'),
 (16, 'public.month_closures'          , NULL                 , 'user_id = ANY({M})'             , 'user_id, year, month'            , 'rows', '{}'               , '{}'),
 (17, 'public.personnel_requests'      , NULL                 , 'user_id = ANY({M})'             , 'created_at, id'                  , 'rows', '{}'               , '{}'),
 (18, 'public.notification_preferences', NULL                 , 'user_id = ANY({M})'             , 'user_id'                         , 'rows', '{}'               , '{}'),
 (19, 'public.correction_auto_approvals', NULL                , 'user_id = ANY({M})'             , 'user_id'                         , 'rows', '{}'               , '{}'),
 (20, 'public.audit_log'               , NULL                 , 'actor = ANY({M})'               , 'id'                              , 'rows', '{id}'             , '{}'),
 (21, 'public.month_closure_snapshots' , NULL                 , 'organization_id = $1'           , 'user_id, year, month'            , 'rows', '{}'               , '{}')
) v(ord, rel, key_col, filter, order_by, mode, digest_exclude, null_cols) ORDER BY ord
$$;

-- Odkazy pri importe. Odkaz na verziu nastavení (version_id, settings_version_id) je druhu 'own': že vedie na verziu TEJ ISTEJ
-- organizácie, vynucujú zložené cudzie kľúče (organization_id, verzia) a organization_id sa kontroluje druhom 'org'.
-- Rok a mesiac snímky sú súčasťou cudzieho kľúča na month_closures (tiež 'own').
CREATE OR REPLACE FUNCTION org_transfer.import_refs() RETURNS TABLE(rel text, col text, kind text) LANGUAGE sql IMMUTABLE AS $$
SELECT * FROM (VALUES
 ('public.organizations', 'id', 'own'), ('public.organizations', 'created_by', 'user_loose'),
 ('public.organization_settings', 'organization_id', 'org'),
 ('public.organization_codes', 'organization_id', 'org'),
 ('public.organization_holidays', 'organization_id', 'org'),
 ('public.organization_invites', 'organization_id', 'org'),
 ('public.settings_versions', 'id', 'own'), ('public.settings_versions', 'organization_id', 'org'), ('public.settings_versions', 'created_by', 'user_loose'),
 ('public.employee_month_plan', 'organization_id', 'org'), ('public.employee_month_plan', 'version_id', 'own'),
 ('auth.identities', 'user_id', 'owner'),
 ('public.profiles', 'id', 'own'), ('public.profiles', 'organization_id', 'org'), ('public.profiles', 'manager_id', 'user'),
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
 ('public.audit_log', 'actor', 'owner'),
 ('public.month_closure_snapshots', 'organization_id', 'org'), ('public.month_closure_snapshots', 'user_id', 'owner'),
 ('public.month_closure_snapshots', 'settings_version_id', 'own'),
 ('public.month_closure_snapshots', 'year', 'own'), ('public.month_closure_snapshots', 'month', 'own')
) v(rel, col, kind)
$$;

NOTIFY pgrst, 'reload schema';

-- Kontrola po spustení (každý riadok má vrátiť true):
--   SELECT NOT EXISTS (SELECT 1 FROM public.organizations o WHERE NOT EXISTS (SELECT 1 FROM public.settings_versions v WHERE v.organization_id = o.id));
--   SELECT (SELECT relkind FROM pg_class WHERE oid = 'public.access_config'::regclass) = 'v';
--   SELECT cardinality(org_transfer.uncovered_tables()) = 0 AND cardinality(org_transfer.import_unclassified()) = 0;
--   SELECT (SELECT count(*) FROM public.month_closures) = (SELECT count(*) FROM public.month_closure_snapshots);
