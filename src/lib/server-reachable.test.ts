import { afterEach, describe, expect, it, vi } from "vitest";
import { isServerReachable, PROBE_TIMEOUT_MS, serverAnswered } from "./server-reachable";

afterEach(() => {
  vi.useRealTimers();
});

describe("serverAnswered", () => {
  it("is true without an error and for a clear rejection (4xx)", () => {
    expect(serverAnswered(null)).toBe(true);
    expect(serverAnswered(undefined)).toBe(true);
    expect(serverAnswered({ status: 401, message: "invalid JWT" })).toBe(true);
    expect(serverAnswered({ status: 403, message: "forbidden" })).toBe(true);
  });
  it("is false for network errors, gateway answers, timeouts and throttling", () => {
    expect(serverAnswered({ name: "AuthRetryableFetchError", message: "Failed to fetch" })).toBe(
      false,
    );
    expect(serverAnswered({ message: "Failed to fetch" })).toBe(false);
    expect(serverAnswered({ status: 502 })).toBe(false);
    expect(serverAnswered({ status: 503 })).toBe(false);
    expect(serverAnswered({ status: 408 })).toBe(false);
    expect(serverAnswered({ status: 429 })).toBe(false);
  });
});

describe("isServerReachable", () => {
  it("does not try the request while the browser is offline", async () => {
    const check = vi.fn().mockResolvedValue({ error: null });
    expect(await isServerReachable(check, { online: false })).toBe(false);
    expect(check).not.toHaveBeenCalled();
  });
  it("is true when the server answers, also with a clear rejection", async () => {
    expect(await isServerReachable(async () => ({ error: null }), { online: true })).toBe(true);
    expect(
      await isServerReachable(async () => ({ error: { status: 401 } }), { online: true }),
    ).toBe(true);
  });
  it("is false when the request throws or returns a connection error", async () => {
    expect(
      await isServerReachable(
        async () => {
          throw new TypeError("Failed to fetch");
        },
        { online: true },
      ),
    ).toBe(false);
    expect(
      await isServerReachable(
        async () => ({ error: { name: "AuthRetryableFetchError", message: "x" } }),
        {
          online: true,
        },
      ),
    ).toBe(false);
  });
  it("is false when the server does not answer in time", async () => {
    vi.useFakeTimers();
    const pending = isServerReachable(() => new Promise(() => {}), { online: true });
    await vi.advanceTimersByTimeAsync(PROBE_TIMEOUT_MS + 1);
    expect(await pending).toBe(false);
  });
  it("clears its timer after a fast answer", async () => {
    vi.useFakeTimers();
    await isServerReachable(async () => ({ error: null }), { online: true });
    expect(vi.getTimerCount()).toBe(0);
  });
});
