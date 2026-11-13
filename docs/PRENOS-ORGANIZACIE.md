# Prenos organizácie na iný server

Správca môže celú svoju organizáciu (účty s hashmi PIN a hesiel, osobné čísla, zariadenia, razenia s hash reťazou, opravy, uzávierky, nastavenia, konfigurácia z Accessu, audit) vyexportovať do súboru a na inom serveri ju znova vytvoriť. Identifikátory zostávajú, preto zostáva rovnaký aj **kód organizácie** a zamestnanci sa prihlásia rovnakými údajmi ako predtým.

> **Stav:** hotový je **export** (migrácia [`0016`](migracie/0016_prenos_organizacie_export.sql), karta *Prenos organizácie na iný server*) aj **import tlačidlom** na cieľovom serveri (migrácia [`0017`](migracie/0017_prenos_organizacie_import.sql), karta *Import organizácie z iného servera*). Obe karty sú v skrytej karte Servis. **Ešte nie je:** upozornenie „organizácia sa presťahovala“ na starom serveri a Docker/GitHub nasadenie nového servera.

## Ako má celý prenos prebiehať

1. Na **cieľovom serveri** sa správca zaregistruje a vytvorí organizáciu (pripraví sa tým prihlasovanie a prázdna databáza).
2. Na **pôvodnom serveri** v skrytej karte Servis spustí *Prenos na iný server*, zvolí, či sa majú zamknúť razenia, a zadá heslo súboru. Aplikácia stránkovaním vyžiada údaje (`org_export_begin`, `org_export_page`), v prehliadači ich zašifruje heslom a stiahne súbor. Heslo sa na server neposiela. Potom prenos uzavrie (`org_export_finish`): organizácia sa označí ako **testovacia** a správca sa presmeruje do okna zrušenia.
3. Na **cieľovom serveri** správca tej čerstvej prázdnej organizácie v karte Servis (`?servis=1`) otvorí *Import organizácie z iného servera*, vyberie súbor a zadá heslo. Prehliadač súbor dešifruje a po častiach nahrá, databáza ho skontroluje. Po potvrdení v dialógu (súhlas a opísanie názvu prázdnej organizácie) databáza prázdnu organizáciu aj s účtom správcu **nahradí** organizáciou zo súboru, overí ju a vypíše **kód potvrdenia prenosu** (`XXXX-XXXX`). Správca sa odhlási a prihlási účtom z prenesenej organizácie; kód potom vidí v tej istej karte znova.
4. Na **pôvodnom serveri** správca zadá kód a názov organizácie (`org_transfer_confirm_and_delete`). Organizácia sa zruší až vtedy. Bez správneho kódu sa zrušiť nedá.

Terminály sa na nový server neprepnú samy a zariadenia sa musia na novom serveri schváliť znova, pozri nižšie „Čo sa stane s terminálmi“.

## Čo dodáva migrácia 0016

| Funkcia | Čo robí |
|---|---|
| `org_export_begin(_lock boolean default true)` | Založí prenos, voliteľne zamkne razenia a uloží kontrolné súčty údajov. Vráti id prenosu, hlavičku súboru a zoznam tabuliek s počtami. Nový export nahrádza predchádzajúci neukončený. |
| `org_export_page(_transfer, _rel, _offset, _limit)` | Jedna stránka tabuľky (najviac 5 000 riadkov, odporúča sa 2 000). Tabuľka musí byť zo zoznamu prenosu. Riadky vracia ako **text** (pole `rows` je reťazec s JSON), pozri „Súbor a šifrovanie“. |
| `org_export_finish(_transfer, _received)` | Overí, že súbor je úplný (`_received` = počty prijatých riadkov) a že sa údaje počas exportu nezmenili; označí organizáciu ako testovaciu. |
| `org_transfer_status()` | Stav prenosu, či je zámok aktívny, a zmeny od exportu (pre obrazovku). |
| `org_transfer_cancel()` | Zruší prenos, odomkne razenia, vráti označenie „testovacia“, ak ho nastavil prenos. |
| `org_transfer_confirm_and_delete(_receipt, _confirm_name, _accept_changes)` | Zruší pôvodnú organizáciu po potvrdení kódom. Údaje, ktoré od exportu pribudli, treba výslovne odsúhlasiť (`_accept_changes = true`), inak by sa stratili. |

Všetky volá prihlásený **správca** a pracujú vždy len s jeho organizáciou. Pomocné funkcie a tabuľka `org_transfer.transfers` (história prenosov) sú v schéme `org_transfer`, ktorú REST API nevidí.

## Ochrany

- **Zámok razení** (voliteľný): kým trvá, databáza odmietne nové razenia organizácie (SQLSTATE `55000`). Terminál také razenie nezahodí ani nezaparkuje, ukladá si ho a skúša znova, takže po zrušení prenosu sa odošle samo. Začiatok exportu počká na práve rozpísané razenia (najviac 5 s), takže sa dostanú do súboru. Zámok nedokončeného exportu sám vyprší po 2 hodinách. Zámok dokončeného exportu trvá, kým prenos nepotvrdíte alebo nezrušíte.
- **Ochrana pred predčasným zrušením:** organizáciu s rozpracovaným prenosom nejde zrušiť (spúšťač na `organizations` zastaví aj priame `delete_test_organization`), kým prenos nepotvrdíte kódom alebo nezrušíte.
- **Kód potvrdenia** sa odvodzuje z kontrolných súčtov údajov (id organizácie, počty a odtlačky tabuliek, poradie hashov razení). Cieľ ho vypíše až po úspešnom importe a overení. Je to poistka proti omylu, nie tajomstvo.
- **Zmeny od exportu:** `org_transfer_status` a zrušenie porovnajú dnešný stav s exportom. Samovoľné zmeny (`devices.last_seen_at`, príznak testovacia, audit) sa nepočítajú.
- **Pôvodná organizácia** (`00000000-0000-4000-8000-000000000001`) sa dá exportovať, ale nedá sa označiť ako testovacia ani zrušiť (platí 0007).
- Súbor vo formáte 2 nemá súčet celého súboru, obsah overujú odtlačky tabuliek, počty, reťaz hashov a poradie razení pri importe.

## Obrazovka (Správa → Servis a testovanie → Prenos organizácie na iný server)

Karta je v skrytej časti Servis (`serviceVisibility`), oprávnenia vynucuje databáza. Podľa stavu prenosu ukazuje:

- **Bez prenosu:** formulár exportu: voľba *Zamknúť razenia na čas prenosu* (predvolene zapnutá), heslo súboru (aspoň 12 znakov) a jeho zopakovanie. Po spustení ukazuje priebeh (kľúč, začiatok, čítanie *N z M* riadkov, šifrovanie, uzavretie) a tlačidlo *Prerušiť*. Chyba alebo prerušenie prenos na serveri **sám zruší** (odomkne razenia), aby organizácia nezostala zamknutá.
- **Po exporte:** súbor `prenos-<kód organizácie>-<dátum a čas>.dochs-enc` sa stiahne a hneď sa skontroluje (dešifruje sa a overia sa počty riadkov všetkých tabuliek). Organizácia je označená ako testovacia. Karta ukáže okno na zrušenie: pole *Kód potvrdenia z cieľového servera* a presný názov organizácie. Tlačidlo *Zrušiť pôvodnú organizáciu…* sa odomkne až po správnom kóde a názve; ak sa údaje od exportu zmenili, treba výslovne odsúhlasiť, že sa stratia. Potom sa otvorí dialóg, ktorý vyžaduje potvrdenie, že na každom termináli je „čaká na odoslanie: 0“ (razenia vo fronte by sa zrušením stratili). Po zrušení sa správca odhlási a presmeruje na prihlásenie.
- **Skontrolovať uložený súbor:** rozbaľovacia časť, v ktorej správca vyberie súbor, ktorý má uložený, a zadá heslo; karta overí, že sa dá otvoriť a je úplný, a upozorní, ak je súbor z inej organizácie. Súbor sa nikam neodosiela.
- **Po opätovnom načítaní stránky** šifrovaný súbor v prehliadači už nie je (drží sa len v pamäti). Karta to povie: ak ho správca nemá uložený, prenos zruší (*Zrušiť prenos*) a export zopakuje.
- **Rozpracovaný prenos** (napr. po zatvorení karty počas exportu): ponúkne sa *Zrušiť rozpracovaný prenos*.
- **Pôvodná organizácia** sa dá exportovať ako kópia, ale nedá sa zrušiť: karta ponúkne len *Ukončiť prenos* (odomkne razenia).

## Súbor a šifrovanie

- Obsah je JSON `{"meta": …, "tables": {"<schéma.tabuľka>": [riadky…], …}}` (formát 2). Šifruje sa **v prehliadači** (WebCrypto): kľúč z hesla cez PBKDF2-HMAC-SHA256 (600 000 iterácií, náhodná soľ), obsah AES-256-GCM po blokoch po 1 MiB. Hlavička (`DOCHSENC`, verzia, parametre) je overovaná; poradie, odstránenie či zámena blokov sa pri dešifrovaní odhalí. Heslo sa nikam neposiela a nedá sa obnoviť. Implementácia: `src/lib/org-transfer-crypto.ts`.
- **Riadky sa do súboru vkladajú ako text, presne ako ich vrátila databáza.** Kontrolné súčty sa počítajú z textu `to_jsonb(riadok)`, v ktorom je napr. `7.50` alebo vnorené `1.0`. Ak by ich prehliadač prečítal cez `JSON.parse` a zapísal cez `JSON.stringify`, stali by sa `7.5` a `1`, súčet na cieľovom serveri by sa nezhodoval a import by sa odmietol (overené: import takto prepísaného súboru skončí chybou *obsah riadkov sa líši od súboru*). Preto `org_export_page` vracia `rows` ako reťazec a `exportOrganization` (`src/lib/org-transfer.ts`) ho do súboru vloží bez spracovania. Pri úprave exportu to treba zachovať.
- Súbor je potrebné pred importom dešifrovať. Na to slúži [`tools/prenos-desifruj.mjs`](../tools/prenos-desifruj.mjs) (Node.js 18 a novší, bez závislostí; formát číta nezávisle od aplikácie cez `node:crypto`): `node tools/prenos-desifruj.mjs prenos-XXXX-….dochs-enc [vystup.json] [--prepisat]`. Heslo sa pýta bez zobrazenia (v skriptoch ho možno dať do premennej `PRENOS_HESLO`, nie do príkazového riadka). Nástroj zapisuje do dočasného súboru a premenuje ho až po overení všetkých blokov, takže pri zlom hesle či poškodení nezostane polovičný výstup a existujúci súbor sa nestratí; bez `--prepisat` existujúci výstup neprepíše. Výstup (JSON formátu 2) obsahuje hashe hesiel a osobné čísla, preto sa po importe maže. Importuje ho balík 0015 (`prenos_import.cmd`).

## Import tlačidlom (migrácia 0017)

Kto a kam: importovať smie len **správca organizácie, v ktorej je jediným účtom** a ktorá nemá razenia, opravy, žiadosti, uzávierky, plán ani konfiguráciu z Accessu a nemá rozpracovaný vlastný export. Pôvodnú organizáciu nahradiť nejde. Organizácia s údajmi sa nikdy neprepíše; ak organizácia zo súboru (alebo jej účty, razenia, kód) na serveri už je, import sa odmietne.

| Funkcia (volá prihlásený správca) | Čo robí |
|---|---|
| `org_import_status()` | či je organizácia spôsobilá (s dôvodmi), rozpracovaný import, kód potvrdenia posledného importu tejto organizácie |
| `org_import_begin(hlavička)` | skontroluje hlavičku súboru voči serveru (formát 2, tabuľky, stĺpce) a založí import; predchádzajúci rozpracovaný import zahodí |
| `org_import_chunk(import, tabuľka, poradie, riadky)` | uloží časť riadkov do odkladacej tabuľky `org_transfer.import_rows`; tá istá časť sa dá poslať znova |
| `org_import_check(import)` | skontroluje celý súbor a cieľ; nič v aplikácii nemení |
| `org_import_commit(import, názov)` | v jednej transakcii zmaže prázdnu organizáciu, vloží organizáciu zo súboru, overí ju a vráti kód potvrdenia; pri akejkoľvek chybe sa nezmení nič |
| `org_import_cancel()` | zahodí rozpracovaný import |

**Súboru sa neverí** (mohol ho vyrobiť alebo upraviť ktokoľvek, kto pozná formát). Databáza preto pri kontrole a zápise vynucuje:

- každý riadok patrí organizácii zo súboru a každý odkaz (účet, nadriadený, zariadenie, razenie, žiadosť) vedie na riadok z toho istého súboru. Zoznam odkazov je v `org_transfer.import_refs()`; **nový stĺpec typu uuid alebo s cudzím kľúčom, ktorý v zozname chýba, import zastaví**, kým sa nedoplní;
- prihlasovacie účty sa nevkladajú tak, ako sú v súbore: `role` a `aud` sú vždy `authenticated` (rola účtu ide do prístupového tokenu, `service_role` by obišla všetky pravidlá), žiadny super admin, SSO ani telefón, tokeny na obnovu sa nulujú, `instance_id` je tunajšie, v `app_metadata` sú povolené len kľúče z `org_transfer.import_app_meta_keys()`, identity len typu e-mail;
- identifikátory zo súboru nesmú na cieli existovať; čísla razení sa zachovajú, len ak sa s ničím nezrazia a nie sú neprimerane vysoké, inak sa prečíslujú v rovnakom poradí (hash reťaz ostáva platná);
- po vložení sa overia počty a odtlačky každej tabuľky, hash reťaz a poradie razení (rovnako ako pri operátorskom importe) a to, že žiadny účet nemá inú rolu než `authenticated`;
- názvy tabuliek a stĺpcov v príkazoch sú len z `org_transfer.spec()` a z katalógu databázy; funkcie sú `SECURITY DEFINER` s pevným `search_path`, bez práv pre `anon`; veľkosť častí aj celého importu je obmedzená (`org_transfer.import_limits()`: 1,5 milióna riadkov).

Súbor je dôveryhodný len pre vlastné údaje organizácie: kto smie na serveri založiť organizáciu, vie do nej cez import vložiť, čo chce (aj účty), ale nič mimo nej.

Počas zápisu sú na pár sekúnd vypnuté spúšťače aplikácie, preto ostatné organizácie v tej chvíli so zápisom čakajú (terminál razenie nezahodí, skúsi znova). Zvyšky auditu po skoršom zrušení tej istej organizácie na cieli sa od účtov odpoja (`actor = NULL`, pôvodný účet v `details.actor_pred_importom`), takže opakovaný import po zmazaní prejde.

V prehliadači (`src/lib/org-transfer-import.ts`) sa dešifrovaný súbor **nečíta cez `JSON.parse`**: krája sa podľa zátvoriek a riadky idú na server ako pôvodný text (inak by `7.50` zmenilo zápis a overenie odtlačkov by import vrátilo). Časti majú najviac 1000 riadkov a 1 MB; pri zlyhaní spojenia sa časť pošle znova, zápis sa neopakuje nikdy. Ak sa spojenie preruší počas zápisu, výsledok nie je istý: po obnovení stránky to ukáže prihlásenie (starý účet už neexistuje = import prebehol).

Operátorský postup (dešifrovanie nástrojom a súkromný balík 0015 cez `psql`) ostáva ako záloha pre organizácie nad limit a pre servery bez migrácie 0017.

## Overenie

- Import (0017): skúšobný Postgres, 28 kontrol okruhu export → import → kód odomkne zrušenie na zdroji, **55 útokov so 174 kontrolami** (účet s rolou `service_role`, super admin, cudzie `organization_id`, `user_id`, `manager_id`, zariadenie a razenie cudzej organizácie, kolízie id, e-mailov a kódu, nepovolený kľúč v `app_metadata`, poškodený tvar; obeť je po všetkých nedotknutá), 57 kontrol oprávnení a spôsobilosti (zamestnanec, anon, organizácia s údajmi, cudzí import, opakovaný import po zmazaní), 100 000 razení (kontrola 0,9 s, zápis 4,7 s, pod limitom 8 s), inštalácia a návrat, 6 zámerných pokazení migrácie (všetky odhalené) a integračný test so **skutočnou knižnicou** exportu aj importu cez šifrovaný súbor (čísla `8.00`, `1.0`, `0.10` a zátvorky v texte sa preniesli nezmenené). Jednotkové testy knižnice a karty (30).

- Databáza: skúšobný Postgres s dvoma databázami, 91 kontrol exportu (oprávnenia, izolácia organizácií, zámok, zmeny od exportu, kód potvrdenia, návrat), test s 100 000 razeniami (časy pod limitom 8 s), súbežnosť (razenie počas začiatku exportu), návrat migrácie a 24 zámerných pokazení (mutácií), ktoré testy musia zachytiť.
- Knižnica a karta: jednotkové testy (šifrovanie vrátane útokov na súbor, stránkovanie, opakovanie čítania, prerušenie, kontrola súboru, stavy karty a dialóg zrušenia) a **integračný test**: skutočná knižnica exportuje z PostgreSQL pod rolou `authenticated` (každé volanie osobitná transakcia s limitom 8 s), súbor sa dešifruje, naimportuje do druhej databázy balíkom 0015 a výpis organizácie sa zhoduje so zdrojom.
- Neoverené na ostrej databáze (Lovable/Supabase): správanie proxy pri dlhom exporte, skutočné časy a limity. Pozri „Obmedzenia“.

## Obmedzenia

- **Veľkosť:** každé volanie po stránkach trvá okolo 0,1 s. Drahý je len `org_export_begin` (a `org_export_finish`, `org_transfer_status`), ktoré prejdú celé tabuľky: na skúšobnom stroji trvalo približne 2,5 s pri 100 000 razeniach (súbor 60 MB, 53 stránok, najpomalšia 0,13 s). Databáza povoľuje prihlásenému používateľovi približne 8 s na príkaz (v Supabase rola `authenticated`), preto sa organizácia s niekoľkými stovkami tisíc razení z aplikácie exportovať nemusí (odhad podľa skúšobného stroja, na ostrej databáze to môže byť skôr; neoverené). Zlyhanie je bezpečné (nič sa nezapíše, zámok sa vráti späť) a také organizácie sa prenášajú operátorským postupom cez psql (súkromný balík 0015, bez časového limitu).
- Súbor obsahuje hashe PIN a hesiel, takže na sile hesla súboru záleží (min. 12 znakov).
- Zámok sa týka len zápisu razení. Ostatné zmeny správcu po exporte (zamestnanci, opravy) zámok nebrzdí; odhalí ich porovnanie pri zrušení.

## Čo sa stane s terminálmi napojenými na starý server

Podľa kódu aplikácie (`offline-queue.ts`, `device.ts`, `auth-guard.ts`, `pwa.ts`); správanie starého servera po zrušení organizácie je z kódu odvodené, na ostrom serveri neoverené.

* **Terminál sa na nový server sám neprepne.** Adresa databázy je zabudovaná v zostavení aplikácie a front razení čakajúcich na odoslanie aj kľúč zariadenia sú uložené v prehliadači (IndexedDB) len pre adresu, z ktorej sa aplikácia otvorila. Nový server s inou adresou je pre prehliadač nová stránka: prázdna fronta, žiadny kľúč zariadenia, žiadne prihlásenie. Staré terminály zostanú napojené na starý server.
* **Kým organizácia na starom serveri existuje a razenia nie sú zamknuté**, starý terminál na ňom razí ďalej. Také razenia na nový server neprejdú, pri zrušení sa vypíšu ako zmeny od exportu.
* **So zámkom razení** ostanú nové razenia vo fronte terminálu (pruh „čaká na odoslanie: N“) a skúšajú sa odoslať každú minútu. Po zrušení organizácie na starom serveri už nemajú kam ísť: účty tam zaniknú, prihlásenia sú neplatné a front sa ďalej neodosiela. Razenia ostanú uložené v tom prehliadači, na novom serveri sa neobjavia. **Preto pred potvrdením zrušenia overte na každom termináli, že „čaká na odoslanie“ je 0** (server nevie, čo majú terminály vo fronte, takže to nemôže skontrolovať za vás). Ak nie, prenos radšej zrušte (odomkne razenia, odošlú sa) a zopakujte ho v čase, keď sa nerazí (mimo pracovného času).
* **Po presune** zamestnanec otvorí novú adresu, aplikáciu si znova pridá do záložiek alebo nainštaluje a prihlási sa. Kód organizácie, osobné čísla aj heslá a PIN sa prenášajú, takže prihlasovacie údaje sú rovnaké (prihlásenie na reálnom novom serveri sa neoverovalo).
* **Zariadenie bude nové.** Kľúč zariadenia sa neprenáša (je len v pôvodnom prehliadači), preto sa razenia z neho najprv označia „neoverené“, kým vedúci nové zariadenie nepotvrdí (Nahradiť pôvodné zariadenie, potom schválenie v Môj tím → Zariadenia). Razenia sa počítajú aj dovtedy. Pozri [`OVERENIE-ZARIADENI.md`](OVERENIE-ZARIADENI.md).
* **Staré inštalácie odstráňte.** Ak starý server vypnete úplne, nainštalovaná aplikácia sa ešte otvorí z vyrovnávacej pamäte a razenia ukladá do fronty, ktorá sa už nikdy neodošle, a zamestnanec si to nemusí všimnúť. Všetkým oznámte novú adresu.
* **Najplynulejší presun:** ak terminály používajú vlastnú doménu, ktorú pri presune len prepojíte na nový server, ostane pôvodná adresa (a teda kľúč zariadenia aj front razení); zamestnanci sa len znova prihlásia a razenia vo fronte sa odošlú na nový server (účty majú rovnaké id a razenie je podľa `client_uuid` idempotentné). Neoverené: závisí od hostingu a od zostavenia aplikácie s adresou novej databázy.
* **Od migrácie 0019** terminál presťahovanie zistí sám a razenia, ktoré v ňom ostali, ponúkne uložiť do šifrovaného súboru pre nový server: pozri ďalšiu kapitolu. Overenie „čaká na odoslanie je 0“ pred zrušením ostáva najistejšia cesta; súbor je záchrana pre terminály, na ktoré sa zabudlo.

## Razenia, ktoré ostali v zariadení (migrácia 0019)

Fronta razení terminálu o prenose nevedela: počas zámku sa razenie ticho opakovalo a po zrušení organizácie ostalo navždy len v prehliadači. Migrácia `0019_razenia_po_prestahovani.sql` a aplikácia to riešia v troch častiach.

**1. Oznam (starý server).** Funkcia `punch_move_notice(účty)` je jediná, ktorú smie volať neprihlásený (po zrušení organizácie účty neexistujú). Zariadenie pošle id účtov, ktorých razenia má vo fronte, a dostane `transferring` (organizácia sa prenáša, rovnaká podmienka ako zámok razení) alebo `moved` (prenos bol potvrdený kódom a organizácia tu zanikla), prípadne novú adresu. Oznam je **pre organizáciu, nie pre server** (na serveri je viac organizácií). Po zrušenej organizácii ostane v `org_transfer.move_notices` len jej id, id prenosu, čas, voliteľná adresa a SHA-256 odtlačky id jej účtov; žiadne osobné čísla ani samotné id účtov. Stav vedie spúšťač na tabuľke prenosov, funkcie z 0016 sa nemenia: potvrdenie kódom = `moved`, zrušenie prenosu alebo nový export = oznam sa zmaže. Ak sa organizácia vráti importom späť, živý účet má prednosť a `moved` sa prestane vydávať.
Novú adresu (nepovinnú) uloží správca v karte prenosu po exporte (`org_transfer_set_destination`); prejde len `http(s)://meno[:port][/cesta]`.

**2. Terminál** (`src/lib/server-move.ts`, `src/components/ServerMoveNotice.tsx`, nad každou stránkou vrátane prihlásenia).
* Zámok prenosu sa pozná z odpovede na razenie (SQLSTATE 55000), bez ďalšieho dopytu: „Organizácia sa práve sťahuje… razenia sú uložené a odošlú sa samy“.
* Na oznam sa zariadenie pýta len vtedy, keď má vo fronte razenia a zároveň server razenie neprijal alebo razenia patria neprihlásenému účtu, najviac raz za 10 minút. Pri prázdnej fronte neposiela nič.
* Pri `moved` ukáže „Server bol presťahovaný“ s počtom razení: (1) uložiť do šifrovaného súboru (formát `DOCHSENC` ako prenos organizácie, heslo aspoň 12 znakov, ostáva v prehliadači), (2) súbor odovzdať správcovi nového servera, (3) zmazať razenia a upratať zariadenie. **Zmazanie sa ponúkne až po uložení súboru**, vyžaduje zaškrtnutie aj druhé potvrdenie s počtom a zmaže presne to, čo je v súbore. Nič sa nemaže samo.
* Súbor obsahuje len `client_uuid`, `user_id`, `code`, `direction`, `client_time`, `device`, verziu a odtlačok. Kľúč zariadenia sa doň nikdy nedostane.
* Upratanie (`src/lib/device-cleanup.ts`): razenia zo súboru, kľúč zariadenia a uložené údaje presťahovaných účtov; ak v zariadení neostali iné razenia ani iný prihlásený účet, aj prihlásenie, celé úložisko stránky, obe databázy IndexedDB, vyrovnávacia pamäť a service worker. Kým je stránka otvorená, prázdna databáza fronty môže vzniknúť znova.
* Priame odoslanie na novú adresu nejde (iná adresa = iná fronta a prihlásenie), preto súbor.

**3. Nový server** (Správa → Servis → *Neskoré razenia zo zariadenia*, `late_punches_import`). Súbor sa dešifruje v prehliadači, server ho najprv len skontroluje a po potvrdení zapíše, čo je v poriadku. Súboru sa neverí: len správca a len účty jeho organizácie, opakované nahratie nič nezdvojí (`client_uuid`), nie do uzavretého mesiaca, nie do budúcnosti, nie staršie než 120 dní, najviac 2 000 razení v súbore. Razenia idú **bežnou cestou** (zdroj `terminal`, bez kľúča zariadenia), takže hash reťaz doplní `punches_chain` ako vždy a razenie je **neoverené**, kým ho nepotvrdí vedúci. Vzorec reťaze, `punches`, `profiles` ani `contract/` sa nemenia. Každé nahratie má jeden záznam v audite (počty, bez razení).

**Access (zatiaľ len návrh rozhrania).** Tie isté razenia by sa dali vydať ako `.rzn` pre príjem v Accesse HR. Zariadenie na to nestačí: fronta má `user_id`, osobné číslo je len v kópii účtu `me-cache`, ktorá sa pri odhlásení maže. Mapovanie pozná nový server, preto je správna cesta: nahrať súbor na novom serveri a razenia odovzdať Accessu bežným exportom razení (bez zmeny kontraktu). Samostatný export `.rzn` zo súboru by bola nová funkcia na serveri (`user_id` → osobné číslo) a zmena dohodnutá s Accessom.

**Čo to nerieši:** vypnutý celý starý server (oznam nemá kto vydať) a zariadenie, ktoré sa už nikdy neotvorí. Organizáciu zrušenú ako testovaciu bez prenosu rieši od migrácie 0020 oznam „zrušená“ (ďalšia kapitola).

## Vlastná správa, zrušenie bez presunu a rozpis po účtoch (migrácia 0020)

Migrácia `0020_sprava_a_ukoncenie_organizacie.sql` (predpoklady 0019 a 0007, opakovateľná, návrat `0020_spat_zachranny.sql` **pred** `0019_spat_zachranny.sql`) pridáva tri veci. Tabuľky `punches` a `profiles`, export pre Access ani `contract/` sa nemenia (stĺpec `device` nie je súčasťou kontraktu).

**1. Správa správcu.** K oznamu možno pridať vlastný text (1 až 300 znakov, jeden riadok, čistý text bez riadiacich a skrytých znakov; pravidlo `org_transfer.valid_message`, v aplikácii `safeMessage` v `server-move.ts`).
* Pri prenose: pole „Správa pre zariadenia“ v karte prenosu spolu s adresou (`org_transfer_set_notice(adresa, správa)`; `org_transfer_set_destination` ostáva, mení len adresu a správu zachová). Správa sa pri potvrdení prenosu prenesie do stavu `moved`.
* Pri zrušení bez presunu: pole v karte Testovacia organizácia (`delete_test_organization(názov, správa)`, druhý parameter je nepovinný, volanie len s názvom funguje ďalej).
* Zariadenie ju ukáže ako „Správa od správcu: …“ v okne počas prenosu, po presťahovaní, po zrušení aj po upratení. Vždy ako text: nikdy ako HTML ani odkaz.
* Oznam číta aj neprihlásený (kto pozná id účtu), preto správa **nesmie obsahovať osobné údaje**; pri poli je na to upozornenie. V oznamoch ostávajú len SHA-256 odtlačky id účtov, adresa a správa.
* Ak v poli ostane nepotvrdený text, karta prenosu na to pred zrušením pôvodnej organizácie (aj v potvrdzovacom okne) upozorní: zariadenia ho neuvidia, kým sa neuloží.

**2. Zrušenie bez presunu (stav `ended`).** Zrušenie testovacej organizácie (`delete_test_organization`) dosiaľ nenechalo žiadny oznam: zariadenie s neodoslaným razením nemalo ako zistiť, čo sa stalo. Teraz funkcia pred zrušením, v tej istej transakcii, zapíše oznam `ended` (so správou, ak je zadaná) a až potom volá `purge_organization` (ktorá sa nemení; zrušenie po prenose robí `moved` spúšťač z 0019). Zariadenie ukáže okno „Organizácia bola zrušená“:
* Súbor je **nepovinný** (ak sa organizácia obnoví z exportu, správca ho nahrá cez Neskoré razenia). Po uložení súboru platí rovnaké zmazanie ako pri presťahovaní.
* Ak razenia netreba, dajú sa **zahodiť bez súboru**: zaškrtnutie, druhé potvrdenie s počtom a poznámka, že nezostane žiadna kópia. Táto cesta je **len pri `ended`**, nikdy pri presťahovaní (tam sú razenia jediná kópia údajov, ktoré na novom serveri chýbajú). Zahodí sa presne to, čo okno ukázalo (čerstvé čítanie fronty sa porovná s počtom).
* Presťahované razenia majú prednosť pred zrušenými (kým sa nevybavia, `ended` okno čaká).
* Živý účet nikdy `ended` nedostane (rovnako ako `moved`).

**3. Neskoré razenia na novom serveri.**
* `late_punches_import` pridá k poľu `device` každého zapísaného razenia predponu `neskoré: ` (dá sa potom nájsť a odlíšiť; obsah po predpone volí autor súboru, predponu nie).
* Odpoveď vracia `by_account`: osobné číslo, počet a rozsah času po účtoch (vo „Skontrolovať“ aj po zápise; ide o razenia, ktoré sa dali zapísať). Karta ich vypíše a pri viac než jednom účte upozorní: súbor zo zariadenia zvyčajne patrí jednému človeku. Zoznam je v rozsahu `max_report_items`.

**Súčinnosť s verziami.** Aplikácia ide aj proti databáze len s 0019: `org_transfer_get_destination` bez poľa `message` = pole správy sa neukáže a ukladá sa len adresa starou funkciou; rozpis po účtoch chýba a karta sa správa ako predtým; zrušenie testovacej organizácie bez správy volá funkciu ako doteraz. So správou proti databáze bez 0020 aplikácia odmietne a napíše, že treba spustiť 0020. **Poradie nasadenia nie je kritické** (odporúčané: najprv migrácia 0020 na oboch serveroch, potom Publish aplikácie; pole správy sa ukáže, až keď ju databáza podporuje). Staršia aplikácia (bez tejto verzie) proti databáze s 0020 funguje, no stav `ended` nepozná a oznam „zrušená“ by ignorovala (razenia zostanú vo fronte bez vysvetlenia).

## Ručné vyskúšanie (SQL editor, ako správca)

Funkcie závisia od prihláseného používateľa (`auth.uid()`), takže v SQL editore bez prihlásenia hlásia `Prihlásenie je potrebné`. Skutočné volanie ide z aplikácie. Po spustení migrácie stačí skontrolovať, že existujú:

```sql
SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND proname LIKE 'org\_%' ESCAPE '\' ORDER BY 1;   -- 6 funkcií
SELECT org_transfer.version();                                                 -- org_transfer 2 (migrácia 0016, export)
SELECT org_transfer.uncovered_tables();                                        -- {} (prenos pozná všetky tabuľky)
```

Ak `uncovered_tables()` vráti nejakú tabuľku, niektorá novšia migrácia pridala tabuľku, ktorú prenos nepozná. Export sa vtedy zámerne odmietne, kým sa tabuľka nedoplní do `org_transfer.spec()`.

## Nasadenie a návrat

1. Záloha podľa [`ZALOHA-DATABAZY.md`](ZALOHA-DATABAZY.md).
2. Spustiť `docs/migracie/0016_prenos_organizacie_export.sql` (opakovateľné). Predpoklad: migrácie 0001 až 0008.
3. Na serveri, ktorý má organizácie **prijímať**, spustiť aj `docs/migracie/0017_prenos_organizacie_import.sql` (opakovateľné, predpoklad 0016). Kontrola: `SELECT org_transfer.import_version(), org_transfer.import_unclassified();` vráti verziu a `{}`.
4. Na oboch serveroch spustiť `docs/migracie/0019_razenia_po_prestahovani.sql` (opakovateľné, predpoklad 0016): starý vydáva oznam, nový prijíma neskoré razenia. Kontrola: `SELECT org_transfer.move_version();`. Bez nej všetko beží ako predtým.
5. Voliteľne `docs/migracie/0020_sprava_a_ukoncenie_organizacie.sql` (opakovateľné, predpoklady 0019 a 0007): vlastná správa, oznam o zrušení bez presunu, rozpis po účtoch. Kontrola: `SELECT org_transfer.move_version();` vráti `org_move 2 (migrácia 0020)`.
6. Návrat: [`migracie/0020_spat_zachranny.sql`](migracie/0020_spat_zachranny.sql) (ak bola spustená), potom [`migracie/0019_spat_zachranny.sql`](migracie/0019_spat_zachranny.sql), potom [`migracie/0017_spat_zachranny.sql`](migracie/0017_spat_zachranny.sql) a až potom [`migracie/0016_spat_zachranny.sql`](migracie/0016_spat_zachranny.sql), pozri [`ZACHRANA-A-NAVRAT.md`](ZACHRANA-A-NAVRAT.md).

**Migrácia 0019 nie je overená na ostrej databáze Lovable Cloud ani v prehliadači** (volanie `punch_move_notice` bez prihlásenia cez REST a firemný proxy, stiahnutie súboru, upratanie service workera). Overené v sandboxe PostgreSQL 16 nad skutočnou schémou aplikácie: oznam, útoky na nahrávaný súbor, práva, návrat, okruh s 0016/0017 a 29 zámerných pokazení.

**Migrácia 0020 nie je overená na ostrej databáze Lovable Cloud ani v prehliadači.** Overené v sandboxe PostgreSQL 16 (114 kontrol: oznam `ended`, správa, atomickosť zrušenia, ochrana pôvodnej a ostrej organizácie, oprávnenia, predpona a rozpis po účtoch, návrat, opakovanie) so zámernými pokazeniami (13 z 14 zmysluplných zachytených, jedno je ekvivalentné: `purge_organization` kontrolu testovacej organizácie opakuje), a v aplikácii testami komponentov a fronty so skutočným IndexedDB v pamäti. Neoverené: živý prehliadač, volanie `punch_move_notice` bez prihlásenia cez REST a firemný proxy, skutočné časy.

**Import (0017) nie je overený na ostrej databáze Lovable Cloud ani na lokálnom Supabase so skutočným prihlasovacím serverom:** práva vlastníka migrácie na vypnutie spúšťačov a na `auth.users` z funkcie volanej prihláseným správcom, prihlásenie preneseným účtom po importe tlačidlom a to, či server rešpektuje dlhší časový limit funkcie (bez neho platí 8 s, čo stačí približne do 100 000 razení).

**Overené** na dočasných databázach PostgreSQL 16 s kópiou schémy aplikácie a napodobeninou Supabase: oprávnenia (správca, zamestnanec, cudzia organizácia, anon), stránkovanie a zhoda odtlačkov, zámok razení vrátane súbehu, zmeny od exportu, kód potvrdenia na oboch stranách, zrušenie, import súboru a zhoda údajov, veľká organizácia (100 000 razení), návrat a zámerné pokazenia migrácie. **Neoverené:** beh na ostrej databáze Lovable Cloud (práva vlastníka migrácie na `LOCK TABLE`, vytvorenie schémy `org_transfer`), časové limity na jej hardvéri.
