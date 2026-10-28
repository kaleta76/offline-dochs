DROP POLICY "settings read" ON public.settings;
CREATE POLICY "settings admin read" ON public.settings FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'::public.app_role));

DROP POLICY "codes read" ON public.absence_codes;
CREATE POLICY "codes admin read" ON public.absence_codes FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'::public.app_role));

-- Employees still need the handful of calculation settings (rounding, lunch break,
-- daily fund, max drift) for the month view. Expose only those keys through a
-- whitelisted SECURITY DEFINER function; all other settings stay admin-only.
CREATE OR REPLACE FUNCTION public.calc_settings()
RETURNS TABLE(key text, value text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.key, s.value
  FROM public.settings s
  WHERE s.key IN (
    'ZAOKRUHLENIE_PRICHOD',
    'ZAOKRUHLENIE_ODCHOD',
    'OBED_PAUZA_MIN',
    'OBED_PO_HODINACH',
    'DENNY_FOND_HODIN',
    'MAX_ODCHYLKA_CASU_MIN'
  );
$$;

GRANT EXECUTE ON FUNCTION public.calc_settings() TO authenticated;