# Prenos organizácie na iný server

Správca môže celú svoju organizáciu (účty s hashmi PIN a hesiel, osobné čísla, zariadenia, razenia s hash reťazou, opravy, uzávierky, nastavenia, konfigurácia z Accessu, audit) vyexportovať do súboru a na inom serveri ju znova vytvoriť. Identifikátory zostávajú, preto zostáva rovnaký aj **kód organizácie** a zamestnanci sa prihlásia rovnakými údajmi ako predtým.

> **Stav:** hotová je **databázová časť exportu** (migrácia [`0016`](migracie/0016_prenos_organizacie_export.sql)). Obrazovka v skrytej karte Servis, šifrovanie súboru heslom v prehliadači, import na cieľovom serveri a Docker nasadenie ešte nie sú. Bez nich sa funkcie dajú volať len ručne (pozri nižšie).

## Ako má celý prenos prebiehať

1. Na **cieľovom serveri** sa správca zaregistruje a vytvorí organizáciu (pripraví sa tým prihlasovanie a prázdna databáza).
2. Na **pôvodnom serveri** v skrytej karte Servis spustí *Prenos na iný server*, zvolí, či sa majú zamknúť razenia, a zadá heslo súboru. Aplikácia stránkovaním vyžiada údaje (`org_export_begin`, `org_export_page`), v prehliadači ich zašifruje heslom a stiahne súbor. Heslo sa na server neposiela. Potom prenos uzavrie (`org_export_finish`): organizácia sa označí ako **testovacia** a správca sa presmeruje do okna zrušenia.
3. Na **cieľovom serveri** sa súbor nahrá, dešifruje, skúšobne naimportuje, importuje a overí. Cieľ vypíše **kód potvrdenia prenosu** (`XXXX-XXXX`).
4. Na **pôvodnom serveri** správca zadá kód a názov organizácie (`org_transfer_confirm_and_delete`). Organizácia sa zruší až vtedy. Bez správneho kódu sa zrušiť nedá.

Terminály sa na nový server neprepnú samy a zariadenia sa musia na novom serveri schváliť znova, pozri nižšie „Čo sa stane s terminálmi“.

## Čo dodáva migrácia 0016

| Funkcia | Čo robí |
|---|---|
| `org_export_begin(_lock boolean default true)` | Založí prenos, voliteľne zamkne razenia a uloží kontrolné súčty údajov. Vráti id prenosu, hlavičku súboru a zoznam tabuliek s počtami. Nový export nahrádza predchádzajúci neukončený. |
| `org_export_page(_transfer, _rel, _offset, _limit)` | Jedna stránka tabuľky (najviac 5 000 riadkov, odporúča sa 2 000). Tabuľka musí byť zo zoznamu prenosu. |
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
* **Zatiaľ nie je** upozornenie na starom serveri typu „organizácia sa presťahovala na adresu …“ ani odoslanie fronty z terminálu na nový server. Je to vhodný ďalší krok, ktorý by odstránil riziko tichej straty razení na starých termináloch.

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
3. Návrat: [`migracie/0016_spat_zachranny.sql`](migracie/0016_spat_zachranny.sql), pozri [`ZACHRANA-A-NAVRAT.md`](ZACHRANA-A-NAVRAT.md).

**Overené** na dočasných databázach PostgreSQL 16 s kópiou schémy aplikácie a napodobeninou Supabase: oprávnenia (správca, zamestnanec, cudzia organizácia, anon), stránkovanie a zhoda odtlačkov, zámok razení vrátane súbehu, zmeny od exportu, kód potvrdenia na oboch stranách, zrušenie, import súboru a zhoda údajov, veľká organizácia (100 000 razení), návrat a zámerné pokazenia migrácie. **Neoverené:** beh na ostrej databáze Lovable Cloud (práva vlastníka migrácie na `LOCK TABLE`, vytvorenie schémy `org_transfer`), časové limity na jej hardvéri.
