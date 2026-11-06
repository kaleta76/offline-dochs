import { readFileSync } from "node:fs";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { Route } from "./terminal";
import { terminalCacheKey } from "@/lib/terminal-actions";

const mocks = vi.hoisted(() => ({
  from: vi.fn(),
  enqueue: vi.fn(),
  online: true,
  userId: "owner",
  organizationId: "company",
  today: [] as {
    client_uuid: string;
    code: string;
    direction: string;
    client_time: string;
    drift_minutes: number;
    voided_at: null;
  }[],
}));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { from: mocks.from } }));
vi.mock("@/lib/auth", () => ({
  useAuth: () => ({
    session: { user: { id: mocks.userId } },
    profile: { sap_id: "9000001", organization_id: mocks.organizationId },
  }),
}));
vi.mock("@/lib/offline-queue", () => ({
  useQueue: () => ({ items: [], online: mocks.online }),
  enqueue: mocks.enqueue,
}));
vi.mock("@/components/DeviceRegistration", () => ({ DeviceRegistration: () => null }));

function mount() {
  const Component = Route.options.component;
  if (!Component) throw new Error("Terminal component missing");
  return render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <Component />
    </QueryClientProvider>,
  );
}

describe("terminal configured punching", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    localStorage.clear();
    mocks.online = true;
    mocks.userId = "owner";
    mocks.organizationId = "company";
    mocks.today = [];
    const config = JSON.parse(readFileSync("contract/examples/config_example.json", "utf8"));
    mocks.from.mockImplementation((table: string) => {
      const query = {
        select: () => query,
        eq: () => query,
        gte: () => query,
        order: () => Promise.resolve({ data: mocks.today, error: null }),
        maybeSingle: () =>
          Promise.resolve({
            data: table === "access_config" ? { config_version: "2026.11.04.1200", config } : null,
            error: null,
          }),
      };
      return query;
    });
    mocks.enqueue.mockResolvedValue({ client_time: "2026-11-05T10:00:00Z" });
  });

  it("sends the configured interruption code through the existing queue", async () => {
    mount();
    await waitFor(() =>
      expect(localStorage.getItem(terminalCacheKey("owner", "company"))).not.toBeNull(),
    );
    fireEvent.click(screen.getByRole("button", { name: "Služobné vzdialenie" }));
    await waitFor(() =>
      expect(mocks.enqueue).toHaveBeenCalledWith({
        user_id: "owner",
        code: "ERRAND",
        direction: "OUT",
      }),
    );
  });

  it("keeps every punch button enabled with a full-day punch today and enqueues arrival", async () => {
    mocks.today = [
      {
        client_uuid: "full-day-today",
        code: "LEAVE",
        direction: "OUT",
        client_time: new Date().toISOString(),
        drift_minutes: 0,
        voided_at: null,
      },
    ];
    mount();
    await screen.findByRole("alert");
    const buttons = screen.getAllByRole("button");
    expect(buttons).toHaveLength(6);
    for (const button of buttons) expect(button).toBeEnabled();
    fireEvent.click(screen.getByRole("button", { name: "Príchod" }));
    await waitFor(() =>
      expect(mocks.enqueue).toHaveBeenCalledWith({
        user_id: "owner",
        code: "WORK",
        direction: "IN",
      }),
    );
  });

  it("uses persisted buttons after offline reopening without a configuration request", async () => {
    const mounted = mount();
    await waitFor(() =>
      expect(localStorage.getItem(terminalCacheKey("owner", "company"))).not.toBeNull(),
    );
    mounted.unmount();
    mocks.from.mockClear();
    mocks.online = false;
    mount();
    await waitFor(() => expect(screen.queryByRole("button", { name: "Súkromne" })).toBeNull());
    fireEvent.click(screen.getByRole("button", { name: "Služobná cesta" }));
    await waitFor(() =>
      expect(mocks.enqueue).toHaveBeenCalledWith({
        user_id: "owner",
        code: "TRIP",
        direction: "OUT",
      }),
    );
    expect(mocks.from).not.toHaveBeenCalled();
  });

  it("falls back without blocking punching when configuration cannot be read", async () => {
    mocks.from.mockImplementation(() => {
      const query = {
        select: () => query,
        eq: () => query,
        gte: () => query,
        order: () => Promise.resolve({ data: [], error: null }),
        maybeSingle: () =>
          Promise.resolve({ data: null, error: { message: "Network unavailable" } }),
      };
      return query;
    });
    mount();
    fireEvent.click(screen.getByRole("button", { name: "Príchod" }));
    await waitFor(() =>
      expect(mocks.enqueue).toHaveBeenCalledWith({
        user_id: "owner",
        code: "WORK",
        direction: "IN",
      }),
    );
  });
});
