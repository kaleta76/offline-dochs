// Overenie, či je databáza (Lovable Cloud) práve dosiahnuteľná, teda či by sa prihlásenie teraz podarilo.
//
// Používa sa pri odhlásení pre nečinnosť (src/lib/idle-timeout.ts): zamestnanca netreba odhlásiť v okamihu, keď sa nevie
// znova prihlásiť. Prihlásenie končí dopytom GET /auth/v1/user (setSession); práve ten firemný proxy (Fortinet) niekedy
// zatvorí, preto je tým istým dopytom aj overenie. `navigator.onLine` na to nestačí: za proxy je pravda aj pri blokovaní.
import { isAuthRejection } from "./auth-guard";

export const PROBE_TIMEOUT_MS = 8000;

/**
 * True, keď server odpovedal: bez chyby alebo jasným odmietnutím (4xx, napr. neplatný token). False pri chybe spojenia,
 * odpovedi brány (502, 503, 504, HTML stránka proxy) a pri 408 a 429, teda vždy, keď by prihlásenie zrejme neprešlo.
 */
export function serverAnswered(error: unknown): boolean {
  return !error || isAuthRejection(error);
}

function browserOnline(): boolean {
  return typeof navigator === "undefined" || navigator.onLine !== false;
}

/**
 * Spustí krátky dopyt `check` (napr. `supabase.auth.getUser()`) a vráti, či server odpovedal. Bez spojenia sa dopyt ani
 * nepokúša. Výnimka a prekročenie času (`timeoutMs`) znamenajú „nedosiahnuteľný“.
 */
export async function isServerReachable(
  check: () => Promise<{ error?: unknown } | null | undefined>,
  opts: { online?: boolean; timeoutMs?: number } = {},
): Promise<boolean> {
  if (!(opts.online ?? browserOnline())) return false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error("timeout")), opts.timeoutMs ?? PROBE_TIMEOUT_MS);
    });
    const result = await Promise.race([check(), timeout]);
    return serverAnswered(result?.error);
  } catch {
    return false;
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}
