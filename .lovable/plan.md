# Revízia: Podnikový Dochádzkový Systém v1.0 → návrh v1.1

## Výsledok
Vylepšená dokumentácia **v1.1 (PDF, slovensky)** s opravenými skriptmi, doplneným dátovým modelom, bezpečnostnými úpravami a podrobnými krokmi implementácie. Uložím ju do Files spolu so samostatnými súbormi `.ps1`.

## 1. Zistené chyby (treba opraviť)

**Skripty**
- `$$$$dbPath` – preklep, skript nespustí. `($Get-Date)` musí byť `$(Get-Date)`.
- Kľúč `ZAOKRUHLENE_PRICHOD` v skripte ≠ `ZAOKRUHLENIE_PRICHOD` v tabuľke pravidiel – engine hodnotu nenájde.
- Skript nevkladá `ZAOKRUHLENIE_ODCHOD`, `PRUZNA_ZAKLAD_START/KONIEC`, `SETTINGS_VERZIA`.
- `DEFAULT` cez `CurrentDb.Execute` (DAO) Access nepodporuje – treba ADO (`CurrentProject.Connection.Execute`) alebo nastaviť `DefaultValue` cez TableDef. `TEXT` → `LONGTEXT`.
- `zamestnanc_id` – preklep, chýba cudzí kľúč a indexy (zamestnanec + čas).
- Chýba tabuľka `ciselnik_preruseni`, na ktorú sa odvoláva Master Prompt 3.

**Logika a legislatíva**
- Zaokrúhľovanie v neprospech zamestnanca (príchod nahor, odchod nadol) je podľa Zákonníka práce (§ 99 evidencia) rizikové. Vždy ukladať presný čas, zaokrúhľovať iba vo výpočte a nechať to schváliť HR/právnikom.
- Lekár (§ 141): 7 dní/rok, sprevádzanie rodinného príslušníka: 10 dní/rok – treba evidovať zostatky nárokov.
- Chýbajú: štátne sviatky, úväzok a fond pre každého zamestnanca, nočné zmeny cez polnoc, saldo pružného času, zostatok dovolenky.

## 2. Bezpečnostné a architektonické riziká

- **SHA-256 „reťaz“ nie je reťaz:** chýba `prev_hash`. Aj s ním si môže používateľ s prístupom k súboru prepočítať celú reťaz. Riešenie: `prev_hash` + overovanie (ukotvenie) hashov na centrále pri synchronizácii, centrálna tabuľka iba na pridávanie záznamov. Treba pravdivo uvádzať „odhalenie úprav“, nie „nemožnosť úprav“.
- **Offline a hodiny PC:** offline záznam berie čas z lokálnych hodín, ktoré sa dajú zmeniť. Treba ukladať `cas_lokalny` aj `cas_server` (pri synchronizácii), sledovať rozdiel a označovať podozrivé záznamy.
- **Identita:** pri `WScript.Network` uviesť, že `%USERNAME%` sa dá podvrhnúť. Ako primárny zdroj použiť `ADSystemInfo.UserName` (DN).
- **SHA-256 vo VBA:** nespoliehať sa na .NET 3.5 (`SHA256Managed`). Použiť Windows CNG (`bcrypt.dll` cez `Declare PtrSafe`).
- **Uzamknutie:** samotná prípona `.accdr` nič nechráni. Treba skompilovať do `.accde`, nastaviť `AllowBypassKey=False` a oprávnenia NTFS na zdieľanom priečinku.
- **EDR/SentinelOne:** VBA, ktoré spúšťa PowerShell/WScript, môže spustiť poplach. Treba podpísať VBA projekt, nastaviť Trusted Location cez GPO a dohodnúť to vopred so SOC.
- **Access na sieti:** sieťový súbor sa poškodí pri Wi-Fi/VPN. Treba rozdeliť aplikáciu na front-end (lokálne) a back-end (sieť), synchronizovať v dávkach, zálohovať každý deň a pripraviť automatickú aktualizáciu front-endu.
- **Migrácia na SQL Server „bez úpravy VBA“** je prehnaný sľub: `dbSeeChanges`, autonumber, typy dátumov. Odhadnúť realisticky.
- **HW snímač cez PEStudio** (spätné inžinierstvo) prináša licenčné riziko. Uprednostniť SDK alebo protokol od výrobcu.
- **GDPR:** treba DPIA, informovanie zamestnancov a dobu uchovávania. Mzdové podklady sa uchovávajú 10 rokov centrálne, lokálne 2-ročné okno je v poriadku.

## 3. Doplnený dátový model
`zamestnanci` (+ uväzok, fond, manager_id, zastupca_id, platne_od/do), `nastavenia_systemu`, `ciselnik_preruseni`, `dochadzka_raw` (+ prev_hash, cas_lokalny, cas_server, zdroj, zariadenie), `dochadzka_den` (vypočítané), `korekcie` (dôvod, schválil), `naroky` (dovolenka, lekár, KZ voľno), `sviatky`, `uzavierky` (mesiac, stav, schválil), `audit_log`.

## 4. Kroky implementácie (s odhadom)
```text
F0  Príprava (1 týž.)    AD diagnostika, HR dotazník, DPIA, schválenie SOC/IT
F1  Dáta (1 týž.)        opravený skript, split FE/BE, test data
F2  Jadro (2-3 týž.)     SSO/LDAP, Crypto (CNG), Engine + unit testy výpočtov
F3  GUI (2 týž.)         Wizard, Terminál, Korekcie, Môj tím, Uzávierka
F4  Export (1 týž.)      SAP xlsx, A4 výkaz, kontrolné súčty
F5  Pilot (2-4 týž.)     1 stredisko, súbežne so starým systémom, porovnanie
F6  Nasadenie            .accde, GPO, podpis, zálohy, školenie, runbook
F7  Rozšírenia           SQL Server, snímač, archivácia
```
Každá fáza bude mať kritériá prijatia, napr. „výpočet sa zhoduje so starým systémom na 100 % testovacích dní“.

## 5. Obsah PDF v1.1
1. Zhrnutie zmien oproti v1.0
2. Architektúra (diagram FE/BE/centrála)
3. Opravené `diagnostika_ad.ps1` a `vytvor_databazu.ps1` (ADO, všetky tabuľky, indexy a parametre)
4. Rozšírený číselník a pravidlá
5. Bezpečnosť a GDPR
6. Upresnené Master Prompty 1–3 a nový prompt pre testy
7. Plán implementácie, riziká a testovací scenár

## Technické detaily
- PDF vytvorím cez reportlab s fontom DejaVu (diakritika) a vizuálne skontrolujem každú stranu.
- Skripty `.ps1` dodám aj samostatne (UTF-8 s BOM, aby PowerShell 5.1 správne zobrazil diakritiku). Overím ich aspoň syntakticky, Access v prostredí nie je dostupný.
- Voliteľne: ak namiesto Accessu chcete webovú aplikáciu (bez rizík zdieľaného súboru), viem pripraviť samostatný plán.
