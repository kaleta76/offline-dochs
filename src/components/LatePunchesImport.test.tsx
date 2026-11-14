import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ read: vi.fn(), send: vi.fn() }));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc: vi.fn() } }));
vi.mock("@/lib/late-punches", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/late-punches")>()),
  readLateFile: mocks.read,
  importLatePunches: mocks.send,
}));
import { LatePunchesImport } from "./LatePunchesImport";
import type { LateFile, LateReport } from "@/lib/late-punches";

const FILE: LateFile = {
  createdAt: "2026-11-13T06:00:00.000Z",
  origin: "https://stary.example.test",
  fingerprint: "f".repeat(64),
  accounts: 2,
  from: "2026-11-12T06:00:00.000Z",
  to: "2026-11-12T14:00:00.000Z",
  punches: [
    {
      client_uuid: "00000000-0000-4000-8000-000000000001",
      user_id: "11111111-1111-4111-8111-111111111111",
      code: "WORK",
      direction: "IN",
      client_time: "2026-11-12T06:00:00.000Z",
      device: "d",
    },
  ],
};
const report = (over: Partial<LateReport>): LateReport => ({
  dryRun: true,
  total: 4,
  acceptable: 3,
  inserted: 0,
  already: 0,
  rejected: 1,
  accounts: 2,
  byAccount: null,
  reasons: [{ reason: "closed_month", text: "mesiac je uzavretý", count: 1 }],
  items: [
    {
      n: 2,
      reason: "closed_month",
      text: "mesiac je uzavretý",
      clientTime: "2026-09-15T08:00:00.000Z",
      code: "WORK",
      direction: "IN",
      message: null,
    },
  ],
  ...over,
});

function open() {
  render(
    <QueryClientProvider client={new QueryClient()}>
      <LatePunchesImport />
    </QueryClientProvider>,
  );
  fireEvent.change(screen.getByLabelText("Súbor s razeniami zo zariadenia"), {
    target: { files: [new File(["x"], "razenia-zo-zariadenia-20261113-0705-4.dochs-enc")] },
  });
  fireEvent.change(screen.getByLabelText("Heslo súboru s razeniami"), {
    target: { value: "správne-heslo-12345" },
  });
}

beforeEach(() => {
  mocks.read.mockReset();
  mocks.send.mockReset();
});

describe("Neskoré razenia zo zariadenia (karta v Servise)", () => {
  it("najprv len kontrola; zapíše sa až po stlačení a len to, čo server označil za prijateľné", async () => {
    mocks.read.mockResolvedValue(FILE);
    mocks.send
      .mockResolvedValueOnce(report({}))
      .mockResolvedValueOnce(report({ dryRun: false, inserted: 3 }));
    open();
    fireEvent.click(screen.getByRole("button", { name: "Skontrolovať súbor" }));
    const write = await screen.findByRole("button", { name: "Zapísať 3 razení" });
    expect(mocks.send).toHaveBeenCalledTimes(1);
    expect(mocks.send.mock.calls[0]![2]).toBe(true);
    expect(screen.getByText(/zapísať sa dá/).textContent).toContain("3 z 4 razení");
    expect(screen.getAllByRole("list")[0]!.textContent).toContain("mesiac je uzavretý: 1");
    expect((screen.getByLabelText("Heslo súboru s razeniami") as HTMLInputElement).value).toBe("");
    fireEvent.click(write);
    await waitFor(() => expect(mocks.send).toHaveBeenCalledTimes(2));
    expect(mocks.send.mock.calls[1]![1]).toBe(FILE);
    expect(mocks.send.mock.calls[1]![2]).toBe(false);
    expect((await screen.findByText("Hotovo.")).parentElement?.textContent).toContain(
      "Zapísaných 3 z 4 razení",
    );
    expect(screen.queryByRole("button", { name: /Zapísať/ })).toBeNull();
  });

  it("zlé heslo alebo cudzí súbor: chyba, na server sa nič neposiela", async () => {
    mocks.read.mockRejectedValue(
      new Error("Súbor sa nepodarilo dešifrovať: nesprávne heslo alebo poškodený súbor."),
    );
    open();
    fireEvent.click(screen.getByRole("button", { name: "Skontrolovať súbor" }));
    expect((await screen.findByRole("alert")).textContent).toContain("nesprávne heslo");
    expect(mocks.send).not.toHaveBeenCalled();
    expect(screen.queryByRole("button", { name: /Zapísať/ })).toBeNull();
  });

  it("keď sa nedá zapísať nič, tlačidlo zápisu je vypnuté; Zahodiť všetko vráti", async () => {
    mocks.read.mockResolvedValue(FILE);
    mocks.send.mockResolvedValue(report({ acceptable: 0, already: 3 }));
    open();
    fireEvent.click(screen.getByRole("button", { name: "Skontrolovať súbor" }));
    const write = (await screen.findByRole("button", {
      name: "Zapísať 0 razení",
    })) as HTMLButtonElement;
    expect(write.disabled).toBe(true);
    expect(screen.getByText(/už na serveri je/)).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Zahodiť" }));
    expect(screen.queryByRole("button", { name: /Zapísať/ })).toBeNull();
  });

  it("rozpis po účtoch ukáže osobné čísla a pri viac než jednom účte upozorní", async () => {
    mocks.read.mockResolvedValue(FILE);
    mocks.send.mockResolvedValue(
      report({
        byAccount: [
          {
            sapId: "1001",
            count: 2,
            from: "2026-11-12T06:00:00.000Z",
            to: "2026-11-12T14:00:00.000Z",
          },
          { sapId: null, count: 1, from: null, to: null },
        ],
      }),
    );
    open();
    fireEvent.click(screen.getByRole("button", { name: "Skontrolovať súbor" }));
    await screen.findByRole("button", { name: "Zapísať 3 razení" });
    const text = document.body.textContent ?? "";
    expect(text).toContain("Razenia po účtoch (osobné číslo)");
    expect(text).toContain("1001: 2 razenia");
    expect(text).toContain("bez osobného čísla: 1 razenie");
    const warning = screen
      .getAllByRole("alert")
      .map((a) => a.textContent ?? "")
      .find((t) => t.includes("zvyčajne patrí jednému človeku"));
    expect(warning).toContain("tu je účtov 2");
  });

  it("jeden účet: rozpis je, upozornenie nie; starý server bez rozpisu nič nehlási", async () => {
    mocks.read.mockResolvedValue(FILE);
    mocks.send.mockResolvedValueOnce(
      report({ byAccount: [{ sapId: "1001", count: 3, from: null, to: null }] }),
    );
    open();
    fireEvent.click(screen.getByRole("button", { name: "Skontrolovať súbor" }));
    await screen.findByRole("button", { name: "Zapísať 3 razení" });
    expect(document.body.textContent).toContain("1001: 3 razenia");
    expect(document.body.textContent).not.toContain("zvyčajne patrí jednému človeku");
  });

  it("server bez migrácie 0020 (bez by_account): karta funguje ako predtým", async () => {
    mocks.read.mockResolvedValue(FILE);
    mocks.send.mockResolvedValueOnce(report({ byAccount: null }));
    open();
    fireEvent.click(screen.getByRole("button", { name: "Skontrolovať súbor" }));
    await screen.findByRole("button", { name: "Zapísať 3 razení" });
    expect(document.body.textContent).not.toContain("Razenia po účtoch");
  });

  it("chyba pri zápise povie, ako zistiť, či sa razenia zapísali", async () => {
    mocks.read.mockResolvedValue(FILE);
    mocks.send
      .mockResolvedValueOnce(report({}))
      .mockRejectedValueOnce(new Error("Spojenie so serverom zlyhalo."));
    open();
    fireEvent.click(screen.getByRole("button", { name: "Skontrolovať súbor" }));
    fireEvent.click(await screen.findByRole("button", { name: "Zapísať 3 razení" }));
    expect((await screen.findByRole("alert")).textContent).toContain(
      "opakovanou kontrolou toho istého súboru",
    );
    // súbor ostáva pripravený na ďalší pokus
    expect(screen.getByRole("button", { name: "Zapísať 3 razení" })).toBeTruthy();
  });
});
