# Verzie nastavení výpočtu (etapa 1a, migrácia 0022)

Záväzný návrh je v `docs/ARCHITEKTURA.md`, kapitola 5. Tento dokument opisuje, ako je urobený: úložisko, pravidlá platnosti, spárovanie s Accessom, snímka uzavretého mesiaca a nasadenie. Výpočet nad celým modelom je etapa 1b; v 1a `src/lib/engine.ts` ostáva bez zmeny a z modelu číta len to, čo čítal doteraz (zaokrúhlenia, obed, predvolený fond, sviatky).

## Úložisko

- **`settings_versions`**: jedna verzia nastavení = jeden **nemenný** riadok (organizácia, poradie `ord`, pôvod `terminal` alebo `access`, „platí od mesiaca“ `valid_from`, dôvod vzniku, model `config`). Model má tvar kontraktu 1.5.0 bez zamestnancov (`contract/config-export.schema.json`). Úprava je vždy nový riadok; UPDATE a DELETE odmietne spúšťač aj pre funkcie.
- **Platná verzia pre mesiac**: najvyššie `ord` spomedzi verzií, ktorých `valid_from` nie je neskôr než mesiac. Jej pôvod určuje, komu mesiac patrí. Verzia s prázdnym `valid_from` je uložená a na časovej osi nie je.
- **Plán z Accessu** (`employee_month_plan`) patrí verzii, s ktorou prišiel (`version_id`). Nový import starší plán neprepíše ani nezmaže; plán za mesiace pred platnosťou verzie je uložený a nepoužije sa.
- **`access_config`** je od migrácie pohľad s pôvodnými stĺpcami (verzia z Accessu platná pre aktuálny mesiac). Číta ho automatické schvaľovanie opráv a staršia aplikácia v zariadeniach; pôvodná tabuľka je odložená v schéme `settings_archive` kvôli návratu.
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

## Nasadenie a návrat

1. Záloha (`docs/ZALOHA-DATABAZY.md`).
2. `docs/migracie/0022_verzie_nastaveni.sql` celý naraz v novej karte SQL editora; na konci súboru sú štyri kontrolné dopyty.
3. Až potom nová aplikácia. Aplikácia bez migrácie ukáže hlásenie, že treba spustiť 0022; staršia aplikácia po migrácii ďalej razí a ukazuje tlačidlá, len import z Accessu a úpravu pravidiel odmietne, kým sa neobnoví.

Návrat: najprv staršia aplikácia, potom `0022_spat_zachranny.sql`. Stratí sa história verzií a snímky uzavretých mesiacov (podrobne v hlavičke skriptu); uzávierky, razenia a audit ostanú.

Migrácia nemení `punches`, `profiles`, `punches_chain`, vzorec hash reťaze ani export razení.
