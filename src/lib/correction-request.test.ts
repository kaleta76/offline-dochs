import { describe, expect, it } from "vitest";
import {
  CLOSED_MONTH_MESSAGE,
  CORRECTION_AUTO_APPROVED_MESSAGE,
  CORRECTION_SENT_MESSAGE,
  correctionErrorMessage,
  correctionSuccessMessage,
  parseCorrectionOutcome,
  submitCorrection,
} from "./correction-request";

type DbError = { message: string; code?: string };
interface Calls {
  rpc: { name: string; args: Record<string, unknown> }[];
  inserts: Record<string, unknown>[];
}

const UID = "11111111-1111-4111-8111-111111111111";
const TOKEN = "a".repeat(64);
const AT = new Date("2026-11-10T07:30:00.000Z");
const INPUT = {
  userId: UID,
  code: "WORK",
  direction: "IN",
  at: AT,
  reason: "  Zabudol som odpípať  ",
};

// Falošný klient: zaznamená volania a vráti pripravené odpovede. Žiadna skutočná sieť.
function fakeClient(opts: {
  rpc?: { data?: unknown; error?: DbError | null };
  insertError?: DbError | null;
}) {
  const calls: Calls = { rpc: [], inserts: [] };
  const client = {
    rpc: (name: string, args: Record<string, unknown>) => {
      calls.rpc.push({ name, args });
      return Promise.resolve({ data: opts.rpc?.data ?? null, error: opts.rpc?.error ?? null });
    },
    from: (table: string) => {
      expect(table).toBe("corrections");
      return {
        insert: (row: Record<string, unknown>) => {
          calls.inserts.push(row);
          return Promise.resolve({ error: opts.insertError ?? null });
        },
      };
    },
  };
  return { client: client as unknown as Parameters<typeof submitCorrection>[0], calls };
}

describe("parseCorrectionOutcome", () => {
  it("rozpozná automatické schválenie", () => {
    expect(parseCorrectionOutcome({ id: "x", status: "approved", auto_approved: true })).toBe(
      "approved",
    );
  });
  it("čakajúca žiadosť ostáva čakajúca", () => {
    expect(parseCorrectionOutcome({ id: "x", status: "pending", auto_approved: false })).toBe(
      "pending",
    );
  });
  it("neznámy alebo poškodený tvar nikdy nehlási schválenie", () => {
    for (const bad of [
      null,
      undefined,
      "approved",
      {},
      { status: "approved" },
      { status: "approved", auto_approved: false },
      { status: "pending", auto_approved: true },
      { status: "done", auto_approved: true },
      { status: "approved", auto_approved: "true" },
    ]) {
      expect(parseCorrectionOutcome(bad)).toBe("pending");
    }
  });
});

describe("submitCorrection", () => {
  it("volá request_correction so všetkými poľami a kľúčom zariadenia, dôvod orezaný", async () => {
    const { client, calls } = fakeClient({
      rpc: { data: { id: "c1", status: "approved", auto_approved: true } },
    });
    const outcome = await submitCorrection(client, INPUT, TOKEN);
    expect(outcome).toBe("approved");
    expect(calls.rpc).toEqual([
      {
        name: "request_correction",
        args: {
          _code: "WORK",
          _direction: "IN",
          _at_time: "2026-11-10T07:30:00.000Z",
          _reason: "Zabudol som odpípať",
          _device_token: TOKEN,
        },
      },
    ]);
    expect(calls.inserts).toEqual([]);
  });

  it("bez kľúča zariadenia kľúč neposiela", async () => {
    const { client, calls } = fakeClient({
      rpc: { data: { id: "c1", status: "pending", auto_approved: false } },
    });
    const outcome = await submitCorrection(client, INPUT, null);
    expect(outcome).toBe("pending");
    expect(calls.rpc[0]?.args).not.toHaveProperty("_device_token");
  });

  it("nikdy neposiela pole, ktoré smie nastaviť len databáza", async () => {
    const { client, calls } = fakeClient({
      rpc: { data: { id: "c1", status: "pending", auto_approved: false } },
    });
    await submitCorrection(client, INPUT, TOKEN);
    const keys = Object.keys(calls.rpc[0]?.args ?? {});
    expect(keys.some((k) => /verified|auto|status|decided|punch/i.test(k))).toBe(false);
  });

  it("chýbajúca funkcia (PGRST202): pôvodný priamy zápis, žiadosť čaká", async () => {
    const { client, calls } = fakeClient({
      rpc: {
        error: {
          code: "PGRST202",
          message: "Could not find the function public.request_correction in the schema cache",
        },
      },
    });
    const outcome = await submitCorrection(client, INPUT, TOKEN);
    expect(outcome).toBe("pending");
    expect(calls.inserts).toEqual([
      {
        user_id: UID,
        code: "WORK",
        direction: "IN",
        at_time: "2026-11-10T07:30:00.000Z",
        reason: "Zabudol som odpípať",
      },
    ]);
    // Kľúč zariadenia sa pri zálohe nikam neposiela.
    expect(JSON.stringify(calls.inserts)).not.toContain(TOKEN);
  });

  it("chybu zálohy vyhodí ďalej", async () => {
    const { client } = fakeClient({
      rpc: { error: { code: "PGRST202", message: "Could not find the function" } },
      insertError: {
        message: 'new row violates row-level security policy for table "corrections"',
      },
    });
    await expect(submitCorrection(client, INPUT, TOKEN)).rejects.toMatchObject({
      message: expect.stringContaining("row-level"),
    });
  });

  it("iná chyba (uzavretý mesiac) sa nezakryje zálohou a nezapíše nič priamo", async () => {
    const { client, calls } = fakeClient({ rpc: { error: { message: "Mesiac je uzavretý" } } });
    await expect(submitCorrection(client, INPUT, TOKEN)).rejects.toMatchObject({
      message: "Mesiac je uzavretý",
    });
    expect(calls.inserts).toEqual([]);
  });

  it("chyba spojenia sa nezakryje zálohou", async () => {
    const { client, calls } = fakeClient({ rpc: { error: { message: "Failed to fetch" } } });
    await expect(submitCorrection(client, INPUT, TOKEN)).rejects.toMatchObject({
      message: "Failed to fetch",
    });
    expect(calls.inserts).toEqual([]);
  });
});

describe("správy pre zamestnanca", () => {
  it("úspech: automatické schválenie sa líši od čakajúcej žiadosti", () => {
    expect(correctionSuccessMessage("approved")).toBe(CORRECTION_AUTO_APPROVED_MESSAGE);
    expect(correctionSuccessMessage("pending")).toBe(CORRECTION_SENT_MESSAGE);
    expect(CORRECTION_AUTO_APPROVED_MESSAGE).not.toBe(CORRECTION_SENT_MESSAGE);
  });
  it("chyba pravidla riadkov znamená uzavretý mesiac, ostatné správy ostávajú", () => {
    expect(
      correctionErrorMessage({
        message: 'new row violates row-level security policy for table "corrections"',
      }),
    ).toBe(CLOSED_MONTH_MESSAGE);
    expect(correctionErrorMessage({ message: "Mesiac je uzavretý" })).toBe("Mesiac je uzavretý");
    expect(correctionErrorMessage({ message: "Dôvod musí mať 3 až 500 znakov" })).toBe(
      "Dôvod musí mať 3 až 500 znakov",
    );
    expect(correctionErrorMessage({})).toBe("");
  });
});
