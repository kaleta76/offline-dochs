import { describe, expect, it } from "vitest";
import {
  NUMBER_KEY,
  browserStorage,
  forgetNumber,
  readRememberedNumber,
  rememberNumber,
  type NumberStorage,
} from "./remembered-number";

function memoryStorage(initial: Record<string, string> = {}): NumberStorage & { data: Record<string, string> } {
  const data = { ...initial };
  return {
    data,
    getItem: (k) => data[k] ?? null,
    setItem: (k, v) => {
      data[k] = String(v);
    },
    removeItem: (k) => {
      delete data[k];
    },
  };
}

const brokenStorage: NumberStorage = {
  getItem: () => {
    throw new Error("zablokované");
  },
  setItem: () => {
    throw new Error("zablokované");
  },
  removeItem: () => {
    throw new Error("zablokované");
  },
};

describe("zapamätané osobné číslo", () => {
  it("uloží číslo po prihlásení a vráti ho", () => {
    const s = memoryStorage();
    rememberNumber(s, "4002012", true);
    expect(s.data[NUMBER_KEY]).toBe("4002012");
    expect(readRememberedNumber(s)).toBe("4002012");
  });

  it("pri vypnutom zapamätaní číslo nezapíše a už zapamätané zmaže", () => {
    const s = memoryStorage({ [NUMBER_KEY]: "4002012" });
    rememberNumber(s, "4002012", false);
    expect(s.data[NUMBER_KEY]).toBeUndefined();
    expect(readRememberedNumber(s)).toBe("");
  });

  it("neuloží neplatné číslo a predchádzajúce zapamätané zmaže", () => {
    const s = memoryStorage({ [NUMBER_KEY]: "4002012" });
    for (const bad of ["", "123456", "123456789", "40020a2", " 4002012", "4002012 "]) {
      rememberNumber(s, bad, true);
      expect(s.data[NUMBER_KEY]).toBeUndefined();
      s.data[NUMBER_KEY] = "4002012";
    }
  });

  it("prijme 7- aj 8-miestne číslo", () => {
    const s = memoryStorage();
    rememberNumber(s, "1234567", true);
    expect(readRememberedNumber(s)).toBe("1234567");
    rememberNumber(s, "12345678", true);
    expect(readRememberedNumber(s)).toBe("12345678");
  });

  it("poškodená alebo cudzia hodnota v úložisku sa nepredvyplní", () => {
    for (const bad of ["abc", "12", "<script>", "4002012;DROP", "123456789"]) {
      expect(readRememberedNumber(memoryStorage({ [NUMBER_KEY]: bad }))).toBe("");
    }
    expect(readRememberedNumber(memoryStorage())).toBe("");
  });

  it("forgetNumber zmaže zapamätané číslo a iné kľúče nechá", () => {
    const s = memoryStorage({ [NUMBER_KEY]: "4002012", "org-code": "ABCD-1234" });
    forgetNumber(s);
    expect(s.data[NUMBER_KEY]).toBeUndefined();
    expect(s.data["org-code"]).toBe("ABCD-1234");
  });

  it("neukladá nič iné než číslo (nikdy heslo)", () => {
    const s = memoryStorage();
    rememberNumber(s, "4002012", true);
    expect(Object.keys(s.data)).toEqual([NUMBER_KEY]);
    expect(Object.values(s.data)).toEqual(["4002012"]);
  });

  it("bez úložiska alebo so zablokovaným úložiskom nič nespadne", () => {
    expect(readRememberedNumber(null)).toBe("");
    expect(() => rememberNumber(null, "4002012", true)).not.toThrow();
    expect(() => forgetNumber(null)).not.toThrow();
    expect(readRememberedNumber(brokenStorage)).toBe("");
    expect(() => rememberNumber(brokenStorage, "4002012", true)).not.toThrow();
    expect(() => rememberNumber(brokenStorage, "4002012", false)).not.toThrow();
    expect(() => forgetNumber(brokenStorage)).not.toThrow();
  });

  it("browserStorage vráti úložisko prehliadača, v ktorom číslo prežije", () => {
    const s = browserStorage();
    expect(s).not.toBeNull();
    rememberNumber(s, "4002012", true);
    expect(window.localStorage.getItem(NUMBER_KEY)).toBe("4002012");
    forgetNumber(s);
    expect(window.localStorage.getItem(NUMBER_KEY)).toBeNull();
  });
});
