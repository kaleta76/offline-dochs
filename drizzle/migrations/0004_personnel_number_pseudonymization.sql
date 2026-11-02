COMMENT ON COLUMN public.profiles.sap_id IS 'SAP personnel number used as the attendance pseudonym; 7 or 8 digits, leading zeros preserved; unique within organization.';
COMMENT ON COLUMN public.profiles.full_name IS 'DEPRECATED: legacy identity data, inaccessible to application roles; mapping maintained outside the application.';
COMMENT ON COLUMN public.profiles.email IS 'DEPRECATED: legacy identity data, inaccessible to application roles; email authentication remains managed by Auth.';
REVOKE SELECT, UPDATE ON public.profiles FROM authenticated, anon;
REVOKE SELECT (full_name, email), UPDATE (full_name, email) ON public.profiles FROM authenticated, anon;
GRANT SELECT (id, department, sap_id, manager_id, daily_fund, created_at, organization_id) ON public.profiles TO authenticated;
GRANT UPDATE (department, sap_id, manager_id, daily_fund) ON public.profiles TO authenticated;
CREATE UNIQUE INDEX profiles_sap_personnel_unique ON public.profiles(organization_id,sap_id) WHERE sap_id ~ '^[0-9]{7,8}$';
CREATE OR REPLACE FUNCTION public.validate_personnel_number() RETURNS trigger LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
 IF TG_OP='INSERT' OR NEW.sap_id IS DISTINCT FROM OLD.sap_id THEN
  IF NEW.sap_id IS NOT NULL AND NEW.sap_id !~ '^[0-9]{7,8}$' THEN RAISE EXCEPTION 'Osobné číslo zo SAP musí mať 7 alebo 8 číslic'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER profile_personnel_number_guard BEFORE INSERT OR UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.validate_personnel_number();
CREATE OR REPLACE FUNCTION public.handle_new_user() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE org uuid; org_name text; invite text;
BEGIN
 org_name:=btrim(COALESCE(NEW.raw_user_meta_data->>'organization_name','')); invite:=btrim(COALESCE(NEW.raw_user_meta_data->>'invite_code',''));
 IF org_name<>'' AND invite<>'' THEN RAISE EXCEPTION 'Vyberte registráciu firmy alebo pozvanie'; END IF;
 IF org_name<>'' THEN
  IF length(org_name) NOT BETWEEN 2 AND 160 THEN RAISE EXCEPTION 'Názov organizácie musí mať 2 až 160 znakov'; END IF;
  INSERT INTO public.organizations(name,created_by) VALUES(org_name,NEW.id) RETURNING id INTO org;
  INSERT INTO public.organization_settings SELECT org,s.* FROM public.settings s;
  INSERT INTO public.organization_codes SELECT org,c.* FROM public.absence_codes c;
  INSERT INTO public.organization_holidays SELECT org,h.* FROM public.holidays h;
  INSERT INTO public.organization_invites(organization_id) VALUES(org);
 ELSE
  SELECT organization_id INTO org FROM public.organization_invites WHERE code=invite;
  IF org IS NULL THEN RAISE EXCEPTION 'Neplatný pozývací kód organizácie'; END IF;
 END IF;
 -- Only a company admin assigns SAP numbers; user-editable signup metadata cannot impersonate an employee number.
 INSERT INTO public.profiles(id,organization_id) VALUES(NEW.id,org);
 INSERT INTO public.user_roles(user_id,role) VALUES(NEW.id,'employee');
 IF org_name<>'' THEN INSERT INTO public.user_roles(user_id,role) VALUES(NEW.id,'admin'),(NEW.id,'manager'); END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION public.audit_generic() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE before_row jsonb; after_row jsonb;
BEGIN
 IF TG_OP<>'INSERT' THEN before_row:=to_jsonb(OLD); END IF;
 IF TG_OP<>'DELETE' THEN after_row:=to_jsonb(NEW); END IF;
 IF TG_TABLE_NAME='profiles' THEN before_row:=before_row-'full_name'-'email'; after_row:=after_row-'full_name'-'email'; END IF;
 INSERT INTO public.audit_log(actor,action,target,details) VALUES(auth.uid(),TG_OP||' '||TG_TABLE_NAME,NULL,jsonb_build_object('old',before_row,'new',after_row));
 RETURN COALESCE(NEW,OLD);
END $$;
-- Historical audit payloads can contain legacy names. Preserve history, but do not expose raw payloads to any app role.
REVOKE SELECT ON public.audit_log FROM authenticated, anon;
REVOKE SELECT (details) ON public.audit_log FROM authenticated, anon;
GRANT SELECT (id,at,actor,action,target) ON public.audit_log TO authenticated;
COMMENT ON COLUMN public.audit_log.details IS 'Privileged audit payload; legacy history may include identity fields. Not readable by application roles; future profile audit omits names/email.';