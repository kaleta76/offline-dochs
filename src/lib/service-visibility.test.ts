import { describe, expect, it } from "vitest";
import { serviceVisibility } from "./service-visibility";

describe("serviceVisibility", () => {
  it("ostrá organizácia bez parametra: karta Servis sa neukáže vôbec", () => {
    for (const search of [
      "",
      "?mesiac=11",
      "?servis=0",
      "?servis=",
      "?servis",
      "?Servis=1",
      "?servis=true",
    ]) {
      expect(serviceVisibility({ isTestOrganization: false, search })).toEqual({
        tab: false,
        tools: false,
        diagnostics: false,
        openByDefault: false,
      });
    }
  });

  it("?servis=1 odkryje kartu so všetkými nástrojmi aj diagnostikou a otvorí ju", () => {
    for (const search of ["?servis=1", "servis=1", "?mesiac=11&servis=1"]) {
      expect(serviceVisibility({ isTestOrganization: false, search })).toEqual({
        tab: true,
        tools: true,
        diagnostics: true,
        openByDefault: true,
      });
    }
  });

  it("staršie ?diagnostika=1 odkryje kartu len s diagnostikou, bez servisných nástrojov", () => {
    expect(serviceVisibility({ isTestOrganization: false, search: "?diagnostika=1" })).toEqual({
      tab: true,
      tools: false,
      diagnostics: true,
      openByDefault: true,
    });
    expect(serviceVisibility({ isTestOrganization: false, search: "?diagnostika=0" }).tab).toBe(
      false,
    );
  });

  it("testovacia organizácia má kartu vždy, ale neotvára ju sama", () => {
    expect(serviceVisibility({ isTestOrganization: true, search: "" })).toEqual({
      tab: true,
      tools: true,
      diagnostics: true,
      openByDefault: false,
    });
    expect(serviceVisibility({ isTestOrganization: true, search: "?servis=0" }).tools).toBe(true);
  });
});
