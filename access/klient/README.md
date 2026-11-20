# Klient na razenie v Accesse (DochadzkaKlient.accdb)

Malý samostatný súbor Accessu na pracovnom počítači zamestnanca. Zamestnanec klikne **Príchod**, **Odchod** alebo tlačidlo prerušenia (Lekár, Služobne, …) a klient razenie zapíše ako súbor `.rzn` (protokol v1) do zdieľaného priečinka `prijem\` na serveri; HR ich prevezme príjmom v Accesse HR (karta 7). Bez webového terminálu, bez internetu, bez servera mimo organizácie. Návrh, protokol a práva na priečinky: [`docs/KLIENT-ACCESS.md`](../../docs/KLIENT-ACCESS.md). Postup pre zamestnanca: [`PRIRUCKA.md`](PRIRUCKA.md). Zmeny, **čo je overené a čo nie**, a skúšobný postup: [`CHANGELOG.md`](CHANGELOG.md).

> **Stav (balík 1.0.1): hotové, ale neoverené v skutočnom Accesse.** Kód VBA, zostavovač a spúšťač sa mimo Windows s Accessom nedajú spustiť. Pred nasadením urobte skúšobný postup z `CHANGELOG.md` na jednom počítači.

## Čo tu je

| Cesta | Obsah |
|---|---|
| `moduly/kl_00` … `kl_08` | zdrojový kód VBA (2. riadok `'@Verzia X.Y.Z`): spoločné funkcie, identita, protokol, fronta, konfigurácia, razenie, okno, štart, samotest |
| `manifest.json` | verzia balíka a SHA-256 modulov (`access/tools/zostav_balik.py --koren access/klient`) |
| `Instaluj-Klienta.cmd`, `Instaluj-Klienta.ps1` | **zostavovač** (správca, raz na jednom počítači s Accessom): vytvorí `DochadzkaKlient.accdb` |
| `Spusti-Dochadzku.cmd` | **spúšťač** (zamestnanec): skopíruje novšiu verziu zo servera a otvorí klienta; beží z lokálnej kópie, takže funguje aj pri výpadku servera |
| `Vytvor-Odkaz.cmd` | skopíruje spúšťač do `%LOCALAPPDATA%\DochadzkaKlient\`, zapíše `zaklad.txt` a vytvorí odkaz na ploche a v priečinku Po spustení (mieri na lokálnu kópiu) |
| `testy/klient_konfig_vzor.txt` | vzor konfigurácie tlačidiel pre testy |
| `CHANGELOG.md`, `PRIRUCKA.md` | zmeny a skúšobný postup; príručka pre zamestnanca |

Klient **nezávisí od modulov HR** a v ZIP-e inštalátora HR nie je (`access/.gitattributes`: `klient export-ignore`). Hotový `.accdb` je binárny súbor a do repozitára sa nepridáva; vzniká u správcu.

## Zostavenie (správca)

Potrebné: Windows s plnou verziou Microsoft Access (Access Runtime nestačí, nemá editor VBA).

```
Instaluj-Klienta.cmd -Vystup C:\dochadzka-test\klient
Instaluj-Klienta.cmd -Vystup .\vystup -Publikuj \\server\dochadzka\klient
```

Parametre: `-Vystup` (predvolene `.\vystup`), `-Publikuj <priečinok klient\ na serveri>`, `-Tiho`, `-IbaOtestuj` (len skontroluje Access a balík). Zostavovač overí SHA-256 modulov podľa `manifest.json`, vytvorí vždy nový `DochadzkaKlient.accdb`, importuje moduly, skompiluje, vytvorí formulár `frmKlient` a makro AutoExec, spustí samotest (pri akomkoľvek ZLE skončí chybou) a zapíše `verzia.txt` (`klient=<verzia>`, `sha256=<SHA-256 súboru>`) a spúšťače. Pri `-Publikuj` sa najprv skopíruje `.accdb`, `verzia.txt` až nakoniec. Zostavovač na chvíľu zapne v Accesse „Dôverovať prístupu k objektovému modelu projektu VBA“ a potom vráti pôvodnú hodnotu. Protokol: `instalacia_klient_*.log` vo výstupnom priečinku (bez používateľského mena).

Pri zmene modulu zvýšte jeho `'@Verzia` a spustite `python3 -I access/tools/zostav_balik.py --koren access/klient` (vynúti vyššiu verziu pri zmene obsahu); potom `python3 -I tools/over_access_balik.py --koren access/klient`.

## Nasadenie

Server (základ napr. `\\server\dochadzka`):

| Priečinok | Zamestnanci | HR / správca |
|---|---|---|
| `prijem\` | vytvárať nové súbory, nie čítať cudzie, nie meniť, nie mazať | všetko |
| `konfiguracia\` | len čítať | zápis (`klient_konfig.txt` ukladá Access HR) |
| `klient\` | len čítať | zápis: `DochadzkaKlient.accdb`, `verzia.txt`, `Spusti-Dochadzku.cmd`, `Vytvor-Odkaz.cmd` |
| `spracovane\`, `chybne\` | nič | všetko |

Zamestnanec nič neinštaluje a nepotrebuje práva správcu. Raz spustí `\\server\dochadzka\klient\Vytvor-Odkaz.cmd` (lokálna kópia spúšťača a odkaz na ploche a v Po spustení; pri zmene spúšťača na serveri ho treba spustiť znova); potom pri každom spustení lokálna kópia `Spusti-Dochadzku.cmd`: zapíše cestu zakladu do `zaklad.txt`, ak je na serveri iná `verzia.txt`, skopíruje nový `.accdb` (najprv pod dočasným názvom, výmena až po úspešnom skopírovaní; otvorený alebo nedostupný súbor nič nepokazí a ostane stará verzia), pridá lokálny priečinok medzi dôveryhodné umiestnenia Accessu (`HKCU`; aj na čistom profile, verzia Office sa berie z `HKCU` alebo `HKLM`) a otvorí klienta; pri nedostupnom serveri otvorí klienta, ktorý už je lokálne. Hromadné nasadenie odkazov cez prihlasovací skript správcu je mimo tohto balíka. Cesta zakladu nesmie obsahovať znaky `&`, `^`, `!` (zátvorky sú v poriadku).

V ostrej prevádzke používajte **UNC cestu** (`\\server\dochadzka`), nie namapovanú jednotku; klient namapovanú jednotku poznáva ako sieťovú, ale UNC je spoľahlivejšie.

## Lokálne dáta (`%LOCALAPPDATA%\DochadzkaKlient\`)

`DochadzkaKlient.accdb` a `verzia.txt` (kópia zo servera), `zaklad.txt` (cesta k základu), `identita.txt` (záloha identity z AD), `konfiguracia\klient_konfig.txt` (záloha konfigurácie), `razenia\fronta\` (čaká na odoslanie), `razenia\odoslane\RRRR-MM\` (odoslané, 90 dní), `log\klient.log` (do 200 kB), `log\samotest.txt`, `spustac.log`, `klient.lock`. Aktualizácia klienta dáta nikdy nezmaže; fronta sa nikdy nemaže automaticky.

## Test na jednom počítači (bez servera)

Ak `zaklad.txt` obsahuje **lokálnu** cestu (napr. `C:\dochadzka-test`, spúšťač: `Spusti-Dochadzku.cmd C:\dochadzka-test`) a v `%LOCALAPPDATA%\DochadzkaKlient\test.ini` je `oc_test=9000001`, klient použije toto osobné číslo namiesto AD a ukáže oranžový pruh „TESTOVACÍ REŽIM“. Pri sieťovej ceste sa `test.ini` ignoruje. Celý postup: `CHANGELOG.md`.

## Hranice a riziká

- Klient je súbor Accessu s VBA, ktorý si zdatný používateľ vie upraviť. Dôvera sa opiera o Windows vlastníka súboru a práva na `prijem\` (kontroluje HR pri príjme), nie o to, čo klient tvrdí.
- Súbor na serveri sa po zápise nedá prečítať (zamestnanec nemá právo čítať `prijem\`): úspešné vytvorenie súboru sa berie za odoslanie, vlastný záznam razení je lokálny.
- Razenie čaká lokálne, kým je server nedostupný; HR prijíma razenia odložené najviac `KlientMaxOdlozenieDni` dní (predvolene 3). Pri mazaní profilu (VDI, `%LOCALAPPDATA%`) sa stratí fronta aj záznam.
- Politika makier (GPO) môže zablokovať dôveryhodné umiestnenie; správca ho potom nastaví politikou (sieťové umiestnenia).
- Možné spevnenie (nerobí sa): `.accde` a podpis kódu.
- Osobné údaje: v kóde, logu ani na obrazovke nie sú mená, len osobné číslo a účet. V testoch sa používa výlučne `9000001` a `test.zam1`.
