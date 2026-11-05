import { describe, it, expect } from "vitest";
import { computeDay, type PunchLike, type EngineSettings } from "./engine";

const S: EngineSettings = { roundInMin: 0, roundOutMin: 0, breakMin: 30, breakAfterHours: 6 };
const t = (hm: string) => new Date(`2026-10-21T${hm}:00`);
const p = (code: string, direction: "IN" | "OUT", hm: string): PunchLike => ({ code, direction, time: t(hm) });
const day = (punches: PunchLike[], isWorkday = true) => ({ punches, fundHours: 7.5, isWorkday });

describe("computeDay", () => {
  it("7:00–15:30 deducts 30 min break and gives +30 balance on a 7.5 h fund", () => {
    const r = computeDay(day([p("WORK", "IN", "07:00"), p("WORK", "OUT", "15:30")]), S);
    expect(r.workMin).toBe(480);
    expect(r.breakMin).toBe(30);
    expect(r.balanceMin).toBe(30);
  });

  describe("lunch punched out and back in", () => {
    it("does not deduct the automatic break again (real day 1. 10.: 7:00–12:15, 12:45–15:19 is 469 min, +19)", () => {
      const r = computeDay(day([p("WORK", "IN", "07:00"), p("WORK", "OUT", "12:15"), p("WORK", "IN", "12:45"), p("WORK", "OUT", "15:19")]), S);
      expect(r.workMin).toBe(469);
      expect(r.breakMin).toBe(0);
      expect(r.balanceMin).toBe(19);
      expect(r.byCode["WORK"]).toBe(469);
    });

    it("keeps a lunch shorter than the break as it is (27 min, no top-up of the break)", () => {
      const r = computeDay(day([p("WORK", "IN", "06:53"), p("WORK", "OUT", "12:00"), p("WORK", "IN", "12:27"), p("WORK", "OUT", "14:12")]), S);
      expect(r.workMin).toBe(412);
      expect(r.breakMin).toBe(0);
    });

    it("keeps a lunch longer than the break as it is (one hour out, no extra deduction)", () => {
      const r = computeDay(day([p("WORK", "IN", "07:00"), p("WORK", "OUT", "12:00"), p("WORK", "IN", "13:00"), p("WORK", "OUT", "16:00")]), S);
      expect(r.workMin).toBe(480);
      expect(r.breakMin).toBe(0);
      expect(r.balanceMin).toBe(30);
    });

    it("still deducts the break when the only gap is a doctor visit or a private departure", () => {
      const doctor = computeDay(day([p("WORK", "IN", "07:00"), p("DOCTOR", "OUT", "10:00"), p("WORK", "IN", "10:30"), p("WORK", "OUT", "16:30")]), S);
      expect(doctor.breakMin).toBe(30);
      const priv = computeDay(day([p("WORK", "IN", "07:00"), p("PRIV", "OUT", "10:00"), p("WORK", "IN", "10:30"), p("WORK", "OUT", "16:30")]), S);
      expect(priv.breakMin).toBe(30);
    });

    it("a final departure is not a lunch", () => {
      const r = computeDay(day([p("WORK", "IN", "07:00"), p("WORK", "OUT", "15:30")]), S);
      expect(r.breakMin).toBe(30);
    });
  });

  it("no break deducted for 5 hours of work", () => {
    const r = computeDay(day([p("WORK", "IN", "08:00"), p("WORK", "OUT", "13:00")]), S);
    expect(r.workMin).toBe(300);
    expect(r.breakMin).toBe(0);
  });

  describe("break threshold (same as Access: 6 h or more, the full break)", () => {
    it("5 h 59 min of work deducts nothing", () => {
      const r = computeDay(day([p("WORK", "IN", "07:00"), p("WORK", "OUT", "12:59")]), S);
      expect(r.workMin).toBe(359);
      expect(r.breakMin).toBe(0);
    });
    it("exactly 6 h of work deducts the full 30 min", () => {
      const r = computeDay(day([p("WORK", "IN", "07:00"), p("WORK", "OUT", "13:00")]), S);
      expect(r.breakMin).toBe(30);
      expect(r.workMin).toBe(330);
    });
    it("6 h 10 min of work deducts the full 30 min, not only the part above 6 h", () => {
      const r = computeDay(day([p("WORK", "IN", "07:00"), p("WORK", "OUT", "13:10")]), S);
      expect(r.breakMin).toBe(30);
      expect(r.workMin).toBe(340);
      expect(r.byCode["WORK"]).toBe(340);
    });
  });

  it("leaving to the doctor without return tops the day up to the fund", () => {
    const r = computeDay(day([p("WORK", "IN", "07:00"), p("DOCTOR", "OUT", "10:00")]), S);
    expect(r.workMin).toBe(180);
    expect(r.creditMin).toBe(270);
    expect(r.totalMin).toBe(450);
  });

  it("doctor 10–12 with return credits the real 2 hours", () => {
    const r = computeDay(day([p("WORK", "IN", "07:00"), p("DOCTOR", "OUT", "10:00"), p("WORK", "IN", "12:00"), p("WORK", "OUT", "15:30")]), S);
    expect(r.workMin).toBe(360);
    expect(r.creditMin).toBe(120);
    expect(r.byCode["DOCTOR"]).toBe(120);
  });

  it("private interruption is not counted", () => {
    const r = computeDay(day([p("WORK", "IN", "07:00"), p("PRIV", "OUT", "10:00"), p("WORK", "IN", "11:00"), p("WORK", "OUT", "15:30")]), S);
    expect(r.privMin).toBe(60);
    expect(r.workMin).toBe(420);
    expect(r.balanceMin).toBe(-30);
  });

  it("holiday has zero expected time", () => {
    const r = computeDay(day([], false), S);
    expect(r.expectedMin).toBe(0);
    expect(r.balanceMin).toBe(0);
  });

  it("15 min rounding moves 7:05 to 7:15 and 15:40 to 15:30", () => {
    const r = computeDay(day([p("WORK", "IN", "07:05"), p("WORK", "OUT", "15:40")]), { ...S, roundInMin: 15, roundOutMin: 15 });
    expect(r.workMin).toBe(495 - 30);
  });

  it("arrival without departure is flagged open", () => {
    const r = computeDay(day([p("WORK", "IN", "07:00")]), S);
    expect(r.open).toBe(true);
    expect(r.workMin).toBe(0);
  });
});
