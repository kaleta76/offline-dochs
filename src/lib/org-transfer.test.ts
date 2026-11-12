import { Blob as NodeBlob } from "node:buffer";
import { webcrypto } from "node:crypto";
import { beforeAll, describe, expect, it, vi } from "vitest";
import { decryptToText, encryptText } from "./org-transfer-crypto";
import {
  MISSING_MESSAGE,
  TRANSPORT_MESSAGE,
  TransferError,
  cancelTransfer,
  confirmTransferAndDelete,
  describeChanges,
  exportOrganization,
  getTransferStatus,
  normalizeReceipt,
  parsePage,
  parseStatus,
  transferFileName,
  verifyTransferFile,
  type RpcResponse,
  type TransferClient,
} from "./org-transfer";

beforeAll(() => {
  vi.stubGlobal("Blob", NodeBlob);
  vi.stubGlobal("crypto", webcrypto);
});

const PW = "správne-heslo-12345";
const FAST = { iterations: 100_000, chunkBytes: 64 };
const TID = "7b0f7f4e-3d1c-4a69-9f0e-0a1b2c3d4e5f";
const ORG = "11111111-2222-4333-8444-555555555555";

// Riadky tak, ako ich vráti databáza: text s presne zachovanými číslami (7.50, 8.0) aj diakritikou.
const ROWS: Record<string, string[]> = {
  "public.profiles": [
    '{"id": "u1", "daily_fund": 7.50, "name": "Ľ"}',
    '{"id": "u2", "daily_fund": 8.0, "cfg": {"x": 1.0, "y": [0.10]}}',
  ],
  "public.punches": [
    '{"id": 1, "code": "WORK"}',
    '{"id": 2, "code": "TRIP"}',
    '{"id": 3, "code": "WORK"}',
  ],
  "public.empty_table": [],
};

const meta = {
  format: 2,
  tool: "org_transfer 2",
  organization: { id: ORG, name: "Firma „Ľ“", code: "11111111", is_test: false },
  counts: { "public.profiles": 2, "public.punches": 3, "public.empty_table": 0 },
  fingerprint: { "public.punches": { n: 3, d: "abc" } },
};
const beginPayload = {
  transfer_id: TID,
  locked: true,
  meta,
  tables: Object.entries(ROWS).map(([rel, r]) => ({ rel, n: r.length })),
  page_size: 2000,
};

interface FakeOptions {
  failPage?: (rel: string, offset: number, attempt: number) => RpcResponse | null;
  pageOverride?: (rel: string, offset: number) => unknown;
  finish?: RpcResponse;
  begin?: RpcResponse;
}

function fakeClient(opts: FakeOptions = {}) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const attempts = new Map<string, number>();
  const client: TransferClient = {
    async rpc(fn, args = {}) {
      calls.push({ fn, args });
      if (fn === "org_export_begin") return opts.begin ?? { data: beginPayload, error: null };
      if (fn === "org_export_page") {
        const rel = String(args["_rel"]);
        const offset = Number(args["_offset"]);
        const limit = Number(args["_limit"]);
        const key = `${rel}:${offset}`;
        const attempt = (attempts.get(key) ?? 0) + 1;
        attempts.set(key, attempt);
        const failed = opts.failPage?.(rel, offset, attempt);
        if (failed) return failed;
        if (opts.pageOverride) return { data: opts.pageOverride(rel, offset), error: null };
        const slice = (ROWS[rel] ?? []).slice(offset, offset + limit);
        return {
          data: { rel, offset, count: slice.length, rows: `[${slice.join(", ")}]` },
          error: null,
        };
      }
      if (fn === "org_export_finish") {
        return (
          opts.finish ?? {
            data: {
              state: "exported",
              transfer_id: TID,
              locked: true,
              is_test: true,
              protected: false,
            },
            error: null,
          }
        );
      }
      return { data: null, error: { message: `neznáma funkcia ${fn}` } };
    },
  };
  return { client, calls };
}

const run = (
  client: TransferClient,
  extra: Partial<Parameters<typeof exportOrganization>[1]> = {},
) =>
  exportOrganization(client, {
    lock: true,
    password: PW,
    encrypt: FAST,
    sleep: async () => {},
    ...extra,
  });

describe("exportOrganization", () => {
  it("vytvorí šifrovaný súbor, v ktorom sú riadky nezmenené (7.50 a 8.0 ostanú) a ktorý je platný JSON formátu 2", async () => {
    const { client } = fakeClient();
    const result = await run(client, { pageSize: 2 });
    const text = await decryptToText(result.blob, PW);
    expect(text).toContain('"daily_fund": 7.50');
    expect(text).toContain('"x": 1.0, "y": [0.10]');
    const parsed = JSON.parse(text) as { meta: typeof meta; tables: Record<string, unknown[]> };
    expect(parsed.meta).toEqual(meta);
    expect(Object.keys(parsed.tables)).toEqual(Object.keys(ROWS));
    for (const [rel, rows] of Object.entries(ROWS))
      expect(parsed.tables[rel]).toHaveLength(rows.length);
    expect(result.counts).toEqual({
      "public.profiles": 2,
      "public.punches": 3,
      "public.empty_table": 0,
    });
    expect(result.rows).toBe(5);
    expect(result.transferId).toBe(TID);
    expect(result.isTest).toBe(true);
    expect(result.organizationName).toBe("Firma „Ľ“");
  });

  it("súbor neobsahuje čitateľný obsah a nesprávne heslo ho neotvorí", async () => {
    const { client } = fakeClient();
    const result = await run(client);
    const bytes = Buffer.from(await result.blob.arrayBuffer());
    expect(bytes.includes(Buffer.from("WORK"))).toBe(false);
    expect(bytes.includes(Buffer.from("Firma"))).toBe(false);
    await expect(decryptToText(result.blob, "iné-heslo-123456")).rejects.toThrow(/nesprávne heslo/);
  });

  it("číta po stránkach zvolenej veľkosti a pošle serveru presné počty prijatých riadkov", async () => {
    const { client, calls } = fakeClient();
    await run(client, { pageSize: 2 });
    const pages = calls.filter((c) => c.fn === "org_export_page");
    expect(pages.map((c) => `${c.args["_rel"]}:${c.args["_offset"]}`)).toEqual([
      "public.profiles:0",
      "public.punches:0",
      "public.punches:2",
    ]);
    expect(pages.every((c) => c.args["_limit"] === 2 && c.args["_transfer"] === TID)).toBe(true);
    const finish = calls.find((c) => c.fn === "org_export_finish");
    expect(finish?.args).toEqual({
      _transfer: TID,
      _received: { "public.profiles": 2, "public.punches": 3, "public.empty_table": 0 },
    });
    expect(calls.map((c) => c.fn)[0]).toBe("org_export_begin");
    expect(calls.find((c) => c.fn === "org_export_begin")?.args).toEqual({ _lock: true });
  });

  it("veľkosť stránky sa obmedzí na 5 000 a zámok sa dá vypnúť", async () => {
    const { client, calls } = fakeClient();
    await run(client, { pageSize: 999999, lock: false });
    expect(calls.find((c) => c.fn === "org_export_begin")?.args).toEqual({ _lock: false });
    expect(calls.find((c) => c.fn === "org_export_page")?.args["_limit"]).toBe(5000);
  });

  it("krátke heslo sa odmietne ešte pred prvým volaním databázy (zámok sa nezačne)", async () => {
    const { client, calls } = fakeClient();
    await expect(run(client, { password: "krátke" })).rejects.toThrow(/aspoň 12 znakov/);
    expect(calls).toHaveLength(0);
  });

  it("pri výpadku spojenia pri čítaní stránky ju zopakuje a export dokončí", async () => {
    const { client, calls } = fakeClient({
      failPage: (rel, offset, attempt) =>
        rel === "public.punches" && offset === 0 && attempt < 3
          ? { data: null, error: { message: "TypeError: Failed to fetch" } }
          : null,
    });
    const sleeps: number[] = [];
    const result = await run(client, { sleep: async (ms) => void sleeps.push(ms) });
    expect(result.rows).toBe(5);
    expect(
      calls.filter(
        (c) =>
          c.fn === "org_export_page" &&
          c.args["_rel"] === "public.punches" &&
          c.args["_offset"] === 0,
      ),
    ).toHaveLength(3);
    expect(sleeps).toEqual([1000, 2000]);
  });

  it("trvalý výpadok spojenia skončí chybou s číslom prenosu, zápisy sa nezopakujú a súbor sa nevráti", async () => {
    const { client, calls } = fakeClient({
      failPage: () => ({ data: null, error: { message: "Failed to fetch" } }),
    });
    const err = await run(client).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(TransferError);
    expect((err as TransferError).kind).toBe("transport");
    expect((err as TransferError).message).toBe(TRANSPORT_MESSAGE);
    expect((err as TransferError).transferId).toBe(TID);
    expect(calls.filter((c) => c.fn === "org_export_begin")).toHaveLength(1);
    expect(calls.some((c) => c.fn === "org_export_finish")).toBe(false);
  });

  it("chyba databázy pri čítaní stránky sa nezopakuje a zachová správu databázy", async () => {
    const { client, calls } = fakeClient({
      failPage: () => ({
        data: null,
        error: { code: "P0001", message: "Prenos už nie je v stave exportu (stav: cancelled)." },
      }),
    });
    const err = (await run(client).catch((e: unknown) => e)) as TransferError;
    expect(err.kind).toBe("database");
    expect(err.message).toContain("stave exportu");
    expect(calls.filter((c) => c.fn === "org_export_page")).toHaveLength(1);
  });

  it("chyba certifikátu sa nepovažuje za bežný výpadok a neopakuje sa", async () => {
    const { client, calls } = fakeClient({
      failPage: () => ({ data: null, error: { message: "net::ERR_CERT_AUTHORITY_INVALID" } }),
    });
    const err = (await run(client).catch((e: unknown) => e)) as TransferError;
    expect(err.kind).toBe("transport");
    expect(calls.filter((c) => c.fn === "org_export_page")).toHaveLength(1);
  });

  it("chýbajúca migrácia sa ohlási zrozumiteľne a nezačne sa nič zapisovať", async () => {
    const { client } = fakeClient({
      begin: {
        data: null,
        error: { code: "PGRST202", message: "Could not find the function public.org_export_begin" },
      },
    });
    const err = (await run(client).catch((e: unknown) => e)) as TransferError;
    expect(err.kind).toBe("missing");
    expect(err.message).toBe(MISSING_MESSAGE);
    expect(err.transferId).toBeNull();
  });

  it("neúplný súbor (tabuľka skončila skôr) sa odmietne ešte pred dokončením prenosu", async () => {
    const { client, calls } = fakeClient({
      pageOverride: (rel, offset) => ({ rel, offset, count: 0, rows: "[]" }),
    });
    const err = (await run(client).catch((e: unknown) => e)) as TransferError;
    expect(err.kind).toBe("incomplete");
    expect(err.transferId).toBe(TID);
    expect(calls.some((c) => c.fn === "org_export_finish")).toBe(false);
  });

  it("odmietnutie dokončenia serverom (údaje sa zmenili) súbor nevráti a chyba nesie číslo prenosu", async () => {
    const { client } = fakeClient({
      finish: {
        data: null,
        error: {
          code: "P0001",
          message: "Údaje sa počas exportu zmenili (tabuľky: public.punches).",
        },
      },
    });
    const err = (await run(client).catch((e: unknown) => e)) as TransferError;
    expect(err.kind).toBe("database");
    expect(err.message).toContain("zmenili");
    expect(err.transferId).toBe(TID);
  });

  it("prerušenie pred ďalšou stránkou skončí chybou „aborted“ s číslom prenosu", async () => {
    const ac = new AbortController();
    const { client, calls } = fakeClient();
    const err = (await run(client, {
      signal: ac.signal,
      onProgress: (p) => p.phase === "read" && ac.abort(),
    }).catch((e: unknown) => e)) as TransferError;
    expect(err.kind).toBe("aborted");
    expect(err.transferId).toBe(TID);
    expect(calls.some((c) => c.fn === "org_export_finish")).toBe(false);
  });

  it("hlási priebeh od odvodenia kľúča po dokončenie", async () => {
    const { client } = fakeClient();
    const phases: string[] = [];
    await run(client, { onProgress: (p) => phases.push(p.phase) });
    expect(phases[0]).toBe("key");
    expect(phases[1]).toBe("begin");
    expect(phases.filter((p) => p === "read")).toHaveLength(2); // po jednej stránke na neprázdnu tabuľku
    expect(phases.slice(-2)).toEqual(["seal", "finish"]);
  });

  it("odmietne odpoveď s neočakávaným tvarom (stará alebo cudzia databáza)", async () => {
    const { client } = fakeClient({ begin: { data: { transfer_id: "nie-uuid" }, error: null } });
    const err = (await run(client).catch((e: unknown) => e)) as TransferError;
    expect(err.kind).toBe("invalid");
    expect(err.message).toContain("Neočakávaná odpoveď");
  });
});

describe("parsePage", () => {
  it("odmietne stránku s iným počtom riadkov, iným posunom alebo tabuľkou než sa pýtalo", () => {
    const ok = { rel: "public.punches", offset: 0, count: 2, rows: '[{"a": 1}, {"a": 2}]' };
    expect(parsePage(ok, "public.punches", 0).count).toBe(2);
    expect(() => parsePage({ ...ok, count: 3 }, "public.punches", 0)).toThrow(
      /Neočakávaná odpoveď/,
    );
    expect(() => parsePage(ok, "public.profiles", 0)).toThrow(/Neočakávaná odpoveď/);
    expect(() => parsePage(ok, "public.punches", 2)).toThrow(/Neočakávaná odpoveď/);
    expect(() => parsePage({ ...ok, rows: [{ a: 1 }, { a: 2 }] }, "public.punches", 0)).toThrow();
    expect(() => parsePage({ ...ok, rows: '{"a": 1}' }, "public.punches", 0)).toThrow();
    expect(() => parsePage({ ...ok, rows: "[{" }, "public.punches", 0)).toThrow();
  });
});

describe("stav, zrušenie a potvrdenie", () => {
  const statusData = {
    name: "Firma",
    is_test: true,
    protected: false,
    state: "exported",
    transfer_id: TID,
    locked: true,
    lock_active: true,
    started_at: "2026-11-12T10:00:00Z",
    exported_at: "2026-11-12T10:05:00Z",
    marked_test: true,
    has_changes: true,
    changes: { "public.punches": { then: 120, now: 123 }, "public.profiles": { then: 5, now: 6 } },
  };

  it("parseStatus prevedie odpoveď databázy a neznámy tvar odmietne", () => {
    const s = parseStatus(statusData);
    expect(s).toMatchObject({
      state: "exported",
      lockActive: true,
      markedTest: true,
      hasChanges: true,
      transferId: TID,
    });
    expect(describeChanges(s?.changes ?? [])).toBe("razenia: 120 → 123, účty: 5 → 6");
    expect(parseStatus({ ...statusData, state: "niečo" })).toBeNull();
    expect(parseStatus(null)).toBeNull();
    expect(parseStatus({ name: "x" })).toBeNull();
    expect(
      parseStatus({
        ...statusData,
        state: "none",
        transfer_id: null,
        started_at: null,
        exported_at: null,
        changes: {},
      })?.changes,
    ).toEqual([]);
  });

  it("getTransferStatus zavolá org_transfer_status a pri neplatnej odpovedi vyhodí chybu", async () => {
    const ok: TransferClient = { rpc: async () => ({ data: statusData, error: null }) };
    expect((await getTransferStatus(ok)).name).toBe("Firma");
    const bad: TransferClient = { rpc: async () => ({ data: { zle: true }, error: null }) };
    await expect(getTransferStatus(bad)).rejects.toThrow(/Neočakávaná odpoveď/);
  });

  it("cancelTransfer vráti, či sa odomklo a vrátilo označenie testovacia", async () => {
    const c: TransferClient = {
      rpc: async () => ({
        data: { state: "cancelled", unlocked: true, test_flag_reverted: true },
        error: null,
      }),
    };
    expect(await cancelTransfer(c)).toEqual({
      hadTransfer: true,
      unlocked: true,
      testFlagReverted: true,
    });
    const none: TransferClient = { rpc: async () => ({ data: { state: "none" }, error: null }) };
    expect(await cancelTransfer(none)).toEqual({
      hadTransfer: false,
      unlocked: false,
      testFlagReverted: false,
    });
  });

  it("confirmTransferAndDelete pošle kód v tvare XXXX-XXXX, názov a súhlas so zmenami; zlý kód odmietne bez volania", async () => {
    const rpc = vi.fn(async () => ({ data: { users: 4, punches: 120, devices: 3 }, error: null }));
    const out = await confirmTransferAndDelete(
      { rpc },
      { receipt: " ab12 cd34 ", name: "Firma", acceptChanges: true },
    );
    expect(out).toEqual({ users: 4, punches: 120, devices: 3 });
    expect(rpc).toHaveBeenCalledWith("org_transfer_confirm_and_delete", {
      _receipt: "AB12-CD34",
      _confirm_name: "Firma",
      _accept_changes: true,
    });
    rpc.mockClear();
    await expect(
      confirmTransferAndDelete({ rpc }, { receipt: "XYZ", name: "Firma", acceptChanges: false }),
    ).rejects.toThrow(/XXXX-XXXX/);
    expect(rpc).not.toHaveBeenCalled();
  });

  it("chyba databázy pri potvrdení ostane so správou databázy (kód nesedí, názov nesedí, zmeny)", async () => {
    const rpc = async () => ({
      data: null,
      error: { code: "P0001", message: "Kód potvrdenia prenosu nesedí." },
    });
    await expect(
      confirmTransferAndDelete(
        { rpc },
        { receipt: "AB12-CD34", name: "Firma", acceptChanges: false },
      ),
    ).rejects.toThrow("Kód potvrdenia prenosu nesedí.");
  });

  it("normalizeReceipt", () => {
    expect(normalizeReceipt("ab12-cd34")).toBe("AB12-CD34");
    expect(normalizeReceipt("AB12CD34")).toBe("AB12-CD34");
    expect(normalizeReceipt("  ab12 cd34  ")).toBe("AB12-CD34");
    expect(normalizeReceipt("AB12-CD3")).toBeNull();
    expect(normalizeReceipt("AB12-CD345")).toBeNull();
    expect(normalizeReceipt("GH12-CD34")).toBeNull();
    expect(normalizeReceipt("")).toBeNull();
  });

  it("transferFileName", () => {
    expect(transferFileName("1A2B3C4D", new Date(2026, 10, 12, 9, 5))).toBe(
      "prenos-1A2B3C4D-20261112-0905.dochs-enc",
    );
    expect(transferFileName("../x/y", new Date(2026, 0, 2, 3, 4))).toBe(
      "prenos-xy-20260102-0304.dochs-enc",
    );
  });
});

describe("verifyTransferFile", () => {
  it("potvrdí úplný súbor a vráti jeho zhrnutie", async () => {
    const { client } = fakeClient();
    const result = await run(client);
    const v = await verifyTransferFile(result.blob, PW);
    expect(v).toMatchObject({
      organizationName: "Firma „Ľ“",
      organizationCode: "11111111",
      rows: 5,
    });
    expect(v.counts["public.punches"]).toBe(3);
  });

  it("nesprávne heslo a poškodený súbor ohlási zrozumiteľne", async () => {
    const { client } = fakeClient();
    const result = await run(client);
    await expect(verifyTransferFile(result.blob, "iné-heslo-123456")).rejects.toThrow(
      /nesprávne heslo/,
    );
    const bytes = new Uint8Array(await result.blob.arrayBuffer());
    bytes[bytes.length - 3] = (bytes[bytes.length - 3] ?? 0) ^ 1;
    await expect(verifyTransferFile(new Blob([bytes as BlobPart]), PW)).rejects.toBeInstanceOf(
      TransferError,
    );
  });

  it("súbor, ktorému chýbajú riadky alebo nie je prenosom, odmietne", async () => {
    const missing = JSON.stringify({
      meta,
      tables: { "public.profiles": [{}, {}], "public.punches": [{}], "public.empty_table": [] },
    });
    await expect(verifyTransferFile(await encryptText(missing, PW, FAST), PW)).rejects.toThrow(
      /public\.punches má 1 riadkov namiesto 3/,
    );
    const absent = JSON.stringify({ meta, tables: { "public.profiles": [{}, {}] } });
    await expect(verifyTransferFile(await encryptText(absent, PW, FAST), PW)).rejects.toThrow(
      /namiesto/,
    );
    await expect(
      verifyTransferFile(await encryptText("toto nie je JSON", PW, FAST), PW),
    ).rejects.toThrow(/nie je to platný prenos/);
    const v1 = JSON.stringify({ meta: { ...meta, format: 1 }, tables: {} });
    await expect(verifyTransferFile(await encryptText(v1, PW, FAST), PW)).rejects.toThrow(
      /nie je to platný prenos/,
    );
  });
});
