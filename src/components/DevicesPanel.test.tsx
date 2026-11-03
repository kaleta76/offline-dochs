import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { DevicesPanel } from "./DevicesPanel";

const { from, rpc, deviceNeq } = vi.hoisted(() => ({
  from: vi.fn(), rpc: vi.fn(), deviceNeq: vi.fn(),
}));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { from, rpc } }));

describe("DevicesPanel own-device approval", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    rpc.mockResolvedValue({ error: null });
    from.mockImplementation((table: string) => {
      if (table === "profiles") return { select: () => Promise.resolve({ data: [{ id: "owner", sap_id: "00123456" }] }) };
      const query = {
        select: () => query,
        eq: () => query,
        neq: (column: string, value: string) => {
          if (table === "devices") deviceNeq(column, value);
          return query;
        },
        order: () => table === "devices" ? Promise.resolve({ data: [{
          id: "own-device", user_id: "owner", status: "pending", pairing_code: "123456",
          pairing_expires_at: null, created_at: "2026-11-02T00:00:00Z",
          last_seen_at: null, user_agent_hint: "Edge", replaces_device_id: null,
        }], error: null }) : query,
        limit: () => Promise.resolve({ data: [], error: null }),
      };
      return query;
    });
  });

  it("does not exclude the owner from the device query", async () => {
    render(<QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <DevicesPanel uid="owner" />
    </QueryClientProvider>);
    await screen.findByText("123456");
    expect(deviceNeq).not.toHaveBeenCalledWith("user_id", "owner");
  });

  it("submits the own-device approval to the existing authorized RPC", async () => {
    render(<QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <DevicesPanel uid="owner" />
    </QueryClientProvider>);
    fireEvent.click(await screen.findByRole("button", { name: "Schváliť ako primárne" }));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith("approve_device", { _id: "own-device", _as_backup: false }));
  });
});

describe("DevicesPanel device changes", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    rpc.mockResolvedValue({ error: null });
    const recent = new Date().toISOString();
    const base = {
      user_id: "emp", pairing_code: null, pairing_expires_at: null, last_seen_at: null,
      created_at: "2026-10-01T08:00:00Z", approved_by: "boss", approved_at: "2026-10-01T08:05:00Z",
      revoked_at: null, revoke_reason: null, replaces_device_id: null,
    };
    const rows = [
      { ...base, id: "c0de0000-0000-4000-8000-000000000001", status: "revoked", revoked_at: recent, revoke_reason: "Obnova záchranným kódom",
        user_agent_hint: "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" },
      { ...base, id: "a3f90000-0000-4000-8000-000000000002", status: "active", approved_by: "emp", approved_at: recent,
        replaces_device_id: "c0de0000-0000-4000-8000-000000000001", user_agent_hint: "Mozilla/5.0 (Linux; Android 14; Pixel 8)" },
    ];
    from.mockImplementation((table: string) => {
      if (table === "profiles") return { select: () => Promise.resolve({ data: [{ id: "emp", sap_id: "00123456" }] }) };
      const query = {
        select: () => query,
        eq: () => query,
        neq: () => query,
        order: () => table === "devices" ? Promise.resolve({ data: rows, error: null }) : query,
        limit: () => Promise.resolve({ data: [], error: null }),
      };
      return query;
    });
  });

  it("shows a device recovered with a recovery code as a change, including the change of device type", async () => {
    render(<QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <DevicesPanel uid="boss" />
    </QueryClientProvider>);
    await screen.findByText("obnovené záchranným kódom, bez schválenia vedúceho");
    expect(screen.getByText("zmena typu zariadenia")).toBeTruthy();
    expect(screen.getByRole("button", { name: "Zrušiť zariadenie" })).toBeTruthy();
  });
});