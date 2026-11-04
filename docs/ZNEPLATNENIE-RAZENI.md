# Zneplatnenie razenia (duplicita, omyl)

## Postup
1. **Zamestnanec** otvorí *Môj mesiac*, pri razení klikne na malé tlačidlo **zneplatniť** a napíše dôvod (3 až 500 znakov, **bez osobných údajov**, napr. „dvojité razenie“). Žiadosť môže podať aj vedúci alebo správca za zamestnanca vo výkaze zamestnanca (Môj tím → Výkaz A4). Kým žiadosť nie je schválená, razenie sa počíta a je označené „čaká na zneplatnenie“.
2. **Vedúci alebo správca** vidí žiadosť v *Môj tím* → **Žiadosti o zneplatnenie razenia** a klikne na **Zneplatniť razenie** alebo **Zamietnuť**. Schváliť môže len vedúci tohto zamestnanca alebo správca; vedúci si vlastnú žiadosť v zozname nevidí (nemôže si ju schváliť sám), správca áno.
3. **Schválením** sa razenie označí `voided_at`. Z databázy sa **nemaže** a hash reťaz ostáva nezmenená. Zneplatnené razenie sa nezapočítava do výpočtu dňa, mesiaca a sald; v tabuľke je preškrtnuté.
4. Na jedno razenie môže byť naraz jediná otvorená alebo schválená žiadosť; zamietnutú možno podať znova.
5. Do uzavretého mesiaca sa nedá zasahovať (tlačidlo sa neukáže, žiadosť ani schválenie databáza nepovolí).

## Prenos do Accessu
* *Admin → Export pre dochádzkový systém*: tlačidlo **Zneplatnené razenia (.csv)** stiahne `voids_RRRRMM.csv` (kontrakt 1.1, pozri `contract/README.md`).
* Pri exporte sa zapíše záznam `export.voids` do auditu.
* Importovať treba v tomto poradí: najprv `punches_RRRRMM.csv`, potom `voids_RRRRMM.csv`.

## Nasadenie (poradie je dôležité)
1. **Najprv migrácia** (v databáze je spustená od 3. 11. 2026) `docs/migracie/0006_zneplatnenie_razeni.sql` (v Lovable chate: „Spusti migráciu zo súboru docs/migracie/0006_zneplatnenie_razeni.sql presne tak, ako je, nič nemeň.“ – približne 1 kredit; viď `LOVABLE-KREDITY.md`).
2. Potom zlúčiť PR a **Publish**. Kód bez migrácie spadne pri načítaní mesiaca (chýbajú stĺpce `voided_at`, `void_request_id`).
3. Migrácia je aditívna (nové stĺpce a tabuľka, bez mazania dát). Funkcia `punches own insert` sa upravuje tak, aby zamestnanec nemohol vložiť už „zneplatnené“ razenie.

## Čo bolo overené a čo nie
* Migrácia bola vyskúšaná na lokálnom PostgreSQL 16 so zjednodušenými kópiami pomocných funkcií (RLS, schvaľovanie, uzavretý mesiac, hash reťaz sa nezmení).
* Zlatý súbor a pätička SHA-256 boli overené nezávisle v Pythone; čisté funkcie majú testy.
* **Neoverené:** beh celej aplikácie v Lovable (UI formulár, zoznam v Tíme, stiahnutie súboru) – skontrolujte po Publish.
