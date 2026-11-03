import { describe, expect, it } from "vitest";
import {
  exportFileName,
  monthRangeUtc,
  toExportRows,
  type ProfileLite,
  type PunchDbShape,
} from "./punch-export-range";

const iso = (d: Date) => d.toISOString();

describe("monthRangeUtc (Europe/Bratislava)", () => {
  it("november 2026: zimný čas, polnoc je 23:00 UTC predošlého dňa", () => {
    const r = monthRangeUtc(2026, 11);
    expect(iso(r.from)).toBe("2026-10-31T23:00:00.000Z");
    expect(iso(r.to)).toBe("2026-11-30T23:00:00.000Z");
  });

  it("október 2026: koniec letného času sa do hraníc nepremietne nesprávne", () => {
    const r = monthRangeUtc(2026, 10);
    expect(iso(r.from)).toBe("2026-09-30T22:00:00.000Z");
    expect(iso(r.to)).toBe("2026-10-31T23:00:00.000Z");
  });

  it("marec 2027: začiatok letného času", () => {
    const r = monthRangeUtc(2027, 3);
    expect(iso(r.from)).toBe("2027-02-28T23:00:00.000Z");
    expect(iso(r.to)).toBe("2027-03-31T22:00:00.000Z");
  });

  it("december prechádza do januára nasledujúceho roka", () => {
    const r = monthRangeUtc(2026, 12);
    expect(iso(r.from)).toBe("2026-11-30T23:00:00.000Z");
    expect(iso(r.to)).toBe("2026-12-31T23:00:00.000Z");
  });
});

describe("exportFileName", () => {
  it("celý mesiac", () => {
    expect(exportFileName({ year: 2026, month: 3 })).toBe("punches_202603.csv");
  });

  it("prírastok používa miestny čas generovania", () => {
    const now = new Date("2026-11-03T08:12:45Z"); // 09:12 v Bratislave
    expect(exportFileName({ year: 2026, month: 11, sinceId: 5, now })).toBe(
      "punches_20261103_0912.csv",
    );
  });
});

const profile = (id: string, sap: string | null): ProfileLite => ({ id, sap_id: sap });
const punch = (over: Partial<PunchDbShape> = {}): PunchDbShape => ({
  id: 1,
  client_uuid: "a0000000-0000-4000-8000-000000000001",
  code: "WORK",
  direction: "IN",
  client_time: "2026-11-02T04:58:12.345+00:00",
  server_time: "2026-11-02T04:58:14.1+00:00",
  drift_minutes: 0,
  source: "terminal",
  device_verification: "verified",
  device_id: null,
  user_id: "6d1c3b84-1111-4a2e-8c11-aaaaaaaaaaa1",
  prev_hash: "GENESIS",
  record_hash: "abc",
  ...over,
});

describe("toExportRows", () => {
  const profiles = [profile("6d1c3b84-1111-4a2e-8c11-aaaaaaaaaaa1", "00123456")];

  it("pridá osobné číslo a organizáciu", () => {
    const [row] = toExportRows([punch()], profiles, "org-1");
    expect(row?.sap_id).toBe("00123456");
    expect(row?.organization_id).toBe("org-1");
  });

  it("účet bez platného osobného čísla zastaví export a uvedie len skrátené ID", () => {
    const bad = [profile("6d1c3b84-1111-4a2e-8c11-aaaaaaaaaaa1", null)];
    expect(() => toExportRows([punch()], bad, "org-1")).toThrow(/6d1c3b84/);
    expect(() => toExportRows([punch()], bad, "org-1")).toThrow(/osobné číslo SAP/);
  });

  it("neznámy zdroj alebo chýbajúci hash export zastaví", () => {
    expect(() => toExportRows([punch({ source: "manual" })], profiles, "org-1")).toThrow(/zdroj/);
    expect(() => toExportRows([punch({ record_hash: null })], profiles, "org-1")).toThrow(/hash/);
    expect(() => toExportRows([punch({ direction: "X" })], profiles, "org-1")).toThrow(/smer/);
  });
});
