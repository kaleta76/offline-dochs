import "fake-indexeddb/auto";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  rpc: vi.fn(),
  getSession: vi.fn(),
  signOut: vi.fn(),
}));
vi.mock("@/integrations/supabase/client", () => ({
  supabase: { rpc: mocks.rpc, auth: { getSession: mocks.getSession, signOut: mocks.signOut } },
}));
import { ServerMoveNotice } from "./ServerMoveNotice";
import { enqueue, listAllQueued, removeQueued } from "@/lib/offline-queue";
import { resetMoveStateForTests } from "@/lib/server-move";

// Celý oznam so skutočnou frontou (IndexedDB v pamäti): zahodenie bez súboru sa týka len razení zrušenej organizácie.
const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";
const C = "33333333-3333-4333-8333-333333333333";
const MSG = "Testovanie sa po upozornení SOC ukončilo.";

function notice(users: Record<string, unknown>) {
  mocks.rpc.mockImplementation(async (fn: string) =>
    fn === "punch_move_notice"
      ? { data: { version: 1, users }, error: null }
      : { data: null, error: { message: "neočakávané volanie" } },
  );
}
const add = (user: string, n: number) =>
  Promise.all(
    Array.from({ length: n }, () => enqueue({ user_id: user, code: "WORK", direction: "IN" })),
  );

beforeEach(async () => {
  for (const m of [mocks.rpc, mocks.getSession, mocks.signOut]) m.mockReset();
  mocks.getSession.mockResolvedValue({ data: { session: null }, error: null });
  mocks.signOut.mockResolvedValue({ error: null });
  window.localStorage.clear();
  resetMoveStateForTests();
  await removeQueued((await listAllQueued()).map((p) => p.client_uuid));
});
afterEach(() => {
  resetMoveStateForTests();
});

describe("oznam so skutočnou frontou: zrušená organizácia (migrácia 0020)", () => {
  it("správa a nadpis sa ukážu; zahodenie bez súboru zmaže presne zobrazené razenia a upratanie sa dokončí", async () => {
    await add(B, 2);
    notice({ [B]: { state: "ended", url: null, message: MSG } });
    render(<ServerMoveNotice />);
    const alert = await screen.findByRole("alert");
    expect(alert.textContent).toContain("Organizácia bola zrušená");
    expect(alert.textContent).toContain(`Správa od správcu: ${MSG}`);
    fireEvent.click(screen.getByRole("checkbox"));
    fireEvent.click(screen.getByRole("button", { name: "Zahodiť 2 razení a upratať" }));
    fireEvent.click(screen.getByRole("button", { name: "Áno, zahodiť" }));
    expect(await screen.findByText("Zariadenie je upratané.")).toBeTruthy();
    expect(await listAllQueued()).toEqual([]);
    expect(document.body.textContent).toContain(`Správa od správcu: ${MSG}`);
  });

  it("zahodenie sa dotkne len razení zrušenej organizácie; cudzie razenie na zariadení ostane", async () => {
    await add(B, 2);
    const [other] = await add(C, 1);
    notice({ [B]: { state: "ended", url: null, message: null } });
    render(<ServerMoveNotice />);
    await screen.findByText("Organizácia bola zrušená");
    fireEvent.click(screen.getByRole("checkbox"));
    fireEvent.click(screen.getByRole("button", { name: "Zahodiť 2 razení a upratať" }));
    fireEvent.click(screen.getByRole("button", { name: "Áno, zahodiť" }));
    expect(await screen.findByText(/V zariadení ostalo 1 razení/)).toBeTruthy();
    const left = await listAllQueued();
    expect(left.map((p) => p.client_uuid)).toEqual([other!.client_uuid]);
  });

  it("presťahovaná organizácia má prednosť a zahodenie bez súboru sa pri nej neponúka; zrušená čaká", async () => {
    await add(A, 1);
    await add(B, 2);
    notice({
      [A]: { state: "moved", url: "https://novy.example.test", message: null },
      [B]: { state: "ended", url: null, message: null },
    });
    render(<ServerMoveNotice />);
    const alert = await screen.findByText(/Server bol presťahovaný/, { selector: "p" });
    expect(alert).toBeTruthy();
    expect(screen.getByRole("alert").textContent).toContain("ostalo 1 razenie");
    expect(screen.queryByRole("button", { name: /Zahodiť/ })).toBeNull();
    await waitFor(() => expect(mocks.rpc).toHaveBeenCalled());
    expect((await listAllQueued()).length).toBe(3);
  });

  it("server bez správy a bez stavu ended (len 0019): okno sa správa ako predtým", async () => {
    await add(A, 1);
    notice({ [A]: { state: "moved", url: "https://novy.example.test" } });
    render(<ServerMoveNotice />);
    expect((await screen.findByRole("alert")).textContent).toContain("Server bol presťahovaný");
    expect(screen.getByRole("alert").textContent).not.toContain("Správa od správcu");
  });
});
