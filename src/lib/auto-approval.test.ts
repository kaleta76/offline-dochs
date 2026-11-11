import { describe, expect, it } from "vitest";
import {
  AUTO_APPROVAL_DAYS,
  AUTO_APPROVAL_PER_DAY,
  autoApprovalRows,
  autoApprovalSince,
  isAutoApprovalUnavailable,
  type AutoApprovalPair,
  type AutoApprovalPerson,
} from "./auto-approval";

const ME = "m0000000-0000-4000-8000-000000000001";
const OTHER_MGR = "m0000000-0000-4000-8000-000000000002";
const person = (id: string, sap: string, manager: string | null): AutoApprovalPerson => ({
  id,
  sap_id: sap,
  department: null,
  manager_id: manager,
});
const E1 = person("e1", "9000003", ME);
const E2 = person("e2", "9000002", ME);
const E3 = person("e3", "9000004", OTHER_MGR);
const SELF = person(ME, "9000001", null);
const pair = (user: string, manager: string): AutoApprovalPair => ({
  user_id: user,
  manager_id: manager,
  enabled_at: "2026-11-10T08:00:00Z",
});

describe("autoApprovalRows", () => {
  it("vedúci vidí len svojich priamych podriadených, zoradených podľa osobného čísla", () => {
    const rows = autoApprovalRows(ME, false, [E1, E2, E3, SELF], []);
    expect(rows.map((r) => r.person.id)).toEqual(["e2", "e1"]);
  });

  it("vedúci môže zapnúť vypnutú voľbu, vypnúť nemôže nič, čo nie je zapnuté", () => {
    const [row] = autoApprovalRows(ME, false, [E1], []);
    expect(row).toMatchObject({ enabled: false, canEnable: true, canDisable: false });
  });

  it("zapnutú voľbu vedúci vypne, znova zapnúť netreba", () => {
    const [row] = autoApprovalRows(ME, false, [E1], [pair("e1", ME)]);
    expect(row).toMatchObject({
      enabled: true,
      canEnable: false,
      canDisable: true,
      enabledBy: ME,
      enabledAt: "2026-11-10T08:00:00Z",
    });
  });

  it("správca vidí cudzie zapnuté voľby a vie ich vypnúť, ale nie zapnúť", () => {
    const rows = autoApprovalRows(ME, true, [E1, E3, SELF], [pair("e3", OTHER_MGR)]);
    const byId = Object.fromEntries(rows.map((r) => [r.person.id, r]));
    expect(Object.keys(byId).sort()).toEqual(["e1", "e3"]);
    expect(byId["e3"]).toMatchObject({ enabled: true, canEnable: false, canDisable: true });
    // Priamy podriadený správcu: zapnúť smie ako priamy vedúci.
    expect(byId["e1"]).toMatchObject({ enabled: false, canEnable: true, canDisable: false });
  });

  it("správca nevidí cudzích zamestnancov bez zapnutej voľby", () => {
    const rows = autoApprovalRows(ME, true, [E3], []);
    expect(rows).toEqual([]);
  });

  it("nikto nevidí seba (voľbu si nikto nezapne sám sebe), ani keby mal sám seba za vedúceho", () => {
    const selfManaged = person(ME, "9000001", ME);
    expect(autoApprovalRows(ME, false, [selfManaged], [])).toEqual([]);
    expect(autoApprovalRows(ME, true, [selfManaged], [pair(ME, ME)])).toEqual([]);
  });

  it("zamestnanec bez osobného čísla sa nezrúti pri zoraďovaní", () => {
    const noSap: AutoApprovalPerson = { ...E1, id: "e9", sap_id: null };
    expect(autoApprovalRows(ME, false, [E1, noSap], []).map((r) => r.person.id)).toEqual([
      "e9",
      "e1",
    ]);
  });
});

describe("limity a okno", () => {
  it("konštanty zodpovedajú rozhodnutiu majiteľa a migrácii 0013", () => {
    expect(AUTO_APPROVAL_DAYS).toBe(14);
    expect(AUTO_APPROVAL_PER_DAY).toBe(5);
  });
  it("okno začína presne 14 dní pred zadaným časom", () => {
    expect(autoApprovalSince(new Date("2026-11-15T10:00:00.000Z"))).toBe(
      "2026-11-01T10:00:00.000Z",
    );
  });
});

describe("isAutoApprovalUnavailable", () => {
  it("rozpozná chýbajúcu tabuľku, stĺpec aj funkciu", () => {
    expect(isAutoApprovalUnavailable({ code: "42P01", message: "x" })).toBe(true);
    expect(isAutoApprovalUnavailable({ code: "42703", message: "x" })).toBe(true);
    expect(isAutoApprovalUnavailable({ code: "PGRST205", message: "x" })).toBe(true);
    expect(isAutoApprovalUnavailable({ code: "PGRST202", message: "x" })).toBe(true);
    expect(
      isAutoApprovalUnavailable({
        message: "Could not find the table 'public.correction_auto_approvals' in the schema cache",
      }),
    ).toBe(true);
    expect(
      isAutoApprovalUnavailable({ message: "column corrections.auto_approved does not exist" }),
    ).toBe(true);
  });
  it("chyba spojenia alebo oprávnení nie je „nedostupné“", () => {
    expect(isAutoApprovalUnavailable({ message: "Failed to fetch" })).toBe(false);
    expect(isAutoApprovalUnavailable({ code: "42501", message: "permission denied" })).toBe(false);
    expect(isAutoApprovalUnavailable({})).toBe(false);
  });
});
