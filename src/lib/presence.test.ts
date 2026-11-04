import { describe, expect, it } from "vitest";
import { NO_PRESENCE, presenceOf, summarizePresence, type PresencePunch } from "./presence";

const t = (hhmm: string) => new Date(`2026-11-04T${hhmm}:00`);
const p = (code: string, direction: "IN" | "OUT", hhmm: string, voided = false): PresencePunch => ({ code, direction, time: t(hhmm), voided });

describe("presenceOf", () => {
  it("bez razenia dnes: stav none", () => {
    expect(presenceOf([])).toEqual(NO_PRESENCE);
  });

  it("posledné razenie je príchod: prítomný", () => {
    const r = presenceOf([p("WORK", "IN", "07:02")]);
    expect(r.state).toBe("in");
    expect(r.since).toEqual(t("07:02"));
  });

  it("odchod z práce: odišiel", () => {
    const r = presenceOf([p("WORK", "IN", "07:02"), p("WORK", "OUT", "15:30")]);
    expect(r.state).toBe("out");
    expect(r.since).toEqual(t("15:30"));
  });

  it("obed (odchod a návrat): po návrate je prítomný", () => {
    const r = presenceOf([p("WORK", "IN", "07:00"), p("WORK", "OUT", "11:30"), p("WORK", "IN", "12:00")]);
    expect(r.state).toBe("in");
  });

  it("odchod s dôvodom (lekár, služobná cesta, dovolenka): mimo, s kódom dôvodu", () => {
    for (const code of ["DOCTOR", "TRIP", "FAMILY", "PRIV", "LEAVE", "SICK"]) {
      const r = presenceOf([p("WORK", "IN", "07:00"), p(code, "OUT", "09:10")]);
      expect(r.state).toBe("away");
      expect(r.code).toBe(code);
    }
  });

  it("návrat z lekára: prítomný", () => {
    const r = presenceOf([p("WORK", "IN", "07:00"), p("DOCTOR", "OUT", "09:10"), p("WORK", "IN", "10:40")]);
    expect(r.state).toBe("in");
  });

  it("nezoradený vstup sa zoradí podľa času", () => {
    const r = presenceOf([p("WORK", "OUT", "15:30"), p("WORK", "IN", "07:02")]);
    expect(r.state).toBe("out");
  });

  it("zneplatnené razenie sa nepočíta", () => {
    const r = presenceOf([p("WORK", "IN", "07:02"), p("WORK", "OUT", "07:03", true)]);
    expect(r.state).toBe("in");
    expect(presenceOf([p("WORK", "IN", "07:02", true)])).toEqual(NO_PRESENCE);
  });
});

describe("summarizePresence", () => {
  it("spočíta stavy", () => {
    const list = [
      presenceOf([p("WORK", "IN", "07:00")]),
      presenceOf([p("WORK", "IN", "07:00")]),
      presenceOf([p("WORK", "IN", "07:00"), p("DOCTOR", "OUT", "09:00")]),
      presenceOf([p("WORK", "IN", "07:00"), p("WORK", "OUT", "15:00")]),
      presenceOf([]),
    ];
    expect(summarizePresence(list)).toEqual({ in: 2, away: 1, out: 1, none: 1, total: 5 });
  });
});
