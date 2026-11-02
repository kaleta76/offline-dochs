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