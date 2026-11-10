// Rozhodnutie ochrany chránených stránok (src/routes/_authenticated/route.tsx).
//
// Na prihlasovaciu stránku sa používateľ presmeruje len vtedy, keď server jasne odmietol jeho prihlásenie
// (neplatný alebo zrušený token). Keď overenie zlyhá pre spojenie – výpadok siete, firemný proxy, chyba brány
// 502/503/504 alebo HTML stránka namiesto odpovede – zostáva v platnosti lokálne uložené prihlásenie, aby
// terminál ďalej fungoval a razenia sa uložili do fronty. Dáta tým nie sú odkryté: databáza ich bez platného
// tokenu aj tak nevydá a pri najbližšej úspešnej kontrole sa neplatné prihlásenie zatvorí.

export type GuardDecision = "allow" | "login";

interface AuthErrorLike {
  name?: string | null;
  status?: number | null;
}

/** Stavy 4xx, ktoré nehovoria nič o platnosti prihlásenia (časový limit, obmedzenie počtu požiadaviek). */
const NOT_A_REJECTION = new Set([408, 429]);

/** True, keď server odpovedal a prihlásenie odmietol (napr. 401 neplatný token, 403 zrušená relácia). */
export function isAuthRejection(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const e = error as AuthErrorLike;
  if (e.name === "AuthRetryableFetchError") return false;
  const status = typeof e.status === "number" ? e.status : null;
  if (status == null) return false;
  return status >= 400 && status < 500 && !NOT_A_REJECTION.has(status);
}

export function guardDecision(input: {
  /** V úložisku je prihlásenie (relácia). */
  hasSession: boolean;
  online: boolean;
  /** Používateľ, ktorého vrátilo overenie na serveri; null, keď overenie neprebehlo alebo zlyhalo. */
  user: unknown;
  /** Chyba overenia (vrátená alebo vyhodená). */
  error: unknown;
}): GuardDecision {
  if (!input.hasSession) return input.user ? "allow" : "login";
  // Bez spojenia sa overenie ani nepokúša: platí lokálna relácia.
  if (!input.online) return "allow";
  if (input.user) return "allow";
  // Server odpovedal bez používateľa a bez chyby: relácia neexistuje.
  if (!input.error) return "login";
  return isAuthRejection(input.error) ? "login" : "allow";
}
