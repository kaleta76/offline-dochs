import "fake-indexeddb/auto";
import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    auth: { getSession: async () => ({ data: { session: null } }) },
    rpc: vi.fn(),
    from: vi.fn(),
  },
}));
import { cleanupAfterMove, DEVICE_DB, QUEUE_DB, type CleanupDeps } from "./device-cleanup";
import { createDeviceKey, deleteDeviceKey, getDeviceKey } from "./device";
import { enqueue, listAllQueued, removeQueued } from "./offline-queue";

const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";
const OTHER = "99999999-9999-4999-8999-999999999999";

function storage(initial: Record<string, string>) {
  const data = new Map(Object.entries(initial));
  return {
    data,
    get length() {
      return data.size;
    },
    key: (i: number) => [...data.keys()][i] ?? null,
    removeItem: (k: string) => void data.delete(k),
    clear: () => data.clear(),
  };
}

function deps(over: Partial<CleanupDeps> = {}) {
  const local = storage({
    [`me-cache:${A}`]: "{}",
    [`me-cache:${OTHER}`]: "{}",
    [`terminal-buttons:${A}:org`]: "{}",
    [`terminal-buttons:${OTHER}:org`]: "{}",
    "org-code": "AB12CD34",
    "personnel-number": "1234567",
    "sb-xyz-auth-token": "{}",
  });
  const session = { clear: vi.fn() };
  const d: CleanupDeps = {
    removeQueued,
    listAllQueued,
    deleteDeviceKey,
    forgetMove: vi.fn(),
    sessionUserId: vi.fn(async () => null),
    signOutLocal: vi.fn(async () => undefined),
    storage: local,
    sessionStorage: session,
    deleteDatabase: vi.fn(async () => undefined),
    cacheNames: vi.fn(async () => ["workbox-precache", "fonts"]),
    deleteCache: vi.fn(async () => true),
    unregisterWorkers: vi.fn(async () => 1),
    ...over,
  };
  return { d, local, session };
}

beforeEach(async () => {
  Object.defineProperty(navigator, "onLine", { configurable: true, value: false });
  await removeQueued((await listAllQueued()).map((p) => p.client_uuid));
  for (const id of [A, B, OTHER]) await deleteDeviceKey(id);
});

describe("upratanie zariadenia po presťahovaní organizácie", () => {
  it("zmaže presne razenia zo súboru; keď nič iné neostalo, upratuje úplne", async () => {
    const a1 = await enqueue({ user_id: A, code: "WORK", direction: "IN" });
    const a2 = await enqueue({ user_id: A, code: "WORK", direction: "OUT" });
    const b1 = await enqueue({ user_id: B, code: "WORK", direction: "IN" });
    await createDeviceKey(A);
    const { d, local, session } = deps();
    const res = await cleanupAfterMove(
      { uuids: [a1, a2, b1].map((p) => p.client_uuid), userIds: [A, B] },
      d,
    );
    expect(res).toEqual({ removed: 3, remaining: 0, full: true, problems: [] });
    expect(await listAllQueued()).toEqual([]);
    expect(await getDeviceKey(A)).toBeUndefined();
    expect(local.data.size).toBe(0);
    expect(session.clear).toHaveBeenCalled();
    expect(d.signOutLocal).toHaveBeenCalledTimes(1);
    expect(d.deleteDatabase).toHaveBeenCalledWith(QUEUE_DB);
    expect(d.deleteDatabase).toHaveBeenCalledWith(DEVICE_DB);
    expect(d.deleteCache).toHaveBeenCalledTimes(2);
    expect(d.unregisterWorkers).toHaveBeenCalledTimes(1);
    expect(d.forgetMove).toHaveBeenCalledWith([A, B]);
  });

  it("razenia iného účtu na spoločnom zariadení ostanú a úplné upratanie sa neurobí", async () => {
    const a1 = await enqueue({ user_id: A, code: "WORK", direction: "IN" });
    const o1 = await enqueue({ user_id: OTHER, code: "WORK", direction: "IN" });
    await createDeviceKey(A);
    const other = await createDeviceKey(OTHER);
    const { d, local } = deps();
    const res = await cleanupAfterMove({ uuids: [a1.client_uuid], userIds: [A] }, d);
    expect(res).toMatchObject({ removed: 1, remaining: 1, full: false });
    expect((await listAllQueued()).map((p) => p.client_uuid)).toEqual([o1.client_uuid]);
    expect(await getDeviceKey(A)).toBeUndefined();
    expect((await getDeviceKey(OTHER))?.token).toBe(other.key.token);
    expect([...local.data.keys()].sort()).toEqual(
      [
        `me-cache:${OTHER}`,
        "org-code",
        "personnel-number",
        "sb-xyz-auth-token",
        `terminal-buttons:${OTHER}:org`,
      ].sort(),
    );
    expect(d.signOutLocal).not.toHaveBeenCalled();
    expect(d.deleteDatabase).not.toHaveBeenCalled();
    expect(d.unregisterWorkers).not.toHaveBeenCalled();
  });

  it("razenie, ktoré v súbore nebolo (pribudlo neskôr), ostane aj s kľúčom zariadenia účtu", async () => {
    const a1 = await enqueue({ user_id: A, code: "WORK", direction: "IN" });
    const later = await enqueue({ user_id: A, code: "WORK", direction: "OUT" });
    const key = await createDeviceKey(A);
    const { d, local } = deps();
    const res = await cleanupAfterMove({ uuids: [a1.client_uuid], userIds: [A] }, d);
    expect(res).toMatchObject({ removed: 1, remaining: 1, full: false });
    expect((await listAllQueued()).map((p) => p.client_uuid)).toEqual([later.client_uuid]);
    expect((await getDeviceKey(A))?.token).toBe(key.key.token);
    expect(local.data.has(`me-cache:${A}`)).toBe(true);
    expect(d.forgetMove).toHaveBeenCalledWith([]);
  });

  it("prihlásený účet, ktorého sa presťahovanie netýka, o prihlásenie nepríde", async () => {
    const a1 = await enqueue({ user_id: A, code: "WORK", direction: "IN" });
    const { d, local } = deps({ sessionUserId: vi.fn(async () => OTHER) });
    const res = await cleanupAfterMove({ uuids: [a1.client_uuid], userIds: [A] }, d);
    expect(res).toMatchObject({ removed: 1, remaining: 0, full: false });
    expect(d.signOutLocal).not.toHaveBeenCalled();
    expect(local.data.has("sb-xyz-auth-token")).toBe(true);
    // prihlásený presťahovaný účet (token ešte platí) sa odhlási a upratuje sa úplne
    const a2 = await enqueue({ user_id: A, code: "WORK", direction: "IN" });
    const second = deps({ sessionUserId: vi.fn(async () => A) });
    expect((await cleanupAfterMove({ uuids: [a2.client_uuid], userIds: [A] }, second.d)).full).toBe(
      true,
    );
    expect(second.d.signOutLocal).toHaveBeenCalledTimes(1);
  });

  it("ak sa razenia nepodarí zmazať, nemaže sa nič ďalšie", async () => {
    const a1 = await enqueue({ user_id: A, code: "WORK", direction: "IN" });
    await createDeviceKey(A);
    const { d, local } = deps({
      removeQueued: vi.fn(async () => {
        throw new Error("Zmazanie razení zlyhalo.");
      }),
    });
    await expect(cleanupAfterMove({ uuids: [a1.client_uuid], userIds: [A] }, d)).rejects.toThrow(
      "Zmazanie razení zlyhalo.",
    );
    expect(await listAllQueued()).toHaveLength(1);
    expect(await getDeviceKey(A)).toBeDefined();
    expect(local.data.size).toBe(7);
    expect(d.deleteDatabase).not.toHaveBeenCalled();
    expect(d.signOutLocal).not.toHaveBeenCalled();
  });

  it("zlyhanie vedľajšieho kroku upratanie nezastaví a vypíše sa", async () => {
    const a1 = await enqueue({ user_id: A, code: "WORK", direction: "IN" });
    const { d, local } = deps({
      deleteDatabase: vi.fn(async () => {
        throw new Error("Databáza je otvorená v inej karte.");
      }),
      unregisterWorkers: vi.fn(async () => {
        throw new Error("x");
      }),
    });
    const res = await cleanupAfterMove({ uuids: [a1.client_uuid], userIds: [A] }, d);
    expect(res.full).toBe(true);
    expect(res.problems).toEqual(["fronta razení", "kľúče zariadenia", "service worker"]);
    expect(local.data.size).toBe(0);
    expect(await listAllQueued()).toEqual([]);
  });

  it("client_uuid, ktoré vo fronte nie je, nič nepokazí", async () => {
    const o1 = await enqueue({ user_id: OTHER, code: "WORK", direction: "IN" });
    const { d } = deps();
    const res = await cleanupAfterMove(
      { uuids: ["00000000-0000-4000-8000-000000000000"], userIds: [A] },
      d,
    );
    expect(res).toMatchObject({ removed: 0, remaining: 1, full: false });
    expect((await listAllQueued()).map((p) => p.client_uuid)).toEqual([o1.client_uuid]);
  });
});
