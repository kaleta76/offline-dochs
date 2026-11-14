# Verzie nastavení výpočtu (etapa 1a, migrácia 0022)

Záväzný návrh je v `docs/ARCHITEKTURA.md`, kapitola 5. Tento dokument opisuje, ako je urobený: úložisko, pravidlá platnosti, spárovanie s Accessom, snímka uzavretého mesiaca a nasadenie. Výpočet nad celým modelom je etapa 1b; v 1a `src/lib/engine.ts` ostáva bez zmeny a z modelu číta len to, čo čítal doteraz (zaokrúhlenia, obed, predvolený fond, sviatky).

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
