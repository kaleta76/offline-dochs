import "fake-indexeddb/auto";
import { renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ signOut: vi.fn(), getUser: vi.fn() }));
vi.mock("@/integrations/supabase/client", () => ({
  supabase: { auth: { signOut: mocks.signOut, getUser: mocks.getUser } },
}));

import {
  ACTIVITY_THROTTLE_MS,
  IDLE_GRACE_MS,
  IDLE_LIMIT_MS,
  IDLE_SIGNOUT_KEY,
  LAST_ACTIVITY_KEY,
  PROBE_RETRY_MS,
  beginActiveSession,
  decideIdleExpiry,
  idleDeadline,
  isIdleExpired,
  isIdleSignOutPending,
  readLastActivity,
  recordActivity,
  resetServerProbe,
  signOutForInactivity,
  useIdleSignOut,
} from "./idle-timeout";

const HOUR = 60 * 60 * 1000;
const T0 = Date.parse("2026-11-09T06:00:00Z");

beforeEach(() => {
  localStorage.clear();
  resetServerProbe();
  mocks.signOut.mockReset();
  mocks.signOut.mockResolvedValue({ error: null });
  mocks.getUser.mockReset();
  mocks.getUser.mockResolvedValue({ data: { user: { id: "user-a" } }, error: null });
});
afterEach(() => {
  vi.useRealTimers();
});

describe("idle limit of 12 hours", () => {
  it("is 12 hours", () => {
    expect(IDLE_LIMIT_MS).toBe(12 * HOUR);
  });
  it("does not sign out at exactly 12 hours, but does after more than 12 hours", () => {
    expect(isIdleExpired(T0, T0 + 12 * HOUR)).toBe(false);
    expect(isIdleExpired(T0, T0 + 12 * HOUR + 1)).toBe(true);
  });
  it("never expires without a stored activity (first start after the update)", () => {
    expect(isIdleExpired(null, T0 + 100 * HOUR)).toBe(false);
  });
  it("a newer sign-in overrides a stale stored activity", () => {
    expect(isIdleExpired(T0, T0 + 13 * HOUR, T0 + 12 * HOUR)).toBe(false);
  });
});

describe("activity recording", () => {
  it("writes last_activity_at at most once a minute", () => {
    expect(recordActivity(T0)).toBe(true);
    expect(recordActivity(T0 + 30_000)).toBe(false);
    expect(readLastActivity()).toBe(T0);
    expect(recordActivity(T0 + ACTIVITY_THROTTLE_MS)).toBe(true);
    expect(localStorage.getItem(LAST_ACTIVITY_KEY)).toBe(String(T0 + ACTIVITY_THROTTLE_MS));
  });
  it("a punch (forced) is always recorded", () => {
    recordActivity(T0);
    expect(recordActivity(T0 + 1_000, undefined, true)).toBe(true);
    expect(readLastActivity()).toBe(T0 + 1_000);
  });
  it("a new sign-in clears the pending idle sign-out and refreshes activity", () => {
    localStorage.setItem(IDLE_SIGNOUT_KEY, "1");
    localStorage.setItem(LAST_ACTIVITY_KEY, String(T0));
    beginActiveSession(T0 + 20 * HOUR);
    expect(isIdleSignOutPending()).toBe(false);
    expect(readLastActivity()).toBe(T0 + 20 * HOUR);
  });
});

describe("useIdleSignOut", () => {
  it("signs out after more than 12 hours of inactivity, checked periodically", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    const onExpire = vi.fn();
    renderHook(() => useIdleSignOut({ enabled: true, signedInAt: null, onExpire }));
    expect(readLastActivity()).toBe(T0);
    await vi.advanceTimersByTimeAsync(12 * HOUR);
    expect(onExpire).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(2 * 60_000);
    expect(onExpire).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(HOUR);
    expect(onExpire).toHaveBeenCalledTimes(1);
  });
  it("user activity postpones the sign-out", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    const onExpire = vi.fn();
    renderHook(() => useIdleSignOut({ enabled: true, signedInAt: null, onExpire }));
    await vi.advanceTimersByTimeAsync(11 * HOUR);
    window.dispatchEvent(new Event("keydown"));
    await vi.advanceTimersByTimeAsync(11 * HOUR);
    expect(onExpire).not.toHaveBeenCalled();
    expect(readLastActivity()).toBe(T0 + 11 * HOUR);
  });
  it("checks immediately when the tab becomes visible again", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    localStorage.setItem(LAST_ACTIVITY_KEY, String(T0));
    const onExpire = vi.fn();
    renderHook(() => useIdleSignOut({ enabled: true, signedInAt: null, onExpire }));
    vi.setSystemTime(T0 + 13 * HOUR); // e.g. computer was asleep, timers did not run
    document.dispatchEvent(new Event("visibilitychange"));
    await vi.advanceTimersByTimeAsync(0);
    expect(onExpire).toHaveBeenCalledTimes(1);
  });
  it("a click after a long pause signs out instead of counting as fresh activity", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    localStorage.setItem(LAST_ACTIVITY_KEY, String(T0));
    const onExpire = vi.fn();
    renderHook(() => useIdleSignOut({ enabled: true, signedInAt: null, onExpire }));
    vi.setSystemTime(T0 + 13 * HOUR);
    window.dispatchEvent(new Event("pointerdown"));
    await vi.advanceTimersByTimeAsync(0);
    expect(onExpire).toHaveBeenCalledTimes(1);
    expect(readLastActivity()).toBe(T0);
  });
  it("does nothing while signed out", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    localStorage.setItem(LAST_ACTIVITY_KEY, String(T0));
    const onExpire = vi.fn();
    renderHook(() => useIdleSignOut({ enabled: false, signedInAt: null, onExpire }));
    await vi.advanceTimersByTimeAsync(24 * HOUR);
    expect(onExpire).not.toHaveBeenCalled();
  });
  it("defers the sign-out while the server cannot be reached and signs out when it answers again", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    localStorage.setItem(LAST_ACTIVITY_KEY, String(T0));
    mocks.getUser.mockRejectedValue(new TypeError("Failed to fetch"));
    const onExpire = vi.fn();
    renderHook(() => useIdleSignOut({ enabled: true, signedInAt: null, onExpire }));
    await vi.advanceTimersByTimeAsync(13 * HOUR);
    expect(onExpire).not.toHaveBeenCalled();
    expect(mocks.getUser).toHaveBeenCalled();
    mocks.getUser.mockResolvedValue({ data: { user: { id: "user-a" } }, error: null });
    await vi.advanceTimersByTimeAsync(PROBE_RETRY_MS + 60_000);
    expect(onExpire).toHaveBeenCalledTimes(1);
  });
  it("does not record a click as fresh activity while the sign-out is deferred", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    localStorage.setItem(LAST_ACTIVITY_KEY, String(T0));
    mocks.getUser.mockRejectedValue(new TypeError("Failed to fetch"));
    const onExpire = vi.fn();
    renderHook(() => useIdleSignOut({ enabled: true, signedInAt: null, onExpire }));
    vi.setSystemTime(T0 + 13 * HOUR);
    window.dispatchEvent(new Event("pointerdown"));
    await vi.advanceTimersByTimeAsync(0);
    expect(onExpire).not.toHaveBeenCalled();
    expect(readLastActivity()).toBe(T0);
  });
  it("signs out when the connection returns and the server answers (online event)", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    localStorage.setItem(LAST_ACTIVITY_KEY, String(T0));
    mocks.getUser.mockRejectedValue(new TypeError("Failed to fetch"));
    const onExpire = vi.fn();
    renderHook(() => useIdleSignOut({ enabled: true, signedInAt: null, onExpire }));
    vi.setSystemTime(T0 + 13 * HOUR);
    window.dispatchEvent(new Event("online"));
    await vi.advanceTimersByTimeAsync(0);
    expect(onExpire).not.toHaveBeenCalled();
    mocks.getUser.mockResolvedValue({ data: { user: { id: "user-a" } }, error: null });
    window.dispatchEvent(new Event("online"));
    await vi.advanceTimersByTimeAsync(0);
    expect(onExpire).toHaveBeenCalledTimes(1);
  });
  it("signs out after the grace period even if the server never answers", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    localStorage.setItem(LAST_ACTIVITY_KEY, String(T0));
    mocks.getUser.mockRejectedValue(new TypeError("Failed to fetch"));
    const onExpire = vi.fn();
    renderHook(() => useIdleSignOut({ enabled: true, signedInAt: null, onExpire }));
    await vi.advanceTimersByTimeAsync(12 * HOUR + IDLE_GRACE_MS - 60_000);
    expect(onExpire).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(3 * 60_000);
    expect(onExpire).toHaveBeenCalledTimes(1);
  });
});

describe("decideIdleExpiry", () => {
  const base = { lastActivity: T0, signedInAt: null, limitMs: 12 * HOUR };
  it("is active while the limit has not passed", async () => {
    const probe = vi.fn();
    expect(await decideIdleExpiry({ ...base, now: T0 + 12 * HOUR, probe })).toBe("active");
    expect(probe).not.toHaveBeenCalled();
  });
  it("is active without any stored activity", async () => {
    expect(await decideIdleExpiry({ ...base, lastActivity: null, now: T0 + 100 * HOUR })).toBe("active");
  });
  it("signs out when the limit has passed and the server answers", async () => {
    const probe = vi.fn().mockResolvedValue(true);
    expect(await decideIdleExpiry({ ...base, now: T0 + 13 * HOUR, probe })).toBe("signout");
    expect(probe).toHaveBeenCalledTimes(1);
  });
  it("defers when the limit has passed and the server cannot be reached", async () => {
    const probe = vi.fn().mockResolvedValue(false);
    expect(await decideIdleExpiry({ ...base, now: T0 + 13 * HOUR, probe })).toBe("defer");
  });
  it("does not repeat a failed probe within the retry interval", async () => {
    const probe = vi.fn().mockResolvedValue(false);
    const now = T0 + 13 * HOUR;
    await decideIdleExpiry({ ...base, now, probe });
    expect(await decideIdleExpiry({ ...base, now: now + PROBE_RETRY_MS - 1, probe })).toBe("defer");
    expect(probe).toHaveBeenCalledTimes(1);
    probe.mockResolvedValue(true);
    expect(await decideIdleExpiry({ ...base, now: now + PROBE_RETRY_MS, probe })).toBe("signout");
    expect(probe).toHaveBeenCalledTimes(2);
  });
  it("signs out after the grace period without asking the server", async () => {
    const probe = vi.fn().mockResolvedValue(false);
    const deadline = T0 + 12 * HOUR;
    expect(await decideIdleExpiry({ ...base, now: deadline + IDLE_GRACE_MS, probe })).toBe("defer");
    expect(await decideIdleExpiry({ ...base, now: deadline + IDLE_GRACE_MS + 1, probe })).toBe("signout");
  });
  it("counts the grace period from the later of last activity and sign-in", async () => {
    const probe = vi.fn().mockResolvedValue(false);
    const signedInAt = T0 + 30 * HOUR;
    const now = signedInAt + 12 * HOUR + 1;
    expect(await decideIdleExpiry({ ...base, signedInAt, now, probe })).toBe("defer");
  });
});

describe("idleDeadline", () => {
  it("is last activity (or sign-in, whichever is later) plus the limit", () => {
    expect(idleDeadline(T0, null, 12 * HOUR)).toBe(T0 + 12 * HOUR);
    expect(idleDeadline(T0, T0 + 5 * HOUR, 12 * HOUR)).toBe(T0 + 17 * HOUR);
    expect(idleDeadline(null, null, 12 * HOUR)).toBeNull();
  });
});

function putQueued(item: { client_uuid: string; user_id: string }) {
  return new Promise<void>((resolve, reject) => {
    const open = indexedDB.open("dochadzka", 1);
    open.onupgradeneeded = () => open.result.createObjectStore("queue", { keyPath: "client_uuid" });
    open.onsuccess = () => {
      const tx = open.result.transaction("queue", "readwrite");
      tx.objectStore("queue").put(item);
      tx.oncomplete = () => {
        open.result.close();
        resolve();
      };
      tx.onerror = () => reject(tx.error);
    };
  });
}
function countQueued() {
  return new Promise<number>((resolve) => {
    const open = indexedDB.open("dochadzka", 1);
    open.onsuccess = () => {
      const req = open.result.transaction("queue").objectStore("queue").count();
      req.onsuccess = () => {
        open.result.close();
        resolve(req.result);
      };
    };
  });
}

describe("signOutForInactivity", () => {
  it("signs out, keeps every waiting punch in the device and marks the idle sign-out", async () => {
    await putQueued({ client_uuid: "waiting-1", user_id: "user-a" });
    await putQueued({ client_uuid: "waiting-2", user_id: "user-a" });
    localStorage.setItem("me-cache:user-a", "{}");
    await signOutForInactivity("user-a");
    expect(mocks.signOut).toHaveBeenCalled();
    expect(await countQueued()).toBe(2);
    expect(isIdleSignOutPending()).toBe(true);
    expect(localStorage.getItem("me-cache:user-a")).toBeNull();
  });
  it("falls back to a local sign-out when the server cannot be reached", async () => {
    mocks.signOut
      .mockResolvedValueOnce({ error: { message: "Failed to fetch" } })
      .mockResolvedValueOnce({ error: null });
    await signOutForInactivity("user-a");
    expect(mocks.signOut).toHaveBeenLastCalledWith({ scope: "local" });
    expect(isIdleSignOutPending()).toBe(true);
  });
});
