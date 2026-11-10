import { describe, expect, it } from "vitest";
import {
  DEFAULT_IDLE_LIMIT_HOURS,
  IDLE_LIMIT_KEY,
  IDLE_LIMIT_MS,
  IDLE_LIMIT_OPTIONS_HOURS,
  idleLimitLabel,
  isIdleExpired,
  mirrorOrganizationIdleLimit,
  parseIdleLimitHours,
  readIdleLimitHours,
  readIdleLimitMs,
  writeIdleLimitHours,
} from "./idle-timeout";

const HOUR = 60 * 60 * 1000;

function fakeStore(initial: Record<string, string> = {}) {
  const data = new Map(Object.entries(initial));
  return {
    getItem: (k: string) => data.get(k) ?? null,
    setItem: (k: string, v: string) => void data.set(k, v),
    removeItem: (k: string) => void data.delete(k),
    data,
  };
}

describe("limit nečinnosti zariadenia", () => {
  it("bez nastavenia platí predvolených 12 hodín", () => {
    const store = fakeStore();
    expect(readIdleLimitHours(store)).toBe(12);
    expect(readIdleLimitMs(store)).toBe(IDLE_LIMIT_MS);
    expect(DEFAULT_IDLE_LIMIT_HOURS).toBe(12);
  });

  it("uložená povolená hodnota sa použije", () => {
    expect(readIdleLimitHours(fakeStore({ [IDLE_LIMIT_KEY]: "4" }))).toBe(4);
    expect(readIdleLimitHours(fakeStore({ [IDLE_LIMIT_KEY]: "0.5" }))).toBe(0.5);
    expect(readIdleLimitMs(fakeStore({ [IDLE_LIMIT_KEY]: "24" }))).toBe(24 * HOUR);
  });

  it("neplatná alebo nepovolená hodnota vráti predvolenú", () => {
    for (const bad of ["", "abc", "0", "-2", "5", "1000", "NaN", "Infinity"]) {
      expect(readIdleLimitHours(fakeStore({ [IDLE_LIMIT_KEY]: bad }))).toBe(12);
    }
    expect(readIdleLimitHours(null)).toBe(12);
  });

  it("parseIdleLimitHours prijme len hodnoty zo zoznamu", () => {
    expect(parseIdleLimitHours("8")).toBe(8);
    expect(parseIdleLimitHours(" 0,5 ")).toBe(0.5);
    expect(parseIdleLimitHours(72)).toBe(72);
    expect(parseIdleLimitHours(3)).toBeNull();
    expect(parseIdleLimitHours(null)).toBeNull();
    expect(parseIdleLimitHours({})).toBeNull();
    for (const h of IDLE_LIMIT_OPTIONS_HOURS) expect(parseIdleLimitHours(h)).toBe(h);
  });

  it("zápis uloží platnú hodnotu a predvolenú odstráni", () => {
    const store = fakeStore();
    expect(writeIdleLimitHours(2, store)).toBe(true);
    expect(store.data.get(IDLE_LIMIT_KEY)).toBe("2");
    expect(writeIdleLimitHours(12, store)).toBe(true);
    expect(store.data.has(IDLE_LIMIT_KEY)).toBe(false);
  });

  it("zápis nepovolenej hodnoty nič nezmení", () => {
    const store = fakeStore({ [IDLE_LIMIT_KEY]: "4" });
    expect(writeIdleLimitHours(5, store)).toBe(false);
    expect(writeIdleLimitHours(Number.NaN, store)).toBe(false);
    expect(writeIdleLimitHours(2, null)).toBe(false);
    expect(store.data.get(IDLE_LIMIT_KEY)).toBe("4");
  });

  it("nedostupné úložisko neprerušuje prácu", () => {
    const broken = {
      getItem: () => {
        throw new Error("blocked");
      },
      setItem: () => {
        throw new Error("blocked");
      },
      removeItem: () => {
        throw new Error("blocked");
      },
    };
    expect(readIdleLimitHours(broken)).toBe(12);
    expect(writeIdleLimitHours(2, broken)).toBe(false);
  });

  it("isIdleExpired použije zadaný limit, bez neho 12 hodín", () => {
    const t0 = Date.parse("2026-11-10T06:00:00Z");
    expect(isIdleExpired(t0, t0 + 5 * HOUR, null, 4 * HOUR)).toBe(true);
    expect(isIdleExpired(t0, t0 + 3 * HOUR, null, 4 * HOUR)).toBe(false);
    expect(isIdleExpired(t0, t0 + 5 * HOUR)).toBe(false);
    expect(isIdleExpired(t0, t0 + 13 * HOUR)).toBe(true);
    // chýbajúca posledná aktivita nikdy neodhlasuje
    expect(isIdleExpired(null, t0, null, 1)).toBe(false);
    // novšie prihlásenie prebije starú aktivitu
    expect(isIdleExpired(t0, t0 + 5 * HOUR, t0 + 4.5 * HOUR, 4 * HOUR)).toBe(false);
  });

  it("popisy limitov po slovensky", () => {
    expect(idleLimitLabel(0.5)).toBe("30 minút");
    expect(idleLimitLabel(1)).toBe("1 hodina");
    expect(idleLimitLabel(2)).toBe("2 hodiny");
    expect(idleLimitLabel(4)).toBe("4 hodiny");
    expect(idleLimitLabel(8)).toBe("8 hodín");
    expect(idleLimitLabel(12)).toBe("12 hodín");
    expect(idleLimitLabel(72)).toBe("72 hodín");
  });
});

describe("kópia limitu organizácie v zariadení", () => {
  it("platná hodnota z databázy sa zapíše a predvolená kópiu odstráni", () => {
    const store = fakeStore();
    expect(mirrorOrganizationIdleLimit(24, store)).toBe(true);
    expect(readIdleLimitHours(store)).toBe(24);
    expect(mirrorOrganizationIdleLimit(12, store)).toBe(true);
    expect(store.data.has(IDLE_LIMIT_KEY)).toBe(false);
    expect(readIdleLimitHours(store)).toBe(12);
  });

  it("zmena organizácie na inú hodnotu prepíše starú kópiu", () => {
    const store = fakeStore({ [IDLE_LIMIT_KEY]: "4" });
    expect(mirrorOrganizationIdleLimit(72, store)).toBe(true);
    expect(readIdleLimitHours(store)).toBe(72);
  });

  it("chýbajúca alebo neplatná hodnota kópiu nemení", () => {
    const store = fakeStore({ [IDLE_LIMIT_KEY]: "8" });
    for (const bad of [undefined, null, "abc", 5, Number.NaN, {}]) {
      expect(mirrorOrganizationIdleLimit(bad, store)).toBe(false);
    }
    expect(readIdleLimitHours(store)).toBe(8);
    expect(mirrorOrganizationIdleLimit(24, null)).toBe(false);
  });
});
