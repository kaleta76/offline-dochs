import { describe, expect, it } from "vitest";
import {
  RECOVERY_REVOKE_REASON,
  asVerification,
  countUnverified,
  deviceChanges,
  deviceKind,
  deviceLabel,
  unverifiedSummary,
  type DeviceRow,
} from "./device-trace";

const WIN =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0";
const ANDROID =
  "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0";
const IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15";
const MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15";
const LINUX = "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0";

const NOW = new Date("2026-11-03T12:00:00Z");

function dev(over: Partial<DeviceRow> & { id: string }): DeviceRow {
  return {
    user_id: "emp",
    status: "active",
    created_at: "2026-11-01T08:00:00Z",
    approved_by: "boss",
    approved_at: "2026-11-01T08:05:00Z",
    revoked_at: null,
    revoke_reason: null,
    replaces_device_id: null,
    user_agent_hint: WIN,
    ...over,
  };
}

describe("deviceKind", () => {
  it("rozpozná typ zariadenia a nezamení Android za Linux ani iPhone za Mac", () => {
    expect(deviceKind(WIN)).toBe("Windows");
    expect(deviceKind(ANDROID)).toBe("Android");
    expect(deviceKind(IPHONE)).toBe("iPhone/iPad");
    expect(deviceKind(MAC)).toBe("Mac");
    expect(deviceKind(LINUX)).toBe("Linux");
    expect(deviceKind("Edge")).toBe("iné");
    expect(deviceKind(null)).toBe("iné");
  });
  it("funguje aj na user-agent skrátený na 80 znakov", () => {
    expect(deviceKind(ANDROID.slice(0, 80))).toBe("Android");
    expect(deviceKind(WIN.slice(0, 80))).toBe("Windows");
  });
});

describe("deviceLabel", () => {
  it("vezme prvé štyri hexadecimálne znaky veľkými písmenami", () => {
    expect(deviceLabel("a3f9c2d0-1111-4222-8333-444455556666")).toBe("A3F9");
  });
  it("pri chýbajúcom alebo krátkom id vráti prázdny reťazec", () => {
    expect(deviceLabel(null)).toBe("");
    expect(deviceLabel("ab")).toBe("");
  });
});

describe("asVerification", () => {
  it("známe hodnoty ostanú, neznáme sa berú ako neoverené", () => {
    expect(asVerification("verified")).toBe("verified");
    expect(asVerification("confirmed")).toBe("confirmed");
    expect(asVerification("unverified")).toBe("unverified");
    expect(asVerification("cokolvek")).toBe("unverified");
    expect(asVerification(null)).toBe("unverified");
  });
});

describe("countUnverified", () => {
  it("rátá len neoverené a nezneplatnené razenia", () => {
    expect(
      countUnverified([
        { verification: "unverified" },
        { verification: "unverified", voided: true },
        { verification: "verified" },
        { verification: "confirmed" },
        { verification: "unverified", voided: false },
      ]),
    ).toBe(2);
  });
});

describe("unverifiedSummary", () => {
  it("sklonuje počet", () => {
    expect(unverifiedSummary(1)).toMatch(/^1 razenie je z neschváleného/);
    expect(unverifiedSummary(2)).toMatch(/^2 razenia sú z neschváleného/);
    expect(unverifiedSummary(4)).toMatch(/^4 razenia sú z neschváleného/);
    expect(unverifiedSummary(5)).toMatch(/^5 razení je z neschváleného/);
    expect(unverifiedSummary(12)).toMatch(/^12 razení je z neschváleného/);
  });
});

describe("deviceChanges", () => {
  it("obnova záchranným kódom sa označí aj so zmenou typu zariadenia (scenár: práca na PC, doma mobil)", () => {
    const pc = dev({
      id: "pc",
      status: "revoked",
      revoked_at: "2026-11-03T06:00:00Z",
      revoke_reason: RECOVERY_REVOKE_REASON,
    });
    const phone = dev({
      id: "phone",
      approved_by: "emp", // recover_device zapíše ako schvaľovateľa samotného zamestnanca
      approved_at: "2026-11-03T06:00:00Z",
      replaces_device_id: "pc",
      user_agent_hint: ANDROID,
    });
    const r = deviceChanges([pc, phone], NOW);
    expect(r).toHaveLength(1);
    expect(r[0]!.kind).toBe("recovered");
    expect(r[0]!.from).toBe("Windows");
    expect(r[0]!.to).toBe("Android");
    expect(r[0]!.typeChanged).toBe(true);
    expect(r[0]!.device.id).toBe("phone");
  });

  it("bežné prvé schválenie vedúcim sa nezobrazuje", () => {
    expect(deviceChanges([dev({ id: "a" })], NOW)).toHaveLength(0);
  });

  it("náhrada schválená vedúcim je bežná zmena, nie obnova", () => {
    const old = dev({ id: "old", status: "revoked", revoke_reason: "Nahradené novým zariadením" });
    const next = dev({ id: "new", replaces_device_id: "old", approved_at: "2026-11-02T09:00:00Z" });
    const r = deviceChanges([old, next], NOW);
    expect(r).toHaveLength(1);
    expect(r[0]!.kind).toBe("replacement");
    expect(r[0]!.typeChanged).toBe(false);
  });

  it("čakajúca žiadosť o náhradu sa ukáže s časom vytvorenia", () => {
    const old = dev({ id: "old" });
    const next = dev({
      id: "new",
      status: "pending",
      approved_by: null,
      approved_at: null,
      replaces_device_id: "old",
      created_at: "2026-11-03T10:00:00Z",
    });
    const r = deviceChanges([old, next], NOW);
    expect(r).toHaveLength(1);
    expect(r[0]!.kind).toBe("replacement_pending");
    expect(r[0]!.at).toBe("2026-11-03T10:00:00Z");
  });

  it("zariadenie schválené samým používateľom (správca u seba) je samostatný druh, nie obnova", () => {
    const r = deviceChanges([dev({ id: "own", approved_by: "emp" })], NOW);
    expect(r).toHaveLength(1);
    expect(r[0]!.kind).toBe("self_approved");
  });

  it("staršie zmeny než 90 dní sa vynechajú a výsledok je od najnovšej", () => {
    const a = dev({ id: "a", approved_by: "emp", approved_at: "2026-06-01T08:00:00Z" });
    const b = dev({ id: "b", approved_by: "emp", approved_at: "2026-10-01T08:00:00Z" });
    const c = dev({ id: "c", approved_by: "emp", approved_at: "2026-10-20T08:00:00Z" });
    const r = deviceChanges([a, b, c], NOW);
    expect(r.map((x) => x.device.id)).toEqual(["c", "b"]);
  });

  it("ak pôvodné zariadenie nepoznáme, typ sa neporovnáva", () => {
    const next = dev({ id: "new", replaces_device_id: "missing", user_agent_hint: ANDROID });
    const r = deviceChanges([next], NOW);
    expect(r[0]!.from).toBeNull();
    expect(r[0]!.typeChanged).toBe(false);
  });
});
