-- 0008: overenie prijatia razenia ako záložná cesta pri sieťovej chybe (podnikové proxy, SSL inšpekcia, captive portály).
-- Čisto aditívna migrácia: pridáva jednu funkciu, nemení tabuľky, politiky, trigger punches_chain ani export.
--
-- Terminál ju volá LEN vtedy, keď overovacie čítanie z punches zlyhá sieťovo (HTML odpoveď proxy, 403 bez kódu databázy,
-- 502, 504, zatvorené spojenie, Failed to fetch). Vráti true iba vtedy, ak existuje razenie prihláseného používateľa
-- s presne rovnakým client_uuid, kódom, smerom, časom klienta a zariadením.
--
-- Bezpečnosť:
--   * SECURITY INVOKER – beží s právami volajúceho, platí RLS politika "punches read" (can_see).
--   * Vlastník sa overuje cez auth.uid() = user_id, nikdy nie z parametra klienta (funkcia user_id ani neprijíma).
--   * SET search_path = '' – všetky odkazy sú plne kvalifikované.
--   * Nespustiteľná pre anon.
-- Návrat: docs/migracie/0008_spat_zachranny.sql

CREATE OR REPLACE FUNCTION public.verify_punch_synced(
  p_client_uuid uuid,
  p_code text,
  p_direction text,
  p_client_time timestamptz,
  p_device text
) RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1
      FROM public.punches p
     WHERE p.client_uuid = p_client_uuid
       AND p.user_id = auth.uid()
       AND p.code = p_code
       AND p.direction = p_direction
       AND p.client_time = p_client_time
       AND p.device IS NOT DISTINCT FROM p_device
  );
$$;

REVOKE ALL ON FUNCTION public.verify_punch_synced(uuid, text, text, timestamptz, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.verify_punch_synced(uuid, text, text, timestamptz, text) TO authenticated;
