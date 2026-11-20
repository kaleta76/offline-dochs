# Zmeny klienta na razenie (DochadzkaKlient.accdb)

## Balík 1.0.1

Opravy z nezávislej kontroly balíka 1.0.0 (D1 až D4 a drobnosti) a z prvej skúšky v Accesse 17. 11. 2026. **Nič z toho sa tu nedalo spustiť**: platí rovnaké „neoverené“ ako pri 1.0.0, skúšobný postup nižšie sa len rozšíril (kroky 2, 5 a 7).

### Čo sa zmenilo

- **D1: klient sa otvorí aj pri výpadku servera.** `Vytvor-Odkaz.cmd` teraz skopíruje `Spusti-Dochadzku.cmd` do `%LOCALAPPDATA%\DochadzkaKlient\`, zapíše tam `zaklad.txt` (cesta k serveru) a odkazy (plocha aj Po spustení) mieria na **lokálnu kópiu**. Lokálna kópia berie základ zo `zaklad.txt` a klienta zo `<základ>\klient`; ak `zaklad.txt` chýba, ukáže pokyn spustiť raz `Vytvor-Odkaz.cmd` zo servera. Spúšťač spustený priamo zo servera (a s argumentom na skúšku) funguje ako doteraz. Vedľajší prínos: lokálny `.cmd` nevyvolá varovanie o neoverenom vydavateľovi zo sieťovej cesty. **Zmenený spúšťač sa k zamestnancom dostane opätovným spustením `Vytvor-Odkaz.cmd`** (zriedka; staré odkazy na server fungujú ďalej).
- **D2: dôveryhodné umiestnenie aj na čistom profile.** Spúšťač už nevyžaduje, aby v `HKCU` existoval kľúč Accessu (nemá ho používateľ, ktorý Access ešte nespustil): verzia Office sa berie aj z `HKLM\SOFTWARE\Microsoft\Office\<verzia>\Access\InstallRoot` (aj `WOW6432Node`); ak sa nenájde žiadna, pridá sa kľúč pre 16.0. Zápis ostáva len do `HKCU`.
- **D3: cesta so zátvorkou.** Zápisy a hlásenia so zakladom sú mimo blokov `if ( ... )` (skoky `goto` na návestia), takže cesta ako `C:\dochadzka (test)` spúšťač nerozbije. Zakázané ostáva `&`, `^`, `!`.
- **D4: orezané správy v okne.** Základné chybové texty sú kratšie (`CHYBA_OC`, `CHYBA_UCET`, `CHYBA_PC`, `SPRAVA_BEZ_ZAKLADU`, najviac 60 znakov); správa dlhšia než 60 znakov sa ukáže menším písmom (9), dlhšia než 76 znakov sa skráti na „...“ a celý text je v bubline po nastavení myši (`ControlTipText`). Nové čisté funkcie `VelkostPismaSpravy` a `TextSpravyPreOkno` overuje samotest.
- **Zatvorenie okna inak než tlačidlom Koniec** (Ctrl+F4 a pod.) robí posledný pokus o odoslanie a upozorní na čakajúce razenia, rovnako ako tlačidlo Koniec (špecifikácia §6.5).
- **Drobnosti.** Chýbajúci `verzia.txt` na serveri už nespôsobí kopírovanie `.accdb` pri každom štarte (lokálny klient sa nechá); `spustac.log` sa nad 200 kB odloží do `spustac.old`; `Vytvor-Odkaz.cmd` odmietne spustenie z lokálneho priečinka (zlá cesta k serveru); odstránená nepoužitá premenná `lKopia`. Verzia klienta v okne a v `.rzn` je 1.0.1.

### Zámerne nezmenené

- **D5 (prázdny text Príchod v blokovanom stave)** sa pri druhom spustení nezopakoval; nechané na pozorovanie, nie opravované naslepo. Ak sa objaví, podozrenie je prepisovanie `btnPrichod.Caption` pri každom tiku.
- Etapa 3 (prehľad mesiaca v klientovi) nie je súčasťou tejto opravy.

### Overené (mimo Accessu)

- Lint `kontrola_vba.py` (klient aj HR): 0 chýb. `over_access_balik.py --koren access/klient`: balík 1.0.1, 9 modulov. Testy `test_klient_protokol`, `test_klient_zhoda`, `test_kontrola_vba`, `test_over_access_balik`: prechádzajú.
- Súbory `.cmd` sú ASCII s CRLF. Logika spúšťača a odkazu sa prešla očami (štruktúra skokov, návestia, blokové zátvorky); `cmd` sa tu nespúšťal.

### Do skúšobného postupu navyše

- Krok 2: zapísať, či Access hlásil blokovaný obsah (D2), a skúsiť aj na čistom profile.
- Krok 5: **odpojiť server (alebo premenovať `klient\` na serveri) a spustiť odkaz na ploche**: klient sa musí otvoriť a razenie sa uloží lokálne (D1). Skúsiť aj cestu so zátvorkou, napr. `Spusti-Dochadzku.cmd "C:\dochadzka (test)"` (D3).
- Krok 7: zavrieť okno inak než tlačidlom Koniec pri čakajúcom razení a skontrolovať upozornenie.

## Balík 1.0.0

Prvé vydanie klienta na razenie: malý samostatný súbor Accessu `DochadzkaKlient.accdb` na pracovnom počítači zamestnanca. Zamestnanec klikne Príchod, Odchod alebo tlačidlo prerušenia, klient razenie zapíše najprv do lokálneho záznamu a potom ako súbor `.rzn` (protokol v1) do `prijem\` na serveri, odkiaľ ho HR prevezme príjmom z balíka 2.18.x. Návrh, protokol a práva na priečinky: `docs/KLIENT-ACCESS.md`. Postup pre zamestnanca: `PRIRUCKA.md`, pre správcu: `README.md`.

**Stav: hotové okrem overenia v skutočnom Accesse (etapa 2, míľniky M1 až M3).** Nič z VBA, PowerShellu ani `.cmd` sa tu nedalo spustiť; skúšobný postup je nižšie.

### Čo balík obsahuje

- `moduly/kl_00` až `kl_08`: spoločné funkcie, identita (Windows a AD), protokol `.rzn`, fronta a odosielanie, konfigurácia tlačidiel, razenie, okno `frmKlient`, štart, samotest.
- `Spusti-Dochadzku.cmd` (spúšťač na počítači zamestnanca), `Vytvor-Odkaz.cmd` (odkaz na ploche a v Po spustení), `Instaluj-Klienta.ps1` + `.cmd` (zostavovač pre správcu), `manifest.json`, `testy/klient_konfig_vzor.txt`.
- Nástroje a testy mimo balíka: `access/tools/zostav_balik.py --koren`, `tools/over_access_balik.py --koren`, `tools/klient_protokol.py` (referencia a zrkadlá), `tools/test_klient_zhoda.py`, kroky v CI.

### Overené (mimo Accessu)

- Lint `python3 -I tools/kontrola_vba.py --adresar access/klient/moduly`: 0 chýb, 0 varovaní. Lint balíka HR: 0 chýb.
- `python3 -I tools/over_access_balik.py --koren access/klient`: balík 1.0.0, 9 modulov, kontrolné súčty sedia. Balík HR (2.18.1) nezmenený.
- `tools/test_klient_zhoda.py`: zlaté vektory v `kl_08_Samotest.bas` sa bajt po bajte zhodujú s `klient_protokol.zostav` a prejdú `rozober`; zlé vzory dávajú rovnaké kódy chýb ako `zle_vzory()`; tabuľka chýb odoslania (vektory aj vetvy `Select Case` v `kl_03_Fronta`), počítadlo neúspechov, stav dňa, otázky pred razením a rozbor konfigurácie sa zhodujú s Pythonom; zmena vektora bez zmeny pravidla test zhodí.
- `tools/test_klient_protokol.py`, `tools/test_over_access_balik.py`, `tools/test_kontrola_vba.py` a ostatné testy v `tools/` a `contract/` prechádzajú; CI je zelené.
- ZIP inštalátora HR (`git archive HEAD:access`) neobsahuje `klient/` (`access/.gitattributes`: `klient export-ignore`).
- Súbory `Spusti-Dochadzku.cmd`, `Vytvor-Odkaz.cmd`, `Instaluj-Klienta.cmd` sú ASCII s CRLF; `Instaluj-Klienta.ps1` je UTF-8 s BOM (ako inštalátor HR).

### Neoverené v skutočnom Accesse a vo Windows

**Všetok kód VBA.** Nebol skompilovaný ani spustený. Test zhody overuje len to, že vektory vo VBA a pravidlá v Pythone tvrdia to isté, nie že VBA kód počíta správne; to ukáže až `SamoTestKlienta` v Accesse. Osobitne neoverené:

- **Zostavovač `Instaluj-Klienta.ps1`** (COM Access, import modulov, kompilácia, makro AutoExec, samotest) a **spúšťač `Spusti-Dochadzku.cmd`** (UNC cesty, `chcp 65001`, výmena `.accdb`, `reg add` do dôveryhodných umiestnení) sa nespúšťali; PowerShell nebol k dispozícii ani na kontrolu syntaxe.
- **Okno `frmKlient`**: `CreateForm` a `CreateControl`, udalosti `=Funkcia()`, zablokovanie a odblokovanie tlačidiel časovačom, `CloseButton = False`, skrytie pásu kariet a navigačného panela.
- Volania Windows (`GetSystemTime`, `CoCreateGuid`) v 32- aj 64-bitovom Office, čítanie osobného čísla z AD, zámok inštancie (`klient.lock`), čísla chýb pri zápise do `prijem\` so skutočnými právami na serveri, správanie pri nedostupnej sieti.

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
- **Okno**: formulár `frmKlient` vzniká raz pri zostavení (`kl_07_Spustenie.PripravKlienta`), udalosti sú výrazy `=Funkcia()` na verejné funkcie štandardného modulu (bez triedy formulára). Tlačidlo najprv zablokuje tlačidlá, `ZapisRazenie` zapíše, okno sa prekreslí („Zapísané hh:mm (odosielam…)“, `DoEvents`) a až potom `DorucRazenie` urobí jediný pokus o server. Odblokovanie robí krátky tik časovača okna podľa `BlokovaneDo()`.
- **Časovač počas razenia**: kým beží razenie z tlačidla, tik časovača nič nerobí (príznak v `kl_06_Okno`), takže práve zapísané razenie nemôže odísť s `odlozene=1`. Súbeh s odosielaním z časovača ďalej chráni `mOdosielam` v `kl_03_Fronta`.
- **Koniec**: tlačidlo Koniec skúsi ešte raz odoslať čakajúce razenia, upozorní na tie, ktoré zostali, uvoľní zámok a ukončí Access. Zatvorenie okna inak (napr. Ctrl+F4) klienta tiež ukončí, aby nebežal bez okna so zámkom inštancie. Tlačidlo Zavrieť okna je vypnuté (`CloseButton = False`).
- **Zámok inštancie**: `klient.lock` sa otvorí na výhradný zápis po celý čas behu; chyba 70 = klient už beží (druhá inštancia to oznámi a skončí). Iná chyba pri zámku sa zaloguje a klient beží ďalej (razenia majú vlastné `id`, súbeh nič nezdvojí).
- **Skrytie panelov**: pás kariet a navigačný panel sa skrývajú pri každom štarte (`DoCmd.ShowToolbar`, `NavigateTo` + `acCmdWindowHide`, ako v konzole HR); nič sa netrvalo nezamyká a správca otvorí klienta so Shiftom.
- **Namapovaná sieťová jednotka** (poznámka z kontroly M1): `JeLokalnaCesta` pozná aj `Z:\` cez `FileSystemObject.GetDrive(...).DriveType`; sieťová jednotka sa berie ako sieťová cesta (testovací režim sa nepovolí). Ak sa typ jednotky nepodarí zistiť, cesta sa berie ako sieťová. V ostrej prevádzke sa aj tak odporúča UNC cesta.
- **Spúšťač**: zapisuje `zaklad.txt` po `chcp 65001` (UTF-8 bez BOM; klient číta UTF-8 aj ASCII); cesta zakladu nesmie obsahovať `&`, `^` ani `!`. `.accdb` sa kopíruje pod názvom `.new` a premenuje sa až po úspešnom skopírovaní, `verzia.txt` sa kopíruje ako posledný (zlyhá výmena = ostáva stará verzia, nič sa nehlási). Dôveryhodné umiestnenie sa zapisuje len do `HKCU` (bez práv správcu), len ak existuje kľúč Accessu danej verzie; `Path` s koncovým `\\` v príkaze `reg add`. Spúšťač píše stručný `spustac.log` (bez mien).
- **Zostavovač**: zostavuje vždy nový súbor (doterajší sa premenuje na `DochadzkaKlient_stary_<čas>.accdb`), po kompilácii vytvorí formulár, spustí samotest (pri ZLE končí s kódom 6) a až potom vytvorí makro AutoExec (`Spusti()`), aby sa počas zostavovania nič nespustilo samo. `verzia.txt` (`klient=<verzia>`, `sha256=<SHA-256 súboru>`) sa počíta po zatvorení Accessu. Pri `-Publikuj` ide najprv `.accdb` pod dočasným názvom (kontrola SHA-256), potom spúšťače a `verzia.txt` až nakoniec. Protokol zostavenia nezapisuje používateľské meno z cesty profilu.
- **`ZapisAsciiNovy`** (len lokálne súbory) prepíše existujúci cieľ; názov je zavádzajúci, správanie pre lokálny záznam je správne, preto sa nepremenúvalo.
- **Otázky pred razením** (`MsgBox`) zastavia kód, kým používateľ neodpovie; časovač okna počas toho nebeží a ďalšie razenie chráni príznak `mRazim`.

### Neoverené / otvorené

- Skutočné práva na serveri a čísla chýb pri pokuse o prepísanie existujúceho súboru (tabuľka v `kl_03_Fronta` je podľa zadania, klient loguje presné číslo chyby).
- Zamrznutie okna počas pokusu o nedostupný server (časový limit SMB) sa akceptuje; zapísané razenie je vtedy už v lokálnom zázname.
- Politika makier (GPO) môže zablokovať dôveryhodné umiestnenie; správca ho potom nastaví politikou. Pri mazaní profilu (VDI, `%LOCALAPPDATA%`) sa stratí aj fronta a záznam razení.
- `.accde` a podpis kódu sa nerobili (možné spevnenie, pozri `README.md`).
- Etapa 3 (prehľad vlastného mesiaca) nie je v tomto balíku.

### Skúšobný postup (na jednom počítači s Accessom, bez servera)

**Príprava.** Kópia databázy HR, v nej testovací zamestnanec `9000001` s `LoginAD` = váš Windows účet (zistíte ho príkazom `echo %USERNAME%`; postup ako v balíku 2.18.0, krok 1). Karta 7, „Klient na razenie v Accesse: nastaviť priečinok…“, zadajte `C:\dochadzka-test` (vzniknú `prijem`, `konfiguracia`, `spracovane`, `chybne` a `konfiguracia\klient_konfig.txt`). V tabuľke `NastaveniaSystemu` nastavte `KlientAjDnesne` = `1` a `KlientKontrolaVlastnika` = `UPOZORNIT`.

1. **Zostavenie.** V repozitári `access\klient\Instaluj-Klienta.cmd -Vystup C:\dochadzka-test\klient` (najprv môžete s `-IbaOtestuj`). Očakávané: „Kompilácia prebehla bez chyby“, „Samotest klienta: ZLE 0“, makro AutoExec vytvorené, „Zostavenie dokončené“; v `C:\dochadzka-test\klient` je `DochadzkaKlient.accdb`, `verzia.txt` (dva riadky `klient=1.0.0` a `sha256=...`), `Spusti-Dochadzku.cmd`, `Vytvor-Odkaz.cmd` a protokol `instalacia_klient_*.log`. Ak kompilácia hlási chybu, Access ostane otvorený na riadku s chybou: pošlite názov modulu, riadok a text.
2. **Spustenie.** `mkdir "%LOCALAPPDATA%\DochadzkaKlient"` a `echo oc_test=9000001> "%LOCALAPPDATA%\DochadzkaKlient\test.ini"`. Potom `C:\dochadzka-test\klient\Spusti-Dochadzku.cmd C:\dochadzka-test`. Očakávané: okno „Dochádzka – razenie“, oranžový pruh „TESTOVACÍ REŽIM“, „Osobné číslo 9000001 · účet <váš účet>“, tlačidlá prerušení zodpovedajú `klient_konfig.txt`, stav „Dnes ešte bez razenia“. Zapíšte, či Access hlásil blokovaný obsah (spúšťač mal pridať dôveryhodné umiestnenie; `%LOCALAPPDATA%\DochadzkaKlient\spustac.log`).
3. **Razenie.** Príchod, Odchod (obed), Príchod, Lekár, Návrat do práce, Odchod. V `C:\dochadzka-test\prijem` je 6 súborov `RRRRMMDD-HHMMSS_<id>.rzn`, v okne zoznam „Dnes“ so šiestimi razeniami „odoslané“. Jeden súbor otvorte (ASCII, `#END` na konci, `odlozene=0`) a všetky skontrolujte: `python3 -I tools/klient_protokol.py over C:\dochadzka-test\prijem\*.rzn`. Odchod bez príchodu a rýchle opakovanie rovnakého razenia sa majú pýtať Áno/Nie.
4. **Príjem v HR.** Karta 7, „Prijať razenia z klientov“, najprv nanečisto, potom naozaj: 6 prijatých, v `DochadzkaImport` v správnom poradí (príchod, obed, návrat, lekár, návrat, odchod), v `KlientRazenia` vlastník = váš účet.
5. **Výpadok.** Premenujte `C:\dochadzka-test\prijem` na `prijem_x` a razte Príchod: okno hlási „Zapísané hh:mm, čaká na odoslanie“, dolu „Čaká na odoslanie: 1 (server nedostupný)“, súbor je v `%LOCALAPPDATA%\DochadzkaKlient\razenia\fronta`. Vráťte názov `prijem`: do minúty sa razenie odošle a súbor v `prijem` má `odlozene=1`. Zapíšte číslo chyby z `log\klient.log`.
6. **Opakovanie.** Skopírujte hotový súbor zo `spracovane` späť do `prijem`: HR ho vyhlási za duplicitu a nevloží druhýkrát.
7. **Aktualizácia.** Zatvorte klienta tlačidlom Koniec. V `kl_00_Spolocne.bas` zmeňte `VERZIA_KLIENTA` na `"1.0.1"`, potom `python3 -I access/tools/zostav_balik.py --koren access/klient --bump kl_00_Spolocne --balik 1.0.1`, zostavte s `-Vystup C:\dochadzka-test\klient` a spustite spúšťač: v okne je „klient v1.0.1“ a razenia v `razenia\odoslane` ostali. Zmenu potom vráťte (`git checkout access/klient`).
8. **Zlý čas.** V nastaveniach Windows zmeňte časové pásmo na iné než Bratislava, razte: nesmie sa zapísať nič a okno povie „Hodiny počítača nie sú v časovom pásme Bratislava, razenie sa nezapísalo.“ Pásmo vráťte.
9. **Samotest a druhá inštancia.** V okne priamych príkazov klienta (Ctrl+G, otvorený so Shiftom) `? kl_08_Samotest.SamoTestKlienta()` vráti `0`. Pri bežiacom klientovi spustite spúšťač znova: druhá inštancia povie „Klient už beží“.
10. **Skutočný server (neskôr).** V `\\server\dochadzka\prijem` s účtom zamestnanca: vytvorenie súboru áno; zápis do už existujúceho súboru nie (zapíšte číslo chyby z `klient.log`); zoznam a čítanie cudzích súborov nie; vlastník súboru = účet zamestnanca. Výsledok pošlite, podľa neho sa upraví tabuľka mapovania chýb.
11. **Upratanie.** `rmdir /s /q C:\dochadzka-test`, `rmdir /s /q "%LOCALAPPDATA%\DochadzkaKlient"`, `reg delete "HKCU\Software\Microsoft\Office\16.0\Access\Security\Trusted Locations\DochadzkaKlient" /f` (verziu Office upravte), v HR kópii `?mod_19_TerminalImport.OdstranTestoveData()` a ručne riadky `TerminalInbox` s `KL-%` a tabuľku `KlientRazenia` (ako v 2.18.0).

Na vyhodnotenie pošlite: protokol zostavenia, `log\klient.log`, `log\samotest.txt`, `spustac.log` a text chýb, ktoré Access zobrazil.
