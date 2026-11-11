# Prenos organizácie na iný server

Správca môže celú svoju organizáciu (účty s hashmi PIN a hesiel, osobné čísla, zariadenia, razenia s hash reťazou, opravy, uzávierky, nastavenia, konfigurácia z Accessu, audit) vyexportovať do súboru a na inom serveri ju znova vytvoriť. Identifikátory zostávajú, preto zostáva rovnaký aj **kód organizácie** a zamestnanci sa prihlásia rovnakými údajmi ako predtým.

> **Stav:** hotová je **databázová časť exportu** (migrácia [`0016`](migracie/0016_prenos_organizacie_export.sql)). Obrazovka v skrytej karte Servis, šifrovanie súboru heslom v prehliadači, import na cieľovom serveri a Docker nasadenie ešte nie sú. Bez nich sa funkcie dajú volať len ručne (pozri nižšie).

## Ako má celý prenos prebiehať

1. Na **cieľovom serveri** sa správca zaregistruje a vytvorí organizáciu (pripraví sa tým prihlasovanie a prázdna databáza).
2. Na **pôvodnom serveri** v skrytej karte Servis spustí *Prenos na iný server*, zvolí, či sa majú zamknúť razenia, a zadá heslo súboru. Aplikácia stránkovaním vyžiada údaje (`org_export_begin`, `org_export_page`), v prehliadači ich zašifruje heslom a stiahne súbor. Heslo sa na server neposiela. Potom prenos uzavrie (`org_export_finish`): organizácia sa označí ako **testovacia** a správca sa presmeruje do okna zrušenia.
3. Na **cieľovom serveri** sa súbor nahrá, dešifruje, skúšobne naimportuje, importuje a overí. Cieľ vypíše **kód potvrdenia prenosu** (`XXXX-XXXX`).
4. Na **pôvodnom serveri** správca zadá kód a názov organizácie (`org_transfer_confirm_and_delete`). Organizácia sa zruší až vtedy. Bez správneho kódu sa zrušiť nedá.

Terminály (PWA) si pamätajú spárovanie podľa adresy servera, preto sa na novom serveri musia spárovať znova.

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
