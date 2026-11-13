import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ rpc: vi.fn(), origin: "terminal" as "terminal" | "access" }));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc: mocks.rpc } }));

import { SettingsVersions } from "./SettingsVersions";
import {
  forMonthResponse,
  ID_ACCESS,
  terminalConfig,
  timelineResponse,
} from "@/lib/__fixtures__/settings-fixtures";

function mount() {
  return render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <SettingsVersions organizationId="org1" />
    </QueryClientProvider>,
  );
}

describe("Správa: verzie nastavení výpočtu", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.origin = "terminal";
    mocks.rpc.mockImplementation((fn: string) => {
      if (fn === "settings_for_month")
        return Promise.resolve({ data: forMonthResponse(mocks.origin), error: null });
      if (fn === "settings_timeline")
        return Promise.resolve({ data: timelineResponse(mocks.origin), error: null });
      if (fn === "settings_version_config")
        return Promise.resolve({ data: { config: terminalConfig() }, error: null });
      return Promise.resolve({ data: null, error: null });
    });
  });

  it("mesiac patrí terminálu: pravidlá sa dajú upraviť a uloženie je nová verzia od zvoleného mesiaca", async () => {
    mount();
    await screen.findByText(/patrí terminálu/);
    expect(screen.queryByRole("button", { name: /Odpárovať/ })).toBeNull();
    const save = screen.getByRole("button", { name: "Uložiť pravidlá" });
    expect(save).toBeDisabled();
    fireEvent.change(screen.getByLabelText(/Zaokrúhlenie prvého príchodu/), {
      target: { value: "5" },
    });
    fireEvent.change(screen.getByLabelText("Platí od"), { target: { value: "2026-10" } });
    fireEvent.click(save);
    await waitFor(() =>
      expect(mocks.rpc.mock.calls.some((c) => c[0] === "settings_terminal_save")).toBe(true),
    );
    const call = mocks.rpc.mock.calls.find((c) => c[0] === "settings_terminal_save")!;
    expect(call[1]._valid_from).toBe("2026-10-01");
    expect(call[1]._config.rules.rounding_in_min).toBe(5);
    // celý model ide ďalej, úprava jedného pravidla nič nezahodí
    expect(call[1]._config.interruptions.length).toBe(
      (terminalConfig()["interruptions"] as unknown[]).length,
    );
    expect(await screen.findByRole("status")).toHaveTextContent("Platí od 10/2026");
  });

  it("hodnota mimo rozsahu sa neodošle", async () => {
    mount();
    await screen.findByText(/patrí terminálu/);
    fireEvent.change(screen.getByLabelText(/Zaokrúhlenie prvého príchodu/), {
      target: { value: "99" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Uložiť pravidlá" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("0 až 60");
    expect(mocks.rpc.mock.calls.some((c) => c[0] === "settings_terminal_save")).toBe(false);
  });

  it("mesiac patrí Accessu: len na čítanie, s verziou a dátumom importu, bez ukladania a úpravy sviatkov", async () => {
    mocks.origin = "access";
    mount();
    await screen.findByText(/patrí Accessu/);
    expect(screen.getAllByText(/Access, verzia 2026\.11\.04\.1200, import/).length).toBeGreaterThan(
      0,
    );
    for (const input of screen.getAllByRole("textbox")) expect(input).toHaveAttribute("readonly");
    expect(screen.queryByRole("button", { name: "Uložiť pravidlá" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Pridať" })).toBeNull();
    expect(screen.queryByRole("button", { name: "odstrániť" })).toBeNull();
    expect(screen.getByRole("button", { name: "Odpárovať od Accessu…" })).toBeInTheDocument();
  });

  it("odpárovanie: ukáže rozdiel, bez zaškrtnutia sa nedá potvrdiť, predvolená je kópia z Accessu", async () => {
    mocks.origin = "access";
    mount();
    fireEvent.click(await screen.findByRole("button", { name: "Odpárovať od Accessu…" }));
    await waitFor(() =>
      expect(
        mocks.rpc.mock.calls.some(
          (c) => c[0] === "settings_version_config" && c[1]._id === ID_ACCESS,
        ),
      ).toBe(true),
    );
    // mock vracia pre každú verziu terminálový model, takže oproti platnej verzii z Accessu je rozdiel
    await waitFor(() =>
      expect(screen.getAllByRole("listitem").some((li) => li.textContent?.includes("→"))).toBe(
        true,
      ),
    );
    const go = screen.getByRole("button", { name: "Odpárovať" });
    expect(go).toBeDisabled();
    fireEvent.click(screen.getByRole("checkbox"));
    expect(go).toBeEnabled();
    fireEvent.click(go);
    await waitFor(() =>
      expect(mocks.rpc.mock.calls.some((c) => c[0] === "settings_unpair")).toBe(true),
    );
    expect(mocks.rpc.mock.calls.find((c) => c[0] === "settings_unpair")![1]).toEqual({
      _valid_from: "2026-11-01",
      _choice: "access",
      _confirm: true,
    });
  });

  it("odmietnutie databázou sa ukáže a nič sa netvári ako uložené", async () => {
    mount();
    await screen.findByText(/patrí terminálu/);
    mocks.rpc.mockImplementation((fn: string) =>
      Promise.resolve(
        fn === "settings_terminal_save"
          ? { data: null, error: { message: "Mesiac 11/2026 patrí Accessu" } }
          : { data: null, error: null },
      ),
    );
    fireEvent.change(screen.getByLabelText(/Odpočet prestávky/), { target: { value: "45" } });
    fireEvent.click(screen.getByRole("button", { name: "Uložiť pravidlá" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("patrí Accessu");
  });
});
