// Automatické dotazovanie na server len počas skutočnej práce s aplikáciou.
//
// Databáza v Lovable Cloud sa uspí až po čase bez dopytov (čas nie je verejný a nedá sa nastaviť), pričom účtuje hodiny, keď je prebudená.
// Terminál a karta Tím sa pýtajú servera raz za minútu; okno nechané otvorené a viditeľné by databázu nepustilo spať celý deň.
// Preto sa dotazovanie zastaví po ACTIVE_WINDOW_MS bez pohybu myšou, klávesu alebo dotyku a po návrate sa dáta načítajú hneď.
// Skryté karty sa nedotazujú už dnes (štandardné správanie TanStack Query); tu ide o viditeľné, ale nepoužívané okná.
import { useEffect, useRef, useState } from "react";

/** Po tomto čase bez ovládania sa automatické dotazovanie zastaví. */
export const ACTIVE_WINDOW_MS = 10 * 60_000;

/** Interval pre `refetchInterval`: pri nečinnosti `false` (žiadne dotazovanie). */
export function pollInterval(baseMs: number, active: boolean): number | false {
  return active ? baseMs : false;
}

/** Po návrate z nečinnosti sa dáta načítajú hneď, ak sú staršie než bežný interval (alebo ešte neboli načítané: čas 0). */
export function needsRefreshOnResume(now: number, updatedAt: number, baseMs: number): boolean {
  return now - updatedAt >= baseMs;
}

type Timer = ReturnType<typeof setTimeout>;

export interface ActivityTracker {
  /** Zaznamená ovládanie (lacné: len uloží čas; časovač sa pri aktívnej práci nepreplánúva). */
  mark(): void;
  isActive(): boolean;
  dispose(): void;
}

/**
 * Sleduje, či sa s aplikáciou pracuje. Je neaktívny, keď uplynie `windowMs` od posledného `mark()`.
 * Jediný časovač sa pri vypršaní znovu naplánuje na zostávajúci čas, takže stovky udalostí myši nič nestoja;
 * oneskorený časovač (uspatý počítač) sa vyhodnotí podľa skutočného času.
 */
export function createActivityTracker(opts: {
  windowMs: number;
  onChange: (active: boolean) => void;
  now?: () => number;
  setTimer?: (fn: () => void, ms: number) => Timer;
  clearTimer?: (timer: Timer) => void;
}): ActivityTracker {
  const now = opts.now ?? (() => Date.now());
  const setTimer = opts.setTimer ?? ((fn, ms) => setTimeout(fn, ms));
  const clearTimer = opts.clearTimer ?? ((timer) => clearTimeout(timer));
  let last = now();
  let active = true;
  let disposed = false;
  let timer: Timer | undefined;

  function arm() {
    if (timer !== undefined) clearTimer(timer);
    timer = setTimer(check, Math.max(1, last + opts.windowMs - now()));
  }
  function check() {
    timer = undefined;
    if (disposed) return;
    if (now() - last >= opts.windowMs) {
      if (active) {
        active = false;
        opts.onChange(false);
      }
    } else {
      arm();
    }
  }
  arm();

  return {
    mark() {
      if (disposed) return;
      last = now();
      if (!active) {
        active = true;
        opts.onChange(true);
        arm();
      }
    },
    isActive: () => active,
    dispose() {
      disposed = true;
      if (timer !== undefined) clearTimer(timer);
      timer = undefined;
    },
  };
}

const ACTIVITY_EVENTS = ["pointerdown", "pointermove", "keydown", "wheel", "touchstart"] as const;

/** `true`, kým sa s aplikáciou pracuje (od načítania stránky, potom podľa ovládania); po `windowMs` bez ovládania `false`. */
export function useUserActive(windowMs: number = ACTIVE_WINDOW_MS): boolean {
  const [active, setActive] = useState(true);
  useEffect(() => {
    const tracker = createActivityTracker({ windowMs, onChange: setActive });
    const mark = () => tracker.mark();
    const onVisible = () => {
      if (document.visibilityState === "visible") tracker.mark();
    };
    for (const e of ACTIVITY_EVENTS) window.addEventListener(e, mark, { passive: true });
    window.addEventListener("focus", mark);
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      for (const e of ACTIVITY_EVENTS) window.removeEventListener(e, mark);
      window.removeEventListener("focus", mark);
      document.removeEventListener("visibilitychange", onVisible);
      tracker.dispose();
    };
  }, [windowMs]);
  return active;
}

/** Po prechode z nečinnosti späť do práce načíta dáta hneď, ak sú staršie než `baseMs`. */
export function useRefetchOnResume(opts: {
  active: boolean;
  enabled: boolean;
  updatedAt: number;
  baseMs: number;
  refetch: () => unknown;
}): void {
  const { active } = opts;
  const latest = useRef(opts);
  latest.current = opts;
  const wasActive = useRef(active);
  useEffect(() => {
    const before = wasActive.current;
    wasActive.current = active;
    const o = latest.current;
    if (!before && active && o.enabled && needsRefreshOnResume(Date.now(), o.updatedAt, o.baseMs)) void o.refetch();
  }, [active]);
}
