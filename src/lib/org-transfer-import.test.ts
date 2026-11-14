import { Blob as NodeBlob } from "node:buffer";
import { webcrypto } from "node:crypto";
import { beforeAll, describe, expect, it, vi } from "vitest";
import { encryptText } from "./org-transfer-crypto";
import { TransferError, type RpcResponse, type TransferClient } from "./org-transfer";
import {
  COMMIT_UNKNOWN_MESSAGE,
  IMPORT_MISSING_MESSAGE,
  chunkRows,
  commitImport,
  getImportStatus,
  splitTransferText,
  uploadImport,
} from "./org-transfer-import";

beforeAll(() => {
  vi.stubGlobal("Blob", NodeBlob);
  vi.stubGlobal("crypto", webcrypto);
});

const PW = "správne-heslo-12345";
const IID = "7b0f7f4e-3d1c-4a69-9f0e-0a1b2c3d4e5f";
const ORG = "11111111-2222-4333-8444-555555555555";
const ORGANIZATION = { id: ORG, name: "Firma „Ľ“", code: "11111111" };

// Riadky s číslami a znakmi, ktoré by prevod cez JSON.parse/stringify alebo naivné krájanie pokazili.
const PROFILES = ['{"id": "u1", "daily_fund": 7.50}', '{"id": "u2", "daily_fund": 8.0, "n": 1e2}'];
const AUDIT = [
  '{"id": 1, "details": {"x": 1.0, "y": [0.10, 2.50], "s": "zátvorky } ] { [ , \\" \\\\"}}',
  '{"id": 2, "details": null}',
];
const META = `{"format": 2, "organization": {"id": "${ORG}", "name": "Firma „Ľ“"}, "counts": {"public.profiles": 2, "public.audit_log": 2, "public.devices": 0}, "x": 1.0}`;
const fileText = (profiles = PROFILES) =>
  `{"meta":${META},"tables":{"public.profiles":[${profiles.join(",")}], "public.devices" : [ ] ,"public.audit_log":[${AUDIT.join(" ,\n ")}]}}`;

const encrypted = (text: string) => encryptText(text, PW, { iterations: 100_000 });

interface Call {
  fn: string;
  args: Record<string, unknown>;
}

function fakeClient(
  over: Partial<Record<string, (args: Record<string, unknown>, n: number) => RpcResponse>> = {},
) {
  const calls: Call[] = [];
  const counts: Record<string, number> = {};
  const client: TransferClient = {
    rpc: async (fn, args = {}) => {
      calls.push({ fn, args });
      counts[fn] = (counts[fn] ?? 0) + 1;
      const custom = over[fn];
      if (custom) return custom(args, counts[fn]);
      switch (fn) {
        case "org_import_begin":
          return {
            error: null,
            data: {
              import_id: IID,
              organization: ORGANIZATION,
              tables: [
                { rel: "public.profiles", n: 2 },
                { rel: "public.devices", n: 0 },
                { rel: "public.audit_log", n: 2 },
              ],
              rows: 4,
              max_chunk_rows: 5000,
              max_chunk_chars: 6_000_000,
            },
          };
        case "org_import_chunk": {
          const rows = JSON.parse(args["_rows"] as string) as unknown[];
          return {
            error: null,
            data: {
              rel: args["_rel"],
              seq: args["_seq"],
              count: rows.length,
              received: rows.length,
            },
          };
        }
        case "org_import_check":
          return {
            error: null,
            data: {
              state: "checked",
              import_id: IID,
              organization: ORGANIZATION,
              counts: { "public.profiles": 2 },
              rows: 4,
              exported_at: "2026-11-12T19:00:00Z",
              warnings: [],
              replaces: { name: "Nová firma", code: "AAAAAAAA", eligible: true },
            },
          };
        case "org_import_cancel":
          return { error: null, data: { state: "cancelled" } };
        default:
          return { error: { message: `nečakané volanie ${fn}` }, data: null };
      }
    },
  };
  return { client, calls };
}

describe("splitTransferText", () => {
  it("vráti hlavičku a riadky presne v pôvodnom zápise", () => {
    const text = fileText();
    const split = splitTransferText(text);
    expect(split.metaText).toBe(META);
    expect(split.tables.map((t) => t.rel)).toEqual([
      "public.profiles",
      "public.devices",
      "public.audit_log",
    ]);
    const rows = (rel: string) => {
      const r = split.tables.find((t) => t.rel === rel)!.rows;
      const out: string[] = [];
      for (let k = 0; k < r.length; k += 2) out.push(text.slice(r[k], r[k + 1]));
      return out;
    };
    expect(rows("public.profiles")).toEqual(PROFILES);
    expect(rows("public.devices")).toEqual([]);
    expect(rows("public.audit_log")).toEqual(AUDIT);
  });

  it.each([
    ["nie je JSON", "ahoj"],
    ["chýba meta", '{"tables":{}}'],
    ["chýbajú tabuľky", '{"meta":{}}'],
    ["tabuľka nie je pole", '{"meta":{},"tables":{"public.profiles":{}}}'],
    ["riadok nie je objekt", '{"meta":{},"tables":{"public.profiles":[1]}}'],
    ["useknutý súbor", fileText().slice(0, -20)],
    ["text za koncom", `${fileText()} x`],
    ["tabuľka dvakrát", '{"meta":{},"tables":{"a":[],"a":[]}}'],
  ])("odmietne súbor: %s", (_name, text) => {
    expect(() => splitTransferText(text)).toThrow(TransferError);
  });
});

describe("chunkRows", () => {
  it("delí podľa počtu riadkov aj znakov a nič nestratí", () => {
    const rows = Array.from({ length: 7 }, (_, i) => `{"id": ${i}, "v": 1.0}`);
    const text = `[${rows.join(",")}]`;
    const offsets: number[] = [];
    let at = 1;
    for (const r of rows) {
      offsets.push(at, at + r.length);
      at += r.length + 1;
    }
    const byRows = [...chunkRows(text, offsets, 3, 1_000_000)];
    expect(byRows.map((c) => c.count)).toEqual([3, 3, 1]);
    expect(byRows.map((c) => c.rows.slice(1, -1)).join(",")).toBe(rows.join(","));
    const byChars = [...chunkRows(text, offsets, 100, 45)];
    expect(byChars.every((c) => c.rows.length <= 45)).toBe(true);
    expect(byChars.reduce((s, c) => s + c.count, 0)).toBe(7);
    // riadok väčší než hranica ide sám
    expect([...chunkRows(text, offsets, 100, 5)].map((c) => c.count)).toEqual([
      1, 1, 1, 1, 1, 1, 1,
    ]);
  });
});

describe("uploadImport", () => {
  it("nahrá hlavičku a riadky ako nezmenený text a vráti výsledok kontroly", async () => {
    const { client, calls } = fakeClient();
    const phases: string[] = [];
    const checked = await uploadImport(client, {
      file: await encrypted(fileText()),
      password: PW,
      chunkRows: 1,
      onProgress: (p) => phases.push(p.phase),
    });
    expect(checked).toMatchObject({
      importId: IID,
      organizationName: "Firma „Ľ“",
      replacesName: "Nová firma",
      rows: 4,
    });
    expect(calls[0]).toEqual({ fn: "org_import_begin", args: { _meta: META } });
    const chunks = calls.filter((c) => c.fn === "org_import_chunk");
    expect(chunks.map((c) => [c.args["_rel"], c.args["_seq"], c.args["_rows"]])).toEqual([
      ["public.profiles", 0, `[${PROFILES[0]}]`],
      ["public.profiles", 1, `[${PROFILES[1]}]`],
      ["public.audit_log", 0, `[${AUDIT[0]}]`],
      ["public.audit_log", 1, `[${AUDIT[1]}]`],
    ]);
    expect(calls.at(-1)?.fn).toBe("org_import_check");
    expect([...new Set(phases)]).toEqual(["decrypt", "begin", "upload", "check"]);
  });

  it("zlé heslo: na server sa nič nepošle", async () => {
    const { client, calls } = fakeClient();
    await expect(
      uploadImport(client, { file: await encrypted(fileText()), password: "zlé-heslo-1234567" }),
    ).rejects.toMatchObject({ kind: "invalid" });
    expect(calls).toEqual([]);
  });

  it("súbor, ktorý nie je prenos, sa odmietne pred prvým volaním", async () => {
    const { client, calls } = fakeClient();
    await expect(
      uploadImport(client, { file: await encrypted('{"ahoj": 1}'), password: PW }),
    ).rejects.toMatchObject({ kind: "invalid" });
    expect(calls).toEqual([]);
  });

  it("neúplný súbor: chyba nesie id importu, aby sa dal zahodiť", async () => {
    const { client } = fakeClient();
    const err = await uploadImport(client, {
      file: await encrypted(fileText([PROFILES[0]!])),
      password: PW,
    }).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(TransferError);
    expect(err).toMatchObject({ kind: "incomplete", transferId: IID });
  });

  it("časť sa po zlyhaní spojenia pošle znova s rovnakým poradím", async () => {
    const { client, calls } = fakeClient({
      org_import_chunk: (args, n) =>
        n === 1
          ? { data: null, error: { message: "TypeError: Failed to fetch" } }
          : { error: null, data: { rel: args["_rel"], seq: args["_seq"], count: 2, received: 2 } },
    });
    await uploadImport(client, {
      file: await encrypted(fileText()),
      password: PW,
      sleep: async () => {},
    });
    const chunks = calls.filter((c) => c.fn === "org_import_chunk");
    expect(chunks.map((c) => [c.args["_rel"], c.args["_seq"]])).toEqual([
      ["public.profiles", 0],
      ["public.profiles", 0],
      ["public.audit_log", 0],
    ]);
  });

  it("odmietnutie databázou sa neopakuje a text chyby ostáva", async () => {
    const { client, calls } = fakeClient({
      org_import_begin: () => ({
        data: null,
        error: { code: "P0001", message: "Do tejto organizácie sa importovať nedá: má údaje." },
      }),
    });
    const err = await uploadImport(client, {
      file: await encrypted(fileText()),
      password: PW,
    }).catch((e: unknown) => e);
    expect(err).toMatchObject({ kind: "database", transferId: null });
    expect((err as Error).message).toContain("importovať nedá");
    expect(calls).toHaveLength(1);
  });

  it("prerušenie zastaví nahrávanie", async () => {
    const controller = new AbortController();
    const { client, calls } = fakeClient({
      org_import_chunk: (args) => {
        controller.abort();
        return {
          error: null,
          data: { rel: args["_rel"], seq: args["_seq"], count: 1, received: 1 },
        };
      },
    });
    await expect(
      uploadImport(client, {
        file: await encrypted(fileText()),
        password: PW,
        chunkRows: 1,
        signal: controller.signal,
      }),
    ).rejects.toMatchObject({ kind: "aborted", transferId: IID });
    expect(calls.filter((c) => c.fn === "org_import_chunk")).toHaveLength(1);
    expect(calls.some((c) => c.fn === "org_import_check")).toBe(false);
  });

  it("chýbajúca migrácia má vlastné hlásenie", async () => {
    const { client } = fakeClient({
      org_import_status: () => ({ data: null, error: { code: "PGRST202", message: "x" } }),
    });
    await expect(getImportStatus(client)).rejects.toMatchObject({
      kind: "missing",
      message: IMPORT_MISSING_MESSAGE,
    });
  });
});

describe("commitImport", () => {
  const ok = {
    state: "done",
    organization: ORGANIZATION,
    receipt: "AB12-CD34",
    rows: 4,
    ids_mode: "renumber",
    warnings: [],
  };

  it("vráti kód potvrdenia", async () => {
    const { client, calls } = fakeClient({ org_import_commit: () => ({ error: null, data: ok }) });
    await expect(
      commitImport(client, { importId: IID, confirmName: "Nová firma" }),
    ).resolves.toMatchObject({
      receipt: "AB12-CD34",
      renumbered: true,
      organizationCode: "11111111",
    });
    expect(calls).toEqual([
      { fn: "org_import_commit", args: { _import: IID, _confirm_name: "Nová firma" } },
    ]);
  });

  it("po zlyhaní spojenia sa neopakuje a povie, že výsledok nie je istý", async () => {
    const { client, calls } = fakeClient({
      org_import_commit: () => ({ data: null, error: { message: "Failed to fetch" } }),
    });
    await expect(
      commitImport(client, { importId: IID, confirmName: "Nová firma" }),
    ).rejects.toMatchObject({ kind: "transport", message: COMMIT_UNKNOWN_MESSAGE });
    expect(calls).toHaveLength(1);
  });

  it("odpoveď bez platného kódu potvrdenia odmietne", async () => {
    const { client } = fakeClient({
      org_import_commit: () => ({ error: null, data: { ...ok, receipt: "zle" } }),
    });
    await expect(
      commitImport(client, { importId: IID, confirmName: "Nová firma" }),
    ).rejects.toMatchObject({ kind: "invalid" });
  });

  it("vypršanie času databázy preloží do zrozumiteľnej vety", async () => {
    const { client } = fakeClient({
      org_import_commit: () => ({
        data: null,
        error: { code: "57014", message: "canceling statement due to statement timeout" },
      }),
    });
    const err = await commitImport(client, { importId: IID, confirmName: "x" }).catch(
      (e: unknown) => e,
    );
    expect((err as Error).message).toContain("nič sa nezmenilo");
  });
});
