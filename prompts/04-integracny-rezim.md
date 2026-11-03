Prečítaj si `AGENTS.md` (sekcia „Integrácia s dochádzkovým systémom“) a `docs/SPOLUPRACA.md` (kap. 3, 4 a 9). Zaveď **integrovaný režim** organizácie:

* Nové nastavenie `integration_mode` (boolean, predvolene `false`) v nastaveniach organizácie (`organization_settings`), editovateľné len adminom.
* Keď je zapnuté:
  1. Trigger `punches_chain` **nesmie odmietnuť razenie** kvôli uzavretému mesiacu (`is_closed`). Razenie sa vždy prijme. Funkcia uzávierky v „Môj tím“ je skrytá/zakázaná a v administrácii je vysvetlenie, že mesiac uzatvára dochádzkový systém.
  2. Obrazovky s vypočítanými hodnotami („Môj mesiac“, „Môj tím“, výkaz A4, SAP export) majú výrazný popisok „Orientačný prehľad – záväzný výpočet je v dochádzkovom systéme“. SAP export ostáva dostupný, ale s týmto popiskom.
* Migrácia musí zachovať vzorec hash reťaze (`prev_hash|user_id|code|direction|client_time|server_time|client_uuid[|device_id]`) a poradie krokov triggera; pridaj test, že razenie do mesiaca s existujúcim záznamom v `month_closures` prejde, keď je `integration_mode = true`, a zlyhá, keď je `false`.
* Kontraktový test musí ostať zelený.

Najprv mi stručne napíš plán migrácie (SQL zmena triggera) a počkaj na potvrdenie; potom ju aplikuj. Spusti `bun run lint`, `bun run test`, `bun run build`.
