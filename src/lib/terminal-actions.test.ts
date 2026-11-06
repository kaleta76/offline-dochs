import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  DEFAULT_CORRECTION_TYPES,
  DEFAULT_TERMINAL_ACTIONS,
  correctionDeadlineOk,
  correctionTypes,
  fullDayCodes,
  needsApprovalCodes,
  newestTerminalConfig,
  parseTerminalConfig,
  readTerminalCache,
  terminalActions,
  terminalCacheKey,
} from "./terminal-actions";

const golden = () => JSON.parse(readFileSync("contract/examples/config_example.json", "utf8"));
const version = "2026.11.04.1200";

describe("Access terminal button mapping", () => {
  it("keeps arrival/departure and maps configured buttons to unchanged OUT punching", () => {
    const config = parseTerminalConfig(version, golden());
    expect(config).not.toBeNull();
    expect(terminalActions(config).map((a) => [a.code, a.dir])).toEqual([
      ["WORK", "IN"],
      ["WORK", "OUT"],
      ["DOCTOR", "OUT"],
      ["FAMILY", "OUT"],
      ["TRIP", "OUT"],
      ["ERRAND", "OUT"],
    ]);
  });
  it("uses configured order and breaks ties by interruption number", () => {
    const config = parseTerminalConfig(version, golden());
    if (!config) throw new Error("Fixture must parse");
    for (const button of config.buttons) button.order = button.code === "TRIP" ? 1 : 2;
    expect(
      terminalActions(config)
        .slice(2)
        .map((a) => a.code),
    ).toEqual(["TRIP", "DOCTOR", "ERRAND", "FAMILY"]);
  });
  it("keeps default buttons when no configuration or no flagged button exists", () => {
    const doc = golden();
    for (const it of doc.interruptions) it.terminal_button = false;
    expect(terminalActions(null).map((a) => a.code)).toEqual([
      "WORK",
      "WORK",
      "DOCTOR",
      "FAMILY",
      "TRIP",
      "ERRAND",
      "PRIV",
    ]);
    expect(terminalActions(parseTerminalConfig(version, doc))).toEqual(DEFAULT_TERMINAL_ACTIONS);
  });
  it("refuses ambiguous mapping instead of recording an incorrect code", () => {
    const doc = golden();
    doc.terminal_code_map.push({ code: "DOCTOR2", interruption: 2 });
    expect(parseTerminalConfig(version, doc)).toBeNull();
  });
  it("records configured lunch as OUT and replaces unknown icons safely", () => {
    const doc = golden();
    const lunch = doc.interruptions.find((it: { code: number }) => it.code === 7);
    Object.assign(lunch, {
      terminal_button: true,
      terminal_label: "Obed",
      terminal_icon: "rocket",
    });
    doc.terminal_code_map.push({ code: "LUNCH", interruption: 7 });
    expect(
      terminalActions(parseTerminalConfig(version, doc)).find((a) => a.code === "LUNCH"),
    ).toEqual({ code: "LUNCH", dir: "OUT", label: "Obed", icon: "other" });
  });
  it("restores only the owner/company button projection offline, without employee plans", () => {
    const config = parseTerminalConfig(version, golden());
    const key = terminalCacheKey("owner", "company");
    localStorage.setItem(key, JSON.stringify(config));
    expect(readTerminalCache(localStorage, key)).toEqual(config);
    expect(readTerminalCache(localStorage, terminalCacheKey("other", "company"))).toBeNull();
    expect(readTerminalCache(localStorage, terminalCacheKey("owner", "other"))).toBeNull();
    expect(config).not.toHaveProperty("employees");
  });
  it("does not roll back to an older fetched version", () => {
    const old = parseTerminalConfig(version, golden());
    const current = parseTerminalConfig("2026.11.05.1200", golden());
    if (!old || !current) throw new Error("Fixture must parse");
    expect(newestTerminalConfig(current, old).version).toBe("2026.11.05.1200");
  });
});

describe("Correction requests from Access config (terminal_request)", () => {
  it("offers arrival/departure plus only interruptions with terminal_request = true", () => {
    const types = correctionTypes(parseTerminalConfig(version, golden()));
    // zlatý súbor: terminal_request majú prerušenia 8 (Dovolenka), 11 (Nemoc) a 12 (Služobná cesta)
    expect(types.map((t) => [t.code, t.dir])).toEqual([
      ["WORK", "IN"],
      ["WORK", "OUT"],
      ["LEAVE", "OUT"],
      ["SICK", "OUT"],
      ["TRIP", "OUT"],
    ]);
  });
  it("falls back to the default list without configuration", () => {
    expect(correctionTypes(null)).toEqual(DEFAULT_CORRECTION_TYPES);
    const doc = golden();
    for (const it of doc.interruptions) it.terminal_request = false;
    expect(correctionTypes(parseTerminalConfig(version, doc))).toEqual(DEFAULT_CORRECTION_TYPES);
  });
  it("skips a request with ambiguous code mapping instead of offering a wrong code", () => {
    const doc = golden();
    doc.terminal_code_map.push({ code: "LEAVE2", interruption: 8 });
    const types = correctionTypes(parseTerminalConfig(version, doc));
    expect(types.map((t) => t.code)).toEqual(["WORK", "WORK", "SICK", "TRIP"]);
  });
  it("carries needs_approval and full_day_only flags from the config", () => {
    const config = parseTerminalConfig(version, golden());
    expect([...needsApprovalCodes(config)].sort()).toEqual(["LEAVE", "TRIP"]);
    expect([...fullDayCodes(config)].sort()).toEqual(["LEAVE", "SICK"]);
    expect(needsApprovalCodes(null).size).toBe(0);
    expect(fullDayCodes(null).size).toBe(0);
  });
  it("reads correction_deadline_day from rules, default 0", () => {
    expect(parseTerminalConfig(version, golden())?.correctionDeadlineDay).toBe(5);
    const doc = golden();
    delete doc.rules.correction_deadline_day;
    expect(parseTerminalConfig(version, doc)?.correctionDeadlineDay).toBe(0);
  });
  it("old cached snapshot without the new fields still parses with defaults", () => {
    const config = parseTerminalConfig(version, golden());
    if (!config) throw new Error("Fixture must parse");
    const legacy = JSON.parse(JSON.stringify(config)) as Record<string, unknown>;
    delete legacy["requests"];
    delete legacy["correctionDeadlineDay"];
    const key = terminalCacheKey("owner", "company");
    localStorage.setItem(key, JSON.stringify(legacy));
    const restored = readTerminalCache(localStorage, key);
    expect(restored?.requests).toEqual([]);
    expect(restored?.correctionDeadlineDay).toBe(0);
  });
});

describe("Correction deadline (correction_deadline_day)", () => {
  const now = new Date(2026, 10, 4); // 4. november 2026
  it("0 means no deadline", () => {
    expect(correctionDeadlineOk(new Date(2026, 0, 15), now, 0)).toBe(true);
  });
  it("current month is always allowed", () => {
    expect(correctionDeadlineOk(new Date(2026, 10, 1), now, 5)).toBe(true);
  });
  it("previous month is allowed until the deadline day", () => {
    expect(correctionDeadlineOk(new Date(2026, 9, 31), now, 5)).toBe(true);
    expect(correctionDeadlineOk(new Date(2026, 9, 31), now, 3)).toBe(false);
  });
  it("older months are never allowed once a deadline exists", () => {
    expect(correctionDeadlineOk(new Date(2026, 8, 30), now, 31)).toBe(false);
  });
  it("deadline across a year boundary", () => {
    const jan = new Date(2027, 0, 3);
    expect(correctionDeadlineOk(new Date(2026, 11, 20), jan, 5)).toBe(true);
    expect(correctionDeadlineOk(new Date(2026, 10, 20), jan, 5)).toBe(false);
  });
});
