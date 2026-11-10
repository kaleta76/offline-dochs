// Automatic sign-out after a period without user activity (12 hours by default, set per device in Správa).
//
// The time of the last user activity (key, click, touch, punch) is stored in localStorage under
// `last_activity_at`, written at most once a minute. Sign-out only ends the login session: the
// offline punch queue in IndexedDB is never touched, so waiting punches are sent after the next
// sign-in of the same person.
import { useEffect, useRef } from "react";
import { supabase } from "@/integrations/supabase/client";

const HOUR_MS = 60 * 60 * 1000;
export const DEFAULT_IDLE_LIMIT_HOURS = 12;
export const IDLE_LIMIT_MS = DEFAULT_IDLE_LIMIT_HOURS * HOUR_MS;
/** Povolené hodnoty limitu nečinnosti v hodinách (kratší limit než pol hodiny by pri bežnej práci odhlasoval zbytočne). */
export const IDLE_LIMIT_OPTIONS_HOURS = [0.5, 1, 2, 4, 8, 12, 24, 48, 72] as const;
/** Kľúč v localStorage: limit nečinnosti pre toto zariadenie (prehliadač), nastavuje ho správca v Správe. */
export const IDLE_LIMIT_KEY = "idle_limit_hours";
export const ACTIVITY_THROTTLE_MS = 60 * 1000;
export const IDLE_CHECK_INTERVAL_MS = 60 * 1000;
export const LAST_ACTIVITY_KEY = "last_activity_at";
/** Set while an idle sign-out is in progress or could not remove the session (for example offline). */
export const IDLE_SIGNOUT_KEY = "idle_signout_pending";
export const IDLE_MESSAGE = "Boli ste odhlásený z dôvodu nečinnosti.";

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

/** Limit nečinnosti tohto zariadenia v hodinách; bez platného nastavenia 12 hodín. */
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

/** Uloží limit nečinnosti zariadenia. Neplatná hodnota sa nezapíše; predvolená hodnota nastavenie odstráni. */
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
 * default, see readIdleLimitMs) passed since the last activity: checked every minute, when the tab becomes visible or focused, and before any
 * new activity is recorded.
 */
export function useIdleSignOut(opts: {
  enabled: boolean;
  signedInAt: number | null;
  onExpire: () => void;
}) {
  const { enabled, signedInAt } = opts;
  const onExpire = useRef(opts.onExpire);
  onExpire.current = opts.onExpire;

  useEffect(() => {
    if (!enabled) return;
    let fired = false;
    const check = () => {
      if (fired) return true;
      if (isIdleExpired(readLastActivity(), Date.now(), signedInAt, readIdleLimitMs())) {
        fired = true;
        onExpire.current();
        return true;
      }
      return false;
    };
    const onActivity = () => {
      if (!check()) recordActivity(Date.now());
    };
    const onVisible = () => {
      if (typeof document === "undefined" || document.visibilityState === "visible") check();
    };
    if (!check() && readLastActivity() == null) recordActivity(Date.now(), undefined, true);
    for (const e of ACTIVITY_EVENTS) window.addEventListener(e, onActivity, { passive: true });
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("focus", onVisible);
    const iv = setInterval(check, IDLE_CHECK_INTERVAL_MS);
    return () => {
      for (const e of ACTIVITY_EVENTS) window.removeEventListener(e, onActivity);
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("focus", onVisible);
      clearInterval(iv);
    };
  }, [enabled, signedInAt]);
}
