import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

vi.mock("@/integrations/supabase/client", () => ({ supabase: {} }));
import { RejectedPunchNotice } from "./RejectedPunchNotice";

const punch = {
  client_uuid: "u1",
  user_id: "a",
  code: "WORK",
  direction: "IN" as const,
  client_time: "2026-11-02T06:00:00.000Z",
  device: "d",
  error: "Mesiac je uzavretý",
};

describe("RejectedPunchNotice (razenie, ktoré server natrvalo neprijal)", () => {
  it("ukáže druh razenia, dôvod odmietnutia a vysvetlí, že ďalšie razenia čakajú", () => {
    render(<RejectedPunchNotice punch={punch} onRetry={vi.fn()} onDiscard={vi.fn()} />);
    const alert = screen.getByRole("alert");
    expect(alert.textContent).toContain("Príchod");
    expect(alert.textContent).toContain("Mesiac je uzavretý");
    expect(alert.textContent).toContain("ďalšie razenia sa neodošlú");
  });

  it("Skúsiť znova zavolá jeden pokus a nič nezahodí", () => {
    const onRetry = vi.fn();
    const onDiscard = vi.fn();
    render(<RejectedPunchNotice punch={punch} onRetry={onRetry} onDiscard={onDiscard} />);
    fireEvent.click(screen.getByRole("button", { name: "Skúsiť znova" }));
    expect(onRetry).toHaveBeenCalledTimes(1);
    expect(onDiscard).not.toHaveBeenCalled();
  });

  it("zahodenie vyžaduje potvrdenie a bez neho sa nič nestane", () => {
    const onDiscard = vi.fn();
    render(<RejectedPunchNotice punch={punch} onRetry={vi.fn()} onDiscard={onDiscard} />);
    fireEvent.click(screen.getByRole("button", { name: "Zahodiť v zariadení" }));
    expect(onDiscard).not.toHaveBeenCalled();
    expect(screen.getByText(/Naozaj zahodiť toto razenie/)).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Nie, ponechať" }));
    expect(onDiscard).not.toHaveBeenCalled();
    expect(screen.queryByText(/Naozaj zahodiť toto razenie/)).toBeNull();
  });

  it("po potvrdení zahodí práve toto razenie", () => {
    const onDiscard = vi.fn();
    render(<RejectedPunchNotice punch={punch} onRetry={vi.fn()} onDiscard={onDiscard} />);
    fireEvent.click(screen.getByRole("button", { name: "Zahodiť v zariadení" }));
    fireEvent.click(screen.getByRole("button", { name: "Áno, zahodiť" }));
    expect(onDiscard).toHaveBeenCalledWith("u1");
  });
});
