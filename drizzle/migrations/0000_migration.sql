
CREATE TYPE public.app_role AS ENUM ('employee','manager','admin');

CREATE TABLE public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name text NOT NULL DEFAULT '',
  email text,
  department text,
  sap_id text,
  manager_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  daily_fund numeric(5,2) NOT NULL DEFAULT 7.5,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, UPDATE ON public.profiles TO authenticated;
GRANT ALL ON public.profiles TO service_role;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.user_roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.app_role NOT NULL,
  UNIQUE (user_id, role)
);
GRANT SELECT, INSERT, DELETE ON public.user_roles TO authenticated;
GRANT ALL ON public.user_roles TO service_role;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.has_role(_user_id uuid, _role public.app_role)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role)
$$;

CREATE OR REPLACE FUNCTION public.is_manager_of(_emp uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.profiles WHERE id = _emp AND manager_id = auth.uid())
$$;

CREATE OR REPLACE FUNCTION public.can_see(_emp uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT _emp = auth.uid() OR public.is_manager_of(_emp) OR public.has_role(auth.uid(),'admin')
$$;

CREATE POLICY "profiles read" ON public.profiles FOR SELECT TO authenticated USING (public.can_see(id));
CREATE POLICY "profiles admin update" ON public.profiles FOR UPDATE TO authenticated
  USING (public.has_role(auth.uid(),'admin')) WITH CHECK (public.has_role(auth.uid(),'admin'));

CREATE POLICY "roles read" ON public.user_roles FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "roles admin insert" ON public.user_roles FOR INSERT TO authenticated
  WITH CHECK (public.has_role(auth.uid(),'admin'));
CREATE POLICY "roles admin delete" ON public.user_roles FOR DELETE TO authenticated
  USING (public.has_role(auth.uid(),'admin'));

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, email)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email,'@',1)), NEW.email);
  INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'employee');
  IF NOT EXISTS (SELECT 1 FROM public.user_roles WHERE role = 'admin') THEN
    INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'admin'), (NEW.id, 'manager');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

CREATE TABLE public.settings (
  key text PRIMARY KEY,
  value text NOT NULL DEFAULT '',
  description text
);
GRANT SELECT, UPDATE ON public.settings TO authenticated;
GRANT ALL ON public.settings TO service_role;
ALTER TABLE public.settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "settings read" ON public.settings FOR SELECT TO authenticated USING (true);
CREATE POLICY "settings admin" ON public.settings FOR UPDATE TO authenticated
  USING (public.has_role(auth.uid(),'admin')) WITH CHECK (public.has_role(auth.uid(),'admin'));

CREATE TABLE public.absence_codes (
  code text PRIMARY KEY,
  sap_code text NOT NULL,
  name text NOT NULL,
  calc_type text NOT NULL,
  counts boolean NOT NULL DEFAULT false,
  limit_days numeric(5,1),
  sort int NOT NULL DEFAULT 0
);
GRANT SELECT, UPDATE ON public.absence_codes TO authenticated;
GRANT ALL ON public.absence_codes TO service_role;
ALTER TABLE public.absence_codes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "codes read" ON public.absence_codes FOR SELECT TO authenticated USING (true);
CREATE POLICY "codes admin" ON public.absence_codes FOR UPDATE TO authenticated
  USING (public.has_role(auth.uid(),'admin')) WITH CHECK (public.has_role(auth.uid(),'admin'));

CREATE TABLE public.holidays (
  day date PRIMARY KEY,
  name text NOT NULL
);
GRANT SELECT, INSERT, DELETE ON public.holidays TO authenticated;
GRANT ALL ON public.holidays TO service_role;
ALTER TABLE public.holidays ENABLE ROW LEVEL SECURITY;
CREATE POLICY "holidays read" ON public.holidays FOR SELECT TO authenticated USING (true);
CREATE POLICY "holidays admin ins" ON public.holidays FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(),'admin'));
CREATE POLICY "holidays admin del" ON public.holidays FOR DELETE TO authenticated USING (public.has_role(auth.uid(),'admin'));

CREATE TABLE public.month_closures (
  user_id uuid NOT NULL,
  year int NOT NULL,
  month int NOT NULL,
  closed_by uuid NOT NULL,
  closed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, year, month)
);
GRANT SELECT, INSERT, DELETE ON public.month_closures TO authenticated;
GRANT ALL ON public.month_closures TO service_role;
ALTER TABLE public.month_closures ENABLE ROW LEVEL SECURITY;
CREATE POLICY "closures read" ON public.month_closures FOR SELECT TO authenticated USING (public.can_see(user_id));
CREATE POLICY "closures insert" ON public.month_closures FOR INSERT TO authenticated
  WITH CHECK (closed_by = auth.uid() AND (public.is_manager_of(user_id) OR public.has_role(auth.uid(),'admin')));
CREATE POLICY "closures admin delete" ON public.month_closures FOR DELETE TO authenticated
  USING (public.has_role(auth.uid(),'admin'));

CREATE OR REPLACE FUNCTION public.is_closed(_user uuid, _t timestamptz)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.month_closures
    WHERE user_id = _user
      AND year = extract(year FROM _t AT TIME ZONE 'Europe/Bratislava')::int
      AND month = extract(month FROM _t AT TIME ZONE 'Europe/Bratislava')::int)
$$;

CREATE TABLE public.punches (
  id bigserial PRIMARY KEY,
  client_uuid uuid NOT NULL UNIQUE,
  user_id uuid NOT NULL,
  code text NOT NULL REFERENCES public.absence_codes(code),
  direction text NOT NULL CHECK (direction IN ('IN','OUT')),
  client_time timestamptz NOT NULL,
  server_time timestamptz NOT NULL DEFAULT now(),
  drift_minutes int NOT NULL DEFAULT 0,
  source text NOT NULL DEFAULT 'terminal',
  device text,
  prev_hash text,
  record_hash text
);
CREATE INDEX punches_user_time ON public.punches (user_id, client_time);
GRANT SELECT, INSERT ON public.punches TO authenticated;
GRANT USAGE ON SEQUENCE public.punches_id_seq TO authenticated;
GRANT ALL ON public.punches TO service_role;
ALTER TABLE public.punches ENABLE ROW LEVEL SECURITY;
CREATE POLICY "punches read" ON public.punches FOR SELECT TO authenticated USING (public.can_see(user_id));
CREATE POLICY "punches own insert" ON public.punches FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() AND source = 'terminal');

CREATE OR REPLACE FUNCTION public.punches_chain()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE last_hash text;
BEGIN
  IF public.is_closed(NEW.user_id, NEW.client_time) THEN
    RAISE EXCEPTION 'Mesiac je uzavretý';
  END IF;
  NEW.server_time := now();
  NEW.drift_minutes := round(extract(epoch FROM (NEW.server_time - NEW.client_time)) / 60);
  PERFORM pg_advisory_xact_lock(hashtext(NEW.user_id::text));
  SELECT record_hash INTO last_hash FROM public.punches WHERE user_id = NEW.user_id ORDER BY id DESC LIMIT 1;
  NEW.prev_hash := COALESCE(last_hash, 'GENESIS');
  NEW.record_hash := encode(sha256(convert_to(
    NEW.prev_hash || '|' || NEW.user_id || '|' || NEW.code || '|' || NEW.direction || '|' ||
    to_char(NEW.client_time AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS') || '|' ||
    to_char(NEW.server_time AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS') || '|' || NEW.client_uuid, 'UTF8')), 'hex');
  RETURN NEW;
END $$;
CREATE TRIGGER punches_chain BEFORE INSERT ON public.punches FOR EACH ROW EXECUTE FUNCTION public.punches_chain();

CREATE TABLE public.corrections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  code text NOT NULL REFERENCES public.absence_codes(code),
  direction text NOT NULL CHECK (direction IN ('IN','OUT')),
  at_time timestamptz NOT NULL,
  reason text NOT NULL CHECK (length(reason) BETWEEN 3 AND 500),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  decided_by uuid,
  decided_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT ON public.corrections TO authenticated;
GRANT ALL ON public.corrections TO service_role;
ALTER TABLE public.corrections ENABLE ROW LEVEL SECURITY;
CREATE POLICY "corr read" ON public.corrections FOR SELECT TO authenticated USING (public.can_see(user_id));
CREATE POLICY "corr own insert" ON public.corrections FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() AND status = 'pending' AND NOT public.is_closed(user_id, at_time));

CREATE TABLE public.audit_log (
  id bigserial PRIMARY KEY,
  at timestamptz NOT NULL DEFAULT now(),
  actor uuid,
  action text NOT NULL,
  target text,
  details jsonb
);
GRANT SELECT ON public.audit_log TO authenticated;
GRANT ALL ON public.audit_log TO service_role;
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY "audit admin read" ON public.audit_log FOR SELECT TO authenticated USING (public.has_role(auth.uid(),'admin'));

CREATE OR REPLACE FUNCTION public.decide_correction(_id uuid, _approve boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c public.corrections;
BEGIN
  SELECT * INTO c FROM public.corrections WHERE id = _id FOR UPDATE;
  IF c.id IS NULL OR c.status <> 'pending' THEN RAISE EXCEPTION 'Žiadosť neexistuje alebo je vybavená'; END IF;
  IF NOT (public.is_manager_of(c.user_id) OR public.has_role(auth.uid(),'admin')) THEN
    RAISE EXCEPTION 'Nemáte oprávnenie';
  END IF;
  UPDATE public.corrections SET status = CASE WHEN _approve THEN 'approved' ELSE 'rejected' END,
    decided_by = auth.uid(), decided_at = now() WHERE id = _id;
  IF _approve THEN
    INSERT INTO public.punches (client_uuid, user_id, code, direction, client_time, source, device)
    VALUES (gen_random_uuid(), c.user_id, c.code, c.direction, c.at_time, 'correction', 'schválil ' || auth.uid());
  END IF;
  INSERT INTO public.audit_log (actor, action, target, details)
  VALUES (auth.uid(), CASE WHEN _approve THEN 'correction_approved' ELSE 'correction_rejected' END, c.user_id::text, to_jsonb(c));
END $$;

CREATE OR REPLACE FUNCTION public.audit_generic()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.audit_log (actor, action, target, details)
  VALUES (auth.uid(), TG_OP || ' ' || TG_TABLE_NAME, NULL,
          jsonb_build_object('old', CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
                             'new', CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END));
  RETURN COALESCE(NEW, OLD);
END $$;
CREATE TRIGGER audit_settings AFTER UPDATE ON public.settings FOR EACH ROW EXECUTE FUNCTION public.audit_generic();
CREATE TRIGGER audit_codes AFTER UPDATE ON public.absence_codes FOR EACH ROW EXECUTE FUNCTION public.audit_generic();
CREATE TRIGGER audit_closures AFTER INSERT OR DELETE ON public.month_closures FOR EACH ROW EXECUTE FUNCTION public.audit_generic();
CREATE TRIGGER audit_profiles AFTER UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.audit_generic();
CREATE TRIGGER audit_roles AFTER INSERT OR DELETE ON public.user_roles FOR EACH ROW EXECUTE FUNCTION public.audit_generic();

REVOKE EXECUTE ON FUNCTION public.decide_correction(uuid, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.decide_correction(uuid, boolean) TO authenticated;

INSERT INTO public.settings (key, value, description) VALUES
 ('ZAOKRUHLENIE_PRICHOD','0','Zaokrúhlenie prvého príchodu nahor v minútach (0 = vypnuté)'),
 ('ZAOKRUHLENIE_ODCHOD','0','Zaokrúhlenie posledného odchodu nadol v minútach (0 = vypnuté)'),
 ('OBED_PAUZA_MIN','30','Odpočet prestávky v minútach'),
 ('OBED_PO_HODINACH','6','Prestávka sa odpočíta pri práci nad X hodín'),
 ('DENNY_FOND_HODIN','7.5','Predvolený denný fond'),
 ('PRUZNA_ZAKLAD_START','09:00','Začiatok základného času'),
 ('PRUZNA_ZAKLAD_KONIEC','14:00','Koniec základného času'),
 ('MAX_ODCHYLKA_CASU_MIN','10','Rozdiel času zariadenia a servera, od ktorého sa záznam označí'),
 ('SETTINGS_VERZIA','1.1.0','Verzia pravidiel');

INSERT INTO public.absence_codes (code, sap_code, name, calc_type, counts, limit_days, sort) VALUES
 ('WORK','0100','Práca na pracovisku','REAL',true,NULL,1),
 ('TRIP','0120','Služobná cesta','REAL_DOPOCET',true,NULL,2),
 ('DOCTOR','0210','Lekár / ošetrenie','DOPOCET',true,7,3),
 ('FAMILY','0220','Sprievod rodinného príslušníka','DOPOCET',true,10,4),
 ('LEAVE','0300','Dovolenka','CELODENNE',true,NULL,5),
 ('SICK','0400','PN / práceneschopnosť','NULOVE',false,NULL,6),
 ('PRIV','0500','Súkromné prerušenie','REAL',false,NULL,7);

INSERT INTO public.holidays (day, name) VALUES
 ('2026-01-01','Deň vzniku SR'),('2026-01-06','Zjavenie Pána'),('2026-04-03','Veľký piatok'),
 ('2026-04-06','Veľkonočný pondelok'),('2026-05-01','Sviatok práce'),('2026-05-08','Deň víťazstva nad fašizmom'),
 ('2026-07-05','Sv. Cyril a Metod'),('2026-08-29','Výročie SNP'),('2026-09-15','Sedembolestná Panna Mária'),
 ('2026-11-01','Sviatok Všetkých svätých'),('2026-11-17','Deň boja za slobodu a demokraciu'),
 ('2026-12-24','Štedrý deň'),('2026-12-25','Prvý sviatok vianočný'),('2026-12-26','Druhý sviatok vianočný');
