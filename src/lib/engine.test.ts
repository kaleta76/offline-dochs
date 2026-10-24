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

  it("no break deducted for 5 hours of work", () => {
    const r = computeDay(day([p("WORK", "IN", "08:00"), p("WORK", "OUT", "13:00")]), S);
    expect(r.workMin).toBe(300);
    expect(r.breakMin).toBe(0);
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
    expect(r.byCode.DOCTOR).toBe(120);
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
    expect(r.workMin).toBe(465 - 30);
  });

  it("arrival without departure is flagged open", () => {
    const r = computeDay(day([p("WORK", "IN", "07:00")]), S);
    expect(r.open).toBe(true);
    expect(r.workMin).toBe(0);
  });
});
