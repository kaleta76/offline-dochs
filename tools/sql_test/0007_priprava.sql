-- Príprava pred migráciou 0007: pomocné funkcie a údaje troch organizácií (A = bude zrušená, B a pôvodná = nesmú sa zmeniť).
CREATE SCHEMA t;
GRANT USAGE ON SCHEMA t TO PUBLIC;

CREATE FUNCTION t.ok(cond boolean, msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'TEST ZLYHAL: %', msg; END IF; END $$;

-- Príkaz musí zlyhať s chybou zodpovedajúcou vzoru (LIKE).
CREATE FUNCTION t.must_fail(q text, pat text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE q;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE pat THEN RETURN; END IF;
    RAISE EXCEPTION 'TEST ZLYHAL: [%] zlyhal s inou chybou: %', q, SQLERRM;
  END;
  RAISE EXCEPTION 'TEST ZLYHAL: [%] malo zlyhať', q;
END $$;
GRANT EXECUTE ON FUNCTION t.ok(boolean, text), t.must_fail(text, text) TO PUBLIC;

-- Odtlačok všetkých údajov jednej organizácie (na dôkaz, že cudzia organizácia ostala nedotknutá).
CREATE FUNCTION t.fp(org uuid) RETURNS text LANGUAGE sql AS $$
  SELECT md5(concat_ws('|',
    (SELECT string_agg(p::text, ',' ORDER BY p.id) FROM public.profiles p WHERE p.organization_id = org),
    (SELECT string_agg(r::text, ',' ORDER BY r.id) FROM public.user_roles r JOIN public.profiles p ON p.id = r.user_id WHERE p.organization_id = org),
    (SELECT string_agg(x::text, ',' ORDER BY x.id) FROM public.punches x JOIN public.profiles p ON p.id = x.user_id WHERE p.organization_id = org),
    (SELECT string_agg(d::text, ',' ORDER BY d.id) FROM public.devices d WHERE d.organization_id = org),
    (SELECT string_agg(v::text, ',' ORDER BY v.id) FROM public.punch_void_requests v JOIN public.profiles p ON p.id = v.user_id WHERE p.organization_id = org),
    (SELECT string_agg(c::text, ',' ORDER BY c.id) FROM public.corrections c JOIN public.profiles p ON p.id = c.user_id WHERE p.organization_id = org),
    (SELECT string_agg(m::text, ',' ORDER BY m.user_id, m.year, m.month) FROM public.month_closures m JOIN public.profiles p ON p.id = m.user_id WHERE p.organization_id = org),
    (SELECT string_agg(q::text, ',' ORDER BY q.id) FROM public.personnel_requests q JOIN public.profiles p ON p.id = q.user_id WHERE p.organization_id = org),
    (SELECT string_agg(n::text, ',' ORDER BY n.user_id) FROM public.notification_preferences n JOIN public.profiles p ON p.id = n.user_id WHERE p.organization_id = org),
    (SELECT string_agg(i::text, ',' ORDER BY i.organization_id) FROM public.organization_invites i WHERE i.organization_id = org),
    (SELECT string_agg(s::text, ',' ORDER BY s.key) FROM public.organization_settings s WHERE s.organization_id = org),
    (SELECT string_agg(c::text, ',' ORDER BY c.code) FROM public.organization_codes c WHERE c.organization_id = org),
    (SELECT string_agg(h::text, ',' ORDER BY h.day) FROM public.organization_holidays h WHERE h.organization_id = org),
    (SELECT string_agg(a::text, ',' ORDER BY a.id) FROM public.audit_log a JOIN public.profiles p ON p.id = a.actor WHERE p.organization_id = org),
    (SELECT string_agg(u.id::text, ',' ORDER BY u.id) FROM auth.users u JOIN public.profiles p ON p.id = u.id WHERE p.organization_id = org)
  ))
$$;

-- Organizácia A (testovacia, bude zrušená): správca A1, zamestnanci A2, A3.
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('a1000000-0000-4000-8000-000000000001', 'a1@test', '{"organization_name":"TEST A","sap_id":"9000001"}');
SELECT code AS inv_a FROM public.organization_invites WHERE organization_id = (SELECT organization_id FROM public.profiles WHERE id = 'a1000000-0000-4000-8000-000000000001') \gset
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('a2000000-0000-4000-8000-000000000002', 'a2@test', jsonb_build_object('invite_code', :'inv_a', 'sap_id', '9000002')),
  ('a3000000-0000-4000-8000-000000000003', 'a3@test', jsonb_build_object('invite_code', :'inv_a', 'sap_id', '9000003'));

-- Organizácia B (cudzia, rovnaké osobné čísla ako A, nesmie sa zmeniť): správca B1, zamestnanec B2.
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('b1000000-0000-4000-8000-000000000001', 'b1@test', '{"organization_name":"ORG B","sap_id":"9000001"}');
SELECT code AS inv_b FROM public.organization_invites WHERE organization_id = (SELECT organization_id FROM public.profiles WHERE id = 'b1000000-0000-4000-8000-000000000001') \gset
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('b2000000-0000-4000-8000-000000000002', 'b2@test', jsonb_build_object('invite_code', :'inv_b', 'sap_id', '9000002'));

-- Pôvodná organizácia (chránená): jeden správca O1.
INSERT INTO public.organizations (id, name) VALUES ('00000000-0000-4000-8000-000000000001', 'Pôvodná organizácia');
INSERT INTO public.organization_settings SELECT '00000000-0000-4000-8000-000000000001', s.* FROM public.settings s;
INSERT INTO public.organization_codes SELECT '00000000-0000-4000-8000-000000000001', c.* FROM public.absence_codes c;
INSERT INTO public.organization_holidays SELECT '00000000-0000-4000-8000-000000000001', h.* FROM public.holidays h;
INSERT INTO public.organization_invites (organization_id) VALUES ('00000000-0000-4000-8000-000000000001');
SELECT code AS inv_o FROM public.organization_invites WHERE organization_id = '00000000-0000-4000-8000-000000000001' \gset
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('01000000-0000-4000-8000-000000000001', 'o1@test', jsonb_build_object('invite_code', :'inv_o', 'sap_id', '4002012'));
INSERT INTO public.user_roles (user_id, role) VALUES ('01000000-0000-4000-8000-000000000001', 'admin'), ('01000000-0000-4000-8000-000000000001', 'manager');
-- Prihlasovacie relácie a identity všetkých účtov (zrušením účtu musia zaniknúť cez cascade).
INSERT INTO auth.identities (user_id) SELECT id FROM auth.users;
INSERT INTO auth.sessions (user_id) SELECT id FROM auth.users;

-- Vzťahy a údaje: nadriadený, razenia (aj s overeným zariadením), zariadenia, žiadosť o zneplatnenie (až po migrácii 0006 existuje tabuľka),
-- oprava, uzávierka, žiadosť o osobné číslo, upozornenia, záznamy auditu.
UPDATE public.profiles SET manager_id = 'a1000000-0000-4000-8000-000000000001' WHERE id IN ('a2000000-0000-4000-8000-000000000002', 'a3000000-0000-4000-8000-000000000003');
UPDATE public.profiles SET manager_id = 'b1000000-0000-4000-8000-000000000001' WHERE id = 'b2000000-0000-4000-8000-000000000002';

INSERT INTO public.devices (user_id, organization_id, device_token_hash, status, approved_by, approved_at)
VALUES ('a2000000-0000-4000-8000-000000000002', (SELECT organization_id FROM public.profiles WHERE id = 'a2000000-0000-4000-8000-000000000002'),
        encode(sha256(convert_to(repeat('a', 64), 'UTF8')), 'hex'), 'active', 'a1000000-0000-4000-8000-000000000001', now());
INSERT INTO public.devices (user_id, organization_id, device_token_hash, status)
VALUES ('a3000000-0000-4000-8000-000000000003', (SELECT organization_id FROM public.profiles WHERE id = 'a3000000-0000-4000-8000-000000000003'),
        encode(sha256(convert_to(repeat('c', 64), 'UTF8')), 'hex'), 'pending');
INSERT INTO public.devices (user_id, organization_id, device_token_hash, status, replaces_device_id)
SELECT 'a3000000-0000-4000-8000-000000000003', d.organization_id, encode(sha256(convert_to(repeat('d', 64), 'UTF8')), 'hex'), 'pending', d.id
  FROM public.devices d WHERE d.user_id = 'a2000000-0000-4000-8000-000000000002';
INSERT INTO public.devices (user_id, organization_id, device_token_hash, status, approved_by, approved_at)
VALUES ('b2000000-0000-4000-8000-000000000002', (SELECT organization_id FROM public.profiles WHERE id = 'b2000000-0000-4000-8000-000000000002'),
        encode(sha256(convert_to(repeat('b', 64), 'UTF8')), 'hex'), 'active', 'b1000000-0000-4000-8000-000000000001', now());

INSERT INTO public.punches (client_uuid, user_id, code, direction, client_time, device_token) VALUES
  (gen_random_uuid(), 'a2000000-0000-4000-8000-000000000002', 'WORK', 'IN',  now() - interval '3 hours', repeat('a', 64)),
  (gen_random_uuid(), 'a2000000-0000-4000-8000-000000000002', 'WORK', 'OUT', now() - interval '2 hours', repeat('a', 64)),
  (gen_random_uuid(), 'a3000000-0000-4000-8000-000000000003', 'WORK', 'IN',  now() - interval '3 hours', NULL),
  (gen_random_uuid(), 'a1000000-0000-4000-8000-000000000001', 'WORK', 'IN',  now() - interval '3 hours', NULL),
  (gen_random_uuid(), 'b2000000-0000-4000-8000-000000000002', 'WORK', 'IN',  now() - interval '3 hours', repeat('b', 64)),
  (gen_random_uuid(), 'b2000000-0000-4000-8000-000000000002', 'WORK', 'OUT', now() - interval '1 hours', repeat('b', 64)),
  (gen_random_uuid(), '01000000-0000-4000-8000-000000000001', 'WORK', 'IN',  now() - interval '3 hours', NULL);

INSERT INTO public.punch_void_requests (punch_id, user_id, requested_by, reason)
SELECT id, user_id, user_id, 'Omylom' FROM public.punches WHERE user_id IN ('a2000000-0000-4000-8000-000000000002', 'b2000000-0000-4000-8000-000000000002') AND direction = 'IN';
INSERT INTO public.corrections (user_id, code, direction, at_time, reason) VALUES
  ('a2000000-0000-4000-8000-000000000002', 'WORK', 'OUT', now() - interval '30 minutes', 'Zabudol som odpípať'),
  ('b2000000-0000-4000-8000-000000000002', 'WORK', 'OUT', now() - interval '30 minutes', 'Zabudol som odpípať');
INSERT INTO public.month_closures (user_id, year, month, closed_by) VALUES
  ('a2000000-0000-4000-8000-000000000002', 2020, 1, 'a1000000-0000-4000-8000-000000000001'),
  ('b2000000-0000-4000-8000-000000000002', 2020, 1, 'b1000000-0000-4000-8000-000000000001');
INSERT INTO public.personnel_requests (user_id, requested_number) VALUES
  ('a2000000-0000-4000-8000-000000000002', '9100002'), ('b2000000-0000-4000-8000-000000000002', '9100002');
INSERT INTO public.notification_preferences (user_id, new_devices) VALUES
  ('a1000000-0000-4000-8000-000000000001', true), ('b1000000-0000-4000-8000-000000000001', true);
INSERT INTO public.audit_log (actor, action, target) VALUES
  ('a1000000-0000-4000-8000-000000000001', 'test.a1', NULL), ('a2000000-0000-4000-8000-000000000002', 'test.a2', NULL),
  ('b1000000-0000-4000-8000-000000000001', 'test.b1', NULL), (NULL, 'test.bez_aktora', NULL);

-- Kontrola prípravy: A má 3 používateľov, B 2, pôvodná 1; razenia A2 sú overené zariadením.
SELECT t.ok((SELECT count(*) FROM public.profiles WHERE organization_id = (SELECT organization_id FROM public.profiles WHERE id = 'a1000000-0000-4000-8000-000000000001')) = 3, 'A má mať 3 profily');
SELECT t.ok((SELECT count(*) FROM public.punches WHERE user_id = 'a2000000-0000-4000-8000-000000000002' AND device_verification = 'verified' AND device_id IS NOT NULL) = 2, 'razenia A2 majú byť overené zariadením');
SELECT t.ok((SELECT count(*) FROM public.user_roles WHERE role = 'admin') = 3, 'traja správcovia (A1, B1, O1)');
