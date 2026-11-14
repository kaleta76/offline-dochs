-- 0017: prenos celej organizácie na iný server – strana IMPORTU (databáza cieľového servera).
--
-- Správca na cieľovom serveri najprv zaregistruje novú organizáciu (vznikne čerstvá prázdna organizácia s jediným účtom). V skrytej karte
-- Servis potom vyberie súbor z exportu (migrácia 0016), zadá heslo a prehliadač súbor dešifruje a po častiach nahrá do databázy. Po
-- kontrole a výslovnom potvrdení databáza čerstvú prázdnu organizáciu (aj s účtom správcu) NAHRADÍ organizáciou zo súboru s pôvodnými
-- identifikátormi: ostáva kód organizácie, osobné čísla, PIN-y aj heslá. Nakoniec vypíše KÓD POTVRDENIA PRENOSU (XXXX-XXXX), ktorým sa
-- na pôvodnom serveri odomkne zrušenie pôvodnej organizácie.
--
-- Ako to ide (všetko volá prihlásený SPRÁVCA čerstvej prázdnej organizácie):
--   1. org_import_status()                 či je organizácia na import spôsobilá, rozpracovaný import a kód posledného importu,
--   2. org_import_begin(hlavička)          založí import a skontroluje hlavičku súboru voči tejto databáze,
--   3. org_import_chunk(import, tabuľka, poradie, riadky)   po častiach uloží riadky do odkladacej tabuľky (nič v aplikácii sa nemení),
--   4. org_import_check(import)            skontroluje celý nahraný súbor (úplnosť, vlastníctvo riadkov, účty) a cieľovú databázu,
--   5. org_import_commit(import, názov)    v JEDNEJ transakcii zmaže čerstvú organizáciu, vloží organizáciu zo súboru, overí ju
--                                          (počty a odtlačky každej tabuľky, hash reťaz a poradie razení) a vráti kód potvrdenia,
--   6. org_import_cancel()                 zahodí rozpracovaný import (nahrané riadky).
--
-- Bezpečnosť (súbor môže vyrobiť aj niekto nedôveryhodný, preto sa mu neverí):
--   * importovať smie len správca organizácie, v ktorej je jediným účtom a ktorá nemá razenia, opravy, uzávierky ani plán z Accessu;
--     pôvodnú organizáciu nahradiť nejde. Organizácia s údajmi sa nikdy neprepíše,
--   * súbor nesmie siahať mimo svojej organizácie: každý riadok musí patriť organizácii zo súboru a každý odkaz (účet, nadriadený,
--     zariadenie, razenie) musí viesť na riadok z toho istého súboru. Zoznam odkazov je v org_transfer.import_refs(); stĺpec typu uuid
--     alebo s cudzím kľúčom, ktorý v zozname chýba, import zastaví (po novej migrácii ho treba doplniť),
--   * prihlasovacie účty sa nevkladajú tak, ako sú v súbore: rola a aud sú vždy „authenticated“ (rola z účtu ide do prístupového tokenu,
--     „service_role“ by obišla všetky pravidlá), žiadny super admin, SSO ani telefón, tokeny na obnovu sa nulujú, v app_metadata sú
--     povolené len známe kľúče (org_transfer.import_app_meta_keys()), identity len typu e-mail,
--   * identifikátory zo súboru nesmú na cieli existovať (import nič neprepisuje, len vkladá); čísla razení sa zachovajú, len ak sa
--     s ničím nezrazia a nie sú neprimerane vysoké, inak sa prečíslujú v rovnakom poradí (sekvencia sa súborom nedá „vystreliť“),
--   * názvy tabuliek a stĺpcov v príkazoch pochádzajú len zo zoznamu org_transfer.spec() a z katalógu databázy, nikdy zo súboru,
--   * funkcie bežia s právami vlastníka migrácie, každá najprv overí prihlásenie a rolu správcu; odkladacie tabuľky sú v schéme
--     org_transfer, ktorú REST API nevidí; veľkosť častí aj celého importu je obmedzená (org_transfer.import_limits()).
-- Súbor je dôveryhodný len pre VLASTNÉ údaje organizácie (razenia, hash reťaz, roly vo vnútri organizácie): kto vie založiť organizáciu,
-- vie do nej cez import vložiť, čo chce, ale nič mimo nej.
--
-- Počas kroku 5 sú na pár sekúnd vypnuté spúšťače aplikácie (reťaz hashov, audit, zakladanie účtov), preto ostatné organizácie v tej
-- chvíli so zápisom čakajú (terminál razenie nezahodí, skúsi znova). Väčší import robte mimo špičky.
-- Limit databázy ~8 s na príkaz: kroky 4 a 5 majú nastavený dlhší limit (120 s), ktorý PostgREST 12 a novší rešpektuje; kde ho
-- nerešpektuje, prejde tlačidlom organizácia približne do 100 000 razení a pre väčšiu ostáva operátorský postup.
--
-- Predpoklady: migrácia 0016 (spoločné funkcie org_transfer). Súbor je opakovateľný. Pred spustením urobte zálohu: docs/ZALOHA-DATABAZY.md.
-- Návrat: docs/migracie/0017_spat_zachranny.sql (spúšťa sa PRED 0016_spat_zachranny.sql).
-- Tabuľky punches a profiles sa nemenia (import do nich len vkladá riadky zo súboru); export razení pre Access sa nemení.

DO $$ BEGIN
  IF to_regnamespace('org_transfer') IS NULL OR to_regclass('org_transfer.transfers') IS NULL
     OR NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'org_transfer' AND p.proname IN ('receipt', 'fp_live', 'caller_org', 'spec')
                    GROUP BY n.nspname HAVING count(DISTINCT p.proname) = 4) THEN
    RAISE EXCEPTION 'Najprv spustite migráciu 0016 (docs/migracie/0016_prenos_organizacie_export.sql).';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION org_transfer.import_version() RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT 'org_import 1 (migrácia 0017)' $$;

-- Obmedzenia nahrávania (jedna časť, celý import, všetky rozpracované importy spolu) a číslovania razení.
CREATE OR REPLACE FUNCTION org_transfer.import_limits() RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('max_chunk_rows', 5000, 'max_chunk_chars', 6000000, 'max_meta_chars', 200000,
                            'max_total_rows', 1500000, 'max_staged_rows', 4000000, 'stale_hours', 24, 'keep_id_slack', 100000000)
$$;


-- ===== Spoločné funkcie (rovnaké ako v privátnom balíku 0015) =====

-- -----------------------------------------------------------------------------------------------------
-- Kontrola prostredia (práva a štruktúra). Používa ju aj import. Stav: OK / POZOR / CHYBA.
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION org_transfer.check_environment()
RETURNS TABLE(kontrola text, stav text, detail text)
LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $fn$
DECLARE r record; list text; seqs text[] := ARRAY[pg_get_serial_sequence('public.punches', 'id'), pg_get_serial_sequence('public.audit_log', 'id')];
        s text; bypass boolean; sup boolean;
BEGIN
  SELECT rolsuper, rolbypassrls INTO sup, bypass FROM pg_roles WHERE rolname = current_user;
  kontrola := 'Rola'; stav := 'OK'; detail := format('%s (superuser: %s, obchádza RLS: %s)', current_user, sup, bypass); RETURN NEXT;

  -- 1. potrebné tabuľky
  SELECT string_agg(v.rel, ', ') INTO list FROM org_transfer.spec() v WHERE to_regclass(v.rel) IS NULL;
  kontrola := 'Tabuľky aplikácie'; IF list IS NULL THEN stav := 'OK'; detail := 'všetky prenášané tabuľky existujú'; ELSE stav := 'CHYBA'; detail := 'chýbajú: ' || list || ' (iná verzia schémy?)'; END IF; RETURN NEXT;
  SELECT string_agg(g, ', ') INTO list FROM unnest(org_transfer.global_tables()) g WHERE to_regclass('public.' || g) IS NULL;
  kontrola := 'Spoločné číselníky'; IF list IS NULL THEN stav := 'OK'; detail := 'absence_codes, settings, holidays existujú'; ELSE stav := 'CHYBA'; detail := 'chýbajú: ' || list; END IF; RETURN NEXT;
  list := array_to_string(org_transfer.uncovered_tables(), ', ');
  kontrola := 'Tabuľky, ktoré prenos nepozná'; IF list = '' THEN stav := 'OK'; detail := 'žiadne'; ELSE stav := 'POZOR'; detail := 'v databáze sú tabuľky, ktoré sa neprenášajú: ' || list || ' (doplniť do org_transfer.spec())'; END IF; RETURN NEXT;

  -- 2. práva na prihlasovacie účty
  list := NULL;
  IF to_regclass('auth.users') IS NOT NULL AND to_regclass('auth.identities') IS NOT NULL THEN
    SELECT string_agg(p.t || ' ' || p.pr, ', ') INTO list
    FROM (VALUES ('auth.users','INSERT'),('auth.users','DELETE'),('auth.users','SELECT'),('auth.identities','INSERT'),('auth.identities','DELETE'),('auth.identities','SELECT')) p(t, pr)
    WHERE NOT has_table_privilege(p.t, p.pr);
    kontrola := 'Práva na auth.users a auth.identities';
    IF list IS NULL THEN stav := 'OK'; detail := 'SELECT, INSERT, DELETE'; ELSE stav := 'CHYBA'; detail := 'chýba právo: ' || list; END IF; RETURN NEXT;
  ELSE
    kontrola := 'Práva na auth.users a auth.identities'; stav := 'CHYBA'; detail := 'tabuľky schémy auth neexistujú'; RETURN NEXT;
  END IF;

  -- 3. spúšťače na tabuľkách aplikácie sa pri importe dočasne vypínajú: treba byť vlastníkom tabuľky
  SELECT string_agg(DISTINCT c.relname::text, ', ') INTO list
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE NOT t.tgisinternal AND n.nspname = 'public' AND ('public.' || c.relname) IN (SELECT rel FROM org_transfer.spec())
    AND NOT pg_has_role(current_user, c.relowner, 'USAGE');
  kontrola := 'Vlastníctvo tabuliek so spúšťačmi'; IF list IS NULL THEN stav := 'OK'; detail := 'môžem dočasne vypnúť spúšťače'; ELSE stav := 'CHYBA'; detail := 'nie ste vlastníkom: ' || list; END IF; RETURN NEXT;

  -- 4. spúšťače na auth.users / auth.identities: funkcie z public sa dočasne nahrádzajú prázdnymi (to vytvára účty bez zásahu pri vkladaní)
  list := NULL;
  SELECT string_agg(pn.nspname || '.' || p.proname || CASE WHEN NOT pg_has_role(current_user, p.proowner, 'USAGE') THEN ' (nie ste vlastník)'
                                                       WHEN l.lanname <> 'plpgsql' THEN ' (jazyk ' || l.lanname || ')' END, ', ')
    INTO list
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace cn ON cn.oid = c.relnamespace
       JOIN pg_proc p ON p.oid = t.tgfoid JOIN pg_namespace pn ON pn.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang
  WHERE NOT t.tgisinternal AND t.tgenabled <> 'D' AND cn.nspname = 'auth' AND c.relname IN ('users', 'identities')
    AND (NOT pg_has_role(current_user, p.proowner, 'USAGE') OR l.lanname <> 'plpgsql');
  kontrola := 'Spúšťače na auth.users'; IF list IS NULL THEN stav := 'OK'; detail := 'funkcie spúšťačov môžem dočasne nahradiť'; ELSE stav := 'CHYBA'; detail := 'nedá sa obísť: ' || list; END IF; RETURN NEXT;

  -- 5. zabezpečenie na úrovni riadkov
  IF NOT coalesce(sup, false) AND NOT coalesce(bypass, false) THEN
    SELECT string_agg(c.relname::text, ', ') INTO list
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND ('public.' || c.relname) IN (SELECT rel FROM org_transfer.spec())
      AND c.relrowsecurity AND (c.relforcerowsecurity OR NOT pg_has_role(current_user, c.relowner, 'USAGE'));
    kontrola := 'Zabezpečenie riadkov (RLS)'; IF list IS NULL THEN stav := 'OK'; detail := 'vlastník tabuliek RLS obchádza'; ELSE stav := 'CHYBA'; detail := 'RLS by obmedzilo import v tabuľkách: ' || list; END IF; RETURN NEXT;
  END IF;

  -- 6. sekvencie
  list := NULL;
  FOREACH s IN ARRAY seqs LOOP
    IF s IS NOT NULL AND NOT (has_sequence_privilege(s, 'UPDATE') AND has_sequence_privilege(s, 'SELECT')) THEN list := coalesce(list || ', ', '') || s; END IF;
  END LOOP;
  kontrola := 'Sekvencie (id pečiatok a auditu)'; IF list IS NULL THEN stav := 'OK'; detail := 'môžem ich posunúť'; ELSE stav := 'CHYBA'; detail := 'chýba právo na: ' || list; END IF; RETURN NEXT;

  -- 7. iné spúšťače na auth tabuľkách (nie z public) sa neobchádzajú
  SELECT string_agg(t.tgname || ' (' || pn.nspname || '.' || p.proname || ')', ', ') INTO list
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace cn ON cn.oid = c.relnamespace
       JOIN pg_proc p ON p.oid = t.tgfoid JOIN pg_namespace pn ON pn.oid = p.pronamespace
  WHERE NOT t.tgisinternal AND t.tgenabled <> 'D' AND cn.nspname = 'auth' AND c.relname IN ('users', 'identities') AND pn.nspname <> 'public';
  kontrola := 'Cudzie spúšťače na auth'; IF list IS NULL THEN stav := 'OK'; detail := 'žiadne'; ELSE stav := 'POZOR'; detail := 'budú pri vkladaní účtov bežať: ' || list; END IF; RETURN NEXT;

  -- 8. zvyšok po prerušenom importe
  SELECT string_agg(pn.nspname || '.' || p.proname, ', ') INTO list
  FROM pg_proc p JOIN pg_namespace pn ON pn.oid = p.pronamespace WHERE p.prosrc LIKE '%org_transfer:noop%' AND pn.nspname <> 'org_transfer';
  kontrola := 'Prázdne nahradené funkcie'; IF list IS NULL THEN stav := 'OK'; detail := 'žiadne'; ELSE stav := 'CHYBA'; detail := 'funkcia zostala nahradená prázdnou: ' || list || ' (obnoviť pôvodnú definíciu)'; END IF; RETURN NEXT;
  SELECT string_agg(c.relname || '.' || t.tgname, ', ') INTO list
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE NOT t.tgisinternal AND t.tgenabled = 'D' AND n.nspname = 'public';
  kontrola := 'Vypnuté spúšťače v public'; IF list IS NULL THEN stav := 'OK'; detail := 'žiadne'; ELSE stav := 'POZOR'; detail := 'vypnuté: ' || list; END IF; RETURN NEXT;
END $fn$;

-- Dočasné vypnutie spúšťačov. Platí len v rámci tejto transakcie: pri chybe sa všetko vráti samo.
--   * spúšťače aplikácie (reťaz hashov, ochrany, audit) by prepísali alebo zdvojili údaje, ktoré prenášame hotové
--   * spúšťač na auth.users, ktorý pri vložení účtu vytvára organizáciu/profil, sa obchádza prázdnou funkciou (po importe sa vráti pôvodná)
CREATE OR REPLACE FUNCTION org_transfer.suspend_triggers() RETURNS jsonb
LANGUAGE plpgsql SET search_path = pg_catalog AS $fn$
DECLARE r record; trg jsonb := '[]'; fns jsonb := '[]';
BEGIN
  FOR r IN
    SELECT n.nspname AS sch, c.relname AS rel, t.tgname, t.tgenabled
    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE NOT t.tgisinternal AND t.tgenabled <> 'D' AND n.nspname = 'public' AND ('public.' || c.relname) IN (SELECT rel FROM org_transfer.spec())
    ORDER BY c.relname, t.tgname
  LOOP
    EXECUTE format('ALTER TABLE %I.%I DISABLE TRIGGER %I', r.sch, r.rel, r.tgname);
    trg := trg || jsonb_build_array(jsonb_build_object('sch', r.sch, 'rel', r.rel, 'name', r.tgname, 'en', r.tgenabled));
  END LOOP;
  FOR r IN
    SELECT DISTINCT p.oid AS fn, pn.nspname AS fsch, p.proname AS fname, pg_get_functiondef(p.oid) AS def
    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace cn ON cn.oid = c.relnamespace
         JOIN pg_proc p ON p.oid = t.tgfoid JOIN pg_namespace pn ON pn.oid = p.pronamespace
    WHERE NOT t.tgisinternal AND t.tgenabled <> 'D' AND cn.nspname = 'auth' AND c.relname IN ('users', 'identities') AND pn.nspname = 'public'
  LOOP
    fns := fns || jsonb_build_array(jsonb_build_object('def', r.def));
    EXECUTE format('CREATE OR REPLACE FUNCTION %I.%I() RETURNS trigger LANGUAGE plpgsql AS $b$ BEGIN /* org_transfer:noop */ RETURN NEW; END $b$', r.fsch, r.fname);
  END LOOP;
  RETURN jsonb_build_object('triggers', trg, 'functions', fns);
END $fn$;

CREATE OR REPLACE FUNCTION org_transfer.resume_triggers(_state jsonb) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog AS $fn$
DECLARE e jsonb;
BEGIN
  FOR e IN SELECT * FROM jsonb_array_elements(_state->'functions') LOOP
    EXECUTE e->>'def';
  END LOOP;
  FOR e IN SELECT * FROM jsonb_array_elements(_state->'triggers') LOOP
    EXECUTE format('ALTER TABLE %I.%I %s TRIGGER %I', e->>'sch', e->>'rel',
                   CASE e->>'en' WHEN 'A' THEN 'ENABLE ALWAYS' WHEN 'R' THEN 'ENABLE REPLICA' ELSE 'ENABLE' END, e->>'name');
  END LOOP;
END $fn$;


-- ===== Import z aplikácie =====

-- -----------------------------------------------------------------------------------------------------
-- Odkazy v prenášaných tabuľkách. Každý stĺpec typu uuid a každý stĺpec s cudzím kľúčom na prenášanú tabuľku tu MUSÍ byť:
--   own        vlastný identifikátor riadku (nesmie na cieli existovať; stráži primárny alebo jedinečný kľúč)
--   org        musí sa rovnať id organizácie zo súboru
--   owner      účet, ktorému riadok patrí: povinný a musí byť medzi účtami zo súboru
--   user       odkaz na účet: prázdny alebo účet zo súboru
--   user_loose odkaz na účet bez cudzieho kľúča (kto rozhodol, schválil…): prázdny, účet zo súboru, alebo účet, ktorý už neexistuje
--              (na cieli taký účet nesmie byť)
--   device     prázdny alebo zariadenie zo súboru          punch   prázdny alebo razenie zo súboru
--   void       prázdny alebo žiadosť o zneplatnenie zo súboru
-- -----------------------------------------------------------------------------------------------------
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

-- Stĺpce, ktoré by mali byť v import_refs() a nie sú (po migrácii, ktorá pridala odkaz). Kým sú, import sa odmietne.
CREATE OR REPLACE FUNCTION org_transfer.import_unclassified() RETURNS text[]
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT coalesce(array_agg(s.rel || '.' || a.attname ORDER BY s.rel, a.attname), ARRAY[]::text[])
  FROM org_transfer.spec() s JOIN pg_attribute a ON a.attrelid = to_regclass(s.rel) AND a.attnum > 0 AND NOT a.attisdropped
  WHERE s.rel LIKE 'public.%'
    AND (a.atttypid IN ('uuid'::regtype, 'uuid[]'::regtype)
         OR EXISTS (SELECT 1 FROM pg_constraint k
                    WHERE k.contype = 'f' AND k.conrelid = a.attrelid AND a.attnum = ANY (k.conkey)
                      AND (k.confrelid = to_regclass('auth.users') OR k.confrelid IN (SELECT to_regclass(x.rel) FROM org_transfer.spec() x))))
    AND NOT EXISTS (SELECT 1 FROM org_transfer.import_refs() f WHERE f.rel = s.rel AND f.col = a.attname::text)
$$;

-- Kľúče, ktoré smie mať app_metadata prihlasovacieho účtu zo súboru (provider/providers píše prihlasovací server, ostatné aplikácia:
-- jednorazový PIN, obnovovací kód a počítadlá neúspešných pokusov, src/lib/accounts-core.ts). Iný kľúč import zastaví: app_metadata
-- ide do prístupového tokenu a nový kľúč by mohol niesť oprávnenie. Po pridaní kľúča do aplikácie ho treba doplniť aj sem.
CREATE OR REPLACE FUNCTION org_transfer.import_app_meta_keys() RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['provider', 'providers', 'onboarding_pending', 'pin_hash', 'pin_salt', 'pin_expires', 'pin_attempts',
               'recovery_hash', 'recovery_salt', 'login_fail', 'login_fail_at', 'recovery_fail', 'recovery_fail_at']
$$;

-- -----------------------------------------------------------------------------------------------------
-- Stav importov a odkladacia tabuľka riadkov (neprenášajú sa; klient k nim nemá prístup)
-- -----------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS org_transfer.imports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target_org uuid NOT NULL,          -- čerstvá prázdna organizácia, ktorú import nahradí
  target_name text NOT NULL,
  started_by uuid NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  state text NOT NULL CHECK (state IN ('uploading', 'checked', 'done', 'cancelled')),
  org_id uuid NOT NULL,              -- organizácia zo súboru
  org_name text NOT NULL,
  total_rows bigint NOT NULL,
  meta jsonb NOT NULL,
  loose_ids uuid[] NOT NULL DEFAULT '{}',
  summary jsonb,
  checked_at timestamptz,
  finished_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS imports_one_active ON org_transfer.imports (target_org) WHERE state IN ('uploading', 'checked');
CREATE INDEX IF NOT EXISTS imports_org_done ON org_transfer.imports (org_id) WHERE state = 'done';
CREATE TABLE IF NOT EXISTS org_transfer.import_rows (
  import_id uuid NOT NULL REFERENCES org_transfer.imports (id) ON DELETE CASCADE,
  rel text NOT NULL,
  seq integer NOT NULL,              -- poradie časti
  n integer NOT NULL,                -- poradie riadku v časti
  k text,                            -- hodnota kľúča riadku (stĺpec key_col zo spec(), inak id), na kontrolu odkazov
  data jsonb NOT NULL,
  PRIMARY KEY (import_id, rel, seq, n)
);
CREATE INDEX IF NOT EXISTS import_rows_key ON org_transfer.import_rows (import_id, rel, k);
ALTER TABLE org_transfer.imports ENABLE ROW LEVEL SECURITY;
ALTER TABLE org_transfer.import_rows ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON org_transfer.imports, org_transfer.import_rows FROM PUBLIC;
DO $$ DECLARE r text; BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON org_transfer.imports, org_transfer.import_rows FROM %I', r);
    END IF;
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------------------------------
-- Spôsobilosť: import smie nahradiť len čerstvú prázdnu organizáciu, v ktorej je volajúci jediným účtom.
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION org_transfer.import_eligibility(_org uuid, _uid uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $fn$
DECLARE reasons text[] := '{}'; members uuid[]; o record; r record; n bigint; devices bigint;
BEGIN
  SELECT * INTO o FROM public.organizations WHERE id = _org;
  IF o.id IS NULL THEN RETURN jsonb_build_object('eligible', false, 'reasons', jsonb_build_array('Organizácia neexistuje.')); END IF;
  members := ARRAY(SELECT id FROM public.profiles WHERE organization_id = _org);
  IF _org = '00000000-0000-4000-8000-000000000001' THEN reasons := reasons || 'Pôvodnú organizáciu nemožno nahradiť importom.'::text; END IF;
  IF cardinality(members) <> 1 OR members[1] IS DISTINCT FROM _uid THEN
    reasons := reasons || format('Organizácia má %s účtov. Import je možný len do organizácie, v ktorej je jediným účtom jej správca.', cardinality(members));
  END IF;
  FOR r IN SELECT s.rel, s.filter, v.label FROM org_transfer.spec() s
           JOIN (VALUES ('public.punches', 'razenia'), ('public.corrections', 'žiadosti o opravu'), ('public.punch_void_requests', 'žiadosti o zneplatnenie'),
                        ('public.month_closures', 'uzávierky mesiaca'), ('public.personnel_requests', 'žiadosti o osobné číslo'),
                        ('public.employee_month_plan', 'plán z Accessu'), ('public.access_config', 'konfigurácia z Accessu')) v(rel, label) ON v.rel = s.rel
           ORDER BY s.ord LOOP
    EXECUTE format('SELECT count(*) FROM %s t WHERE %s', r.rel, replace(r.filter, '{M}', '$2')) INTO n USING _org, members;
    IF n > 0 THEN reasons := reasons || format('Organizácia už má údaje (%s: %s).', r.label, n); END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM org_transfer.transfers t WHERE t.organization_id = _org AND t.state IN ('ready', 'exported')) THEN
    reasons := reasons || 'Organizácia má rozpracovaný export na iný server. Najprv ho zrušte.'::text;
  END IF;
  SELECT count(*) INTO devices FROM public.devices WHERE organization_id = _org;
  RETURN jsonb_build_object('eligible', cardinality(reasons) = 0, 'reasons', to_jsonb(reasons), 'name', o.name,
                            'code', org_transfer.org_code(o.id), 'users', cardinality(members), 'devices', devices);
END $fn$;

-- Prekážky na strane cieľovej databázy (volá sa pri kontrole aj tesne pred zápisom). _strict = už prebehla kontrola súboru.
CREATE OR REPLACE FUNCTION org_transfer.import_target_problems(_import uuid, _strict boolean) RETURNS text[]
LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $fn$
DECLARE i org_transfer.imports; problems text[] := '{}'; r record; list text; n bigint;
BEGIN
  SELECT * INTO i FROM org_transfer.imports WHERE id = _import;
  list := array_to_string(org_transfer.uncovered_tables(), ', ');
  IF list <> '' THEN problems := problems || format('Prenos nepozná tabuľky: %s. Doplňte ich do org_transfer.spec().', list); END IF;
  list := array_to_string(org_transfer.import_unclassified(), ', ');
  IF list <> '' THEN problems := problems || format('Import nepozná odkazy v stĺpcoch: %s. Doplňte ich do org_transfer.import_refs().', list); END IF;
  FOR r IN SELECT * FROM org_transfer.check_environment() WHERE stav = 'CHYBA' LOOP
    problems := problems || format('Server nie je pripravený na import (%s: %s).', r.kontrola, r.detail);
  END LOOP;
  IF EXISTS (SELECT 1 FROM public.organizations WHERE id = i.org_id) THEN
    problems := problems || 'Organizácia zo súboru na tomto serveri už existuje. Import nič neprepisuje.'::text;
  END IF;
  IF EXISTS (SELECT 1 FROM public.organizations WHERE id NOT IN (i.org_id, i.target_org) AND org_transfer.org_code(id) = org_transfer.org_code(i.org_id)) THEN
    problems := problems || format('Na tomto serveri je iná organizácia s rovnakým kódom %s (prihlásenie by bolo nejednoznačné).', org_transfer.org_code(i.org_id));
  END IF;
  IF NOT _strict OR cardinality(problems) > 0 THEN RETURN problems; END IF;

  -- Účty zo súboru nesmú na cieli existovať (ani ako účet, ani ako profil), e-maily musia byť voľné.
  SELECT count(*) INTO n FROM org_transfer.import_rows w
   WHERE w.import_id = i.id AND w.rel = 'auth.users'
     AND (EXISTS (SELECT 1 FROM auth.users u WHERE u.id = w.k::uuid) OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = w.k::uuid));
  IF n > 0 THEN problems := problems || format('%s účtov zo súboru na tomto serveri už existuje.', n); END IF;
  SELECT count(*) INTO n FROM org_transfer.import_rows w
   WHERE w.import_id = i.id AND w.rel = 'auth.users'
     AND EXISTS (SELECT 1 FROM auth.users u WHERE lower(u.email) = lower(w.data->>'email') AND u.id <> i.started_by);
  IF n > 0 THEN problems := problems || format('%s účtov zo súboru má prihlasovací identifikátor, ktorý sa na tomto serveri už používa.', n); END IF;
  IF cardinality(i.loose_ids) > 0 AND (EXISTS (SELECT 1 FROM auth.users u WHERE u.id = ANY (i.loose_ids))
                                       OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = ANY (i.loose_ids))) THEN
    problems := problems || 'Súbor odkazuje na účet, ktorý nie je v súbore, ale na tomto serveri existuje (cudzia organizácia).'::text;
  END IF;
  SELECT count(*) INTO n FROM org_transfer.import_rows w
   WHERE w.import_id = i.id AND w.rel = 'public.punches' AND EXISTS (SELECT 1 FROM public.punches p WHERE p.client_uuid = (w.data->>'client_uuid')::uuid);
  IF n > 0 THEN problems := problems || format('%s razení zo súboru na tomto serveri už existuje (údaje sú pravdepodobne už prenesené).', n); END IF;
  SELECT string_agg(DISTINCT s.c, ', ') INTO list FROM (
      SELECT w.data->>'code' AS c FROM org_transfer.import_rows w
       WHERE w.import_id = i.id AND w.rel IN ('public.organization_codes', 'public.punches', 'public.corrections')) s
   WHERE s.c IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.absence_codes a WHERE a.code = s.c);
  IF list IS NOT NULL THEN problems := problems || format('Tento server nemá v číselníku prerušení kódy: %s.', left(list, 300)); END IF;
  RETURN problems;
END $fn$;

-- -----------------------------------------------------------------------------------------------------
-- Vkladanie z odkladacej tabuľky. Názvy stĺpcov sa berú z katalógu (prienik so stĺpcami zo súboru), nikdy zo súboru priamo.
--   _base: ak nie je NULL, razenia sa prečíslujú (_base + poradie podľa pôvodného id) a odkazy punch_id sa prepočítajú rovnako.
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION org_transfer.import_insert(_import uuid, _rel text, _cols jsonb, _null_cols text[], _key text, _base bigint) RETURNS bigint
LANGUAGE plpgsql SET search_path = pg_catalog AS $fn$
DECLARE keys text[]; cols text; sel text; setlist text; pre text := ''; n bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM org_transfer.spec() s WHERE s.rel = _rel AND s.rel LIKE 'public.%') THEN RAISE EXCEPTION 'Neznáma tabuľka %', _rel; END IF;
  keys := ARRAY(SELECT jsonb_array_elements_text(coalesce(_cols, '[]'::jsonb)));
  SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum),
         string_agg(CASE
             WHEN a.attname::text = ANY (_null_cols) THEN 'CAST(NULL AS ' || format_type(a.atttypid, a.atttypmod) || ')'
             WHEN _base IS NOT NULL AND _rel = 'public.punches' AND a.attname = 'id'
               THEN '($3 + row_number() OVER (ORDER BY (s.data->>''id'')::bigint))'
             WHEN _base IS NOT NULL AND _rel IN ('public.corrections', 'public.punch_void_requests') AND a.attname = 'punch_id'
               THEN '(SELECT $3 + pm.rn FROM pm WHERE pm.old = r.punch_id)'
             ELSE 'r.' || quote_ident(a.attname) END, ', ' ORDER BY a.attnum)
    INTO cols, sel
  FROM pg_attribute a
  WHERE a.attrelid = _rel::regclass AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = ''
    AND a.attname::text = ANY (keys) AND NOT (_rel = 'public.audit_log' AND a.attname = 'id');
  IF cols IS NULL THEN RAISE EXCEPTION 'Tabuľka % nemá žiadny stĺpec zo súboru', _rel; END IF;
  IF _base IS NOT NULL AND _rel IN ('public.corrections', 'public.punch_void_requests') THEN
    pre := 'WITH pm AS MATERIALIZED (SELECT (p.data->>''id'')::bigint AS old, row_number() OVER (ORDER BY (p.data->>''id'')::bigint) AS rn '
        || 'FROM org_transfer.import_rows p WHERE p.import_id = $1 AND p.rel = ''public.punches'') ';
  END IF;
  EXECUTE format('%sINSERT INTO %s (%s) OVERRIDING SYSTEM VALUE SELECT %s FROM org_transfer.import_rows s, LATERAL jsonb_populate_record(NULL::%s, s.data) AS r '
              || 'WHERE s.import_id = $1 AND s.rel = $2 ORDER BY s.seq, s.n', pre, _rel, cols, sel, _rel)
    USING _import, _rel, _base;
  GET DIAGNOSTICS n = ROW_COUNT;
  -- odkazy na tú istú tabuľku (nadriadený, nahradené zariadenie) až druhým krokom
  SELECT string_agg(format('%I = r.%I', c, c), ', ') INTO setlist FROM unnest(_null_cols) c WHERE c = ANY (keys);
  IF setlist IS NOT NULL THEN
    EXECUTE format('UPDATE %s t SET %s FROM org_transfer.import_rows s, LATERAL jsonb_populate_record(NULL::%s, s.data) AS r '
                || 'WHERE s.import_id = $1 AND s.rel = $2 AND t.%I = r.%I', _rel, setlist, _rel, _key, _key)
      USING _import, _rel;
  END IF;
  RETURN n;
END $fn$;

-- Prihlasovacie účty a identity: vkladajú sa len vymenované stĺpce (prienik s tým, čo má táto verzia prihlasovacieho servera);
-- rola, aud, príznaky a tokeny sa NEpreberajú zo súboru.
CREATE OR REPLACE FUNCTION org_transfer.import_insert_auth(_import uuid, _instance uuid) RETURNS jsonb
LANGUAGE plpgsql SET search_path = pg_catalog AS $fn$
DECLARE cols text; sel text; nu bigint; ni bigint;
BEGIN
  SELECT string_agg(quote_ident(c.col), ', ' ORDER BY c.ord), string_agg(c.expr, ', ' ORDER BY c.ord) INTO cols, sel
  FROM (VALUES
    (1, 'instance_id', '$2'), (2, 'id', 'r.id'), (3, 'aud', '''authenticated'''), (4, 'role', '''authenticated'''),
    (5, 'email', 'r.email'), (6, 'encrypted_password', 'r.encrypted_password'), (7, 'email_confirmed_at', 'r.email_confirmed_at'),
    (8, 'invited_at', 'r.invited_at'), (9, 'last_sign_in_at', 'r.last_sign_in_at'),
    (10, 'raw_app_meta_data', 'coalesce(r.raw_app_meta_data, ''{}''::jsonb)'), (11, 'raw_user_meta_data', 'coalesce(r.raw_user_meta_data, ''{}''::jsonb)'),
    (12, 'is_super_admin', 'r.is_super_admin'), (13, 'created_at', 'r.created_at'), (14, 'updated_at', 'r.updated_at'),
    (15, 'banned_until', 'r.banned_until'), (16, 'deleted_at', 'r.deleted_at'),
    (17, 'confirmation_token', ''''''), (18, 'recovery_token', ''''''), (19, 'email_change_token_new', ''''''), (20, 'email_change', ''''''),
    (21, 'phone_change', ''''''), (22, 'phone_change_token', ''''''), (23, 'email_change_token_current', ''''''),
    (24, 'reauthentication_token', ''''''), (25, 'email_change_confirm_status', '0'), (26, 'is_sso_user', 'false'), (27, 'is_anonymous', 'false')
  ) c(ord, col, expr)
  JOIN pg_attribute a ON a.attrelid = 'auth.users'::regclass AND a.attname = c.col AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = '';
  EXECUTE format('INSERT INTO auth.users (%s) SELECT %s FROM org_transfer.import_rows s, LATERAL jsonb_populate_record(NULL::auth.users, s.data) AS r '
              || 'WHERE s.import_id = $1 AND s.rel = ''auth.users'' ORDER BY s.seq, s.n', cols, sel)
    USING _import, _instance;
  GET DIAGNOSTICS nu = ROW_COUNT;

  SELECT string_agg(quote_ident(c.col), ', ' ORDER BY c.ord), string_agg(c.expr, ', ' ORDER BY c.ord) INTO cols, sel
  FROM (VALUES
    (1, 'id', 'r.id'), (2, 'provider_id', 'r.provider_id'), (3, 'user_id', 'r.user_id'), (4, 'identity_data', 'r.identity_data'),
    (5, 'provider', '''email'''), (6, 'last_sign_in_at', 'r.last_sign_in_at'), (7, 'created_at', 'r.created_at'), (8, 'updated_at', 'r.updated_at')
  ) c(ord, col, expr)
  JOIN pg_attribute a ON a.attrelid = 'auth.identities'::regclass AND a.attname = c.col AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = '';
  EXECUTE format('INSERT INTO auth.identities (%s) SELECT %s FROM org_transfer.import_rows s, LATERAL jsonb_populate_record(NULL::auth.identities, s.data) AS r '
              || 'WHERE s.import_id = $1 AND s.rel = ''auth.identities'' ORDER BY s.seq, s.n', cols, sel)
    USING _import;
  GET DIAGNOSTICS ni = ROW_COUNT;
  RETURN jsonb_build_object('auth.users', nu, 'auth.identities', ni);
END $fn$;

-- -----------------------------------------------------------------------------------------------------
-- 1. Stav pre obrazovku
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.org_import_status() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET timezone = 'UTC' AS $$
DECLARE org uuid; e jsonb; i org_transfer.imports; d org_transfer.imports; received bigint := 0;
BEGIN
  org := org_transfer.caller_org();
  e := org_transfer.import_eligibility(org, auth.uid());
  SELECT * INTO i FROM org_transfer.imports x WHERE x.target_org = org AND x.state IN ('uploading', 'checked');
  IF i.id IS NOT NULL THEN SELECT count(*) INTO received FROM org_transfer.import_rows w WHERE w.import_id = i.id; END IF;
  SELECT * INTO d FROM org_transfer.imports x WHERE x.org_id = org AND x.state = 'done' ORDER BY x.finished_at DESC LIMIT 1;
  RETURN e || jsonb_build_object(
    'active', CASE WHEN i.id IS NULL THEN NULL ELSE jsonb_build_object('import_id', i.id, 'state', i.state, 'organization',
                   jsonb_build_object('id', i.org_id, 'name', i.org_name, 'code', org_transfer.org_code(i.org_id)),
                   'rows', i.total_rows, 'received', received, 'started_at', i.started_at) END,
    'last_import', CASE WHEN d.id IS NULL THEN NULL ELSE jsonb_build_object('finished_at', d.finished_at, 'receipt', org_transfer.receipt(d.meta),
                   'rows', d.total_rows) END,
    'limits', org_transfer.import_limits());
END $$;

-- -----------------------------------------------------------------------------------------------------
-- 2. Začiatok importu. _meta = hlavička súboru (časť „meta“) ako text.
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.org_import_begin(_meta text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public SET timezone = 'UTC' AS $$
DECLARE org uuid; e jsonb; meta jsonb; lim jsonb := org_transfer.import_limits(); r record; xorg uuid; xname text; total bigint := 0; n bigint;
        problems text[] := '{}'; pcols text[]; c text; ix record; tables jsonb := '[]'; iid uuid := gen_random_uuid(); staged bigint;
BEGIN
  org := org_transfer.caller_org();
  PERFORM 1 FROM public.organizations WHERE id = org FOR UPDATE;
  e := org_transfer.import_eligibility(org, auth.uid());
  IF NOT (e->>'eligible')::boolean THEN
    RAISE EXCEPTION 'Do tejto organizácie sa importovať nedá: %', (SELECT string_agg(x, ' ') FROM jsonb_array_elements_text(e->'reasons') x);
  END IF;

  IF _meta IS NULL OR length(_meta) > (lim->>'max_meta_chars')::int THEN RAISE EXCEPTION 'Hlavička súboru chýba alebo je príliš veľká'; END IF;
  BEGIN
    meta := _meta::jsonb;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Hlavička súboru nie je platný JSON';
  END;
  IF jsonb_typeof(meta) <> 'object' OR jsonb_typeof(meta->'organization') IS DISTINCT FROM 'object' OR jsonb_typeof(meta->'counts') IS DISTINCT FROM 'object'
     OR jsonb_typeof(meta->'columns') IS DISTINCT FROM 'object' OR jsonb_typeof(meta->'fingerprint') IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Súbor nie je prenos organizácie (neúplná hlavička)';
  END IF;
  IF meta->>'format' IS DISTINCT FROM '2' THEN RAISE EXCEPTION 'Nepodporovaný formát súboru (očakáva sa 2, export z aplikácie)'; END IF;
  IF coalesce(meta->'organization'->>'id', '') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN RAISE EXCEPTION 'Hlavička súboru nemá platné id organizácie'; END IF;
  xorg := (meta->'organization'->>'id')::uuid; xname := meta->'organization'->>'name';
  IF xname IS NULL OR length(btrim(xname)) NOT BETWEEN 2 AND 160 THEN RAISE EXCEPTION 'Hlavička súboru nemá platný názov organizácie'; END IF;
  IF jsonb_typeof(meta->'order_digest') IS DISTINCT FROM 'string' THEN RAISE EXCEPTION 'Hlavička súboru nemá odtlačok poradia razení'; END IF;
  IF coalesce(meta->>'chain_problems', '0') !~ '^[0-9]{1,12}$' THEN RAISE EXCEPTION 'Hlavička súboru má neplatný počet porušení reťaze'; END IF;

  FOR r IN SELECT * FROM org_transfer.spec() ORDER BY ord LOOP
    IF coalesce(meta->'counts'->>r.rel, '') !~ '^[0-9]{1,9}$' OR jsonb_typeof(meta->'columns'->r.rel) IS DISTINCT FROM 'array'
       OR jsonb_typeof(meta->'fingerprint'->r.rel) IS DISTINCT FROM 'object'
       OR (meta->'fingerprint'->r.rel->>'n') IS DISTINCT FROM (meta->'counts'->>r.rel) OR jsonb_typeof(meta->'fingerprint'->r.rel->'d') IS DISTINCT FROM 'string' THEN
      RAISE EXCEPTION 'V hlavičke súboru chýba alebo je poškodená tabuľka %', r.rel;
    END IF;
    n := (meta->'counts'->>r.rel)::bigint; total := total + n;
    tables := tables || jsonb_build_array(jsonb_build_object('rel', r.rel, 'n', n));
    CONTINUE WHEN r.rel LIKE 'auth.%';     -- účty sa vkladajú po vymenovaných stĺpcoch
    pcols := ARRAY(SELECT jsonb_array_elements_text(meta->'columns'->r.rel));
    FOREACH c IN ARRAY pcols LOOP
      IF NOT EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = r.rel::regclass AND a.attname = c AND a.attnum > 0 AND NOT a.attisdropped) THEN
        problems := problems || format('%s: súbor obsahuje stĺpec, ktorý tento server nemá (iná verzia aplikácie).', r.rel);
        EXIT;
      END IF;
    END LOOP;
    FOR ix IN SELECT a.attname::text AS col FROM pg_attribute a
              WHERE a.attrelid = r.rel::regclass AND a.attnum > 0 AND NOT a.attisdropped AND a.attnotnull AND NOT a.atthasdef
                AND a.attgenerated = '' AND a.attidentity = '' AND a.attname::text <> ALL (pcols) LOOP
      problems := problems || format('%s: tento server vyžaduje stĺpec %s, ktorý súbor neobsahuje (iná verzia aplikácie).', r.rel, ix.col);
    END LOOP;
  END LOOP;
  IF (meta->'counts'->>'public.organizations')::bigint <> 1 THEN RAISE EXCEPTION 'Súbor musí obsahovať práve jednu organizáciu'; END IF;
  IF (meta->'counts'->>'auth.users')::bigint < 1 OR (meta->'counts'->>'auth.users') <> (meta->'counts'->>'public.profiles') THEN
    RAISE EXCEPTION 'Súbor musí obsahovať aspoň jeden účet a rovnaký počet účtov a profilov';
  END IF;
  IF total > (lim->>'max_total_rows')::bigint THEN
    RAISE EXCEPTION 'Organizácia je na import tlačidlom príliš veľká (% riadkov, najviac %). Použite operátorský postup.', total, lim->>'max_total_rows';
  END IF;

  -- Staré rozpracované importy (opustené pred viac ako 24 hodinami) a predchádzajúci import tejto organizácie sa zahodia.
  DELETE FROM org_transfer.import_rows w USING org_transfer.imports x
   WHERE w.import_id = x.id AND x.state IN ('uploading', 'checked')
     AND (x.target_org = org OR x.started_at < now() - make_interval(hours => (lim->>'stale_hours')::int));
  UPDATE org_transfer.imports x SET state = 'cancelled', finished_at = now()
   WHERE x.state IN ('uploading', 'checked') AND (x.target_org = org OR x.started_at < now() - make_interval(hours => (lim->>'stale_hours')::int));
  SELECT coalesce(sum(x.total_rows), 0) INTO staged FROM org_transfer.imports x WHERE x.state IN ('uploading', 'checked');
  IF staged + total > (lim->>'max_staged_rows')::bigint THEN RAISE EXCEPTION 'Server práve spracúva iné importy. Skúste to neskôr.'; END IF;

  INSERT INTO org_transfer.imports (id, target_org, target_name, started_by, state, org_id, org_name, total_rows, meta)
  VALUES (iid, org, e->>'name', auth.uid(), 'uploading', xorg, xname, total, meta);
  problems := problems || org_transfer.import_target_problems(iid, false);
  IF cardinality(problems) > 0 THEN
    RAISE EXCEPTION E'Import sa nezačal:%', (SELECT string_agg(E'\n - ' || p, '') FROM unnest(problems) p);
  END IF;
  RETURN jsonb_build_object('import_id', iid, 'organization', jsonb_build_object('id', xorg, 'name', xname, 'code', org_transfer.org_code(xorg)),
                            'tables', tables, 'rows', total, 'replaces', e,
                            'max_chunk_rows', (lim->>'max_chunk_rows')::int, 'max_chunk_chars', (lim->>'max_chunk_chars')::int);
END $$;

-- -----------------------------------------------------------------------------------------------------
-- 3. Jedna časť riadkov jednej tabuľky. _rows = text s JSON poľom objektov presne tak, ako sú v súbore (prehliadač ho neprevádza:
-- čísla by stratili zápis a odtlačok by sa nezhodoval). Tá istá časť (_seq) sa dá poslať znova, nahradí predchádzajúcu.
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.org_import_chunk(_import uuid, _rel text, _seq integer, _rows text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public SET timezone = 'UTC' AS $$
DECLARE org uuid; i org_transfer.imports; s record; lim jsonb := org_transfer.import_limits(); rws jsonb; cnt int; have bigint; kcol text;
BEGIN
  org := org_transfer.caller_org();
  SELECT * INTO i FROM org_transfer.imports x WHERE x.id = _import AND x.target_org = org AND x.started_by = auth.uid() FOR UPDATE;
  IF i.id IS NULL THEN RAISE EXCEPTION 'Import neexistuje'; END IF;
  IF i.state <> 'uploading' THEN RAISE EXCEPTION 'Import už nie je v stave nahrávania (stav: %). Začnite nový import.', i.state; END IF;
  SELECT * INTO s FROM org_transfer.spec() x WHERE x.rel = _rel;
  IF s.rel IS NULL THEN RAISE EXCEPTION 'Neznáma tabuľka'; END IF;
  IF _seq IS NULL OR _seq < 0 OR _seq > 100000 THEN RAISE EXCEPTION 'Neplatné poradie časti'; END IF;
  IF _rows IS NULL OR length(_rows) > (lim->>'max_chunk_chars')::int THEN RAISE EXCEPTION 'Časť chýba alebo je príliš veľká'; END IF;
  BEGIN
    rws := _rows::jsonb;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Časť nie je platný JSON';
  END;
  IF jsonb_typeof(rws) <> 'array' THEN RAISE EXCEPTION 'Časť musí byť pole riadkov'; END IF;
  cnt := jsonb_array_length(rws);
  IF cnt < 1 OR cnt > (lim->>'max_chunk_rows')::int THEN RAISE EXCEPTION 'Neplatný počet riadkov v časti'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(rws) e WHERE jsonb_typeof(e) <> 'object') THEN RAISE EXCEPTION 'Riadok musí byť objekt'; END IF;

  kcol := coalesce(s.key_col, 'id');
  DELETE FROM org_transfer.import_rows w WHERE w.import_id = i.id AND w.rel = _rel AND w.seq = _seq;
  INSERT INTO org_transfer.import_rows (import_id, rel, seq, n, k, data)
  SELECT i.id, _rel, _seq, a.n::int, a.e->>kcol, a.e FROM jsonb_array_elements(rws) WITH ORDINALITY a(e, n);
  SELECT count(*) INTO have FROM org_transfer.import_rows w WHERE w.import_id = i.id AND w.rel = _rel;
  IF have > (i.meta->'counts'->>_rel)::bigint THEN
    RAISE EXCEPTION 'Tabuľka % má viac riadkov, než uvádza hlavička súboru', _rel;
  END IF;
  RETURN jsonb_build_object('rel', _rel, 'seq', _seq, 'count', cnt, 'received', have);
END $$;

-- -----------------------------------------------------------------------------------------------------
-- 4. Kontrola nahraného súboru (nič v aplikácii nemení). Po úspechu je import v stave „checked“ a ďalšie časti už neprijíma.
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.org_import_check(_import uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public SET timezone = 'UTC' SET statement_timeout = '120s' AS $$
DECLARE org uuid; i org_transfer.imports; e jsonb; r record; n bigint; m bigint; problems text[] := '{}'; warnings text[] := '{}'; meta jsonb;
        el jsonb; loose text[]; list text; tgt text; summ jsonb; c3 bigint; c4 bigint;
        uu CONSTANT text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
BEGIN
  org := org_transfer.caller_org();
  SELECT * INTO i FROM org_transfer.imports x WHERE x.id = _import AND x.target_org = org AND x.started_by = auth.uid() FOR UPDATE;
  IF i.id IS NULL THEN RAISE EXCEPTION 'Import neexistuje'; END IF;
  IF i.state NOT IN ('uploading', 'checked') THEN RAISE EXCEPTION 'Import už nie je rozpracovaný (stav: %). Začnite nový import.', i.state; END IF;
  e := org_transfer.import_eligibility(org, auth.uid());
  IF NOT (e->>'eligible')::boolean THEN
    RAISE EXCEPTION 'Do tejto organizácie sa importovať nedá: %', (SELECT string_agg(x, ' ') FROM jsonb_array_elements_text(e->'reasons') x);
  END IF;
  meta := i.meta;

  -- úplnosť
  FOR r IN SELECT s.rel, (meta->'counts'->>s.rel)::bigint AS want,
                  (SELECT count(*) FROM org_transfer.import_rows w WHERE w.import_id = i.id AND w.rel = s.rel) AS have
           FROM org_transfer.spec() s ORDER BY s.ord LOOP
    IF r.have <> r.want THEN problems := problems || format('%s: nahraných %s riadkov namiesto %s', r.rel, r.have, r.want); END IF;
  END LOOP;
  IF cardinality(problems) > 0 THEN
    RAISE EXCEPTION E'Súbor nie je nahraný celý:%', (SELECT string_agg(E'\n - ' || p, '') FROM unnest(problems) p);
  END IF;

  -- tvar identifikátorov (rovnaký zápis, aký píše databáza: porovnania odkazov sú potom jednoznačné)
  SELECT count(*) INTO n FROM org_transfer.import_rows w
   WHERE w.import_id = i.id AND w.rel IN ('public.organizations', 'auth.users', 'auth.identities', 'public.profiles', 'public.devices', 'public.punch_void_requests')
     AND (w.k IS NULL OR w.k !~ uu);
  IF n > 0 THEN problems := problems || format('%s riadkov má neplatný identifikátor.', n); END IF;
  SELECT count(*) INTO n FROM org_transfer.import_rows w WHERE w.import_id = i.id AND w.rel = 'public.punches' AND (w.k IS NULL OR w.k !~ '^[1-9][0-9]{0,17}$');
  IF n > 0 THEN problems := problems || format('%s razení má neplatné číslo.', n); END IF;
  SELECT count(*) INTO n FROM org_transfer.import_rows w WHERE w.import_id = i.id AND w.rel = 'public.punches' AND coalesce(w.data->>'client_uuid', '') !~ uu;
  IF n > 0 THEN problems := problems || format('%s razení má neplatný identifikátor (client_uuid).', n); END IF;
  IF cardinality(problems) > 0 THEN
    RAISE EXCEPTION E'Súbor nevyhovuje:%', (SELECT string_agg(E'\n - ' || p, '') FROM unnest(problems) p);
  END IF;

  -- organizácia: jediný riadok, id a názov ako v hlavičke (to, čo správca potvrdzuje, je to, čo sa vloží)
  SELECT w.data INTO el FROM org_transfer.import_rows w WHERE w.import_id = i.id AND w.rel = 'public.organizations';
  IF el->>'id' IS DISTINCT FROM i.org_id::text OR el->>'name' IS DISTINCT FROM i.org_name THEN
    problems := problems || 'Organizácia v súbore sa nezhoduje s hlavičkou súboru.'::text;
  END IF;

  -- účty = profily (tie isté id, každé raz)
  SELECT count(*) INTO n FROM (
    (SELECT w.k FROM org_transfer.import_rows w WHERE w.import_id = i.id AND w.rel = 'auth.users'
     EXCEPT SELECT w.k FROM org_transfer.import_rows w WHERE w.import_id = i.id AND w.rel = 'public.profiles')
    UNION ALL
    (SELECT w.k FROM org_transfer.import_rows w WHERE w.import_id = i.id AND w.rel = 'public.profiles'
     EXCEPT SELECT w.k FROM org_transfer.import_rows w WHERE w.import_id = i.id AND w.rel = 'auth.users')) s;
  SELECT count(*) - count(DISTINCT w.k) INTO m FROM org_transfer.import_rows w WHERE w.import_id = i.id AND w.rel = 'auth.users';
  IF n > 0 OR m > 0 THEN problems := problems || 'Prihlasovacie účty a profily v súbore si nezodpovedajú.'::text; END IF;

  -- odkazy: všetko musí ostať vo vnútri organizácie zo súboru
  FOR r IN SELECT f.rel, f.col, f.kind FROM org_transfer.import_refs() f WHERE f.kind NOT IN ('own', 'user_loose') ORDER BY f.rel, f.col LOOP
    IF r.kind = 'org' THEN
      SELECT count(*) INTO n FROM org_transfer.import_rows w
       WHERE w.import_id = i.id AND w.rel = r.rel AND (w.data->>r.col) IS DISTINCT FROM i.org_id::text;
    ELSE
      tgt := CASE r.kind WHEN 'device' THEN 'public.devices' WHEN 'punch' THEN 'public.punches' WHEN 'void' THEN 'public.punch_void_requests' ELSE 'public.profiles' END;
      SELECT count(*) INTO n FROM org_transfer.import_rows w
       WHERE w.import_id = i.id AND w.rel = r.rel
         AND CASE WHEN w.data->>r.col IS NULL THEN r.kind = 'owner'
                  ELSE NOT EXISTS (SELECT 1 FROM org_transfer.import_rows t WHERE t.import_id = i.id AND t.rel = tgt AND t.k = w.data->>r.col) END;
    END IF;
    IF n > 0 THEN problems := problems || format('%s.%s: %s riadkov nepatrí organizácii zo súboru alebo odkazuje mimo súboru.', r.rel, r.col, n); END IF;
  END LOOP;
  -- voľné odkazy na účty (kto rozhodol…): účet zo súboru, alebo účet, ktorý neexistuje ani tu
  SELECT coalesce(array_agg(DISTINCT s.v), ARRAY[]::text[]) INTO loose FROM (
    SELECT w.data->>f.col AS v FROM org_transfer.import_refs() f JOIN org_transfer.import_rows w ON w.import_id = i.id AND w.rel = f.rel
     WHERE f.kind = 'user_loose' AND w.data->>f.col IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM org_transfer.import_rows t WHERE t.import_id = i.id AND t.rel = 'public.profiles' AND t.k = w.data->>f.col)) s;
  IF EXISTS (SELECT 1 FROM unnest(loose) v WHERE v !~ uu) OR cardinality(loose) > 1000 THEN
    problems := problems || 'Súbor má neplatné alebo príliš početné odkazy na účty mimo súboru.'::text; loose := ARRAY[]::text[];
  ELSIF cardinality(loose) > 0 THEN
    warnings := warnings || format('%s odkazov vedie na účty, ktoré už v pôvodnej organizácii neexistovali (prenesú sa tak, ako sú).', cardinality(loose));
  END IF;

  -- prihlasovacie účty: žiadne zvýšené oprávnenia
  SELECT count(*) FILTER (WHERE coalesce(d->>'aud', 'authenticated') <> 'authenticated' OR coalesce(d->>'role', 'authenticated') <> 'authenticated'
                             OR coalesce(d->>'is_super_admin', 'false') <> 'false' OR coalesce(d->>'is_sso_user', 'false') <> 'false'
                             OR coalesce(d->>'is_anonymous', 'false') <> 'false' OR d->>'phone' IS NOT NULL),
         count(*) FILTER (WHERE d->>'email' IS NULL OR length(d->>'email') > 255 OR d->>'email' !~ '^[^@[:space:]]+@[^@[:space:]]+$'
                             OR length(coalesce(d->>'encrypted_password', '')) > 255),
         count(*) FILTER (WHERE jsonb_typeof(coalesce(nullif(d->'raw_app_meta_data', 'null'), '{}')) <> 'object'
                             OR jsonb_typeof(coalesce(nullif(d->'raw_user_meta_data', 'null'), '{}')) <> 'object'
                             OR coalesce(d->'raw_app_meta_data'->>'provider', 'email') <> 'email'
                             OR jsonb_typeof(coalesce(nullif(d->'raw_app_meta_data'->'providers', 'null'), '[]')) <> 'array'
                             OR coalesce(nullif(d->'raw_app_meta_data'->'providers', 'null'), '[]') NOT IN ('[]'::jsonb, '["email"]'::jsonb)),
         count(*) - count(DISTINCT lower(d->>'email'))
    INTO n, m, c3, c4
    FROM (SELECT w.data AS d FROM org_transfer.import_rows w WHERE w.import_id = i.id AND w.rel = 'auth.users') s;
  IF n > 0 THEN problems := problems || format('%s prihlasovacích účtov má neštandardnú rolu alebo príznak (povolené sú len bežné účty).', n); END IF;
  IF m > 0 THEN problems := problems || format('%s prihlasovacích účtov má neplatný prihlasovací identifikátor alebo heslo.', m); END IF;
  IF c3 > 0 THEN problems := problems || format('%s prihlasovacích účtov má neplatné metadáta.', c3); END IF;
  IF c4 > 0 THEN problems := problems || 'Prihlasovacie identifikátory účtov sa v súbore opakujú.'::text; END IF;
  SELECT string_agg(DISTINCT key, ', ') INTO list
    FROM org_transfer.import_rows w,
         LATERAL jsonb_object_keys(CASE WHEN jsonb_typeof(w.data->'raw_app_meta_data') = 'object' THEN w.data->'raw_app_meta_data' ELSE '{}'::jsonb END) key
   WHERE w.import_id = i.id AND w.rel = 'auth.users' AND key <> ALL (org_transfer.import_app_meta_keys());
  IF list IS NOT NULL THEN
    problems := problems || format('Prihlasovacie účty majú v app_metadata nepovolený kľúč (%s). Povolené kľúče: org_transfer.import_app_meta_keys().', left(list, 200));
  END IF;
  SELECT count(*) INTO n FROM org_transfer.import_rows w
   WHERE w.import_id = i.id AND w.rel = 'auth.identities'
     AND (w.data->>'provider' IS DISTINCT FROM 'email' OR w.data->>'provider_id' IS DISTINCT FROM w.data->>'user_id'
          OR jsonb_typeof(w.data->'identity_data') IS DISTINCT FROM 'object'
          OR coalesce(w.data->'identity_data'->>'sub', w.data->>'user_id') <> w.data->>'user_id');
  IF n > 0 THEN problems := problems || format('%s identít účtov nie je typu e-mail alebo nepatrí svojmu účtu.', n); END IF;

  -- pravidlá, ktoré inak strážia spúšťače (počas importu sú vypnuté)
  SELECT count(*) INTO n FROM org_transfer.import_rows w
   WHERE w.import_id = i.id AND w.rel = 'public.profiles' AND w.data->>'sap_id' IS NOT NULL AND w.data->>'sap_id' !~ '^[0-9]{7,8}$';
  IF n > 0 THEN problems := problems || format('%s profilov má neplatné osobné číslo.', n); END IF;
  SELECT count(*) FILTER (WHERE w.data->>'role' = 'admin'), count(*) FILTER (WHERE coalesce(w.data->>'role', '') NOT IN ('employee', 'manager', 'admin')) INTO n, m
    FROM org_transfer.import_rows w WHERE w.import_id = i.id AND w.rel = 'public.user_roles';
  IF n < 1 THEN problems := problems || 'Organizácia v súbore nemá žiadneho správcu.'::text; END IF;
  IF m > 0 THEN problems := problems || format('%s rolí má neznámu hodnotu.', m); END IF;

  IF cardinality(problems) > 0 THEN
    RAISE EXCEPTION E'Súbor nevyhovuje:%', (SELECT string_agg(E'\n - ' || p, '') FROM unnest(problems) p);
  END IF;

  UPDATE org_transfer.imports SET loose_ids = loose::uuid[] WHERE id = i.id;
  problems := org_transfer.import_target_problems(i.id, true);
  IF cardinality(problems) > 0 THEN
    RAISE EXCEPTION E'Import nie je možný:%', (SELECT string_agg(E'\n - ' || p, '') FROM unnest(problems) p);
  END IF;
  IF coalesce((meta->>'chain_problems')::bigint, 0) > 0 THEN
    warnings := warnings || format('Reťaz hashov mala už na pôvodnom serveri %s porušení (prenesie sa tak, ako je).', meta->>'chain_problems');
  END IF;

  summ := jsonb_build_object('organization', jsonb_build_object('id', i.org_id, 'name', i.org_name, 'code', org_transfer.org_code(i.org_id)),
                                'counts', meta->'counts', 'rows', i.total_rows, 'exported_at', meta->>'exported_at', 'warnings', to_jsonb(warnings), 'replaces', e);
  UPDATE org_transfer.imports SET state = 'checked', checked_at = now(), summary = summ WHERE id = i.id;
  RETURN summ || jsonb_build_object('state', 'checked', 'import_id', i.id);
END $$;

-- -----------------------------------------------------------------------------------------------------
-- 5. Zápis. _confirm_name = názov čerstvej organizácie, ktorá zanikne (potvrdenie správcu). Jedna transakcia: buď prejde všetko
-- a overí sa, alebo sa nezmení nič (aj vypnutie spúšťačov sa vráti).
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.org_import_commit(_import uuid, _confirm_name text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public SET timezone = 'UTC' SET statement_timeout = '120s' AS $$
DECLARE org uuid; uid uuid := auth.uid(); i org_transfer.imports; o public.organizations; e jsonb; meta jsonb; problems text[]; r record; n bigint;
        fmembers uuid[]; members uuid[]; inst uuid; st jsonb; pseq text; base bigint; maxfile bigint; collisions bigint; renumber boolean; stale bigint := 0;
        counts jsonb := '{}'; removed jsonb := '{}'; fp jsonb; bad text[] := '{}'; cb bigint; maxid bigint; lastv bigint; cname text; receipt text; result jsonb;
        lim jsonb := org_transfer.import_limits();
BEGIN
  org := org_transfer.caller_org();
  SELECT * INTO i FROM org_transfer.imports x WHERE x.id = _import AND x.target_org = org AND x.started_by = uid FOR UPDATE;
  IF i.id IS NULL THEN RAISE EXCEPTION 'Import neexistuje'; END IF;
  IF i.state <> 'checked' THEN RAISE EXCEPTION 'Import nie je skontrolovaný (stav: %). Najprv spustite kontrolu.', i.state; END IF;
  SELECT * INTO o FROM public.organizations WHERE id = org FOR UPDATE;
  IF btrim(coalesce(_confirm_name, '')) <> btrim(o.name) THEN RAISE EXCEPTION 'Názov organizácie, ktorá sa má nahradiť, sa nezhoduje'; END IF;
  e := org_transfer.import_eligibility(org, uid);
  IF NOT (e->>'eligible')::boolean THEN
    RAISE EXCEPTION 'Do tejto organizácie sa importovať nedá: %', (SELECT string_agg(x, ' ') FROM jsonb_array_elements_text(e->'reasons') x);
  END IF;
  problems := org_transfer.import_target_problems(i.id, true);
  IF cardinality(problems) > 0 THEN
    RAISE EXCEPTION E'Import nie je možný:%', (SELECT string_agg(E'\n - ' || p, '') FROM unnest(problems) p);
  END IF;
  meta := i.meta;
  fmembers := ARRAY(SELECT id FROM public.profiles WHERE organization_id = org);
  members := ARRAY(SELECT w.k::uuid FROM org_transfer.import_rows w WHERE w.import_id = i.id AND w.rel = 'public.profiles');
  SELECT coalesce((SELECT u.instance_id FROM auth.users u WHERE u.id = uid), '00000000-0000-0000-0000-000000000000') INTO inst;

  BEGIN
    -- Vypnutie spúšťačov čaká na rozpísané zápisy ostatných najviac 8 s; potom import skončí chybou a nič sa nezmení.
    PERFORM set_config('lock_timeout', '8s', true);
    st := org_transfer.suspend_triggers();

    -- a) čerstvá prázdna organizácia volajúceho zanikne (v opačnom poradí tabuliek)
    FOR r IN SELECT * FROM org_transfer.spec() ORDER BY ord DESC LOOP
      EXECUTE format('DELETE FROM %s t WHERE %s', r.rel, replace(r.filter, '{M}', '$2')) USING org, fmembers;
      GET DIAGNOSTICS n = ROW_COUNT;
      removed := removed || jsonb_build_object(r.rel, n);
    END LOOP;

    -- b) zvyšky auditu po skoršom zrušení tej istej organizácie na tomto serveri (záznam „organization.deleted“ s účtom, ktorý zanikol)
    --    by po importe patrili obnoveným účtom a overenie auditu by zlyhalo: odpoja sa od účtu, pôvodný účet ostane v details.
    UPDATE public.audit_log SET actor = NULL, details = coalesce(details, '{}'::jsonb) || jsonb_build_object('actor_pred_importom', actor::text)
     WHERE actor = ANY (members);
    GET DIAGNOSTICS stale = ROW_COUNT;

    -- c) čísla razení: zachovajú sa, ak sa s ničím nezrazia a nie sú neprimerane vysoké; inak sa prečíslujú v rovnakom poradí
    pseq := pg_get_serial_sequence('public.punches', 'id');
    EXECUTE format('SELECT GREATEST(coalesce((SELECT max(id) FROM public.punches), 0), (SELECT last_value FROM %s))', pseq) INTO base;
    SELECT coalesce(max(w.k::bigint), 0), count(*) FILTER (WHERE EXISTS (SELECT 1 FROM public.punches p WHERE p.id = w.k::bigint))
      INTO maxfile, collisions FROM org_transfer.import_rows w WHERE w.import_id = i.id AND w.rel = 'public.punches';
    renumber := collisions > 0 OR maxfile > base + (lim->>'keep_id_slack')::bigint;

    -- d) vkladanie v poradí cudzích kľúčov
    FOR r IN SELECT * FROM org_transfer.spec() ORDER BY ord LOOP
      IF r.rel = 'auth.users' THEN
        counts := counts || org_transfer.import_insert_auth(i.id, inst);
      ELSIF r.rel <> 'auth.identities' THEN
        counts := counts || jsonb_build_object(r.rel, org_transfer.import_insert(i.id, r.rel, meta->'columns'->r.rel, r.null_cols, r.key_col,
                                                                              CASE WHEN renumber THEN base END));
      END IF;
    END LOOP;

    PERFORM org_transfer.resume_triggers(st);

    -- e) overenie: počty a odtlačky každej tabuľky, hash reťaz, poradie razení, správca
    fp := org_transfer.fp_live(i.org_id, meta->'columns');
    FOR r IN SELECT * FROM org_transfer.spec() ORDER BY ord LOOP
      IF (fp->r.rel->>'n')::bigint <> (meta->'fingerprint'->r.rel->>'n')::bigint THEN
        bad := bad || format('%s: počet riadkov %s namiesto %s', r.rel, fp->r.rel->>'n', meta->'fingerprint'->r.rel->>'n');
      ELSIF fp->r.rel->>'d' <> meta->'fingerprint'->r.rel->>'d' THEN
        bad := bad || format('%s: obsah riadkov sa líši od súboru', r.rel);
      END IF;
    END LOOP;
    members := ARRAY(SELECT id FROM public.profiles WHERE organization_id = i.org_id);
    cb := org_transfer.chain_problems_live(members);
    IF cb <> coalesce((meta->>'chain_problems')::bigint, 0) THEN bad := bad || format('hash reťaz razení: %s porušení namiesto %s', cb, coalesce(meta->>'chain_problems', '0')); END IF;
    IF org_transfer.order_digest_live(members) <> meta->>'order_digest' THEN bad := bad || 'poradie razení (hashov) sa líši od súboru'::text; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.user_roles ur WHERE ur.user_id = ANY (members) AND ur.role = 'admin') THEN bad := bad || 'organizácia nemá správcu'::text; END IF;
    IF EXISTS (SELECT 1 FROM auth.users u WHERE u.id = ANY (members) AND (u.role IS DISTINCT FROM 'authenticated' OR u.aud IS DISTINCT FROM 'authenticated' OR coalesce(u.is_super_admin, false))) THEN
      bad := bad || 'prihlasovací účet s neštandardnou rolou'::text;
    END IF;
    IF cardinality(bad) > 0 THEN
      RAISE EXCEPTION E'Import sa vrátil späť, overenie zlyhalo:%', (SELECT string_agg(E'\n - ' || b, '') FROM unnest(bad) b);
    END IF;

    -- f) sekvencia čísel razení až po úspešnom overení (posun sekvencie sa nevracia späť)
    IF (counts->>'public.punches')::bigint > 0 THEN
      SELECT coalesce(max(id), 1) INTO maxid FROM public.punches;
      EXECUTE format('SELECT last_value FROM %s', pseq) INTO lastv;
      PERFORM setval(pseq, GREATEST(maxid, lastv), true);
    END IF;
  EXCEPTION
    WHEN unique_violation THEN
      GET STACKED DIAGNOSTICS cname = CONSTRAINT_NAME;
      RAISE EXCEPTION 'Import sa vrátil späť: údaj zo súboru sa zráža s údajom, ktorý na tomto serveri už je (obmedzenie %). Nič sa nezmenilo.', cname;
    WHEN foreign_key_violation THEN
      GET STACKED DIAGNOSTICS cname = CONSTRAINT_NAME;
      RAISE EXCEPTION 'Import sa vrátil späť: súbor odkazuje na údaj, ktorý v ňom nie je (obmedzenie %). Nič sa nezmenilo.', cname;
    WHEN lock_not_available THEN
      RAISE EXCEPTION 'Import sa nespustil: databáza je práve zaneprázdnená zápismi. Skúste to o chvíľu znova. Nič sa nezmenilo.';
  END;

  receipt := org_transfer.receipt(meta);
  INSERT INTO public.audit_log (actor, action, target, details)
  VALUES (NULL, 'organization.imported', i.org_id::text,
          jsonb_build_object('name', i.org_name, 'via', 'app', 'by', uid::text, 'replaced', jsonb_build_object('id', org, 'name', o.name),
                             'source_db', meta->>'source_db', 'exported_at', meta->>'exported_at',
                             'ids', CASE WHEN renumber THEN 'renumber' ELSE 'keep' END, 'counts', counts, 'stale_audit_detached', stale));
  result := jsonb_build_object('organization', jsonb_build_object('id', i.org_id, 'name', i.org_name, 'code', org_transfer.org_code(i.org_id)),
                               'receipt', receipt, 'counts', counts, 'rows', i.total_rows, 'ids_mode', CASE WHEN renumber THEN 'renumber' ELSE 'keep' END,
                               'replaced', jsonb_build_object('id', org, 'name', o.name), 'stale_audit_detached', stale,
                               'warnings', coalesce(i.summary->'warnings', '[]'::jsonb));
  DELETE FROM org_transfer.import_rows w WHERE w.import_id = i.id;
  UPDATE org_transfer.imports SET state = 'done', finished_at = now(), summary = result WHERE id = i.id;
  RETURN result || jsonb_build_object('state', 'done', 'import_id', i.id);
END $$;

-- -----------------------------------------------------------------------------------------------------
-- 6. Zahodenie rozpracovaného importu (nahrané riadky sa zmažú; v aplikácii sa nič nemenilo)
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.org_import_cancel() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE org uuid; i org_transfer.imports;
BEGIN
  org := org_transfer.caller_org();
  SELECT * INTO i FROM org_transfer.imports x WHERE x.target_org = org AND x.state IN ('uploading', 'checked') FOR UPDATE;
  IF i.id IS NULL THEN RETURN jsonb_build_object('state', 'none'); END IF;
  DELETE FROM org_transfer.import_rows w WHERE w.import_id = i.id;
  UPDATE org_transfer.imports SET state = 'cancelled', finished_at = now() WHERE id = i.id;
  RETURN jsonb_build_object('state', 'cancelled', 'import_id', i.id);
END $$;

-- Práva. Prednastavené práva migračnej roly by dali EXECUTE aj anonymnému používateľovi, preto ich odoberáme výslovne.
REVOKE ALL ON FUNCTION public.org_import_status() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.org_import_begin(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.org_import_chunk(uuid, text, integer, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.org_import_check(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.org_import_commit(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.org_import_cancel() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.org_import_status() TO authenticated;
GRANT EXECUTE ON FUNCTION public.org_import_begin(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.org_import_chunk(uuid, text, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.org_import_check(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.org_import_commit(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.org_import_cancel() TO authenticated;

-- Schéma org_transfer a jej funkcie: len vlastník (rola, ktorá spustila túto migráciu). Funkcie vyššie bežia s jeho právami.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA org_transfer FROM PUBLIC;
DO $$ DECLARE r text; BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON SCHEMA org_transfer FROM %I', r);
      EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA org_transfer FROM %I', r);
    END IF;
  END LOOP;
END $$;

SELECT org_transfer.import_version() AS nainstalovane;
