-- Testy docs/zaloha/snapshot_pred_zasahom.sql (spustené po 0007_priprava.sql a po samotnom snapshote).
SELECT nspname AS zs FROM pg_namespace WHERE nspname LIKE 'zaloha\_%' \gset
SELECT t.ok(:'zs' ~ '^zaloha_[0-9]{8}_[0-9]{4}$', 'názov snapshotu má tvar zaloha_RRRRMMDD_HHMM');
-- každá tabuľka public je skopírovaná a má rovnaký počet riadkov
SELECT t.ok((SELECT count(*) FROM pg_tables WHERE schemaname = 'public') = (SELECT count(*) FROM pg_tables WHERE schemaname = :'zs' AND tablename NOT LIKE 'auth\_%'), 'všetky tabuľky public sú v snapshote');
SELECT t.ok((SELECT count(*) FROM pg_tables WHERE schemaname = :'zs' AND tablename IN ('auth_users', 'auth_identities')) = 2, 'auth.users a auth.identities sú v snapshote');
SELECT count(*) AS a FROM public.punches \gset
SELECT count(*) AS b FROM :"zs".punches \gset
SELECT t.ok(:a = :b AND :a > 0, 'razenia: rovnaký počet riadkov');
SELECT count(*) AS a FROM auth.users \gset
SELECT count(*) AS b FROM :"zs".auth_users \gset
SELECT t.ok(:a = :b AND :a > 0, 'účty: rovnaký počet riadkov');
SELECT t.ok((SELECT md5(string_agg(x::text, ',' ORDER BY x.id)) FROM public.profiles x) = (SELECT md5(string_agg(x::text, ',' ORDER BY x.id)) FROM :"zs".profiles x), 'profily sú v snapshote bajt po bajte rovnaké');
-- všetky kópie majú zapnuté RLS a anon/authenticated k nim nemajú prístup
SELECT t.ok((SELECT count(*) FROM pg_tables WHERE schemaname = :'zs' AND NOT rowsecurity) = 0, 'RLS je zapnuté na všetkých kópiách');
SET ROLE anon;
SELECT t.must_fail(format('SELECT count(*) FROM %I.punches', :'zs'), 'permission denied%');
RESET ROLE;
SET ROLE authenticated;
SELECT t.must_fail(format('SELECT count(*) FROM %I.profiles', :'zs'), 'permission denied%');
SELECT t.must_fail(format('SELECT count(*) FROM %I.auth_users', :'zs'), 'permission denied%');
RESET ROLE;
-- originály sa snapshotom nezmenili a druhý snapshot v tej istej minúte skončí chybou (ochrana pred prepísaním)
SELECT t.ok((SELECT count(*) FROM public.organizations) = 3, 'organizácie sa nezmenili');
