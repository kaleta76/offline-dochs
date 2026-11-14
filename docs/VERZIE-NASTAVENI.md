# Verzie nastavení výpočtu (etapa 1a, migrácia 0022)

Záväzný návrh je v `docs/ARCHITEKTURA.md`, kapitola 5. Tento dokument opisuje, ako je urobený: úložisko, pravidlá platnosti, spárovanie s Accessom, snímka uzavretého mesiaca a nasadenie. V etape 1a `src/lib/engine.ts` ostal bez zmeny; výpočet nad celým modelom je etapa 1b (kapitola „Výpočet nad modelom“ nižšie).

## Úložisko

- **`settings_versions`**: jedna verzia nastavení = jeden **nemenný** riadok (organizácia, poradie `ord`, pôvod `terminal` alebo `access`, „platí od mesiaca“ `valid_from`, dôvod vzniku, model `config`). Model má tvar kontraktu 1.5.0 bez zamestnancov (`contract/config-export.schema.json`). Úprava je vždy nový riadok; UPDATE a DELETE odmietne spúšťač aj pre funkcie.
- **Platná verzia pre mesiac**: najvyššie `ord` spomedzi verzií, ktorých `valid_from` nie je neskôr než mesiac. Jej pôvod určuje, komu mesiac patrí. Verzia s prázdnym `valid_from` je uložená a na časovej osi nie je.
- **Plán z Accessu** (`employee_month_plan`) patrí verzii, s ktorou prišiel (`version_id`). Nový import starší plán neprepíše ani nezmaže; plán za mesiace pred platnosťou verzie je uložený a nepoužije sa.
- **`access_config`** je od migrácie pohľad s pôvodnými stĺpcami (verzia z Accessu platná pre aktuálny mesiac). Číta ho staršia aplikácia v zariadeniach (automatické schvaľovanie opráv ho čítalo do súkromnej migrácie 0023, pozri nižšie); pôvodná tabuľka je odložená v schéme `settings_archive` kvôli návratu.
- **`organization_settings`, `organization_codes`, `organization_holidays`** ostali s údajmi. Výpočtové kľúče a sviatky sa z nich nečítajú; ich zmenu zo staršej aplikácie databáza odmietne s výzvou obnoviť aplikáciu. `organization_settings` ďalej drží nastavenia mimo výpočtu, `organization_codes` SAP kódy.

Klient do tabuliek verzií a snímok nezapisuje ani z nich nečíta priamo. Všetko ide cez funkcie, ktoré overia prihlásenie, rolu správcu a vlastnú organizáciu.

## Jediné čítanie nastavení

`loadSettingsForMonth` v `src/lib/settings-model.ts` (RPC `settings_for_month`, jeden POST dopyt). Číta ním výpočet (`month.ts`), tlačidlá terminálu (`use-terminal-actions.ts`) aj Správa. Iné čítanie nastavení výpočtu v kóde nie je. Do zariadenia sa z odpovede kešuje len overená projekcia tlačidiel, nikdy plán.

## Terminálová verzia

- Nová organizácia ju dostane pri registrácii (spúšťač na `organizations`, tá istá transakcia) z predvolených hodnôt: pravidlá, sedem kódov ako prerušenia s tlačidlami, sviatky, jeden fond.
- Existujúce organizácie ju pri migrácii dostali zo svojich vtedajších hodnôt, s platnosťou od mesiaca najstaršieho razenia.
- Úprava v Správe (karta Servis, „Pravidlá výpočtu“ a „Sviatky“) uloží novú verziu platnú od mesiaca, ktorý správca zvolí: predvolene aktuálny, najskôr najstarší neuzavretý, najviac 12 mesiacov dopredu. Pri mesiaci, ktorý patrí Accessu, je karta len na čítanie a databáza úpravu odmietne.

## Spárovanie a odpárovanie

- **Import z Accessu** (`settings_import_access`): súbor skontroluje doterajšia kontrola, potom vznikne verzia z Accessu a jej plán. Náhľad ukáže, komu mesiac patrí dnes a v ktorých predchádzajúcich mesiacoch sú neuzavretí zamestnanci; správca môže zvoliť skoršiu platnosť („Použiť Access aj pre október“). Ostrý import vyžaduje zaškrtnuté potvrdenie. Starší súbor než posledný prijatý sa odmietne.
- **Odpárovanie** (`settings_unpair`, tlačidlo v karte „Pravidlá výpočtu“, len správca, potvrdenie, audit `settings.unpaired`): od zvoleného mesiaca platí nová terminálová verzia, buď kópia posledných nastavení z Accessu (predvolené), alebo posledná terminálová verzia. Pred potvrdením sa ukáže rozdiel hodnôt. Verzie z Accessu ostávajú v histórii; znova spárovať sa dá novým importom.
- Skoršia platnosť nič neprepisuje: otvorený mesiac sa počíta pri zobrazení podľa platnej verzie, uzavretý zo snímky.

## Uzavretý mesiac

Rozhodnutie vlastníčky (13. 11. 2026): po uzavretí sa nemenia parametre, výpočet ani fond; jediná cesta k zmene je vrátiť **poslednú** uzávierku zamestnanca a uzavrieť mesiac znova.

- Pri vložení uzávierky databáza sama uloží snímku (`month_closure_snapshots`): verziu nastavení platnú pre mesiac, denný fond zamestnanca a odtlačok razení (počet platných razení a posledný hash reťaze mesiaca).
- Ten, kto uzatvára, uloží v tej istej transakcii výsledok mesiaca (súčty a čísla po dňoch, RPC `close_month`). Počíta ho `engine.ts` v jeho prehliadači; databáza ho neprepočítava, ale nezmyselný nepustí (`month_result_problem`): presne známe kľúče, denné hodnoty v rozsahu 0 až 2880 minút (zostatok −2880 až 2880), každý deň je ten istý deň mesiaca v poradí, v každom dni súčet = práca + kredit a zostatok = súčet − fond, súčty mesiaca = súčet dní, a počet razení sedí s jej vlastným. Pri chybe sa uzávierka nevykoná a správa nesie dôvod. Výsledok sa dá zapísať raz a potom sa nemení. Kontrola platí pre tvar `engine` = 1: keď etapa 1b zmení tvar výsledku (`RESULT_ENGINE` v `settings-model.ts`), treba v tej istej zmene upraviť aj `month_result_problem`, inak sa uzávierka s novým tvarom odmietne.
- Uzavretý mesiac sa zobrazuje z uloženého výsledku. Kontrolný prepočet z pripnutej verzie a fondu len ukáže, či s ním sedí. Uzávierka bez výsledku (staršia aplikácia, uzávierky spred migrácie) sa počíta z pripnutej verzie a fondu.
- Vrátiť sa dá len posledná uzávierka zamestnanca (správca, Môj tím); snímka sa zmaže s ňou. Zrušenie celej testovacej organizácie je výnimka.
- Prijatie razenia do uzavretého mesiaca a to, kto smie mesiac uzavrieť, sa nezmenilo. Mesiace, ktoré patria Accessu a uzatvára ich Access, dostanú snímku až so správou o uzávierke (etapa 5).

## Prenos organizácie

`settings_versions` a `month_closure_snapshots` sú v `org_transfer.spec()`, ich odkazy v `org_transfer.import_refs()`. Súbor exportovaný pred migráciou 0022 sa na serveri po migrácii neimportuje (nesie tabuľku `access_config`); oba servery musia byť na rovnakej migrácii. Súkromný balík 0015 má vlastnú kópiu zoznamu tabuliek: po 0022 ho neinštalujte znova v staršej verzii.

## Automatické schvaľovanie opráv a model nastavení (súkromná migrácia 0023)

Oprava `request_correction` (súkromný balík, v repozitári nie je; funkcia je z 0013 a 0014) po 0022 posudzovala typ opravy podľa pohľadu `access_config`, ktorý ukazuje len verziu z Accessu platnú pre **aktuálny** mesiac. Pre mesiac, ktorý patrí terminálu (každá nová organizácia, aj po odpárovaní), bol pohľad prázdny, a preto sa sama schvaľovala už len oprava `WORK`; prerušenia išli vždy na ručné schválenie. Migrácia 0023 to opravuje:

- Typ opravy (odchod s iným kódom než `WORK`) sa posudzuje podľa **verzie nastavení platnej pre mesiac, do ktorého oprava patrí** (`settings_version_for(organizácia, mesiac času opravy v Europe/Bratislava)`), nie podľa aktuálneho mesiaca. Oprava z minulého mesiaca sa teda posudzuje podľa verzie, ktorá platila vtedy.
- Pravidlo z 0013 ostáva: kód má v `terminal_code_map` práve jedno priradenie a príslušné prerušenie v `interruptions` je práve jedno. Čo model nenesie (chýba verzia, priradenie alebo prerušenie), ostáva na ručné schválenie. Príznak `needs_approval` sa číta podľa pôvodu verzie (nižšie).
- **Mesiace z Accessu:** správanie je rovnaké ako pred 0022. Prerušenie sa schváli samo, ak nemá `needs_approval = true` (Access príznak pri `false` neposiela, chýbajúci príznak sa berie ako `false`).
- **Mesiace patriace terminálu (opatrne, rozhodnutie majiteľky 14. 11. 2026):** terminálový model z 0022 príznak `needs_approval` nenesie a v Správe sa zatiaľ nedá nastaviť. Prerušenie sa tu preto schváli samo **len ak má v terminálovej verzii výslovne `needs_approval = false`**. Dnes teda platí to, čo pred 0022: sama sa schváli len oprava príchodu a odchodu (`WORK`), ostatné čaká na vedúceho. Voľnejšie pravidlo (chýbajúci príznak = povolené) sa neprijalo. Súhlas vedúceho (`AutoApprovalConsent`) hovorí o prerušeniach bez príznaku „vyžaduje schválenie“; v mesiaci terminálu je správanie užšie než text, teda bezpečné. Keď etapy 2 až 4 pridajú editor prerušení v termináli (príznak výslovne nastaviteľný), treba text zosúladiť s pravidlom.
- Nemení sa nič iné: overenie zariadenia, limity (14 dní, 5 za deň, 5 minút do budúcnosti), poradie razení dňa, dôvody `manual_reason`, audit, hash reťaz razení ani podpis funkcie. Klient sa nemení: tlačidlá a „Môj mesiac“ čítali model pre mesiac už cez `loadSettingsForMonth`.

Nasadenie: súkromný balík `0023_balik` (migrácia, kontrola, návrat) v novej karte SQL editora, kontrola má mať všetky riadky `OK`. Poradie voči aplikácii je ľubovoľné, klient sa nemení. Vyžaduje 0014 a 0022. Návrat: `0023_spat_zachranny.sql` vráti znenie z 0014 (nič sa nestratí).

## Nasadenie a návrat

1. Záloha (`docs/ZALOHA-DATABAZY.md`).
2. `docs/migracie/0022_verzie_nastaveni.sql` celý naraz v novej karte SQL editora; na konci súboru sú štyri kontrolné dopyty.
3. Až potom nová aplikácia. Aplikácia bez migrácie ukáže hlásenie, že treba spustiť 0022; staršia aplikácia po migrácii ďalej razí a ukazuje tlačidlá, len import z Accessu a úpravu pravidiel odmietne, kým sa neobnoví.

Návrat: najprv staršia aplikácia, potom `0022_spat_zachranny.sql`. Stratí sa história verzií a snímky uzavretých mesiacov (podrobne v hlavičke skriptu); uzávierky, razenia a audit ostanú.

Migrácia nemení `punches`, `profiles`, `punches_chain`, vzorec hash reťaze ani export razení.

## Terminálový model a kódy razení Accessu (`punch_codes`)

Terminálový model nenesie kódy razení Accessu: pole `punch_codes` je prázdne a čísla `start_punch_code` a `end_punch_code` pri prerušeniach (100, 101, …) sú pozostatok číslovania z Accessu. Terminál razí slovnými kódmi (`WORK`, `DOCTOR`, …), prekladá ich cez `terminal_code_map` a výpočet tieto čísla nečíta (používa ich len kontrola súboru z Accessu v `src/lib/access-config.ts`). Prísny režim `contract/tools/verify_config.py --strict` preto na terminálovom modeli hlási upozornenia o chýbajúcich kódoch razení. Je to zámer, nie chyba: model sa nedopĺňa a upozornenia sa neriešia. Rozhodnutie majiteľky 14. 11. 2026.

## Výpočet nad modelom (etapa 1b)

`computeDay` v `src/lib/engine.ts` ostáva čistá funkcia bez I/O. Vstupy mu z modelu pripraví `engineInputs` v `src/lib/settings-model.ts`: pravidlá (obed, zaokrúhlenie so smerom, okno práce, razený obed, duplicita, automatická oprava), prerušenia s vlastnosťami podľa kódu terminála (`terminal_code_map` spojená s `interruptions[]`) a režimy (`regimes[]`). Deň, plán a režim dňa môže volajúci doplniť (`DayInput.plan`, `DayInput.regime`); bez nich platí denný fond zamestnanca a pravidlá verzie. Pôvodný tvar volania (štyri polia `EngineSettings`) funguje ďalej a počíta ako terminál pred 1b; `settingsFromRows` ostáva len pre `contract/scenare/referencne_saldo.ts`.

Čo sa počíta (prepis Accessu: `SparujRazenia`, `SpracujDen`, `TrvanieIntervalu`, `SumarDna`, `ZaokruhliCas`):

- Razenia sa párujú ako v Accesse: príchod pri otvorenom prerušení je jeho koniec, odchod za posledným príchodom je odchod, odchod pred ním je obed (ak `unlabeled_out_is_lunch`), ostatné kódy cez `terminal_code_map`. Čas je minúta od polnoci, vteriny sa zahadzujú.
- Práca sa orezáva oknom práce (okno z plánu zamestnanca má prednosť pred oknom z pravidiel). Obed je skutočný čas, `UNPAID` sa nepočíta, `COUNTED` je skutočný čas alebo celý denný fond, ak interval dosiahne `full_day_min` (inak `full_day_obstacle_min`).
- Automatický obed sa odpočíta z práce, keď základ (práca + započítaný čas prerušení s `counts_to_lunch_base`) dosiahne prah (vrátane), deň má fond a nebol razený obed; odpočet nikdy nezníži prácu pod nulu. Razený obed upravuje `lunch_recorded_mode` (0 skutočný, 1 aspoň minimum, 2 vždy presne minimum).
- Zaokrúhlenie má smer podľa `rounding_mode` (0 príchod nahor a odchod nadol, 1 oboje nahor, 2 oboje nadol, 3 najbližšie). Zaokrúhľuje sa len prvý príchod dňa a posledný odchod dňa; návrat z prerušenia nie.
- Celodenné kódy (`full_day_only`, dovolenka a PN) dajú celý denný fond a nulové saldo; v dni bez fondu nič.
- Prerušenie bez návratu: pri `auto_repair_mode` 2 a vlastnosti `auto_end_of_shift` sa deň doplní do fondu, pri 0 a 1 ostane otvorený s anomáliou `UNFINISHED_INTERRUPTION` (v tabuľke „chýba návrat“) a nič sa nedoplní.
- Duplicita (rovnaký kód a smer v rámci `duplicate_punch_window_min`), paralelné prerušenia v tej istej minúte, anomálie (`DOUBLE_ARRIVAL`, `END_WITHOUT_START`, …) sa hlásia vo výsledku (`anomalies`).

**Nepotvrdený deň.** Výsledok nesie `unconfirmed`, keď sa saldo nedá potvrdiť, a nikdy sa nehádže: `no_plan` (mesiac patrí Accessu, plán z Accessu terminál zatiaľ nenačítal), `unknown_calc` (prerušenie s hodnotou `calc`, ktorú výpočet nepozná, sa nepočíta), `unknown_code` (razenie s kódom, ktorý model nepozná, sa vynechá). V tabuľke je to štítok „nepotvrdené“, v prehľade tímu pri saldo. `no_plan` dostanú teraz všetky dni mesiaca, ktorý patrí Accessu, kým nepribudne čítanie plánu (samostatná migrácia, súkromné tabuľky).

**Rozdiely oproti terminálu pred 1b** (rozhodnutie majiteľky 13. 11.: dnešný výpočet je len otestovaný, nemusí sa zachovať):

1. Predvolená terminálová verzia má `auto_repair_mode` 0, preto sa odchod k lekárovi, na služobnú cestu a pod. bez návratu už **nedopĺňa do fondu**; deň ostane otvorený. **Rozhodnutie majiteľky 14. 11. 2026:** terminál odchod ani prerušenie bez návratu nedopĺňa; zamestnanci by to zneužívali a odchod by nerazili, lebo by mali fond splnený vždy. Predvolená hodnota ostáva 0 a migrácia na jej zmenu nebude. Dopĺňať môže len Access (režim 2 alebo schválená oprava).
2. Služobná cesta je započítané prerušenie (nie práca) s príznakom základu obeda; súčet dňa sa nemení, mení sa rozdelenie práca a kredit. Služobné vzdialenie sa počíta (dnes sa nepočítalo), súkromné prerušenie je `UNPAID`.
3. Dovolenka a PN sú rovnaké (celý fond, saldo 0); PN predtým malo očakávaný čas 0.
4. Vteriny sa zahadzujú pri každom razení, preto sa výsledok môže líšiť o minútu od výpočtu z rozdielu milisekúnd.
5. V dni bez fondu (víkend, sviatok) sa automatický obed neodpočíta.
6. **Rozdiel oproti textu kontraktu v základe obeda (rozhodnuté 14. 11. 2026).** Kontrakt 1.5.0 (`counts_to_lunch_base`) hovorí, že interval započítaný ako celý deň (dosiahol `full_day_min`) do základu obeda nevstupuje. Kód Accessu (`mod_08.SumarDna`) ho do základu pripočíta celým fondom a terminál robí to isté. Majiteľka rozhodla, že správne je správanie Accessu: služobná cesta je práca a počas nej môže zamestnanec ísť na obed, takže odpočet obeda z odpracovaného času je v poriadku (príklad: cesta 7:00–14:00, práca 14:00–15:30, fond 7:30 dá práca 1:00, cesta 7:30, saldo +1:00). Text kontraktu je v tomto bode nepresný a opraví sa pri verzii 1.6.0; do tej doby sa `contract/` nemení. Odpočet obeda Access zráža z práce a pri prerušení s príznakom ho zastaví na nule; terminál ho zastaví na nule vždy.

**Uzavretý mesiac** sa neprepočítava: tvar uloženého výsledku ani `RESULT_ENGINE` (1) sa nemenia, preto `month_result_problem` ostáva bez migrácie. Zmena výpočtu sa v starých uzávierkach prejaví len ako `matches = false` pri kontrolnom prepočte; platí uložený výsledok.

**Čo sa ešte musí overiť.** Referenčné saldá z Accessu pre zlatý scenár `contract/scenare/2026-10` (Access scenár ešte nepočítal); `ocakavane_saldo_2026-10.csv` je z dnešného enginu a prepočíta sa len na pokyn majiteľky.

**Opravy z Accessu (`mod_09_AutoOprava`), ktoré terminál nerobí.** Access dopĺňa „virtuálne razenia“: trieda A (chýbajúci začiatok alebo koniec obeda) a trieda B (zabudnutý odchod z práce a prerušenie bez návratu, odhad podľa fondu, najviac po koniec okna práce). Režim 0 nič, 1 (predvolený v Accesse) triedu A automaticky a B ako návrh na schválenie, 2 všetko automaticky; ďalej `auto_repair_target` (cieľ „do konca okna práce“) a `auto_repair_cases` (výber prípadov). Terminál pri režime 0 a 1 nič nedopĺňa (zhoda s Accessom, kým sa návrh neschváli) a pri režime 2 doplní len prerušenie bez návratu do fondu. Nerobí: doplnenie zabudnutého odchodu z práce, zastavenie na konci okna práce, cieľ „do konca okna“, výber prípadov a schválené opravy z Accessu. Mesiac, ktorý patrí Accessu, je preto celý `nepotvrdený`; doplní sa v etape 3 spolu s čítaním plánu a opráv z Accessu.
