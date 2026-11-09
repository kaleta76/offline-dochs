import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc: mocks.rpc } }));
vi.mock("@/lib/device", () => ({
  getOrCreateDeviceKey: () =>
    Promise.resolve({
      key: { user_id: "u", token: "t", hash: "h", created_at: "" },
      persisted: true,
    }),
  ensurePersistent: () => Promise.resolve(true),
  newDeviceKey: vi.fn(),
  saveDeviceKey: vi.fn(),
}));
vi.mock("@/lib/device-trace", () => ({ deviceLabel: () => "PC-1" }));

import { DeviceRegistration } from "./DeviceRegistration";

const registerCalls = () =>
  mocks.rpc.mock.calls.filter(([name]) => name === "register_device").length;

describe("DeviceRegistration pending status checks", () => {
  beforeEach(() => {
    mocks.rpc.mockReset();
    mocks.rpc.mockImplementation((name: string) =>
      Promise.resolve(
        name === "register_device"
          ? {
              data: [
                {
                  device_id: "d1",
                  status: "pending",
                  pairing_code: "123456",
                  pairing_expires_at: new Date(Date.now() + 10 * 60_000).toISOString(),
                },
              ],
              error: null,
            }
          : { data: null, error: null },
      ),
    );
  });

  it("does not poll every 15 seconds while waiting for approval", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    try {
      render(<DeviceRegistration userId="u" online />);
      await screen.findByText("123456");
      expect(registerCalls()).toBe(1);
      await act(async () => {
        vi.advanceTimersByTime(60_000);
      });
      expect(registerCalls()).toBe(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it("re-checks when the user returns to the app (focus / visibilitychange), once per return", async () => {
    render(<DeviceRegistration userId="u" online />);
    await screen.findByText("123456");
    expect(registerCalls()).toBe(1);
    act(() => {
      document.dispatchEvent(new Event("visibilitychange"));
      window.dispatchEvent(new Event("focus"));
    });
    await waitFor(() => expect(registerCalls()).toBe(2));
  });

  it("re-checks on the manual button", async () => {
    render(<DeviceRegistration userId="u" online />);
    fireEvent.click(await screen.findByRole("button", { name: "Skontrolovať stav" }));
    await waitFor(() => expect(registerCalls()).toBe(2));
  });
});
