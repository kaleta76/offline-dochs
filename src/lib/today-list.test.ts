import { describe, expect, it } from "vitest";
import { buildTodayList, lastActiveEntry, type QueuedRow, type TodayRow } from "./today-list";

const NOW = new Date(2026, 10, 10, 13, 0, 0);
const at = (h: number, m = 0, day = 10) => new Date(2026, 10, day, h, m, 0).toISOString();
const isToday = (d: Date) => d.getFullYear() === 2026 && d.getMonth() === 10 && d.getDate() === 10;

const row = (id: string, code: string, direction: string, time: string, voided = false): TodayRow => ({
  client_uuid: id,
  code,
  direction,
  client_time: time,
  voided_at: voided ? at(12, 30) : null,
});
const queued = (id: string, code: string, direction: string, time: string, error?: string): QueuedRow => ({
  client_uuid: id,
  code,
  direction,
  client_time: time,
  ...(error ? { error } : {}),
});

describe("buildTodayList", () => {
  it("zneplatnené razenie ostane v zozname a je označené", () => {
    const list = buildTodayList(
      [row("a", "WORK", "IN", at(7, 30)), row("b", "WORK", "OUT", at(12, 0), true)],
      [],
      isToday,
      NOW,
    );
    expect(list.map((e) => [e.id, e.voided])).toEqual([
      ["a", false],
      ["b", true],
    ]);
  });

  it("razenie z fronty sa pridá ako čakajúce, duplicita so serverom a iné dni sa vynechajú", () => {
    const list = buildTodayList(
      [row("a", "WORK", "IN", at(7, 30))],
      [
        queued("a", "WORK", "IN", at(7, 30)),
        queued("c", "WORK", "OUT", at(12, 5), "chyba"),
        queued("d", "WORK", "IN", at(7, 0, 9)),
      ],
      isToday,
      NOW,
    );
    expect(list.map((e) => e.id)).toEqual(["a", "c"]);
    expect(list[1]?.pending).toBe(true);
    expect(list[1]?.voided).toBe(false);
    expect(list[1]?.error).toBe("chyba");
    expect(list[0]?.pending).toBe(false);
  });

  it("plánované razenie ďaleko v budúcnosti sa neukáže, razenie o pár minút napred áno", () => {
    const list = buildTodayList(
      [row("a", "WORK", "IN", at(7, 30)), row("f", "TRIP", "OUT", at(17, 0)), row("g", "WORK", "OUT", at(13, 10))],
      [],
      isToday,
      NOW,
    );
    expect(list.map((e) => e.id)).toEqual(["a", "g"]);
  });

  it("zoradí podľa času", () => {
    const list = buildTodayList([row("b", "WORK", "OUT", at(12, 0)), row("a", "WORK", "IN", at(7, 30))], [], isToday, NOW);
    expect(list.map((e) => e.id)).toEqual(["a", "b"]);
  });
});

describe("lastActiveEntry", () => {
  it("zneplatnený odchod nezmení stav: zamestnanec je stále v práci", () => {
    const list = buildTodayList(
      [row("a", "WORK", "IN", at(7, 30)), row("b", "WORK", "OUT", at(12, 0), true)],
      [],
      isToday,
      NOW,
    );
    const last = lastActiveEntry(list);
    expect(last?.id).toBe("a");
    expect(last?.dir).toBe("IN");
  });

  it("zneplatnený príchod po platnom odchode ponechá stav mimo", () => {
    const list = buildTodayList(
      [row("a", "WORK", "IN", at(7, 30)), row("b", "WORK", "OUT", at(12, 0)), row("c", "WORK", "IN", at(12, 40), true)],
      [],
      isToday,
      NOW,
    );
    expect(lastActiveEntry(list)?.id).toBe("b");
  });

  it("bez platného razenia nie je nič", () => {
    expect(lastActiveEntry([])).toBeUndefined();
    const all = buildTodayList([row("a", "WORK", "IN", at(7, 30), true)], [], isToday, NOW);
    expect(all).toHaveLength(1);
    expect(lastActiveEntry(all)).toBeUndefined();
  });
});
