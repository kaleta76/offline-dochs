import { describe, expect, it } from "vitest";
import { localToUtc, zoneOffsetMs } from "./zone-time";

const TZ = "Europe/Bratislava";
const iso = (d: Date | null) => (d ? d.toISOString() : null);

describe("localToUtc (Europe/Bratislava)", () => {
  it("zimný čas je UTC+1", () => {
    expect(iso(localToUtc(2026, 11, 2, 7, 0, 0, TZ))).toBe("2026-11-02T06:00:00.000Z");
  });
  it("letný čas je UTC+2", () => {
    expect(iso(localToUtc(2026, 10, 5, 7, 0, 12, TZ))).toBe("2026-10-05T05:00:12.000Z");
  });
  it("preskočená hodina pri prechode na letný čas neexistuje", () => {
    expect(localToUtc(2026, 3, 29, 2, 30, 0, TZ)).toBeNull();
  });
  it("opakovaná hodina pri prechode na zimný čas dá prvý (letný) výskyt", () => {
    expect(iso(localToUtc(2026, 10, 25, 2, 30, 0, TZ))).toBe("2026-10-25T00:30:00.000Z");
  });
  it("mesiac s prechodom: pred a po prechode sa líši posun", () => {
    expect(iso(localToUtc(2026, 10, 24, 8, 0, 0, TZ))).toBe("2026-10-24T06:00:00.000Z");
    expect(iso(localToUtc(2026, 10, 26, 8, 0, 0, TZ))).toBe("2026-10-26T07:00:00.000Z");
  });
  it("zoneOffsetMs vracia posun v milisekundách", () => {
    expect(zoneOffsetMs(Date.UTC(2026, 0, 15, 12), TZ)).toBe(3600_000);
    expect(zoneOffsetMs(Date.UTC(2026, 6, 15, 12), TZ)).toBe(7200_000);
  });
});
