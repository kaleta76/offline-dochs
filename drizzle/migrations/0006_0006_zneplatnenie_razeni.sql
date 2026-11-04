-- 0006: zneplatnenie razení (žiadosť zamestnanca, schválenie vedúcim alebo správcom).
-- Razenie sa NEMAŽE a jeho hash reťaz sa nemení (voided_at a void_request_id nie sú súčasťou record_hash).

ALTER TABLE public.punches ADD COLUMN voided_at timestamptz, ADD COLUMN void_request_id uuid;

CREATE TABLE public.punch_void_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  punch_id bigint NOT NULL REFERENCES public.punches(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  requested_by uuid NOT NULL,
  reason text NOT NULL CHECK (length(btrim(reason)) BETWEEN 3 AND 500),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  decided_by uuid,
  decided_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX punch_void_one_open ON public.punch_void_requests (punch_id) WHERE status IN ('pending','approved');
CREATE INDEX punch_void_user_status ON public.punch_void_requests (user_id, status);
GRANT SELECT ON public.punch_void_requests TO authenticated;
GRANT ALL ON public.punch_void_requests TO service_role;
ALTER TABLE public.punch_void_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY punch_void_read ON public.punch_void_requests FOR SELECT TO authenticated USING (public.can_see(user_id));

ALTER POLICY "punches own insert" ON public.punches
  WITH CHECK (user_id = auth.uid() AND source = 'terminal' AND public.my_organization() IS NOT NULL AND voided_at IS NULL AND void_request_id IS NULL);

CREATE OR REPLACE FUNCTION public.request_punch_void(_punch_id bigint, _reason text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.punches; rid uuid; r text := btrim(coalesce(_reason, ''));
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Prihlásenie je potrebné'; END IF;
  IF length(r) < 3 OR length(r) > 500 THEN RAISE EXCEPTION 'Dôvod musí mať 3 až 500 znakov'; END IF;
  SELECT * INTO p FROM public.punches WHERE id = _punch_id;
  IF p.id IS NULL THEN RAISE EXCEPTION 'Razenie neexistuje'; END IF;
  IF NOT public.can_see(p.user_id) THEN RAISE EXCEPTION 'Nemáte oprávnenie'; END IF;
  IF p.voided_at IS NOT NULL THEN RAISE EXCEPTION 'Razenie je už zneplatnené'; END IF;
  IF public.is_closed(p.user_id, p.client_time) THEN RAISE EXCEPTION 'Mesiac je uzavretý'; END IF;
  BEGIN
    INSERT INTO public.punch_void_requests (punch_id, user_id, requested_by, reason)
    VALUES (p.id, p.user_id, auth.uid(), r) RETURNING id INTO rid;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Na toto razenie už žiadosť existuje';
  END;
  INSERT INTO public.audit_log (actor, action, target, details)
  VALUES (auth.uid(), 'void_requested', p.user_id::text, jsonb_build_object('request_id', rid, 'punch_id', p.id, 'reason', r));
  RETURN rid;
END $$;

CREATE OR REPLACE FUNCTION public.decide_punch_void(_id uuid, _approve boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v public.punch_void_requests; p public.punches;
BEGIN
  SELECT * INTO v FROM public.punch_void_requests WHERE id = _id FOR UPDATE;
  IF v.id IS NULL OR v.status <> 'pending' THEN RAISE EXCEPTION 'Žiadosť neexistuje alebo je vybavená'; END IF;
  IF NOT (public.same_organization(v.user_id) AND (public.is_manager_of(v.user_id) OR public.has_role(auth.uid(), 'admin'))) THEN
    RAISE EXCEPTION 'Nemáte oprávnenie';
  END IF;
  IF _approve THEN
    SELECT * INTO p FROM public.punches WHERE id = v.punch_id FOR UPDATE;
    IF public.is_closed(p.user_id, p.client_time) THEN RAISE EXCEPTION 'Mesiac je uzavretý'; END IF;
    UPDATE public.punches SET voided_at = now(), void_request_id = v.id WHERE id = v.punch_id;
  END IF;
  UPDATE public.punch_void_requests
     SET status = CASE WHEN _approve THEN 'approved' ELSE 'rejected' END, decided_by = auth.uid(), decided_at = now()
   WHERE id = v.id;
  INSERT INTO public.audit_log (actor, action, target, details)
  VALUES (auth.uid(), CASE WHEN _approve THEN 'void_approved' ELSE 'void_rejected' END, v.user_id::text,
          jsonb_build_object('request_id', v.id, 'punch_id', v.punch_id));
END $$;

REVOKE ALL ON FUNCTION public.request_punch_void(bigint, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.decide_punch_void(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_punch_void(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.decide_punch_void(uuid, boolean) TO authenticated;