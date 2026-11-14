// Odpovede RPC migrácie 0022 pre testy. Predvolená terminálová verzia je skutočný výstup databázy zo sandboxu
// (settings_default_config), verzia z Accessu je zlatý súbor kontraktu bez zamestnancov.
import { readFileSync } from "node:fs";

export const ID_TERMINAL = "11111111-1111-4111-8111-111111111111";
export const ID_ACCESS = "22222222-2222-4222-8222-222222222222";

export function terminalConfig(): Record<string, unknown> {
  return JSON.parse(readFileSync("src/lib/__fixtures__/settings-default-terminal.json", "utf8"));
}
export function accessConfig(): Record<string, unknown> {
  const { employees: _employees, ...rest } = JSON.parse(
    readFileSync("contract/examples/config_example.json", "utf8"),
  );
  return rest;
}

export const terminalVersion = {
  id: ID_TERMINAL,
  ord: 1,
  origin: "terminal",
  valid_from: "2026-09",
  reason: "registration",
  config_version: null,
  period_from: null,
  period_to: null,
  created_at: "2026-09-02T08:00:00Z",
};
export const accessVersion = {
  id: ID_ACCESS,
  ord: 2,
  origin: "access",
  valid_from: "2026-11",
  reason: "import",
  config_version: "2026.11.04.1200",
  period_from: "2026-10",
  period_to: "2026-12",
  created_at: "2026-11-13T09:00:00Z",
};

/** Odpoveď settings_for_month: mesiac 11/2026 patrí terminálu alebo Accessu. */
export function forMonthResponse(origin: "terminal" | "access", closure: unknown = null) {
  return {
    month: "2026-11",
    version: origin === "access" ? accessVersion : terminalVersion,
    config: origin === "access" ? accessConfig() : terminalConfig(),
    max_drift_min: 10,
    closure,
  };
}

/** Odpoveď settings_timeline. */
export function timelineResponse(origin: "terminal" | "access") {
  return {
    month_now: "2026-11",
    current: origin === "access" ? accessVersion : terminalVersion,
    oldest_open: "2026-10",
    open_months: [
      { month: "2026-10", open: 2, closed: 1 },
      { month: "2026-11", open: 3, closed: 0 },
    ],
    last_access: origin === "access" ? accessVersion : null,
    last_terminal: terminalVersion,
    versions: origin === "access" ? [terminalVersion, accessVersion] : [terminalVersion],
  };
}
