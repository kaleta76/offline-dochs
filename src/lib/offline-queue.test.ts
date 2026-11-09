import "fake-indexeddb/auto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  insert: vi.fn(),
  read: vi.fn(),
  rpc: vi.fn(),
  getUser: vi.fn(),
  getSession: vi.fn(),
  from: vi.fn(),
  uid: "user-a",
  sends: [] as unknown[],
}));
vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    auth: { getUser: mocks.getUser, getSession: mocks.getSession },
    rpc: mocks.rpc,
    from: (table: string) => {
      mocks.from(table);
      return {
        insert: (p: unknown) => {
          mocks.sends.push(p);
          return mocks.insert(p);
        },
        select: () => ({ eq: () => ({ eq: () => ({ maybeSingle: mocks.read }) }) }),
      };
    },
  },
}));
import {
  BACKOFF_MAX_MS,
  BACKOFF_STEPS_MS,
  backoffDelay,
  classifySyncError,
  enqueue,
  getSyncStatus,
  hasSyncFailed,
  resetBackoff,
  SYNC_FAILED_MESSAGE,
  syncNow,
  syncQueue,
} from "./offline-queue";
import type { QueuedPunch } from "./offline-queue";
import { createDeviceKey } from "./device";

async function rows() {
  const db = await new Promise<IDBDatabase>((resolve) => {
    const r = indexedDB.open("dochadzka", 1);
    r.onsuccess = () => resolve(r.result);
  });
  return new Promise<QueuedPunch[]>((resolve) => {
    const t = db.transaction("queue", "readonly");
    const r = t.objectStore("queue").getAll();
    t.oncomplete = () => {
      db.close();
      resolve(r.result);
    };
  });
}
async function clear() {
  const db = await new Promise<IDBDatabase>((resolve) => {
    const r = indexedDB.open("dochadzka", 1);
    r.onupgradeneeded = () => r.result.createObjectStore("queue", { keyPath: "client_uuid" });
    r.onsuccess = () => resolve(r.result);
  });
  await new Promise<void>((resolve) => {
    const t = db.transaction("queue", "readwrite");
    t.objectStore("queue").clear();
    t.oncomplete = () => {
      db.close();
      resolve();
    };
  });
}
const goOnline = () =>
  Object.defineProperty(navigator, "onLine", { configurable: true, value: true });
const fetchFailure = {
  error: { message: "TypeError: Failed to fetch", code: "", details: "", hint: "" },
  data: null,
  status: 0,
};

beforeEach(async () => {
  Object.defineProperty(navigator, "onLine", { configurable: true, value: false });
  mocks.uid = "user-a";
  mocks.sends = [];
  for (const m of [mocks.insert, mocks.read, mocks.rpc, mocks.getUser, mocks.from]) m.mockReset();
  mocks.getSession.mockReset();
  mocks.getSession.mockImplementation(async () => ({
    data: { session: { user: { id: mocks.uid } } },
    error: null,
  }));
  resetBackoff();
  await clear();
});
afterEach(() => {
  resetBackoff();
  vi.restoreAllMocks();
});

describe("Durable owner-scoped synchronization", () => {
  it("attaches the device key when this browser has one, and omits it otherwise", async () => {
    const plain = await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    expect(plain.device_token).toBeUndefined();
    const { key } = await createDeviceKey("user-c");
    const keyed = await enqueue({ user_id: "user-c", code: "WORK", direction: "IN" });
    expect(keyed.device_token).toBe(key.token);
  });
  it("commits punches locally without a network connection", async () => {
    const p = await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    expect((await rows())[0]?.client_uuid).toBe(p.client_uuid);
    expect(mocks.sends).toHaveLength(0);
  });
  it("reconnects safely and leaves another account’s records untouched", async () => {
    const a = await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    const b = await enqueue({ user_id: "user-b", code: "WORK", direction: "OUT" });
    mocks.insert.mockResolvedValue({ error: null });
    mocks.read.mockResolvedValue({ error: null, data: a });
    goOnline();
    await syncQueue();
    expect(mocks.sends).toHaveLength(1);
    expect(mocks.sends[0]).toMatchObject({ user_id: "user-a", client_uuid: a.client_uuid });
    expect((await rows()).map((p) => p.client_uuid)).toEqual([b.client_uuid]);
  });
  it("never discards a conflicting duplicate", async () => {
    const p = await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockResolvedValue({ error: { code: "23505", message: "duplicate" } });
    mocks.read.mockResolvedValue({ error: null, data: { ...p, direction: "OUT" } });
    goOnline();
    await syncQueue();
    expect(await rows()).toHaveLength(1);
    expect((await rows())[0]?.error).toContain("Konflikt");
  });
  it("retains queued events on authentication and network failures", async () => {
    await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockRejectedValue(new Error("network unavailable"));
    goOnline();
    await syncQueue();
    expect(await rows()).toHaveLength(1);
  });
  it("never sends another user’s events when the session changes", async () => {
    const p = await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.uid = "user-b";
    goOnline();
    await syncQueue();
    expect(mocks.sends).toHaveLength(0);
    expect((await rows())[0]?.client_uuid).toBe(p.client_uuid);
  });
  it("retains an unverified duplicate and retries permission failures later", async () => {
    await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert
      .mockResolvedValueOnce({ error: { code: "23505", message: "duplicate" } })
      .mockResolvedValueOnce({ error: { code: "42501", message: "permission denied" } });
    mocks.read.mockResolvedValue({ error: null, data: null });
    goOnline();
    await syncQueue();
    expect(await rows()).toHaveLength(1);
    await syncQueue();
    expect(await rows()).toHaveLength(1);
  });
});

describe("Zero beaconing", () => {
  it("makes no request at all while the local queue is empty", async () => {
    goOnline();
    await syncQueue();
    await syncQueue("auto");
    await syncNow();
    expect(mocks.getSession).not.toHaveBeenCalled();
    expect(mocks.getUser).not.toHaveBeenCalled();
    expect(mocks.from).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalled();
    expect(getSyncStatus().retryScheduled).toBe(false);
  });
  it("uses the local session and never calls getUser", async () => {
    const p = await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockResolvedValue({ error: null });
    mocks.read.mockResolvedValue({ error: null, data: p });
    goOnline();
    await syncQueue();
    expect(mocks.getSession).toHaveBeenCalled();
    expect(mocks.getUser).not.toHaveBeenCalled();
    expect(await rows()).toHaveLength(0);
  });
});

describe("server_inserted state machine", () => {
  it("deletes after a successful select and never calls the RPC", async () => {
    const p = await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockResolvedValue({ error: null });
    mocks.read.mockResolvedValue({ error: null, data: p });
    goOnline();
    await syncQueue();
    expect(await rows()).toHaveLength(0);
    expect(mocks.rpc).not.toHaveBeenCalled();
    expect(getSyncStatus()).toMatchObject({ failures: 0, retryScheduled: false });
  });
  it("marks the item after insert and does not insert again when read-back fails", async () => {
    const p = await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockResolvedValue({ error: null });
    mocks.read
      .mockResolvedValueOnce({ error: { message: "JWT expired", code: "PGRST301" }, data: null })
      .mockResolvedValueOnce({ error: null, data: p });
    goOnline();
    await syncQueue();
    expect((await rows())[0]?.server_inserted).toBe(true);
    await syncQueue();
    expect(await rows()).toHaveLength(0);
    expect(mocks.sends).toHaveLength(1);
  });
  it("marks the item on unique violation 23505", async () => {
    await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockResolvedValue({ error: { code: "23505", message: "duplicate" } });
    mocks.read.mockResolvedValue({
      error: { message: "JWT expired", code: "PGRST301" },
      data: null,
    });
    goOnline();
    await syncQueue();
    expect((await rows())[0]?.server_inserted).toBe(true);
  });
  it("keeps server_inserted when the read fails on the network", async () => {
    await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockResolvedValue({ error: null });
    mocks.read.mockResolvedValue(fetchFailure);
    mocks.rpc.mockResolvedValue(fetchFailure);
    goOnline();
    await syncQueue();
    await syncQueue();
    expect((await rows())[0]?.server_inserted).toBe(true);
    expect(mocks.sends).toHaveLength(1);
  });
  it("clears server_inserted when the read succeeds without the row, then inserts again", async () => {
    const p = await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockResolvedValue({ error: null });
    mocks.read
      .mockResolvedValueOnce({ error: null, data: null })
      .mockResolvedValueOnce({ error: null, data: p });
    goOnline();
    await syncQueue();
    expect((await rows())[0]?.server_inserted).toBe(false);
    expect(mocks.rpc).not.toHaveBeenCalled();
    await syncQueue();
    expect(mocks.sends).toHaveLength(2);
    expect(await rows()).toHaveLength(0);
  });
});

describe("Two-phase verification", () => {
  it("falls back to verify_punch_synced only after a transport failure and deletes on true", async () => {
    const p = await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockResolvedValue({ error: null });
    mocks.read.mockResolvedValue(fetchFailure);
    mocks.rpc.mockResolvedValue({ data: true, error: null, status: 200 });
    goOnline();
    await syncQueue();
    expect(mocks.rpc).toHaveBeenCalledTimes(1);
    expect(mocks.rpc).toHaveBeenCalledWith("verify_punch_synced", {
      p_client_uuid: p.client_uuid,
      p_code: "WORK",
      p_direction: "IN",
      p_client_time: p.client_time,
      p_device: p.device,
    });
    expect(mocks.rpc.mock.calls[0]?.[1]).not.toHaveProperty("p_user_id");
    expect(await rows()).toHaveLength(0);
  });
  it.each([
    [
      "HTML proxy page with 502",
      {
        error: { message: "<!DOCTYPE html><html><body>Bad Gateway</body></html>", code: "" },
        data: null,
        status: 502,
      },
    ],
    [
      "gateway timeout 504",
      { error: { message: "Gateway Timeout", code: "" }, data: null, status: 504 },
    ],
    [
      "proxy 403 without database code",
      { error: { message: "Forbidden", code: "" }, data: null, status: 403 },
    ],
    [
      "HTML parsed as JSON",
      {
        error: {
          message: "SyntaxError: Unexpected token '<', \"<html>\" is not valid JSON",
          code: "",
        },
        data: null,
        status: 200,
      },
    ],
    [
      "closed connection",
      { error: { message: "net::ERR_CONNECTION_CLOSED", code: "" }, data: null, status: 0 },
    ],
  ])("uses the RPC fallback for %s", async (_label, failure) => {
    await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockResolvedValue({ error: null });
    mocks.read.mockResolvedValue(failure);
    mocks.rpc.mockResolvedValue({ data: true, error: null, status: 200 });
    goOnline();
    await syncQueue();
    expect(mocks.rpc).toHaveBeenCalledTimes(1);
    expect(await rows()).toHaveLength(0);
  });
  it.each([
    [
      "RLS / grant 42501",
      {
        error: { message: "permission denied for table punches", code: "42501" },
        data: null,
        status: 403,
      },
    ],
    [
      "expired JWT",
      { error: { message: "JWT expired", code: "PGRST301" }, data: null, status: 401 },
    ],
    ["conflict", { error: { message: "conflict", code: "409" }, data: null, status: 409 }],
  ])("does not call the RPC for %s", async (_label, failure) => {
    await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockResolvedValue({ error: null });
    mocks.read.mockResolvedValue(failure);
    goOnline();
    await syncQueue();
    expect(mocks.rpc).not.toHaveBeenCalled();
    expect((await rows())[0]?.server_inserted).toBe(true);
  });
  it("keeps the item and backs off when the RPC returns false", async () => {
    await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockResolvedValue({ error: null });
    mocks.read.mockResolvedValue(fetchFailure);
    mocks.rpc.mockResolvedValue({ data: false, error: null, status: 200 });
    goOnline();
    await syncQueue();
    expect(await rows()).toHaveLength(1);
    expect(getSyncStatus()).toMatchObject({ failures: 1, retryScheduled: true });
  });
  it("keeps the item and backs off when the RPC also fails on the network", async () => {
    await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockResolvedValue({ error: null });
    mocks.read.mockResolvedValue(fetchFailure);
    mocks.rpc.mockResolvedValue(fetchFailure);
    goOnline();
    await syncQueue();
    expect(await rows()).toHaveLength(1);
    expect(getSyncStatus().retryScheduled).toBe(true);
  });
});

describe("Certificate errors", () => {
  it("logs visibly and does not retry automatically in a loop", async () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => undefined);
    await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockResolvedValue({
      error: { message: "TypeError: net::ERR_CERT_AUTHORITY_INVALID", code: "" },
      status: 0,
    });
    goOnline();
    await syncQueue();
    expect(consoleError).toHaveBeenCalled();
    expect(getSyncStatus()).toMatchObject({ blockedBy: "certificate", retryScheduled: false });
    expect((await rows())[0]?.error).toBe(
      "Odoslanie sa nepodarilo potvrdiť, razenia sú uložené v zariadení.",
    );
    expect(mocks.rpc).not.toHaveBeenCalled();
    await syncQueue("auto");
    await syncQueue("retry");
    expect(mocks.sends).toHaveLength(1);
    await syncNow();
    expect(mocks.sends).toHaveLength(2);
  });
  it("treats a certificate failure during read-back the same way and skips the RPC", async () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => undefined);
    await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockResolvedValue({ error: null });
    mocks.read.mockResolvedValue({
      error: {
        message: "SSL certificate problem: self signed certificate in certificate chain",
        code: "",
      },
      data: null,
      status: 0,
    });
    goOnline();
    await syncQueue();
    expect(consoleError).toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalled();
    expect(getSyncStatus().blockedBy).toBe("certificate");
    expect((await rows())[0]?.server_inserted).toBe(true);
  });
  it("classifies certificate errors separately from ordinary outages", () => {
    expect(classifySyncError({ message: "net::ERR_CERT_DATE_INVALID" })).toBe("certificate");
    expect(classifySyncError({ message: "SEC_ERROR_UNKNOWN_ISSUER" })).toBe("certificate");
    expect(classifySyncError({ message: "TypeError: Failed to fetch" })).toBe("transport");
    expect(classifySyncError({ message: "permission denied", code: "42501" }, 403)).toBe("other");
  });
  it("keeps a certificate error with status 502 as certificate, not transport", () => {
    expect(classifySyncError({ message: "net::ERR_CERT_AUTHORITY_INVALID" }, 502)).toBe(
      "certificate",
    );
  });
  it("keeps a certificate error with status 504 as certificate, not transport", () => {
    expect(classifySyncError({ message: "SSL_ERROR_BAD_CERT_DOMAIN" }, 504)).toBe("certificate");
  });
  it("detects a certificate pattern in the code field", () => {
    expect(classifySyncError({ message: "", code: "UNABLE_TO_GET_ISSUER_CERT_LOCALLY" })).toBe(
      "certificate",
    );
  });
  it("treats HTTP 403 without a database code as transport", () => {
    expect(classifySyncError({ message: "Forbidden", code: "" }, 403)).toBe("transport");
  });
  it("treats HTTP 403 with database code 42501 as other", () => {
    expect(classifySyncError({ message: "permission denied", code: "42501" }, 403)).toBe("other");
  });
});

describe("Exponential backoff with jitter", () => {
  it("follows 2 s, 5 s, 15 s, 30 s and caps at 60 s", () => {
    const mid = () => 0.5;
    expect([1, 2, 3, 4, 5, 6, 20].map((n) => backoffDelay(n, mid))).toEqual([
      2_000, 5_000, 15_000, 30_000, 60_000, 60_000, 60_000,
    ]);
    expect(BACKOFF_STEPS_MS).toEqual([2_000, 5_000, 15_000, 30_000, 60_000]);
    expect(backoffDelay(0)).toBe(0);
  });
  it("spreads delays randomly but never exceeds 60 s", () => {
    expect(backoffDelay(1, () => 0)).toBe(1_500);
    expect(backoffDelay(1, () => 0.999)).toBeGreaterThan(2_400);
    expect(backoffDelay(5, () => 0.999)).toBe(BACKOFF_MAX_MS);
  });
  it("increments on failure, gates periodic checks, and resets on the online event or manual trigger", async () => {
    await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockResolvedValue(fetchFailure);
    goOnline();
    await syncQueue();
    expect(getSyncStatus()).toMatchObject({ failures: 1, retryScheduled: true });
    await syncQueue("retry");
    expect(getSyncStatus().failures).toBe(2);
    await syncQueue("auto"); // periodic check waits for the backoff
    expect(mocks.sends).toHaveLength(2);
    await syncQueue("online"); // reset to 0, then one fresh failure
    expect(mocks.sends).toHaveLength(3);
    expect(getSyncStatus().failures).toBe(1);
    await syncNow();
    expect(getSyncStatus().failures).toBe(1);
    mocks.insert.mockResolvedValue({ error: null });
    mocks.read.mockResolvedValue({ error: null, data: (await rows())[0] });
    await syncNow();
    expect(getSyncStatus()).toMatchObject({ failures: 0, retryScheduled: false });
  });
});

describe("Neutral sync indicator", () => {
  it("uses neutral wording without technical infrastructure", () => {
    expect(SYNC_FAILED_MESSAGE).toBe(
      "Odoslanie sa nepodarilo potvrdiť, razenia sú uložené v zariadení.",
    );
    expect(SYNC_FAILED_MESSAGE).not.toMatch(/proxy|firewall|certifik|server|sieť/i);
  });
  it("reports a failure after an unconfirmed send and clears it after success", async () => {
    await enqueue({ user_id: "user-a", code: "WORK", direction: "IN" });
    mocks.insert.mockResolvedValue(fetchFailure);
    goOnline();
    await syncQueue();
    expect(hasSyncFailed()).toBe(true);
    mocks.insert.mockResolvedValue({ error: null });
    mocks.read.mockResolvedValue({ error: null, data: (await rows())[0] });
    await syncNow();
    expect(hasSyncFailed()).toBe(false);
  });
});
