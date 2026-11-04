# Testovací scenár so skutočnými dátami z Ordata: od registrácie organizácie po porovnanie s Accessom

Stav: **nespustené**. Postup je zostavený z kódu terminálu a Accessu; v živom Lovable Cloude ani v skutočnom Accesse sa zatiaľ neskúšal.
Trvá asi dve až tri hodiny. Nič v ňom nemení ostrú databázu Accessu: **všetko v Accesse sa robí na kópiách**.

Doplňuje [`TESTOVANIE-S-ACCESSOM.md`](TESTOVANIE-S-ACCESSOM.md) (vymyslení zamestnanci 9000001 až 9000004). Tu sa namiesto nich použijú **skutočné razenia a skutočné výsledky výpočtu z vášho Accessu**
(po importe z Ordata). Skutočné osobné čísla a časy razení sú v súboroch, ktoré vzniknú pri teste: **nepatria na GitHub ani do verejného chatu**.

## Čo test zistí

1. Funguje celý reťazec naživo: registrácia organizácie, zamestnanci, import konfigurácie z Accessu, razenia, export, import späť do Accessu.
2. Ako veľmi sa saldo v termináli líši od salda v Accesse na skutočných dátach. Z toho sa rozhodne D1 (kto je „pravda“ vo výpočte, `KONFIGURACIA-Z-ACCESSU.md` kapitola 4).
3. Ktoré prerušenia zo skutočných dát terminál nevie vyjadriť (a či treba doplniť mapovanie `FAMILY` / `PRIV`).

Terminál zatiaľ počíta po starom (jeden denný fond, bez plánu z Accessu). Preto **rozdiely v saldách sú očakávané**; hľadajú sa tie, ktoré očakávané nie sú (kapitola 5).

## 0. Príprava (asi 30 minút)

| Čo | Poznámka |
|---|---|
| Kópia databázy Accessu | Zatvorte Access, skopírujte `.accdb` ako `dochadzka_TEST_A.accdb`. Všetko v Accesse robte len v kópiách. Dôvod: Access pozná duplicitu razenia len podľa ID z terminála, nie podľa obsahu. Razenia, ktoré už v databáze sú z Ordata, by sa po importe z terminála **zdvojili**. |
| Balík Access 2.12.1 alebo novší | Nainštalovaný v kópii (`docs/VYDANIA-ACCESS.md`). Verzia 2.12.0 sa v Accesse nedá skompilovať. |
| Python 3 a repozitár | Stiahnite repozitár (zelené tlačidlo Code > Download ZIP) a rozbaľte ho. Súbory z testu ukladajte **mimo** rozbaleného priečinka, napr. `C:\dochadzka_test\`. |
| Registračný kód firmy | Máte ho vy (vlastník). V repozitári je len jeho odtlačok. |
| Prístup do Lovable Cloud | SQL editor (na záverečnú kontrolu stavu databázy). |

**Výber vzorky** (zapíšte si ju):
* **3 až 6 zamestnancov**, ktorí majú **rovnaký denný fond** (napr. pevná 7:30) a úväzok 100 %. Terminál má zatiaľ jeden denný fond pre všetkých; prevodník v kapitole 4 vám povie, kto je porovnateľný.
* Aspoň jeden má v mesiaci lekára, dovolenku alebo obed. Nie je to nutné, ale test je potom cennejší.
* **Jeden mesiac z minulosti**, ideálne taký, ktorý je v Accesse už vyhodnotený. Celkovo najviac asi 1 400 razení na jeden súbor (limit testovacieho importu je 1 500; prevodník dlhší súbor rozdelí).
* Osobné čísla vo formáte, aký má Access (terminál ich prijme ako text, 1 až 20 znakov, písmená a číslice).

Stav databázy terminála: po čistení v nej nie je žiadna organizácia ani účet. Nič nemažte.

## 1. Registrácia testovacej organizácie (asi 10 minút)

1. Otvorte aplikáciu, odhláste sa, ak ste prihlásený, na prihlasovacej stránke zvoľte **Registrovať organizáciu / firmu**.
2. Vyplňte: registračný kód, názov **`TEST – dochádzka (skúška s Accessom)`**, osobné číslo správcu **`9000001`** (testovací správca, nie je vo vzorke), heslo aspoň 12 znakov, súhlas „zodpovedám za organizáciu“.
3. Po registrácii sa zobrazí **kód organizácie** (8 znakov) a **obnovovací kód správcu** (zobrazí sa len raz). Uložte oba do správcu hesiel.
   * Očakávané: ste prihlásený ako správca novej organizácie.
   * Ak zlyhá: pošlite presný text hlásenia a čas pokusu.
4. **Ihneď označte organizáciu ako testovaciu**: Správa > sekcia **Testovacia organizácia** > **Označiť „…“ ako testovaciu**. Bez toho sa na konci nedá zrušiť.
5. **Kontrola databázy po prvej registrácii.** V SQL editore spustite `docs/zaloha/stav_databazy.sql` (Raw, celý obsah) a výsledok pošlite. Očakávané: 1 organizácia, 1 účet, žiadne `POZOR`.
   Ak je to v poriadku, môžete zmazať dva snapshoty z 4. 11.: `DROP SCHEMA zaloha_20261104_1104 CASCADE;` a `DROP SCHEMA zaloha_20261104_1430 CASCADE;` (každý príkaz samostatne).

## 2. Zamestnanci (asi 10 minút)

1. Správa > **Prístup zamestnancov**: vložte osobné čísla vzorky (jedno na riadok) alebo nahrajte CSV, skontrolujte náhľad (neplatné a duplicitné čísla sa vypíšu), **Vydať PIN**.
2. PIN-y netreba odovzdávať ani sťahovať (platia 24 hodín a nikto ich nepoužije). Účty sú potrebné preto, že testovací import zapisuje razenia len existujúcim zamestnancom.
   * Očakávané: v zozname sú všetky čísla vzorky ako účty čakajúce na prvé prihlásenie.
3. Voliteľne (5 minút): jednému zamestnancovi aktivujte účet v inom prehliadači (`…/auth?o=KÓD`, „Mám PIN od správcu“) a overte, že po ďalšom prihlásení je osobné číslo predvyplnené a stačí heslo.

## 3. Konfigurácia z Accessu (asi 20 minút)

1. **Access (kópia A)**, karta 7: **Vytvoriť verziu konfigurácie prerušení pre terminál**. Vznikne `dochs_config.json`.
2. Kontrola súboru: `python3 -I contract/tools/verify_config.py dochs_config.json`. Očakávané: „V poriadku“ (upozornenia sú prípustné, chyby nie). Pri chybe súbor neimportujte a pošlite výpis.
3. Terminál > Správa > **Konfigurácia z Accessu** > vyberte súbor.
   * Očakávané: „Súbor … je v poriadku: verzia …, N zamestnancov, M mesačných plánov, okno …“. N má zodpovedať počtu aktívnych zamestnancov v Accesse.
4. **Náhľad (nič sa nezapíše)**.
   * Očakávané: „Nová verzia …“, „Zatiaľ sa nič nezapísalo“. „Bez účtu v termináli“ je približne N mínus počet zamestnancov vzorky (správca 9000001 v súbore nie je). Osobné čísla sa vypíšu len prvých 50.
5. **Prijať konfiguráciu**. Očakávané: „Prijatá verzia …“.
6. Vyberte ten istý súbor znova a dajte Náhľad. Očakávané: „Verzia … je už prijatá, nič sa nezmení.“
7. **Záporné skúšky** (kópia súboru, originál nechajte):
   * do jedného zamestnanca doplňte riadok `"meno": "X"` → aplikácia súbor odmietne s upozornením na osobné údaje;
   * `config_version` zmeňte na `2020.01.01.0000` → Náhľad z databázy odmietne ako „starší“;
   * súbor useknite (zmažte posledných 200 znakov) → „Súbor nie je platný JSON“.
   Po všetkých troch ostáva platná verzia z bodu 5.
8. Žiadna z týchto obrazoviek nemení výpočet salda v termináli (etapa 1). Údaje v Môj mesiac ostanú rovnaké.

## 4. Razenia zo skutočných dát (asi 30 minút)

1. **Access (kópia A)**, karta 7: **EXPORTOVAŤ KONFIGURÁCIU A TESTOVACIE DÁTA (JSON)**. Mesiac = vybraný mesiac, Osobné čísla = vzorka (oddelené čiarkou alebo medzerou), cesta = `C:\dochadzka_test\`.
   Access pri tom prepočíta mesiac pre vzorku (v kópii) a zapíše `dochs_test_sample.json`: platné razenia, schválené automatické opravy a svoj vypočítaný výsledok po dňoch.
2. **Prevod** (v rozbalenom repozitári):
   `python3 -I contract/scenare/z_accessu.py C:\dochadzka_test\dochs_test_sample.json C:\dochadzka_test\prevodA --config C:\dochadzka_test\dochs_config.json`
   Vznikne `import_do_terminalu_RRRR-MM.csv` (pri väčšom súbore `_cast1`, `_cast2`…), `access_vysledky_RRRR-MM.csv`, `popis_RRRR-MM.json` a `report_prevodu_RRRR-MM.txt`.
3. Prečítajte **`report_prevodu`**:
   * **Dni, ktoré sa nepreviedli**: ide o dni s prerušením, ktoré terminál nemá (iné než lekár, služobná cesta, dovolenka, PN, rodina, súkromné, obed). V porovnaní sa preskočia. Ak ich je veľa, pošlite mi zoznam prerušení, rozhodneme, či ich doplniť.
   * **Denný fond**: tabuľka ukáže, kto má ktorý fond, a odporúčanú hodnotu `DENNY_FOND_HODIN`.
4. Terminál > Správa > **Pravidlá výpočtu**: `DENNY_FOND_HODIN` podľa odporúčania (7,5 = 450 minút), `ZAOKRUHLENIE_PRICHOD` a `ZAOKRUHLENIE_ODCHOD` = 0, `OBED_PAUZA_MIN` = 30, `OBED_PO_HODINACH` = 6. Skontrolujte aj **Sviatky** v danom mesiaci proti Accessu (v `dochs_config.json` je ich zoznam).
5. Správa > **Testovacia prevádzka a porovnanie s Accessom** > **Zapnúť testovaciu prevádzku**. Pre každý súbor `import_do_terminalu_*.csv`: vyberte ho, **Skontrolovať** (nič nezapíše), potom **Importovať**.
   * Očakávané: „Kontrola prešla: N razení“, potom „Zapísaných N razení … Reťaz je v poriadku“.
   * Ten istý import zopakujte: „Zapísaných 0 razení, N už existovalo“, nič sa nezdvojí.

## 5. Porovnanie sald (asi 20 minút)

1. V tej istej sekcii vyberte mesiac > **Stiahnuť saldá (.csv)** → `terminal_saldo_RRRRMM.csv` (uložte do `C:\dochadzka_test\`).
2. Porovnanie:
   `python3 -I contract/scenare/porovnaj.py --terminal C:\dochadzka_test\terminal_saldo_202610.csv --access C:\dochadzka_test\prevodA\access_vysledky_2026-10.csv --popis C:\dochadzka_test\prevodA\popis_2026-10.json --iba-osoby-z-accessu --vystup C:\dochadzka_test\prevodA`
3. Vznikne `porovnanie_report.txt` a `porovnanie_rozdiely.csv`. Rozhoduje `fond_min` a `saldo_min` po dňoch.

**Ako čítať rozdiely.** Najprv si zoraďte rozdielne dni podľa príčiny:

| Rozdiel | Dôvod | Je to chyba? |
|---|---|---|
| Fond dňa je iný | Zamestnanec má v Accesse iný fond, úväzok, deň v týždni alebo kalendár; terminál má jeden `DENNY_FOND_HODIN` | Nie, dôvod pre etapu 2 |
| Pracovný deň bez razenia, Access riadok nemá | Terminál počíta fond a záporné saldo, Access deň neeviduje | Treba posúdiť |
| Sviatok | Terminál berie sviatky z organizácie, Access z kalendára zamestnanca | Skontrolujte zoznam sviatkov |
| Lekár / rodina | Terminál ich dopĺňa do fondu, Access počíta skutočné trvanie | Rozdiel v pravidle (D1) |
| Súkromné prerušenie | Terminál ho nezapočíta, Access áno | Rozdiel v pravidle (D1) |
| Obed | Terminál odpočíta len prebytok nad 6 h, Access celý automatický obed, ak nebol obed | Rozdiel v pravidle (D1) |
| Práca mimo okna 6:00 až 17:00 | Access oreže, terminál nie | Rozdiel v pravidle (D1) |
| Deň so schválenou automatickou opravou | Access ju má, terminál nie (v popise dňa je poznámka) | Očakávané |
| **Obyčajný deň s rovnakým fondom, príchod a odchod bez zvláštností, a predsa iné saldo** | Nič z hore uvedeného to nevysvetľuje | **Podozrenie na chybu. Pošlite `porovnanie_report.txt`.** |

Zapíšte si: koľko dní z koľkých sedí, a rozdielne dni podľa príčiny. Na tom sa rozhodne D1.

## 6. Cesta späť: export z terminálu do Accessu (asi 30 minút, odporúčané)

Overuje, že razenia, ktoré terminál vydá, Access správne prevezme (pätička SHA-256, hash reťaz, mapovanie kódov, párovanie začiatkov a koncov) a že výsledok zodpovedá originálu.

1. Terminál > Správa > **Export pre Access**: mesiac > **Stiahnuť .csv** → `punches_RRRRMM.csv`.
2. **Access: druhá kópia databázy `dochadzka_TEST_B.accdb`** (z pôvodnej databázy, nie z kópie A). Mesiac nesmie byť v kópii uzavretý (inak sa razenia uložia do stavu `UZAVRETY`).
3. V kópii B zmažte razenia vzorky v mesiaci, aby sa nezdvojili. Vytvorenie > Návrh dotazu > zobrazenie SQL > spustite (osobné čísla a dátumy upravte):

   ```sql
   DELETE FROM DochadzkaImport
   WHERE OsobneCislo IN ('4002012', '4002013')
     AND Datum >= #2026-10-01# AND Datum <= #2026-10-31#;
   ```

   Spustiť ho **len v kópii B**.
4. Karta 7 v kópii B: **Importovať súbor z terminála…** → `punches_RRRRMM.csv`, najprv **nanečisto** (report: pätička a reťaz v poriadku, počet razení sedí s importom do terminálu), potom naostro. Potom **Spracovať prijaté pípnutia z terminálu**.
   * Očakávané: „Prenesené razenia: N, duplicity: 0, chyby: 0“.
5. Znova **EXPORTOVAŤ KONFIGURÁCIU A TESTOVACIE DÁTA (JSON)** (rovnaký mesiac a osobné čísla, priečinok `C:\dochadzka_test\B\`) a prevod:
   `python3 -I contract/scenare/z_accessu.py C:\dochadzka_test\B\dochs_test_sample.json C:\dochadzka_test\prevodB`
6. Porovnanie originálu (A) a výsledku po ceste cez terminál (B), s popisom z A, aby sa preskočené dni vynechali:
   `python3 -I contract/scenare/porovnaj.py --terminal C:\dochadzka_test\prevodB\access_vysledky_2026-10.csv --access C:\dochadzka_test\prevodA\access_vysledky_2026-10.csv --popis C:\dochadzka_test\prevodA\popis_2026-10.json --vystup C:\dochadzka_test\prevodB`
   * Očakávané: všetky dni sedia (fond aj saldo). Môžu sa líšiť dni so schválenou automatickou opravou a dni, kde je v Ordata jeden druh razenia, ktorý prevod zjednodušil (pozri nižšie).

## 7. Upratanie (asi 10 minút)

1. Terminál > **Vypnúť testovaciu prevádzku**.
2. Správa > **Testovacia organizácia** > prepíšte názov > **Zrušiť organizáciu natrvalo**. Zmaže razenia, účty, konfiguráciu aj plán z Accessu tejto organizácie. Pôvodnú ani ostrú organizáciu zrušiť nejde.
3. V SQL editore znova spustite `stav_databazy.sql`. Očakávané: bez testovacej organizácie, bez `POZOR`.
4. Zmažte kópie A a B a priečinok `C:\dochadzka_test\` (alebo ho uložte tam, kde súbory s osobnými číslami smú byť). Originálnu databázu Accessu test nezmenil.

## Čo poslať späť

* `report_prevodu_*.txt` (A), `porovnanie_report.txt` (kapitola 5) a `porovnanie_report.txt` (kapitola 6),
* text hlásení z Náhľadu a prijatia konfigurácie (kapitola 3),
* výsledok `stav_databazy.sql` po registrácii (kapitola 1, bod 5),
* ak niektorý krok zlyhal: číslo kroku, presný text hlásenia, čas.

Súbory obsahujú skutočné osobné čísla a časy. Posielajte ich len do tohto chatu, nie na GitHub.

## Čo prevod zjednodušuje a čo nie je overené

* Prevodník preloží razenia Accessu na kódy terminálu rovnakým mapovaním, aké používa Access pri importe, len opačným smerom (`mod_19_TerminalImport`). Prerušenie bez kódu v termináli sa nepreloží, celý taký deň sa preskočí.
* Koniec celodennej neprítomnosti (napr. dovolenka od 7:00 do 15:30) sa v termináli vyjadruje jediným razením `LEAVE`/`OUT`; koniec prerušenia ako posledné razenie dňa sa preto vynechá. Ako Ordata skutočne zapisuje celodenné neprítomnosti, sa nedá zistiť z kódu; ak sa takéto dni líšia, pošlite ich zo `popis_*.json`.
* Prevodník ani celý scenár sa v živom prostredí zatiaľ nespúšťal. Prevod je pokrytý testami na vymyslených údajoch a výstup prechádza skutočným parserom testovacieho importu terminálu.
* Testovací import v termináli prijme najviac 1 500 riadkov a 400 000 znakov naraz. Prevodník súbory rozdelí po zamestnancoch.
* Podmienky, ktoré tento test nevie overiť: ostrá prevádzka s viacerými zariadeniami, offline fronta v prehliadači a neoverené zariadenia (to je `OVERENIE-ZARIADENI.md`).
