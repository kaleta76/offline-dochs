/**
 * Zapamätanie osobného čísla v prehliadači, aby sa pri ďalšom prihlásení zadávalo len heslo.
 * Ukladá sa výlučne osobné číslo (pseudonym SAP, v aplikácii je aj inak v pamäti prehliadača), nikdy heslo ani PIN.
 * Číslo ostáva len v tomto prehliadači (localStorage), na server sa nikam neposiela.
 * Bez úložiska (súkromné okno, zablokované cookies) prihlásenie funguje ďalej, číslo sa len nepredvyplní.
 */
export const NUMBER_KEY = "personnel-number";

// Rovnaké pravidlo ako personnelNumberSchema v personnel.ts: 7 alebo 8 číslic.
const NUMBER_PATTERN = /^[0-9]{7,8}$/;

export type NumberStorage = Pick<Storage, "getItem" | "setItem" | "removeItem">;

/** Úložisko prehliadača, alebo null, ak nie je dostupné (prístup k nemu môže vyhodiť chybu). */
export function browserStorage(): NumberStorage | null {
  try {
    return typeof window === "undefined" ? null : window.localStorage;
  } catch {
    return null;
  }
}

/** Zapamätané číslo, alebo prázdny reťazec, ak nie je, je poškodené alebo úložisko nie je dostupné. */
export function readRememberedNumber(storage: NumberStorage | null): string {
  try {
    const value = storage?.getItem(NUMBER_KEY) ?? "";
    return NUMBER_PATTERN.test(value) ? value : "";
  } catch {
    return "";
  }
}

/** Po úspešnom prihlásení: so zapnutým `remember` číslo uloží, inak zapamätané číslo zmaže. */
export function rememberNumber(storage: NumberStorage | null, number: string, remember: boolean): void {
  try {
    if (remember && NUMBER_PATTERN.test(number)) storage?.setItem(NUMBER_KEY, number);
    else storage?.removeItem(NUMBER_KEY);
  } catch {
    // bez úložiska sa číslo len nezapamätá
  }
}

/** „Nie ste to vy?“ alebo spoločné zariadenie: zmaže zapamätané číslo. */
export function forgetNumber(storage: NumberStorage | null): void {
  try {
    storage?.removeItem(NUMBER_KEY);
  } catch {
    // nič na zmazanie
  }
}
