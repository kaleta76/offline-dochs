# Architektúra systému Dochádzka (stav 13. 11. 2026)

Mapa celku: z čoho sa systém skladá, kto čo vlastní, ako idú údaje a podľa čoho sa rozhoduje. Podrobnosti sú v dokumentoch, na ktoré odkazuje; tento dokument ich nenahrádza.

Stav každej časti: **hotové** (je v `main`, má testy alebo CI), **neoverené v prevádzke** (napísané a vyskúšané v sandboxe alebo na ukážkových dátach, nie v ostrej prevádzke ani v skutočnom Accesse), **návrh** (ešte nie je v kóde). Kapitola 7 zhŕňa, čo je overené a čo nie.

## 1. Čo systém je

Náhrada starej dochádzkovej aplikácie hybridným modelom. Základom je **dochádzkový systém v Accesse**: záväzný výpočet, editor dňa, tlač, podpis a uzávierka mesiaca. Razenia do neho prichádzajú z **webového terminálu** (PWA, funguje aj offline) alebo z klienta v Accesse. Terminál je **voliteľná** súčasť: Access funguje aj bez neho.

```
 zamestnanec ──► Terminál (PWA, Supabase)                  Access + VBA (lokálne)
                  razenie aj offline, bez mien              mená, fondy, pravidlá, výpočet
                          │                                  tlač, podpis, uzávierka
                          ├── punches_RRRRMM.csv ───────────►  (kontrakt 1.0)
                          ├── voids_RRRRMM.csv   ───────────►  (kontrakt 1.1)
                          ◄── dochs_config.json ─────────────  (kontrakt 1.2 až 1.5)

 zamestnanec ──► Klient v Accesse ── súbor .rzn ──► príjem v Accesse HR      (návrh)
```

## 2. Súčasti

### 2.1 Terminál (`src/`): hotové, výpočet len orientačný

React a TanStack Start, PWA, backend Supabase (Postgres, RLS, funkcie `SECURITY DEFINER`). Beží na Lovable Cloud (`offline-dochs.lovable.app`), lokálne (Docker a Supabase CLI) alebo na vlastnom serveri; migrácie z `docs/migracie/` spúšťa vlastník ručne v SQL editore.

| Oblasť               | Čo robí                                                                                                                                                                                                                                                 | Dokument                        |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| Razenie              | IndexedDB fronta, idempotentný `client_uuid`, čas servera a hash reťaz doplní databáza (`punches_chain`), razenia sa nemažú                                                                                                                             | `AGENTS.md`                     |
| Identita             | osobné číslo SAP, bez mien a e-mailov; registrácia firmy kódom, zamestnanca PIN-om; odhlásenie pri nečinnosti                                                                                                                                           | `docs/REGISTRACIA.md`           |
| Zariadenia           | párovací kód, schválenie, zrušenie, záchranný kód; neoverené razenie sa prijme, len je označené                                                                                                                                                         | `docs/OVERENIE-ZARIADENI.md`    |
| Opravy               | žiadosť o korekciu a schválenie vedúcim, zneplatnenie razenia, automatické schvaľovanie (migrácia 0013)                                                                                                                                                 | `docs/ZNEPLATNENIE-RAZENI.md`   |
| Obrazovky            | Terminál, Môj mesiac, Môj tím, výkaz A4, Správa (karta Prevádzka a skrytá karta Servis)                                                                                                                                                                 | `AGENTS.md`                     |
| Tlačidlá             | Príchod a Odchod sú pevné, ďalšie tlačidlá sa berú z poslednej prijatej konfigurácie z Accessu (offline kópia len projekcie tlačidiel)                                                                                                                  | `src/lib/terminal-actions.ts`   |
| Výpočet              | `src/lib/engine.ts`, jediné miesto s dochádzkovou matematikou; dnes počíta zo siedmich kódov, spoločných pravidiel organizácie (zaokrúhlenie príchodu a odchodu, obed, predvolený fond), sviatkov a fondu na zamestnanca; konfiguráciu z Accessu nečíta | kapitola 5                      |
| Prenos organizácie   | export a import organizácie medzi servermi, oznam zariadeniam o presťahovaní, neskoré razenia (migrácie 0016 až 0021)                                                                                                                                   | `docs/PRENOS-ORGANIZACIE.md`    |
| Export pre Access    | razenia a zneplatnené razenia podľa kontraktu                                                                                                                                                                                                           | `contract/README.md`            |
| Testovacia prevádzka | import razení z CSV a porovnanie sald s Accessom                                                                                                                                                                                                        | `docs/TESTOVANIE-S-ACCESSOM.md` |

### 2.2 Dochádzkový systém (`access/`): neoverené v skutočnom Accesse

Microsoft Access (plná verzia, Runtime nestačí) a VBA. Inštalátor overuje SHA-256 modulov; balík v `main` je **2.17.0**. Výpočet dňa je v `mod_08_UdalostiDna`, automatické opravy v `mod_09`, pravidlá prerušení a fondy v `mod_16` a `mod_17`, uzávierka v `mod_18`, import z terminála v `mod_19`, export konfigurácie v `mod_20`, režimy výpočtu v `mod_21`, import zo starého systému (DBF) v `mod_02`.

- **Dve nezávislé inštancie** (rozhodnutie 12. 11. 2026): každá inštancia je plný Access s vlastnými zamestnancami a nastaveniami. Medzi inštanciami sa neprenášajú razenia ani nastavenia a nastavenia sa neuzamykajú.
- **Klient na razenie v Accesse** (návrh): zamestnanec razí z Accessu na svojom počítači, razenie je jeden súbor `.rzn` v zdieľanom priečinku, HR ho prijme a prevedie rovnakým kódom ako razenie z terminála. Strana HR (balík 2.18.0) je vo vetve `claude/access-klient-razenia`, nezlúčená. Samotný klient ešte nie je.
- **Snímač SKE**: modul nie je vo verejnom repozitári.
- Kód VBA sa mimo Accessu nedá spustiť. Kontroluje ho `tools/kontrola_vba.py` (CI) a správanie v skutočnom Accesse overuje vlastník; v `access/CHANGELOG.md` je pri každom balíku skúšobný postup.

### 2.3 Kontrakt (`contract/`): hotové, overuje ho CI

Jediné miesto, kde sa dohodne rozhranie medzi terminálom a Accessom. Mení sa len cez PR so schválením vlastníka.

| Súbor                                     | Smer              | Verzia                      |
| ----------------------------------------- | ----------------- | --------------------------- |
| `punches_RRRRMM.csv` (pätička SHA-256)    | terminál → Access | 1.0                         |
| `voids_RRRRMM.csv` (zneplatnenia)         | terminál → Access | 1.1                         |
| `dochs_config.json` (konfigurácia a plán) | Access → terminál | 1.2 až 1.5                  |
| správa o uzávierke mesiaca                | Access → terminál | 1.6.0 (návrh, kapitola 5.7) |

Terminál posiela **fakty** (kto, aký kód, smer, kedy). Mená neopúšťajú Access. Prenos je idempotentný a overiteľný. Konfigurácia z Accessu nesie nastavenia výpočtu aj **plán** (typ dňa a denný fond na každý deň, pre každého zamestnanca a mesiac); správca ju v Správe najprv skontroluje v náhľade a potom prijme celú alebo vôbec (`docs/KONFIGURACIA-Z-ACCESSU.md`).

## 3. Hranica zodpovednosti

| Oblasť                                                     | Terminál                                                                                                                         | Access                      |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | --------------------------- |
| Zachytenie razenia, offline, duplicity                     | vlastní                                                                                                                          | prijíma a páruje            |
| Overenie zariadenia                                        | vlastní                                                                                                                          | zobrazí príznak             |
| Mená a mapovanie na osobné čísla                           | nepozná                                                                                                                          | vlastní                     |
| Fondy, kalendár, šablóny, úväzok                           | zatiaľ len fond na zamestnanca; viď kapitola 5                                                                                   | vlastní (platné od mesiaca) |
| Pravidlá prerušení a výpočet                               | orientačný (`engine.ts`)                                                                                                         | **záväzný** (zásada D1)     |
| Tlač, podpis, uzávierka mesiaca                            | dnes vlastné uzatvorenie mesiaca (`month_closures`); pri spárovanej organizácii prijme uzávierku z Accessu (návrh, kapitola 5.7) | vlastní                     |
| Politika terminálu (kto schvaľuje, kto čo vidí, uzávierka) | vlastní                                                                                                                          | neposiela                   |

**D1 (Access je pravda vo výpočte):** terminál sa má Accessu prispôsobiť, nie ho kopírovať po svojom. Kým výpočet v termináli nečíta konfiguráciu z Accessu, je jeho saldo len orientačné. Integrovaný režim (`prompts/04`, razenie sa vždy prijme, popisky „orientačné“) je návrh, v kóde nie je; uzávierku pri spárovanej organizácii rieši kapitola 5.7.

## 4. Tok údajov a nasadenie

1. Zamestnanec razí v termináli (alebo v klientovi). Terminál zapíše razenie do fronty a odošle ho, keď je spojenie.
2. Správca exportuje razenia a zneplatnenia (Správa → Prevádzka). HR ich importuje do Accessu.
3. HR v Accesse nastaví fondy, pravidlá a prerušenia, vytvorí `dochs_config.json`, správca ho prijme v termináli.
4. Mesiac uzavrie HR v Accesse podpísanou zostavou. Návrh: Access pošle terminálu správu o uzávierke (kapitola 5.7).

Terminál sa dá presťahovať na iný server šifrovaným súborom (`docs/PRENOS-ORGANIZACIE.md`); zariadenia dostanú oznam o presťahovaní a neodoslané razenia sa dajú uložiť do súboru.

Vetvy a synchronizácia s Lovable: `main` je chránená a ide do nej všetko cez PR, Lovable píše do vetvy `lovable` (`docs/LOVABLE-VETVY.md`).

## 5. Nastavenia výpočtu: kto ich vlastní

**Rozhodnuté 13. 11. 2026 (vlastníčka systému).** V kóde zatiaľ nič z toho nie je: je to schválený návrh, podľa ktorého sa píše etapa 1 (kapitola 8).

### 5.1 Stav dnes

Terminál má **dva nezávislé zdroje** nastavení výpočtu:

- **Správa, skrytá karta Servis**: pravidlá výpočtu pre celú organizáciu (`organization_settings`: zaokrúhlenie príchodu a odchodu, dĺžka a hranica obeda, predvolený denný fond, najväčšia odchýlka času), číselník prerušení (`organization_codes`, pevných 7 kódov, upraviť sa dá len názov a SAP kód), sviatky (`organization_holidays`) a denný fond na zamestnanca (`profiles.daily_fund`). Príznaky prerušení, šablóny ani plán po mesiacoch tam nie sú, pravidlá sú rovnaké pre všetkých zamestnancov a časť správania (ktoré kódy sa dopočítajú do fondu) je pevná v kóde. Karta je skrytá, lebo tieto hodnoty majú prísť z Accessu.
- **Konfigurácia z Accessu**: prijíma sa do samostatného úložiska (pravidlá, prerušenia s `calc` a príznakmi, fondy, šablóny, režimy a plán po zamestnancoch a mesiacoch). Zatiaľ ju používajú len tlačidlá a náhľad v Správe. Žiadny výpočet ju nečíta.

Výpočet (`engine.ts`) číta len prvý zdroj. Keby sa teraz písal „výpočet podľa plánu z Accessu“ popri ňom, mal by dve cesty a pre každú organizáciu by záviselo, ktorá platí.

### 5.2 Princíp: jeden model, verzie s platnosťou od mesiaca

1. **Jeden model nastavení výpočtu** v termináli, rovnaký tvar ako kontrakt 1.5.0: pravidlá (`rules`), prerušenia s vlastnosťami (`calc`, hranica celého dňa, príznaky, tlačidlá), režimy, fondy so šablónami a kalendárom, sviatky a plán zamestnanca po mesiacoch (typ dňa, denný fond, okno práce, režim). Model je od začiatku **úplný**, nie jeho jednoduchá podmnožina.
2. **Nastavenia sú verzie, každá s „platí od mesiaca“** (tak ako v Accesse platia fondy a pravidlá od mesiaca). Verzia je buď **terminálová** (pri registrácii vznikne z predvolených hodnôt, správca ju upravuje), alebo **z Accessu** (každý import je nová verzia, len na čítanie). Staré verzie sa nemažú, tvoria históriu.
3. **Vlastník je daný časovou osou.** Pre každý mesiac platí práve jedna verzia: tá s najneskorším „platí od“, ktoré nie je neskoršie než daný mesiac. Ak je to verzia z Accessu, mesiac **patrí Accessu**, inak terminálu. Nová organizácia má terminálovú verziu od mesiaca registrácie.
4. **Výpočet číta len „platné nastavenia pre mesiac“**, jednu funkciu, ktorá podľa mesiaca vyberie verziu. Nemá „režim Access“ a „režim terminál“.
5. **Uzavretý mesiac sa nikdy neprepočíta.** Uzavretý mesiac zamestnanca drží uložený výsledok a snímku nastavení, podľa ktorých sa počítal (tak ako Access ukladá snímku parametrov pri uzavretí). Pri mesiaci, ktorý patrí terminálu, ju ukladá uzávierka v termináli; pri mesiaci, ktorý patrí Accessu, správa o uzávierke (kapitola 5.7).

| Mesiac patrí | Platí                                | Správa (nastavenia výpočtu)                                                                               |
| ------------ | ------------------------------------ | --------------------------------------------------------------------------------------------------------- |
| terminálu    | terminálová verzia platná pre mesiac | upraviteľná v editoroch; úprava platí od mesiaca, ktorý správca určí (predvolene aktuálny)                |
| Accessu      | verzia z Accessu platná pre mesiac   | všetko, čo ovplyvňuje výpočet, je len na čítanie; údaj „verzia a dátum importu“; zmena len novým importom |

**Príklad.** Sep a okt 2026: terminál je sám, platia jeho nastavenia. 13. 11. import z Accessu platný od novembra: september a október ostanú podľa terminálových nastavení, ich výsledky sa nezmenia. Január 2027: nový import platný od januára, december ostane podľa novembrovej verzie. Marec 2027: odpárovanie, od marca platí terminálová verzia (kapitola 5.4).

**Spárovanie nič neprepíše, len pridá verziu z Accessu od zvoleného mesiaca.** Terminálové verzie ostávajú uložené, takže sa k nim dá vrátiť.

Bez čiastočných výnimiek: ak by sa pri mesiaci, ktorý patrí Accessu, dalo zmeniť jedno pravidlo v termináli, terminál a Access by počítali rôzne a saldo by sa nedalo overiť.

### 5.3 Čo zamykanie pokrýva

- **Zamknuté pre mesiace, ktoré patria Accessu**: pravidlá výpočtu, prerušenia a ich vlastnosti, tlačidlá, fondy, šablóny, kalendár, sviatky, režimy, plán zamestnancov.
- **Vždy upraviteľné v termináli** (Access to neposiela): politika terminálu (kto schvaľuje, viditeľnosť salda a prítomnosti), zamestnanci, roly, vedúci, PIN-y, zariadenia, odhlásenie pri nečinnosti.

### 5.4 Spárovanie a odpárovanie

- **Spárovanie** je automatické pri prijatí prvého importu z Accessu. Náhľad pred prijatím **upozorní správcu**, že od zvoleného mesiaca platia nastavenia z Accessu, terminálové verzie ostanú uložené a dajú sa k nim vrátiť, a vyžiada výslovné potvrdenie.
- **Import platí od mesiaca importu** (predvolene). Ak sú predchádzajúce mesiace ešte otvorené, náhľad to ukáže: „Október nie je uzavretý u N zamestnancov, ostane s pôvodnými nastaveniami. Použiť Access aj pre október?“ Odpoveď „áno“ prepočíta len **neuzavreté** mesiace zamestnancov; uzavretý mesiac sa nezmení nikdy. Nie je to tvrdá podmienka (jeden neuzavretý zamestnanec by zablokoval celý import). Plán z Accessu za mesiace pred platnosťou sa uloží, ale nepoužije.
- **Ďalšie importy** sú nové verzie z Accessu s rovnakými pravidlami platnosti; terminálové verzie sa nikdy neprepíšu.
- **Odpárovanie** je samostatné tlačidlo len pre správcu, s potvrdením a záznamom do auditu. Správca **vyberie, s čím terminál pokračuje**:
  - **kópia posledných nastavení z Accessu** (predvolené): pravidlá sa uprostred roka nezmenia a správca ich môže upraviť; vhodné, ak firma Access prestane používať alebo ho len mení;
  - **posledná terminálová verzia spred spárovania**: vhodné, ak to boli skutočne udržiavané nastavenia; ak boli len predvolenými hodnotami z registrácie, priniesla by zbytočný skok.

  Pred voľbou sa ukáže rozdiel (napríklad „zaokrúhlenie 5 min → 0, obed 30 → 45“). Nová terminálová verzia platí od zvoleného mesiaca podľa rovnakých pravidiel o neuzavretých mesiacoch. Verzie z Accessu ostanú v histórii.

- **Minulé mesiace** ostávajú s verziou, podľa ktorej sa počítali; plán z Accessu ostáva pri mesiacoch, ktoré patria Accessu. Deň bez plánu v takom mesiaci ukáže „bez plánu z Accessu, nepotvrdené“, nie tichý odhad.
- Odpárovanie nie je prepínač pre každodenné použitie: kto Access používa na záväzný výpočet, nemá odpárovať, nastavenia by sa rozišli.

### 5.5 Úplné rozhranie nastavení v termináli

Pre firmu bez Accessu je terminál jediný systém, nie orientačný pohľad. Jednoduchá podmnožina editorov by jej zafixovala zvyšok nastavení na predvolených hodnotách a výpočet by nemusel zodpovedať jej pracovnému poriadku. Preto sa v termináli robí **úplné rozhranie** pre celý model, po etapách (kapitola 8), a model je úplný už od prvej etapy, lebo sa dodatočne mení najdrahšie.

- **Predvolená terminálová verzia pri registrácii** pokrýva celý model (kódy prerušení s príznakmi, fond, pravidlá, sviatky). Hodnoty sú orientačné, kým ich nepotvrdí smernica.
- **Cena**: každá zmena kontraktu znamená zmenu v Accesse, kontrakte, editore aj výpočte. Zmierňuje to tvar modelu podľa kontraktu 1.5.0 a kontrola voči jeho schéme (`contract/config-export.schema.json`).
- **Overenie**: generátor plánu v TypeScripte sa porovná s referenčným Pythonom (`contract/tools/build_config_example.py`) na súbore vstupov (rovnaká metóda ako pri prechode na zod 4, PR #75); výpočet sa overí na zlatom scenári `contract/scenare/2026-10`.
- **Osobné údaje**: terminál ich nezbiera ani pri firme bez Accessu. Tlačený výkaz má riadok na ručné doplnenie mena, ostatné políčka ostanú prázdne.
- **Export pre SAP je mimo rozsahu**: formát nie je určený. Ak ho niekto bude potrebovať a dodá špecifikáciu, doplní sa.

### 5.6 Čo z toho vyplýva pre výpočet

- Ostáva čistou funkciou bez I/O v `src/lib/engine.ts` (pravidlo z `AGENTS.md`). Vstup: razenia dňa, plán dňa (typ dňa, denný fond, okno práce, režim), platné nastavenia pre mesiac dňa (po uplatnení režimu) a vlastnosti prerušení. Deň bez plánu v mesiaci, ktorý patrí Accessu, vráti stav „bez plánu, nepotvrdené“. Uzavretý mesiac zamestnanca sa nepočíta, použije sa jeho uložený výsledok.
- Plán zamestnanca sa v zariadení **nekešuje** (`AGENTS.md`): výpočet s plánom potrebuje spojenie so serverom.
- Pri mesiaci, ktorý patrí terminálu, plán dňa vyrobí terminál sám podľa terminálovej verzie (fond, deň v týždni, kalendár, sviatky, úväzok). Referenčný výpočet plánu je v `contract/tools/build_config_example.py` a v Accesse v `mod_08.NacitajKontextMesiaca`.
- Overenie: zlatý scenár `contract/scenare/2026-10` a porovnanie sald s Accessom (`docs/TESTOVANIE-S-ACCESSOM.md`). Rozdiely, ktoré ostanú, sa vypíšu s dôvodom.

### 5.7 Uzávierka mesiaca pri spárovanej organizácii

Vyžaduje **kontrakt 1.6.0** (správa o uzávierke, smer Access → terminál). Vlastníčka jeho návrh povolila 13. 11. 2026; zmena sa robí samostatným PR so schválením a samostatným balíkom Access.

- Access uzavrie mesiac a pošle správu o uzávierke. Terminál ju prijme a **zosúladí**: mesiac zamestnanca označí ako uzavretý Accessom a ukáže záverečné čísla z Accessu.
- **Razenia mimo uzávierky** (Access ich nezarátal, napríklad prišli neskôr) terminál uloží do auditu a upozorní na ne vedúceho.
- **Razenie sa vždy prijme**: pri mesiaci, ktorý patrí Accessu, uzavretie mesiaca razenie neblokuje (cieľový stav z `AGENTS.md`, bod 5).
- Správa nesie pre zamestnanca (osobné číslo) a mesiac záverečné čísla a odtlačok zarátaných razení (počet a stav hash reťaze; vzorec sa nemení). Presný tvar určí kontrakt 1.6.0.
- Mesiac, ktorý patrí terminálu, uzatvára terminál sám ako dnes (a uloží výsledok a snímku nastavení).
- Kým kontrakt 1.6.0 nie je schválený a zavedený aj v Accesse, platí dnešné správanie (`month_closures`).

### 5.8 Otvorené

1. **Snímka uzavretého mesiaca**: čo presne obsahuje (verzia nastavení, výsledok mesiaca) a ako sa ukladá pri uzávierke v termináli aj pri správe z Accessu. Rozhodne etapa 1 a skontroluje ju nezávislá kontrola.
2. **Platnosť verzie a uzavretie po zamestnancoch**: verzia platí od mesiaca, uzavretie je po zamestnancoch. Treba určiť, ako Správa pri voľbe mesiaca ukáže, ktorí zamestnanci sú uzavretí a ktorých mesiac sa prepočíta.
3. **Starší terminál, novší kontrakt**: súbor s neznámymi kľúčmi sa dnes odmietne celý. Treba určiť verziu nastavení a správanie pri nezhode.
4. **Správa o uzávierke**: tvar, opakovaná alebo opravná uzávierka, znovuotvorenie mesiaca v Accesse.

## 6. Bezpečnostné zásady

- Pseudonymizácia: osobné číslo SAP, nikde mená ani e-maily; do repozitára nepatria skutočné osoby, produkčné exporty ani kľúče (`docs/SPOLUPRACA.md`, CI krok „no-secrets“). Platí to aj pre firmu bez Accessu (kapitola 5.5).
- Razenia sa nemažú; oprava je nové razenie s auditom. Vzorec hash reťaze sa nemení.
- Oprávnenia rozhoduje databáza (RLS a funkcie), nie aplikácia.
- Zmena kontraktu a hash reťaze len s výslovným pokynom vlastníčky (`AGENTS.md`).

## 7. Čo je overené a čo nie

- **Overené:** testy aplikácie (vitest) a CI na `main`; migrácie 0016 až 0021 v sandboxe PostgreSQL 16 nad lokálnou schémou aplikácie; ručné skúšky prenosu organizácie medzi Lovable a lokálnym Supabase.
- **Neoverené v prevádzke:** VBA v skutočnom Accesse (kontrola je len statická a skúšobné postupy v `access/CHANGELOG.md`), klient v Accesse, výpočet terminálu podľa plánu a model s verziami nastavení (nie sú napísané), správa o uzávierke (nie je v kontrakte), správanie na ostrej databáze Lovable Cloud pri veľkých súboroch, obrazovky v prehliadači okrem ručne vyskúšaných scenárov.
- Tvrdenia o stave databázy terminálu vychádzajú z kódu, dokumentov a lokálnej databázy; na Lovable Cloud ich treba overiť SQL kontrolou.

## 8. Poradie prác

Veľké časti píše jeden agent v samostatnom chate podľa písomného zadania a kód nezávisle kontroluje iný, aby písanie a kontrola nešli z jednej hlavy.

1. **Architektúra a rozhodnutia** (tento dokument), nezávislá kontrola dokumentu.
2. **Kontrakt 1.6.0** (správa o uzávierke): len `contract/`, samostatný PR na schválenie vlastníčkou. Zavedenie v termináli a v Accesse až po schválení.
3. **Etapa 1 – model a výpočet**: úplný model, verzie nastavení s platnosťou od mesiaca (terminálové a z Accessu), predvolená terminálová verzia pri registrácii, automatické párovanie pri prijatí importu s upozornením a voľbou pri otvorených mesiacoch, odpárovanie s výberom, „platné nastavenia pre mesiac“, snímka uzavretého mesiaca, výpočet nad modelom, zobrazenie platných nastavení v Správe na čítanie. Rozhodnú otvorené body 5.8/1 a 5.8/2.
4. **Etapa 2 – editory** pravidiel, fondov, šablón, kalendára a sviatkov.
5. **Etapa 3 – editor prerušení** s príznakmi a tlačidlami.
6. **Etapa 4 – plán zamestnanca**: generátor po mesiacoch, režimy výpočtu.
7. **Etapa 5 – uzávierka z Accessu v termináli** (po kontrakte 1.6.0 a balíku Access): zosúladenie mesiaca, razenia mimo uzávierky do auditu s upozornením.
8. **Access**: klient na počítači zamestnanca, okno na nastavenie režimov výpočtu, okno práce podľa fondu a organizačnej jednotky, upozornenie na razenie mimo okna, zostávajúce body z `access/CHANGELOG.md`.

## 9. Rozhodnutia

| Dátum        | Rozhodnutie                                                                                                                                                                                                            |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 3. 11. 2026  | Terminál je zberač razení, Access záväzný systém záznamov a výpočtu (zásada v `docs/SPOLUPRACA.md`, v `docs/KONFIGURACIA-Z-ACCESSU.md` ako D1); rozhranie je `contract/`                                               |
| 4. 11. 2026  | Tlačidlá terminálu sa riadia konfiguráciou z Accessu (kontrakt 1.3.0)                                                                                                                                                  |
| 5. 11. 2026  | Výpočet riadia parametre, ktoré nastavuje správca; kontrakt 1.4.0 a 1.5.0                                                                                                                                              |
| 11. 11. 2026 | Základom náhrady je Access, terminál je voliteľný; výpočtový motor po vyplnení dotazníkov                                                                                                                              |
| 12. 11. 2026 | Dve nezávislé inštancie Accessu, nastavenia sa neprenášajú; klient na razenie v Accesse                                                                                                                                |
| 13. 11. 2026 | Vetvy `main` (chránená) a `lovable` (pripojená k Lovable), synchronizácia PR-kami                                                                                                                                      |
| 13. 11. 2026 | Jeden úplný model nastavení výpočtu; nastavenia sú verzie s platnosťou od mesiaca (terminálové a z Accessu), vlastník je daný časovou osou; uzavretý mesiac sa nikdy neprepočíta (uložený výsledok a snímka nastavení) |
| 13. 11. 2026 | Spárovanie automaticky pri prijatí importu s upozornením; import platí od mesiaca importu, pri otvorených minulých mesiacoch upozornenie s voľbou (nie tvrdá podmienka)                                                |
| 13. 11. 2026 | Odpárovanie tlačidlom s výberom: kópia posledných nastavení z Accessu (predvolené) alebo posledná terminálová verzia spred spárovania                                                                                  |
| 13. 11. 2026 | Úplné rozhranie nastavení v termináli po etapách (pre firmy bez Accessu); model úplný od začiatku                                                                                                                      |
| 13. 11. 2026 | Uzávierka z Accessu: terminál zosúladí mesiac, razenia mimo uzávierky do auditu s upozornením; návrh kontraktu 1.6.0 povolený                                                                                          |
| 13. 11. 2026 | Terminál osobné údaje nezbiera, mená sa dopisujú ručne na tlačený výkaz; export pre SAP je mimo rozsahu, kým nie je špecifikácia                                                                                       |
