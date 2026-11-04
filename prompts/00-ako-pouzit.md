# Ako používať prompty

Prompty sú určené pre Lovable agenta (vkladáte ich do chatu projektu v Lovable). Idú **po jednom, v poradí**; po každom skontrolujte výsledok
(CI zelené, náhľad v Lovable) a až potom vložte ďalší. Každý prompt začína rovnakou vetou, aby agent najprv prečítal pravidlá.

| # | Súbor | Čo robí | Zasahuje DB? |
|---|---|---|---|
| 01 | `01-ci-a-kontraktovy-test.md` | CI, presun referenčného exportu do `src`, kontraktový test | nie |
| 02 | `02-export-pre-access.md` | Tlačidlo „Export pre Access“ v administrácii | nie |
| 03 | `03-bezpecnost.md` | `.env`, registrácia organizácií, voliteľný e-mail | možno (nastavenie Auth) |
| 04 | `04-integracny-rezim.md` | Vypnutie uzávierky v terminále, popisky „orientačné“ | áno (jedno nastavenie) |
| 05 | `05-https-pull-volitelne.md` | Voliteľne: čítací endpoint s tokenom | áno (tabuľka tokenov) |
| 06 | `06-konfiguracia-z-accessu.md` | Prijatie konfigurácie a výpočtového plánu z Accessu, výpočet podľa nej | áno (plán, verzie konfigurácie) |
