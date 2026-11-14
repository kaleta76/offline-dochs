import "fake-indexeddb/auto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  insert: vi.fn(),
  read: vi.fn(),
  rpc: vi.fn(),
  getSession: vi.fn(),
  uid: "user-a" as string | null,
}));
vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    auth: { getSession: mocks.getSession },
    rpc: mocks.rpc,
    from: () => ({
      insert: (p: unknown) => mocks.insert(p),
      select: () => ({ eq: () => ({ eq: () => ({ maybeSingle: mocks.read }) }) }),
    }),
  },
}));
import {
  enqueue,
  getParkedUuid,
  listAllQueued,
  observeQueue,
  removeQueued,
  resetBackoff,
  syncQueue,
  type QueueEvent,
} from "./offline-queue";

const LOCK = {
  error: {
    code: "55000",
    message:
      "Organizácia sa práve prenáša na iný server. Razenie sa teraz nedá zapísať, terminál ho uloží a odošle neskôr.",
  },
  status: 400,
};
const online = (value: boolean) =>
  Object.defineProperty(navigator, "onLine", { configurable: true, value });
let events: QueueEvent[] = [];
let stop: () => void = () => undefined;

beforeEach(async () => {
  online(false);
  mocks.uid = "user-a";
  for (const m of [mocks.insert, mocks.read, mocks.rpc, mocks.getSession]) m.mockReset();
  mocks.getSession.mockImplementation(async () => ({
    data: { session: mocks.uid ? { user: { id: mocks.uid } } : null },
    error: null,
  }));
  resetBackoff();
  await removeQueued((await listAllQueued()).map((p) => p.client_uuid));
  events = [];
  stop = observeQueue((e) => events.push(e));
});
afterEach(() => {
  stop();
  resetBackoff();
});

describe("fronta a prenos organizácie na iný server", () => {
  it("zámok prenosu (55000): razenie ostane vo fronte, nezaparkuje sa, pozorovateľ sa dozvie o zámku a fronta sama nič navyše neposiela", async () => {
    const p = await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockResolvedValue(LOCK);
    online(true);
    await syncQueue();
    const left = await listAllQueued();
    expect(left.map((x) => x.client_uuid)).toEqual([p.client_uuid]);
    expect(left[0]?.error).toContain("prenáša");
    expect(left[0]?.server_inserted).toBeUndefined();
    expect(getParkedUuid()).toBeNull();
    expect(events).toEqual([{ type: "transfer-lock", userId: "user-a" }]);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("po zrušení prenosu sa to isté razenie odošle (rovnaké client_uuid) a pozorovateľ sa dozvie o prijatí", async () => {
    const p = await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockResolvedValueOnce(LOCK).mockResolvedValue({ error: null });
    mocks.read.mockResolvedValue({ error: null, data: p });
    online(true);
    await syncQueue();
    await syncQueue();
    expect(await listAllQueued()).toEqual([]);
    expect(
      mocks.insert.mock.calls.map((c) => (c[0] as { client_uuid: string }).client_uuid),
    ).toEqual([p.client_uuid, p.client_uuid]);
    expect(events.map((e) => e.type)).toEqual(["transfer-lock", "accepted"]);
  });

  it("server razenie neprijal (oprávnenie, chýbajúci účet): udalosť refused, razenie ostáva", async () => {
    await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    online(true);
    mocks.insert.mockResolvedValueOnce({
      error: { code: "42501", message: "new row violates row-level security policy" },
      status: 403,
    });
    await syncQueue();
    mocks.insert.mockResolvedValueOnce({
      error: { code: "23503", message: "violates foreign key constraint" },
      status: 409,
    });
    await syncQueue();
    expect(events).toEqual([
      { type: "refused", userId: "user-a" },
      { type: "refused", userId: "user-a" },
    ]);
    expect(await listAllQueued()).toHaveLength(1);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("výpadok spojenia nie je dôvod pýtať sa na presťahovanie", async () => {
    await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    online(true);
    mocks.insert.mockResolvedValue({
      error: { message: "TypeError: Failed to fetch", code: "" },
      status: 0,
    });
    await syncQueue();
    expect(events).toEqual([]);
  });

  it("razenia neprihlásených účtov sa ohlásia ako unsent; prázdna fronta neohlási nič", async () => {
    online(true);
    await syncQueue();
    expect(events).toEqual([]);
    mocks.uid = null;
    // enqueue samo spustí odoslanie na pozadí (už so spojením): stačí počkať na jeho udalosť
    await enqueue({ user_id: "user-b", code: "WORK", direction: "IN" });
    await enqueue({ user_id: "user-c", code: "WORK", direction: "IN" });
    // poradie účtov v udalosti určuje poradie riadkov v IndexedDB (kľúč je náhodné client_uuid), preto sa porovnáva zoradené
    await vi.waitFor(() =>
      expect(events.map((e) => (e.type === "unsent" ? [...e.userIds].sort() : []))).toContainEqual([
        "user-b",
        "user-c",
      ]),
    );
    expect(events.every((e) => e.type === "unsent")).toBe(true);
    expect(mocks.insert).not.toHaveBeenCalled();
    expect(await listAllQueued()).toHaveLength(2);
  });

  it("chyba pozorovateľa odosielanie nezastaví", async () => {
    const p = await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    const off = observeQueue(() => {
      throw new Error("pozorovateľ");
    });
    mocks.insert.mockResolvedValue({ error: null });
    mocks.read.mockResolvedValue({ error: null, data: p });
    online(true);
    await syncQueue();
    off();
    expect(await listAllQueued()).toEqual([]);
  });

  it("removeQueued zmaže len vymenované razenia", async () => {
    const a = await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    const b = await enqueue({ user_id: "user-b", code: "WORK", direction: "OUT" });
    await removeQueued([a.client_uuid, "neexistuje"]);
    expect((await listAllQueued()).map((p) => p.client_uuid)).toEqual([b.client_uuid]);
    await removeQueued([]);
    expect(await listAllQueued()).toHaveLength(1);
  });
});
