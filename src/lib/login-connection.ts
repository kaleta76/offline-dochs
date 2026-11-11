// Prihlásenie bez spojenia: rozpoznanie výpadku a jasné hlásenie.
//
// Keď zlyhá prihlásenie pre chýbajúce spojenie (výpadok, firemný proxy), prihlasovacia stránka predtým ukázala text
// „Skontrolujte zadané údaje…“ alebo „Nesprávny e-mail alebo heslo“ a zamestnanec si myslel, že zadal zle.
import { isNetworkError } from "./connection";

export const OFFLINE_LOGIN_MESSAGE =
  "Bez spojenia so serverom sa nedá prihlásiť. Skontrolujte pripojenie a skúste to o chvíľu. Razenia čakajúce v tomto zariadení sa nestratia.";
export const OFFLINE_ACTION_MESSAGE =
  "Bez spojenia so serverom sa to teraz nedá dokončiť. Skontrolujte pripojenie a skúste to o chvíľu.";

function browserOnline(): boolean {
  return typeof navigator === "undefined" || navigator.onLine !== false;
}

/**
 * True, keď chyba hovorí o spojení a nie o zadaných údajoch: prehliadač je offline, výnimka siete (Failed to fetch…),
 * AuthRetryableFetchError, stav 0 alebo odpoveď brány 502, 503, 504. SyntaxError (odpoveď, ktorá nie je JSON, napr. HTML
 * stránka proxy namiesto odpovede serverovej funkcie) sa berie rovnako.
 */
export function isConnectionFailure(error: unknown, online: boolean = browserOnline()): boolean {
  if (!online) return true;
  if (!error || typeof error !== "object") return false;
  const e = error as { name?: unknown; message?: unknown; status?: unknown };
  if (e.name === "AuthRetryableFetchError" || e.name === "SyntaxError") return true;
  if (typeof e.message === "string" && isNetworkError(e.message)) return true;
  return typeof e.status === "number" && [0, 502, 503, 504].includes(e.status);
}

export interface SetSessionOutcome {
  ok: boolean;
  /** Neúspech pre spojenie (nie pre odmietnutie tokenov serverom). */
  connection: boolean;
}

/**
 * Začne reláciu s tokenmi z prihlásenia. `setSession` pri čerstvom tokene volá GET /auth/v1/user, ktorý pri blokovaní proxy
 * zlyhá; jednorazový krátky opakovaný pokus zachráni bežný prerušený dopyt. Opakuje sa len pri chybe spojenia a len keď je
 * prehliadač online; odmietnutie servera sa neopakuje.
 */
export async function setSessionWithRetry(
  attempt: () => Promise<{ error?: unknown } | null | undefined>,
  opts: {
    retries?: number;
    delayMs?: number;
    sleep?: (ms: number) => Promise<void>;
    online?: () => boolean;
  } = {},
): Promise<SetSessionOutcome> {
  const retries = opts.retries ?? 1;
  const delayMs = opts.delayMs ?? 1500;
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const isOnline = opts.online ?? browserOnline;
  for (let i = 0; ; i += 1) {
    let error: unknown = null;
    try {
      error = (await attempt())?.error ?? null;
    } catch (e) {
      error = e ?? new Error("setSession failed");
    }
    if (!error) return { ok: true, connection: false };
    const online = isOnline();
    const connection = isConnectionFailure(error, online);
    if (!connection || !online || i >= retries) return { ok: false, connection };
    await sleep(delayMs);
  }
}
