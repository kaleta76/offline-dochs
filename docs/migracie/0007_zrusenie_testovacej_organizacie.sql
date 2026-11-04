-- 0007: testovacia organizácia – označenie a zrušenie.
--
-- Správca môže svoju organizáciu označiť ako testovaciu a potom ju natrvalo zrušiť (obrazovka Správa → Testovacia organizácia).
-- Zrušenie zmaže aj razenia, zariadenia, nastavenia, zamestnancov a ich prihlasovacie účty. Je NEVRATNÉ (vráti ho len obnova zálohy).
-- Ochrany:
--   * zrušiť sa dá LEN organizácia, ktorú správca predtým označil ako testovaciu (is_test),
--   * "Pôvodná organizácia" (z migrácie 0002, id 00000000-0000-4000-8000-000000000001) sa nedá označiť ani zrušiť,
--   * správca musí napísať presný názov organizácie,
--   * správca môže zrušiť iba vlastnú organizáciu, cudzie nevidí ani nezmení,
--   * všetko prebehne v jednej transakcii: pri chybe sa nezmení nič.
-- Výnimka z pravidla "razenia sa nemažú" platí výlučne pre takto označenú testovaciu organizáciu. Hash reťaz (punches_chain) sa nemení.
-- Pred spustením urobte zálohu: docs/ZALOHA-DATABAZY.md. Návrat: docs/migracie/0007_spat_zachranny.sql.

ALTER TABLE public.organizations ADD COLUMN is_test boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.organizations.is_test IS 'Testovacia organizácia: smie ju zrušiť jej správca (delete_test_organization). Nastavuje len set_organization_test.';

-- Posledný správca sa nesmie odstrániť, okrem zrušenia celej testovacej organizácie (nastaví ho purge_organization len v rámci svojej transakcie).
CREATE OR REPLACE FUNCTION public.guard_last_admin() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ DECLARE org uuid; BEGIN IF OLD.role='admin' THEN SELECT organization_id INTO org FROM public.profiles WHERE id=OLD.user_id; IF org IS NOT NULL AND COALESCE(current_setting('app.purging_organization', true), '') = org::text THEN RETURN OLD; END IF; PERFORM pg_advisory_xact_lock(hashtext(org::text)); IF NOT EXISTS(SELECT 1 FROM public.user_roles r JOIN public.profiles p ON p.id=r.user_id WHERE r.role='admin' AND p.organization_id=org AND r.id<>OLD.id) THEN RAISE EXCEPTION 'Organizácia musí mať aspoň jedného správcu'; END IF; END IF; RETURN OLD; END $$;

-- Označenie vlastnej organizácie ako testovacej (a späť).
CREATE OR REPLACE FUNCTION public.set_organization_test(_is_test boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE org uuid := public.my_organization();
BEGIN
  IF auth.uid() IS NULL OR org IS NULL THEN RAISE EXCEPTION 'Prihlásenie je potrebné'; END IF;
  IF NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Nemáte oprávnenie'; END IF;
  IF _is_test IS NULL THEN RAISE EXCEPTION 'Neplatná hodnota'; END IF;
  IF _is_test AND org = '00000000-0000-4000-8000-000000000001' THEN
    RAISE EXCEPTION 'Pôvodnú organizáciu nemožno označiť ako testovaciu';
  END IF;
  UPDATE public.organizations SET is_test = _is_test WHERE id = org AND is_test <> _is_test;
  IF FOUND THEN
    INSERT INTO public.audit_log (actor, action, target, details)
    VALUES (auth.uid(), 'organization.test_flag', org::text, jsonb_build_object('is_test', _is_test));
  END IF;
END $$;

-- Čo sa zruší: počty pre potvrdzovaciu obrazovku (iba správca vlastnej organizácie).
CREATE OR REPLACE FUNCTION public.test_organization_summary() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE org public.organizations;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Prihlásenie je potrebné'; END IF;
  SELECT o.* INTO org FROM public.organizations o WHERE o.id = public.my_organization();
  IF org.id IS NULL THEN RAISE EXCEPTION 'Organizácia neexistuje'; END IF;
  IF NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Nemáte oprávnenie'; END IF;
  RETURN jsonb_build_object(
    'name', org.name,
    'is_test', org.is_test,
    'protected', org.id = '00000000-0000-4000-8000-000000000001',
    'users', (SELECT count(*) FROM public.profiles WHERE organization_id = org.id),
    'punches', (SELECT count(*) FROM public.punches x JOIN public.profiles p ON p.id = x.user_id WHERE p.organization_id = org.id),
    'devices', (SELECT count(*) FROM public.devices WHERE organization_id = org.id)
  );
END $$;

-- Pracovná funkcia: zmaže organizáciu a všetko, čo jej patrí. NEMÁ kontrolu oprávnení, preto ju nemôže volať používateľ aplikácie
-- (len správca databázy z SQL editora alebo delete_test_organization). Odmietne neoznačenú a pôvodnú organizáciu.
CREATE OR REPLACE FUNCTION public.purge_organization(_org uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  org public.organizations;
  members uuid[];
  n_users int; n_punches bigint; n_devices int;
BEGIN
  SELECT o.* INTO org FROM public.organizations o WHERE o.id = _org FOR UPDATE;
  IF org.id IS NULL THEN RAISE EXCEPTION 'Organizácia neexistuje'; END IF;
  IF org.id = '00000000-0000-4000-8000-000000000001' THEN RAISE EXCEPTION 'Pôvodnú organizáciu nemožno zrušiť'; END IF;
  IF NOT org.is_test THEN RAISE EXCEPTION 'Zrušiť sa dá len organizácia označená ako testovacia'; END IF;
  -- Funkcia patrí vlastníkovi migrácie. Ak by ten nesmel mazať prihlasovacie účty, zlyhá hneď na začiatku a nič sa nezmení.
  IF NOT has_table_privilege('auth.users', 'DELETE') THEN
    RAISE EXCEPTION 'Databáza nedovoľuje mazať prihlasovacie účty (auth.users). Organizáciu nemožno zrušiť.';
  END IF;

  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO members FROM public.profiles WHERE organization_id = org.id;
  n_users := COALESCE(array_length(members, 1), 0);
  SELECT count(*) INTO n_punches FROM public.punches WHERE user_id = ANY(members);
  SELECT count(*) INTO n_devices FROM public.devices WHERE organization_id = org.id;

  -- Len v tejto transakcii: guard_last_admin dovolí odstrániť aj posledného správcu rušenej organizácie.
  PERFORM set_config('app.purging_organization', org.id::text, true);

  DELETE FROM public.punch_void_requests WHERE user_id = ANY(members);
  DELETE FROM public.punches WHERE user_id = ANY(members);
  DELETE FROM public.corrections WHERE user_id = ANY(members);
  DELETE FROM public.month_closures WHERE user_id = ANY(members);
  DELETE FROM public.personnel_requests WHERE user_id = ANY(members);
  DELETE FROM public.notification_preferences WHERE user_id = ANY(members);
  DELETE FROM public.devices WHERE organization_id = org.id;
  DELETE FROM public.organization_invites WHERE organization_id = org.id;
  DELETE FROM public.organization_settings WHERE organization_id = org.id;
  DELETE FROM public.organization_codes WHERE organization_id = org.id;
  DELETE FROM public.organization_holidays WHERE organization_id = org.id;
  DELETE FROM public.user_roles WHERE user_id = ANY(members);
  DELETE FROM public.profiles WHERE organization_id = org.id;
  DELETE FROM public.organizations WHERE id = org.id;
  -- Záznamy auditu, ktoré vyrobili účty tejto organizácie (vrátane tých, čo vznikli pri tomto mazaní).
  DELETE FROM public.audit_log WHERE actor = ANY(members);
  -- Prihlasovacie účty (cascade zmaže aj ich relácie a identity).
  DELETE FROM auth.users WHERE id = ANY(members);

  PERFORM set_config('app.purging_organization', '', true);

  INSERT INTO public.audit_log (actor, action, target, details)
  VALUES (auth.uid(), 'organization.deleted', org.id::text,
          jsonb_build_object('name', org.name, 'users', n_users, 'punches', n_punches, 'devices', n_devices));
  RETURN jsonb_build_object('name', org.name, 'users', n_users, 'punches', n_punches, 'devices', n_devices);
END $$;

-- Zrušenie vlastnej testovacej organizácie správcom (volá obrazovka Správa).
CREATE OR REPLACE FUNCTION public.delete_test_organization(_confirm_name text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE org public.organizations;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Prihlásenie je potrebné'; END IF;
  SELECT o.* INTO org FROM public.organizations o WHERE o.id = public.my_organization();
  IF org.id IS NULL THEN RAISE EXCEPTION 'Organizácia neexistuje'; END IF;
  IF NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Nemáte oprávnenie'; END IF;
  IF org.id = '00000000-0000-4000-8000-000000000001' THEN RAISE EXCEPTION 'Pôvodnú organizáciu nemožno zrušiť'; END IF;
  IF NOT org.is_test THEN RAISE EXCEPTION 'Zrušiť sa dá len organizácia označená ako testovacia'; END IF;
  IF btrim(COALESCE(_confirm_name, '')) <> btrim(org.name) THEN RAISE EXCEPTION 'Názov organizácie sa nezhoduje'; END IF;
  RETURN public.purge_organization(org.id);
END $$;

REVOKE ALL ON FUNCTION public.set_organization_test(boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.test_organization_summary() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.delete_test_organization(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.purge_organization(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_organization_test(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.test_organization_summary() TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_test_organization(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.purge_organization(uuid) TO service_role;
