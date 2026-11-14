-- 0016: prenos celej organizácie na iný server – strana EXPORTU (databáza).
--
-- Správca organizácie vie v skrytej karte Servis vyexportovať celú svoju organizáciu (účty s hashmi PIN a hesiel, osobné čísla,
-- zariadenia, razenia s hash reťazou, opravy, uzávierky, nastavenia, konfigurácia z Accessu, audit) tak, aby sa dala na inom serveri
-- znova vytvoriť. Šifrovanie súboru heslom robí prehliadač (nie databáza), heslo sa na server nikdy neodošle.
-- Táto migrácia dodáva len databázovú časť. Obrazovka a šifrovanie v prehliadači, import na cieľovom serveri a Docker prídu osobitne.
--
-- Ako to ide (všetko volá prihlásený SPRÁVCA, vždy len nad svojou organizáciou):
--   1. org_export_begin(_lock)   založí prenos, voliteľne ZAMKNE razenia organizácie a uloží kontrolné súčty údajov v tej chvíli,
--   2. org_export_page(...)      po stránkach (po 2 000 riadkov) vydáva tabuľky; každé volanie je krátke, lebo databáza prihláseným
--                                používateľom povoľuje len ~8 s na príkaz (celý export jedným volaním by pri väčšej organizácii zlyhal),
--   3. org_export_finish(...)    overí, že súbor je úplný a údaje sa počas exportu nezmenili, a označí organizáciu ako testovaciu,
--   4. org_transfer_status()     stav prenosu a zmeny od exportu (pre obrazovku),
--   5. org_transfer_confirm_and_delete(kód, názov, ...)  zrušenie pôvodnej organizácie, až keď cieľový server potvrdil prenos kódom,
--   6. org_transfer_cancel()     zrušenie prenosu (odomkne razenia, vráti označenie testovacia, ak ho nastavil prenos).
--
-- Ochrany:
--   * zámok razení (voliteľný): kým trvá, databáza odmietne nové razenia organizácie (SQLSTATE 55000). Terminál také razenie nezahodí
--     ani nezaparkuje, ukladá si ho a skúša znova, takže po zrušení prenosu sa odošle samo. Zámok z nedokončeného exportu (stav ready)
--     sám vyprší po 2 hodinách; po dokončenom exporte trvá, kým prenos nepotvrdíte alebo nezrušíte,
--   * organizáciu s rozpracovaným prenosom nejde zrušiť inak ako cez org_transfer_confirm_and_delete (spúšťač na tabuľke organizations;
--     zastaví aj priame volanie delete_test_organization). Najprv treba prenos potvrdiť kódom alebo ho zrušiť,
--   * KÓD POTVRDENIA PRENOSU (XXXX-XXXX) odvodený z kontrolných súčtov údajov vypíše cieľový server až po úspešnom importe a overení.
--     Bez správneho kódu sa organizácia nezruší. Údaje, ktoré pribudli od exportu (napr. razenia bez zámku), sa pri zrušení vypíšu a
--     treba ich výslovne odsúhlasiť (inak by sa stratili),
--   * pôvodnú organizáciu (00000000-0000-4000-8000-000000000001) nejde označiť ako testovaciu ani zrušiť (platí 0007), exportovať sa dá,
--   * funkcie bežia s právami vlastníka migrácie; každá najprv overí prihlásenie a rolu správcu a pracuje len s organizáciou volajúceho.
--     Pomocné tabuľky a funkcie sú v schéme org_transfer, ktorú REST API nevidí.
--
-- Predpoklady: migrácie 0001–0008 (organizácie, role, testovacia organizácia). Súbor je opakovateľný (CREATE OR REPLACE / IF NOT EXISTS).
-- Súbor org_transfer.* zdieľa s privátnym balíkom 0015 (operátorský prenos cez psql): spoločné funkcie sú v oboch rovnaké.
-- Súbor prenosu je vo formáte 2 (kontrolné súčty po tabuľkách; formát 1 z balíka 0015 mal navyše súčet celého súboru, ktorý prehliadač nevie spočítať).
-- Pred spustením urobte zálohu: docs/ZALOHA-DATABAZY.md. Návrat: docs/migracie/0016_spat_zachranny.sql.

CREATE SCHEMA IF NOT EXISTS org_transfer;
REVOKE ALL ON SCHEMA org_transfer FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA org_transfer REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
COMMENT ON SCHEMA org_transfer IS 'Prenos celej organizácie medzi databázami (migrácia 0016 a súkromný balík 0015). Neexponuje sa cez REST API.';

CREATE OR REPLACE FUNCTION org_transfer.version() RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT 'org_transfer 2 (migrácia 0016, export)' $$;


-- ===== Spoločné funkcie (rovnaké ako v privátnom balíku 0015) =====

-- Kód organizácie ako ho zobrazuje aplikácia: prvých 8 hexadecimálnych znakov id veľkými písmenami.
CREATE OR REPLACE FUNCTION org_transfer.org_code(_id uuid) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT upper(left(replace(_id::text, '-', ''), 8))
$$;

-- -----------------------------------------------------------------------------------------------------
-- Zoznam prenášaných tabuliek (poradie = poradie vkladania; mazanie ide opačne).
--   filter: {M} = pole id členov organizácie (profiles), $1 = id organizácie
--   mode:   rows = porovnáva sa každý riadok; ids = porovnávajú sa len id (tabuľky auth, ktorých stĺpce závisia od verzie GoTrue)
--   digest_exclude: stĺpce, ktoré sa pri porovnaní riadkov vynechávajú (číslovanie, ktoré sa pri prenose smie zmeniť)
--   null_cols: odkazy na tú istú tabuľku; vkladajú sa až druhým krokom (po vložení všetkých riadkov)
-- Tabuľky bez organizácie (absence_codes, settings, holidays) sa neprenášajú: sú spoločné pre celú databázu.
-- -----------------------------------------------------------------------------------------------------
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

-- Spoločné číselníky (neprenášajú sa; cieľ ich musí mať).
CREATE OR REPLACE FUNCTION org_transfer.global_tables() RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['absence_codes', 'settings', 'holidays']
$$;

-- Tabuľky v schéme public, ktoré prenos nepozná (po pridaní novej migrácie s tabuľkou sa to tu ukáže hneď, nie až po strate dát).
CREATE OR REPLACE FUNCTION org_transfer.uncovered_tables() RETURNS text[]
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), ARRAY[]::text[])
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND NOT c.relispartition
    AND ('public.' || c.relname) NOT IN (SELECT rel FROM org_transfer.spec())
    AND c.relname <> ALL (org_transfer.global_tables())
$$;

-- Zhodný výpočet nad živými tabuľkami cieľovej databázy; _cols = {tabuľka: [stĺpce zo súboru]}
CREATE OR REPLACE FUNCTION org_transfer.fp_live(_org uuid, _cols jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET timezone = 'UTC' SET search_path = pg_catalog AS $fn$
DECLARE r record; members uuid[]; res jsonb := '{}'; q text; n bigint; d text; cols text[];
BEGIN
  members := ARRAY(SELECT id FROM public.profiles WHERE organization_id = _org);
  FOR r IN SELECT * FROM org_transfer.spec() ORDER BY ord LOOP
    cols := ARRAY(SELECT jsonb_array_elements_text(coalesce(_cols->r.rel, '[]'::jsonb)));
    IF r.mode = 'ids' THEN
      q := format('SELECT count(*), md5(coalesce(string_agg(t.%I::text, '','' ORDER BY t.%I::text), '''')) FROM %s t WHERE %s',
                  r.key_col, r.key_col, r.rel, replace(r.filter, '{M}', '$2'));
    ELSE
      q := format('SELECT count(*), md5(coalesce(string_agg(c, E''\n'' ORDER BY c), '''')) FROM (SELECT (SELECT jsonb_object_agg(k, v) FROM jsonb_each(to_jsonb(t)) x(k, v) WHERE k = ANY($3) AND k <> ALL($4))::text AS c FROM %s t WHERE %s) s',
                  r.rel, replace(r.filter, '{M}', '$2'));
    END IF;
    EXECUTE q INTO n, d USING _org, members, cols, r.digest_exclude;
    res := res || jsonb_build_object(r.rel, jsonb_build_object('n', n, 'd', d));
  END LOOP;
  RETURN res;
END $fn$;

CREATE OR REPLACE FUNCTION org_transfer.chain_problems_live(_members uuid[]) RETURNS bigint
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT count(*) FROM (
    SELECT p.prev_hash, lag(p.record_hash) OVER (PARTITION BY p.user_id ORDER BY p.id) AS expected
    FROM public.punches p WHERE p.user_id = ANY (_members)) s
  WHERE s.prev_hash IS DISTINCT FROM coalesce(s.expected, 'GENESIS')
$$;

CREATE OR REPLACE FUNCTION org_transfer.order_digest_live(_members uuid[]) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT md5(coalesce(string_agg(p.record_hash, ',' ORDER BY p.user_id, p.id), ''))
  FROM public.punches p WHERE p.user_id = ANY (_members)
$$;

-- -----------------------------------------------------------------------------------------------------
-- Kód potvrdenia prenosu: z kontrolných súčtov údajov (id organizácie, počty a odtlačky tabuliek, poradie hashov razení).
-- Rovnaký výpočet urobí cieľový server nad súborom po úspešnom overení importu. Nie je to tajomstvo, je to poistka proti omylu.
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION org_transfer.receipt(_meta jsonb) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT substr(h, 1, 4) || '-' || substr(h, 5, 4)
  FROM (SELECT upper(encode(sha256(convert_to(
           jsonb_build_array(_meta->'organization'->>'id', _meta->'fingerprint', _meta->>'order_digest')::text, 'UTF8')), 'hex')) AS h) s
$$;

-- Odtlačok jednej tabuľky (rovnaký výpočet ako fp_live, len pre jeden riadok zoznamu spec()).
CREATE OR REPLACE FUNCTION org_transfer.fp_one(_org uuid, _rel text, _cols jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET timezone = 'UTC' SET search_path = pg_catalog AS $fn$
DECLARE r record; members uuid[]; q text; n bigint; d text; cols text[];
BEGIN
  SELECT * INTO r FROM org_transfer.spec() s WHERE s.rel = _rel;
  IF r.rel IS NULL THEN RAISE EXCEPTION 'Neznáma tabuľka %', _rel; END IF;
  members := ARRAY(SELECT id FROM public.profiles WHERE organization_id = _org);
  cols := ARRAY(SELECT jsonb_array_elements_text(coalesce(_cols, '[]'::jsonb)));
  IF r.mode = 'ids' THEN
    q := format('SELECT count(*), md5(coalesce(string_agg(t.%I::text, '','' ORDER BY t.%I::text), '''')) FROM %s t WHERE %s',
                r.key_col, r.key_col, r.rel, replace(r.filter, '{M}', '$2'));
  ELSE
    q := format('SELECT count(*), md5(coalesce(string_agg(c, E''\n'' ORDER BY c), '''')) FROM (SELECT (SELECT jsonb_object_agg(k, v) FROM jsonb_each(to_jsonb(t)) x(k, v) WHERE k = ANY($3) AND k <> ALL($4))::text AS c FROM %s t WHERE %s) s',
                r.rel, replace(r.filter, '{M}', '$2'));
  END IF;
  EXECUTE q INTO n, d USING _org, members, cols, r.digest_exclude;
  RETURN jsonb_build_object('n', n, 'd', d);
END $fn$;

-- -----------------------------------------------------------------------------------------------------
-- Zmeny od exportu. Kontrolné súčty sa tu rátajú BEZ stĺpcov, ktoré sa menia samy (devices.last_seen_at, organizations.is_test)
-- a bez audit_log (každá akcia správcu pridá riadok). Ostatné tabuľky: akákoľvek zmena sa ráta.
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION org_transfer.drift_cols() RETURNS jsonb LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT jsonb_object_agg(s.rel, (SELECT jsonb_agg(a.attname::text ORDER BY a.attnum)
                                  FROM pg_attribute a
                                  WHERE a.attrelid = s.rel::regclass AND a.attnum > 0 AND NOT a.attisdropped
                                    AND NOT ((s.rel = 'public.devices' AND a.attname = 'last_seen_at')
                                          OR (s.rel = 'public.organizations' AND a.attname = 'is_test'))))
  FROM org_transfer.spec() s WHERE s.rel <> 'public.audit_log'
$$;
CREATE OR REPLACE FUNCTION org_transfer.drift_fp(_org uuid) RETURNS jsonb LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT org_transfer.fp_live(_org, org_transfer.drift_cols()) - 'public.audit_log'
$$;
-- {tabuľka: {then, now}} len pre tabuľky, ktoré sa od uloženého odtlačku zmenili
CREATE OR REPLACE FUNCTION org_transfer.drift(_org uuid, _then jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $$
DECLARE cur jsonb := org_transfer.drift_fp(_org); k text; res jsonb := '{}';
BEGIN
  FOR k IN SELECT jsonb_object_keys(_then) LOOP
    IF _then->k IS DISTINCT FROM cur->k THEN
      res := res || jsonb_build_object(k, jsonb_build_object('then', (_then->k->>'n')::bigint, 'now', (cur->k->>'n')::bigint));
    END IF;
  END LOOP;
  RETURN res;
END $$;

-- -----------------------------------------------------------------------------------------------------
-- Stav prenosov (tabuľky v schéme org_transfer; neprenášajú sa a nezrušia sa so zrušením organizácie, ostane po nich záznam)
-- -----------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS org_transfer.transfers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  org_name text NOT NULL,
  started_by uuid,
  started_at timestamptz NOT NULL DEFAULT now(),
  state text NOT NULL CHECK (state IN ('ready', 'exported', 'confirmed', 'cancelled')),
  locked boolean NOT NULL,
  marked_test boolean NOT NULL DEFAULT false,
  meta jsonb NOT NULL,
  drift_fp jsonb NOT NULL,
  audit_max bigint NOT NULL DEFAULT 0,
  exported_at timestamptz,
  confirmed_at timestamptz,
  cancelled_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS transfers_one_active ON org_transfer.transfers (organization_id) WHERE state IN ('ready', 'exported');
ALTER TABLE org_transfer.transfers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON org_transfer.transfers FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN EXECUTE 'REVOKE ALL ON org_transfer.transfers FROM anon'; END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN EXECUTE 'REVOKE ALL ON org_transfer.transfers FROM authenticated'; END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN EXECUTE 'REVOKE ALL ON org_transfer.transfers FROM service_role'; END IF;
END $$;

-- Prihlásený správca a jeho organizácia (spoločná kontrola všetkých funkcií nižšie)
CREATE OR REPLACE FUNCTION org_transfer.caller_org() RETURNS uuid LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $$
DECLARE org uuid := public.my_organization();
BEGIN
  IF auth.uid() IS NULL OR org IS NULL THEN RAISE EXCEPTION 'Prihlásenie je potrebné'; END IF;
  IF NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Nemáte oprávnenie'; END IF;
  RETURN org;
END $$;

-- -----------------------------------------------------------------------------------------------------
-- Zámok razení a ochrana pred predčasným zrušením organizácie
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.punches_transfer_lock() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM org_transfer.transfers t JOIN public.profiles p ON p.organization_id = t.organization_id
             WHERE p.id = NEW.user_id AND t.locked
               AND (t.state = 'exported' OR (t.state = 'ready' AND t.started_at > now() - interval '2 hours'))) THEN
    RAISE EXCEPTION 'Organizácia sa práve prenáša na iný server. Razenie sa teraz nedá zapísať, terminál ho uloží a odošle neskôr.' USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS a_punches_transfer_lock ON public.punches;
CREATE TRIGGER a_punches_transfer_lock BEFORE INSERT ON public.punches FOR EACH ROW EXECUTE FUNCTION public.punches_transfer_lock();

CREATE OR REPLACE FUNCTION public.organizations_transfer_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM org_transfer.transfers t WHERE t.organization_id = OLD.id AND t.state IN ('ready', 'exported')) THEN
    RAISE EXCEPTION 'Organizácia má rozpracovaný prenos na iný server. Zrušiť ju možno až po potvrdení prenosu kódom z cieľového servera, alebo po zrušení prenosu.' USING ERRCODE = '55000';
  END IF;
  RETURN OLD;
END $$;
DROP TRIGGER IF EXISTS a_organizations_transfer_guard ON public.organizations;
CREATE TRIGGER a_organizations_transfer_guard BEFORE DELETE ON public.organizations FOR EACH ROW EXECUTE FUNCTION public.organizations_transfer_guard();

-- -----------------------------------------------------------------------------------------------------
-- 1. Začiatok exportu. Vráti id prenosu, hlavičku súboru (meta) a zoznam tabuliek s počtami riadkov.
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.org_export_begin(_lock boolean DEFAULT true) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public SET timezone = 'UTC' AS $$
DECLARE org uuid; o public.organizations; unknown text[]; members uuid[]; cols jsonb := '{}'; fp jsonb; counts jsonb := '{}'; r record;
        meta jsonb; dfp jsonb; dcols jsonb; tid uuid := gen_random_uuid(); amax bigint; carried boolean := false; tables jsonb := '[]';
BEGIN
  org := org_transfer.caller_org();
  IF _lock IS NULL THEN RAISE EXCEPTION 'Neplatná hodnota'; END IF;
  SELECT * INTO o FROM public.organizations WHERE id = org;
  unknown := org_transfer.uncovered_tables();
  IF cardinality(unknown) > 0 THEN
    RAISE EXCEPTION 'Prenos nepozná tabuľky: %. Doplňte ich do org_transfer.spec(), inak by sa ich údaje stratili.', array_to_string(unknown, ', ');
  END IF;

  -- Nový export nahrádza predchádzajúci neukončený; označenie testovacia, ktoré nastavil prenos, sa prenáša ďalej.
  SELECT coalesce(bool_or(t.marked_test), false) INTO carried FROM org_transfer.transfers t WHERE t.organization_id = org AND t.state IN ('ready', 'exported');
  UPDATE org_transfer.transfers SET state = 'cancelled', cancelled_at = now() WHERE organization_id = org AND state IN ('ready', 'exported');

  IF _lock THEN
    -- Počká na rozpísané razenia (najviac 5 s) a až potom sa číta: razenia zapísané do tejto chvíle sú v súbore, ďalšie už odmietne spúšťač.
    PERFORM set_config('lock_timeout', '5s', true);
    LOCK TABLE public.punches IN SHARE ROW EXCLUSIVE MODE;
  END IF;

  -- Záznam o začiatku prenosu sa zapíše PRED výpočtom odtlačkov, aby bol aj on v súbore; neskoršie záznamy auditu sa do súboru nedostanú (audit_max).
  INSERT INTO public.audit_log (actor, action, target, details)
  VALUES (auth.uid(), 'organization.transfer_started', org::text, jsonb_build_object('transfer', tid, 'locked', _lock));
  SELECT coalesce(max(id), 0) INTO amax FROM public.audit_log;
  members := ARRAY(SELECT id FROM public.profiles WHERE organization_id = org);
  FOR r IN SELECT * FROM org_transfer.spec() ORDER BY ord LOOP
    cols := cols || jsonb_build_object(r.rel, (SELECT jsonb_agg(a.attname::text ORDER BY a.attnum)
                                                FROM pg_attribute a WHERE a.attrelid = r.rel::regclass AND a.attnum > 0 AND NOT a.attisdropped));
  END LOOP;
  fp := org_transfer.fp_live(org, cols);
  FOR r IN SELECT * FROM org_transfer.spec() ORDER BY ord LOOP
    counts := counts || jsonb_build_object(r.rel, (fp->r.rel->>'n')::bigint);
    tables := tables || jsonb_build_array(jsonb_build_object('rel', r.rel, 'n', (fp->r.rel->>'n')::bigint));
  END LOOP;
  -- Odtlačok na zisťovanie zmien od exportu = ten istý odtlačok bez audit_log a bez samovoľne sa meniacich stĺpcov (tabuľky devices a organizations
  -- sa rátajú znova, ostatné sa preberú, aby sa veľké tabuľky neprechádzali dvakrát).
  dcols := org_transfer.drift_cols();
  dfp := (fp - 'public.audit_log' - 'public.devices' - 'public.organizations')
         || jsonb_build_object('public.devices', org_transfer.fp_one(org, 'public.devices', dcols->'public.devices'),
                               'public.organizations', org_transfer.fp_one(org, 'public.organizations', dcols->'public.organizations'));
  meta := jsonb_build_object(
    'format', 2, 'tool', org_transfer.version(), 'exported_at', now(), 'source_db', current_database(), 'source_server', version(),
    'organization', jsonb_build_object('id', o.id, 'name', o.name, 'code', org_transfer.org_code(o.id), 'is_test', o.is_test),
    'counts', counts, 'columns', cols, 'fingerprint', fp,
    'chain_problems', org_transfer.chain_problems_live(members), 'order_digest', org_transfer.order_digest_live(members));

  INSERT INTO org_transfer.transfers (id, organization_id, org_name, started_by, state, locked, marked_test, meta, drift_fp, audit_max)
  VALUES (tid, org, o.name, auth.uid(), 'ready', _lock, carried, meta, dfp, amax);
  RETURN jsonb_build_object('transfer_id', tid, 'locked', _lock, 'meta', meta, 'tables', tables, 'page_size', 2000);
END $$;

-- -----------------------------------------------------------------------------------------------------
-- 2. Jedna stránka tabuľky. _rel musí byť z org_transfer.spec().
-- Riadky (pole objektov, rovnaký tvar ako v súbore) sa vracajú ako TEXT (`rows` je reťazec s JSON), nie ako vnorený JSON: klient ich do súboru
-- vloží bez spracovania. Inak by ich prehliadač pri čítaní odpovede prevádzal na čísla JavaScriptu a stratil by napr. 7.50 → 7.5 alebo 8.0 → 8
-- vo vnorenom jsonb (odtlačok riadku na cieli by sa potom nezhodoval).
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.org_export_page(_transfer uuid, _rel text, _offset integer DEFAULT 0, _limit integer DEFAULT 2000) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public SET timezone = 'UTC' AS $$
DECLARE org uuid; t org_transfer.transfers; s record; members uuid[]; rws jsonb;
BEGIN
  org := org_transfer.caller_org();
  SELECT * INTO t FROM org_transfer.transfers x WHERE x.id = _transfer AND x.organization_id = org;
  IF t.id IS NULL THEN RAISE EXCEPTION 'Prenos neexistuje'; END IF;
  IF t.state <> 'ready' THEN RAISE EXCEPTION 'Prenos už nie je v stave exportu (stav: %). Začnite nový export.', t.state; END IF;
  SELECT * INTO s FROM org_transfer.spec() x WHERE x.rel = _rel;
  IF s.rel IS NULL THEN RAISE EXCEPTION 'Neznáma tabuľka'; END IF;
  IF _offset IS NULL OR _offset < 0 THEN RAISE EXCEPTION 'Neplatný posun'; END IF;
  IF _limit IS NULL OR _limit < 1 THEN RAISE EXCEPTION 'Neplatný počet riadkov'; END IF;
  _limit := LEAST(_limit, 5000);
  members := ARRAY(SELECT id FROM public.profiles WHERE organization_id = org);
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(q)), ''[]''::jsonb) FROM (SELECT * FROM %s x WHERE %s%s ORDER BY %s OFFSET $2 LIMIT $3) q',
                 s.rel, replace(s.filter, '{M}', '$4'), CASE WHEN s.rel = 'public.audit_log' THEN ' AND x.id <= $5' ELSE '' END, s.order_by)
    INTO rws USING org, _offset, _limit, members, t.audit_max;
  RETURN jsonb_build_object('rel', _rel, 'offset', _offset, 'count', jsonb_array_length(rws), 'rows', rws::text);
END $$;

-- -----------------------------------------------------------------------------------------------------
-- 3. Dokončenie exportu. _received = {tabuľka: počet riadkov, ktoré prehliadač dostal}. Označí organizáciu ako testovaciu.
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.org_export_finish(_transfer uuid, _received jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public SET timezone = 'UTC' AS $$
DECLARE org uuid; t org_transfer.transfers; r record; changed jsonb; o public.organizations; marked boolean := false;
BEGIN
  org := org_transfer.caller_org();
  SELECT * INTO t FROM org_transfer.transfers x WHERE x.id = _transfer AND x.organization_id = org FOR UPDATE;
  IF t.id IS NULL THEN RAISE EXCEPTION 'Prenos neexistuje'; END IF;
  IF t.state <> 'ready' THEN RAISE EXCEPTION 'Prenos už nie je v stave exportu (stav: %). Začnite nový export.', t.state; END IF;
  IF _received IS NULL OR jsonb_typeof(_received) <> 'object' THEN RAISE EXCEPTION 'Chýba prehľad prijatých riadkov'; END IF;
  FOR r IN SELECT * FROM org_transfer.spec() ORDER BY ord LOOP
    IF (_received->>r.rel) IS DISTINCT FROM (t.meta->'counts'->>r.rel) THEN
      RAISE EXCEPTION 'Súbor je neúplný: %: prijatých % riadkov namiesto %', r.rel, coalesce(_received->>r.rel, '0'), t.meta->'counts'->>r.rel;
    END IF;
  END LOOP;
  changed := org_transfer.drift(org, t.drift_fp);
  IF changed <> '{}'::jsonb THEN
    RAISE EXCEPTION 'Údaje sa počas exportu zmenili (tabuľky: %). Export zopakujte, najlepšie so zámkom razení.',
      (SELECT string_agg(k, ', ') FROM jsonb_object_keys(changed) k);
  END IF;

  SELECT * INTO o FROM public.organizations WHERE id = org FOR UPDATE;
  IF NOT o.is_test AND org <> '00000000-0000-4000-8000-000000000001' THEN
    UPDATE public.organizations SET is_test = true WHERE id = org;
    marked := true;
    INSERT INTO public.audit_log (actor, action, target, details)
    VALUES (auth.uid(), 'organization.test_flag', org::text, jsonb_build_object('is_test', true, 'by', 'transfer'));
  END IF;
  UPDATE org_transfer.transfers SET state = 'exported', exported_at = now(), marked_test = t.marked_test OR marked WHERE id = t.id;
  INSERT INTO public.audit_log (actor, action, target, details)
  VALUES (auth.uid(), 'organization.transfer_exported', org::text, jsonb_build_object('transfer', t.id, 'locked', t.locked, 'counts', t.meta->'counts'));
  RETURN jsonb_build_object('state', 'exported', 'transfer_id', t.id, 'locked', t.locked,
                            'is_test', (SELECT is_test FROM public.organizations WHERE id = org),
                            'protected', org = '00000000-0000-4000-8000-000000000001');
END $$;

-- -----------------------------------------------------------------------------------------------------
-- Stav prenosu pre obrazovku
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.org_transfer_status() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET timezone = 'UTC' AS $$
DECLARE org uuid; o public.organizations; t org_transfer.transfers; changed jsonb := '{}';
BEGIN
  org := org_transfer.caller_org();
  SELECT * INTO o FROM public.organizations WHERE id = org;
  SELECT * INTO t FROM org_transfer.transfers x WHERE x.organization_id = org AND x.state IN ('ready', 'exported') ORDER BY x.started_at DESC LIMIT 1;
  IF t.id IS NOT NULL THEN changed := org_transfer.drift(org, t.drift_fp); END IF;
  RETURN jsonb_build_object(
    'name', o.name, 'is_test', o.is_test, 'protected', org = '00000000-0000-4000-8000-000000000001',
    'state', coalesce(t.state, 'none'), 'transfer_id', t.id, 'locked', coalesce(t.locked, false),
    'lock_active', coalesce(t.locked AND (t.state = 'exported' OR (t.state = 'ready' AND t.started_at > now() - interval '2 hours')), false),
    'started_at', t.started_at, 'exported_at', t.exported_at, 'marked_test', coalesce(t.marked_test, false),
    'has_changes', changed <> '{}'::jsonb, 'changes', changed);
END $$;

-- -----------------------------------------------------------------------------------------------------
-- Zrušenie prenosu: odomkne razenia a vráti označenie testovacia, ak ho nastavil prenos.
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.org_transfer_cancel() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE org uuid; t org_transfer.transfers; reverted boolean := false;
BEGIN
  org := org_transfer.caller_org();
  SELECT * INTO t FROM org_transfer.transfers x WHERE x.organization_id = org AND x.state IN ('ready', 'exported') FOR UPDATE;
  IF t.id IS NULL THEN RETURN jsonb_build_object('state', 'none'); END IF;
  UPDATE org_transfer.transfers SET state = 'cancelled', cancelled_at = now() WHERE id = t.id;
  IF t.marked_test THEN
    UPDATE public.organizations SET is_test = false WHERE id = org AND is_test;
    IF FOUND THEN
      reverted := true;
      INSERT INTO public.audit_log (actor, action, target, details)
      VALUES (auth.uid(), 'organization.test_flag', org::text, jsonb_build_object('is_test', false, 'by', 'transfer_cancel'));
    END IF;
  END IF;
  INSERT INTO public.audit_log (actor, action, target, details)
  VALUES (auth.uid(), 'organization.transfer_cancelled', org::text, jsonb_build_object('transfer', t.id, 'was', t.state));
  RETURN jsonb_build_object('state', 'cancelled', 'transfer_id', t.id, 'unlocked', t.locked, 'test_flag_reverted', reverted);
END $$;

-- -----------------------------------------------------------------------------------------------------
-- 5. Zrušenie pôvodnej organizácie po potvrdení prenosu. Kód zobrazí cieľový server po úspešnom importe.
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.org_transfer_confirm_and_delete(_receipt text, _confirm_name text, _accept_changes boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public SET timezone = 'UTC' AS $$
DECLARE org uuid; o public.organizations; t org_transfer.transfers; changed jsonb; res jsonb;
BEGIN
  org := org_transfer.caller_org();
  SELECT * INTO o FROM public.organizations WHERE id = org;
  IF org = '00000000-0000-4000-8000-000000000001' THEN RAISE EXCEPTION 'Pôvodnú organizáciu nemožno zrušiť'; END IF;
  SELECT * INTO t FROM org_transfer.transfers x WHERE x.organization_id = org AND x.state = 'exported' FOR UPDATE;
  IF t.id IS NULL THEN RAISE EXCEPTION 'Pre túto organizáciu nie je dokončený export na prenos'; END IF;
  IF NOT o.is_test THEN RAISE EXCEPTION 'Zrušiť sa dá len organizácia označená ako testovacia'; END IF;
  IF upper(replace(coalesce(_receipt, ''), '-', '')) <> replace(org_transfer.receipt(t.meta), '-', '') THEN
    RAISE EXCEPTION 'Kód potvrdenia prenosu nesedí. Zadajte kód, ktorý vypísal cieľový server po úspešnom importe.';
  END IF;
  IF btrim(coalesce(_confirm_name, '')) <> btrim(o.name) THEN RAISE EXCEPTION 'Názov organizácie sa nezhoduje'; END IF;
  IF _accept_changes IS NULL THEN RAISE EXCEPTION 'Neplatná hodnota'; END IF;
  changed := org_transfer.drift(org, t.drift_fp);
  IF changed <> '{}'::jsonb AND NOT _accept_changes THEN
    RAISE EXCEPTION 'Od exportu sa údaje zmenili (tabuľky: %). Cieľový server ich nemá. Zopakujte export, alebo výslovne potvrďte, že zmeny sa môžu stratiť.',
      (SELECT string_agg(k, ', ') FROM jsonb_object_keys(changed) k);
  END IF;
  -- Prenos sa označí ako potvrdený PRED zrušením: odvtedy spúšťač na organizations organizáciu už nebrzdí. Ak zrušenie zlyhá, vráti sa aj toto označenie.
  UPDATE org_transfer.transfers SET state = 'confirmed', confirmed_at = now() WHERE id = t.id;
  res := public.purge_organization(org);
  RETURN res || jsonb_build_object('transfer_id', t.id, 'changes_accepted', changed <> '{}'::jsonb);
END $$;

-- Práva. Prednastavené práva migračnej roly by dali EXECUTE aj anonymnému používateľovi, preto ich odoberáme výslovne.
REVOKE ALL ON FUNCTION public.org_export_begin(boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.org_export_page(uuid, text, integer, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.org_export_finish(uuid, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.org_transfer_status() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.org_transfer_cancel() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.org_transfer_confirm_and_delete(text, text, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.punches_transfer_lock() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.organizations_transfer_guard() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.org_export_begin(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.org_export_page(uuid, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.org_export_finish(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.org_transfer_status() TO authenticated;
GRANT EXECUTE ON FUNCTION public.org_transfer_cancel() TO authenticated;
GRANT EXECUTE ON FUNCTION public.org_transfer_confirm_and_delete(text, text, boolean) TO authenticated;

-- Schéma org_transfer a jej funkcie: len vlastník (rola, ktorá spustila túto migráciu). Funkcie vyššie bežia s jeho právami.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA org_transfer FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON SCHEMA org_transfer FROM anon'; EXECUTE 'REVOKE ALL ON ALL FUNCTIONS IN SCHEMA org_transfer FROM anon'; END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'REVOKE ALL ON SCHEMA org_transfer FROM authenticated'; EXECUTE 'REVOKE ALL ON ALL FUNCTIONS IN SCHEMA org_transfer FROM authenticated'; END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'REVOKE ALL ON SCHEMA org_transfer FROM service_role'; EXECUTE 'REVOKE ALL ON ALL FUNCTIONS IN SCHEMA org_transfer FROM service_role'; END IF;
END $$;

SELECT org_transfer.version() AS nainstalovane;
