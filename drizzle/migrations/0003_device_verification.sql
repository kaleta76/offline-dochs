CREATE TABLE public.devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  organization_id uuid NOT NULL REFERENCES public.organizations(id),
  device_token_hash text NOT NULL UNIQUE CHECK (device_token_hash ~ '^[0-9a-f]{64}$'),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','active','backup','revoked')),
  pairing_code text,
  pairing_expires_at timestamptz,
  recovery_code_hash text,
  recovery_code_pending text,
  replaces_device_id uuid REFERENCES public.devices(id),
  approved_by uuid, approved_at timestamptz,
  revoked_by uuid, revoked_at timestamptz, revoke_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz,
  user_agent_hint text
);
CREATE UNIQUE INDEX devices_one_active ON public.devices(user_id) WHERE status = 'active';
CREATE INDEX devices_org_status ON public.devices(organization_id, status);
GRANT SELECT (id, user_id, organization_id, status, pairing_code, pairing_expires_at, replaces_device_id, approved_by, approved_at, revoked_by, revoked_at, revoke_reason, created_at, last_seen_at, user_agent_hint, device_token_hash) ON public.devices TO authenticated;
GRANT ALL ON public.devices TO service_role;
ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;
CREATE POLICY devices_read ON public.devices FOR SELECT TO authenticated USING (public.can_see(user_id));

CREATE OR REPLACE FUNCTION public.device_manager_ok(_user uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT public.same_organization(_user) AND (public.is_manager_of(_user) OR public.has_role(auth.uid(),'admin')) $$;
CREATE OR REPLACE FUNCTION public.new_pairing_code() RETURNS text LANGUAGE sql VOLATILE SET search_path=public AS $$
  SELECT lpad(((('x'||encode(extensions.gen_random_bytes(4),'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0') $$;
CREATE OR REPLACE FUNCTION public.new_recovery_code() RETURNS text LANGUAGE plpgsql VOLATILE SET search_path=public AS $$
DECLARE alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; b bytea := extensions.gen_random_bytes(12); r text := ''; i int;
BEGIN
  FOR i IN 0..11 LOOP r := r || substr(alphabet, (get_byte(b,i) % 32) + 1, 1); IF i IN (3,7) THEN r := r || '-'; END IF; END LOOP;
  RETURN r;
END $$;
CREATE OR REPLACE FUNCTION public.hash_recovery_code(_code text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path=public AS $$
  SELECT encode(sha256(convert_to(upper(regexp_replace(_code,'[^A-Za-z0-9]','','g')),'UTF8')),'hex') $$;
REVOKE EXECUTE ON FUNCTION public.new_pairing_code(), public.new_recovery_code() FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public.register_device(_token_hash text, _ua_hint text, _replace boolean DEFAULT false)
RETURNS TABLE(device_id uuid, status text, pairing_code text, pairing_expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE d public.devices; org uuid := public.my_organization(); prev uuid;
BEGIN
  IF auth.uid() IS NULL OR org IS NULL THEN RAISE EXCEPTION 'Prihlásenie je potrebné'; END IF;
  SELECT * INTO d FROM public.devices WHERE device_token_hash = _token_hash FOR UPDATE;
  IF d.id IS NOT NULL THEN
    IF d.user_id <> auth.uid() THEN RAISE EXCEPTION 'Zariadenie patrí inému používateľovi'; END IF;
    IF d.status = 'pending' AND (d.pairing_expires_at IS NULL OR d.pairing_expires_at < now()) THEN
      UPDATE public.devices SET pairing_code = public.new_pairing_code(), pairing_expires_at = now() + interval '10 minutes' WHERE id = d.id RETURNING * INTO d;
    END IF;
    RETURN QUERY SELECT d.id, d.status, d.pairing_code, d.pairing_expires_at; RETURN;
  END IF;
  IF (SELECT count(*) FROM public.devices x WHERE x.user_id = auth.uid() AND x.status = 'pending') >= 3 THEN
    RAISE EXCEPTION 'Príliš veľa čakajúcich zariadení. Požiadajte vedúceho o vybavenie.';
  END IF;
  IF _replace THEN SELECT x.id INTO prev FROM public.devices x WHERE x.user_id = auth.uid() AND x.status = 'active'; END IF;
  INSERT INTO public.devices(user_id, organization_id, device_token_hash, pairing_code, pairing_expires_at, user_agent_hint, replaces_device_id)
  VALUES (auth.uid(), org, _token_hash, public.new_pairing_code(), now() + interval '10 minutes', left(_ua_hint, 80), prev) RETURNING * INTO d;
  INSERT INTO public.audit_log(actor, action, target, details) VALUES (auth.uid(), CASE WHEN prev IS NULL THEN 'device.registered' ELSE 'device.replacement_requested' END, d.id::text,
    jsonb_build_object('user_id', d.user_id, 'new_status', 'pending', 'replaces', prev));
  RETURN QUERY SELECT d.id, d.status, d.pairing_code, d.pairing_expires_at;
END $$;

CREATE OR REPLACE FUNCTION public.approve_device(_id uuid, _as_backup boolean DEFAULT false) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE d public.devices; code text := public.new_recovery_code();
BEGIN
  SELECT * INTO d FROM public.devices WHERE id = _id FOR UPDATE;
  IF d.id IS NULL OR d.status <> 'pending' THEN RAISE EXCEPTION 'Zariadenie neexistuje alebo nečaká na schválenie'; END IF;
  IF NOT public.device_manager_ok(d.user_id) THEN RAISE EXCEPTION 'Nemáte oprávnenie'; END IF;
  IF d.replaces_device_id IS NOT NULL THEN
    UPDATE public.devices SET status='revoked', revoked_by=auth.uid(), revoked_at=now(), revoke_reason='Nahradené novým zariadením'
      WHERE id = d.replaces_device_id AND status <> 'revoked';
    INSERT INTO public.audit_log(actor, action, target, details) VALUES (auth.uid(), 'device.revoked', d.replaces_device_id::text, jsonb_build_object('user_id', d.user_id, 'new_status','revoked','reason','replaced'));
  END IF;
  IF NOT _as_backup THEN UPDATE public.devices SET status='backup' WHERE user_id = d.user_id AND status='active'; END IF;
  UPDATE public.devices SET status = CASE WHEN _as_backup THEN 'backup' ELSE 'active' END, approved_by=auth.uid(), approved_at=now(),
    pairing_code=NULL, pairing_expires_at=NULL, recovery_code_hash=public.hash_recovery_code(code), recovery_code_pending=code WHERE id = d.id;
  INSERT INTO public.audit_log(actor, action, target, details) VALUES (auth.uid(), 'device.approved', d.id::text,
    jsonb_build_object('user_id', d.user_id, 'old_status','pending', 'new_status', CASE WHEN _as_backup THEN 'backup' ELSE 'active' END));
END $$;

CREATE OR REPLACE FUNCTION public.claim_recovery_code(_token_hash text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE c text;
BEGIN
  UPDATE public.devices x SET recovery_code_pending = NULL FROM (SELECT id, recovery_code_pending FROM public.devices WHERE device_token_hash=_token_hash AND user_id=auth.uid() AND status IN ('active','backup') FOR UPDATE) old
    WHERE x.id = old.id RETURNING old.recovery_code_pending INTO c;
  RETURN c;
END $$;

CREATE OR REPLACE FUNCTION public.revoke_device(_id uuid, _reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE d public.devices;
BEGIN
  SELECT * INTO d FROM public.devices WHERE id = _id FOR UPDATE;
  IF d.id IS NULL OR d.status = 'revoked' THEN RAISE EXCEPTION 'Zariadenie neexistuje alebo je už zrušené'; END IF;
  IF NOT (d.user_id = auth.uid() OR public.device_manager_ok(d.user_id)) THEN RAISE EXCEPTION 'Nemáte oprávnenie'; END IF;
  UPDATE public.devices SET status='revoked', revoked_by=auth.uid(), revoked_at=now(), revoke_reason=left(_reason,200), pairing_code=NULL, recovery_code_pending=NULL WHERE id=_id;
  INSERT INTO public.audit_log(actor, action, target, details) VALUES (auth.uid(), 'device.revoked', _id::text,
    jsonb_build_object('user_id', d.user_id, 'old_status', d.status, 'new_status','revoked', 'reason', left(_reason,200)));
END $$;

CREATE OR REPLACE FUNCTION public.recover_device(_recovery_code text, _new_token_hash text, _ua_hint text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE d public.devices; nid uuid; code text := public.new_recovery_code(); org uuid := public.my_organization();
BEGIN
  IF auth.uid() IS NULL OR org IS NULL THEN RAISE EXCEPTION 'Prihlásenie je potrebné'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('recover'||auth.uid()));
  IF (SELECT count(*) FROM public.audit_log WHERE actor=auth.uid() AND action='device.recovery_failed' AND at > now() - interval '1 hour') >= 5 THEN
    RAISE EXCEPTION 'Príliš veľa neúspešných pokusov. Skúste o hodinu alebo požiadajte vedúceho.';
  END IF;
  SELECT * INTO d FROM public.devices WHERE user_id=auth.uid() AND status IN ('active','backup') AND recovery_code_hash = public.hash_recovery_code(_recovery_code) FOR UPDATE;
  IF d.id IS NULL THEN
    INSERT INTO public.audit_log(actor, action, target, details) VALUES (auth.uid(), 'device.recovery_failed', auth.uid()::text, jsonb_build_object('user_id', auth.uid()));
    RETURN NULL;
  END IF;
  DELETE FROM public.devices WHERE device_token_hash=_new_token_hash AND user_id=auth.uid() AND status='pending';
  UPDATE public.devices SET status='revoked', revoked_by=auth.uid(), revoked_at=now(), revoke_reason='Obnova záchranným kódom', recovery_code_hash=NULL, recovery_code_pending=NULL WHERE id=d.id;
  INSERT INTO public.devices(user_id, organization_id, device_token_hash, status, recovery_code_hash, approved_by, approved_at, user_agent_hint, replaces_device_id)
  VALUES (auth.uid(), org, _new_token_hash, d.status, public.hash_recovery_code(code), auth.uid(), now(), left(_ua_hint,80), d.id) RETURNING id INTO nid;
  INSERT INTO public.audit_log(actor, action, target, details) VALUES (auth.uid(), 'device.recovered', nid::text,
    jsonb_build_object('user_id', auth.uid(), 'revoked_device', d.id, 'new_status', d.status));
  RETURN code;
END $$;

ALTER TABLE public.punches ADD COLUMN device_id uuid REFERENCES public.devices(id),
  ADD COLUMN device_verification text NOT NULL DEFAULT 'unverified' CHECK (device_verification IN ('verified','unverified','confirmed')),
  ADD COLUMN device_token text;
UPDATE public.punches SET device_verification = 'confirmed';

CREATE OR REPLACE FUNCTION public.punches_chain()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE last_hash text; dev uuid;
BEGIN
  IF public.is_closed(NEW.user_id, NEW.client_time) THEN RAISE EXCEPTION 'Mesiac je uzavretý'; END IF;
  NEW.device_id := NULL;
  IF NEW.source <> 'terminal' THEN
    NEW.device_verification := 'confirmed';
  ELSE
    IF NEW.device_token IS NOT NULL AND NEW.device_token ~ '^[0-9a-f]{64}$' THEN
      SELECT id INTO dev FROM public.devices WHERE user_id = NEW.user_id AND status IN ('active','backup')
        AND device_token_hash = encode(sha256(convert_to(NEW.device_token,'UTF8')),'hex');
    END IF;
    IF dev IS NOT NULL THEN
      NEW.device_id := dev; NEW.device_verification := 'verified';
      UPDATE public.devices SET last_seen_at = now() WHERE id = dev;
    ELSE
      NEW.device_verification := 'unverified';
    END IF;
  END IF;
  NEW.device_token := NULL;
  NEW.server_time := now();
  NEW.drift_minutes := round(extract(epoch FROM (NEW.server_time - NEW.client_time)) / 60);
  PERFORM pg_advisory_xact_lock(hashtext(NEW.user_id::text));
  SELECT record_hash INTO last_hash FROM public.punches WHERE user_id = NEW.user_id ORDER BY id DESC LIMIT 1;
  NEW.prev_hash := COALESCE(last_hash, 'GENESIS');
  NEW.record_hash := encode(sha256(convert_to(
    NEW.prev_hash || '|' || NEW.user_id || '|' || NEW.code || '|' || NEW.direction || '|' ||
    to_char(NEW.client_time AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS') || '|' ||
    to_char(NEW.server_time AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS') || '|' || NEW.client_uuid ||
    CASE WHEN NEW.device_id IS NULL THEN '' ELSE '|' || NEW.device_id END, 'UTF8')), 'hex');
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.confirm_unverified_punch(_punch_id bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE p public.punches;
BEGIN
  SELECT * INTO p FROM public.punches WHERE id=_punch_id FOR UPDATE;
  IF p.id IS NULL OR p.device_verification <> 'unverified' THEN RAISE EXCEPTION 'Záznam neexistuje alebo nie je neoverený'; END IF;
  IF NOT public.device_manager_ok(p.user_id) THEN RAISE EXCEPTION 'Nemáte oprávnenie'; END IF;
  UPDATE public.punches SET device_verification='confirmed' WHERE id=_punch_id;
  INSERT INTO public.audit_log(actor, action, target, details) VALUES (auth.uid(), 'punch.device_confirmed', _punch_id::text, jsonb_build_object('user_id', p.user_id));
END $$;

REVOKE EXECUTE ON FUNCTION public.register_device(text,text,boolean), public.approve_device(uuid,boolean), public.claim_recovery_code(text), public.revoke_device(uuid,text), public.recover_device(text,text,text), public.confirm_unverified_punch(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_device(text,text,boolean), public.approve_device(uuid,boolean), public.claim_recovery_code(text), public.revoke_device(uuid,text), public.recover_device(text,text,text), public.confirm_unverified_punch(bigint) TO authenticated;