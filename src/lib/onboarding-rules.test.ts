import { describe, expect, it } from "vitest";
import {
  enrollSchema,
  loginSchema,
  orgCodeSchema,
  provisionSchema,
  recoverSchema,
  registerSchema,
  strongPasswordSchema,
} from "./onboarding-rules";
import { REGISTRATION_CODE_SHA256 } from "./registration-code";

const base = { name: " Firma A ", number: "4002012", password: "dlhe-heslo-12345" };

describe("registrácia organizácie: vstupy", () => {
  it("prijme úplný vstup a upraví názov", () => {
    const r = registerSchema.parse({ code: "ABCD-EFGH-JKMN", accepted: true, ...base });
    expect(r.name).toBe("Firma A");
  });
  it("vyžaduje súhlas so zodpovednosťou", () => {
    expect(
      registerSchema.safeParse({ code: "ABCD-EFGH-JKMN", accepted: false, ...base }).success,
    ).toBe(false);
    expect(registerSchema.safeParse({ code: "ABCD-EFGH-JKMN", ...base }).success).toBe(false);
  });
  it("odmietne krátke heslo a neplatné osobné číslo", () => {
    expect(strongPasswordSchema.safeParse("kratke").success).toBe(false);
    expect(
      registerSchema.safeParse({
        code: "ABCD-EFGH-JKMN",
        accepted: true,
        ...base,
        password: "kratke",
      }).success,
    ).toBe(false);
    expect(
      registerSchema.safeParse({ code: "ABCD-EFGH-JKMN", accepted: true, ...base, number: "12345" })
        .success,
    ).toBe(false);
  });
});

describe("kód organizácie a prihlásenie", () => {
  it("normalizuje kód organizácie", () => {
    expect(orgCodeSchema.parse("a1b2-c3d4")).toBe("A1B2C3D4");
    expect(orgCodeSchema.safeParse("a1b2").success).toBe(false);
    expect(orgCodeSchema.safeParse("zzzzzzzz").success).toBe(false);
  });
  it("prihlásenie nevyžaduje 12 znakov (staršie heslá)", () => {
    expect(
      loginSchema.safeParse({ orgCode: "A1B2-C3D4", number: "4002012", password: "x" }).success,
    ).toBe(true);
  });
  it("prvé prihlásenie vyžaduje nové heslo s 12 znakmi", () => {
    const pin = "ABCD-EFGH-JKMN";
    expect(
      enrollSchema.safeParse({
        orgCode: "A1B2C3D4",
        number: "4002012",
        pin,
        password: "dlhe-heslo-12345",
      }).success,
    ).toBe(true);
    expect(
      enrollSchema.safeParse({ orgCode: "A1B2C3D4", number: "4002012", pin, password: "kratke" })
        .success,
    ).toBe(false);
  });
  it("obnova vyžaduje obnovovací kód", () => {
    expect(
      recoverSchema.safeParse({
        orgCode: "A1B2C3D4",
        number: "4002012",
        recoveryCode: "ABCD",
        password: "dlhe-heslo-12345",
      }).success,
    ).toBe(false);
  });
});

describe("vydanie PIN-ov", () => {
  it("povolí 1 až 25 čísel naraz", () => {
    expect(provisionSchema.safeParse({ numbers: [], reset: false }).success).toBe(false);
    expect(provisionSchema.safeParse({ numbers: ["4002012"], reset: false }).success).toBe(true);
    const many = Array.from({ length: 26 }, (_, i) => String(4000000 + i));
    expect(provisionSchema.safeParse({ numbers: many, reset: false }).success).toBe(false);
  });
});

describe("odtlačok registračného kódu", () => {
  it("je 64 hexadecimálnych znakov", () => {
    expect(/^[0-9a-f]{64}$/.test(REGISTRATION_CODE_SHA256)).toBe(true);
  });
});
