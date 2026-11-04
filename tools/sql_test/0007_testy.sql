-- Testy migrácie 0007 (spúšťa sa až po nej). Každé zlyhanie ukončí test chybou "TEST ZLYHAL".
\set A1 'a1000000-0000-4000-8000-000000000001'
\set A2 'a2000000-0000-4000-8000-000000000002'
\set B1 'b1000000-0000-4000-8000-000000000001'
\set O1 '01000000-0000-4000-8000-000000000001'
\set ORIG '00000000-0000-4000-8000-000000000001'

SELECT organization_id AS org_a FROM public.profiles WHERE id = :'A1' \gset
SELECT organization_id AS org_b FROM public.profiles WHERE id = :'B1' \gset
SELECT t.fp(:'org_a') AS fp_a_pred, t.fp(:'org_b') AS fp_b_pred, t.fp(:'ORIG') AS fp_o_pred \gset
SELECT count(*) AS punches_pred FROM public.punches \gset
SELECT count(*) AS users_pred FROM auth.users \gset

-- 0. nová organizácia nie je testovacia a pôvodná organizácia je nedotknuteľná
SELECT t.ok((SELECT NOT is_test FROM public.organizations WHERE id = :'org_a'), 'is_test má byť predvolene false');
SELECT t.ok((SELECT NOT is_test FROM public.organizations WHERE id = :'ORIG'), 'pôvodná organizácia nie je testovacia');

-- 1. oprávnenia na funkcie: anon nič, authenticated nesmie volať pracovnú funkciu
SET ROLE anon;
SELECT t.must_fail('SELECT public.delete_test_organization(''x'')', 'permission denied%');
SELECT t.must_fail('SELECT public.set_organization_test(true)', 'permission denied%');
SELECT t.must_fail('SELECT public.test_organization_summary()', 'permission denied%');
SELECT t.must_fail(format('SELECT public.purge_organization(%L)', :'org_a'), 'permission denied%');
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'A1', false);
SELECT t.must_fail(format('SELECT public.purge_organization(%L)', :'org_a'), 'permission denied%');
RESET ROLE;

-- 2. zamestnanec (nie správca) nemôže nič z toho
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'A2', false);
SELECT t.must_fail('SELECT public.set_organization_test(true)', 'Nemáte oprávnenie');
SELECT t.must_fail('SELECT public.test_organization_summary()', 'Nemáte oprávnenie');
SELECT t.must_fail('SELECT public.delete_test_organization(''TEST A'')', 'Nemáte oprávnenie');
RESET ROLE;

-- 3. správca: neoznačenú organizáciu zrušiť nejde, prehľad ukazuje počty
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'A1', false);
SELECT t.must_fail('SELECT public.delete_test_organization(''TEST A'')', 'Zrušiť sa dá len organizácia označená ako testovacia%');
SELECT t.ok((public.test_organization_summary()->>'users')::int = 3, 'prehľad: 3 používatelia');
SELECT t.ok((public.test_organization_summary()->>'punches')::int = 4, 'prehľad: 4 razenia');
SELECT t.ok((public.test_organization_summary()->>'devices')::int = 3, 'prehľad: 3 zariadenia');
SELECT t.ok((public.test_organization_summary()->>'is_test')::boolean = false, 'prehľad: nie je testovacia');
SELECT t.ok((public.test_organization_summary()->>'name') = 'TEST A', 'prehľad: názov');
-- bežná ochrana posledného správcu ostáva v platnosti
SELECT t.must_fail(format('DELETE FROM public.user_roles WHERE user_id = %L AND role = ''admin''', :'A1'), 'Organizácia musí mať aspoň jedného správcu');
RESET ROLE;

-- 4. označenie ako testovacia: iba vlastná organizácia, B ostáva nedotknutá
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'A1', false);
SELECT public.set_organization_test(true);
SELECT public.set_organization_test(true);
RESET ROLE;
SELECT t.ok((SELECT is_test FROM public.organizations WHERE id = :'org_a'), 'A má byť testovacia');
SELECT t.ok((SELECT NOT is_test FROM public.organizations WHERE id = :'org_b'), 'B nesmie byť testovacia');
SELECT t.ok((SELECT count(*) FROM public.audit_log WHERE action = 'organization.test_flag' AND target = :'org_a') = 1, 'zmena príznaku sa zapíše do auditu iba raz');

-- 5. zlý názov
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'A1', false);
SELECT t.must_fail('SELECT public.delete_test_organization(''test a'')', 'Názov organizácie sa nezhoduje');
SELECT t.must_fail('SELECT public.delete_test_organization('''')', 'Názov organizácie sa nezhoduje');
SELECT t.must_fail('SELECT public.delete_test_organization(NULL)', 'Názov organizácie sa nezhoduje');
RESET ROLE;
SELECT t.ok((SELECT count(*) FROM public.organizations WHERE id = :'org_a') = 1, 'po zlom názve sa nič nezmazalo');

-- 6. pôvodná organizácia: nedá sa označiť, ani keď ju niekto označí cez databázu, nedá sa zrušiť
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'O1', false);
SELECT t.must_fail('SELECT public.set_organization_test(true)', 'Pôvodnú organizáciu nemožno označiť ako testovaciu');
RESET ROLE;
UPDATE public.organizations SET is_test = true WHERE id = :'ORIG';
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'O1', false);
SELECT t.must_fail('SELECT public.delete_test_organization(''Pôvodná organizácia'')', 'Pôvodnú organizáciu nemožno zrušiť');
RESET ROLE;
SELECT t.must_fail(format('SELECT public.purge_organization(%L)', :'ORIG'), 'Pôvodnú organizáciu nemožno zrušiť');
UPDATE public.organizations SET is_test = false WHERE id = :'ORIG';

-- 7. neoznačená cudzia organizácia sa nedá zrušiť ani pracovnou funkciou
SELECT t.must_fail(format('SELECT public.purge_organization(%L)', :'org_b'), 'Zrušiť sa dá len organizácia označená ako testovacia');
SELECT t.must_fail('SELECT public.purge_organization(gen_random_uuid())', 'Organizácia neexistuje');

-- 8. zrušenie testovacej organizácie správcom
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'A1', false);
SELECT public.delete_test_organization('TEST A') AS vysledok \gset
RESET ROLE;
SELECT t.ok((:'vysledok'::jsonb->>'users')::int = 3, 'výsledok: 3 používatelia');
SELECT t.ok((:'vysledok'::jsonb->>'punches')::int = 4, 'výsledok: 4 razenia');
SELECT t.ok((:'vysledok'::jsonb->>'devices')::int = 3, 'výsledok: 3 zariadenia');
SELECT t.ok((SELECT count(*) FROM public.organizations WHERE id = :'org_a') = 0, 'organizácia A je zrušená');
SELECT t.ok((SELECT count(*) FROM public.profiles WHERE organization_id = :'org_a') = 0, 'profily A sú zrušené');
SELECT t.ok((SELECT count(*) FROM auth.users WHERE email IN ('a1@test', 'a2@test', 'a3@test')) = 0, 'prihlasovacie účty A sú zrušené');
SELECT t.ok((SELECT count(*) FROM auth.identities i WHERE NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = i.user_id)) = 0, 'identity A sú zrušené (cascade)');
SELECT t.ok((SELECT count(*) FROM auth.sessions) = 3, 'relácie A sú zrušené, ostali relácie B1, B2 a O1');
SELECT t.ok((SELECT count(*) FROM public.user_roles r WHERE NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = r.user_id)) = 0, 'v user_roles nie sú siroty');
SELECT t.ok((SELECT count(*) FROM public.punches WHERE user_id IN (:'A1', :'A2', 'a3000000-0000-4000-8000-000000000003')) = 0, 'razenia A sú zrušené');
SELECT t.ok((SELECT count(*) FROM public.devices WHERE user_id IN (:'A1', :'A2', 'a3000000-0000-4000-8000-000000000003')) = 0, 'zariadenia A sú zrušené');
SELECT t.ok((SELECT count(*) FROM public.punch_void_requests WHERE user_id IN (:'A1', :'A2', 'a3000000-0000-4000-8000-000000000003')) = 0, 'žiadosti A sú zrušené');
SELECT t.ok((SELECT count(*) FROM public.corrections WHERE user_id = :'A2') = 0 AND (SELECT count(*) FROM public.month_closures WHERE user_id = :'A2') = 0 AND
            (SELECT count(*) FROM public.personnel_requests WHERE user_id = :'A2') = 0 AND (SELECT count(*) FROM public.notification_preferences WHERE user_id = :'A1') = 0, 'opravy, uzávierky, žiadosti a upozornenia A sú zrušené');
SELECT t.ok((SELECT count(*) FROM public.organization_settings WHERE organization_id = :'org_a') + (SELECT count(*) FROM public.organization_codes WHERE organization_id = :'org_a') +
            (SELECT count(*) FROM public.organization_holidays WHERE organization_id = :'org_a') + (SELECT count(*) FROM public.organization_invites WHERE organization_id = :'org_a') = 0, 'nastavenia A sú zrušené');
SELECT t.ok((SELECT count(*) FROM public.audit_log WHERE actor IN (:'A1', :'A2', 'a3000000-0000-4000-8000-000000000003')) = 1 AND
            (SELECT count(*) FROM public.audit_log WHERE action = 'organization.deleted' AND target = :'org_a' AND actor = :'A1') = 1, 'z auditu A ostal len záznam o zrušení');
SELECT t.ok((SELECT details->>'name' = 'TEST A' AND (details->>'users')::int = 3 AND (details->>'punches')::int = 4 FROM public.audit_log WHERE action = 'organization.deleted' AND target = :'org_a'), 'záznam o zrušení obsahuje názov a počty');
SELECT t.ok((SELECT count(*) FROM public.audit_log WHERE action = 'test.bez_aktora') = 1, 'záznam bez aktora ostal');
-- cudzie organizácie sú bajt po bajte rovnaké
SELECT t.ok(t.fp(:'org_b') = :'fp_b_pred', 'organizácia B sa nezmenila');
SELECT t.ok(t.fp(:'ORIG') = :'fp_o_pred', 'pôvodná organizácia sa nezmenila');
SELECT t.ok((SELECT count(*) FROM public.punches) = :punches_pred - 4, 'celkový počet razení klesol presne o 4');
SELECT t.ok((SELECT count(*) FROM auth.users) = :users_pred - 3, 'celkový počet účtov klesol presne o 3');
SELECT t.ok(COALESCE(current_setting('app.purging_organization', true), '') = '', 'príznak rušenia sa po transakcii nezachoval');

-- 9. po zrušení platí ochrana posledného správcu opäť (B má jediného správcu)
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'B1', false);
SELECT t.must_fail(format('DELETE FROM public.user_roles WHERE user_id = %L AND role = ''admin''', :'B1'), 'Organizácia musí mať aspoň jedného správcu');
RESET ROLE;

-- 10. ručné zrušenie zo SQL editora (bez prihlásenia): najprv označiť, potom purge_organization
SELECT set_config('request.jwt.claim.sub', '', false);
SELECT t.must_fail(format('SELECT public.purge_organization(%L)', :'org_b'), 'Zrušiť sa dá len organizácia označená ako testovacia');
UPDATE public.organizations SET is_test = true WHERE id = :'org_b';
SELECT public.purge_organization(:'org_b') AS vysledok_b \gset
SELECT t.ok((:'vysledok_b'::jsonb->>'users')::int = 2 AND (:'vysledok_b'::jsonb->>'punches')::int = 2, 'ručné zrušenie B: 2 používatelia a 2 razenia');
SELECT t.ok((SELECT count(*) FROM public.organizations WHERE id = :'org_b') = 0, 'organizácia B je zrušená');
SELECT t.ok((SELECT count(*) FROM auth.users WHERE email IN ('b1@test', 'b2@test')) = 0, 'účty B sú zrušené');
SELECT t.ok(t.fp(:'ORIG') = :'fp_o_pred', 'pôvodná organizácia sa nezmenila ani po druhom zrušení');
SELECT t.ok((SELECT count(*) FROM public.audit_log WHERE action = 'organization.deleted' AND target = :'org_b' AND actor IS NULL) = 1, 'ručné zrušenie zapísalo záznam bez aktora');
SELECT t.ok((SELECT count(*) FROM public.organizations) = 1, 'ostala len pôvodná organizácia');
