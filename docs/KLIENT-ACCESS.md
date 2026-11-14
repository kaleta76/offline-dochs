# Klient na razenie v Accesse (bez cloudu)

Spôsob, ako zamestnanci razia príchody, odchody a prerušenia **priamo z Accessu na svojom pracovnom počítači**, bez webového terminálu a bez akéhokoľvek servera mimo organizácie. Je určený pre prostredie, kde sa smie používať len Access a Excel (pokyn č. 19/2015, pozri `docs/` v súkromných poznámkach a odpoveď SOC z 12. 11. 2026): všetko beží v infraštruktúre organizácie.

> **Stav:** návrh a **strana HR** (príjem a prevod razení v Accesse). Samotný klient (okno s tlačidlami na počítači zamestnanca) a jeho inštalátor ešte nie sú. Kód VBA sa nedá spustiť mimo Accessu, preto je všetko **neoverené v skutočnom Accesse**; po každom kroku je v `access/CHANGELOG.md` skúška na kópii databázy.

## Rozhodnutia (12. 11. 2026)

| Otázka | Rozhodnutie |
|---|---|
| Kde sa razí | V práci len Access. Terminál (Lovable) sa v práci nenasadzuje; vyvíja sa súkromne. |
| Access na počítačoch | Plná verzia Accessu je na všetkých pracovných počítačoch, kde sa razí. |
| Úložisko | Zdieľaný sieťový priečinok s právami „zamestnanec môže pridávať, nie meniť ani mazať“. Každé razenie je jeden malý súbor. |
| Identifikácia | Podľa prihláseného Windows konta (osobné číslo z Active Directory, ako už používa karta 9). Bez PIN-u. |
| Prvá verzia klienta | Razenie (príchod, odchod, tlačidlá prerušení podľa konfigurácie), dnešné razenia, stav „čaká na odoslanie“ a prehľad vlastného mesiaca. Úpravy a schvaľovanie robí HR v Editore dňa. |
| Priorita | Klient v Accesse pred snímačom SKE a čítačkou kariet NFC (tie sú ďalšia možnosť, nie prvá). |

## Ako to funguje

```
 zamestnanec (Access, klient) ──► prijem\*.rzn   (jedno razenie = jeden súbor, len pridávanie)
                                       │  HR: karta 7 „Prijať razenia z klientov“
                                       ▼
 Access HR:  kontrola súboru a účtu → párovanie (to isté ako pri termináli) → TerminalInbox → DochadzkaImport → výpočet
                                       │
                                       └─► spracovane\RRRR-MM\  (prijaté)    chybne\  (odmietnuté s dôvodom)
 Access HR:  konfiguracia\klient_konfig.txt  (tlačidlá a texty)  ──► klient na všetkých počítačoch (len na čítanie)
```

Prevod razení na prerušenia a kódy razenia robí **rovnaký kód ako pri termináli** (`mod_19_TerminalImport`: príchod, odchod, obed, začiatok a koniec prerušenia), takže výpočet, editor dňa, výkazy a uzávierka sa správajú rovnako bez ohľadu na zdroj. Kontrakt terminála (`contract/`) sa nemení.

### Priečinky a práva (nastaví správca siete)

Základ (napr. `\\server\dochadzka`) je v nastavení `KlientPriecinok`.

| Priečinok | Zamestnanci | HR / správca |
|---|---|---|
| `prijem\` | **vytvárať súbory** (zápis nového súboru), nie čítať cudzie, nie meniť, nie mazať | všetko |
| `konfiguracia\` | len čítať | zápis (Access HR tam ukladá `klient_konfig.txt`) |
| `spracovane\`, `chybne\` | žiadny prístup | všetko |

Typické nastavenie práv je „odkladacia schránka“ (drop box): skupina zamestnancov má na `prijem\` právo *Vytvárať súbory / zapisovať údaje* len pre tento priečinok a nič pre existujúce súbory; vlastníkom nového súboru je ten, kto ho vytvoril. **Neoverené v tomto prostredí**: správca siete má nastavenie vyskúšať na jednom účte (vytvoriť súbor áno, otvoriť, zmeniť, zmazať cudzí nie).

### Súbor razenia `.rzn` (protokol v1)

Čistý text ASCII (bez diakritiky; úvodný UTF-8 BOM sa toleruje), riadky oddelené CRLF, najviac 2048 bajtov, názov `RRRRMMDD-HHMMSS_<id>.rzn` (čas razenia a `id`). Súbor sa zapíše naraz; riadok `#END` je posledný, takže nedopísaný súbor sa pozná.

```
DOCHSRZN;1
id=3F2A9C1E-7B64-4D0A-9E85-1C2D3E4F5A6B
oc=4002012
login=jnovak
pc=PC-0123
kod=WORK
smer=IN
cas=2026-11-12T14:23:05
utc=2026-11-12T13:23:05
odlozene=0
klient=1.0.0
#END
```

| Kľúč | Význam |
|---|---|
| `id` | GUID razenia; musí sa zhodovať s názvom súboru. Opakovaný príjem toho istého `id` je bezpečný (nevloží sa druhýkrát). |
| `oc` | osobné číslo (text, 1 až 20 znakov). |
| `login` | prihlasovacie meno do Windows (`sAMAccountName`), bez domény. |
| `pc` | názov počítača (`COMPUTERNAME`). |
| `kod`, `smer` | rovnaké ako v termináli: `WORK`/`DOCTOR`/`TRIP`/`FAMILY`/`LEAVE`/`SICK`/`PRIV`/`ERRAND` a `IN`/`OUT`. Príchod = `WORK` `IN`, odchod = `WORK` `OUT`, začiatok prerušenia = `X` `OUT`, jeho koniec = `WORK` `IN` (alebo `X` `IN`). |
| `cas` | miestny čas razenia na počítači (RRRR-MM-DDTHH:MM:SS). |
| `utc` | ten istý okamih v UTC; rozhoduje pri poradí razení pri zmene času. |
| `odlozene` | `1`, ak sa razenie zapísalo do súboru až dodatočne (sieť nebola k dispozícii a čakalo v klientovi). |
| `klient` | verzia klienta. |

### Čo kontroluje príjem v Accesse HR

1. **Tvar súboru** (hlavička, riadok `#END`, povinné kľúče, platný čas, kód a smer, `id` zhodné s názvom). Zlý súbor ide do `chybne\` s dôvodom.
2. **Účet a osobné číslo**: `login` musí v tabuľke Zamestnanci (`LoginAD`) patriť zamestnancovi s osobným číslom `oc`. Nastavenie `KlientKontrolaUctu`: `PRISNE` (predvolené; nezhoda = odmietnuté), `UPOZORNIT` (importuje sa ako neoverené), `VYPNUTE`.
3. **Vlastník súboru** v sieti musí byť ten istý účet ako `login` (zistí sa zo Windows). Tým sa pozná razenie „za iného“ aj vtedy, keď niekto upraví klienta. Nastavenie `KlientKontrolaVlastnika`: `UPOZORNIT` (predvolené; nezhoda = importuje sa ako **neoverené**), `PRISNE`, `VYPNUTE`. Správcovské účty môžu mať vlastníka „Administrators“, preto nie je predvolené `PRISNE`.
4. **Čas**: razenie nesmie byť v budúcnosti a rozdiel medzi `cas` a časom vytvorenia súboru na serveri nesmie presiahnuť `KlientMaxOdchylkaMin` (predvolene 10 minút); pri `odlozene=1` sa toleruje `KlientMaxOdlozenieDni` (predvolene 3). Inak je razenie **neoverené**.
5. **Dnešné razenia čakajú.** Párovanie príchodu, obeda a odchodu potrebuje celý deň (odchod uprostred dňa je obed, posledný odchod je koniec). Preto sa razenia dnešného dňa prevezmú až na ďalší deň (nastavenie `KlientAjDnesne` = 1 to zmení; potom môže byť obed pred návratom považovaný za odchod).
6. **Zdvojenie**: `id` sa ukladá ako `KL-<id>` do `TerminalInbox.ExterneID`; súbor, ktorý už bol prijatý, sa len presunie.

**Neoverené** razenia sa počítajú ako ostatné (`TerminalInbox.Overenie = unverified`), len sú označené rovnako ako neoverené razenia z terminála. Dôvod je v tabuľke `KlientRazenia` (stĺpec `Poznamka`).

### Čo tento návrh nerieši (a čo pri ňom treba vedieť)

- **Klient je súbor Accessu s VBA**, ktorý si zdatný používateľ vie upraviť. Preto sa dôvera opiera o **Windows vlastníka súboru a práva na priečinku**, nie o to, čo klient tvrdí. Neoverený čas (hodiny počítača) sa dá odhaliť len porovnaním s časom vytvorenia súboru na serveri.
- **Súbor sa nedá po zápise skontrolovať**, ak zamestnanec nemá právo čítať `prijem\`. Klient preto berie úspešné zapísanie súboru za odoslanie a drží si lokálny záznam vlastných razení.
- **Prehľad vlastného mesiaca** (druhá etapa) potrebuje, aby HR zverejnila súbory s odpracovaným časom, ku ktorým má každý zamestnanec prístup len k svojmu (práva na jednotlivé súbory). Bez toho by mohol každý čítať cudzie. Kým to nie je vyriešené, klient ukáže len vlastné razenia z lokálneho záznamu.
- **Nedostupná sieť**: klient razenie uloží lokálne a odošle pri ďalšom pokuse (označí `odlozene=1`).
- **Snímač SKE a karty NFC** sú ďalšia možnosť pre pracoviská bez počítača pri vchode; modul `mod_07_SKE` je len v súkromnom balíku a nie je testovaný.

## Etapy

1. **Strana HR (hotové tu, neoverené v Accesse):** protokol, príjem a prevod razení (`mod_22_KlientRazenia`, `mod_19_TerminalImport.PrevedRazeniaKlienta`), konfigurácia pre klienta, referenčný zapisovač a skúšobné súbory (`tools/klient_protokol.py`).
2. **Klient:** `DochadzkaKlient.accdb` (okno s tlačidlami, identifikácia z AD, lokálny záznam a fronta, zápis `.rzn`) a jeho inštalátor.
3. **Prehľad mesiaca a doladenie:** súbory s odpracovaným časom pre jednotlivých zamestnancov, upozornenia, príručka pre používateľov, snímač SKE a NFC.

## Skúška na kópii databázy (strana HR)

Pozri `access/CHANGELOG.md` (balík 2.18.0). Skúšobné súbory vytvorí `python3 tools/klient_protokol.py vzor <priečinok>`.
