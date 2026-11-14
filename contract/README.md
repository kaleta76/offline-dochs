# Kontrakt terminál ⇄ Access (verzia 1, doplnky 1.1 až 1.6)

Tento priečinok je **jediné miesto, na ktorom sa dohodne rozhranie** medzi terminálom (tento repozitár, vyvíja ho Lovable agent)
a lokálnym dochádzkovým systémom v Accesse (vyvíja ho Claude). Zmena súborov tu = zmena dohody, preto ide **iba cez pull request**
a schvaľuje ju vlastník repozitára (pozri `.github/CODEOWNERS`).

## Zásady
1. Terminál posiela len **fakty** (kto, aký kód, smer, kedy, z akého zariadenia). Nepočíta mzdové ani fondové výsledky pre Access.
2. Osobné údaje (mená) nikdy neopúšťajú Access. Terminál pozná len **osobné číslo SAP** (pseudonym).
3. Prenos je **idempotentný**: ten istý záznam môže prísť viackrát, Access ho nespracuje dvakrát (`external_id`).
4. Prenos je **overiteľný**: súbor má pätičku so SHA-256 a každý záznam nesie hash reťaz (`prev_hash` → `record_hash`).
5. Zmena kontraktu = nová hlavná verzia (`contract_version`), stará verzia sa podporuje aspoň do ďalšieho mesačného uzatvorenia.

## Súbor `punches_YYYYMM.csv` (alebo `punches_YYYYMMDD_HHMM.csv` pre prírastok)
* UTF-8 s BOM, oddeľovač `;`, texty v `"..."`, čísla bez úvodzoviek, riadky končia `CRLF`.
* Prvý riadok = hlavička, posledný riadok = pätička `#END;rows=<počet>;sha256=<hex>`.
  SHA-256 sa počíta zo **všetkých bajtov od hlavičky po posledné `CRLF` pred pätičkou** (bez BOM).
* Riadky sú zoradené podľa `punch_id` vzostupne.

| stĺpec | typ | význam |
|---|---|---|
| `contract_version` | číslo | vždy `1` |
| `organization_id` | uuid | organizácia v terminále (Access má jednu a overuje ju pri prvom importe) |
| `punch_id` | číslo | `punches.id` – rastúce, slúži ako kurzor prírastkového importu |
| `external_id` | uuid | `punches.client_uuid` – kľúč na deduplikáciu (Access ho ukladá do `DochadzkaImport.ExterneID`) |
| `personnel_number` | text | osobné číslo SAP, **text** (môže mať vedúce nuly, Access porovnáva po odstránení nulí) |
| `code` | text | `WORK`, `TRIP`, `DOCTOR`, `FAMILY`, `LEAVE`, `SICK`, `PRIV` (rozšíriteľné, pozri `code-mapping.csv`) |
| `direction` | text | `IN` / `OUT` |
| `client_time_local` | text | čas na zariadení v `Europe/Bratislava`, `RRRR-MM-DD HH:MM:SS` |
| `client_time_utc` | text | rovnaký okamih v UTC, `RRRR-MM-DDTHH:MM:SSZ` (**záväzný**, lokálny je len na čítanie) |
| `server_time_utc` | text | kedy záznam prijal server |
| `drift_minutes` | číslo | `server_time − client_time` v minútach (veľké číslo = záznam prišiel neskoro/offline) |
| `source` | text | `terminal` (razil zamestnanec) / `correction` (schválená oprava vedúcim) |
| `device_verification` | text | `verified` / `unverified` / `confirmed` (neoverené potvrdil vedúci) |
| `device_id` | uuid alebo prázdne | zariadenie, z ktorého prišlo razenie (prázdne pri korekcii) |
| `user_uuid` | uuid | interný pseudonymný účet (len pre kontrolu reťaze) |
| `prev_hash`, `record_hash` | hex | hash reťaz po používateľovi (vzorec nižšie) |

### Hash reťaz
`record_hash = SHA-256( prev_hash | user_uuid | code | direction | client_time_utc(do sekundy, bez Z) | server_time_utc(do sekundy, bez Z) | external_id [| device_id] )`,
`prev_hash` úplne prvého záznamu používateľa je `GENESIS`. Reťaz ide podľa `punch_id`, ale súbor sa filtruje podľa času razenia, preto mesačný a prírastkový súbor obsahuje len jej časť: prvý záznam používateľa v súbore má `prev_hash` staršieho záznamu, ktorý v súbore nie je (nie je to chyba). Vzorec je presná kópia databázového triggera `punches_chain`
(`drizzle/migrations/0003_device_verification.sql`) a bol overený proti PostgreSQL 16. Overenie: `tools/verify_export.py`.

## Pravidlá, ktoré musí dodržať Access pri importe (zhrnutie, detail v dokumente `docs/SPOLUPRACA.md`)
* **Mapovanie kódov je kontextové.** `X/OUT` (okrem `WORK`) = *začiatok* prerušenia X, nasledujúce `WORK/IN` = *koniec* prerušenia X;
  prvé `WORK/IN` dňa = príchod, posledné `WORK/OUT` = odchod. Tabuľka je v `code-mapping.csv` a vlastní ju Access.
* **Mesiac uzavretý v Accesse:** razenie sa nezahodí, ostane v `TerminalInbox` so stavom `UZAVRETY` a spracuje sa po otvorení mesiaca.
* **Neoverené razenia** (`unverified`) sa importujú, ale Access ich označí na kontrolu; oprava/potvrdenie ide cez vedúceho v terminále.
* **Prírastok:** Access si pamätá posledné `punch_id` a pri ďalšom importe žiada `punch_id > posledné − 500` (prekrytie); duplicity vyradí `external_id`.

## Súbor `voids_YYYYMM.csv` (kontrakt 1.1, doplnok – formát `punches_*.csv` sa NEMENÍ)
Zamestnanec môže požiadať o zneplatnenie razenia (napr. duplicitné razenie), vedúci alebo správca žiadosť schváli. Razenie sa v databáze **nemaže** a jeho
hash reťaz sa nemení (`voided_at` nie je súčasťou `record_hash`). Preto zneplatnené razenie ostáva aj v `punches_*.csv` a Access ho dostane
v **samostatnom zozname** za rovnaký mesiac (podľa času zneplatneného razenia, nie podľa času schválenia).
* Formát súboru je rovnaký ako pri razeniach: UTF-8 s BOM, `;`, `CRLF`, hlavička, riadky podľa `punch_id`, pätička `#END;rows=N;sha256=...` (SHA-256 tela bez BOM).
* Dôvod zneplatnenia sa **neexportuje** (voľný text môže obsahovať osobné údaje); ostáva v terminále v audite.

| stĺpec | typ | význam |
|---|---|---|
| `contract_version` | číslo | vždy `1` (zmena 1.1 je spätne kompatibilná, nový je len tento súbor) |
| `organization_id` | uuid | rovnaká organizácia ako v `punches_*.csv` |
| `punch_id` | číslo | `punches.id` zneplatneného razenia |
| `external_id` | uuid | `punches.client_uuid` – podľa neho Access nájde riadok v `DochadzkaImport.ExterneID` |
| `personnel_number` | text | osobné číslo SAP |
| `user_uuid` | uuid | pseudonymný účet |
| `voided_at_utc` | text | kedy bolo zneplatnenie schválené, `RRRR-MM-DDTHH:MM:SSZ` |
| `record_hash` | hex | hash zneplatneného razenia (Access ním overí, že ide o to isté razenie, ktoré importoval) |

### Pravidlá pre Access
* **Idempotencia:** zoznam sa môže importovať opakovane; už zneplatnené razenie sa preskočí.
* **Poradie:** najprv `punches_*.csv`, potom `voids_*.csv` za ten istý mesiac. Ak `external_id` v Accesse ešte nie je, riadok sa nezahodí, ostane v čakaní a použije sa po importe razenia.
* **Zneplatnenie = `Platnost = False`, `DovodNeplatnosti = 'ZNEPLATNENE_V_TERMINALI'`;** riadok sa nemaže, deň a sald sa prepočítajú.
* **Nezhoda `record_hash`** (razenie s rovnakým `external_id` má iný hash) = chyba, nezneplatňuje sa, zapíše sa do protokolu.
* **Uzavretý mesiac v Accesse:** zneplatnenie sa neaplikuje, ostáva v čakaní do otvorenia mesiaca (rovnako ako razenia).
* Zlatý súbor: `examples/voids_example.csv`, test `tests/void-export.contract.test.ts`, referencia `reference/void-export.ts`.

## Súbor `dochs_config.json` (kontrakt 1.2.0 až 1.5.0, smer Access → terminál)
Access posiela terminálu **hotový výpočtový plán**, aby terminál počítal saldo rovnako ako Access a zamestnanec si ho mohol skontrolovať skôr, než sekretárka mesiac
opraví, vytlačí a uzavrie. Zásada je „Access rozhoduje, terminál preberá“: terminál nepozná pravidlá fondov, kalendárov ani úväzkov, dostane z nich už vypočítaný
denný fond. Formát je JSON (UTF-8), schéma `config-export.schema.json` (`schema_version` 2), zlatý súbor `examples/config_example.json`, overovač `tools/verify_config.py`.
Súbor je **nadmnožina** pôvodnej konfigurácie (`schema_version` 1); kľúče `rules`, `interruptions`, `punch_codes`, `holidays` ostávajú.

| časť | obsah |
|---|---|
| `config_version`, `generated_at` | poradie verzií (`rrrr.mm.dd.hhmm`); terminál drží najnovšiu a nikdy nevráti staršiu |
| `rules` | okno práce, hranica celodennej prekážky, automatický obed, predvolený denný fond, `interruption_check_enabled`; od 1.4.0 voliteľne pravidlá obeda, zaokrúhlenia, opráv a lehoty (nižšie) |
| `interruptions[]` | číselník prerušení; **`calc`** určuje, ako sa interval počíta (nižšie); od 1.3.0 voliteľne `terminal_button`, `terminal_label`, `terminal_order` (tlačidlá terminálu, nižšie); od 1.4.0 voliteľne `terminal_icon`, `terminal_request`, `needs_approval`, `full_day_only`; od 1.5.0 voliteľne `full_day_min`, `counts_to_lunch_base` |
| `regimes[]` | od 1.5.0 voliteľne **režimy výpočtu** (napr. krízová situácia): pomenovaná sada prepísaných pravidiel a vlastností prerušení (nižšie) |
| `punch_codes[]` | kódy razení Accessu (číslo, prerušenie, smer Z/K) |
| `terminal_code_map[]` | kódy razení terminála (`WORK`, `DOCTOR`, …) → číslo prerušenia v Accesse |
| `holidays[]` | sviatky roka a nasledujúceho roka |
| `period` | mesiace okna, pre ktoré je plán (zvyčajne predchádzajúci až nasledujúci mesiac) |
| `funds[]` | názov a typ použitých fondov (informatívne) |
| `templates[].months[].rules[]` | pravidlá prerušení po mesiacoch: povolený čas, najdlhšie a najkratšie trvanie, minimum odpracovaného času (sedem hodnôt pondelok až nedeľa) |
| `employees[].months[]` | **plán**: `employment_pct`, `fund_id`, `template_id`, `calendar_id`, `day_types[]` a `expected_min[]` pre každý deň mesiaca; od 1.4.0 voliteľne okno práce `window_start_min` a `window_end_min`; od 1.5.0 voliteľne `regime_ids` (režim výpočtu pre každý deň mesiaca) |
| `counts` | počet zamestnancov a mesačných plánov v súbore (kontrola úplnosti) |

**Tlačidlá terminálu (kontrakt 1.3.0, voliteľné kľúče prerušenia).** O tom, ktoré prerušenia majú na obrazovke Terminál vlastné tlačidlo, rozhoduje Access (rozhodnutie vlastníka 4. 11. 2026):

| kľúč | význam |
|---|---|
| `terminal_button` | `true` = prerušenie má tlačidlo. Access kľúč vynechá, ak príznak nie je nastavený (súbor bez tlačidiel je ten istý ako v 1.2.0). Neplatí pre č. 1 (práca): tá má Príchod a Odchod. Č. 7 (obed) tlačidlo mať smie: odchod s kódom `LUNCH`, návrat je Príchod. |
| `terminal_label` | text tlačidla, 1 až 24 znakov: celý názov alebo skratka, ako ju zvolí Access. Bez neho sa použije `name`. Len spolu s `terminal_button = true`. |
| `terminal_order` | poradie tlačidla (1 až 99, od najmenšieho; pri rovnakom čísle rozhoduje číslo prerušenia). Len spolu s `terminal_button = true`. |

Pravidlá: prerušenie s tlačidlom má v `terminal_code_map` **práve jeden** kód terminála (ten kód tlačidlo zapíše ako odchod `OUT`; návrat je vždy Príchod); text tlačidla je v súbore jedinečný (bez ohľadu na veľkosť písmen);
tlačidiel je najviac 12. Overovač a kontrola v termináli tieto pravidlá odmietnu.
Správanie terminálu: Príchod a Odchod sú vždy, ďalej tlačidlá z konfigurácie podľa `terminal_order`. Ak v prijatej konfigurácii nie je žiadne tlačidlo (alebo konfigurácia nebola prijatá),
terminál ukáže predvolené tlačidlá zabudované v aplikácii: Lekár, Sprievod, Služobná cesta, Služobné vzdialenie, Súkromne.
Prerušenia, ktoré sa dávajú na celý deň (dovolenka, PN, ošetrovanie a pod.), tlačidlo mať nemusia; zadávajú sa žiadosťou o opravu, ktorú schváli vedúci, alebo priamo v Accesse.
**Nasadenie:** súbor s novými kľúčmi prijme len verzia terminálu a databázy, ktorá ich pozná. Access ich preto vloží, len keď má aspoň jedno prerušenie nastavené (predvolene žiadne).

### Voliteľné kľúče kontraktu 1.4.0: nastavenia z Accessu bez zásahu do kódu

Cieľ (rozhodnutie vlastníka 5. 11. 2026): väčšinu volieb z dotazníka pre vedenie nastaví správca v Accesse a terminál ich len preberie, bez novej verzie programu.
Všetky kľúče nižšie sú **voliteľné**. Chýbajúci kľúč znamená predvolenú hodnotu, ktorá je dnešné správanie, takže súbor 1.3.0 ostáva platný a nezmenený.
Access kľúč vloží, len keď ho správca nastavil. Hodnoty v `rules` sú ako doteraz len čísla a `true`/`false`; výber z možností má číselný kód.
Terminál nové kľúče zatiaľ len **prijme a overí**. Ako ich použije výpočet (`src/lib/engine.ts`) a tlačidlá, je samostatná zmena podľa Accessu; do tej doby platí správanie terminálu ako doteraz.

**`rules`**

| kľúč | hodnoty | predvolené | význam |
|---|---|---|---|
| `lunch_recorded_mode` | 0, 1, 2 | 0 | obed, ktorý zamestnanec odrazil (č. 7 alebo odchod bez dôvodu, ak je `unlabeled_out_is_lunch`): 0 skutočný čas, 1 najmenej `lunch_min_min`, 2 vždy presne `lunch_min_min`; 1 a 2 sa uplatnia len v dni, kde odpracovaný čas spolu s obedom dosiahne `auto_lunch_trigger_min` (kratšia zmena na prestávku nárok nemá a obed sa počíta skutočným časom) |
| `lunch_min_min` | 0 až 600 | 30 | minúty obeda pre režim 1 a 2; bez režimu 1 alebo 2 sa nepoužije (overovač upozorní) |
| `unlabeled_out_is_lunch` | true/false | true | `true`: Odchod bez dôvodu a neskorší Príchod v ten istý deň je obed; `false`: je to odchod a nový príchod (Access: `TerminalOdchodBezDovodu`) |
| `rounding_in_min` | 0 až 60 | 0 | prvý príchod dňa sa zaokrúhli na násobok týchto minút; 0 nezaokrúhľuje |
| `rounding_out_min` | 0 až 60 | 0 | posledný odchod dňa sa zaokrúhli na násobok týchto minút; 0 nezaokrúhľuje |
| `rounding_mode` | 0 až 3 | 0 | smer: 0 príchod nahor a odchod nadol (ako dnes v termináli, v neprospech zamestnanca), 1 oba nahor, 2 oba nadol, 3 na najbližší násobok |
| `auto_repair_target` | 0, 1 | 0 | kam sa dopĺňa zabudnuté razenie: 0 tak, aby sa deň vyrovnal na denný fond, 1 do konca okna práce (platí, keď `auto_repair_mode` > 0) |
| `auto_repair_cases` | 1 až 3 | 3 | prípady opráv, súčet bitov: 1 zabudnutý odchod z práce, 2 zabudnutý návrat z prerušenia, 3 oba |
| `correction_deadline_day` | 0 až 31 | 0 | do ktorého dňa nasledujúceho mesiaca sa smie žiadať o opravu; 0 bez lehoty |
| `early_return_ends_interruption` | true/false | true | `true`: Príchod pred plánovaným koncom prerušenia ho skončí a zvyšok dňa je práca; `false`: deň ostane celý ako prerušenie (dotazník 4.5) |

Neznámy kľúč v `rules` overovač nehlási ako chybu (Access môže časom pridať ďalšie), ale ako upozornenie: zachytí preklep, napr. `rounding_in_mn`. V prísnom režime (`--strict`) je to chyba.

**`interruptions[]`**

| kľúč | hodnoty | význam |
|---|---|---|
| `calc` = `UNPAID` | nová hodnota | interval sa nezapočíta ani do práce, ani do fondu dňa (napr. nepočítaný súkromný odchod). Platí pre iné prerušenie než č. 1 a č. 7. Starší terminál hodnotu nepozná a podľa pravidla pri `calc` nižšie saldo neráta, ale upozorní správcu |
| `terminal_icon` | názov ikony | ikona tlačidla zo zatvoreného zoznamu: `doctor`, `family`, `trip`, `errand`, `private`, `lunch`, `home`, `other`; názov z malých písmen, číslic a `_` (najviac 20 znakov). Neznámy názov terminál nahradí všeobecnou ikonou a overovač upozorní. Len spolu s `terminal_button = true` |
| `terminal_request` | true/false | zamestnanec smie o prerušenie požiadať v termináli aj vopred (napr. plánovaná služobná cesta). Nie pre č. 1 |
| `needs_approval` | true/false | razenie s týmto dôvodom sa prijme, ale deň je nepotvrdený, kým ho vedúci neschváli. Nie pre č. 1 |
| `full_day_only` | true/false | prerušenie sa zadáva len na celý deň (dovolenka, PN), nie ako odchod a návrat; preto nemá tlačidlo (`terminal_button = true` s ním ide proti sebe). Nie pre č. 1 |

**`employees[].months[]`: okno práce podľa fondu**

| kľúč | hodnoty | význam |
|---|---|---|
| `window_start_min`, `window_end_min` | 0 až 1440, koniec po začiatku, vždy spolu | okno práce zamestnanca v tomto mesiaci namiesto `rules.work_window_start_min` a `rules.work_window_end_min`. Access ich vloží, keď platná verzia jeho fondu okno určuje; inak chýbajú a platí okno z `rules`. Okno 0 až 1440 znamená „okno sa nepoužíva“ |

Referenčný výpočet: `tools/build_config_example.py` (fond s `window` vo verzii platnej pre mesiac). Zlatý súbor `examples/config_example.json` používa všetky nové kľúče (vymyslené hodnoty),
súbor bez nich ostáva platný (test `test_subor_bez_novych_klucov_je_stale_platny` v oboch jazykoch).

**Nasadenie 1.4.0:** rovnako ako pri 1.3.0 súbor s novými kľúčmi prijme len verzia terminálu a databázy, ktorá ich pozná (`prerušenia` a `mesiac` v pláne majú zakázané neznáme kľúče, preto starší terminál súbor odmietne celý).
Databázová kontrola je súkromný SQL balík mimo repozitára; pred prvým súborom s novými kľúčmi ju treba rozšíriť rovnako (`calc` = `UNPAID`, kľúče prerušení, kľúče mesiaca, číselné hodnoty `rules`).
Access nové kľúče vloží, len keď ich správca nastaví.

### Voliteľné kľúče kontraktu 1.5.0: vlastnosti prerušení a režimy výpočtu

Cieľ (rozhodnutie vlastníka 5. 11. 2026): o tom, **ako sa ktoré prerušenie počíta**, nerozhoduje názov ani číslo prerušenia, ale parametre, ktoré nastavuje správca (HR) v tabuľkách Accessu;
my určujeme len počiatočné hodnoty. Zodpovednosť za nastavenie nesie správca. Terminál parametre z Accessu prevezme a počíta rovnako (zásada „Access rozhoduje, terminál preberá“).
Všetky kľúče nižšie sú **voliteľné**; chýbajúci kľúč = správanie 1.4.0, takže súbor 1.4.0 ostáva platný a nezmenený. Terminál ich zatiaľ len **prijme a overí**;
použitie vo výpočte (`src/lib/engine.ts`) je samostatná zmena (etapa 2) a overí sa proti výsledkom Accessu.
Č. 1 (`is_work`, `calc` `WORK`) a č. 7 (`is_lunch`, `calc` `LUNCH`) ostávajú pevné čísla; uvoľnenie čísel je mimo tejto verzie.

**`interruptions[]`** (len pre `calc` = `COUNTED`; zmysel majú až pri skutočnom počítaní, preto pre `WORK`, `LUNCH` a `UNPAID` ide o chybu, výnimkou je `counts_to_lunch_base = false`, ktoré je neškodné):

| kľúč | hodnoty | predvolené | význam |
|---|---|---|---|
| `full_day_min` | 1 až 1440 | `rules.full_day_obstacle_min` | od akej dĺžky jedného intervalu tohto prerušenia sa započíta celý denný fond dňa (`expected_min`) namiesto skutočného trvania (od tejto hodnoty vrátane, rovnako ako `full_day_obstacle_min`). Umožní napríklad, aby návšteva lekára od 5 hodín bola celý deň, ale iné prerušenie až od 6 hodín |
| `counts_to_lunch_base` | true/false | false | skutočné trvanie intervalov tohto prerušenia sa pripočíta k odpracovanému času pri posudzovaní, či zamestnanec dosiahol `auto_lunch_trigger_min` (nárok na prestávku). Odpočet obeda ide aj tak z odpracovaného času, nie z času prerušenia. Interval, ktorý sa započítava ako celý deň (dosiahol `full_day_min`), do základu nevstupuje |

Základ pre prah obeda je potom **odpracovaný čas + intervaly prerušení s `counts_to_lunch_base`**; platí rovnako pre automatický obed aj pre `lunch_recorded_mode` 1 a 2
(kde sa k základu pripočíta aj razený obed, ako dnes). Pri predvolených hodnotách je základ len odpracovaný čas, teda dnešné správanie Accessu.

**`regimes[]`: režim výpočtu na obdobie** (napr. krízová situácia vybraných zamestnancov). Režim je pomenovaná sada prepísaných hodnôt. Access ho priraďuje zamestnancovi na obdobie od–do
(zadáva ho správca, napr. sekretárka); terminál dostane pre každý deň len číslo režimu a nič nepočíta z dátumov. Zamestnanec zostáva len osobné číslo, názov režimu je bez osobných údajov.

| kľúč | význam |
|---|---|
| `id` | číslo režimu 1 až 99, v súbore jedinečné |
| `name` | názov 1 až 40 znakov bez medzier na kraji, jedinečný bez ohľadu na veľkosť písmen (napr. „Krízový režim“) |
| `rules` | voliteľné, prepísané hodnoty z `rules`; **uzavretý zoznam**: `work_window_start_min` a `work_window_end_min` (vždy spolu, koniec po začiatku; 0 až 1440 = okno sa nepoužíva), `full_day_obstacle_min`, `auto_lunch_enabled`, `auto_lunch_trigger_min`, `auto_lunch_deduct_min`, `lunch_recorded_mode`, `lunch_min_min`, `unlabeled_out_is_lunch`, `rounding_in_min`, `rounding_out_min`, `rounding_mode`, `auto_repair_mode`, `auto_repair_target`, `auto_repair_cases`. Rozsahy sú rovnaké ako v `rules`. Iný kľúč je chyba (nie upozornenie): terminál by ho potichu ignoroval a počítal by inak ako Access |
| `interruptions` | voliteľné, úpravy prerušení v dňoch režimu: `{ "code": …, "calc"?, "full_day_min"?, "counts_to_lunch_base"? }`; `calc` len `COUNTED` alebo `UNPAID`; č. 1 a č. 7 sa v režime nemenia (pravidlá obeda sú v `rules`); každá úprava mení aspoň jednu vlastnosť; `full_day_min` a `counts_to_lunch_base = true` platia len pre výsledné `calc` `COUNTED` |

Režim bez `rules` aj `interruptions` nič nemení (upozornenie). Režimov je najviac 20.

**`employees[].months[].regime_ids`**: pole s toľkými číslami, koľko má mesiac dní (rovnako ako `day_types`); číslo režimu z `regimes[].id`, `0` = bez režimu. Access kľúč **vynechá**,
ak v mesiaci žiadny deň režim nemá (pole samých núl je upozornenie). Obdobie režimu môže presahovať mesiac a Access ho rozpíše po dňoch; obdobia jedného zamestnanca sa neprekrývajú (zabezpečí Access).
Referenčné rozpísanie je v `tools/build_config_example.py` (vstup `regime_periods` zamestnanca: `{ "regime", "from", "to" }`, krajné dni vrátane).

**Poradie hodnôt pre jeden deň:** `rules` → okno práce zamestnanca v mesiaci (`window_*`, 1.4.0) → hodnoty režimu dňa (`regimes[].rules`; okno režimu prebije okno z fondu);
vlastnosti prerušení: `interruptions[]` → úpravy režimu dňa. Deň bez režimu sa počíta ako v 1.4.0.

**Zámerne nie je v 1.5.0** (bude samostatná verzia po rozhodnutí vlastníka): najdlhšie trvanie s prevodom prekročenia na iné prerušenie, zaokrúhlenie po prerušeniach, prerušenie cez polnoc,
priorita prerušenia pred sviatkom, predvoľba a plánovanie neprítomností, mesačný limit súkromných odchodov, kódy pre mzdy a pridelenie režimu podľa roly zamestnanca.

**Nasadenie 1.5.0:** rovnako ako pri 1.3.0 a 1.4.0 súbor s novými kľúčmi prijme len verzia terminálu a databázy, ktorá ich pozná (kľúč `regimes` najvyššej úrovne, kľúče prerušení a `regime_ids` v mesiaci
majú zakázané neznáme kľúče, preto starší terminál súbor odmietne celý). Databázová kontrola je súkromný SQL balík mimo repozitára; pred prvým súborom s novými kľúčmi ju treba rozšíriť
(`regimes` s uzavretým zoznamom kľúčov a rozsahmi vyššie, `full_day_min`, `counts_to_lunch_base`, `regime_ids` s dĺžkou podľa mesiaca). Access nové kľúče vloží, len keď ich správca nastaví.

**Typ dňa** (`day_types`) má dve písmená: kalendár (`P` pracovný, `V` voľný, `S` sviatok) a deň v týždni (`P` pondelok až piatok, `V` sobota, `N` nedeľa).
**Denný fond** (`expected_min`) je v minútach po zohľadnení fondu, fondu podľa dňa v týždni, pevného mesačného fondu (mesačný fond ÷ počet pracovných dní) a úväzku
(zaokrúhlenie polovice na párne, ako `CLng` vo VBA); `0` je nepracovný deň alebo sviatok. Algoritmus presne opisuje `tools/build_config_example.py`
(referenčná implementácia; z `examples/config_example.input.json` vytvorí zlatý súbor, test to stráži).

**Ako sa interval počíta do dňa (`interruptions[].calc`)** – tak, ako to robí Access 2.11 (`mod_08.TrvanieIntervalu`, `SumarDna`):
* `WORK`: práca (č. 1) sa oreže oknom práce (`work_window_start_min` až `work_window_end_min`);
* `LUNCH`: obed (č. 7) sa počíta skutočným trvaním; ak v dni obed je, automatický obed sa neodpočíta;
* `COUNTED`: každé iné prerušenie sa počíta skutočným trvaním; ak trvá `full_day_obstacle_min` (od 1.5.0 `full_day_min` prerušenia, ak je uvedené) a viac, započíta sa **denný fond dňa** (`expected_min`);
* `UNPAID` (od 1.4.0): interval sa nezapočíta ani do práce, ani do fondu dňa;
* po zostavení dňa sa od práce odpočíta automatický obed (`auto_lunch_deduct_min`), ak je zapnutý, deň má fond, odpracovaný čas (od 1.5.0 spolu s intervalmi prerušení s `counts_to_lunch_base`) dosiahne `auto_lunch_trigger_min` (od tejto hodnoty vrátane; pri 360 je to 6:00, 5:59 ešte nie) a nebol obed;
* denné saldo = odpracované + započítané prekážky − `expected_min`.
Neznámu hodnotu `calc` terminál nesmie nahradiť vlastným odhadom: saldo označí ako nepotvrdené a upozorní správcu (Access mohol zmeniť pravidlo a kontrakt dostane novú verziu).

**Pravidlá prerušení** (`templates`) Access používa len na upozornenia (nemenia výpočet). Hodnoty sú už rozpísané na sedem dní. Kontrola sa nevykoná, ak `disabled`; interval sa
kontroluje, len ak `allowed_to > allowed_from` a nejde o celý deň (0 až 1440); `max_duration_min` len ak je väčšie ako 0 a menšie ako 1440; kontrolujú sa iba skutočné
prerušenia kratšie ako `full_day_obstacle_min`.

**Súkromie**: zamestnanec je len `personnel_number` (číslo SAP z `TerminalMapaOsob`, inak osobné číslo). Meno, e-mail, oddelenie ani iný osobný údaj do súboru nepatrí;
overovač odmietne každý kľúč navyše.

**Prenos a pravidlá pre terminál** (podrobne `docs/KONFIGURACIA-Z-ACCESSU.md`):
* súbor sa overí (`verify_config.py` alebo rovnaká kontrola v termináli) a **prijme sa celý alebo vôbec**; pri chybe ostáva platná predchádzajúca konfigurácia;
* import smie spraviť len správca organizácie; zapíše sa do auditu (verzia, počty, kto);
* mesiac mimo `period` nemá plán: terminál saldo ukáže ako nepotvrdené (bez plánu z Accessu);
* po vyradení zamestnanca, zmene fondu alebo úväzku Access vydá novú verziu; terminál nepoužije nič staršie, než čo už prijal.

## Súbor `dochs_closures.json` (kontrakt 1.6.0, smer Access → terminál)
Mesiac zamestnanca sa v Accesse uzavrie podpísanou zostavou (`mod_18_Uzavierka`) a dá sa znova otvoriť s uvedením dôvodu. Tento súbor oznamuje terminálu, **ktoré mesiace Access uzavrel
alebo znova otvoril**, s konečnými číslami a so zoznamom razení, ktoré zarátal, aby terminál zosúladil mesiac s Accessom a našiel razenia, ktoré Access nezarátal.
Zásada je rovnaká ako pri konfigurácii: „Access rozhoduje, terminál preberá“. Formát je JSON (UTF-8), schéma `closures-export.schema.json` (`schema_version` 1),
zlatý súbor `examples/closures_example.json`, overovač `tools/verify_closures.py`. Je to **nový súbor**: žiadny existujúci súbor kontraktu (`punches_*.csv`, `voids_*.csv`, `dochs_config.json`) sa nemení.

| časť | obsah |
|---|---|
| `closures_version`, `generated_at` | označenie súboru (`rrrr.mm.dd.hhmm`) a miestny čas zostavenia; terminál ich zapíše do auditu |
| `organization_id` | organizácia v termináli, rovnaká ako v `punches_*.csv`; súbor inej organizácie terminál odmietne |
| `closures[]` | jeden záznam na zamestnanca a mesiac (aktuálny stav): `personnel_number`, `year`, `month`, `state`, `state_seq`, `changed_at` |
| `closures[].state` | `CLOSED` (mesiac je v Accesse uzavretý) alebo `REOPENED` (bol uzavretý a Access ho znova otvoril) |
| `closures[].state_seq` | počítadlo zmien stavu tohto mesiaca zamestnanca v Accesse: uzavretie = 1, otvorenie = 2, uzavretie = 3 … Preto `CLOSED` má nepárne a `REOPENED` párne číslo |
| `closures[].report_code` | voliteľne kontrolný kód zostavy z Accessu (pätička zostavy), aby sa dal vytlačený výkaz porovnať s terminálom |
| `closures[].totals` | len `CLOSED`: `worked_min`, `expected_min`, `balance_min` tak, ako ich Access uložil (súčty `OdpracovaneMin`, `DennyFondMin`, `SaldoMin` za mesiac); terminál ich nepočíta, len zobrazí |
| `closures[].counted_punches` | len `CLOSED`: `external_id` (`punches.client_uuid`) razení z terminálu, ktoré Access v tomto mesiaci zarátal (neplatné a zneplatnené nie sú v zozname) |
| `counts` | počet záznamov a súčet dĺžok `counted_punches` (kontrola úplnosti) |

**Poradie a idempotencia.** Terminál použije záznam, len ak je jeho `state_seq` **väčšie** než číslo, ktoré už má pre toho zamestnanca a mesiac. Rovnaký súbor sa dá preto prijať opakovane a starší súbor
nič nepokazí. Prijíma sa **celý alebo vôbec**; import smie spraviť len správca organizácie a zapíše sa do auditu (verzia súboru, počty, kto), rovnako ako pri konfigurácii.

**Razenia mimo uzávierky.** Razenie patrí do mesiaca podľa `client_time` v pásme `Europe/Bratislava` (polootvorený interval [začiatok mesiaca, začiatok nasledujúceho)), rovnako ako v `punches_YYYYMM.csv`.
Pri `CLOSED` vezme terminál platné (nezneplatnené) razenia zamestnanca z tohto mesiaca; tie, ktorých `client_uuid` nie je v `counted_punches`, sú **razenia mimo uzávierky**
(napríklad prišli do Accessu až po uzavretí a ostali v `TerminalInbox` so stavom `UZAVRETY`, alebo sa tam ešte nedostali). Terminál ich **nemaže ani nemení**: uloží ich do auditu a upozorní vedúceho zamestnanca.
Razenia, ktoré vznikli priamo v Accesse (editor, import z DBF), nemajú `external_id` z terminálu, v zozname nie sú a terminál ich nepozná; to nie je chyba.

**Razenie sa vždy prijme.** Uzávierka v Accesse nikdy nebráni terminálu prijať razenie. Razenie za uzavretý mesiac ostane v Accesse v `TerminalInbox` (pravidlo „Mesiac uzavretý v Accesse“ vyššie) a v termináli sa ukáže ako razenie mimo uzávierky.

**`REOPENED`.** Terminál zruší označenie „uzavretý Accessom“ aj konečné čísla mesiaca; mesiac sa zase počíta podľa platných nastavení. Zoznam razení mimo uzávierky sa zostaví nanovo pri ďalšom `CLOSED`.

**Čo súbor zámerne nenesie** (môže pribudnúť v ďalšej verzii po rozhodnutí vlastníka): čísla po dňoch, prenos salda do ďalšieho mesiaca, uznaný nadčas, dôvod otvorenia, kto mesiac uzavrel.
Dôvod a osoba ostávajú v Accesse (`DochadzkaUzavierkaLog`).

**Súkromie**: zamestnanec je len `personnel_number`. Meno, e-mail, oddelenie ani iný osobný údaj do súboru nepatrí; overovač odmietne každý kľúč navyše.

**Nasadenie 1.6.0.** Návrh je na schválenie vlastníkom (zmena `contract/`). Zavedenie je samostatná práca: terminál súbor prijme a zosúladí až po etape 5 (`docs/ARCHITEKTURA.md`, kapitola 5.7),
Access súbor vytvorí samostatným balíkom. Kým to neexistuje, platí dnešné správanie. Databázová časť (úložisko stavu uzávierok a auditu) je súkromný SQL balík mimo repozitára a treba ju spustiť pred prvým súborom.
