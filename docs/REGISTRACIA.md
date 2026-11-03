# Registrácia firiem a zamestnancov (bez e-mailu)

Stav: návrh implementovaný v kóde, **ešte neoverený v živom prostredí** (pozri „Čo je neoverené“).
Dôvod: potvrdzovací e-mail z Lovable Cloud nechodí na pracovné adresy a terminál nemá zbierať osobné údaje.
V terminále preto nie je žiadny e-mail, zamestnanec je identifikovaný len osobným číslom SAP.

## Kto čo robí

| Kto | Čo |
|---|---|
| **Vlastník projektu** | Raz pošle firmám stály registračný kód. Žiadny superužívateľ ani schvaľovanie v aplikácii nie je. |
| **Správca firmy** | Zaregistruje organizáciu, pridá osobné čísla zamestnancov, vydá PIN-y, obnoví zabudnuté heslá. |
| **Zamestnanec** | Prvýkrát sa prihlási s PIN-om a nastaví si heslo. Ďalej sa prihlasuje číslom a heslom. |

Každá firma alebo oddelenie je samostatná organizácia (samostatný kód organizácie, osobné čísla, nastavenia a údaje).
Údaje sú oddelené databázovými pravidlami (RLS), ktoré sa tu nemenia.

## 1. Registrácia firmy

Obrazovka `Registrovať organizáciu / firmu` na `/auth`:

1. Registračný kód (od vlastníka projektu), názov firmy, osobné číslo správcu, heslo (aspoň 12 znakov), súhlas „zodpovedám za organizáciu“.
2. Systém založí organizáciu a správcu. Zobrazí **kód organizácie** (8 znakov, pre zamestnancov, nie je tajný) a **obnovovací kód správcu** (zobrazí sa len raz).
3. Súhlas sa zapíše do auditu (`organization_terms_accepted`).

Registračný kód je jeden, stály a overuje ho server. V repozitári je len jeho odtlačok SHA-256 (`src/lib/registration-code.ts`).
Kód má 100 bitov náhody, takže sa z odtlačku nedá zistiť.

**Výmena kódu** (ak by unikol): `python3 -I tools/new_registration_code.py`, nový odtlačok vložiť do `src/lib/registration-code.ts`, zlúčiť a publikovať.
Už založené firmy to neovplyvní.

## 2. Zamestnanci

V administrácii je sekcia **Prístup zamestnancov**:

1. Vložiť osobné čísla (riadok = číslo) alebo nahrať CSV z Accessu. Stačia čísla, mená netreba. Neplatné a duplicitné čísla ukáže náhľad.
2. „Vydať PIN“ vytvorí účet a PIN (12 znakov, platí 24 hodín). Zobrazí sa **raz**, dá sa stiahnuť ako CSV (`osobne_cislo;pin;platne_do`). Správca ho odovzdá osobne a súbor zmaže.
3. Zamestnanec na `/auth` zvolí „Mám PIN od správcu“, zadá kód organizácie, osobné číslo, PIN a nové heslo (aspoň 12 znakov).
4. Zabudnuté heslo: správca zadá číslo znova a zaškrtne „Obnoviť aj účty, ktoré už majú heslo“. Staré heslo aj prihlásenia na všetkých zariadeniach sa zrušia a vydá sa nový PIN.

Odkaz pre zamestnancov má tvar `…/auth?o=KÓD`, kód organizácie sa tak predvyplní.

## 3. Obnova hesla správcu

- Ak je správcov viac, jeden vydá druhému nový PIN (ako pri zamestnancovi, ale cez „Obnoviť“ nemožno obnoviť seba).
- Ak je správca jediný, použije **obnovovací kód** (`Obnova hesla správcu` na `/auth`). Kód je jednorazový, po použití sa vydá nový.
- Núdzovo (stratený obnovovací kód aj heslo jediného správcu): vlastník projektu cez Lovable Cloud → Users. **Odporúčanie: vždy aspoň dvaja správcovia.**

## Bezpečnostný model

- **PIN** je v účte uložený len ako odtlačok (PBKDF2-SHA256, soľ, 100 000 iterácií) v `app_metadata` (zapisuje ho iba server). Heslo účtu je pritom náhodné a nikomu neznáme, takže PIN nejde použiť ako heslo cez verejné prihlásenie. Platí 24 hodín a po 5 chybných pokusoch zhasne.
- **Heslo**: po 8 chybných pokusoch sa účet na 15 minút zamkne. Obnovovací kód: 5 pokusov, zámok 1 hodina. Zámok vie niekto zneužiť na dočasné zablokovanie cudzieho účtu (číslo je pseudonym, nie tajomstvo); správca vtedy vydá nový PIN.
- **Reset** zruší všetky relácie používateľa (pôvodná funkcia predávala ID namiesto tokenu, takže relácie nerušila).
- Chyby pri prihlásení sú rovnaké pre neznámu firmu aj neznáme číslo.
- Audit (`audit_log`): `organization_registered`, `organization_terms_accepted`, `employee_provisioned`, `employee_password_reset`, `employee_enrollment_completed`, `admin_recovered`.
- Žiadny e-mail, meno ani telefón sa neukladá. Syntetický e-mail účtu (`…@accounts.invalid`) je len interný identifikátor.

## Nasadenie (poradie je dôležité)

1. Zlúčiť pull request do `main`, v Lovable **Publish** (bezplatné dialógové okno).
2. Otestovať: registrácia testovacej firmy, vydanie PIN-u, prvé prihlásenie, obnova.
3. Až potom v Lovable → Users → Settings zapnúť **Disable sign-up**. Tým sa zruší verejné zakladanie účtov priamo cez Supabase (inak by sa dalo obísť registračný kód). Existujúci používatelia sa prihlasujú ďalej, účty zakladá server.
4. Ak by po vypnutí registrácie server nevedel zakladať účty, zapnúť ju späť a nahlásiť (pozri nižšie).

## Čo je neoverené

Kód nebol spustený proti skutočnej databáze. Overené je len jadro logiky v testoch s pamäťovou náhradou databázy a build v CI.

- Či Supabase prijme interný e-mail s doménou `.invalid` pri `admin.createUser`. Ak nie, zlyhá registrácia aj vydanie PIN-u.
- Či po „Disable sign-up“ stále funguje `admin.createUser` zo servera (podľa dokumentácie Lovable áno).
- Či `updateUserById` zlučuje alebo nahrádza `app_metadata` (kód počíta s oboma možnosťami).
- Či databázový trigger `handle_new_user` pri vytvorení účtu zo servera založí organizáciu a roly tak, ako pri registrácii z formulára.
- Vzhľad a použiteľnosť obrazoviek na telefóne.

Prvý test: zaregistrovať testovaciu firmu so skúšobným číslom. Ak zlyhá, chybová hláška nie je podrobná; príčinu treba hľadať v logoch servera.

## Čo tu nie je (zámerne)

- Samoobslužná zmena hesla prihláseným zamestnancom (zatiaľ cez správcu).
- Dvojfaktorové overenie správcu (Supabase TOTP je možné doplniť neskôr).
- Hierarchia firma → oddelenie (`parent_id`) a spoločný prehľad. Zatiaľ je každá jednotka samostatná organizácia.
- Zrušenie starého interného pozvania (`organization_invites`). Používa ho už len server pri vydaní PIN-u.
