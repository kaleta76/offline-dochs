import { describe, expect, it } from "vitest";
import { confirmationMatches, describeContents, parseDeleteResult, parseSummary } from "./organization-delete";

describe("parseSummary", () => {
  it("prevezme odpoveď databázy", () => {
    expect(parseSummary({ name: "TEST A", is_test: true, protected: false, users: 3, punches: 120, devices: 2 })).toEqual({
      name: "TEST A", isTest: true, protectedOrganization: false, users: 3, punches: 120, devices: 2,
    });
  });
  it("neznáme alebo chybné hodnoty nahradí bezpečne", () => {
    expect(parseSummary({ name: "X", users: "3", punches: -1, devices: NaN })).toEqual({
      name: "X", isTest: false, protectedOrganization: false, users: 0, punches: 0, devices: 0,
    });
  });
  it("organizáciu bez názvu odmietne", () => {
    expect(parseSummary(null)).toBeNull();
    expect(parseSummary([])).toBeNull();
    expect(parseSummary({ users: 1 })).toBeNull();
  });
});

describe("confirmationMatches", () => {
  it("vyžaduje presný názov", () => {
    expect(confirmationMatches("TEST - nepoužívať", "TEST - nepoužívať")).toBe(true);
    expect(confirmationMatches("TEST - nepoužívať", "  TEST - nepoužívať ")).toBe(true);
  });
  it("rozlišuje veľkosť písmen aj pomlčky", () => {
    expect(confirmationMatches("TEST A", "test a")).toBe(false);
    expect(confirmationMatches("TEST - A", "TEST – A")).toBe(false);
    expect(confirmationMatches("TEST A", "TEST")).toBe(false);
  });
  it("prázdne potvrdenie nikdy nesedí", () => {
    expect(confirmationMatches("", "")).toBe(false);
    expect(confirmationMatches("   ", "   ")).toBe(false);
    expect(confirmationMatches("TEST A", "")).toBe(false);
  });
});

describe("describeContents", () => {
  it("skloňuje podľa počtu", () => {
    expect(describeContents({ users: 1, punches: 1, devices: 1 })).toBe("1 účet, 1 razenie a 1 zariadenie");
    expect(describeContents({ users: 3, punches: 2, devices: 4 })).toBe("3 účty, 2 razenia a 4 zariadenia");
    expect(describeContents({ users: 5, punches: 0, devices: 12 })).toBe("5 účtov, 0 razení a 12 zariadení");
  });
});

describe("parseDeleteResult", () => {
  it("číta počty a zvyšok ignoruje", () => {
    expect(parseDeleteResult({ name: "TEST A", users: 3, punches: 4, devices: 3 })).toEqual({ users: 3, punches: 4, devices: 3 });
    expect(parseDeleteResult(null)).toEqual({ users: 0, punches: 0, devices: 0 });
  });
});
