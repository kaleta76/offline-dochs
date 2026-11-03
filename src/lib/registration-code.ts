// SHA-256 odtlačok registračného kódu (kód je normalizovaný: veľké písmená, bez pomlčiek).
// Samotný kód v repozitári nie je a z odtlačku sa nedá zistiť (kód má 100 bitov náhody).
// Výmena kódu: vygenerovať nový kód, sem vložiť jeho odtlačok, zlúčiť a publikovať. Pozri docs/REGISTRACIA.md.
export const REGISTRATION_CODE_SHA256 =
  "3cf03fd74c9e7def409eb3a2e3b5834b7deb6bd854db7c6d25d6edca3bb4b791";
