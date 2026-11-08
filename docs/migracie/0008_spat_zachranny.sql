-- 0008 SPÄŤ: ZÁCHRANNÝ skript, ktorý vráti databázu do stavu pred migráciou 0008 (verify_punch_synced).
-- NESPÚŠŤAJTE ho bez dôvodu. Spúšťa sa len ak migrácia 0008 niečo pokazila a oprava dopredu nejde.
--
-- Čo urobí: zruší funkciu public.verify_punch_synced. Dáta (razenia, rad v zariadeniach) sa nemenia.
-- Dopad na terminál: záložné overenie po sieťovej chybe prestane fungovať; razenia ostanú v zariadení
-- a odošlú/overia sa bežným čítaním, keď sieť znova pustí požiadavky na databázu.
-- Skript je opakovateľný (pri druhom spustení nič nezmení).

DROP FUNCTION IF EXISTS public.verify_punch_synced(uuid, text, text, timestamptz, text);
