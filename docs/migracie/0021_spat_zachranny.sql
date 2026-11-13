-- 0021 SPÄŤ: ZÁCHRANNÝ skript, ktorý vráti org_transfer.drift_cols() do podoby z migrácie 0016 (z tabuľky devices sa vynecháva len last_seen_at).
-- Dôsledok: kontrola „údaje sa od exportu zmenili“ znova ukáže zmenu zariadení, keď čakajúce zariadenie vymení párovací kód. Je to len
-- zbytočné upozornenie, údaje sa nestratia. Skript je opakovateľný. Rozpracovaný prenos treba zrušiť a export zopakovať (jeho odtlačok je z novej podoby).

CREATE OR REPLACE FUNCTION org_transfer.drift_cols() RETURNS jsonb LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT jsonb_object_agg(s.rel, (SELECT jsonb_agg(a.attname::text ORDER BY a.attnum)
                                  FROM pg_attribute a
                                  WHERE a.attrelid = s.rel::regclass AND a.attnum > 0 AND NOT a.attisdropped
                                    AND NOT ((s.rel = 'public.devices' AND a.attname = 'last_seen_at')
                                          OR (s.rel = 'public.organizations' AND a.attname = 'is_test'))))
  FROM org_transfer.spec() s WHERE s.rel <> 'public.audit_log'
$$;
