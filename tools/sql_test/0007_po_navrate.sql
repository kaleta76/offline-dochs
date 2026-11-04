-- Kontrola po záchrannom skripte 0007_spat_zachranny.sql (spustený dvakrát: skript musí byť opakovateľný).
SELECT t.ok((SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'public' AND p.proname IN ('delete_test_organization', 'purge_organization', 'test_organization_summary', 'set_organization_test')) = 0, 'funkcie 0007 sú zrušené');
SELECT t.ok((SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'organizations' AND column_name = 'is_test') = 0, 'stĺpec is_test je zrušený');
SELECT t.ok((SELECT prosrc LIKE '%app.purging_organization%' FROM pg_proc WHERE proname = 'guard_last_admin') IS FALSE, 'guard_last_admin je pôvodný');
-- pôvodný guard stále chráni posledného správcu
SELECT t.must_fail('DELETE FROM public.user_roles WHERE user_id = ''01000000-0000-4000-8000-000000000001'' AND role = ''admin''', 'Organizácia musí mať aspoň jedného správcu');
-- údaje pôvodnej organizácie ostali
SELECT t.ok((SELECT count(*) FROM public.organizations) = 1 AND (SELECT count(*) FROM public.profiles) = 1, 'pôvodná organizácia ostala po návrate');
