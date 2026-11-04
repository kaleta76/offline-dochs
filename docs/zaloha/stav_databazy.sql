-- STAV DATABÁZY: jeden dotaz len na čítanie, ktorý vypíše aktuálny stav databázy (schéma, počty, organizácie, kontroly súvislostí).
-- Pozri docs/ZALOHA-DATABAZY.md, kapitola o stave databázy.
--
-- Na čo slúži: Claude nemá prístup do databázy v Lovable Cloud. Tento dotaz spustíte v SQL editore, výsledok uložíte ako CSV
-- (tlačidlo na export výsledku, rovnako ako pri iných dotazoch) a priložíte do chatu. Claude tak vie, ako databáza vyzerá TERAZ,
-- a nemusí hádať z kódu v repozitári.
--
-- Čo dotaz robí: jediný SELECT. Nič nezapisuje, nič nemení, nevytvára objekty. Netreba ho vykonávať v transakcii ani zálohovať.
-- Čo vo výsledku NIE JE: mená, e-maily, osobné čísla SAP, odtlačky hesiel, tokeny zariadení ani obsah razení a auditu.
-- Čo v ňom JE: názvy a identifikátory organizácií, počty riadkov, zoznam tabuliek, stĺpcov, funkcií, spúšťačov a pravidiel RLS,
-- názvy akcií v audite a počty. Výsledok je teda bezpečné poslať do chatu, ale nepatrí do verejného repozitára.
--
-- Výstup má tri stĺpce: sekcia, polozka, hodnota. Dotaz funguje pred aj po migrácii 0007 (chýbajúce veci označí ako "nie").
-- Ak vám editor nemá právo čítať niektorú tabuľku (napr. auth.users), dotaz nespadne a uvedie "bez práva".
-- Skopírujte CELÝ súbor a spustite naraz.

WITH
org AS (
  SELECT o.id, o.name, o.created_at, to_jsonb(o) ->> 'is_test' AS is_test
    FROM public.organizations o
),
auth_ok AS (
  -- Poradie je dôležité: už samotné hľadanie názvu v schéme bez práva USAGE skončí chybou, preto sa najprv pýtame na schému.
  SELECT CASE
           WHEN NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'auth') THEN false
           WHEN NOT has_schema_privilege('auth', 'USAGE') THEN false
           WHEN to_regclass('auth.users') IS NULL THEN false
           ELSE has_table_privilege('auth.users', 'SELECT')
         END AS ok
),
tab AS (
  SELECT n.nspname AS sch, c.relname AS tbl, c.oid AS oid, c.relrowsecurity AS rls
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relkind IN ('r', 'p')
     AND (n.nspname = 'public' OR (n.nspname = 'auth' AND c.relname IN ('users', 'identities', 'sessions')))
),
-- Kontroly súvislostí: 0 = v poriadku, iné číslo = počet záznamov, ktoré tam nepatria.
kontrola AS (
  SELECT 'profily bez organizácie' AS nazov, (SELECT count(*) FROM public.profiles WHERE organization_id IS NULL)::bigint AS n
  UNION ALL SELECT 'profily bez roly',
    (SELECT count(*) FROM public.profiles p WHERE NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = p.id))
  UNION ALL SELECT 'roly bez profilu',
    (SELECT count(*) FROM public.user_roles r WHERE NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = r.user_id))
  UNION ALL SELECT 'razenia bez profilu',
    (SELECT count(*) FROM public.punches x WHERE NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = x.user_id))
  UNION ALL SELECT 'zariadenia bez organizácie alebo profilu',
    (SELECT count(*) FROM public.devices d WHERE d.organization_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = d.user_id))
  UNION ALL SELECT 'organizácie bez správcu',
    (SELECT count(*) FROM public.organizations o WHERE NOT EXISTS (
       SELECT 1 FROM public.profiles p JOIN public.user_roles r ON r.user_id = p.id AND r.role = 'admin' WHERE p.organization_id = o.id))
  UNION ALL SELECT 'razenia bez hashu reťaze',
    (SELECT count(*) FROM public.punches WHERE record_hash IS NULL)
  UNION ALL SELECT 'profily bez účtu v auth.users',
    CASE WHEN (SELECT ok FROM auth_ok)
      THEN (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM public.profiles p WHERE NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p.id)', false, true, '')))[1]::text::bigint
    END
  UNION ALL SELECT 'účty v auth.users bez profilu',
    CASE WHEN (SELECT ok FROM auth_ok)
      THEN (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM auth.users u WHERE NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = u.id)', false, true, '')))[1]::text::bigint
    END
)

SELECT '00_prostredie' AS sekcia, 'skript' AS polozka, 'stav_databazy.sql v1' AS hodnota
UNION ALL SELECT '00_prostredie', 'cas', to_char(now() AT TIME ZONE 'Europe/Bratislava', 'YYYY-MM-DD HH24:MI:SS') || ' (Europe/Bratislava)'
UNION ALL SELECT '00_prostredie', 'server', version()
UNION ALL SELECT '00_prostredie', 'pouzivatel',
  current_user || '; superuser=' || coalesce((SELECT rolsuper::text FROM pg_roles WHERE rolname = current_user), '?')
UNION ALL SELECT '00_prostredie', 'cita_auth_users', (SELECT CASE WHEN ok THEN 'ano' ELSE 'nie (bez práva alebo tabuľka chýba)' END FROM auth_ok)

-- Značky migrácií: čo databáza naozaj obsahuje (nie čo je v repozitári).
UNION ALL SELECT '01_migracie', 'zaznamov v drizzle.__drizzle_migrations',
  CASE WHEN NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'drizzle') THEN 'tabuľka chýba'
       WHEN NOT has_schema_privilege('drizzle', 'USAGE') THEN 'bez práva'
       WHEN to_regclass('drizzle.__drizzle_migrations') IS NULL THEN 'tabuľka chýba'
       WHEN NOT has_table_privilege('drizzle.__drizzle_migrations', 'SELECT') THEN 'bez práva'
       ELSE (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM drizzle.__drizzle_migrations', false, true, '')))[1]::text END
UNION ALL SELECT '01_migracie', m.nazov, CASE WHEN m.je THEN 'ano' ELSE 'nie' END
  FROM (VALUES
    ('0003 stlpec punches.device_verification', EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'punches' AND column_name = 'device_verification')),
    ('0005 tabulka personnel_requests', to_regclass('public.personnel_requests') IS NOT NULL),
    ('0005 tabulka notification_preferences', to_regclass('public.notification_preferences') IS NOT NULL),
    ('0006 tabulka punch_void_requests', to_regclass('public.punch_void_requests') IS NOT NULL),
    ('0006 stlpec punches.voided_at', EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'punches' AND column_name = 'voided_at')),
    ('0007 stlpec organizations.is_test', EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'organizations' AND column_name = 'is_test')),
    ('0007 funkcia set_organization_test', EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'set_organization_test')),
    ('0007 funkcia test_organization_summary', EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'test_organization_summary')),
    ('0007 funkcia delete_test_organization', EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'delete_test_organization')),
    ('0007 funkcia purge_organization', EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'purge_organization'))
  ) AS m(nazov, je)

-- Tabuľky: počet riadkov, zapnuté RLS, počet pravidiel.
UNION ALL SELECT '02_tabulky', t.sch || '.' || t.tbl,
  'riadkov=' || CASE WHEN has_schema_privilege(t.sch, 'USAGE') AND has_table_privilege(t.oid, 'SELECT')
                     THEN (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', t.sch, t.tbl), false, true, '')))[1]::text
                     ELSE 'bez práva' END
  || '; rls=' || CASE WHEN t.rls THEN 'zapnute' ELSE 'VYPNUTE' END
  || '; pravidiel=' || (SELECT count(*) FROM pg_policies pp WHERE pp.schemaname = t.sch AND pp.tablename = t.tbl)
  FROM tab t

-- Stĺpce tabuliek v schéme public.
UNION ALL SELECT '03_stlpce', c.table_name || '.' || c.column_name,
  c.data_type || CASE WHEN c.is_nullable = 'NO' THEN '; NOT NULL' ELSE '' END
  FROM information_schema.columns c JOIN pg_tables pt ON pt.schemaname = c.table_schema AND pt.tablename = c.table_name
 WHERE c.table_schema = 'public'

-- Funkcie v schéme public: typ oprávnenia, práva EXECUTE pre anon a authenticated, odtlačok tela (porovnanie medzi behmi).
UNION ALL SELECT '04_funkcie', p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
  CASE WHEN p.prosecdef THEN 'security definer' ELSE 'invoker' END
  || '; anon_exec=' || CASE WHEN to_regrole('anon') IS NULL THEN 'n/a' ELSE has_function_privilege('anon', p.oid, 'EXECUTE')::text END
  || '; authenticated_exec=' || CASE WHEN to_regrole('authenticated') IS NULL THEN 'n/a' ELSE has_function_privilege('authenticated', p.oid, 'EXECUTE')::text END
  || '; md5=' || left(md5(p.prosrc), 8)
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.prokind = 'f'

-- Spúšťače na tabuľkách v schéme public.
UNION ALL SELECT '05_spustace', c.relname || '.' || t.tgname,
  CASE t.tgenabled WHEN 'O' THEN 'zapnuty' WHEN 'D' THEN 'VYPNUTY' ELSE t.tgenabled::text END
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE NOT t.tgisinternal AND n.nspname = 'public'

-- Pravidlá RLS (len názov, príkaz a rola, nie podmienky).
UNION ALL SELECT '06_pravidla_rls', pp.tablename || '.' || pp.policyname, pp.cmd || ' pre ' || array_to_string(pp.roles, ',')
  FROM pg_policies pp WHERE pp.schemaname = 'public'

-- Organizácie: jeden riadok na organizáciu. Identifikátor sa hodí pre purge_organization, názov je názov firmy.
UNION ALL SELECT '07_organizacie', o.id::text || ' ' || o.name,
  'is_test=' || coalesce(o.is_test, 'stlpec chyba')
  || '; vytvorena=' || to_char(o.created_at AT TIME ZONE 'Europe/Bratislava', 'YYYY-MM-DD HH24:MI')
  || '; ucty=' || (SELECT count(*) FROM public.profiles p WHERE p.organization_id = o.id)
  || '; admin=' || (SELECT count(*) FROM public.user_roles r JOIN public.profiles p ON p.id = r.user_id WHERE p.organization_id = o.id AND r.role = 'admin')
  || '; manager=' || (SELECT count(*) FROM public.user_roles r JOIN public.profiles p ON p.id = r.user_id WHERE p.organization_id = o.id AND r.role = 'manager')
  || '; razenia=' || (SELECT count(*) FROM public.punches x JOIN public.profiles p ON p.id = x.user_id WHERE p.organization_id = o.id)
  || '; zneplatnene=' || (SELECT count(*) FROM public.punches x JOIN public.profiles p ON p.id = x.user_id WHERE p.organization_id = o.id AND to_jsonb(x) ->> 'voided_at' IS NOT NULL)
  || '; posledne_razenie=' || coalesce((SELECT to_char(max(x.server_time) AT TIME ZONE 'Europe/Bratislava', 'YYYY-MM-DD HH24:MI') FROM public.punches x JOIN public.profiles p ON p.id = x.user_id WHERE p.organization_id = o.id), '-')
  || '; zariadenia=' || coalesce((SELECT string_agg(z.s || ':' || z.c, ',' ORDER BY z.s) FROM (SELECT d.status::text AS s, count(*) AS c FROM public.devices d WHERE d.organization_id = o.id GROUP BY d.status) z), '0')
  FROM org o

-- Razenia celkovo (počty, nie obsah).
UNION ALL SELECT '08_razenia', 'celkom', count(*)::text FROM public.punches
UNION ALL SELECT '08_razenia', 'neoverene zariadenie (unverified)', count(*)::text FROM public.punches WHERE device_verification = 'unverified'
UNION ALL SELECT '08_razenia', 'zneplatnene (voided_at)', count(*)::text FROM public.punches x WHERE to_jsonb(x) ->> 'voided_at' IS NOT NULL
UNION ALL SELECT '08_razenia', 'prve a posledne (server_time)',
  coalesce(to_char(min(server_time) AT TIME ZONE 'Europe/Bratislava', 'YYYY-MM-DD HH24:MI') || ' až ' || to_char(max(server_time) AT TIME ZONE 'Europe/Bratislava', 'YYYY-MM-DD HH24:MI'), '-')
  FROM public.punches
UNION ALL SELECT '08_razenia', 'mesiac ' || z.mesiac, z.n::text
  FROM (SELECT to_char(server_time AT TIME ZONE 'Europe/Bratislava', 'YYYY-MM') AS mesiac, count(*) AS n
          FROM public.punches WHERE server_time > now() - interval '12 months' GROUP BY 1) z

-- Audit: len názvy akcií a počty (bez autora, cieľa a podrobností).
UNION ALL SELECT '09_audit', a.action,
  'celkom=' || count(*) || '; 7_dni=' || count(*) FILTER (WHERE a.at > now() - interval '7 days')
  || '; posledny=' || to_char(max(a.at) AT TIME ZONE 'Europe/Bratislava', 'YYYY-MM-DD HH24:MI')
  FROM public.audit_log a GROUP BY a.action

-- Kontroly súvislostí: OK alebo POZOR s počtom záznamov.
UNION ALL SELECT '10_kontroly', k.nazov,
  CASE WHEN k.n IS NULL THEN 'nezistene (bez práva)' WHEN k.n = 0 THEN 'OK' ELSE 'POZOR ' || k.n END
  FROM kontrola k

ORDER BY 1, 2;
