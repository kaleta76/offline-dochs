import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  DEFAULT_TERMINAL_ACTIONS,
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
