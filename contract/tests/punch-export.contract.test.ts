// Kontraktový test: export z terminálu musí byť bajt po bajte rovnaký ako zlatý súbor v contract/examples.
// Zlatý súbor generuje a overuje strana Access (tools/verify_export.py) – ak test padne, kontrakt sa zmenil.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  buildPunchExportCsv,
  chainInput,
  sha256Hex,
  localTime,
  type PunchDbRow,
} from "../reference/punch-export";

const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "examples");
const input = JSON.parse(
  readFileSync(join(dir, "punches_example.input.json"), "utf8"),
) as PunchDbRow[];
const golden = readFileSync(join(dir, "punches_example.csv"), "utf8");

describe("export razení pre Access – kontrakt v1", () => {
  it("zodpovedá zlatému súboru (vrátane pätičky so SHA-256)", async () => {
    expect(await buildPunchExportCsv(input)).toBe(golden);
  });

  it("poradie vstupu nehrá rolu (radí podľa punch_id)", async () => {
    expect(await buildPunchExportCsv([...input].reverse())).toBe(golden);
  });

  it("record_hash sa dá prepočítať rovnakým vzorcom ako v databázovom triggeri", async () => {
    for (const r of input) expect(await sha256Hex(chainInput(r))).toBe(r.record_hash);
  });

  it("reťaz je súvislá pre každého používateľa", () => {
    const last = new Map<string, string>();
    for (const r of [...input].sort((a, b) => a.id - b.id)) {
      expect(r.prev_hash).toBe(last.get(r.user_id) ?? "GENESIS");
      last.set(r.user_id, r.record_hash);
    }
  });

  it("lokálny čas rešpektuje letný/zimný čas", () => {
    expect(localTime("2026-11-02T04:58:12Z")).toBe("2026-11-02 05:58:12"); // CET = UTC+1
    expect(localTime("2026-07-01T04:58:12Z")).toBe("2026-07-01 06:58:12"); // CEST = UTC+2
    expect(localTime("2026-10-25T00:30:00Z")).toBe("2026-10-25 02:30:00"); // pred zmenou času (CEST)
    expect(localTime("2026-10-25T01:30:00Z")).toBe("2026-10-25 02:30:00"); // po zmene (CET) – rovnaký lokálny čas, preto aj UTC v exporte
  });
});
