import "fake-indexeddb/auto";
import { renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ signOut: vi.fn() }));
vi.mock("@/integrations/supabase/client", () => ({
  supabase: { auth: { signOut: mocks.signOut } },
}));

import {
  ACTIVITY_THROTTLE_MS,
  IDLE_LIMIT_MS,
  IDLE_SIGNOUT_KEY,
  LAST_ACTIVITY_KEY,
  beginActiveSession,
  isIdleExpired,
  isIdleSignOutPending,
  readLastActivity,
  recordActivity,
  signOutForInactivity,
  useIdleSignOut,
} from "./idle-timeout";

const HOUR = 60 * 60 * 1000;
const T0 = Date.parse("2026-11-09T06:00:00Z");

beforeEach(() => {
  localStorage.clear();
  mocks.signOut.mockReset();
  mocks.signOut.mockResolvedValue({ error: null });
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
  it("signs out after more than 12 hours of inactivity, checked periodically", () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    const onExpire = vi.fn();
    renderHook(() => useIdleSignOut({ enabled: true, signedInAt: null, onExpire }));
    expect(readLastActivity()).toBe(T0);
    vi.advanceTimersByTime(12 * HOUR);
    expect(onExpire).not.toHaveBeenCalled();
    vi.advanceTimersByTime(2 * 60_000);
    expect(onExpire).toHaveBeenCalledTimes(1);
    vi.advanceTimersByTime(HOUR);
    expect(onExpire).toHaveBeenCalledTimes(1);
  });
  it("user activity postpones the sign-out", () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    const onExpire = vi.fn();
    renderHook(() => useIdleSignOut({ enabled: true, signedInAt: null, onExpire }));
    vi.advanceTimersByTime(11 * HOUR);
    window.dispatchEvent(new Event("keydown"));
    vi.advanceTimersByTime(11 * HOUR);
    expect(onExpire).not.toHaveBeenCalled();
    expect(readLastActivity()).toBe(T0 + 11 * HOUR);
  });
  it("checks immediately when the tab becomes visible again", () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    localStorage.setItem(LAST_ACTIVITY_KEY, String(T0));
    const onExpire = vi.fn();
    renderHook(() => useIdleSignOut({ enabled: true, signedInAt: null, onExpire }));
    vi.setSystemTime(T0 + 13 * HOUR); // e.g. computer was asleep, timers did not run
    document.dispatchEvent(new Event("visibilitychange"));
    expect(onExpire).toHaveBeenCalledTimes(1);
  });
  it("a click after a long pause signs out instead of counting as fresh activity", () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    localStorage.setItem(LAST_ACTIVITY_KEY, String(T0));
    const onExpire = vi.fn();
    renderHook(() => useIdleSignOut({ enabled: true, signedInAt: null, onExpire }));
    vi.setSystemTime(T0 + 13 * HOUR);
    window.dispatchEvent(new Event("pointerdown"));
    expect(onExpire).toHaveBeenCalledTimes(1);
    expect(readLastActivity()).toBe(T0);
  });
  it("does nothing while signed out", () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    localStorage.setItem(LAST_ACTIVITY_KEY, String(T0));
    const onExpire = vi.fn();
    renderHook(() => useIdleSignOut({ enabled: false, signedInAt: null, onExpire }));
    vi.advanceTimersByTime(24 * HOUR);
    expect(onExpire).not.toHaveBeenCalled();
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
