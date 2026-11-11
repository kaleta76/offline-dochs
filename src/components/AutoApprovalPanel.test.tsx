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
      query["then"] = (resolve: (v: DbResult) => unknown, reject?: (e: unknown) => unknown) =>
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
    // Jedno kliknutie voľbu nezapne: najprv sa ukáže upozornenie a súhlas.
    expect(
      await screen.findByRole("group", { name: /Zapnúť automatické schvaľovanie opráv/ }),
    ).toBeTruthy();
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("zapnutie až po začiarknutí súhlasu: bez neho je potvrdzovacie tlačidlo zakázané", async () => {
    mount(false);
    fireEvent.click(await screen.findByRole("button", { name: "Zapnúť" }));
    const confirm = (await screen.findByRole("button", {
      name: "Zapnúť automatické schvaľovanie",
    })) as HTMLButtonElement;
    expect(confirm.disabled).toBe(true);
    fireEvent.click(confirm);
    expect(mocks.rpc).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("checkbox", { name: /Rozumiem, že opravy zamestnanca/ }));
    expect(confirm.disabled).toBe(false);
    fireEvent.click(confirm);
    await waitFor(() =>
      expect(mocks.rpc).toHaveBeenCalledWith("set_correction_auto_approval", {
        _user: E1,
        _enabled: true,
      }),
    );
    // Po úspešnom zapnutí upozornenie zmizne.
    await waitFor(() => expect(screen.queryByRole("group")).toBeNull());
  });

  it("upozornenie pomenuje, čo voľba znamená: okamžité schválenie, zodpovednosť, limity, ručné schvaľovanie", async () => {
    mount(false);
    fireEvent.click(await screen.findByRole("button", { name: "Zapnúť" }));
    const group = await screen.findByRole("group");
    const text = group.textContent ?? "";
    expect(text).toContain("okamžite a bez vášho rozhodnutia");
    expect(text).toContain("Zodpovednosť za tieto opravy ostáva na vás");
    expect(text).toContain("Najviac 5 za deň");
    expect(text).toContain("14 dní");
    expect(text).toContain("neoverených zariadení");
    expect(text).toContain("poradia príchodov a odchodov v ten deň");
    expect(text).toContain("druhý príchod po príchode");
    expect(text).toContain("Pri zmene vedúceho");
    expect(text).toContain("smie ju vypnúť aj správca");
  });

  it("popis karty hovorí, že sa schvaľuje len to, čo zapadá do poradia príchodov a odchodov", async () => {
    mount(false);
    await screen.findByRole("button", { name: "Zapnúť" });
    const text = (document.body.textContent ?? "").replace(/\s+/g, " ");
    expect(text).toContain("zapadajú do poradia príchodov a odchodov v ten deň");
    expect(text).toContain("ktoré nezapadajú do poradia");
  });

  it("zrušenie upozornenia nezapne nič a zatvorí ho", async () => {
    mount(false);
    fireEvent.click(await screen.findByRole("button", { name: "Zapnúť" }));
    fireEvent.click(await screen.findByRole("button", { name: "Zrušiť" }));
    await waitFor(() => expect(screen.queryByRole("group")).toBeNull());
    expect(mocks.rpc).not.toHaveBeenCalled();
    // Po opätovnom otvorení je súhlas znova nezačiarknutý.
    fireEvent.click(screen.getByRole("button", { name: "Zapnúť" }));
    const checkbox = (await screen.findByRole("checkbox")) as HTMLInputElement;
    expect(checkbox.checked).toBe(false);
  });

  it("upozornenie sa ukáže len pri jednom zamestnancovi naraz", async () => {
    mocks.tables["correction_auto_approvals"] = { data: [], error: null };
    mount(true);
    await screen.findByText("9000003");
    const buttons = screen.getAllByRole("button", { name: "Zapnúť" });
    expect(buttons).toHaveLength(2);
    fireEvent.click(buttons.at(0) as HTMLElement);
    fireEvent.click(screen.getAllByRole("button", { name: "Zapnúť" }).at(1) as HTMLElement);
    await waitFor(() => expect(screen.getAllByRole("group")).toHaveLength(1));
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
    mocks.tables["correction_auto_approvals"] = {
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
    fireEvent.click(await screen.findByRole("checkbox"));
    fireEvent.click(screen.getByRole("button", { name: "Zapnúť automatické schvaľovanie" }));
    expect((await screen.findByRole("alert")).textContent).toContain("Nemáte oprávnenie");
    // Pri chybe ostáva upozornenie otvorené, vedúci to môže skúsiť znova alebo zrušiť.
    expect(screen.getByRole("group")).toBeTruthy();
  });

  it("databáza bez migrácie 0013: karta sa neukáže vôbec", async () => {
    mocks.tables["correction_auto_approvals"] = {
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
    mocks.tables["correction_auto_approvals"] = {
      data: null,
      error: { message: "Failed to fetch" },
    };
    mount(false);
    expect(await screen.findByText(/Nepodarilo sa načítať/)).toBeTruthy();
  });
});
