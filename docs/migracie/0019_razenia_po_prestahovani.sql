-- 0019: razenia, ktoré ostali na zariadení po presťahovaní organizácie na iný server.
--
-- Problém: fronta razení terminálu (IndexedDB v prehliadači) nevie o prenose organizácie (migrácie 0016 a 0017). Počas exportu so zámkom
-- databáza razenie odmietne (SQLSTATE 55000) a terminál ho mlčky skúša znova. Po zrušení pôvodnej organizácie účty zaniknú, odoslanie
-- už nikdy neprejde a razenia ostanú len v prehliadači: zamestnanec si myslí, že razil, a nikto sa to nedozvie.
--
-- Táto migrácia dodáva databázovú časť riešenia (obrazovky sú v aplikácii, opis v docs/PRENOS-ORGANIZACIE.md):
--
--   A. OZNAM O PRESŤAHOVANÍ (zdrojový server)
--      * punch_move_notice(účty)  jediná funkcia volateľná BEZ prihlásenia (po zrušení organizácie účty neexistujú). Zariadenie pošle
--        id účtov, ktorých razenia má vo fronte, a dozvie sa, či sa ich organizácia práve prenáša („transferring“), alebo už bola
--        presťahovaná („moved“), prípadne na akú adresu. Pre ostatné účty nevráti nič.
--      * org_transfer_set_destination(adresa) / org_transfer_get_destination()  správca môže k rozpracovanému prenosu uložiť novú adresu
--        (nepovinné); terminály ju potom ukážu ľuďom.
--      * Oznam je PRE ORGANIZÁCIU, nie pre celý server: na jednom serveri je viac organizácií a oznam „server sa presťahoval“ by po
--        odsťahovaní jednej tvrdil terminálom všetkých ostatných, že sa presťahovali.
--      * Po zrušení organizácie po nej ostane len: jej id, id prenosu, čas, voliteľná adresa a SHA-256 odtlačky id jej účtov (podľa nich
--        zariadenie zistí, že „jeho“ účet sa presťahoval). Žiadne osobné čísla, mená, e-maily ani samotné id účtov.
--      * Stav sa vedie sám spúšťačom na tabuľke prenosov: potvrdenie prenosu kódom (org_transfer_confirm_and_delete) = „moved“, zrušenie
--        prenosu = oznam sa zmaže, nový export = starý oznam sa zmaže. Funkcie z migrácie 0016 sa NEMENIA.
--      * Ak sa organizácia neskôr vráti (import späť na tento server), jej účty tu znova existujú a oznam „moved“ sa pre ne prestane
--        vydávať sám (živý účet má prednosť pred starým oznamom).
--
--   B. NESKORÉ RAZENIA (cieľový server)
--      * late_punches_import(súbor, nanečisto)  správca nahrá súbor s razeniami, ktoré ostali na zariadení (šifrovaný súbor rozbalí
--        prehliadač, heslo sa na server neposiela). Predvolene je to SKÚŠKA: nič sa nezapíše, vráti sa prehľad.
--      * Súboru sa NEVERÍ (môže ho vyrobiť ktokoľvek, kto pozná formát):
--          - len správca, len do vlastnej organizácie; razenie cudzieho alebo neznámeho účtu sa odmietne (bez rozlíšenia, či účet existuje inde),
--          - opakované nahratie nič nezdvojí (client_uuid); to isté razenie s iným obsahom sa hlási ako konflikt a nezapíše sa,
--          - nie do uzavretého mesiaca, nie do budúcnosti (tolerancia 5 minút), nie staršie než 120 dní, len kód z číselníka,
--          - najviac 2 000 razení a 1,5 MB na jeden súbor,
--          - žiadny dynamický SQL, pevné search_path, hodnoty zo súboru idú len ako parametre.
--      * Razenia sa vkladajú BEŽNOU CESTOU (INSERT do punches so zdrojom „terminal“ a bez kľúča zariadenia): čas servera, odchýlku a hash
--        reťaz doplní spúšťač punches_chain ako pri každom razení a razenie je NEOVERENÉ (čas pochádza zo zariadenia, nie zo servera),
--        takže ho musí potvrdiť vedúci. Funkcia si po vložení overí, že razenie naozaj ostalo neoverené, inak ho nezapíše.
--        Vzorec hash reťaze sa nemení, kľúč zariadenia sa zo súboru nikdy neberie.
--      * Každé ostré nahratie zapíše jeden záznam do audit_log (počty, odtlačok obsahu), bez jednotlivých razení.
--
-- Tabuľky punches a profiles sa NEMENIA (žiadny nový stĺpec, žiadna nová hodnota); export razení pre Access ani kontrakt sa nemenia.
-- Nová tabuľka je v schéme org_transfer (REST API ju nevidí, neprenáša sa s organizáciou a org_transfer.spec() ju nepotrebuje).
--
-- Predpoklady: migrácia 0016 (schéma org_transfer, tabuľka prenosov). Súbor je opakovateľný. Pred spustením urobte zálohu:
-- docs/ZALOHA-DATABAZY.md. Návrat: docs/migracie/0019_spat_zachranny.sql (spúšťa sa PRED 0017_spat a 0016_spat).

DO $$ BEGIN
  IF to_regnamespace('org_transfer') IS NULL OR to_regclass('org_transfer.transfers') IS NULL
     OR to_regprocedure('org_transfer.caller_org()') IS NULL OR to_regprocedure('public.punches_transfer_lock()') IS NULL THEN
    RAISE EXCEPTION 'Najprv spustite migráciu 0016 (docs/migracie/0016_prenos_organizacie_export.sql).';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'punches' AND column_name = 'device_verification') THEN
    RAISE EXCEPTION 'Chýba stĺpec public.punches.device_verification (overovanie zariadení). Nič sa nezmenilo.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION org_transfer.move_version() RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT 'org_move 1 (migrácia 0019)' $$;

-- Obmedzenia: počet účtov v jednom dopyte na oznam; veľkosť, počet a vek razení v súbore s neskorými razeniami.
CREATE OR REPLACE FUNCTION org_transfer.move_limits() RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('max_notice_users', 50, 'max_late_punches', 2000, 'max_late_chars', 1500000,
                            'max_late_age_days', 120, 'future_tolerance_minutes', 5, 'max_report_items', 100)
$$;

-- Nová adresa: len http(s), meno hostiteľa, voliteľný port a cesta. Žiadne meno a heslo, dopyt ani kotva (adresa sa ukazuje ľuďom
-- a číta sa bez prihlásenia, preto nesmie niesť nič okrem miesta).
CREATE OR REPLACE FUNCTION org_transfer.valid_destination(_url text) RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT _url IS NOT NULL AND length(_url) BETWEEN 10 AND 200
     AND _url ~ '^https?://[A-Za-z0-9]([A-Za-z0-9.-]{0,150}[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]{0,100})?$'
$$;

CREATE OR REPLACE FUNCTION org_transfer.user_hash(_user uuid) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT encode(sha256(convert_to(_user::text, 'UTF8')), 'hex')
$$;

-- -----------------------------------------------------------------------------------------------------
-- A. Oznam o presťahovaní
-- -----------------------------------------------------------------------------------------------------
-- announced = správca k rozpracovanému prenosu uložil novú adresu; moved = prenos bol potvrdený a organizácia tu zanikla.
CREATE TABLE IF NOT EXISTS org_transfer.move_notices (
  organization_id uuid PRIMARY KEY,
  transfer_id uuid NOT NULL,
  state text NOT NULL CHECK (state IN ('announced', 'moved')),
  new_url text CHECK (new_url IS NULL OR org_transfer.valid_destination(new_url)),
  member_hashes text[] NOT NULL DEFAULT '{}',
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS move_notices_members ON org_transfer.move_notices USING gin (member_hashes);
ALTER TABLE org_transfer.move_notices ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON org_transfer.move_notices FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN EXECUTE 'REVOKE ALL ON org_transfer.move_notices FROM anon'; END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN EXECUTE 'REVOKE ALL ON org_transfer.move_notices FROM authenticated'; END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN EXECUTE 'REVOKE ALL ON org_transfer.move_notices FROM service_role'; END IF;
END $$;
COMMENT ON TABLE org_transfer.move_notices IS 'Oznam o presťahovaní organizácie (migrácia 0019). Po zrušení organizácie drží len odtlačky id jej účtov, nie údaje.';

-- Stav oznamu sleduje stav prenosu. Beží v tej istej transakcii ako zmena prenosu: ak zrušenie organizácie zlyhá, vráti sa aj oznam.
CREATE OR REPLACE FUNCTION org_transfer.transfers_move_notice() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- Nový export: organizácia je tu živá, starý oznam (aj „moved“ po skoršom odsťahovaní a návrate) už neplatí.
    DELETE FROM org_transfer.move_notices m WHERE m.organization_id = NEW.organization_id;
  ELSIF NEW.state = 'confirmed' AND OLD.state IS DISTINCT FROM 'confirmed' THEN
    INSERT INTO org_transfer.move_notices AS m (organization_id, transfer_id, state, new_url, member_hashes, updated_at)
    VALUES (NEW.organization_id, NEW.id, 'moved', NULL,
            ARRAY(SELECT org_transfer.user_hash(p.id) FROM public.profiles p WHERE p.organization_id = NEW.organization_id), now())
    ON CONFLICT (organization_id) DO UPDATE
      SET state = 'moved',
          new_url = CASE WHEN m.transfer_id = EXCLUDED.transfer_id THEN m.new_url ELSE NULL END,
          transfer_id = EXCLUDED.transfer_id, member_hashes = EXCLUDED.member_hashes, updated_at = now();
  ELSIF NEW.state = 'cancelled' AND OLD.state IS DISTINCT FROM 'cancelled' THEN
    DELETE FROM org_transfer.move_notices m WHERE m.transfer_id = NEW.id AND m.state = 'announced';
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS transfers_move_notice ON org_transfer.transfers;
CREATE TRIGGER transfers_move_notice AFTER INSERT OR UPDATE OF state ON org_transfer.transfers
  FOR EACH ROW EXECUTE FUNCTION org_transfer.transfers_move_notice();

-- Nová adresa k rozpracovanému prenosu (nepovinná). Prázdna hodnota adresu zmaže.
CREATE OR REPLACE FUNCTION public.org_transfer_set_destination(_url text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE org uuid; t org_transfer.transfers; url text := nullif(btrim(coalesce(_url, '')), '');
BEGIN
  org := org_transfer.caller_org();
  SELECT * INTO t FROM org_transfer.transfers x WHERE x.organization_id = org AND x.state IN ('ready', 'exported') FOR UPDATE;
  IF t.id IS NULL THEN RAISE EXCEPTION 'Organizácia nemá rozpracovaný prenos. Novú adresu možno uložiť až po exporte.'; END IF;
  IF url IS NULL THEN
    DELETE FROM org_transfer.move_notices m WHERE m.organization_id = org AND m.state = 'announced';
  ELSE
    url := regexp_replace(url, '/+$', '');
    IF NOT org_transfer.valid_destination(url) THEN
      RAISE EXCEPTION 'Adresa nie je platná. Zadajte ju v tvare https://nazov.servera (bez mena, hesla a otáznika).';
    END IF;
    INSERT INTO org_transfer.move_notices AS m (organization_id, transfer_id, state, new_url)
    VALUES (org, t.id, 'announced', url)
    ON CONFLICT (organization_id) DO UPDATE SET transfer_id = EXCLUDED.transfer_id, state = 'announced', new_url = EXCLUDED.new_url,
                                                member_hashes = '{}', updated_at = now();
  END IF;
  INSERT INTO public.audit_log (actor, action, target, details)
  VALUES (auth.uid(), 'organization.transfer_destination', org::text, jsonb_build_object('transfer', t.id, 'url', url));
  RETURN jsonb_build_object('transfer_id', t.id, 'url', url);
END $$;

CREATE OR REPLACE FUNCTION public.org_transfer_get_destination() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE org uuid; res jsonb;
BEGIN
  org := org_transfer.caller_org();
  SELECT jsonb_build_object('transfer_id', t.id, 'url', m.new_url) INTO res
  FROM org_transfer.transfers t LEFT JOIN org_transfer.move_notices m ON m.organization_id = t.organization_id AND m.transfer_id = t.id
  WHERE t.organization_id = org AND t.state IN ('ready', 'exported');
  RETURN coalesce(res, jsonb_build_object('transfer_id', NULL, 'url', NULL));
END $$;

-- Oznam pre zariadenie. Volá sa bez prihlásenia; vracia len stav a adresu pre účty, ktorých organizácia sa prenáša alebo presťahovala.
-- „transferring“ má rovnakú podmienku ako zámok razení (punches_transfer_lock v migrácii 0016).
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
        (SELECT jsonb_build_object('state', 'transferring', 'url',
                  (SELECT m.new_url FROM org_transfer.move_notices m WHERE m.organization_id = t.organization_id AND m.transfer_id = t.id))
         FROM org_transfer.transfers t JOIN public.profiles p ON p.organization_id = t.organization_id
         WHERE p.id = u.id AND t.locked
           AND (t.state = 'exported' OR (t.state = 'ready' AND t.started_at > now() - interval '2 hours'))
         LIMIT 1)
      ELSE
        (SELECT jsonb_build_object('state', 'moved', 'url', m.new_url, 'since', m.updated_at)
         FROM org_transfer.move_notices m
         WHERE m.state = 'moved' AND m.member_hashes @> ARRAY[org_transfer.user_hash(u.id)]
         ORDER BY m.updated_at DESC LIMIT 1)
    END AS j) x
  WHERE x.j IS NOT NULL;
  RETURN jsonb_build_object('version', 1, 'users', res);
END $$;

-- -----------------------------------------------------------------------------------------------------
-- B. Neskoré razenia: súbor zo zariadenia nahráva správca na cieľovom serveri
-- -----------------------------------------------------------------------------------------------------
-- _payload = {"format": "dochs-late-punches", "version": 1, "punches": [{client_uuid, user_id, code, direction, client_time, device}], ...}
-- Dôvody odmietnutia jedného razenia (kľúč v prehľade): invalid, duplicate_in_file, unknown_account, unknown_code, future, too_old,
-- closed_month, conflict, refused. „already“ = razenie už na serveri je (nie je to chyba).
CREATE OR REPLACE FUNCTION public.late_punches_import(_payload jsonb, _dry_run boolean DEFAULT true) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog SET timezone = 'UTC' AS $$
DECLARE
  org uuid; lim jsonb := org_transfer.move_limits(); n int; el jsonb; ord int := 0;
  cu text; uu text; v_code text; v_dir text; ts text; dev text; t timestamptz; reason text; msg text;
  seen text[] := '{}'; ex record; dv text;
  ok_rows jsonb := '[]'; items jsonb := '[]'; reasons jsonb := '{}';
  n_ok int := 0; n_already int := 0; n_rejected int := 0; n_inserted int := 0;
  users uuid[] := '{}'; t_min timestamptz; t_max timestamptz; digest text; r record;
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

  IF NOT _dry_run THEN
    -- V poradí času zariadenia, aby reťaz každého účtu pokračovala v tom poradí, v akom razenia vznikli.
    FOR r IN SELECT (x->>'o')::int AS o, (x->>'cu')::uuid AS cu, (x->>'uu')::uuid AS uu, x->>'code' AS code, x->>'dir' AS dir,
                    (x->>'t')::timestamptz AS t, x->>'dev' AS dev
             FROM jsonb_array_elements(ok_rows) x ORDER BY (x->>'t')::timestamptz, x->>'cu' LOOP
      reason := NULL; msg := NULL;
      BEGIN
        INSERT INTO public.punches (client_uuid, user_id, code, direction, client_time, source, device)
        VALUES (r.cu, r.uu, r.code, r.dir, r.t, 'terminal', r.dev)
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
                            'from', t_min, 'to', t_max, 'digest', digest);
END $$;

-- Práva. Prednastavené práva migračnej roly by dali EXECUTE aj anonymnému používateľovi, preto sa odoberajú výslovne.
REVOKE ALL ON FUNCTION public.org_transfer_set_destination(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.org_transfer_get_destination() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.late_punches_import(jsonb, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.punch_move_notice(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.org_transfer_set_destination(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.org_transfer_get_destination() TO authenticated;
GRANT EXECUTE ON FUNCTION public.late_punches_import(jsonb, boolean) TO authenticated;
-- Jediná funkcia pre neprihlásených: po zrušení organizácie sa zariadenie prihlásiť nevie.
GRANT EXECUTE ON FUNCTION public.punch_move_notice(uuid[]) TO anon, authenticated;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA org_transfer FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN EXECUTE 'REVOKE ALL ON ALL FUNCTIONS IN SCHEMA org_transfer FROM anon'; END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN EXECUTE 'REVOKE ALL ON ALL FUNCTIONS IN SCHEMA org_transfer FROM authenticated'; END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN EXECUTE 'REVOKE ALL ON ALL FUNCTIONS IN SCHEMA org_transfer FROM service_role'; END IF;
END $$;

SELECT org_transfer.move_version() AS nainstalovane;
