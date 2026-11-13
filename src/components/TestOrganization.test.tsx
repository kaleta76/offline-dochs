import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ rpc: vi.fn(), signOut: vi.fn(), navigate: vi.fn() }));
vi.mock("@/integrations/supabase/client", () => ({
  supabase: { rpc: mocks.rpc, auth: { signOut: mocks.signOut } },
}));
vi.mock("@/lib/auth", () => ({
  useAuth: () => ({
    organization: { id: "o1", name: "Testovacia firma" },
    session: { user: { id: "u1" } },
  }),
}));
vi.mock("@tanstack/react-router", () => ({ useNavigate: () => mocks.navigate }));
import { TestOrganization } from "./TestOrganization";

const summary = {
  name: "Testovacia firma",
  is_test: true,
  protected: false,
  users: 3,
  punches: 12,
  devices: 2,
};

function open() {
  render(
    <QueryClientProvider client={new QueryClient()}>
      <TestOrganization />
    </QueryClientProvider>,
  );
}
const typeName = () =>
  fireEvent.change(screen.getByLabelText(/Na potvrdenie napíšte názov/), {
    target: { value: "Testovacia firma" },
  });
const noticeInput = () => screen.getByLabelText("Správa pre zariadenia (nepovinné)");
const submit = () => screen.getByRole("button", { name: "Zrušiť organizáciu natrvalo" });

beforeEach(() => {
  for (const m of [mocks.rpc, mocks.signOut, mocks.navigate]) m.mockReset();
  mocks.signOut.mockResolvedValue({ error: null });
  vi.stubGlobal("alert", vi.fn());
  mocks.rpc.mockImplementation(async (fn: string) => {
    if (fn === "test_organization_summary") return { data: summary, error: null };
    if (fn === "delete_test_organization")
      return { data: { users: 3, punches: 12, devices: 2 }, error: null };
    return { data: null, error: { message: "neočakávané volanie " + fn } };
  });
});

describe("zrušenie testovacej organizácie so správou pre zariadenia (migrácia 0020)", () => {
  it("bez správy sa volá ako doteraz: len _confirm_name (funguje aj v databáze bez 0020)", async () => {
    open();
    await screen.findByText(/je označená ako testovacia/);
    typeName();
    fireEvent.click(submit());
    await waitFor(() => expect(mocks.navigate).toHaveBeenCalled());
    const call = mocks.rpc.mock.calls.find((c) => c[0] === "delete_test_organization")!;
    expect(call[1]).toEqual({ _confirm_name: "Testovacia firma" });
  });

  it("so správou sa pošle orezaná správa ako _message", async () => {
    open();
    await screen.findByText(/je označená ako testovacia/);
    typeName();
    fireEvent.change(noticeInput(), {
      target: { value: "  Testovanie sa po upozornení SOC ukončilo.  " },
    });
    fireEvent.click(submit());
    await waitFor(() => expect(mocks.navigate).toHaveBeenCalled());
    const call = mocks.rpc.mock.calls.find((c) => c[0] === "delete_test_organization")!;
    expect(call[1]).toEqual({
      _confirm_name: "Testovacia firma",
      _message: "Testovanie sa po upozornení SOC ukončilo.",
    });
    expect(mocks.signOut).toHaveBeenCalledWith({ scope: "local" });
  });

  it("neplatná správa (skrytý znak) vypne tlačidlo a ukáže dôvod; na server sa nič neposiela", async () => {
    open();
    await screen.findByText(/je označená ako testovacia/);
    typeName();
    expect((submit() as HTMLButtonElement).disabled).toBe(false);
    fireEvent.change(noticeInput(), { target: { value: "skrytý\u200bznak" } });
    expect((submit() as HTMLButtonElement).disabled).toBe(true);
    expect(document.body.textContent).toContain("jeden riadok");
    fireEvent.submit(submit().closest("form")!);
    expect(mocks.rpc.mock.calls.some((c) => c[0] === "delete_test_organization")).toBe(false);
  });

  it("databáza bez migrácie 0020 so správou: zrozumiteľný text s migráciou, organizácia sa nezruší", async () => {
    mocks.rpc.mockImplementation(async (fn: string) => {
      if (fn === "test_organization_summary") return { data: summary, error: null };
      return {
        data: null,
        error: {
          message:
            "Could not find the function public.delete_test_organization(_confirm_name, _message) in the schema cache",
        },
      };
    });
    open();
    await screen.findByText(/je označená ako testovacia/);
    typeName();
    fireEvent.change(noticeInput(), { target: { value: "Ahoj" } });
    fireEvent.click(submit());
    expect((await screen.findByRole("alert")).textContent).toContain("0020");
    expect(mocks.navigate).not.toHaveBeenCalled();
    expect(mocks.signOut).not.toHaveBeenCalled();
  });

  it("bez správy sa chyba databázy ukáže nezmenená", async () => {
    mocks.rpc.mockImplementation(async (fn: string) => {
      if (fn === "test_organization_summary") return { data: summary, error: null };
      return { data: null, error: { message: "Organizácia sa práve prenáša" } };
    });
    open();
    await screen.findByText(/je označená ako testovacia/);
    typeName();
    fireEvent.click(submit());
    expect((await screen.findByRole("alert")).textContent).toContain(
      "Organizácia sa práve prenáša",
    );
  });

  it("textové pole správy má limit 300 znakov a upozornenie, že správu vidí každý (bez osobných údajov)", async () => {
    open();
    await screen.findByText(/je označená ako testovacia/);
    expect((noticeInput() as HTMLInputElement).maxLength).toBe(300);
    expect(document.body.textContent).toContain("nepíšte osobné údaje");
  });
});
