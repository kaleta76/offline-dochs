# Vydania (GitHub Releases) pre časť Access

Tento návod je pre vlastníka repozitára. Popisuje, ako vydať inštalačný balík časti Access ako **vydanie na GitHube** (sekcia *Releases*), ako si stiahnutie overí používateľ a ako (voliteľne) priložiť aj hotovú databázu `.accdb`.

## Stručne

| Príloha vydania | Kto ju vytvorí | Odporúčanie |
|---|---|---|
| `Dochadzka-Instalator-X.Y.Z.zip` (inštalátor, moduly, návody) | workflow na GitHube, jedným kliknutím | **hlavná príloha**, stačí na všetko |
| `SHA256SUMS.txt` (kontrolný súčet ZIP-u) | rovnaký workflow | vždy |
| `Dochadzka-X.Y.Z.accdb.zip` (hotová databáza) | **iba vy ručne**, na počítači s Windows a Accessom | voliteľná, pozri nižšie |

Hotovú databázu workflow vytvoriť nevie: inštalátor beží len na Windows a potrebuje nainštalovaný Microsoft Access (volá ho cez COM), čo GitHub Actions nemá.
Preto je databáza vždy ručný krok. Používateľovi ju zvyčajne netreba, lebo inštalátor z ZIP-u vytvorí databázu sám jedným dvojklikom na `Instaluj.cmd`.

## Vydanie balíka (automaticky vytvorený koncept)

1. Zlúčte (merge) do `main` zmeny balíka, ktoré chcete vydať. Verzia vydania je `balik` v `access/manifest.json` a musí sedieť s hornou sekciou `## Balík X.Y.Z` v `access/CHANGELOG.md`.
   Kontrolu robí `tools/over_access_balik.py` (spúšťa ju aj CI pri každom pull requeste, takže nesúlad uvidíte skôr).
2. Na GitHube otvorte **Actions → Vydanie balíka Access (koncept) → Run workflow** a vyberte vetvu `main`.
3. Workflow:
   - overí balík (SHA-256 každého modulu podľa `manifest.json`, verzie modulov, žiadny zakázaný súbor ani modul SKE),
   - zostaví ZIP priamo z priečinka `access/` z repozitára (`git archive`, bajt po bajte, lebo inštalátor overuje SHA-256 modulov),
   - rozbalí ho a kontrolu zopakuje nad rozbaleným obsahom,
   - spočíta SHA-256 a vytvorí **koncept vydania** `access-vX.Y.Z` s textom zmien z `CHANGELOG.md`.
   Ak vydanie alebo značka `access-vX.Y.Z` už existuje (aj ako koncept), workflow sa zastaví a nič neprepíše. Vtedy zvýšte verziu balíka alebo starý koncept zmažte.
4. V sekcii **Releases** otvorte koncept (označený *Draft*), prečítajte text, prípadne ho upravte a pridajte prílohy podľa nasledujúcej kapitoly.
5. Zverejnite ho tlačidlom **Publish release**. Dovtedy je koncept viditeľný len vám a ostatným s právom zápisu.

Workflow nič nezverejňuje sám a nič nemení v repozitári (nevytvára commit ani značku skôr, než vydanie zverejníte).

## Voliteľne: pripojiť hotovú databázu `.accdb`

Robte to len ak ju niekto naozaj potrebuje (napr. počítač, na ktorom sa nedá spustiť PowerShell, alebo ukážka bez inštalácie). Je to **neoverená príloha na vlastné riziko**, pretože databázu zostavujete u seba a GitHub ju nijako nekontroluje.

### Postup

1. Použite **čistý počítač alebo čistý Windows účet** s neutrálnym menom (napr. `instalacia`), nie váš pracovný účet. Meno účtu sa totiž zapíše do databázy (pozri nižšie).
2. Stiahnite si **zverejnené vydanie** (nie váš súkromný balík) a rozbaľte ho. Vo verejnom ZIP-e nie je modul snímača SKE a databáza nesmie vzniknúť zo súkromnej verzie, inak by ho obsahovala.
3. Rozbalený priečinok nesmie obsahovať žiadnu inú databázu `.accdb` (inštalátor by ju ponúkol ako zdroj údajov). Spustite v ňom v PowerShelli `.\Instaluj-Dochadzku.ps1 -Tiho -NeOtvarat`
   (alebo dvojklikom `Instaluj.cmd`, ak nie je v priečinku žiadna iná databáza) **bez** parametra `-ZdrojovaDatabaza`: nesmú sa importovať žiadne údaje zo starej databázy.
   Vznikne prázdna databáza `dochadzka-X.Y.Z.accdb`. Parameter `-NeOtvarat` zabráni, aby sa po inštalácii otvorila a zapísala vaše prihlásenie.
4. Otvorte vytvorenú databázu a vyčistite údaje, ktoré vznikli pri inštalácii:

   | Kde | Čo urobiť |
   |---|---|
   | tabuľka `PrihlaseniUzivatelia` | zmazať všetky riadky (Windows meno, názov počítača, doména) |
   | tabuľka `LogImportu` | zmazať všetky riadky (diagnostika inštalátora) |
   | tabuľka `VerzieModulov`, stĺpec `Instaloval` | nahradiť meno účtu neutrálnym textom (napr. `instalator`) |
   | tabuľka `KonfiguraciaVerzie`, stĺpec `Autor` | ak má riadky, nahradiť meno účtu neutrálnym textom |
   | tabuľka `NastaveniaSystemu` | prečítať celú, nemá obsahovať cestu ani meno (kľúče `InstalaciaDatum`, `VerziaBalika` a `VerziaDatovehoModelu` sú v poriadku) |
   | vlastnosti databázy (*Súbor → Informácie → Zobraziť a upraviť vlastnosti databázy*, View and edit database properties) | v záložke Súhrn vymazať Autor, Organizácia a Manažér |
   | tabuľka `TerminalInbox` a ostatné dátové tabuľky | musia byť prázdne (po čistej inštalácii bez zdrojovej databázy aj sú, overte) |

   Po úprave databázu zatvorte a **nespúšťajte ju znova** pred zabalením (každé otvorenie zapíše nový riadok do `PrihlaseniUzivatelia`), alebo po poslednom otvorení vyčistenie zopakujte.
5. Spustite **Nástroje databázy → Zhutniť a opraviť databázu** (Compact and Repair Database), aby z nej zmizli zmazané záznamy (inak môžu ostať fyzicky v súbore).
6. Zabaľte `dochadzka-X.Y.Z.accdb` do ZIP-u s názvom `Dochadzka-X.Y.Z.accdb.zip` (X.Y.Z je verzia balíka, z ktorého databáza vznikla). Súbor `.laccdb` nepribaľujte.
7. Do konceptu vydania pridajte tento ZIP a pripíšte do textu vydania riadok, napr.: *„Hotová databáza vytvorená inštalátorom z tohto balíka na čistom počítači, Access 2019 (64-bit). Neoverená, bez záruky. Odporúčaný postup je inštalátor.“*
   Ak chcete, doplňte jej SHA-256 (`Get-FileHash`) do `SHA256SUMS.txt` (súbor v koncepte môžete nahradiť).

### Čo si pri tejto prílohe uvedomiť

- **Súkromné údaje:** pozrite tabuľku vyššie, pri každej databáze si pred zverejnením skontrolujte, čo v nej je. Vo verejnom vydaní nesmie byť žiadne meno, osobné číslo ani údaj z vašej organizácie. Databáza, ktorá už niekedy obsahovala skutočné údaje, sa nesmie použiť ani po zmazaní riadkov.
- **Modul SKE:** databáza zostavená z vášho súkromného balíka ho obsahuje. Verejná príloha ho mať nesmie (rozhodnutie vlastníka, pozri `access/README.md`). Postup vyššie to zaručuje, ak vychádza zo zverejneného vydania.
- **Blokovanie VBA:** ZIP stiahnutý z internetu dostane od Windows značku „zdroj: internet“ a Access potom zablokuje makrá a VBA. Používateľ musí ZIP pred rozbalením odblokovať (Vlastnosti → Odblokovať) a databázu rozbaliť do dôveryhodného umiestnenia. Napíšte to do textu vydania.
- **Verzia Accessu:** neoverené, ako sa databáza zostavená vo vašej verzii a bitnosti Accessu (32 alebo 64-bit) správa v inej. Uveďte v texte vydania, v akej verzii vznikla. Inštalátor vytvorí databázu vždy v Accesse používateľa, preto je jeho ZIP bezpečnejšia voľba.
- **Aktualizácie:** databáza z vydania X.Y.Z sa neaktualizuje sama. Novšiu verziu modulov do nej dostane inštalátor z novšieho ZIP-u.

## Ako si stiahnutie overí používateľ

V PowerShelli v priečinku so stiahnutými súbormi:

```powershell
Get-FileHash .\Dochadzka-Instalator-X.Y.Z.zip -Algorithm SHA256
```

Výsledok sa musí zhodovať s riadkom v `SHA256SUMS.txt`. Inštalátor navyše pri každom spustení overuje SHA-256 každého modulu podľa `manifest.json`, takže pozmenený modul odmietne.
Ak sa súčet nezhoduje, súbor je poškodený alebo upravený: nepoužívajte ho a stiahnite ho znova.

## Čo kontroluje `tools/over_access_balik.py`

Spúšťa sa z koreňa repozitára: `python3 -I tools/over_access_balik.py` (vypíše `OK` alebo zoznam chýb, kód 1 = chyba). Nič nemení. Kontroluje:

1. SHA-256 a verziu `'@Verzia` každého modulu proti `access/manifest.json`, a že v `access/moduly/` nie je modul navyše,
2. že v balíku nie je modul snímača SKE ani reťazec z neho, databáza (`.accdb`, `.laccdb`, `.mdb`), protokol (`.log`) ani ZIP,
3. že horná sekcia `access/CHANGELOG.md` je verzia balíka z `manifest.json`.

Po úprave modulu spustite v priečinku `access/` príkaz `python tools/zostav_balik.py` (skontroluje verzie a prepíše `manifest.json`).
Ďalšie parametre: `--verzia` vypíše verziu, `--poznamky SUBOR` zapíše text vydania. Testy: `python3 -I tools/test_over_access_balik.py`.

## Čo kontroluje `tools/kontrola_vba.py`

Access hlási chyby kompilácie až pri Ladenie > Kompilovať, a vždy len prvú. Skript `python3 -I tools/kontrola_vba.py` (z koreňa repozitára, CI ho spúšťa pri každom pull requeste) preto vopred prejde všetky moduly v `access/moduly/` a hľadá najčastejšie príčiny: lokálnu premennú s rovnakým menom ako funkcia, ktorú tá istá procedúra volá (VBA nerozlišuje veľkosť písmen, takto vznikla chyba `Expected array` v balíku 2.12.0), nedeklarované premenné pri `Option Explicit`, volanie neexistujúceho alebo súkromného člena modulu, zlý počet argumentov, nezhodu typu pri odovzdaní `ByRef` a nespárované bloky `If` / `For` / `Do` / `With` / `Select`. Nahlási aj možné chyby ako varovania (`--varovania`). Kód 1 = nájdená chyba. Nič nemení. Testy: `python3 -I tools/test_kontrola_vba.py`.
Je to pomôcka, nie kompilátor: typy výrazov a členy objektov DAO ani Access nekontroluje, takže skutočné Ladenie > Kompilovať po inštalácii ostáva v postupe.
