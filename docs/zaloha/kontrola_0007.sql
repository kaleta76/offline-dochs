-- KONTROLA MIGRÁCIE 0007: jeden dotaz len na čítanie, ktorý sa spúšťa PRED migráciou aj PO nej. Pozri docs/ZRUSENIE-TESTOVACEJ-ORGANIZACIE.md.
-- Nič nezapisuje ani nemení. Výsledok je jeden riadok.
--
-- PRED migráciou (migrácia je pripravená na spustenie, keď platí všetko z tohto zoznamu):
--   smie_vytvarat_v_public = true, vlastni_organizations = true, vlastni_guard_last_admin = true
--       (rola, pod ktorou bežíte, smie pridať stĺpec a prepísať funkciu; ak je niečo false, migrácia by v editore zlyhala)
--   smie_mazat_auth_users = true
--       (funkcia purge_organization maže prihlasovacie účty; vlastní ju rola, ktorá migráciu spustí, a musí mať toto právo)
--   stlpec_is_test = false, funkcie_0007 = 0, purge_pre_authenticated = NULL, purge_pre_service_role = NULL
--       (migrácia ešte nebola spustená)
-- PO migrácii:
--   stlpec_is_test = true, funkcie_0007 = 4, purge_pre_authenticated = false, purge_pre_service_role = true
--       (purge_organization smie volať len správca databázy, nie používateľ aplikácie)

SELECT
  current_user AS rola,
  has_schema_privilege(current_user, 'public', 'CREATE') AS smie_vytvarat_v_public,
  pg_has_role(current_user, (SELECT relowner FROM pg_class WHERE oid = 'public.organizations'::regclass), 'USAGE') AS vlastni_organizations,
  pg_has_role(current_user, (SELECT proowner FROM pg_proc WHERE oid = 'public.guard_last_admin()'::regprocedure), 'USAGE') AS vlastni_guard_last_admin,
  CASE WHEN NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'auth') THEN false
       WHEN NOT has_schema_privilege(current_user, 'auth', 'USAGE') THEN false
       ELSE has_table_privilege(current_user, 'auth.users', 'DELETE') END AS smie_mazat_auth_users,
  EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'organizations' AND column_name = 'is_test') AS stlpec_is_test,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN ('set_organization_test', 'test_organization_summary', 'delete_test_organization', 'purge_organization')) AS funkcie_0007,
  CASE WHEN to_regprocedure('public.purge_organization(uuid)') IS NULL THEN NULL
       ELSE has_function_privilege('authenticated', 'public.purge_organization(uuid)', 'EXECUTE') END AS purge_pre_authenticated,
  CASE WHEN to_regprocedure('public.purge_organization(uuid)') IS NULL THEN NULL
       ELSE has_function_privilege('service_role', 'public.purge_organization(uuid)', 'EXECUTE') END AS purge_pre_service_role;
