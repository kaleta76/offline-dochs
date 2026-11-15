# Zmeny klienta na razenie (DochadzkaKlient.accdb)

## Balík 1.0.0

**Stav: rozpracované (etapa 2, míľnik M1 hotový; M2 okno, spúšťač a zostavovač a M3 dokumentácia ešte nie sú).** Klient sa zatiaľ nedá zostaviť ani spustiť: chýba okno (`kl_06_Okno`), štart (`kl_07_Spustenie`), `Spusti-Dochadzku.cmd`, `Instaluj-Klienta.ps1` a `manifest.json`. Skúšobný postup pre Access príde s M2 a M3.

### Čo je hotové (M1, jadro bez okna)

- `kl_02_Protokol`: zostavenie a kontrola súboru `.rzn` (protokol v1), čisté funkcie, zrkadlo `tools/klient_protokol.py`.
- `kl_00_Spolocne`: priečinky, čítanie a zápis súborov, log, čas v UTC, ID razenia.
- `kl_03_Fronta`: lokálny záznam, fronta, odosielanie na server, mapovanie chýb odoslania.
- `kl_01_Identita`: účet zo Windows, osobné číslo z AD, záloha identity, testovací režim.
- `kl_04_Konfig`: tlačidlá prerušení z `klient_konfig.txt` (server, lokálna kópia, predvolené).
- `kl_05_Razenie`: razenie, stav dňa, otázky pred razením.
- `kl_08_Samotest`: zlaté vektory a kontroly čistých funkcií, súborov a prostredia.
- Nástroje: `access/tools/zostav_balik.py --koren`, zrkadlá v `tools/klient_protokol.py` (`rozober_konfig`, `vysledok_odoslania`, `novy_pocet_neuspechov`, `stav_dna`, `popis_stavu`, `otazka_pred_razenim`), test zhody `tools/test_klient_zhoda.py`, kroky v CI.

### Overené (mimo Accessu)

- Lint `python3 -I tools/kontrola_vba.py --adresar access/klient/moduly`: 0 chýb, 0 varovaní. Lint balíka HR: 0 chýb.
- `tools/test_klient_zhoda.py`: zlaté vektory v `kl_08_Samotest.bas` sa bajt po bajte zhodujú s `klient_protokol.zostav` a prejdú `rozober`; zlé vzory dávajú rovnaké kódy chýb ako `zle_vzory()`; tabuľka chýb odoslania (vektory aj vetvy `Select Case` v `kl_03_Fronta`), počítadlo neúspechov, stav dňa, otázky pred razením a rozbor konfigurácie sa zhodujú s Pythonom; zmena vektora bez zmeny pravidla test zhodí.
- `tools/test_klient_protokol.py`, `tools/test_over_access_balik.py`, `tools/test_kontrola_vba.py` a ostatné testy v `tools/` a `contract/` prechádzajú.
- ZIP inštalátora HR (`git archive HEAD:access`) neobsahuje `klient/` (`access/.gitattributes`: `klient export-ignore`).

### Neoverené v skutočnom Accesse

**Všetok kód VBA.** Nebol skompilovaný ani spustený. Test zhody overuje len to, že vektory vo VBA a pravidlá v Pythone tvrdia to isté, nie že VBA kód počíta správne; to ukáže až `SamoTestKlienta` v Accesse. Osobitne neoverené: volania Windows (`GetSystemTime`, `CoCreateGuid`) v 32- aj 64-bitovom Office, čítanie osobného čísla z AD, čísla chýb pri zápise do `prijem\` so skutočnými právami na serveri, správanie pri nedostupnej sieti.

### Rozhodnutia implementácie (kde zadanie nechalo voľbu alebo sa od odporúčania odchyľujem)

- **Čas razenia**: UTC sa číta zo systému (`GetSystemTime`, nie WMI: nezávisí od služby, ktorá býva pomalá alebo vypnutá) a miestny čas sa odvodí ako UTC + posun zaokrúhlený na minúty. Dve samostatné čítania hodín (`Now` a UTC) by sa na hranici sekundy mohli líšiť o sekundu a razenie by neprešlo kontrolou 3600/7200 s.
- **ID razenia**: `CoCreateGuid` (ole32); `Scriptlet.TypeLib` je len záloha, lebo po aktualizácii Office z roku 2017 často hlási chybu 70.
- **Čas po otázke**: ak sa klient pred razením pýta (opakované razenie, odchod bez príchodu), čas razenia je okamih potvrdenia, nie kliknutia (inak by sa líšil od času vzniku súboru na serveri).
- **Blokovanie tlačidiel 5 s** sa počíta od zápisu razenia; počas spracovania chráni príznak súbehu. Okno (M2) podľa `BlokovaneDo()` tlačidlá vypne.
- **Klient zapisuje len** `WORK/IN`, `WORK/OUT` a `KOD/OUT`; koniec prerušenia je vždy `WORK/IN` (protokol pripúšťa aj `KOD/IN`, klient ho nepoužíva, stav dňa mu rozumie).
- **Poškodený súbor vo fronte** (neprejde kontrolou protokolu) sa premenuje na `<názov>.zle`, ostane vo fronte a zaloguje sa; neodošle sa a neblokuje ostatné. Súbor, ktorý sa nedá prečítať, sa nepremenúva a skúsi sa znova.
- **Nedopísaný súbor na serveri**: ak zápis zlyhá až po vytvorení súboru, poznačí sa to súborom `<názov>.ciastocne`; ďalšia chyba 58 sa potom neberie ako doručenie (HR nedopísaný súbor pri príjme presunie do `chybne\` a ďalší pokus prejde).
- **Počítadlo neúspechov** (upozornenie po 5): zvyšuje ho `PRISTUP` (70) a `INA`, nuluje doručenie; nedostupný server ho nemení.
- **Kópia v `odoslane\`** pri chybe 58 (doručené skôr) obsahuje text aktuálneho pokusu; čo presne je na serveri, klient nevie prečítať.
- **Konfigurácia**: tlačidlá sú v poradí riadkov súboru (pole `poradie` musí byť 1 až 4 číslice, inak sa riadok preskočí); ten istý kód môže mať viac tlačidiel; neznáma hodnota `odchod_bez_dovodu` je chybný riadok a platí `OBED`.
- **Testovací režim**: pri lokálnej ceste a platnom `oc_test` sa AD vôbec nepýta.
- **Log** `klient.log` je v kódovaní Windows (zápis `Print #`), `samotest.txt` v UTF-8.
- **Balík HR**: `access/klient` je vylúčený zo ZIP-u inštalátora HR cez `export-ignore`.

### Neoverené / otvorené

- Skutočné práva na serveri a čísla chýb pri pokuse o prepísanie existujúceho súboru (tabuľka v `kl_03_Fronta` je podľa zadania, klient loguje presné číslo chyby).
- Zamrznutie okna počas pokusu o nedostupný server (časový limit SMB) sa akceptuje.
- **Pre M2**: `zaklad.txt` číta klient ako UTF-8 alebo ASCII. Spúšťač `.cmd` zapisuje v kódovej stránke konzoly, takže cesta k základu s diakritikou by sa prečítala zle: spúšťač musí pred zápisom prepnúť `chcp 65001`, alebo sa cesta obmedzí na ASCII a zapíše sa to do README.
- **Pre M2**: okno má volať `ZapisRazenie`, prekresliť sa a až potom `DorucRazenie` (alebo `Razit`, ktoré robí oboje s `DoEvents` medzi krokmi); časovač volá `kl_03_Fronta.OdosliCakajuce(True)` a každý 10. tik `kl_04_Konfig.NacitajKonfig`.
