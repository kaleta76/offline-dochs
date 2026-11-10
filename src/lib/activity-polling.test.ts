import { describe, expect, it } from "vitest";
import { ACTIVE_WINDOW_MS, createActivityTracker, needsRefreshOnResume, pollInterval } from "./activity-polling";

type Handle = ReturnType<typeof setTimeout>;

/** Vlastné hodiny a časovače: čas sa posúva ručne, časovače sa spúšťajú v poradí termínu. */
function fakeEnv(windowMs = ACTIVE_WINDOW_MS) {
  let t = 1_000_000;
  let next = 1;
  const timers = new Map<number, { at: number; fn: () => void }>();
  const changes: boolean[] = [];
  const tracker = createActivityTracker({
    windowMs,
    onChange: (a) => changes.push(a),
    now: () => t,
    setTimer: (fn, ms) => {
      const id = next++;
      timers.set(id, { at: t + ms, fn });
      return id as unknown as Handle;
    },
    clearTimer: (h) => {
      timers.delete(h as unknown as number);
    },
  });
  const fireDue = () => {
    for (;;) {
      const due = [...timers.entries()].filter(([, x]) => x.at <= t).sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) return;
      timers.delete(due[0]);
      due[1].fn();
    }
  };
  return {
    tracker,
    changes,
    timers,
    /** Posun času po krokoch tak, aby sa časovače spustili vo svojom termíne. */
    advance(ms: number) {
      const target = t + ms;
      for (;;) {
        const next = [...timers.values()].map((x) => x.at).sort((a, b) => a - b)[0];
        if (next === undefined || next > target) break;
        t = Math.max(t, next);
        fireDue();
      }
      t = target;
    },
    /** Skok času bez spúšťania časovačov v ich termíne (uspatý počítač): časovač sa spustí až potom. */
    jump(ms: number) {
      t += ms;
      fireDue();
    },
  };
}

const MIN = 60_000;

describe("createActivityTracker", () => {
  it("začína ako aktívny a bez ovládania sa po presne windowMs stane neaktívnym", () => {
    const env = fakeEnv();
    expect(env.tracker.isActive()).toBe(true);
    env.advance(ACTIVE_WINDOW_MS - 1);
    expect(env.tracker.isActive()).toBe(true);
    expect(env.changes).toEqual([]);
    env.advance(1);
    expect(env.tracker.isActive()).toBe(false);
    expect(env.changes).toEqual([false]);
  });

  it("ovládanie predĺži aktívny čas od posledného zaznamenania", () => {
    const env = fakeEnv();
    env.advance(9 * MIN);
    env.tracker.mark();
    env.advance(10 * MIN - 1);
    expect(env.tracker.isActive()).toBe(true);
    env.advance(1);
    expect(env.tracker.isActive()).toBe(false);
    expect(env.changes).toEqual([false]);
  });

  it("po nečinnosti ovládanie znova zapne a po ďalších windowMs znova vypne", () => {
    const env = fakeEnv();
    env.advance(ACTIVE_WINDOW_MS);
    expect(env.changes).toEqual([false]);
    env.tracker.mark();
    expect(env.tracker.isActive()).toBe(true);
    expect(env.changes).toEqual([false, true]);
    env.advance(ACTIVE_WINDOW_MS);
    expect(env.changes).toEqual([false, true, false]);
  });

  it("množstvo udalostí nevytvára ďalšie časovače", () => {
    const env = fakeEnv();
    for (let i = 0; i < 500; i++) {
      env.advance(100);
      env.tracker.mark();
    }
    expect(env.timers.size).toBe(1);
    expect(env.changes).toEqual([]);
  });

  it("oneskorený časovač (uspatý počítač) sa vyhodnotí podľa skutočného času", () => {
    const env = fakeEnv();
    env.advance(MIN);
    env.tracker.mark();
    env.jump(3 * 60 * MIN);
    expect(env.tracker.isActive()).toBe(false);
    expect(env.changes).toEqual([false]);
  });

  it("po dispose už nič neohlási a nezostane žiadny časovač", () => {
    const env = fakeEnv();
    env.tracker.dispose();
    expect(env.timers.size).toBe(0);
    env.advance(ACTIVE_WINDOW_MS * 2);
    env.tracker.mark();
    expect(env.changes).toEqual([]);
  });

  it("kratšie okno sa riadi zadanou hodnotou", () => {
    const env = fakeEnv(2 * MIN);
    env.advance(2 * MIN - 1);
    expect(env.tracker.isActive()).toBe(true);
    env.advance(1);
    expect(env.tracker.isActive()).toBe(false);
  });
});

describe("pollInterval", () => {
  it("pri práci vráti bežný interval, pri nečinnosti false", () => {
    expect(pollInterval(60_000, true)).toBe(60_000);
    expect(pollInterval(60_000, false)).toBe(false);
  });
});

describe("needsRefreshOnResume", () => {
  it("načíta hneď, ak údaje ešte neboli načítané alebo sú staršie než interval", () => {
    expect(needsRefreshOnResume(1_000_000, 0, 60_000)).toBe(true);
    expect(needsRefreshOnResume(1_000_000, 1_000_000 - 60_000, 60_000)).toBe(true);
    expect(needsRefreshOnResume(1_000_000, 1_000_000 - 3 * 60 * 60_000, 60_000)).toBe(true);
  });
  it("čerstvé údaje nenačítava znova", () => {
    expect(needsRefreshOnResume(1_000_000, 1_000_000 - 59_999, 60_000)).toBe(false);
    expect(needsRefreshOnResume(1_000_000, 1_000_000, 60_000)).toBe(false);
  });
});
