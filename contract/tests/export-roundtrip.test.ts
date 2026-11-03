// Overuje, že kód v aplikácii (src/lib) vytvára pre ukážkové dáta presne zlatý súbor kontraktu
// a že src/lib/punch-export.ts je verná kópia referencie v contract/reference.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { buildPunchExportCsv, type PunchDbRow } from "../../src/lib/punch-export";
import { toExportRows } from "../../src/lib/punch-export-range";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (...p: string[]) => readFileSync(join(root, ...p), "utf8");
const input = JSON.parse(
  read("contract", "examples", "punches_example.input.json"),
) as PunchDbRow[];
const golden = read("contract", "examples", "punches_example.csv");

describe("export v aplikácii sa zhoduje s kontraktom", () => {
  it("src/lib/punch-export.ts je bajt po bajte kópia contract/reference/punch-export.ts", () => {
    expect(read("src", "lib", "punch-export.ts")).toBe(
      read("contract", "reference", "punch-export.ts"),
    );
  });

  it("riadky z databázy -> toExportRows -> buildPunchExportCsv dá zlatý súbor", async () => {
    const orgId = input[0]?.organization_id ?? "";
    const profiles = [...new Map(input.map((r) => [r.user_id, r.sap_id])).entries()].map(
      ([id, sap_id]) => ({ id, sap_id }),
    );
    // tvar riadku tak, ako ho vracia databáza (bez organization_id a sap_id)
    const dbRows = input.map(({ organization_id: _o, sap_id: _s, ...rest }) => rest);
    const rows = toExportRows(dbRows, profiles, orgId);
    expect(rows).toEqual(input);
    expect(await buildPunchExportCsv(rows)).toBe(golden);
  });
});
