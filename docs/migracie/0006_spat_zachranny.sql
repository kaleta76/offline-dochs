-- 0006 SPÄŤ: ZÁCHRANNÝ skript, ktorý vráti databázu do stavu pred migráciou 0006 (zneplatnenie razení).
-- NESPÚŠŤAJTE ho, kým nečítate docs/ZACHRANA-A-NAVRAT.md. Spúšťa sa len ak migrácia 0006 niečo pokazila a oprava dopredu nejde.
--
-- Čo urobí:
--   1. zruší funkcie request_punch_void a decide_punch_void,
--   2. vráti pôvodné pravidlo vkladania "punches own insert" (z migrácie 0002),
--   3. zmaže tabuľku punch_void_requests (zmažú sa všetky žiadosti o zneplatnenie),
--   4. zmaže stĺpce punches.voided_at a punches.void_request_id (zmaže sa informácia, ktoré razenia boli zneplatnené).
-- Samotné razenia ostávajú, ich hash reťaz sa nemení (stĺpce nie sú súčasťou record_hash). Zaznamenané riadky v audit_log ostávajú.
--
-- POZOR: po zmazaní stĺpcov sa zneplatnené razenia znova počítajú do dochádzky. Kód terminálu od PR #6 tieto stĺpce vyžaduje,
-- takže po tomto skripte treba aj kód vrátiť (pozri docs/ZACHRANA-A-NAVRAT.md), inak obrazovky s mesiacom nenačítajú údaje.
-- Skript je opakovateľný (pri druhom spustení nič nezmení). Poradie príkazov nemeňte: vyskúšané je presne v tomto poradí (pravidlo vkladania používa stĺpce, preto sa mení pred ich zmazaním).

DROP FUNCTION IF EXISTS public.decide_punch_void(uuid, boolean);
DROP FUNCTION IF EXISTS public.request_punch_void(bigint, text);

ALTER POLICY "punches own insert" ON public.punches
  WITH CHECK (user_id = auth.uid() AND source = 'terminal' AND public.my_organization() IS NOT NULL);

DROP TABLE IF EXISTS public.punch_void_requests;

ALTER TABLE public.punches DROP COLUMN IF EXISTS voided_at, DROP COLUMN IF EXISTS void_request_id;
