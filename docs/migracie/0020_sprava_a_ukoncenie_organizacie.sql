-- 0020: vlastná správa pre zariadenia, zrušenie organizácie bez presunu a prehľadnejšie neskoré razenia (nadväzuje na 0019).
--
-- Súvislosti. Migrácia 0019 dala zariadeniam oznam „organizácia sa prenáša / bola presťahovaná“ len pri PRENOSE na iný server a nesie
-- v ňom jedinú vec: nepovinnú adresu nového servera. Dve medzery:
--   1. Správca nemá ako zariadeniam povedať nič vlastné (napr. „testovanie sa skončilo“); adresa je len adresa.
--   2. Keď sa organizácia zruší bez prenosu (delete_test_organization), zariadenia s nezaslanými razeniami nedostanú NIČ:
--      účty zanikli, odoslanie už nikdy neprejde a zamestnanec vidí len „Odoslanie sa nepodarilo potvrdiť“.
--
-- Čo táto migrácia mení:
--   A. SPRÁVA PRE ZARIADENIA. K rozpracovanému prenosu možno okrem adresy uložiť krátku správu (najviac 300 znakov, jeden riadok, len
--      text). Terminál ju ukáže v okne počas prenosu aj po presťahovaní. Nová funkcia org_transfer_set_notice(adresa, správa);
--      org_transfer_set_destination(adresa) ostáva (mení len adresu a správu zachová), org_transfer_get_destination() vracia navyše „message“.
--   B. ZRUŠENIE BEZ PRESUNU. delete_test_organization(názov, správa) pred zrušením zapíše oznam „ended“ (organizácia bola zrušená, nikam sa
--      nepresťahovala) s voliteľnou správou. Zariadenie ho dostane tou istou funkciou punch_move_notice ako oznam „moved“. Druhý parameter
--      je nepovinný: volanie len s názvom funguje ďalej. purge_organization sa NEMENÍ (zrušenie po prenose robí oznam „moved“ spúšťač z 0019).
--   C. NESKORÉ RAZENIA. late_punches_import
--      * k poľu device každého zapísaného razenia pridá predponu „neskoré: “ (dá sa potom nájsť; autor súboru si obsah volí, predponu nie),
--      * v odpovedi vráti rozpis po účtoch (osobné číslo, počet, od, do), aby správca videl, ktorých ľudí sa súbor týka.
--
-- Oznam číta aj neprihlásený (kto pozná id účtu), preto správa nesmie obsahovať osobné údaje; v aplikácii je na to upozornenie. Oznam stále
-- nenesie osobné čísla, mená ani e-maily: po zrušení organizácie ostávajú len SHA-256 odtlačky id účtov, adresa a správa.
-- Tabuľky punches a profiles sa NEMENIA, export pre Access ani kontrakt sa nemenia (device nie je súčasťou kontraktu).
--
-- Predpoklady: 0019 a 0007. Opakovateľné. Pred spustením urobte zálohu: docs/ZALOHA-DATABAZY.md. Návrat: 0020_spat_zachranny.sql (spúšťa sa PRED
-- 0019_spat_zachranny.sql).

DO $$ BEGIN
  IF to_regprocedure('public.punch_move_notice(uuid[])') IS NULL OR to_regclass('org_transfer.move_notices') IS NULL THEN
    RAISE EXCEPTION 'Najprv spustite migráciu 0019 (docs/migracie/0019_razenia_po_prestahovani.sql).';
  END IF;
  IF to_regprocedure('public.delete_test_organization(text)') IS NULL AND to_regprocedure('public.delete_test_organization(text, text)') IS NULL THEN
    RAISE EXCEPTION 'Najprv spustite migráciu 0007 (zrušenie testovacej organizácie).';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION org_transfer.move_version() RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT 'org_move 2 (migrácia 0020)' $$;

-- Správa pre zariadenia: jeden riadok čistého textu, 1 až 300 znakov, bez okrajových medzier, bez riadiacich znakov a znakov, ktoré menia smer
-- alebo skrývajú text (zero-width, bidi). Aplikácia ju ukazuje ako text (nikdy ako HTML ani odkaz).
CREATE OR REPLACE FUNCTION org_transfer.valid_message(_m text) RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT _m IS NOT NULL AND length(_m) BETWEEN 1 AND 300 AND _m = btrim(_m)
     AND _m !~ '[\x01-\x1f\x7f-\x9f\u200b-\u200f\u2028-\u202e\u2066-\u2069\ufeff]'
$$;

-- -----------------------------------------------------------------------------------------------------
-- Tabuľka oznamov: nový stav „ended“, stĺpec správy, prenos nie je pri „ended“ povinný
-- -----------------------------------------------------------------------------------------------------
ALTER TABLE org_transfer.move_notices ADD COLUMN IF NOT EXISTS message text;
ALTER TABLE org_transfer.move_notices ALTER COLUMN transfer_id DROP NOT NULL;
ALTER TABLE org_transfer.move_notices DROP CONSTRAINT IF EXISTS move_notices_state_check;
ALTER TABLE org_transfer.move_notices ADD CONSTRAINT move_notices_state_check CHECK (state IN ('announced', 'moved', 'ended'));
ALTER TABLE org_transfer.move_notices DROP CONSTRAINT IF EXISTS move_notices_transfer_check;
ALTER TABLE org_transfer.move_notices ADD CONSTRAINT move_notices_transfer_check CHECK (state = 'ended' OR transfer_id IS NOT NULL);
ALTER TABLE org_transfer.move_notices DROP CONSTRAINT IF EXISTS move_notices_message_check;
ALTER TABLE org_transfer.move_notices ADD CONSTRAINT move_notices_message_check CHECK (message IS NULL OR org_transfer.valid_message(message));
COMMENT ON TABLE org_transfer.move_notices IS 'Oznam o presťahovaní alebo zrušení organizácie (migrácie 0019 a 0020). Po zrušení organizácie drží len odtlačky id jej účtov, adresu a správu, nie údaje.';

-- Jediné miesto, kde sa zapisuje oznam „announced“ (adresa a správa k rozpracovanému prenosu). Obe hodnoty prázdne = oznam sa zruší.
CREATE OR REPLACE FUNCTION org_transfer.put_announced(_org uuid, _transfer uuid, _url text, _message text) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF _url IS NULL AND _message IS NULL THEN
    DELETE FROM org_transfer.move_notices m WHERE m.organization_id = _org AND m.state = 'announced';
  ELSE
    INSERT INTO org_transfer.move_notices AS m (organization_id, transfer_id, state, new_url, message)
    VALUES (_org, _transfer, 'announced', _url, _message)
    ON CONFLICT (organization_id) DO UPDATE SET transfer_id = EXCLUDED.transfer_id, state = 'announced', new_url = EXCLUDED.new_url,
                                                message = EXCLUDED.message, member_hashes = '{}', updated_at = now();
  END IF;
END $$;

-- Stav oznamu sleduje stav prenosu (ako v 0019); pri potvrdení prenosu sa k „moved“ prenesie aj správa.
CREATE OR REPLACE FUNCTION org_transfer.transfers_move_notice() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- Nový export: organizácia je tu živá, starý oznam (aj „moved“ alebo „ended“ po skoršom odsťahovaní a návrate) už neplatí.
    DELETE FROM org_transfer.move_notices m WHERE m.organization_id = NEW.organization_id;
  ELSIF NEW.state = 'confirmed' AND OLD.state IS DISTINCT FROM 'confirmed' THEN
    INSERT INTO org_transfer.move_notices AS m (organization_id, transfer_id, state, new_url, message, member_hashes, updated_at)
    VALUES (NEW.organization_id, NEW.id, 'moved', NULL, NULL,
            ARRAY(SELECT org_transfer.user_hash(p.id) FROM public.profiles p WHERE p.organization_id = NEW.organization_id), now())
    ON CONFLICT (organization_id) DO UPDATE
      SET state = 'moved',
          new_url = CASE WHEN m.transfer_id = EXCLUDED.transfer_id THEN m.new_url ELSE NULL END,
          message = CASE WHEN m.transfer_id = EXCLUDED.transfer_id THEN m.message ELSE NULL END,
          transfer_id = EXCLUDED.transfer_id, member_hashes = EXCLUDED.member_hashes, updated_at = now();
  ELSIF NEW.state = 'cancelled' AND OLD.state IS DISTINCT FROM 'cancelled' THEN
    DELETE FROM org_transfer.move_notices m WHERE m.transfer_id = NEW.id AND m.state = 'announced';
  END IF;
  RETURN NULL;
END $$;

-- -----------------------------------------------------------------------------------------------------
-- A. Adresa a správa k rozpracovanému prenosu
-- -----------------------------------------------------------------------------------------------------
-- Zmení len adresu (správa ostáva). Volá ju aj aplikácia z doby pred 0020.
CREATE OR REPLACE FUNCTION public.org_transfer_set_destination(_url text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE org uuid; t org_transfer.transfers; url text := nullif(btrim(coalesce(_url, '')), ''); cur text;
BEGIN
  org := org_transfer.caller_org();
  SELECT * INTO t FROM org_transfer.transfers x WHERE x.organization_id = org AND x.state IN ('ready', 'exported') FOR UPDATE;
  IF t.id IS NULL THEN RAISE EXCEPTION 'Organizácia nemá rozpracovaný prenos. Novú adresu možno uložiť až po exporte.'; END IF;
  IF url IS NOT NULL THEN
    url := regexp_replace(url, '/+$', '');
    IF NOT org_transfer.valid_destination(url) THEN
      RAISE EXCEPTION 'Adresa nie je platná. Zadajte ju v tvare https://nazov.servera (bez mena, hesla a otáznika).';
    END IF;
  END IF;
  SELECT m.message INTO cur FROM org_transfer.move_notices m WHERE m.organization_id = org AND m.transfer_id = t.id AND m.state = 'announced';
  PERFORM org_transfer.put_announced(org, t.id, url, cur);
  INSERT INTO public.audit_log (actor, action, target, details)
  VALUES (auth.uid(), 'organization.transfer_destination', org::text, jsonb_build_object('transfer', t.id, 'url', url));
  RETURN jsonb_build_object('transfer_id', t.id, 'url', url);
END $$;

-- Uloží adresu aj správu naraz (prázdna hodnota ju zruší).
CREATE OR REPLACE FUNCTION public.org_transfer_set_notice(_url text, _message text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE org uuid; t org_transfer.transfers; url text := nullif(btrim(coalesce(_url, '')), ''); msg text := nullif(btrim(coalesce(_message, '')), '');
BEGIN
  org := org_transfer.caller_org();
  SELECT * INTO t FROM org_transfer.transfers x WHERE x.organization_id = org AND x.state IN ('ready', 'exported') FOR UPDATE;
  IF t.id IS NULL THEN RAISE EXCEPTION 'Organizácia nemá rozpracovaný prenos. Adresu a správu možno uložiť až po exporte.'; END IF;
  IF url IS NOT NULL THEN
    url := regexp_replace(url, '/+$', '');
    IF NOT org_transfer.valid_destination(url) THEN
      RAISE EXCEPTION 'Adresa nie je platná. Zadajte ju v tvare https://nazov.servera (bez mena, hesla a otáznika).';
    END IF;
  END IF;
  IF msg IS NOT NULL AND NOT org_transfer.valid_message(msg) THEN
    RAISE EXCEPTION 'Správa nie je platná. Môže mať najviac 300 znakov, jeden riadok a len bežný text.';
  END IF;
  PERFORM org_transfer.put_announced(org, t.id, url, msg);
  INSERT INTO public.audit_log (actor, action, target, details)
  VALUES (auth.uid(), 'organization.transfer_notice', org::text, jsonb_build_object('transfer', t.id, 'url', url, 'message', msg));
  RETURN jsonb_build_object('transfer_id', t.id, 'url', url, 'message', msg);
END $$;

CREATE OR REPLACE FUNCTION public.org_transfer_get_destination() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE org uuid; res jsonb;
BEGIN
  org := org_transfer.caller_org();
  SELECT jsonb_build_object('transfer_id', t.id, 'url', m.new_url, 'message', m.message) INTO res
  FROM org_transfer.transfers t
  LEFT JOIN org_transfer.move_notices m ON m.organization_id = t.organization_id AND m.transfer_id = t.id AND m.state = 'announced'
  WHERE t.organization_id = org AND t.state IN ('ready', 'exported');
  RETURN coalesce(res, jsonb_build_object('transfer_id', NULL, 'url', NULL, 'message', NULL));
END $$;

-- -----------------------------------------------------------------------------------------------------
-- Oznam pre zariadenie (bez prihlásenia). Nové: „message“ pri všetkých stavoch a stav „ended“.
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.punch_move_notice(_users uuid[]) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE res jsonb;
BEGIN
  IF _users IS NULL OR cardinality(_users) = 0 THEN RETURN jsonb_build_object('version', 1, 'users', '{}'::jsonb); END IF;
  IF cardinality(_users) > (org_transfer.move_limits()->>'max_notice_users')::int THEN
    RAISE EXCEPTION 'Príliš veľa účtov v jednom dopyte' USING ERRCODE = '22023';
  END IF;
  SELECT coalesce(jsonb_object_agg(u.id::text, x.j), '{}'::jsonb) INTO res
  FROM (SELECT DISTINCT i AS id FROM unnest(_users) i WHERE i IS NOT NULL) u
  CROSS JOIN LATERAL (
    SELECT CASE
      WHEN EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = u.id) THEN
        -- Živý účet: len „transferring“ (rovnaká podmienka ako zámok razení). Žiadny starý oznam („moved“, „ended“) pre neho neplatí.
        (SELECT jsonb_build_object('state', 'transferring', 'url', m.new_url, 'message', m.message)
         FROM org_transfer.transfers t JOIN public.profiles p ON p.organization_id = t.organization_id
         LEFT JOIN org_transfer.move_notices m ON m.organization_id = t.organization_id AND m.transfer_id = t.id AND m.state = 'announced'
         WHERE p.id = u.id AND t.locked
           AND (t.state = 'exported' OR (t.state = 'ready' AND t.started_at > now() - interval '2 hours'))
         LIMIT 1)
      ELSE
        (SELECT jsonb_build_object('state', m.state, 'url', m.new_url, 'message', m.message, 'since', m.updated_at)
         FROM org_transfer.move_notices m
         WHERE m.state IN ('moved', 'ended') AND m.member_hashes @> ARRAY[org_transfer.user_hash(u.id)]
         ORDER BY m.updated_at DESC LIMIT 1)
    END AS j) x
  WHERE x.j IS NOT NULL;
  RETURN jsonb_build_object('version', 1, 'users', res);
END $$;

-- -----------------------------------------------------------------------------------------------------
-- B. Zrušenie testovacej organizácie bez presunu: oznam „ended“ so správou
-- -----------------------------------------------------------------------------------------------------
-- Pôvodný podpis (text) sa nahrádza podpisom (text, text DEFAULT NULL): dve funkcie s rovnakým názvom by pri volaní s jedným
-- argumentom neboli jednoznačné. Volanie len s názvom funguje ďalej.
DROP FUNCTION IF EXISTS public.delete_test_organization(text);
CREATE OR REPLACE FUNCTION public.delete_test_organization(_confirm_name text, _message text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE org public.organizations; msg text := nullif(btrim(coalesce(_message, '')), '');
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Prihlásenie je potrebné'; END IF;
  SELECT o.* INTO org FROM public.organizations o WHERE o.id = public.my_organization();
  IF org.id IS NULL THEN RAISE EXCEPTION 'Organizácia neexistuje'; END IF;
  IF NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Nemáte oprávnenie'; END IF;
  IF org.id = '00000000-0000-4000-8000-000000000001' THEN RAISE EXCEPTION 'Pôvodnú organizáciu nemožno zrušiť'; END IF;
  IF NOT org.is_test THEN RAISE EXCEPTION 'Zrušiť sa dá len organizácia označená ako testovacia'; END IF;
  IF btrim(COALESCE(_confirm_name, '')) <> btrim(org.name) THEN RAISE EXCEPTION 'Názov organizácie sa nezhoduje'; END IF;
  IF msg IS NOT NULL AND NOT org_transfer.valid_message(msg) THEN
    RAISE EXCEPTION 'Správa nie je platná. Môže mať najviac 300 znakov, jeden riadok a len bežný text.';
  END IF;
  -- Oznam sa zapíše PRED zrušením a v tej istej transakcii: ak zrušenie zlyhá (napr. rozpracovaný prenos), vráti sa aj oznam.
  INSERT INTO org_transfer.move_notices AS m (organization_id, transfer_id, state, new_url, message, member_hashes, updated_at)
  VALUES (org.id, NULL, 'ended', NULL, msg,
          ARRAY(SELECT org_transfer.user_hash(p.id) FROM public.profiles p WHERE p.organization_id = org.id), now())
  ON CONFLICT (organization_id) DO UPDATE
    SET transfer_id = NULL, state = 'ended', new_url = NULL, message = EXCLUDED.message,
        member_hashes = EXCLUDED.member_hashes, updated_at = now();
  RETURN public.purge_organization(org.id);
END $$;

-- -----------------------------------------------------------------------------------------------------
-- C. Neskoré razenia: predpona „neskoré: “ v poli device a rozpis po účtoch
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.late_punches_import(_payload jsonb, _dry_run boolean DEFAULT true) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog SET timezone = 'UTC' AS $$
DECLARE
  org uuid; lim jsonb := org_transfer.move_limits(); n int; el jsonb; ord int := 0;
  cu text; uu text; v_code text; v_dir text; ts text; dev text; t timestamptz; reason text; msg text;
  seen text[] := '{}'; ex record; dv text;
  ok_rows jsonb := '[]'; items jsonb := '[]'; reasons jsonb := '{}';
  n_ok int := 0; n_already int := 0; n_rejected int := 0; n_inserted int := 0;
  users uuid[] := '{}'; t_min timestamptz; t_max timestamptz; digest text; r record;
  by_acc jsonb := '[]';
  uuid_re constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  time_re constant text := '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$';
BEGIN
  org := org_transfer.caller_org();
  IF _dry_run IS NULL THEN RAISE EXCEPTION 'Neplatná hodnota'; END IF;
  IF _payload IS NULL OR jsonb_typeof(_payload) <> 'object' OR (_payload->>'format') IS DISTINCT FROM 'dochs-late-punches'
     OR jsonb_typeof(_payload->'punches') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Toto nie je súbor s razeniami zo zariadenia.';
  END IF;
  IF (_payload->>'version') IS DISTINCT FROM '1' THEN RAISE EXCEPTION 'Súbor je v novšom formáte, ktorý tento server nepozná.'; END IF;
  n := jsonb_array_length(_payload->'punches');
  IF n = 0 THEN RAISE EXCEPTION 'Súbor neobsahuje žiadne razenia.'; END IF;
  IF n > (lim->>'max_late_punches')::int THEN
    RAISE EXCEPTION 'Súbor má príliš veľa razení (%). Najviac % v jednom súbore.', n, lim->>'max_late_punches';
  END IF;
  IF length(_payload::text) > (lim->>'max_late_chars')::int THEN RAISE EXCEPTION 'Súbor je príliš veľký.'; END IF;
  IF EXISTS (SELECT 1 FROM org_transfer.transfers x WHERE x.organization_id = org AND x.locked
               AND (x.state = 'exported' OR (x.state = 'ready' AND x.started_at > now() - interval '2 hours'))) THEN
    RAISE EXCEPTION 'Organizácia sa práve prenáša na iný server a razenia sú zamknuté. Neskoré razenia nahrajte až na novom serveri, alebo po zrušení prenosu.';
  END IF;
  digest := encode(sha256(convert_to((_payload->'punches')::text, 'UTF8')), 'hex');

  FOR el IN SELECT e FROM jsonb_array_elements(_payload->'punches') WITH ORDINALITY a(e, o) ORDER BY o LOOP
    ord := ord + 1; reason := NULL; msg := NULL; t := NULL;
    cu := NULL; uu := NULL; v_code := NULL; v_dir := NULL; ts := NULL; dev := NULL;
    IF jsonb_typeof(el) <> 'object' THEN
      reason := 'invalid';
    ELSE
      cu := el->>'client_uuid'; uu := el->>'user_id'; v_code := el->>'code'; v_dir := el->>'direction'; ts := el->>'client_time';
      dev := CASE WHEN jsonb_typeof(el->'device') = 'string' THEN left(el->>'device', 60) END;
      IF jsonb_typeof(el->'client_uuid') IS DISTINCT FROM 'string' OR cu !~ uuid_re
         OR jsonb_typeof(el->'user_id') IS DISTINCT FROM 'string' OR uu !~ uuid_re
         OR jsonb_typeof(el->'code') IS DISTINCT FROM 'string' OR length(v_code) NOT BETWEEN 1 AND 40
         OR jsonb_typeof(el->'direction') IS DISTINCT FROM 'string' OR v_dir NOT IN ('IN', 'OUT')
         OR jsonb_typeof(el->'client_time') IS DISTINCT FROM 'string' OR ts !~ time_re THEN
        reason := 'invalid';
      ELSE
        BEGIN
          t := ts::timestamptz;
        EXCEPTION WHEN OTHERS THEN
          reason := 'invalid';
        END;
      END IF;
    END IF;

    IF reason IS NULL THEN
      IF cu = ANY (seen) THEN
        reason := 'duplicate_in_file';
      ELSE
        seen := seen || cu;
        IF NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = uu::uuid AND p.organization_id = org) THEN
          reason := 'unknown_account';
        ELSIF NOT EXISTS (SELECT 1 FROM public.absence_codes c WHERE c.code = v_code) THEN
          reason := 'unknown_code';
        ELSIF t > now() + make_interval(mins => (lim->>'future_tolerance_minutes')::int) THEN
          reason := 'future';
        ELSIF t < now() - make_interval(days => (lim->>'max_late_age_days')::int) THEN
          reason := 'too_old';
        ELSIF public.is_closed(uu::uuid, t) THEN
          reason := 'closed_month';
        ELSE
          SELECT p.user_id, p.code, p.direction, p.client_time INTO ex FROM public.punches p WHERE p.client_uuid = cu::uuid;
          IF FOUND THEN
            IF ex.user_id = uu::uuid AND ex.code = v_code AND ex.direction = v_dir AND ex.client_time = t THEN reason := 'already';
            ELSE reason := 'conflict'; END IF;
          END IF;
        END IF;
      END IF;
    END IF;

    IF reason IS NULL THEN
      n_ok := n_ok + 1;
      ok_rows := ok_rows || jsonb_build_object('o', ord, 'cu', cu, 'uu', uu, 'code', v_code, 'dir', v_dir, 't', t, 'dev', dev);
      IF NOT (uu::uuid = ANY (users)) THEN users := users || uu::uuid; END IF;
      t_min := least(coalesce(t_min, t), t); t_max := greatest(coalesce(t_max, t), t);
    ELSIF reason = 'already' THEN
      n_already := n_already + 1;
    ELSE
      n_rejected := n_rejected + 1;
      reasons := reasons || jsonb_build_object(reason, coalesce((reasons->>reason)::int, 0) + 1);
      IF jsonb_array_length(items) < (lim->>'max_report_items')::int THEN
        items := items || jsonb_build_object('n', ord, 'reason', reason, 'client_time', left(ts, 40), 'code', left(v_code, 40), 'direction', left(v_dir, 3));
      END IF;
    END IF;
  END LOOP;

  -- Rozpis po účtoch (osobné čísla): správca vidí, ktorých ľudí sa súbor týka. Súbor zo zariadenia zvyčajne patrí jednému účtu.
  SELECT coalesce(jsonb_agg(jsonb_build_object('sap_id', c.sap_id, 'count', c.cnt, 'from', c.t_min, 'to', c.t_max) ORDER BY c.sap_id), '[]'::jsonb)
    INTO by_acc
  FROM (SELECT p.sap_id, count(*) AS cnt, min((x->>'t')::timestamptz) AS t_min, max((x->>'t')::timestamptz) AS t_max
        FROM jsonb_array_elements(ok_rows) x JOIN public.profiles p ON p.id = (x->>'uu')::uuid
        GROUP BY p.id, p.sap_id ORDER BY p.sap_id LIMIT (lim->>'max_report_items')::int) c;

  IF NOT _dry_run THEN
    -- V poradí času zariadenia, aby reťaz každého účtu pokračovala v tom poradí, v akom razenia vznikli.
    FOR r IN SELECT (x->>'o')::int AS o, (x->>'cu')::uuid AS cu, (x->>'uu')::uuid AS uu, x->>'code' AS code, x->>'dir' AS dir,
                    (x->>'t')::timestamptz AS t, x->>'dev' AS dev
             FROM jsonb_array_elements(ok_rows) x ORDER BY (x->>'t')::timestamptz, x->>'cu' LOOP
      reason := NULL; msg := NULL;
      BEGIN
        INSERT INTO public.punches (client_uuid, user_id, code, direction, client_time, source, device)
        VALUES (r.cu, r.uu, r.code, r.dir, r.t, 'terminal', rtrim(left('neskoré: ' || coalesce(r.dev, ''), 60)))
        RETURNING device_verification INTO dv;
        IF dv IS DISTINCT FROM 'unverified' THEN
          RAISE EXCEPTION 'Razenie zo súboru by nebolo označené ako neoverené (%).', dv;
        END IF;
        n_inserted := n_inserted + 1;
      EXCEPTION
        WHEN unique_violation THEN reason := 'conflict';
        WHEN OTHERS THEN reason := 'refused'; msg := left(SQLERRM, 200);
      END;
      IF reason IS NOT NULL THEN
        n_rejected := n_rejected + 1;
        reasons := reasons || jsonb_build_object(reason, coalesce((reasons->>reason)::int, 0) + 1);
        IF jsonb_array_length(items) < (lim->>'max_report_items')::int THEN
          items := items || (jsonb_build_object('n', r.o, 'reason', reason, 'client_time', to_char(r.t, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                                                'code', r.code, 'direction', r.dir)
                             || CASE WHEN msg IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('message', msg) END);
        END IF;
      END IF;
    END LOOP;
    INSERT INTO public.audit_log (actor, action, target, details)
    VALUES (auth.uid(), 'punches.late_imported', org::text,
            jsonb_build_object('total', n, 'inserted', n_inserted, 'already', n_already, 'rejected', n_rejected, 'reasons', reasons,
                               'accounts', cardinality(users), 'from', t_min, 'to', t_max, 'digest', digest,
                               'origin', left(_payload->>'origin', 200), 'file_created_at', left(_payload->>'created_at', 40)));
  END IF;

  RETURN jsonb_build_object('dry_run', _dry_run, 'total', n, 'acceptable', n_ok, 'inserted', n_inserted, 'already', n_already,
                            'rejected', n_rejected, 'reasons', reasons, 'items', items, 'accounts', cardinality(users),
                            'from', t_min, 'to', t_max, 'digest', digest, 'by_account', by_acc);
END $$;
-- Práva. CREATE OR REPLACE ponecháva existujúce práva, napriek tomu sa nastavujú výslovne (prednastavené práva migračnej roly by dali
-- EXECUTE aj anonymnému používateľovi).
REVOKE ALL ON FUNCTION public.org_transfer_set_destination(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.org_transfer_set_notice(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.org_transfer_get_destination() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.late_punches_import(jsonb, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.punch_move_notice(uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_test_organization(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.org_transfer_set_destination(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.org_transfer_set_notice(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.org_transfer_get_destination() TO authenticated;
GRANT EXECUTE ON FUNCTION public.late_punches_import(jsonb, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_test_organization(text, text) TO authenticated;
-- Jediná funkcia pre neprihlásených (ako v 0019).
GRANT EXECUTE ON FUNCTION public.punch_move_notice(uuid[]) TO anon, authenticated;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA org_transfer FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN EXECUTE 'REVOKE ALL ON ALL FUNCTIONS IN SCHEMA org_transfer FROM anon'; END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN EXECUTE 'REVOKE ALL ON ALL FUNCTIONS IN SCHEMA org_transfer FROM authenticated'; END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN EXECUTE 'REVOKE ALL ON ALL FUNCTIONS IN SCHEMA org_transfer FROM service_role'; END IF;
END $$;

SELECT org_transfer.move_version() AS nainstalovane;
