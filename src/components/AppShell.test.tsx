import { render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { AppShell } from "./AppShell";

const mocks = vi.hoisted(() => ({
  queue: { items: [] as unknown[], online: true, syncFailed: false, parked: null as unknown },
  meError: null as string | null,
}));

vi.mock("@tanstack/react-router", () => ({
  Link: ({ to, children, ...rest }: { to: string; children?: React.ReactNode }) => (
    <a href={to} {...rest}>
      {children}
    </a>
  ),
  Outlet: () => <div>obsah stránky</div>,
  useNavigate: () => () => undefined,
}));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { auth: { signOut: vi.fn() } } }));
vi.mock("@/lib/auth", () => ({
  useAuth: () => ({
    roles: [],
    profile: { id: "u1", sap_id: "9000002" },
    session: { user: { id: "u1" } },
    organization: { name: "Firma", is_test: false },
    meError: mocks.meError,
    refetchMe: vi.fn(),
  }),
}));
vi.mock("@/lib/offline-queue", () => ({
  useQueue: () => mocks.queue,
  syncNow: vi.fn(),
  discardParked: vi.fn(),
  SYNC_FAILED_MESSAGE: "Odoslanie sa nepodarilo potvrdiť.",
}));
vi.mock("@/lib/idle-timeout", () => ({
  useIdleSignOut: () => undefined,
  signOutForInactivity: vi.fn(),
  signedInAtOf: () => 0,
}));

const mount = () =>
  render(
    <QueryClientProvider client={new QueryClient()}>
      <AppShell />
    </QueryClientProvider>,
  );
const link = () => screen.queryByRole("link", { name: "Diagnostika" });

describe("AppShell: odkaz na Diagnostiku", () => {
  beforeEach(() => {
    mocks.queue = { items: [], online: true, syncFailed: false, parked: null };
    mocks.meError = null;
  });

  it("bez problému sa odkaz neukáže (diagnostika nie je v ponuke)", () => {
    mount();
    expect(screen.getByText("obsah stránky")).toBeTruthy();
    expect(link()).toBeNull();
  });

  it("pri zlyhanom odosielaní razení sa ukáže odkaz na /diagnostika", () => {
    mocks.queue = { items: [{}], online: true, syncFailed: true, parked: null };
    mount();
    expect(link()?.getAttribute("href")).toBe("/diagnostika");
  });

  it("pri razení, ktoré server odmietol, sa ukáže odkaz", () => {
    mocks.queue = {
      items: [{}],
      online: true,
      syncFailed: true,
      parked: {
        client_uuid: "x",
        client_time: "2026-11-11T12:33:00Z",
        code: "ERRAND",
        direction: "OUT",
        error: "chyba",
      },
    };
    mount();
    expect(link()).not.toBeNull();
  });

  it("pri zlyhaní načítania údajov o účte sa ukáže odkaz", () => {
    mocks.meError = "Failed to fetch";
    mount();
    expect(link()).not.toBeNull();
  });

  it("bez spojenia (offline) sa odkaz neukáže, test by nič nepovedal", () => {
    mocks.queue = { items: [{}], online: false, syncFailed: true, parked: null };
    mount();
    expect(link()).toBeNull();
  });
});
