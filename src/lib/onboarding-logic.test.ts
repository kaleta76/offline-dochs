import { describe, expect, it } from "vitest";
import {
  clearPatch,
  failurePatch,
  hasFailures,
  isThrottled,
  LOGIN_LIMIT,
  LOGIN_WINDOW_MS,
  parseNumberList,
  pinStatus,
} from "./onboarding-logic";

const now = 1_800_000_000_000;
const pending = (extra: Record<string, unknown> = {}) => ({
  onboarding_pending: true,
  pin_hash: "h",
  pin_salt: "s",
  pin_expires: now + 1000,
  pin_attempts: 0,
  ...extra,
});

describe("stav PIN-u", () => {
  it("platný PIN je pripravený", () => expect(pinStatus(pending(), now)).toBe("ready"));
  it("účet bez čakajúceho PIN-u ho nemá", () => {
    expect(pinStatus({}, now)).toBe("missing");
    expect(pinStatus(pending({ onboarding_pending: false }), now)).toBe("missing");
    expect(pinStatus(pending({ pin_hash: null }), now)).toBe("missing");
  });
  it("po uplynutí platnosti expiruje", () => {
    expect(pinStatus(pending({ pin_expires: now - 1 }), now)).toBe("expired");
    expect(pinStatus(pending({ pin_expires: undefined }), now)).toBe("expired");
  });
  it("po piatich omyloch sa zamkne", () => {
    expect(pinStatus(pending({ pin_attempts: 4 }), now)).toBe("ready");
    expect(pinStatus(pending({ pin_attempts: 5 }), now)).toBe("locked");
  });
});

describe("zámok po omyloch", () => {
  it("počíta omyly a po limite zamkne do konca okna", () => {
    let meta: Record<string, unknown> = {};
    for (let i = 0; i < LOGIN_LIMIT; i++) {
      expect(isThrottled(meta, "login", LOGIN_LIMIT, LOGIN_WINDOW_MS, now + i)).toBe(false);
      meta = { ...meta, ...failurePatch(meta, "login", LOGIN_WINDOW_MS, now + i) };
    }
    expect(meta["login_fail"]).toBe(LOGIN_LIMIT);
    expect(isThrottled(meta, "login", LOGIN_LIMIT, LOGIN_WINDOW_MS, now + 1000)).toBe(true);
    expect(
      isThrottled(meta, "login", LOGIN_LIMIT, LOGIN_WINDOW_MS, now + LOGIN_WINDOW_MS + 100),
    ).toBe(false);
  });

  it("po uplynutí okna sa počítadlo začína odznova", () => {
    const old = { login_fail: 7, login_fail_at: now - LOGIN_WINDOW_MS - 1 };
    expect(failurePatch(old, "login", LOGIN_WINDOW_MS, now)["login_fail"]).toBe(1);
  });

  it("vymazanie zruší počítadlo", () => {
    const meta = { login_fail: 3, login_fail_at: now };
    expect(hasFailures(meta, "login")).toBe(true);
    expect(clearPatch("login")).toEqual({ login_fail: null, login_fail_at: null });
    expect(hasFailures({}, "login")).toBe(false);
  });
});

describe("zoznam osobných čísel", () => {
  it("vyberie čísla z riadkov, CSV aj hlavičky a zachová nuly", () => {
    const r = parseNumberList('\uFEFFosobne_cislo\r\n4002012\r\n0012345;Novák\r\n"00123456"\r\n');
    expect(r.valid).toEqual(["4002012", "0012345", "00123456"]);
    expect(r.invalid).toEqual([]);
  });

  it("odstráni duplicity a vráti neplatné položky", () => {
    const r = parseNumberList("4002012 4002012 12345 123456789 40a2012");
    expect(r.valid).toEqual(["4002012"]);
    expect(r.duplicates).toBe(1);
    expect(r.invalid).toEqual(["12345", "123456789", "40a2012"]);
  });

  it("prázdny text nedá nič", () => {
    expect(parseNumberList("   \n ")).toEqual({ valid: [], invalid: [], duplicates: 0 });
  });
});
