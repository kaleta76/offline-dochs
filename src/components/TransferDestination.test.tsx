import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc: mocks.rpc } }));
import { TransferDestination } from "./TransferDestination";

const TID = "7b0f7f4e-3d1c-4a69-9f0e-0a1b2c3d4e5f";
const server = (saved: { url: string | null; message?: string | null }) => {
  let state = { ...saved };
  mocks.rpc.mockImplementation(async (fn: string, args: Record<string, string>) => {
    if (fn === "org_transfer_get_destination")
      return { data: { transfer_id: TID, ...state }, error: null };
    if (fn === "org_transfer_set_notice") {
      state = { url: args["_url"] || null, message: args["_message"] || null };
      return { data: { transfer_id: TID, ...state }, error: null };
    }
    if (fn === "org_transfer_set_destination") {
      state = { ...state, url: args["_url"] || null };
      return { data: { transfer_id: TID, url: state.url }, error: null };
    }
    return { data: null, error: { message: "neočakávané volanie " + fn } };
  });
};
function open(onDirtyChange?: (d: boolean) => void) {
  render(
    <QueryClientProvider client={new QueryClient()}>
      <TransferDestination transferId={TID} onDirtyChange={onDirtyChange} />
    </QueryClientProvider>,
  );
}
const urlInput = () => screen.getByLabelText(/Nová adresa aplikácie/) as HTMLInputElement;
const msgInput = () => screen.getByLabelText(/Správa pre zariadenia/) as HTMLInputElement;
// Polia sú zamknuté, kým sa nenačítajú uložené hodnoty.
const loaded = () => waitFor(() => expect(urlInput().disabled).toBe(false));

beforeEach(() => mocks.rpc.mockReset());

describe("nová adresa a správa pre zariadenia pri prenose (migrácia 0020)", () => {
  it("server s 0020: pole so správou je, tlačidlo je vypnuté, kým nie je zmena; uloží adresu aj správu naraz", async () => {
    server({ url: null, message: null });
    const dirty = vi.fn();
    open(dirty);
    const save = (await screen.findByRole("button", {
      name: "Uložiť adresu a správu",
    })) as HTMLButtonElement;
    await loaded();
    expect(save.disabled).toBe(true);
    fireEvent.change(urlInput(), { target: { value: "https://offline-dochs.lovable.app/" } });
    fireEvent.change(msgInput(), { target: { value: "Presťahovali sme sa." } });
    expect(save.disabled).toBe(false);
    expect(screen.getByText("Zmeny ešte nie sú uložené.")).toBeTruthy();
    await waitFor(() => expect(dirty).toHaveBeenLastCalledWith(true));
    fireEvent.click(save);
    expect(await screen.findByText("Adresa a správa sú uložené.")).toBeTruthy();
    expect(mocks.rpc).toHaveBeenCalledWith("org_transfer_set_notice", {
      _url: "https://offline-dochs.lovable.app/",
      _message: "Presťahovali sme sa.",
    });
    await waitFor(() => expect(dirty).toHaveBeenLastCalledWith(false));
    expect(save.disabled).toBe(true);
  });

  it("uložená správa sa načíta; samotná zmena správy je zmena, ktorá sa dá uložiť", async () => {
    server({ url: "https://novy.example.test", message: "Stará správa" });
    open();
    await waitFor(() => expect(msgInput().value).toBe("Stará správa"));
    expect(urlInput().value).toBe("https://novy.example.test");
    const save = screen.getByRole("button", {
      name: "Uložiť adresu a správu",
    }) as HTMLButtonElement;
    expect(save.disabled).toBe(true);
    fireEvent.change(msgInput(), { target: { value: "Nová správa" } });
    expect(save.disabled).toBe(false);
    fireEvent.change(msgInput(), { target: { value: "Stará správa" } });
    expect(save.disabled).toBe(true);
  });

  it("neplatná správa alebo adresa vypne ukladanie a ukáže dôvod", async () => {
    server({ url: null, message: null });
    open();
    await screen.findByRole("button", { name: "Uložiť adresu a správu" });
    await loaded();
    // pole je jednoriadkové (prehliadač odstráni zalomenie), ostáva skrytý znak, ktorý databáza odmieta tiež
    fireEvent.change(msgInput(), { target: { value: "skrytý\u200bznak" } });
    expect(
      (screen.getByRole("button", { name: "Uložiť adresu a správu" }) as HTMLButtonElement)
        .disabled,
    ).toBe(true);
    expect(document.body.textContent).toContain("jeden riadok");
    fireEvent.change(msgInput(), { target: { value: "" } });
    fireEvent.change(urlInput(), { target: { value: "novy.example.test" } });
    expect(
      (screen.getByRole("button", { name: "Uložiť adresu a správu" }) as HTMLButtonElement)
        .disabled,
    ).toBe(true);
    expect(document.body.textContent).toContain("https://");
  });

  it("server len s migráciou 0019 (odpoveď bez poľa message): bez poľa pre správu, uloží sa len adresa starou funkciou", async () => {
    server({ url: null });
    open();
    const save = (await screen.findByRole("button", {
      name: "Uložiť adresu",
    })) as HTMLButtonElement;
    await loaded();
    expect(screen.queryByLabelText(/Správa pre zariadenia/)).toBeNull();
    fireEvent.change(urlInput(), { target: { value: "https://novy.example.test" } });
    fireEvent.click(save);
    expect(await screen.findByText("Adresa je uložená.")).toBeTruthy();
    expect(mocks.rpc).toHaveBeenCalledWith("org_transfer_set_destination", {
      _url: "https://novy.example.test",
    });
    expect(mocks.rpc.mock.calls.some((c) => c[0] === "org_transfer_set_notice")).toBe(false);
  });

  it("zmazanie oboch hodnôt ich zruší (prázdne polia sa pošlú ako prázdny text)", async () => {
    server({ url: "https://novy.example.test", message: "Správa" });
    open();
    await waitFor(() => expect(msgInput().value).toBe("Správa"));
    fireEvent.change(urlInput(), { target: { value: "" } });
    fireEvent.change(msgInput(), { target: { value: "" } });
    fireEvent.click(screen.getByRole("button", { name: "Uložiť adresu a správu" }));
    expect(await screen.findByText("Adresa a správa sú zmazané.")).toBeTruthy();
    expect(mocks.rpc).toHaveBeenCalledWith("org_transfer_set_notice", { _url: "", _message: "" });
  });

  it("uložená adresa s lomítkom na konci nie je „neuložená zmena“ (server ho odstráni, porovnáva sa po úprave)", async () => {
    server({ url: "https://novy.example.test/", message: null });
    open();
    await waitFor(() => expect(urlInput().value).toBe("https://novy.example.test/"));
    expect(
      (screen.getByRole("button", { name: "Uložiť adresu a správu" }) as HTMLButtonElement)
        .disabled,
    ).toBe(true);
    expect(screen.queryByText("Zmeny ešte nie sú uložené.")).toBeNull();
  });

  it("neúspešné načítanie uložených hodnôt: chyba je vidieť a ukladanie je vypnuté (neprepíše sa nič naslepo)", async () => {
    mocks.rpc.mockResolvedValue({ data: null, error: { message: "TypeError: Failed to fetch" } });
    open();
    expect((await screen.findByRole("alert", {}, { timeout: 5000 })).textContent).toContain(
      "nepodarilo načítať",
    );
    expect(
      (screen.getByRole("button", { name: "Uložiť adresu" }) as HTMLButtonElement).disabled,
    ).toBe(true);
  });

  it("server bez migrácie 0019 vôbec: karta sa neukáže", async () => {
    mocks.rpc.mockResolvedValue({ data: null, error: { code: "PGRST202", message: "x" } });
    const { container } = render(
      <QueryClientProvider client={new QueryClient()}>
        <TransferDestination transferId={TID} />
      </QueryClientProvider>,
    );
    await waitFor(() => expect(mocks.rpc).toHaveBeenCalled());
    await waitFor(() => expect(container.textContent).toBe(""));
  });
});
