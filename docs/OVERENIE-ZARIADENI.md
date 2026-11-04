# Overenie zariadení: čo zaručuje a čo nie

Stav: v kóde (PR „Overenie zariadení“), **bez zmeny databázy**. Časť opatrení potrebuje migráciu, tá je v poslednej kapitole.

## Čo overenie zariadenia je

Každé zariadenie (prehliadač) si vytvorí náhodný 256-bitový kľúč a uloží ho len u seba (IndexedDB). Server pozná iba jeho odtlačok SHA-256.
Pri každom razení terminál pošle kľúč, trigger `punches_chain` ho na serveri zahashuje, porovná so schváleným zariadením zamestnanca a kľúč zahodí.
Výsledok je v stĺpci `device_verification`: `verified` (schválené zariadenie), `unverified` (iné zariadenie), `confirmed` (neoverené razenie potvrdil vedúci alebo ide o korekciu).

**Dokazuje, ktoré zariadenie razilo, nie kde sa nachádza.** Schválený mobil môže pípať doma rovnako ako na pracovisku. Prítomnosť na pracovisku webový terminál nezaručí. Ak je cieľom prítomnosť, treba organizačné pravidlo
(napríklad schvaľovať len pracovné počítače) alebo iný model (spoločný terminál na pracovisku), nie technickú kontrolu v tejto aplikácii.

## Čo sa deje s razením z neschváleného zariadenia

* Prijme sa vždy (offline je základná požiadavka), uloží sa ako `unverified` a **počíta sa** do dňa a mesiaca.
* Od tejto verzie je v Môj mesiac, Môj tím a vo výkaze A4 označené štítkom „neoverené“, nad tabuľkou je pruh s počtom a v Môj tím je stĺpec „Neoverené“. Výpočet sa nezmenil (`engine.ts` príznak nepoužíva).
* Pri uzavretí mesiaca sa vedúci na neoverené razenia upozorní.
* Vedúci ich potvrdí v Môj tím → Zariadenia → „Pípnutia z neoverených zariadení“ (príznak sa zmení na `confirmed`).
* V exporte pre Access ide príznak v stĺpci `device_verification`. Access od 2.11.1 neoverené razenia ukladá a hlási pri importe.

## „Prehliadač nezaručil trvalé uloženie kľúča“

Kľúč je v IndexedDB prehliadača. Kým prehliadač nepovolí „trvalé“ úložisko, môže ho pri nedostatku miesta zmazať (a pri ručnom vymazaní údajov stránky sa zmaže vždy).
Hlásenie pod stavom „Overené zariadenie“ teda **neznamená, že sa kľúč neuložil** (inak by zariadenie vôbec neboli overené), ale že prehliadač zatiaľ nič nezaručil.

* **Chrome a Edge** rozhodujú potichu, bez otázky: trvalé úložisko dostane stránka, ktorú máte medzi záložkami, nainštalovanú ako aplikáciu, často navštevujete alebo má povolené oznámenia.
  Pri novej, zriedka otváranej stránke odpovedia „nie“. Odpoveď sa však časom mení, preto sa aplikácia pýta znova: pri každom načítaní, hneď po schválení zariadenia a na tlačidle **Skúsiť znova**.
* **Firefox** sa pýta používateľa vyskakovacím oknom; aplikácia sa preto bez vášho kliknutia nepýta častejšie než pri načítaní a po schválení.
* **Súkromné okno** trvalé úložisko nikdy nedá a po zatvorení okna kľúč zmizne. Terminál v ňom nepoužívajte.

Čo urobiť: stránku pridať medzi záložky (Ctrl+D) alebo ju nainštalovať ako aplikáciu (ikona inštalácie v adresnom riadku Chrome; v ukážke Lovable `id-preview--…` je service worker vypnutý, takže inštalácia tam nemusí byť dostupná; záložka funguje vždy) a stlačiť **Skúsiť znova**.
Ak sa kľúč aj tak stratí, použije sa „Nahradiť pôvodné zariadenie“ a schváli ho vedúci; pípať sa dá aj dovtedy, razenia sú označené „neoverené“. Žiadne razenie sa nestratí.

## Záchranný kód zariadenia: prečo sa už nezobrazuje

Pôvodný postup: po schválení sa zariadeniu raz zobrazil záchranný kód a ten sa dal zadať na inom zariadení (`recover_device`).
Kto kód zadal (a poznal heslo), dostal **overené zariadenie bez schválenia vedúceho**, pôvodné sa zrušilo a ako schvaľovateľ sa zapísal on sám.

Scenár: zamestnanec si zaregistruje pracovný počítač, kód si uloží (vymazanie cache netreba), na mobile ho zadá a pípa z domu ako `verified`.
Vedúci v zozname čakajúcich ani neoverených razení nič nevidel a žiadna notifikácia neprišla.

Pri dnešnom pravidle (neoverené razenia sa počítajú) kód zamestnancovi nič iné neprinesie: bez kódu sa nové zariadenie zaregistruje, pípa ďalej a vedúci razenia potvrdí.
Kód teda len obchádza kontrolu. Preto:

* kód sa **nezobrazuje** a tlačidlo „Mám záchranný kód“ je odstránené,
* po schválení sa kód na serveri iba „vyzdvihne“ a zahodí (`claim_recovery_code`), aby nezostal čakať v databáze,
* po vymazaní údajov prehliadača alebo pri novom zariadení sa použije „Nahradiť pôvodné zariadenie“ a schváli ho vedúci. Pípať sa dá aj dovtedy.

**Čo to nerieši:** funkcie `recover_device` a `claim_recovery_code` v databáze ostávajú. Technicky zdatný zamestnanec ich vie zavolať sám (napríklad cez vývojárske nástroje prehliadača)
a kódy, ktoré zamestnanci už dostali, platia, kým sa funkcia nevypne migráciou. Pri bežnom používaní to však už nie je možné bez úmyslu.

## Zmeny zariadení pre vedúceho

Môj tím → Zariadenia → „Zmeny zariadení (posledných 90 dní)“ ukazuje to, čo nie je bežné prvé schválenie:

| Druh | Čo znamená | Čo urobiť |
|---|---|---|
| obnovené záchranným kódom, bez schválenia vedúceho | zamestnanec sám získal overené zariadenie (aj dnes je to možné cez databázu) | overiť u zamestnanca, pri pochybnosti „Zrušiť zariadenie“ |
| schválené samotným používateľom | správca schválil vlastné zariadenie | bežné pri správcovi, inak overiť |
| náhrada schválená / čaká na schválenie | normálna výmena zariadenia | pri „zmena typu zariadenia“ (napr. Windows → Android) overiť, že je to zámer |

Zariadenia majú krátke označenie (4 znaky z `id`, napr. `A3F9`), ktoré zamestnanec vidí na svojom zariadení a vedúci v zozname. Nie je tajné ani jedinečné, slúži len na priradenie a dá sa podľa neho filtrovať.
Typ zariadenia sa určuje z user-agent (prvých 80 znakov uložených v `user_agent_hint`), nie je to záruka.

## Hrozby a stav

| Hrozba | Stav |
|---|---|
| Útočník pozná heslo zamestnanca a pípa zo svojho zariadenia | razenia sú `unverified`, označené, vedúci ich vidí a potvrdzuje alebo zneplatní |
| Zamestnanec presunie overené zariadenie na mobil záchranným kódom | v UI zavreté, technická cesta ostáva do migrácie, zmena je viditeľná v „Zmeny zariadení“ |
| Vedúci schváli osobný mobil ako záložné zariadenie | zámer vedúceho, nie chyba; pravidlo patrí do organizácie |
| Podvrhnutie overenia | nemožné: kľúč je náhodný a server porovnáva odtlačok, odtlačok bez kľúča nepomôže |
| Skopírovanie profilu prehliadača na iný počítač (kópia IndexedDB) | neriešené; vyžaduje prístup k súborom a znalosť postupu |
| Neoverené razenia sa počítajú | označené a viditeľné; rozhodnutie nižšie |

## Rozhodnutia pre vlastníka

1. **Majú sa neoverené razenia počítať do schválenia?** Dnes áno, teraz viditeľne označené. Odporúčanie: ponechať. Nepočítanie by pri omeškanom schválení ukrátilo poctivým zamestnancom čas a postup vedúcich ešte nie je vyskúšaný.
2. **Zrušiť záchranný kód úplne?** Odporúčanie: áno (migrácia nižšie). Nová verzia aplikácie ho už nepoužíva.
3. **Povoliť osobné mobily?** Ak nie, vedúci ich neschvaľuje (ani ako záložné) a v „Zmeny zariadení“ sleduje typ zariadenia.

## Zostáva urobiť migráciou (zatiaľ nie je spustená, ide do dávky)

* `recover_device` vypnúť (alebo vytvoriť čakajúce zariadenie, ktoré schváli vedúci) a odobrať právo spúšťať `claim_recovery_code`.
* Odobrať z práv na čítanie stĺpec `device_token_hash` v `devices`. Terminál ho nečíta a zamestnanec by si ho inak mohol prečítať a vybrať čakajúci záchranný kód.
* Notifikácia vedúcemu pri novom zariadení (preferencia `new_devices` v `notification_preferences` existuje, ale nič ju neposiela).
* Obrazovka s auditom (`audit_log` číta len správca cez API, záznam `device.recovered` nikto nevidí).

## Čo nie je overené

* Obrazovky (Môj mesiac, Môj tím, Zariadenia) som nespúšťal v živom prostredí. Logika (označenie zmien, štítok, typ zariadenia, počet neoverených) má testy v `src/lib/device-trace.test.ts`.
* Hlásenie o trvalom uložení kľúča: opakovanú otázku a text som nespúšťal v Chrome (logika má testy v `src/lib/device.test.ts`). Že záložka alebo inštalácia v Chrome naozaj zmení odpoveď, vychádza z dokumentácie prehliadača, nie z vlastného pokusu.
* Po Publish skontrolujte: (1) na novom zariadení sa nezobrazí záchranný kód ani tlačidlo „Mám záchranný kód“, (2) razenie z neschváleného zariadenia má v Môj mesiac štítok „neoverené“, (3) v Môj tím sa objaví stĺpec „Neoverené“,
  (4) po náhrade zariadenia sa v Zariadenia objaví „Zmeny zariadení“.
