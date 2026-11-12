-- 0018: zrušenie organizácie nenecháva v audite záznam s id zaniknutého účtu.
--
-- Problém: purge_organization (zrušenie testovacej organizácie, aj po prenose na iný server) zapisovala záznam „organization.deleted“
-- s actor = auth.uid(), teda s účtom správcu, ktorý práve zrušenú organizáciu zrušil a ktorý týmto zanikol. Záznam ostal s id neexistujúceho
-- účtu. Keď sa tá istá organizácia (s tými istými id účtov) potom importovala späť, záznam patril obnovenému účtu a overenie prenosu
-- hlásilo o jeden riadok auditu viac. Import (migrácia 0017, balík 0015 v1.2) si s tým poradí sám, tu je oprava pri zdroji.
--
-- Oprava: ak je volajúci členom rušenej organizácie, záznam má actor = NULL a jeho id je v details.by (rovnaký tvar ako pri importe:
-- details.actor_pred_importom). Zrušenie z SQL editora (auth.uid() je NULL) sa nemení.
-- Čo sa NEMENÍ: oprávnenia, ochrany (len testovacia, nie pôvodná organizácia), rozsah mazania, výsledok funkcie. Staré záznamy v audite sa
-- nemenia. Funkcia je opakovateľná. Návrat: docs/migracie/0018_spat_zachranny.sql. Predpoklad: migrácia 0007.

DO $$ BEGIN
  IF to_regprocedure('public.purge_organization(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Najprv spustite migráciu 0007 (zrušenie testovacej organizácie).';
  END IF;
END $$;

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

  -- Záznam o zrušení: ak ho zrušil správca rušenej organizácie, jeho účet práve zanikol, preto sa záznam nesmie viazať na jeho id
  -- (po novom importe tej istej organizácie by patril obnovenému účtu a rozbil by počet riadkov auditu pri overení prenosu).
  -- Kto zrušenie urobil, ostáva v details.by.
  INSERT INTO public.audit_log (actor, action, target, details)
  VALUES (CASE WHEN auth.uid() = ANY (members) THEN NULL ELSE auth.uid() END, 'organization.deleted', org.id::text,
          jsonb_build_object('name', org.name, 'users', n_users, 'punches', n_punches, 'devices', n_devices)
          || CASE WHEN auth.uid() = ANY (members) THEN jsonb_build_object('by', auth.uid()::text) ELSE '{}'::jsonb END);
  RETURN jsonb_build_object('name', org.name, 'users', n_users, 'punches', n_punches, 'devices', n_devices);
END $$;

REVOKE ALL ON FUNCTION public.purge_organization(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_organization(uuid) TO service_role;
