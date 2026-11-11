import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { AutoApprovalPanel } from "./AutoApprovalPanel";

type DbResult = { data: unknown; error: { code?: string; message: string } | null };

const ME = "11111111-1111-4111-8111-111111111111";
const OTHER_MGR = "22222222-2222-4222-8222-222222222222";
const E1 = "e1000000-0000-4000-8000-000000000001";
const E2 = "e2000000-0000-4000-8000-000000000002";
const E3 = "e3000000-0000-4000-8000-000000000003";

const mocks = vi.hoisted(() => ({
  tables: {} as Record<string, DbResult>,
  rpc: vi.fn(),
}));
vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    rpc: mocks.rpc,
    from: (table: string) => {
      const result = mocks.tables[table] ?? { data: [], error: null };
      const query: Record<string, unknown> = {};
      for (const method of ["select", "eq", "neq", "gte", "in", "order", "limit"]) {
        query[method] = () => query;
      }
      query.then = (resolve: (v: DbResult) => unknown, reject?: (e: unknown) => unknown) =>
        Promise.resolve(result).then(resolve, reject);
      return query;
    },
  },
}));

const person = (id: string, sap: string, manager: string | null) => ({
  id,
  sap_id: sap,
  department: null,
  manager_id: manager,
});

function mount(isAdmin: boolean) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <AutoApprovalPanel uid={ME} isAdmin={isAdmin} />
    </QueryClientProvider>,
  );
}

describe("AutoApprovalPanel", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.rpc.mockResolvedValue({ data: null, error: null });
    mocks.tables = {
      profiles: {
        data: [
          person(E1, "9000002", ME),
          person(E2, "9000003", ME),
          person(E3, "9000004", OTHER_MGR),
        ],
        error: null,
      },
      correction_auto_approvals: {
        data: [{ user_id: E2, manager_id: ME, enabled_at: "2026-11-10T08:00:00Z" }],
        error: null,
      },
      corrections: {
        data: [
          {
            id: "c1",
            user_id: E2,
            code: "WORK",
            direction: "IN",
            at_time: "2026-11-10T07:30:00Z",
            reason: "Zabudol som odpípať",
            created_at: "2026-11-10T08:05:00Z",
            punch_id: 41,
          },
          {
            id: "c2",
            user_id: E2,
            code: "WORK",
            direction: "OUT",
            at_time: "2026-11-10T15:30:00Z",
            reason: "Zabudol som odpípať večer",
            created_at: "2026-11-10T16:05:00Z",
            punch_id: 42,
          },
        ],
        error: null,
      },
      punches: { data: [{ id: 42, voided_at: "2026-11-10T17:00:00Z" }], error: null },
    };
  });

  it("vedúci vidí svojich podriadených: zapnúť pri vypnutom, vypnúť pri zapnutom", async () => {
    mount(false);
    expect(await screen.findByText("9000002")).toBeTruthy();
    expect(screen.getByText("9000003")).toBeTruthy();
    expect(screen.getAllByRole("button", { name: "Zapnúť" })).toHaveLength(1);
    // Jedno „Vypnúť“ pri zapnutom zamestnancovi.
    expect(screen.getAllByRole("button", { name: "Vypnúť" })).toHaveLength(1);
    fireEvent.click(screen.getByRole("button", { name: "Zapnúť" }));
    await waitFor(() =>
      expect(mocks.rpc).toHaveBeenCalledWith("set_correction_auto_approval", {
        _user: E1,
        _enabled: true,
      }),
    );
  });

  it("vypnutie volá funkciu s _enabled = false", async () => {
    mount(false);
    fireEvent.click(await screen.findByRole("button", { name: "Vypnúť" }));
    await waitFor(() =>
      expect(mocks.rpc).toHaveBeenCalledWith("set_correction_auto_approval", {
        _user: E2,
        _enabled: false,
      }),
    );
  });

  it("zoznam automaticky schválených: zneplatniť pri bežnom, značka pri zneplatnenom", async () => {
    mount(false);
    expect(await screen.findByText("„Zabudol som odpípať“")).toBeTruthy();
    expect(await screen.findByText("zneplatnené")).toBeTruthy();
    expect(screen.getAllByRole("button", { name: "Zneplatniť" })).toHaveLength(1);
  });

  it("správca vidí cudziu zapnutú voľbu a vie ju len vypnúť, nie zapnúť", async () => {
    mocks.tables.correction_auto_approvals = {
      data: [{ user_id: E3, manager_id: OTHER_MGR, enabled_at: "2026-11-09T08:00:00Z" }],
      error: null,
    };
    mount(true);
    expect(await screen.findByText("9000004")).toBeTruthy();
    // E1 a E2 sú priami podriadení správcu (zapnúť smie), E3 patrí inému vedúcemu (len vypnúť).
    expect(screen.getAllByRole("button", { name: "Zapnúť" })).toHaveLength(2);
    expect(screen.getAllByRole("button", { name: "Vypnúť" })).toHaveLength(1);
    expect(screen.getByText(/zapol/)).toBeTruthy();
  });

  it("chyba funkcie sa ukáže zamestnancovi aj vedúcemu v texte", async () => {
    mocks.rpc.mockResolvedValue({ data: null, error: { message: "Nemáte oprávnenie" } });
    mount(false);
    fireEvent.click(await screen.findByRole("button", { name: "Zapnúť" }));
    expect((await screen.findByRole("alert")).textContent).toContain("Nemáte oprávnenie");
  });

  it("databáza bez migrácie 0013: karta sa neukáže vôbec", async () => {
    mocks.tables.correction_auto_approvals = {
      data: null,
      error: {
        code: "PGRST205",
        message: "Could not find the table 'public.correction_auto_approvals'",
      },
    };
    const { container } = mount(false);
    await waitFor(() => expect(mocks.rpc).not.toHaveBeenCalled());
    await new Promise((r) => setTimeout(r, 30));
    expect(container.textContent).toBe("");
  });

  it("chyba spojenia ukáže krátke hlásenie, nie prázdnu stránku", async () => {
    mocks.tables.correction_auto_approvals = { data: null, error: { message: "Failed to fetch" } };
    mount(false);
    expect(await screen.findByText(/Nepodarilo sa načítať/)).toBeTruthy();
  });
});
