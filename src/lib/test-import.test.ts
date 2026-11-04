import { describe, expect, it } from "vitest";
import { sha256Hex } from "./punch-export";
import {
  BALANCE_HEADER,
  buildBalanceCsv,
  existingInOrganization,
  MAX_TEST_ROWS,
  parseTestCsv,
  testPunchUuid,
  verifyChain,
  type BalanceDay,
  type ChainRow,
} from "./test-import";

const CODES = new Set(["WORK", "TRIP", "DOCTOR", "FAMILY", "LEAVE", "SICK", "PRIV"]);
const HEAD = "osobne_cislo;datum;cas;kod;smer";

describe("parseTestCsv", () => {
  it("prečíta správny súbor a prevedie miestny čas na UTC", () => {
    const r = parseTestCsv(
      `${HEAD}\r\n9000001;2026-11-02;07:00:12;WORK;IN\r\n9000001;2026-11-02;15:30;work;out\r\n`,
      CODES,
    );
    expect(r.issues).toEqual([]);
    expect(r.rows.length).toBe(2);
    expect(r.rows[0]!.utc.toISOString()).toBe("2026-11-02T06:00:12.000Z");
    expect(r.rows[1]!.local).toBe("2026-11-02 15:30:00");
    expect(r.rows[1]!.code).toBe("WORK");
    expect(r.rows[1]!.direction).toBe("OUT");
  });
  it("zvláda BOM, komentáre, čiarku ako oddeľovač, slovenský dátum a prehodené stĺpce", () => {
    const r = parseTestCsv(
      `﻿# test\nSMER,KOD,CAS,DATUM,Osobné číslo\nIN,WORK,7:05,2.11.2026,9000002\n`,
      CODES,
    );
    expect(r.issues).toEqual([]);
    expect(r.rows[0]!.sap).toBe("9000002");
    expect(r.rows[0]!.local).toBe("2026-11-02 07:05:00");
  });
  it("hlási chýbajúci stĺpec", () => {
    const r = parseTestCsv("osobne_cislo;datum;cas;kod\n9000001;2026-11-02;07:00;WORK\n", CODES);
    expect(r.rows.length).toBe(0);
    expect(r.issues[0]!.text).toMatch(/smer/);
  });
  it("hlási chyby po riadkoch a nezapíše chybné riadky", () => {
    const r = parseTestCsv(
      `${HEAD}\n900000;2026-11-02;07:00;WORK;IN\n9000001;2026-02-30;07:00;WORK;IN\n9000001;2026-11-02;25:00;WORK;IN\n9000001;2026-11-02;07:00;ABC;IN\n9000001;2026-11-02;07:00;WORK;X\n9000001;2026-11-02;07:00;WORK;IN\n`,
      CODES,
    );
    expect(r.issues.length).toBe(5);
    expect(r.issues.map((i) => i.line)).toEqual([2, 3, 4, 5, 6]);
    expect(r.rows.length).toBe(1);
  });
  it("odmietne čas z preskočenej hodiny", () => {
    const r = parseTestCsv(`${HEAD}\n9000001;2026-03-29;02:30;WORK;IN\n`, CODES);
    expect(r.issues[0]!.text).toMatch(/neexistuje/);
  });
  it("vynechá opakujúci sa riadok a spočíta ho", () => {
    const r = parseTestCsv(`${HEAD}\n9000001;2026-11-02;07:00:00;WORK;IN\n9000001;2026-11-02;07:00:00;WORK;IN\n`, CODES);
    expect(r.rows.length).toBe(1);
    expect(r.duplicatesInFile).toBe(1);
  });
  it("prázdny súbor a príliš veľa riadkov", () => {
    expect(parseTestCsv("", CODES).issues.length).toBe(1);
    const many = [HEAD, ...Array.from({ length: MAX_TEST_ROWS + 1 }, () => "9000001;2026-11-02;07:00;WORK;IN")];
    expect(parseTestCsv(many.join("\n"), CODES).issues[0]!.text).toMatch(/najviac/);
  });
});

describe("testPunchUuid", () => {
  const row = { sap: "9000001", code: "WORK", direction: "IN" as const, utc: new Date("2026-11-02T06:00:12Z") };
  it("je stály a má tvar UUID v4", async () => {
    const a = await testPunchUuid(row);
    expect(a).toBe(await testPunchUuid(row));
    expect(a).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  });
  it("líši sa pri zmene času alebo smeru", async () => {
    const a = await testPunchUuid(row);
    expect(a === (await testPunchUuid({ ...row, direction: "OUT" }))).toBe(false);
    expect(a === (await testPunchUuid({ ...row, utc: new Date("2026-11-02T06:00:13Z") }))).toBe(false);
  });
  it("s organizáciou je stály, líši sa medzi organizáciami aj od pôvodného tvaru bez organizácie", async () => {
    const org1 = "00000000-0000-4000-8000-0000000000a1";
    const org2 = "00000000-0000-4000-8000-0000000000a2";
    const a = await testPunchUuid(row, org1);
    expect(a).toBe(await testPunchUuid(row, org1));
    expect(a).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    expect(a === (await testPunchUuid(row, org2))).toBe(false);
    expect(a === (await testPunchUuid(row))).toBe(false);
  });
});

describe("existingInOrganization", () => {
  const mine = "11111111-1111-4111-8111-111111111111";
  const other = "22222222-2222-4222-8222-222222222222";
  const found = [
    { client_uuid: "u-moje", user_id: mine },
    { client_uuid: "u-cudzie", user_id: other },
  ];
  it("započíta len razenia účtov tejto organizácie", () => {
    expect([...existingInOrganization(found, new Set([mine]))]).toEqual(["u-moje"]);
  });
  it("razenie rovnakého človeka v inej organizácii import neblokuje", () => {
    expect(existingInOrganization([found[1]!], new Set([mine])).size).toBe(0);
    expect(existingInOrganization([], new Set([mine])).size).toBe(0);
  });
});

async function makeChain(): Promise<ChainRow[]> {
  const user = "11111111-1111-4111-8111-111111111111";
  const base = [
    { code: "WORK", direction: "IN", client_time: "2026-10-05T05:00:00+00:00", server_time: "2026-11-03T08:12:45.123456+00:00", uuid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" },
    { code: "WORK", direction: "OUT", client_time: "2026-10-05T13:30:00+00:00", server_time: "2026-11-03T08:12:45.223456+00:00", uuid: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" },
  ];
  const rows: ChainRow[] = [];
  let prev = "GENESIS";
  for (const [i, b] of base.entries()) {
    const text =
      `${prev}|${user}|${b.code}|${b.direction}|` +
      `${new Date(b.client_time).toISOString().slice(0, 19)}|${new Date(b.server_time).toISOString().slice(0, 19)}|${b.uuid}`;
    const hash = await sha256Hex(text);
    rows.push({
      id: i + 1,
      user_id: user,
      code: b.code,
      direction: b.direction,
      client_time: b.client_time,
      server_time: b.server_time,
      client_uuid: b.uuid,
      device_id: null,
      prev_hash: prev,
      record_hash: hash,
    });
    prev = hash;
  }
  return rows;
}

describe("verifyChain", () => {
  it("prijme správnu reťaz vrátane času z databázy s mikrosekundami", async () => {
    expect((await verifyChain(await makeChain())).ok).toBe(true);
  });
  it("odhalí zmenený obsah", async () => {
    const rows = await makeChain();
    rows[0]!.code = "PRIV";
    const r = await verifyChain(rows);
    expect(r.ok).toBe(false);
  });
  it("odhalí pretrhnutú nadväznosť", async () => {
    const rows = await makeChain();
    rows[1]!.prev_hash = "x";
    const r = await verifyChain(rows);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.id).toBe(2);
  });
});

describe("buildBalanceCsv", () => {
  const day = (sap: string, key: string, extra: Partial<BalanceDay> = {}): BalanceDay => ({
    sap,
    key,
    weekend: false,
    holiday: false,
    expectedMin: 450,
    totalMin: 480,
    balanceMin: 30,
    workMin: 480,
    creditMin: 0,
    breakMin: 30,
    open: false,
    byCode: { WORK: 480 },
    ...extra,
  });
  it("má hlavičku s rovnakými názvami ako Access a zoraďuje podľa čísla a dňa", () => {
    const csv = buildBalanceCsv([day("9000002", "2026-10-02"), day("9000001", "2026-10-03", { weekend: true }), day("9000001", "2026-10-02")]);
    const lines = csv.replace("﻿", "").trim().split("\r\n");
    expect(lines[0]).toBe(BALANCE_HEADER.join(";"));
    expect(lines[0]).toMatch(/fond_min;odpracovane_min;saldo_min/);
    expect(lines[1]).toBe("9000001;2026-10-02;PP;450;480;30;480;0;30;0;WORK:480");
    expect(lines[2]!.split(";")[2]).toBe("VO");
    expect(lines[3]!.startsWith("9000002;")).toBe(true);
  });
});
