import { describe, expect, it } from "vitest";
import { backendHost, isNetworkError } from "./connection";

describe("isNetworkError", () => {
  it("rozpozná sieťové chyby prehliadačov", () => {
    expect(isNetworkError("TypeError: Failed to fetch")).toBe(true);
    expect(isNetworkError("NetworkError when attempting to fetch resource.")).toBe(true);
    expect(isNetworkError("Load failed")).toBe(true);
  });
  it("iné chyby nie", () => {
    expect(isNetworkError("Nemáte oprávnenie")).toBe(false);
    expect(isNetworkError("")).toBe(false);
    expect(isNetworkError(null)).toBe(false);
    expect(isNetworkError(undefined)).toBe(false);
  });
});

describe("backendHost", () => {
  it("vráti len hostiteľa", () => {
    expect(backendHost("https://c--abc-prod.lovable.cloud/rest/v1/")).toBe("c--abc-prod.lovable.cloud");
  });
  it("neplatná alebo chýbajúca adresa dá prázdny reťazec", () => {
    expect(backendHost("nie je adresa")).toBe("");
    expect(backendHost(undefined)).toBe("");
  });
});
