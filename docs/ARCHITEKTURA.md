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

| Súbor                                     | Smer              | Verzia     |
| ----------------------------------------- | ----------------- | ---------- |
| `punches_RRRRMM.csv` (pätička SHA-256)    | terminál → Access | 1.0        |
| `voids_RRRRMM.csv` (zneplatnenia)         | terminál → Access | 1.1        |
| `dochs_config.json` (konfigurácia a plán) | Access → terminál | 1.2 až 1.5 |

Terminál posiela **fakty** (kto, aký kód, smer, kedy). Mená neopúšťajú Access. Prenos je idempotentný a overiteľný. Konfigurácia z Accessu nesie nastavenia výpočtu aj **plán** (typ dňa a denný fond na každý deň, pre každého zamestnanca a mesiac); správca ju v Správe najprv skontroluje v náhľade a potom prijme celú alebo vôbec (`docs/KONFIGURACIA-Z-ACCESSU.md`).

## 3. Hranica zodpovednosti

| Oblasť                                                     | Terminál                                                                                                               | Access                      |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | --------------------------- |
| Zachytenie razenia, offline, duplicity                     | vlastní                                                                                                                | prijíma a páruje            |
| Overenie zariadenia                                        | vlastní                                                                                                                | zobrazí príznak             |
| Mená a mapovanie na osobné čísla                           | nepozná                                                                                                                | vlastní                     |
| Fondy, kalendár, šablóny, úväzok                           | zatiaľ len fond na zamestnanca; viď kapitola 5                                                                         | vlastní (platné od mesiaca) |
| Pravidlá prerušení a výpočet                               | orientačný (`engine.ts`)                                                                                               | **záväzný** (zásada D1)     |
| Tlač, podpis, uzávierka mesiaca                            | terminál má vlastné uzatvorenie mesiaca (`month_closures`); vypnúť sa dá až s integrovaným režimom, ktorý je len návrh | vlastní                     |
| Politika terminálu (kto schvaľuje, kto čo vidí, uzávierka) | vlastní                                                                                                                | neposiela                   |

**D1 (Access je pravda vo výpočte):** terminál sa má Accessu prispôsobiť, nie ho kopírovať po svojom. Kým výpočet v termináli nečíta konfiguráciu z Accessu, je jeho saldo len orientačné. Integrovaný režim (`prompts/04`, vypnutá uzávierka a popisky „orientačné“) je návrh, v kóde nie je.

## 4. Tok údajov a nasadenie

1. Zamestnanec razí v termináli (alebo v klientovi). Terminál zapíše razenie do fronty a odošle ho, keď je spojenie.
2. Správca exportuje razenia a zneplatnenia (Správa → Prevádzka). HR ich importuje do Accessu.
3. HR v Accesse nastaví fondy, pravidlá a prerušenia, vytvorí `dochs_config.json`, správca ho prijme v termináli.
4. Mesiac uzavrie HR v Accesse podpísanou zostavou.

Terminál sa dá presťahovať na iný server šifrovaným súborom (`docs/PRENOS-ORGANIZACIE.md`); zariadenia dostanú oznam o presťahovaní a neodoslané razenia sa dajú uložiť do súboru.

Vetvy a synchronizácia s Lovable: `main` je chránená a ide do nej všetko cez PR, Lovable píše do vetvy `lovable` (`docs/LOVABLE-VETVY.md`).

## 5. Nastavenia výpočtu: kto ich vlastní

Táto kapitola je **návrh** a nadväzuje na zásadu, že výpočet riadia parametre (nie kód) a že Access je záväzný.

### 5.1 Stav dnes

Terminál má **dva nezávislé zdroje** nastavení výpočtu:

- **Správa, skrytá karta Servis**: pravidlá výpočtu pre celú organizáciu (`organization_settings`: zaokrúhlenie príchodu a odchodu, dĺžka a hranica obeda, predvolený denný fond, najväčšia odchýlka času), číselník prerušení (`organization_codes`, pevných 7 kódov, upraviť sa dá len názov a SAP kód), sviatky (`organization_holidays`) a denný fond na zamestnanca (`profiles.daily_fund`). Príznaky prerušení, šablóny ani plán po mesiacoch tam nie sú, pravidlá sú rovnaké pre všetkých zamestnancov a časť správania (ktoré kódy sa dopočítajú do fondu) je pevná v kóde. Karta je skrytá, lebo tieto hodnoty majú prísť z Accessu.
- **Konfigurácia z Accessu**: prijíma sa do samostatného úložiska (pravidlá, prerušenia s `calc` a príznakmi, fondy, šablóny, režimy a plán po zamestnancoch a mesiacoch). Zatiaľ ju používajú len tlačidlá a náhľad v Správe. Žiadny výpočet ju nečíta.

Výpočet (`engine.ts`) číta len prvý zdroj. Keby sa teraz písal „výpočet podľa plánu z Accessu“ popri ňom, mal by dve cesty a pre každú organizáciu by záviselo, ktorá platí.

### 5.2 Princíp: jeden model, jeden vlastník

1. **Jeden model nastavení výpočtu** v termináli, rovnaký tvar ako kontrakt 1.5.0: pravidlá (`rules`), prerušenia s vlastnosťami (`calc`, hranica celého dňa, príznaky, tlačidlá), režimy, fondy so šablónami a kalendárom, sviatky a plán zamestnanca po mesiacoch (typ dňa, denný fond, okno práce, režim).
2. **Výpočet číta len tento model.** Nemá „režim Access“ a „režim terminál“. Odkiaľ model pochádza, na výpočet nemá vplyv.
3. **Každá organizácia má v jednom okamihu jedného vlastníka modelu**: `access` alebo `terminal`. Nová organizácia je `terminal`.

| Vlastník   | Kto model plní                       | Správa (nastavenia výpočtu)                                                                               |
| ---------- | ------------------------------------ | --------------------------------------------------------------------------------------------------------- |
| `access`   | import `dochs_config.json` z Accessu | všetko, čo ovplyvňuje výpočet, je len na čítanie; údaj „verzia a dátum importu“; zmena len novým importom |
| `terminal` | správca v Správe (editory)           | upraviteľné; Access sa nepoužíva alebo má vlastné nastavenia a výsledky sa môžu líšiť                     |

Bez čiastočných výnimiek: ak by sa pri vlastníkovi `access` dalo zmeniť jedno pravidlo v termináli, terminál a Access by počítali rôzne a saldo by sa nedalo overiť.

### 5.3 Čo zamykanie pokrýva

- **Zamknuté pri `access`**: pravidlá výpočtu, prerušenia a ich vlastnosti, tlačidlá, fondy, šablóny, kalendár, sviatky, režimy, plán zamestnancov.
- **Vždy upraviteľné v termináli** (Access to neposiela): politika terminálu (kto schvaľuje, viditeľnosť salda a prítomnosti, uzávierka), zamestnanci, roly, vedúci, PIN-y, zariadenia, odhlásenie pri nečinnosti.

### 5.4 Spárovanie a odpárovanie (návrh)

- **Spárovanie**: prvý prijatý import z Accessu prepne vlastníka na `access`. Náhľad pred prijatím to výslovne povie a vyžiada potvrdenie.
- **Odpárovanie**: samostatné tlačidlo len pre správcu, s potvrdením a záznamom do auditu. Posledná importovaná konfigurácia ostane východiskom a dá sa upravovať. Ďalší import sa potom prijme len po potvrdení, že prepíše úpravy v termináli, a vráti vlastníka na `access`.
- **Odpárovanie nie je prepínač pre každodenné použitie.** Kto Access ďalej používa na záväzný výpočet, nemá odpárovať: nastavenia terminálu a Accessu by sa rozišli.

### 5.5 Čo z toho vyplýva pre výpočet

- Ostáva čistou funkciou bez I/O v `src/lib/engine.ts` (pravidlo z `AGENTS.md`). Vstup: razenia dňa, plán dňa (typ dňa, denný fond, okno práce, režim), platné pravidlá dňa (po uplatnení režimu) a vlastnosti prerušení. Deň bez plánu vráti stav „bez plánu, nepotvrdené“, nie potichu odhad.
- Plán zamestnanca sa v zariadení **nekešuje** (`AGENTS.md`): výpočet s plánom potrebuje spojenie so serverom.
- Overenie: zlatý scenár `contract/scenare/2026-10` a porovnanie sald s Accessom (`docs/TESTOVANIE-S-ACCESSOM.md`). Rozdiely, ktoré ostanú, sa vypíšu s dôvodom.
- Pre vlastníka `terminal` musí plán dňa vyrobiť terminál sám (fond, deň v týždni, kalendár, sviatky, úväzok). Referenčný výpočet plánu je v `contract/tools/build_config_example.py` a v Accesse v `mod_08.NacitajKontextMesiaca`.

### 5.6 Otvorené

1. Má import z Accessu spárovať automaticky (s potvrdením v náhľade), alebo samostatným krokom?
2. Mesiace pred odpárovaním: plán z Accessu ostáva ako história; nové mesiace bez plánu ukážu „nepotvrdené“, kým ich terminál nevytvorí.
3. Čo sa stane s dnešnými hodnotami v `organization_settings`: pri vlastníkovi `terminal` sa prevezmú do modelu, pri `access` sa nepoužijú.
4. Rozsah editorov v termináli (prerušenia s príznakmi, šablóny, pravidlá, plán) a ich poradie: vlastník `terminal` je potrebný len pre organizácie bez Accessu.
5. Uzávierka mesiaca v termináli (`month_closures`) pri vlastníkovi `access`: podľa integrovaného režimu sa vypne.

## 6. Bezpečnostné zásady

- Pseudonymizácia: osobné číslo SAP, nikde mená ani e-maily; do repozitára nepatria skutočné osoby, produkčné exporty ani kľúče (`docs/SPOLUPRACA.md`, CI krok „no-secrets“).
- Razenia sa nemažú; oprava je nové razenie s auditom. Vzorec hash reťaze sa nemení.
- Oprávnenia rozhoduje databáza (RLS a funkcie), nie aplikácia.
- Zmena kontraktu a hash reťaze len s výslovným pokynom vlastníka (`AGENTS.md`).

## 7. Čo je overené a čo nie

- **Overené:** testy aplikácie (vitest) a CI na `main`; migrácie 0016 až 0021 v sandboxe PostgreSQL 16 nad lokálnou schémou aplikácie; ručné skúšky prenosu organizácie medzi Lovable a lokálnym Supabase.
- **Neoverené v prevádzke:** VBA v skutočnom Accesse (kontrola je len statická a skúšobné postupy v `access/CHANGELOG.md`), klient v Accesse, výpočet terminálu podľa plánu (nie je napísaný), správanie na ostrej databáze Lovable Cloud pri veľkých súboroch, obrazovky v prehliadači okrem ručne vyskúšaných scenárov.
- Tvrdenia o stave databázy terminálu vychádzajú z kódu, dokumentov a lokálnej databázy; na Lovable Cloud ich treba overiť SQL kontrolou.

## 8. Poradie prác

1. **Tento dokument** a rozhodnutie o vlastníkovi nastavení (kapitola 5).
2. **Model a výpočet (etapa 2)**: úložisko modelu s vlastníkom, výpočet podľa modelu, zobrazenie platných nastavení v Správe na čítanie (nahrádza dnešné „Pravidlá výpočtu“ pri vlastníkovi `access`). Hodnoty pravidiel určí smernica; mechanizmus od nich nezávisí.
3. **Editory v termináli** (prerušenia s príznakmi, šablóny, pravidlá, plán zamestnancov) a odpárovanie, až keď terminál má používateľa bez Accessu.
4. **Access**: klient na počítači zamestnanca, okno na nastavenie režimov výpočtu, okno práce podľa fondu a organizačnej jednotky, upozornenie na razenie mimo okna, zostávajúce body z `access/CHANGELOG.md`.

## 9. Rozhodnutia

| Dátum        | Rozhodnutie                                                                                                                                                              |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 3. 11. 2026  | Terminál je zberač razení, Access záväzný systém záznamov a výpočtu (zásada v `docs/SPOLUPRACA.md`, v `docs/KONFIGURACIA-Z-ACCESSU.md` ako D1); rozhranie je `contract/` |
| 4. 11. 2026  | Tlačidlá terminálu sa riadia konfiguráciou z Accessu (kontrakt 1.3.0)                                                                                                    |
| 5. 11. 2026  | Výpočet riadia parametre, ktoré nastavuje správca; kontrakt 1.4.0 a 1.5.0                                                                                                |
| 11. 11. 2026 | Základom náhrady je Access, terminál je voliteľný; výpočtový motor po vyplnení dotazníkov                                                                                |
| 12. 11. 2026 | Dve nezávislé inštancie Accessu, nastavenia sa neprenášajú; klient na razenie v Accesse                                                                                  |
| 13. 11. 2026 | Vetvy `main` (chránená) a `lovable` (pripojená k Lovable), synchronizácia PR-kami                                                                                        |
| 13. 11. 2026 | **Návrh:** jeden model nastavení výpočtu a jeden vlastník (`access` alebo `terminal`), odpárovanie tlačidlom                                                             |
