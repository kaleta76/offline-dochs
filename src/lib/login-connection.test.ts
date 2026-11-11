import { describe, expect, it, vi } from "vitest";
import {
  isConnectionFailure,
  OFFLINE_ACTION_MESSAGE,
  OFFLINE_LOGIN_MESSAGE,
  setSessionWithRetry,
} from "./login-connection";

describe("isConnectionFailure", () => {
  it("is true whenever the browser is offline, whatever the error", () => {
    expect(isConnectionFailure(new Error("Neplatné údaje"), false)).toBe(true);
    expect(isConnectionFailure(null, false)).toBe(true);
  });
  it("recognises network failures, retryable auth errors and gateway answers", () => {
    expect(isConnectionFailure(new TypeError("Failed to fetch"), true)).toBe(true);
    expect(isConnectionFailure({ name: "AuthRetryableFetchError", message: "x" }, true)).toBe(true);
    expect(isConnectionFailure({ status: 0 }, true)).toBe(true);
    expect(isConnectionFailure({ status: 502 }, true)).toBe(true);
    expect(isConnectionFailure({ status: 503 }, true)).toBe(true);
    expect(isConnectionFailure({ status: 504 }, true)).toBe(true);
  });
  it("treats a non-JSON answer (for example a proxy page) as a connection failure", () => {
    expect(isConnectionFailure(new SyntaxError("Unexpected token <"), true)).toBe(true);
  });
  it("is false for a clear rejection and for an empty or unknown error while online", () => {
    expect(isConnectionFailure({ status: 400, message: "Invalid login credentials" }, true)).toBe(
      false,
    );
    expect(isConnectionFailure({ status: 401 }, true)).toBe(false);
    expect(isConnectionFailure(new Error("Neplatný PIN"), true)).toBe(false);
    expect(isConnectionFailure(null, true)).toBe(false);
    expect(isConnectionFailure("text", true)).toBe(false);
  });
  it("offline messages say what happened and that waiting punches are safe", () => {
    expect(OFFLINE_LOGIN_MESSAGE).toMatch(/Bez spojenia/);
    expect(OFFLINE_LOGIN_MESSAGE).toMatch(/nestratia/);
    expect(OFFLINE_ACTION_MESSAGE).toMatch(/Bez spojenia/);
  });
});

describe("setSessionWithRetry", () => {
  const fast = { sleep: async () => {}, online: () => true };
  it("succeeds on the first attempt without a retry", async () => {
    const attempt = vi.fn().mockResolvedValue({ error: null });
    expect(await setSessionWithRetry(attempt, fast)).toEqual({ ok: true, connection: false });
    expect(attempt).toHaveBeenCalledTimes(1);
  });
  it("retries once after a connection failure and succeeds", async () => {
    const attempt = vi
      .fn()
      .mockResolvedValueOnce({
        error: { name: "AuthRetryableFetchError", message: "Failed to fetch" },
      })
      .mockResolvedValueOnce({ error: null });
    expect(await setSessionWithRetry(attempt, fast)).toEqual({ ok: true, connection: false });
    expect(attempt).toHaveBeenCalledTimes(2);
  });
  it("gives up after one retry and reports a connection failure", async () => {
    const attempt = vi.fn().mockResolvedValue({ error: new TypeError("Failed to fetch") });
    expect(await setSessionWithRetry(attempt, fast)).toEqual({ ok: false, connection: true });
    expect(attempt).toHaveBeenCalledTimes(2);
  });
  it("does not retry when the server rejects the tokens", async () => {
    const attempt = vi.fn().mockResolvedValue({ error: { status: 401, message: "invalid JWT" } });
    expect(await setSessionWithRetry(attempt, fast)).toEqual({ ok: false, connection: false });
    expect(attempt).toHaveBeenCalledTimes(1);
  });
  it("does not retry while the browser is offline", async () => {
    const attempt = vi.fn().mockResolvedValue({ error: new TypeError("Failed to fetch") });
    expect(await setSessionWithRetry(attempt, { ...fast, online: () => false })).toEqual({
      ok: false,
      connection: true,
    });
    expect(attempt).toHaveBeenCalledTimes(1);
  });
  it("treats a thrown error like a returned one", async () => {
    const attempt = vi
      .fn()
      .mockRejectedValueOnce(new TypeError("Failed to fetch"))
      .mockResolvedValueOnce({ error: null });
    expect(await setSessionWithRetry(attempt, fast)).toEqual({ ok: true, connection: false });
  });
  it("waits the configured delay between attempts", async () => {
    const sleep = vi.fn().mockResolvedValue(undefined);
    const attempt = vi
      .fn()
      .mockResolvedValueOnce({ error: new TypeError("Failed to fetch") })
      .mockResolvedValueOnce({ error: null });
    await setSessionWithRetry(attempt, { sleep, online: () => true, delayMs: 700 });
    expect(sleep).toHaveBeenCalledWith(700);
  });
});
