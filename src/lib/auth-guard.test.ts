import { describe, expect, it } from "vitest";
import { guardDecision, isAuthRejection } from "./auth-guard";

const authError = (name: string, status: number | undefined) => ({
  name,
  status,
  message: "x",
  __isAuthError: true,
});

describe("isAuthRejection", () => {
  it("rozpozná jasné odmietnutie servera (401, 403, 400)", () => {
    expect(isAuthRejection(authError("AuthApiError", 401))).toBe(true);
    expect(isAuthRejection(authError("AuthApiError", 403))).toBe(true);
    expect(isAuthRejection(authError("AuthSessionMissingError", 400))).toBe(true);
  });

  it("výpadok spojenia ani chyba brány nie sú odmietnutím", () => {
    expect(isAuthRejection(authError("AuthRetryableFetchError", 0))).toBe(false);
    expect(isAuthRejection(authError("AuthRetryableFetchError", 502))).toBe(false);
    expect(isAuthRejection(authError("AuthRetryableFetchError", 503))).toBe(false);
    expect(isAuthRejection(authError("AuthRetryableFetchError", 504))).toBe(false);
    expect(isAuthRejection(authError("AuthApiError", 500))).toBe(false);
  });

  it("odpoveď bez stavu (HTML od proxy, vyhodená chyba) nie je odmietnutím", () => {
    expect(isAuthRejection(authError("AuthUnknownError", undefined))).toBe(false);
    expect(isAuthRejection(new TypeError("Failed to fetch"))).toBe(false);
    expect(isAuthRejection(null)).toBe(false);
    expect(isAuthRejection("chyba")).toBe(false);
  });

  it("obmedzenie počtu požiadaviek a časový limit neodhlasujú", () => {
    expect(isAuthRejection(authError("AuthApiError", 429))).toBe(false);
    expect(isAuthRejection(authError("AuthApiError", 408))).toBe(false);
  });
});

describe("guardDecision", () => {
  const base = { hasSession: true, online: true, user: null, error: null };

  it("platný používateľ prejde", () => {
    expect(guardDecision({ ...base, user: { id: "u1" } })).toBe("allow");
  });

  it("bez lokálnej relácie vedie na prihlásenie", () => {
    expect(guardDecision({ ...base, hasSession: false })).toBe("login");
    expect(guardDecision({ ...base, hasSession: false, online: false })).toBe("login");
  });

  it("bez spojenia s lokálnou reláciou prejde bez overenia", () => {
    expect(guardDecision({ ...base, online: false })).toBe("allow");
  });

  it("zlyhanie spojenia (proxy, výpadok, 502) ponechá lokálne prihlásenie", () => {
    expect(
      guardDecision({ ...base, error: authError("AuthRetryableFetchError", 0) }),
    ).toBe("allow");
    expect(
      guardDecision({ ...base, error: authError("AuthRetryableFetchError", 502) }),
    ).toBe("allow");
    expect(guardDecision({ ...base, error: authError("AuthUnknownError", undefined) })).toBe(
      "allow",
    );
    expect(guardDecision({ ...base, error: new TypeError("Failed to fetch") })).toBe("allow");
  });

  it("jasné odmietnutie servera vedie na prihlásenie", () => {
    expect(guardDecision({ ...base, error: authError("AuthApiError", 401) })).toBe("login");
    expect(guardDecision({ ...base, error: authError("AuthApiError", 403) })).toBe("login");
  });

  it("bez používateľa a bez chyby je to opatrne prihlásenie", () => {
    expect(guardDecision(base)).toBe("login");
  });
});
