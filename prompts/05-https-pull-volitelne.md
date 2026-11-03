(Použiť až po mesiaci bezproblémového súborového prenosu – fáza B.)

Prečítaj si `AGENTS.md` (sekcia „Integrácia s dochádzkovým systémom“), `contract/README.md` a `docs/SPOLUPRACA.md` (kap. 5). Pridaj **čítací** HTTPS endpoint pre dochádzkový systém:

* `GET /api/public/export/punches?since_id=<číslo>&limit=<=5000>` vracia presne ten istý CSV súbor ako „Export pre Access“ (funkcia `buildPunchExportCsv`), len pre organizáciu priradenú tokenu.
* Autentifikácia: `Authorization: Bearer <token>`. Token sa vytvorí v administrácii (zobrazí sa raz), v databáze sa ukladá **len jeho SHA-256**, má názov, dátum vytvorenia, posledné použitie a dá sa zrušiť. Tokeny sú len na čítanie.
* Limity: obmedzenie počtu požiadaviek na token, odpoveď 401/403 bez podrobností, každé použitie a zrušenie do `audit_log`.
* Žiadne mená ani e-maily; žiadne CORS pre prehliadače (volá to len Access zo servera/počítača).
* Testy: neplatný/zrušený token, token inej organizácie, `since_id`, limit; kontraktový test ostáva zelený.

Nemeň `contract/`. Spusti `bun run lint`, `bun run test`, `bun run build`.
