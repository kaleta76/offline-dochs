// Spoločné pomôcky pre čítania cez malé POST RPC (firemný proxy blokuje niektoré GET dopyty so select=).

export type AppRole = "employee" | "manager" | "admin";

const APP_ROLES: readonly string[] = ["employee", "manager", "admin"];

/** Rola z databázy, ktorú aplikácia pozná. Neznáma rola sa vynecháva, aby novú rolu v databáze nepremenila na chybu. */
export const isAppRole = (role: string): role is AppRole => APP_ROLES.includes(role);

interface RpcErrorLike {
  code?: string | null;
  message?: string | null;
}

/** Funkcia v databáze (ešte) nie je: PostgREST vráti PGRST202 alebo „Could not find the function“. */
export function isMissingFunction(error: RpcErrorLike): boolean {
  return error.code === "PGRST202" || /could not find the function/i.test(error.message ?? "");
}
