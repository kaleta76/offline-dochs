import { beforeEach, describe, expect, it } from "vitest";
import { migrateProfileCaches, personnelLabel, personnelNumberSchema } from "./personnel";

describe("SAP personnel numbers", () => {
  it("accepts exactly 7 digits preserving leading zeros", () => {
    expect(personnelNumberSchema.parse("0012345")).toBe("0012345");
  });
  it("accepts exactly 8 digits preserving leading zeros", () => {
    expect(personnelNumberSchema.parse("00123456")).toBe("00123456");
  });
  it.each(["123456", "123456789", "1234abc", "1234567 "])("rejects invalid SAP number %s", value => {
    expect(personnelNumberSchema.safeParse(value).success).toBe(false);
  });
  it("never falls back to a name for a missing number", () => {
    const profile = { id: "aabbccdd-1234", sap_id: null, full_name: "Private name" };
    expect(personnelLabel(profile)).toBe("Bez osobného čísla · aabbccdd");
  });
});

describe("pseudonymous offline cache", () => {
  beforeEach(() => localStorage.clear());
  it("removes legacy names and emails while preserving offline keys and numbers", () => {
    localStorage.setItem("me-cache:owner", JSON.stringify({
      roles: ["employee"], profile: { id: "owner", full_name: "Private name", email: "private@example.test",
        sap_id: "00123456", department: null, daily_fund: 7.5, organization_id: "org" },
      organization: { id: "org", name: "Company" },
    }));
    localStorage.setItem("unrelated", "preserved");
    migrateProfileCaches(localStorage);
    const cache = JSON.parse(localStorage.getItem("me-cache:owner") ?? "null");
    expect(cache.profile).not.toHaveProperty("full_name");
    expect(cache.profile).not.toHaveProperty("email");
    expect(cache.profile.sap_id).toBe("00123456");
    expect(localStorage.getItem("unrelated")).toBe("preserved");
  });
});