-- 0021: kontrola „údaje sa od exportu zmenili“ prestane hlásiť zmenu len preto, že čakajúce zariadenie samo vymenilo párovací kód (nadväzuje na 0016).
--
-- Súvislosti. Pri prenose organizácie si server na začiatku exportu zapamätá odtlačok údajov a pred zrušením originálu porovná, či sa od exportu
-- niečo nezmenilo (org_transfer.drift). Z tabuľky devices sa pri porovnaní vynecháva len last_seen_at, lebo sa mení samo pri každom razení.
-- Čakajúce (neschválené) zariadenie si však pri otvorení terminálu samo vygeneruje nový párovací kód (pairing_code) s novou platnosťou
-- (pairing_expires_at), keď predchádzajúci vyprší (každých 10 minút, funkcia z migrácie 0003). Výsledok z reálneho skúšobného prenosu (13. 11. 2026):
-- správca videl „Od exportu sa údaje zmenili: zariadenia: 8 → 8“, musel zaškrtnúť „Rozumiem, že tieto zmeny sa stratia“ a nevedel, čo sa zmenilo.
-- Počet zariadení bol rovnaký, zmenil sa len krátkodobý párovací kód, ktorý nemá cenu prenášať ani strážiť.
--
-- Čo táto migrácia mení: org_transfer.drift_cols() vynechá z tabuľky devices okrem last_seen_at aj pairing_code a pairing_expires_at. Nič iné sa
-- nemení: ostatné stĺpce zariadení (stav, schválenie, zrušenie, …) aj všetky ostatné tabuľky sa kontrolujú ako doteraz. Export (stĺpce a odtlačky
-- v súbore) ani import sa nemenia, párovacie kódy sa v súbore prenášajú ako predtým.
--
-- Poznámka k rozpracovanému prenosu: odtlačok sa ukladá pri začiatku exportu. Prenos začatý PRED touto migráciou a dokončený PO nej môže raz ukázať
-- falošnú zmenu zariadení (jeho odtlačok ešte rátal párovací kód). Stačí prenos zrušiť a export zopakovať.
--
-- Predpoklady: 0016. Opakovateľné. Pred spustením urobte zálohu: docs/ZALOHA-DATABAZY.md. Návrat: 0021_spat_zachranny.sql.
-- Spúšťa sa na serveri, z ktorého sa organizácia EXPORTUJE (porovnanie zmien robí zdrojový server); na cieľovom nie je potrebná, ale neškodí.

DO $$ BEGIN
  IF to_regprocedure('org_transfer.drift_cols()') IS NULL THEN
    RAISE EXCEPTION 'Najprv spustite migráciu 0016 (docs/migracie/0016_prenos_organizacie_export.sql).';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION org_transfer.drift_cols() RETURNS jsonb LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT jsonb_object_agg(s.rel, (SELECT jsonb_agg(a.attname::text ORDER BY a.attnum)
                                  FROM pg_attribute a
                                  WHERE a.attrelid = s.rel::regclass AND a.attnum > 0 AND NOT a.attisdropped
                                    AND NOT ((s.rel = 'public.devices' AND a.attname IN ('last_seen_at', 'pairing_code', 'pairing_expires_at'))
                                          OR (s.rel = 'public.organizations' AND a.attname = 'is_test'))))
  FROM org_transfer.spec() s WHERE s.rel <> 'public.audit_log'
$$;

-- Kontrola po spustení: výsledok musí byť false (pairing_code sa už nesleduje).
--   SELECT org_transfer.drift_cols()->'public.devices' ? 'pairing_code';
