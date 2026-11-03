// Kontraktový test v1.1: zoznam zneplatnených razení musí byť bajt po bajte rovnaký ako zlatý súbor.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { sha256Hex } from "../reference/punch-export";
import { buildVoidExportCsv, type VoidRow } from "../reference/void-export";
import { buildVoidExportCsv as buildApp } from "../../src/lib/void-export";

const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "examples");
const input = JSON.parse(readFileSync(join(dir, "voids_example.input.json"), "utf8")) as VoidRow[];
const punches = JSON.parse(readFileSync(join(dir, "punches_example.input.json"), "utf8")) as {
  id: number;
  client_uuid: string;
  record_hash: string;
  sap_id: string;
}[];
const goldenPath = join(dir, "voids_example.csv");

describe("zoznam zneplatnených razení pre Access – kontrakt v1.1", () => {
  it("zodpovedá zlatému súboru (vrátane pätičky so SHA-256)", async () => {
    if (!existsSync(goldenPath) && process.env.WRITE_GOLDEN === "1") {
      writeFileSync(goldenPath, await buildVoidExportCsv(input), "utf8");
    }
    expect(await buildVoidExportCsv(input)).toBe(readFileSync(goldenPath, "utf8"));
  });
  it("aplikačný kód dáva rovnaký súbor ako referencia", async () => {
    expect(await buildApp(input)).toBe(await buildVoidExportCsv(input));
  });
  it("poradie vstupu nehrá rolu", async () => {
    expect(await buildVoidExportCsv([...input].reverse())).toBe(await buildVoidExportCsv(input));
  });
  it("každé zneplatnené razenie existuje v zlatom súbore razení s rovnakým external_id a hashom", () => {
    for (const v of input) {
      const p = punches.find((x) => x.id === v.id);
      expect(p?.client_uuid).toBe(v.client_uuid);
      expect(p?.record_hash).toBe(v.record_hash);
      expect(p?.sap_id).toBe(v.sap_id);
    }
  });
  it("pätička obsahuje počet riadkov a SHA-256 tela", async () => {
    const csv = readFileSync(goldenPath, "utf8");
    const at = csv.lastIndexOf("#END;");
    expect(csv.slice(at)).toBe(
      `#END;rows=${input.length};sha256=${await sha256Hex(csv.slice(1, at))}\r\n`,
    );
  });
});
