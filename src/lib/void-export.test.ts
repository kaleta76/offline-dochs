import { describe, expect, it } from "vitest";
import { sha256Hex } from "./punch-export";
import { buildVoidExportCsv, toVoidRows, voidFileName, VOID_HEADER, type VoidRow } from "./void-export";

const row = (id: number, extra: Partial<VoidRow> = {}): VoidRow => ({
  id,
  organization_id: "0b6f2f0e-5a7e-4b8e-9a43-2c1d5e7a9f01",
  client_uuid: `c0000000-0000-4000-8000-${String(id).padStart(12, "0")}`,
  sap_id: "9000001",
  user_id: "6d1c3b84-0001-4a2e-8c11-000000000001",
  voided_at: "2026-11-03T09:15:42.123456+00:00",
  record_hash: "a".repeat(64),
  ...extra,
});

describe("buildVoidExportCsv", () => {
  it("má BOM, hlavičku, riadky zoradené podľa id a pätičku so SHA-256", async () => {
    const csv = await buildVoidExportCsv([row(9), row(3)]);
    expect(csv.startsWith("﻿")).toBe(true);
    const footerAt = csv.lastIndexOf("#END;");
    const body = csv.slice(1, footerAt);
    const lines = body.split("\r\n");
    expect(lines[0]).toBe(VOID_HEADER.join(";"));
    expect(lines[1]!.split(";")[2]).toBe("3");
    expect(lines[2]!.split(";")[2]).toBe("9");
    expect(lines[1]).toBe(
      '1;"0b6f2f0e-5a7e-4b8e-9a43-2c1d5e7a9f01";3;"c0000000-0000-4000-8000-000000000003";"9000001";"6d1c3b84-0001-4a2e-8c11-000000000001";"2026-11-03T09:15:42Z";"' +
        "a".repeat(64) +
        '"',
    );
    expect(csv.slice(footerAt)).toBe(`#END;rows=2;sha256=${await sha256Hex(body)}\r\n`);
  });
  it("prázdny zoznam má pätičku s rows=0", async () => {
    expect((await buildVoidExportCsv([])).endsWith("#END;rows=0;sha256=" + (await sha256Hex(VOID_HEADER.join(";") + "\r\n")) + "\r\n")).toBe(true);
  });
});

describe("toVoidRows a názov súboru", () => {
  const sap = new Map([["u1", "9000001"]]);
  it("spojí osobné číslo", () => {
    const r = toVoidRows([{ id: 1, client_uuid: "x", user_id: "u1", voided_at: "2026-11-03T00:00:00Z", record_hash: "h" }], sap, "org");
    expect(r[0]!.sap_id).toBe("9000001");
    expect(r[0]!.organization_id).toBe("org");
  });
  it("zastaví export pri chýbajúcom osobnom čísle alebo hashi", () => {
    expect(() => toVoidRows([{ id: 1, client_uuid: "x", user_id: "u2", voided_at: "2026-11-03T00:00:00Z", record_hash: "h" }], sap, "org")).toThrow(/osobného čísla/);
    expect(() => toVoidRows([{ id: 1, client_uuid: "x", user_id: "u1", voided_at: "2026-11-03T00:00:00Z", record_hash: null }], sap, "org")).toThrow(/hash/);
  });
  it("názov súboru", () => {
    expect(voidFileName(2026, 10)).toBe("voids_202610.csv");
  });
});
