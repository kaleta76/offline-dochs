import { describe, expect, it } from "vitest";
import {
  formatCode,
  hashSecret,
  isWellFormedCode,
  normalizeCode,
  orgCodeOf,
  orgPrefixRange,
  randomCode,
  randomSalt,
  safeEqualHex,
  sha256Hex,
} from "./credentials";

describe("tajné kódy", () => {
  it("generuje kód požadovanej dĺžky len zo znakov bez I, L, O, U", () => {
    for (let i = 0; i < 50; i++) {
      const code = randomCode(20);
      expect(code).toHaveLength(20);
      expect(/^[0-9A-HJKMNP-TV-Z]{20}$/.test(code)).toBe(true);
    }
  });

  it("dva kódy sa nezhodujú", () => {
    expect(randomCode(20) === randomCode(20)).toBe(false);
  });

  it("normalizuje preklepy a oddeľovače", () => {
    expect(normalizeCode(" abcd-efgh jkmn ")).toBe("ABCDEFGHJKMN");
    expect(normalizeCode("O0Il1")).toBe("00111");
  });

  it("formátuje po štyroch znakoch", () => {
    expect(formatCode("ABCDEFGHJKMN")).toBe("ABCD-EFGH-JKMN");
    expect(formatCode("ABCDEFGH")).toBe("ABCD-EFGH");
  });

  it("rozpozná správne tvarovaný kód", () => {
    const code = randomCode(12);
    expect(isWellFormedCode(formatCode(code), 12)).toBe(true);
    expect(isWellFormedCode(code.slice(1), 12)).toBe(false);
    expect(isWellFormedCode("ABCD-EFGH-JKM!", 12)).toBe(false);
  });

  it("SHA-256 súhlasí so známym vektorom", async () => {
    expect(await sha256Hex("abc")).toBe(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    );
  });

  it("odtlačok závisí od soli aj od tajomstva", async () => {
    const salt = randomSalt();
    const a = await hashSecret("TAJOMSTVO", salt, 1000);
    expect(a).toHaveLength(64);
    expect(await hashSecret("TAJOMSTVO", salt, 1000)).toBe(a);
    expect(await hashSecret("INE", salt, 1000)).not.toBe(a);
    expect(await hashSecret("TAJOMSTVO", randomSalt(), 1000)).not.toBe(a);
  });

  it("porovnanie rozlišuje rôzne a rovnaké reťazce", () => {
    expect(safeEqualHex("abcd", "abcd")).toBe(true);
    expect(safeEqualHex("abcd", "abce")).toBe(false);
    expect(safeEqualHex("abcd", "abc")).toBe(false);
  });

  it("kód organizácie je prvých 8 znakov UUID a vie sa vrátiť na rozsah", () => {
    const id = "a1b2c3d4-0000-4000-8000-000000000001";
    expect(orgCodeOf(id)).toBe("A1B2C3D4");
    expect(orgPrefixRange("a1b2-c3d4")).toEqual({
      lo: "a1b2c3d4-0000-0000-0000-000000000000",
      hi: "a1b2c3d4-ffff-ffff-ffff-ffffffffffff",
    });
    expect(orgPrefixRange("xyz")).toBeNull();
  });
});
