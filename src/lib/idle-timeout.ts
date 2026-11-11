// Automatic sign-out after a period without user activity (12 hours by default; the organization admin sets it in Správa).
//
// The time of the last user activity (key, click, touch, punch) is stored in localStorage under
// `last_activity_at`, written at most once a minute. Sign-out only ends the login session: the
// offline punch queue in IndexedDB is never touched, so waiting punches are sent after the next
// sign-in of the same person.
//
// When the limit has passed but the server cannot be reached, the sign-out is deferred (at most IDLE_GRACE_MS after the limit,
// see decideIdleExpiry): nobody is signed out at the moment they could not sign in again.
import { useEffect, useRef } from "react";
import { supabase } from "@/integrations/supabase/client";
import { isServerReachable } from "./server-reachable";

const HOUR_MS = 60 * 60 * 1000;
export const DEFAULT_IDLE_LIMIT_HOURS = 12;
export const IDLE_LIMIT_MS = DEFAULT_IDLE_LIMIT_HOURS * HOUR_MS;
/** Povolené hodnoty limitu nečinnosti v hodinách (kratší limit než pol hodiny by pri bežnej práci odhlasoval zbytočne). */
export const IDLE_LIMIT_OPTIONS_HOURS = [0.5, 1, 2, 4, 8, 12, 24, 48, 72] as const;
/**
 * Kľúč v localStorage: kópia limitu nečinnosti organizácie v tomto zariadení. Zdroj pravdy je databáza (organizations.idle_timeout_hours,
 * nastavuje správca v Správe); kópia sa obnovuje pri každom načítaní účtu a slúži ochrane stránok pred načítaním účtu a práci bez siete.
 */
export const IDLE_LIMIT_KEY = "idle_limit_hours";
export const ACTIVITY_THROTTLE_MS = 60 * 1000;
export const IDLE_CHECK_INTERVAL_MS = 60 * 1000;
export const LAST_ACTIVITY_KEY = "last_activity_at";
/** Set while an idle sign-out is in progress or could not remove the session (for example offline). */
export const IDLE_SIGNOUT_KEY = "idle_signout_pending";
export const IDLE_MESSAGE = "Boli ste odhlásený z dôvodu nečinnosti.";
/** Najdlhšie odloženie odhlásenia, keď server nie je dosiahnuteľný: počíta sa od vypršania limitu, potom sa odhlási vždy. */
export const IDLE_GRACE_MS = 12 * HOUR_MS;
/** Po neúspešnom overení dosiahnuteľnosti servera sa ďalšie robí najskôr o túto dobu (návrat spojenia ho vynúti). */
export const PROBE_RETRY_MS = 2 * 60 * 1000;

type Store = Pick<Storage, "getItem" | "setItem" | "removeItem">;

function storage(): Store | null {
  try {
    return typeof window === "undefined" ? null : window.localStorage;
  } catch {
    return null;
  }
}

export function readLastActivity(store: Store | null = storage()): number | null {
  try {
    const raw = store?.getItem(LAST_ACTIVITY_KEY);
    if (!raw) return null;
    const value = Number(raw);
    return Number.isFinite(value) && value > 0 ? value : null;
  } catch {
    return null;
  }
}

/** Prijme len hodnotu zo zoznamu povolených (text alebo číslo); inak null. */
export function parseIdleLimitHours(raw: unknown): number | null {
  const value = typeof raw === "string" ? Number(raw.trim().replace(",", ".")) : raw;
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return (IDLE_LIMIT_OPTIONS_HOURS as readonly number[]).includes(value) ? value : null;
}

/** Limit nečinnosti v hodinách podľa kópie v zariadení; bez platnej hodnoty 12 hodín. */
export function readIdleLimitHours(store: Store | null = storage()): number {
  try {
    return parseIdleLimitHours(store?.getItem(IDLE_LIMIT_KEY)) ?? DEFAULT_IDLE_LIMIT_HOURS;
  } catch {
    return DEFAULT_IDLE_LIMIT_HOURS;
  }
}

export function readIdleLimitMs(store: Store | null = storage()): number {
  return readIdleLimitHours(store) * HOUR_MS;
}

/** Uloží kópiu limitu v zariadení. Neplatná hodnota sa nezapíše; predvolená hodnota kópiu odstráni. */
export function writeIdleLimitHours(hours: number, store: Store | null = storage()): boolean {
  const value = parseIdleLimitHours(hours);
  if (value == null || !store) return false;
  try {
    if (value === DEFAULT_IDLE_LIMIT_HOURS) store.removeItem(IDLE_LIMIT_KEY);
    else store.setItem(IDLE_LIMIT_KEY, String(value));
    return true;
  } catch {
    return false;
  }
}

/**
 * Prenesie limit organizácie (z odpovede databázy) do zariadenia. Chýbajúca alebo neplatná hodnota (databáza bez migrácie 0012,
 * poškodená odpoveď) kópiu nemení, aby sa limit nezmenil omylom.
 */
export function mirrorOrganizationIdleLimit(hours: unknown, store: Store | null = storage()): boolean {
  const value = parseIdleLimitHours(hours);
  return value == null ? false : writeIdleLimitHours(value, store);
}

/** Slovenský popis limitu: „30 minút“, „1 hodina“, „2 hodiny“, „12 hodín“. */
export function idleLimitLabel(hours: number): string {
  if (hours < 1) return `${Math.round(hours * 60)} minút`;
  if (hours === 1) return "1 hodina";
  return `${hours} ${hours >= 2 && hours <= 4 ? "hodiny" : "hodín"}`;
}

/**
 * True when the last activity is older than the limit (12 hours unless set otherwise). A missing value
 * is never expired (first start after an update). A newer sign-in time overrides a stale stored activity.
 */
export function isIdleExpired(
  lastActivity: number | null,
  now: number,
  signedInAt?: number | null,
  limitMs: number = IDLE_LIMIT_MS,
): boolean {
  if (lastActivity == null) return false;
  const reference = Math.max(
    lastActivity,
    Number.isFinite(signedInAt) ? (signedInAt as number) : 0,
  );
  return now - reference > limitMs;
}

/** Time when the idle limit runs out (the later of last activity and sign-in plus the limit); null without stored activity. */
export function idleDeadline(
  lastActivity: number | null,
  signedInAt?: number | null,
  limitMs: number = IDLE_LIMIT_MS,
): number | null {
  if (lastActivity == null) return null;
  const reference = Math.max(lastActivity, Number.isFinite(signedInAt) ? (signedInAt as number) : 0);
  return reference + limitMs;
}

export type IdleDecision = "active" | "signout" | "defer";

let lastFailedProbe: number | null = null;

/** Zabudne posledné neúspešné overenie servera (napr. po návrate spojenia, v testoch). */
export function resetServerProbe() {
  lastFailedProbe = null;
}

/** Overí cez databázu (GET /auth/v1/user, ten istý dopyt ako koniec prihlásenia), či by sa prihlásenie teraz podarilo. */
export function probeSupabaseServer(): Promise<boolean> {
  return isServerReachable(() => supabase.auth.getUser());
}

/**
 * Rozhodne, čo urobiť pri vypršanom limite nečinnosti. "active": limit nevypršal. "signout": odhlásiť. "defer": server nie je
 * dosiahnuteľný, odhlásenie sa odloží, aby sa zamestnanec nemusel prihlasovať, keď sa nevie prihlásiť; razenia ostávajú
 * možné a idú do fronty. Odloženie trvá najviac `graceMs` po vypršaní limitu a nič sa nepíše do úložiska, takže po
 * obnovení stránky platí to isté. Počas odloženia sa aktivita nezapisuje (limit sa nepredlžuje). Neúspešné overenie sa
 * opakuje najskôr po PROBE_RETRY_MS.
 */
export async function decideIdleExpiry(opts: {
  lastActivity: number | null;
  now: number;
  signedInAt?: number | null;
  limitMs?: number;
  graceMs?: number;
  probe?: (() => Promise<boolean>) | undefined;
}): Promise<IdleDecision> {
  const limitMs = opts.limitMs ?? IDLE_LIMIT_MS;
  if (!isIdleExpired(opts.lastActivity, opts.now, opts.signedInAt, limitMs)) return "active";
  const deadline = idleDeadline(opts.lastActivity, opts.signedInAt, limitMs);
  if (deadline == null || opts.now - deadline > (opts.graceMs ?? IDLE_GRACE_MS)) return "signout";
  if (lastFailedProbe != null && opts.now - lastFailedProbe < PROBE_RETRY_MS) return "defer";
  const reachable = await (opts.probe ?? probeSupabaseServer)();
  if (reachable) {
    lastFailedProbe = null;
    return "signout";
  }
  lastFailedProbe = opts.now;
  return "defer";
}

/** Stores the activity time at most once a minute (always when `force`). Returns true when written. */
export function recordActivity(
  now: number,
  store: Store | null = storage(),
  force = false,
): boolean {
  if (!store) return false;
  const last = readLastActivity(store);
  if (!force && last != null && now - last < ACTIVITY_THROTTLE_MS && now >= last) return false;
  try {
    store.setItem(LAST_ACTIVITY_KEY, String(now));
    return true;
  } catch {
    return false;
  }
}

/** Called after a successful sign-in: fresh activity time and no pending idle sign-out. */
export function beginActiveSession(now: number = Date.now(), store: Store | null = storage()) {
  try {
    store?.removeItem(IDLE_SIGNOUT_KEY);
  } catch {
    /* unavailable storage */
  }
  recordActivity(now, store, true);
}

export function markIdleSignOut(store: Store | null = storage()) {
  try {
    store?.setItem(IDLE_SIGNOUT_KEY, "1");
  } catch {
    /* unavailable storage */
  }
}

export function isIdleSignOutPending(store: Store | null = storage()): boolean {
  try {
    return store?.getItem(IDLE_SIGNOUT_KEY) === "1";
  } catch {
    return false;
  }
}

export function signedInAtOf(session: { user?: { last_sign_in_at?: string | null } } | null) {
  const raw = session?.user?.last_sign_in_at;
  const value = raw ? Date.parse(raw) : NaN;
  return Number.isFinite(value) ? value : null;
}

/**
 * Ends the login session after inactivity. Only the session and the account cache are removed; the
 * IndexedDB punch queue stays intact. When the session cannot be removed (offline token refresh),
 * the pending flag keeps the protected pages closed until the next sign-in.
 */
export async function signOutForInactivity(userId?: string | null) {
  const store = storage();
  markIdleSignOut(store);
  try {
    store?.removeItem("me-cache");
    if (userId) store?.removeItem(`me-cache:${userId}`);
  } catch {
    /* unavailable storage */
  }
  try {
    const { error } = await supabase.auth.signOut();
    if (error) await supabase.auth.signOut({ scope: "local" });
  } catch {
    /* the pending flag still keeps protected pages closed */
  }
}

const ACTIVITY_EVENTS = ["keydown", "pointerdown", "touchstart"] as const;

/**
 * Watches user activity while signed in. Calls `onExpire` once when more than the limit (12 hours by
 * default, see readIdleLimitMs) passed since the last activity and the server can be reached (see decideIdleExpiry; without
 * a connection the sign-out is deferred): checked every minute, when the tab becomes visible or focused, when the connection
 * returns, and before any new activity is recorded. An expired limit never counts the activity as fresh.
 */
export function useIdleSignOut(opts: {
  enabled: boolean;
  signedInAt: number | null;
  onExpire: () => void;
  probe?: () => Promise<boolean>;
}) {
  const { enabled, signedInAt } = opts;
  const onExpire = useRef(opts.onExpire);
  onExpire.current = opts.onExpire;
  const probe = useRef(opts.probe);
  probe.current = opts.probe;

  useEffect(() => {
    if (!enabled) return;
    let fired = false;
    let deciding = false;
    let cancelled = false;
    const expired = () => isIdleExpired(readLastActivity(), Date.now(), signedInAt, readIdleLimitMs());
    const evaluate = async () => {
      if (deciding || fired) return;
      deciding = true;
      try {
        const decision = await decideIdleExpiry({
          lastActivity: readLastActivity(),
          now: Date.now(),
          signedInAt,
          limitMs: readIdleLimitMs(),
          probe: probe.current,
        });
        // Po overení servera sa stav mohol zmeniť (aktivita v inej karte, odhlásenie): rozhodnutie sa potvrdí znova.
        if (decision === "signout" && !cancelled && !fired && expired()) {
          fired = true;
          onExpire.current();
        }
      } finally {
        deciding = false;
      }
    };
    const check = () => {
      if (fired) return true;
      if (!expired()) return false;
      void evaluate();
      return true;
    };
    const onActivity = () => {
      if (!check()) recordActivity(Date.now());
    };
    const onVisible = () => {
      if (typeof document === "undefined" || document.visibilityState === "visible") check();
    };
    const onOnline = () => {
      resetServerProbe();
      check();
    };
    if (!check() && readLastActivity() == null) recordActivity(Date.now(), undefined, true);
    for (const e of ACTIVITY_EVENTS) window.addEventListener(e, onActivity, { passive: true });
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("focus", onVisible);
    window.addEventListener("online", onOnline);
    const iv = setInterval(check, IDLE_CHECK_INTERVAL_MS);
    return () => {
      cancelled = true;
      for (const e of ACTIVITY_EVENTS) window.removeEventListener(e, onActivity);
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("focus", onVisible);
      window.removeEventListener("online", onOnline);
      clearInterval(iv);
    };
  }, [enabled, signedInAt]);
}
