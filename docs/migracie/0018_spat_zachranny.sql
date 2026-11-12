-- 0018 SPÄŤ: vráti purge_organization do znenia z migrácie 0007 (záznam „organization.deleted“ s účtom, ktorý zrušenie urobil).
-- Záznamy, ktoré sa medzitým zapísali s actor = NULL, ostávajú. Skript je opakovateľný.

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

REVOKE ALL ON FUNCTION public.purge_organization(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_organization(uuid) TO service_role;
