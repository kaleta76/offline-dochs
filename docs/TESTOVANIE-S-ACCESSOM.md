# Test: razenia do terminálu, export do Accessu, porovnanie sald

Cieľ: overiť, že **terminál a Access vyjdú v saldách rovnako**, než sa to nasadí. Dáta sú vymyslené (zamestnanci 9000001 až 9000004),
bez osobných údajov. Scenár je **október 2026** (celý mesiac je v minulosti, takže terminál počíta saldo za všetky dni; obsahuje aj prechod
na zimný čas 25. 10.).

Stav: **nespustené v živom prostredí**. Terminálová časť (import, kontrola reťaze) je pokrytá testami čistých funkcií, nie behom v Lovable.

## Čo scenár obsahuje (`contract/scenare/2026-10/`)

| Súbor | Na čo |
|---|---|
| `import_do_terminalu_2026-10.csv` | vstup pre **Testovací import** v termináli (237 razení, stĺpce `osobne_cislo;datum;cas;kod;smer`) |
| `terminal_test_2026-10.csv` | to isté vo formáte exportu kontraktu v1 – na test **samotného Accessu** bez terminála |
| `popis_2026-10.json` | popis každého dňa (vypíše sa pri rozdieloch) |
| `ocakavane_saldo_2026-10.csv` | saldá, ktoré má terminál ukázať (referenčný výpočet enginu `src/lib/engine.ts`) |
| `../make_mesiac.py` | generátor (deterministický: rovnaký výstup pri každom spustení) |
| `../referencne_saldo.ts` | výpočet očakávaných sald enginom terminálu (`TZ=Europe/Bratislava tsx ...`) |
| `../porovnaj.py` | porovnanie terminál / Access (len štandardná knižnica Pythonu) |

Scenár pokrýva: bežné dni s náhodným príchodom a odchodom (aj s obedom mimo pracoviska), lekára s návratom a bez návratu, služobnú cestu,
sprievod rodinného príslušníka, súkromné prerušenie, dovolenku, PN, krátky a dlhý deň (prestávka 30 min nad 6 h), príchod bez odchodu,
deň bez akéhokoľvek razenia, sobotu a nedeľu (s prechodom na zimný čas) a **dve duplicity** (dvojitý príchod 9. 10. a dvojitý odchod 13. 10.
u 9000001).

## Postup A: iba Access (bez terminála)

1. Nainštalovať balík 2.11.1 (priečinok `access/` v tomto repozitári; 2.10.2 stačí, ak zneplatnenia a overenie zariadení netestujete), otvoriť konzolu, karta 7 Exporty, **Samočinný test terminála**.
2. Keď sa opýta na súbor, vybrať `terminal_test_2026-10.csv`; ostrý import potvrdiť (najlepšie na kópii databázy).
3. Vznikne `terminal_test_report.txt` a `terminal_test_access_vysledky.csv`.
4. Porovnanie s očakávaným výsledkom enginu:
   `python3 -I porovnaj.py --terminal ocakavane_saldo_2026-10.csv --access terminal_test_access_vysledky.csv --popis popis_2026-10.json`

## Postup B: celý reťazec terminál -> Access

1. **Terminál, testovacia organizácia, správca**: sekcia Prístup zamestnancov, pridať osobné čísla 9000001 až 9000004 a vydať PIN-y
   (zamestnanci musia existovať; správca 9000001 už je).
2. Sekcia **Testovacia prevádzka a porovnanie s Accessom**: **Zapnúť testovaciu prevádzku**, vybrať `import_do_terminalu_2026-10.csv`,
   **Skontrolovať** (nič nezapíše), potom **Importovať**. Výsledok ukáže počty po osobách a „Reťaz je v poriadku“.
   Opakovaný import toho istého súboru nič nezduplikuje.
3. Rovnaká sekcia: mesiac **október 2026**, **Stiahnuť saldá (.csv)** -> `terminal_saldo_202610.csv`.
4. Sekcia Export pre Access: mesiac október 2026 -> `punches_202610.csv`.
5. **Access** (inú kópiu databázy než v postupe A, alebo nechajte samočinný test odstrániť staré testovacie údaje): karta 7, **Samočinný test
   terminála**, vybrať `punches_202610.csv`. Test súbor skontroluje, importuje, prepočíta mesiac a uloží `terminal_test_access_vysledky.csv`.
6. Porovnanie:
   `python3 -I porovnaj.py --terminal terminal_saldo_202610.csv --access terminal_test_access_vysledky.csv --ocakavane ocakavane_saldo_2026-10.csv --popis popis_2026-10.json`
   - **Časť A** správy: terminál voči očakávanému výsledku enginu (zachytí chybu importu alebo časového pásma v termináli).
   - **Časť B**: terminál voči Accessu (hlavný výsledok). Rozhoduje `fond_min` a `saldo_min`; `odpracovane_min` je doplnková informácia.
   - Súbor `porovnanie_rozdiely.csv` je tá istá časť B ako tabuľka.

## Ako čítať rozdiely

Každý rozdiel je buď **chyba mapovania alebo nastavenia** (napr. iný kód prerušenia pre sprievod rodiny, iný fond, iné pravidlo obeda),
alebo **rozdiel v pravidle výpočtu** (napr. ako sa započítava lekár bez návratu, otvorený deň, duplicitné razenie). Správa vypíše scenár dňa,
rozpis z terminála a intervaly s anomáliami z Accessu. Na rozdiele v pravidle sa treba rozhodnúť, ktorý systém je „pravda“, a druhý upraviť.

Očakávané rozdiely, ktoré treba rozhodnúť: otvorený deň (9. 10. u 9000003), deň bez razenia (30. 10. u 9000003 – Access riadok pre deň bez razenia
nemusí mať), duplicity (9. a 13. 10. u 9000001) a prerušenia, ktoré v Accessi nemajú rovnaké pravidlo ako v termináli (sprievod rodiny, súkromné).

## Postup F: skutočné dáta z Ordata

Scenáre vyššie používajú vymyslených zamestnancov. Na **skutočných razeniach a skutočných výsledkoch z Accessu** (po importe z Ordata) slúži
prevodník `contract/scenare/z_accessu.py`: z `dochs_test_sample.json`, ktorý Access vie vyexportovať, pripraví vstup pre Testovací import v termináli
a súbor Accessových sald na porovnanie (`porovnaj.py --iba-osoby-z-accessu`). Celý postup vrátane registrácie testovacej organizácie, importu
konfigurácie, cesty späť do Accessu a upratania je v [`TESTOVACI-SCENAR-SKUTOCNE-DATA.md`](TESTOVACI-SCENAR-SKUTOCNE-DATA.md).
Výstupy obsahujú skutočné osobné čísla: nepatria do repozitára.

## Bezpečnosť testovacieho importu

- Zapnúť a spustiť ho smie len správca; zapnutie aj každý import sa zapíše do auditu.
- Bez zapnutej testovacej prevádzky organizácie server import odmietne.
- Razenia majú zdroj `correction` (zariadenie „testovací import“), idú cez trigger s hash reťazou. **Nič sa nemaže ani neprepisuje.**
- Zapíše sa všetko alebo nič; pri chybe v súbore, neznámom zamestnancovi alebo uzavretom mesiaci sa nezapíše žiadny riadok.
- Testovaciu organizáciu po teste zrušte (alebo nechajte oddelenú od ostrej). **Testovaciu prevádzku nezapínajte v ostrej organizácii.**

## Postup C a D: zneplatnenie duplicít

Duplicity v scenári (9. 10. a 13. 10. u 9000001) sa dajú zneplatniť a otestovať aj v Accesse. Saldo týchto dní sa po zneplatnení nemá zmeniť.
Podrobné kroky sú v `access/testy/terminal/mesiac-2026-10/POSTUP.txt` (postup C: len Access, postup D: celý reťazec) a v [`ZNEPLATNENIE-RAZENI.md`](ZNEPLATNENIE-RAZENI.md).

## Postup E: overenie zariadení (balík 2.11.1)

Malý súbor `overenie_test_2026-10.csv` (osem razení, tri z neschválených zariadení, jeden zamestnanec s dvoma overenými zariadeniami) a jeho verzia po potvrdení vedúcim
overia, že Access príznak ukladá, hlási ho v reporte importu a po potvrdení zmení iba príznak. Kroky a očakávané riadky reportu sú v `POSTUP.txt` (postup E),
súvislosti v `docs/OVERENIE-ZARIADENI.md`. Ide len o Access, terminál netreba.
