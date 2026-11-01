# Overovanie zariadení: registrácia, schválenie, obnova a audit

## Cieľ
Každé pípnutie bude vedieť, či prišlo z overeného zariadenia zamestnanca. Neznáme zariadenia budú môcť pípať aj offline, ale ich záznamy sa označia ako „neoverené“ a vedúci ich musí potvrdiť. Každá zmena stavu zariadenia sa zapíše do auditného záznamu.

## Ako to bude fungovať pre používateľa
```text
Prvé spustenie v prehliadači
  -> vytvorí sa tajný kľúč zariadenia (zostane iba v zariadení)
  -> zobrazí sa 6-miestny párovací kód s odpočtom (10 min)
  -> vedúci/admin v „Správe zariadení“ nájde kód a schváli zariadenie
  -> zamestnanec raz uvidí záchranný kód (napr. XXXX-XXXX-XXXX) na uloženie
Vymazaný prehliadač / nový počítač
  A) zadá záchranný kód -> starý kľúč sa zruší, nový je hneď aktívny, vydá sa nový záchranný kód
  B) požiada o náhradu -> nové zariadenie čaká, po schválení vedúcim sa staré zruší
```

## Kroky implementácie

### 1. Databáza (jedna migrácia)
- Nová tabuľka `devices`: id, user_id, organization_id, device_token_hash (unikátny, sha256 hex), status (`pending|active|backup|revoked`), pairing_code, pairing_expires_at, recovery_code_hash, replaces_device_id, approved_by, approved_at, revoked_by, revoked_at, created_at, last_seen_at, user_agent_hint.
- Pravidlo: na používateľa najviac jedno `active` (čiastočný unikátny index); `backup` = schválené záložné zariadenie.
- GRANT pre authenticated/service_role, RLS: SELECT pre vlastníka alebo `is_manager_of`/admina rovnakej organizácie. Priamy INSERT/UPDATE/DELETE zakázaný – všetko cez funkcie nižšie (zabráni podvrhnutiu stavu).
- Funkcie (security definer, kontrola organizácie, každá zapisuje do `audit_log`):
  - `register_device(token_hash, ua_hint)` → vytvorí `pending`, vráti párovací kód a expiráciu; obnovenie kódu pri vypršaní; limit počtu čakajúcich žiadostí.
  - `request_device_replacement(token_hash, ua_hint)` → `pending` s odkazom na pôvodné aktívne zariadenie (možnosť B).
  - `approve_device(id, as_backup)` → vedúci/admin; aktivuje, pri náhrade zruší pôvodné, vygeneruje záchranný kód a uloží iba jeho hash. Kód vráti jednorazovo cez `claim_recovery_code(token_hash)` pre vlastníka zariadenia.
  - `revoke_device(id, reason)` → vedúci/admin alebo vlastník.
  - `recover_device(recovery_code, new_token_hash)` → možnosť A; overí hash, obmedzenie pokusov (zámok po 5 zlyhaniach/hodinu, audit aj pri neúspechu), zruší starý, aktivuje nový, vráti nový záchranný kód.
  - `confirm_unverified_punch(punch_id)` → vedúci potvrdí neoverené pípnutie.
- `punches`: nové stĺpce `device_id`, `device_verification` (`verified|unverified|confirmed`, predvolene `unverified`), `device_token` (prechodný, trigger ho vždy vymaže).
- Rozšírenie triggera `punches_chain`: zo surového tokenu vypočíta sha256 na serveri, nájde `active/backup` zariadenie toho istého používateľa, nastaví `device_id`, `verified`/`unverified`, `last_seen_at`, vymaže surový token a zahrnie stav zariadenia do hash reťazca.
- Výnimka z append-only: jediná povolená zmena je `unverified -> confirmed` cez `confirm_unverified_punch`, s auditom; čas a kód pípnutia sa nikdy nemenia.

### 2. Klient – kľúč zariadenia (`src/lib/device.ts`)
- `crypto.getRandomValues` 32 bajtov → token; `crypto.subtle.digest('SHA-256')` → hash pre registráciu.
- Uloženie do IndexedDB (nová úložná časť v existujúcej databáze, verzia 2) viazané na user_id; `navigator.storage.persist()` po vytvorení, výsledok sa zobrazí ako upozornenie, ak prehliadač trvalé úložisko odmietne.
- Na serveri je uložený iba hash; surový token sa posiela len s pípnutím a server ho neukladá.

### 3. Klient – obrazovky
- Dialóg „Registrácia zariadenia“ v termináli: párovací kód veľkým písmom, odpočet, stav (čaká / schválené / zrušené), tlačidlá „Mám záchranný kód“ a „Nahradiť pôvodné zariadenie“.
- Po schválení jednorazové zobrazenie záchranného kódu s potvrdením „Uložil som si kód“.
- Pípanie zostáva dostupné aj počas čakania – záznamy sa iba označia ako neoverené (offline požiadavka).
- Nová stránka „Zariadenia“ v Správe (admin) a v „Môj tím“ (vedúci): zoznam zariadení, filter čakajúcich, vyhľadanie podľa párovacieho kódu, schváliť ako primárne / záložné, zrušiť s dôvodom, potvrdenie neoverených pípnutí.
- Vo výkaze a v tíme štítok „neoverené zariadenie“ pri dotknutých pípnutiach.

### 4. Offline front (`src/lib/offline-queue.ts`)
- Položka fronty nesie `device_token` (načítaný z IndexedDB pri pípnutí) namiesto spoliehania sa na user-agenta; `device` zostáva iba ako krátky popis.
- Spätné overenie po odoslaní porovná aj `device_id`/stav, ale nikdy nevyžaduje surový token späť; pri zrušenom zariadení sa záznam neodmietne, len príde ako neoverený.
- Existujúce záznamy vo fronte bez tokenu sa odošlú ako neoverené (spätná kompatibilita).

### 5. Audit
- Akcie: `device.registered`, `device.replacement_requested`, `device.approved`, `device.revoked`, `device.recovered`, `device.recovery_failed`, `punch.device_confirmed`; detail obsahuje id zariadenia, predchádzajúci/nový stav, vykonávateľa a dôvod – nikdy token ani záchranný kód.
- Admin vidí tieto udalosti v existujúcom audite organizácie.

### 6. Testy a overenie
- Unit testy: generovanie tokenu (32 bajtov, hex), hash, ukladanie v IndexedDB, front prenáša token a staré položky bez tokenu.
- Databázové overenie: neoverené pípnutie z neznámeho zariadenia, overené po schválení, zrušené zariadenie → neoverené, cudzia organizácia nevidí ani neschváli zariadenie, záchranný kód funguje iba raz, zámok po opakovaných pokusoch, surový token nie je uložený.
- Prihlásený prechod v prehliadači: registrácia → schválenie adminom → pípnutie označené ako overené.
- Aktualizácia `AGENTS.md` (pravidlo: stav zariadenia určuje iba DB trigger zo serverovo hashovaného tokenu) a `roadmap.md`.

## Rozhodnutia, ktoré plán predpokladá
- Párovací kód platí 10 minút; záchranný kód 12 znakov; zámok po 5 chybných pokusoch na hodinu.
- Vlastník môže svoje zariadenie zrušiť sám, schvaľuje len vedúci alebo admin.
- Neoverené pípnutia sa započítavajú do výkazu, ale sú zvýraznené, kým ich vedúci nepotvrdí (alternatíva: nezapočítať do potvrdenia).
- Poznámka: kľúč v prehliadači chráni pred bežnou zámenou zariadenia, nie pred technicky zdatným používateľom, ktorý si kľúč skopíruje – ide o dôkaz pôvodu, nie o hardvérové overenie.
