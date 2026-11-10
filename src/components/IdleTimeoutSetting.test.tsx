import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  rpc: vi.fn(),
  refetchMe: vi.fn(),
  organization: { current: null as null | { id: string; name: string; idle_timeout_hours?: number } },
}));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc: mocks.rpc } }));
vi.mock("@/lib/auth", () => ({
  useAuth: () => ({ organization: mocks.organization.current, refetchMe: mocks.refetchMe }),
}));

import { IdleTimeoutSetting } from "./IdleTimeoutSetting";

const select = () => screen.getByLabelText("Doba nečinnosti do odhlásenia") as HTMLSelectElement;

describe("IdleTimeoutSetting (limit nečinnosti organizácie)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    localStorage.clear();
    mocks.rpc.mockResolvedValue({ error: null });
    mocks.organization.current = { id: "o1", name: "Firma", idle_timeout_hours: 12 };
  });

  it("ukáže aktuálnu hodnotu organizácie a ponúkne všetky povolené hodnoty", () => {
    mocks.organization.current = { id: "o1", name: "Firma", idle_timeout_hours: 24 };
    render(<IdleTimeoutSetting />);
    expect(select().value).toBe("24");
    expect(select().disabled).toBe(false);
    expect(Array.from(select().options).map((o) => o.value)).toEqual(["0.5", "1", "2", "4", "8", "12", "24", "48", "72"]);
  });

  it("zmena zavolá funkciu v databáze, uloží kópiu do zariadenia a obnoví údaje účtu", async () => {
    render(<IdleTimeoutSetting />);
    fireEvent.change(select(), { target: { value: "4" } });
    await waitFor(() => expect(mocks.rpc).toHaveBeenCalledWith("set_idle_timeout", { _hours: 4 }));
    await waitFor(() => expect(mocks.refetchMe).toHaveBeenCalled());
    expect(localStorage.getItem("idle_limit_hours")).toBe("4");
    expect(screen.getByRole("status").textContent).toContain("Uložené.");
  });

  it("pri chybe nič neuloží do zariadenia a ukáže hlásenie", async () => {
    mocks.rpc.mockResolvedValue({ error: { message: "Nemáte oprávnenie" } });
    render(<IdleTimeoutSetting />);
    fireEvent.change(select(), { target: { value: "2" } });
    await waitFor(() => expect(screen.getByRole("status").textContent).toContain("Limit sa nepodarilo uložiť"));
    expect(localStorage.getItem("idle_limit_hours")).toBeNull();
    expect(mocks.refetchMe).not.toHaveBeenCalled();
  });

  it("bez hodnoty z databázy (stará databáza) je výber vypnutý a text to vysvetlí", () => {
    mocks.organization.current = { id: "o1", name: "Firma" };
    render(<IdleTimeoutSetting />);
    expect(select().disabled).toBe(true);
    expect(select().value).toBe("12");
    expect(screen.getByRole("status").textContent).toContain("po aktualizácii databázy");
  });
});
