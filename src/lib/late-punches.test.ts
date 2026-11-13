import { Blob as NodeBlob } from "node:buffer";
import { webcrypto } from "node:crypto";
import { beforeAll, describe, expect, it, vi } from "vitest";
import {
  buildLateFileText,
  encryptLateFile,
  fingerprintPunches,
  importLatePunches,
  LATE_MISSING_MESSAGE,
  lateFileName,
  MAX_LATE_PUNCHES,
  parseLateFileText,
  parseLateReport,
  razeniaText,
  readLateFile,
  toLatePunch,
  type QueuedLike,
} from "./late-punches";
import { decryptToText, encryptText, TransferCryptoError } from "./org-transfer-crypto";
import { TransferError, type TransferClient } from "./org-transfer";

// Prostredie jsdom nemá Blob.arrayBuffer ani WebCrypto; skutočný prehliadač ich má, preto sa doplnia z Node.
beforeAll(() => {
  vi.stubGlobal("Blob", NodeBlob);
  vi.stubGlobal("crypto", webcrypto);
});

const FAST = { iterations: 100_000, chunkBytes: 64 * 1024 };
const PW = "správne-heslo-12345";
const U1 = "11111111-1111-4111-8111-111111111111";
const U2 = "22222222-2222-4222-8222-222222222222";
const TOKEN = "ab".repeat(32);
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

function queued(n: number, over: Partial<QueuedLike> = {}): QueuedLike {
  return {
    client_uuid: id(n),
    user_id: n % 2 ? U1 : U2,
    code: "WORK",
    direction: n % 2 ? "IN" : "OUT",
    client_time: new Date(Date.UTC(2026, 10, 12, 6, 0, n)).toISOString(),
    device: "Mozilla/5.0 (terminál č. 1)",
    device_token: TOKEN,
    server_inserted: false,
    error: "Organizácia sa práve prenáša na iný server.",
    ...over,
  };
}
// fronta v inom poradí, než je čas
const QUEUE = [queued(3), queued(1), queued(4), queued(2)];

describe("súbor s razeniami zo zariadenia", () => {
  it("fronta → šifrovaný súbor → dešifrovanie: rovnaké razenia v poradí času", async () => {
    const { blob, file } = await encryptLateFile(QUEUE, PW, {
      origin: "https://stary.example.test",
      encrypt: FAST,
    });
    const back = await readLateFile(blob, PW);
    expect(back.punches).toEqual([1, 2, 3, 4].map((n) => toLatePunch(queued(n))));
    expect(back.punches.map((p) => p.client_time)).toEqual(
      [...back.punches.map((p) => p.client_time)].sort(),
    );
    expect(back.fingerprint).toBe(file.fingerprint);
    expect(back.fingerprint).toBe(await fingerprintPunches(QUEUE.map(toLatePunch)));
    expect(back.accounts).toBe(2);
    expect(back.origin).toBe("https://stary.example.test");
    expect(back.from).toBe(queued(1).client_time);
    expect(back.to).toBe(queued(4).client_time);
  });

  it("do súboru ide len šesť polí razenia: kľúč zariadenia, príznaky fronty ani chyba nikdy", async () => {
    const { blob } = await encryptLateFile(QUEUE, PW, {
      origin: "https://stary.example.test",
      encrypt: FAST,
    });
    const text = await decryptToText(blob, PW);
    expect(text).not.toContain(TOKEN);
    expect(text).not.toContain("device_token");
    expect(text).not.toContain("server_inserted");
    expect(text).not.toContain("prenáša");
    const raw = JSON.parse(text) as {
      punches: Record<string, unknown>[];
      format: string;
      version: number;
      count: number;
    };
    expect(raw.format).toBe("dochs-late-punches");
    expect(raw.version).toBe(1);
    expect(raw.count).toBe(4);
    for (const p of raw.punches)
      expect(Object.keys(p).sort()).toEqual([
        "client_time",
        "client_uuid",
        "code",
        "device",
        "direction",
        "user_id",
      ]);
  });

  it("šifrovaný súbor neobsahuje čitateľné údaje a zlé heslo ho neotvorí", async () => {
    const { blob } = await encryptLateFile(QUEUE, PW, { origin: "x", encrypt: FAST });
    const bytes = new TextDecoder("latin1").decode(await blob.arrayBuffer());
    expect(bytes).not.toContain(U1);
    expect(bytes).not.toContain("WORK");
    await expect(readLateFile(blob, "zlé-heslo-123456")).rejects.toBeInstanceOf(
      TransferCryptoError,
    );
    await expect(
      encryptLateFile(QUEUE, "krátke", { origin: "x", encrypt: FAST }),
    ).rejects.toBeInstanceOf(TransferCryptoError);
  });

  it("odtlačok nezávisí od poradia a mení sa s obsahom", async () => {
    const a = await fingerprintPunches(QUEUE.map(toLatePunch));
    expect(await fingerprintPunches([...QUEUE].reverse().map(toLatePunch))).toBe(a);
    expect(await fingerprintPunches(QUEUE.slice(1).map(toLatePunch))).not.toBe(a);
    expect(
      await fingerprintPunches(
        [queued(3, { direction: "OUT" }), ...QUEUE.slice(1)].map(toLatePunch),
      ),
    ).not.toBe(a);
    // oddeľovač v texte zariadenia nesmie dať rovnaký odtlačok ako iné rozdelenie polí
    const x = await fingerprintPunches([toLatePunch(queued(1, { code: "A|B", device: "C" }))]);
    const y = await fingerprintPunches([toLatePunch(queued(1, { code: "A", device: "B|C" }))]);
    expect(x).not.toBe(y);
  });

  it("upravený alebo cudzí súbor sa odmietne", async () => {
    const text = await buildLateFileText(QUEUE, { origin: "x" });
    const raw = JSON.parse(text) as {
      punches: { direction: string }[];
      count: number;
      version: number;
      format: string;
    };
    const tamper = (change: (d: typeof raw) => void) => {
      const d = JSON.parse(text) as typeof raw;
      change(d);
      return parseLateFileText(JSON.stringify(d));
    };
    await expect(tamper((d) => (d.punches[0]!.direction = "OUT"))).rejects.toThrow(
      /odtlačok nesedí/,
    );
    await expect(tamper((d) => d.punches.pop())).rejects.toThrow(/odtlačok nesedí/);
    await expect(tamper((d) => (d.count = 9))).rejects.toThrow(/odtlačok nesedí/);
    await expect(tamper((d) => (d.version = 2))).rejects.toThrow(/novšom formáte/);
    await expect(tamper((d) => (d.format = "iné"))).rejects.toThrow(/nie je súbor s razeniami/);
    await expect(
      tamper((d) => Object.assign(d.punches[0]!, { device_token: TOKEN })),
    ).rejects.toThrow(/poškodený alebo upravený/);
    await expect(parseLateFileText("nie je json")).rejects.toThrow(/nie je súbor s razeniami/);
    await expect(parseLateFileText('{"meta":{"format":2},"tables":{}}')).rejects.toThrow(
      /nie je súbor s razeniami/,
    );
    // šifrovaný súbor s iným obsahom (napr. prenos organizácie)
    const other = await encryptText('{"meta":{"format":2},"tables":{}}', PW, FAST);
    await expect(readLateFile(other, PW)).rejects.toBeInstanceOf(TransferError);
    await expect(
      readLateFile(
        new Blob(["obyčajný text, nie šifrovaný súbor ............................."]),
        PW,
      ),
    ).rejects.toThrow(/nie je súbor s razeniami/);
  });

  it("prázdna fronta, priveľa razení, zdvojené razenie a neplatný tvar súbor nevytvoria", async () => {
    await expect(buildLateFileText([], { origin: "x" })).rejects.toThrow(/nie sú žiadne razenia/);
    const many = Array.from({ length: MAX_LATE_PUNCHES + 1 }, (_, i) => queued(i + 1));
    await expect(buildLateFileText(many, { origin: "x" })).rejects.toThrow(/viac než 2000/);
    await expect(buildLateFileText([queued(1), queued(1)], { origin: "x" })).rejects.toThrow(
      /dvakrát/,
    );
    await expect(
      buildLateFileText([queued(1, { user_id: "user-a" })], { origin: "x" }),
    ).rejects.toThrow(/neplatný tvar/);
  });

  it("najväčší povolený súbor sa vytvorí a prečíta", async () => {
    const many = Array.from({ length: MAX_LATE_PUNCHES }, (_, i) =>
      queued(i + 1, { client_time: new Date(Date.UTC(2026, 10, 1, 0, 0, i)).toISOString() }),
    );
    const { blob, file } = await encryptLateFile(many, PW, { origin: "x", encrypt: FAST });
    expect(file.punches).toHaveLength(MAX_LATE_PUNCHES);
    expect(blob.size).toBeLessThan(1024 * 1024);
  });

  it("názov súboru nesie čas a počet", () => {
    expect(lateFileName(new Date(2026, 10, 13, 7, 5), 12)).toBe(
      "razenia-zo-zariadenia-20261113-0705-12.dochs-enc",
    );
  });
});

describe("nahratie neskorých razení (správca na novom serveri)", () => {
  const report = {
    dry_run: true,
    total: 4,
    acceptable: 3,
    inserted: 0,
    already: 0,
    rejected: 1,
    reasons: { closed_month: 1 },
    items: [
      {
        n: 2,
        reason: "closed_month",
        client_time: "2026-09-15T08:00:00.000Z",
        code: "WORK",
        direction: "IN",
      },
    ],
    accounts: 2,
    from: null,
    to: null,
    digest: "x",
  };

  it("pošle len razenia a hlavičku, skúška je predvolená cesta a odpoveď sa preloží", async () => {
    const file = await parseLateFileText(
      await buildLateFileText(QUEUE, { origin: "https://stary.example.test" }),
    );
    const rpc = vi.fn().mockResolvedValue({ data: report, error: null });
    const res = await importLatePunches({ rpc } as TransferClient, file, true);
    expect(rpc).toHaveBeenCalledTimes(1);
    const [fn, args] = rpc.mock.calls[0] as [
      string,
      { _payload: { punches: unknown[]; format: string }; _dry_run: boolean },
    ];
    expect(fn).toBe("late_punches_import");
    expect(args._dry_run).toBe(true);
    expect(args._payload.format).toBe("dochs-late-punches");
    expect(args._payload.punches).toEqual(file.punches);
    expect(JSON.stringify(args)).not.toContain("device_token");
    expect(res.acceptable).toBe(3);
    expect(res.reasons).toEqual([{ reason: "closed_month", text: "mesiac je uzavretý", count: 1 }]);
    expect(res.items[0]).toMatchObject({ n: 2, text: "mesiac je uzavretý", code: "WORK" });
  });

  it("ostrý zápis sa po chybe spojenia neopakuje, skúška áno", async () => {
    const file = await parseLateFileText(await buildLateFileText(QUEUE, { origin: "x" }));
    const fail = { data: null, error: { message: "TypeError: Failed to fetch" } };
    const write = vi.fn().mockResolvedValue(fail);
    await expect(
      importLatePunches({ rpc: write } as TransferClient, file, false, {
        sleep: async () => undefined,
      }),
    ).rejects.toMatchObject({ kind: "transport" });
    expect(write).toHaveBeenCalledTimes(1);
    const check = vi
      .fn()
      .mockResolvedValueOnce(fail)
      .mockResolvedValue({ data: report, error: null });
    await importLatePunches({ rpc: check } as TransferClient, file, true, {
      sleep: async () => undefined,
    });
    expect(check).toHaveBeenCalledTimes(2);
  });

  it("chýbajúca migrácia a chyba databázy majú zrozumiteľný text", async () => {
    const file = await parseLateFileText(await buildLateFileText(QUEUE, { origin: "x" }));
    const missing = vi.fn().mockResolvedValue({
      data: null,
      error: { code: "PGRST202", message: "Could not find the function" },
    });
    await expect(importLatePunches({ rpc: missing } as TransferClient, file, true)).rejects.toThrow(
      LATE_MISSING_MESSAGE,
    );
    const denied = vi
      .fn()
      .mockResolvedValue({ data: null, error: { code: "P0001", message: "Nemáte oprávnenie" } });
    await expect(importLatePunches({ rpc: denied } as TransferClient, file, true)).rejects.toThrow(
      "Nemáte oprávnenie",
    );
  });

  it("neznámy dôvod a neočakávaná odpoveď", () => {
    expect(
      parseLateReport({ ...report, reasons: { nieco_nove: 2 }, items: [] }).reasons[0],
    ).toEqual({ reason: "nieco_nove", text: "nieco_nove", count: 2 });
    expect(() => parseLateReport({ ok: true })).toThrow(/neočakávanú odpoveď/);
    expect(() => parseLateReport(null)).toThrow(/neočakávanú odpoveď/);
  });

  it("rozpis po účtoch (migrácia 0020): osobné čísla, počty, rozsah; bez neho null", () => {
    expect(parseLateReport(report).byAccount).toBeNull();
    const withAccounts = parseLateReport({
      ...report,
      by_account: [
        {
          sap_id: "1001",
          count: 2,
          from: "2026-11-12T06:00:00+00:00",
          to: "2026-11-12T14:00:00+00:00",
        },
        { sap_id: null, count: 1 },
      ],
    });
    expect(withAccounts.byAccount).toEqual([
      {
        sapId: "1001",
        count: 2,
        from: "2026-11-12T06:00:00+00:00",
        to: "2026-11-12T14:00:00+00:00",
      },
      { sapId: null, count: 1, from: null, to: null },
    ]);
    // zlý tvar rozpisu je neočakávaná odpoveď, nie potichu prázdny zoznam
    expect(() => parseLateReport({ ...report, by_account: [{ sap_id: "1", count: "x" }] })).toThrow(
      /neočakávanú odpoveď/,
    );
  });

  it("skloňovanie počtu razení", () => {
    expect(razeniaText(0)).toBe("0 razení");
    expect(razeniaText(1)).toBe("1 razenie");
    expect(razeniaText(2)).toBe("2 razenia");
    expect(razeniaText(4)).toBe("4 razenia");
    expect(razeniaText(5)).toBe("5 razení");
    expect(razeniaText(22)).toBe("22 razení");
  });
});
