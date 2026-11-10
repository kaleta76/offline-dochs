import { describe, expect, it } from "vitest";
import { showDiagnostics } from "./diagnostics-visibility";

describe("showDiagnostics", () => {
  it("v testovacej organizácii je panel vždy viditeľný", () => {
    expect(showDiagnostics({ isTestOrganization: true, search: "" })).toBe(true);
    expect(showDiagnostics({ isTestOrganization: true, search: "?diagnostika=0" })).toBe(true);
  });

  it("v ostrej organizácii je panel štandardne skrytý", () => {
    expect(showDiagnostics({ isTestOrganization: false, search: "" })).toBe(false);
    expect(showDiagnostics({ isTestOrganization: false, search: "?mesiac=11" })).toBe(false);
  });

  it("v ostrej organizácii ho odkryje ?diagnostika=1", () => {
    expect(showDiagnostics({ isTestOrganization: false, search: "?diagnostika=1" })).toBe(true);
    expect(showDiagnostics({ isTestOrganization: false, search: "diagnostika=1" })).toBe(true);
    expect(showDiagnostics({ isTestOrganization: false, search: "?mesiac=11&diagnostika=1" })).toBe(true);
  });

  it("iná hodnota parametra panel neodkryje", () => {
    for (const search of ["?diagnostika=0", "?diagnostika=", "?diagnostika", "?diagnostika=true", "?Diagnostika=1"]) {
      expect(showDiagnostics({ isTestOrganization: false, search })).toBe(false);
    }
  });
});
