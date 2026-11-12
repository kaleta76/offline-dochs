import { Blob as NodeBlob } from "node:buffer";
import { webcrypto } from "node:crypto";
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { decryptToText, encryptText } from "@/lib/org-transfer-crypto";

type Rpc = { data: unknown; error: { code?: string; message: string } | null };

const TID = "7b0f7f4e-3d1c-4a69-9f0e-0a1b2c3d4e5f";
const ORG = "11111111-2222-4333-8444-555555555555";
const PW = "správne-heslo-12345";

const mocks = vi.hoisted(() => ({
  rpc: vi.fn(),
  signOut: vi.fn(),
  navigate: vi.fn(),
  organization: { id: "o1", name: "Firma „Ľ“" },
}));
vi.mock("@/integrations/supabase/client", () => ({
  supabase: { rpc: mocks.rpc, auth: { signOut: mocks.signOut } },
}));
vi.mock("@/lib/auth", () => ({
  useAuth: () => ({
    organization: mocks.organization,
    session: { user: { id: "u1" } },
    refetchMe: vi.fn(),
  }),
}));
vi.mock("@tanstack/react-router", () => ({ useNavigate: () => mocks.navigate }));
// Skutočný export, len s menším počtom iterácií hesla, aby test netrval dlho.
vi.mock("@/lib/org-transfer", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/org-transfer")>();
  return {
    ...actual,
    exportOrganization: (
      client: Parameters<typeof actual.exportOrganization>[0],
      o: Parameters<typeof actual.exportOrganization>[1],
    ) => actual.exportOrganization(client, { ...o, encrypt: { iterations: 100_000 } }),
  };
});

import { OrganizationTransfer } from "./OrganizationTransfer";

beforeAll(() => {
  vi.stubGlobal("Blob", NodeBlob);
  vi.stubGlobal("crypto", webcrypto);
});

const ROWS: Record<string, string[]> = {
  "public.profiles": ['{"id": "u1", "daily_fund": 7.50}', '{"id": "u2", "daily_fund": 8.0}'],
  "public.punches": ['{"id": 1}', '{"id": 2}', '{"id": 3}'],
};
const meta = {
  format: 2,
  organization: { id: ORG, name: "Firma „Ľ“", code: "11111111", is_test: false },
  counts: { "public.profiles": 2, "public.punches": 3 },
};

interface Db {
  state: "none" | "ready" | "exported";
  isTest: boolean;
  locked: boolean;
  protectedOrg: boolean;
  changes: Record<string, { then: number; now: number }>;
  markedTest: boolean;
  deleted: boolean;
  failPage: boolean;
  receipt: string;
}
let db: Db;

const status = () => ({
  name: "Firma „Ľ“",
  is_test: db.isTest,
  protected: db.protectedOrg,
  state: db.state,
  transfer_id: db.state === "none" ? null : TID,
  locked: db.locked && db.state !== "none",
  lock_active: db.locked && db.state !== "none",
  started_at: null,
  exported_at: null,
  marked_test: db.markedTest,
  has_changes: Object.keys(db.changes).length > 0,
  changes: db.changes,
});

function handle(fn: string, args: Record<string, unknown> | undefined): Rpc {
  const ok = (data: unknown): Rpc => ({ data, error: null });
  switch (fn) {
    case "org_transfer_status":
      return ok(status());
    case "org_export_begin":
      db.state = "ready";
      db.locked = args?.["_lock"] === true;
      return ok({
        transfer_id: TID,
        locked: db.locked,
        meta,
        tables: Object.entries(ROWS).map(([rel, r]) => ({ rel, n: r.length })),
        page_size: 2000,
      });
    case "org_export_page": {
      if (db.failPage) return { data: null, error: { message: "chyba databázy pri čítaní" } };
      const rel = String(args?.["_rel"]);
      const offset = Number(args?.["_offset"]);
      const slice = (ROWS[rel] ?? []).slice(offset, offset + Number(args?.["_limit"]));
      return ok({ rel, offset, count: slice.length, rows: `[${slice.join(", ")}]` });
    }
    case "org_export_finish":
      db.state = "exported";
      if (!db.protectedOrg) {
        db.isTest = true;
        db.markedTest = true;
      }
      return ok({
        state: "exported",
        transfer_id: TID,
        locked: db.locked,
        is_test: db.isTest,
        protected: db.protectedOrg,
      });
    case "org_transfer_cancel": {
      const had = db.state !== "none";
      const reverted = db.markedTest;
      const unlocked = db.locked;
      db.state = "none";
      db.locked = false;
      if (db.markedTest) db.isTest = false;
      db.markedTest = false;
      return ok(
        had
          ? { state: "cancelled", transfer_id: TID, unlocked, test_flag_reverted: reverted }
          : { state: "none" },
      );
    }
    case "org_transfer_confirm_and_delete": {
      if (String(args?.["_receipt"]) !== db.receipt)
        return { data: null, error: { message: "Kód potvrdenia prenosu nesedí." } };
      if (Object.keys(db.changes).length > 0 && args?.["_accept_changes"] !== true)
        return {
          data: null,
          error: { message: "Od exportu sa údaje zmenili (tabuľky: public.punches)." },
        };
      db.deleted = true;
      return ok({
        users: 2,
        punches: 3,
        devices: 1,
        transfer_id: TID,
        changes_accepted: args?.["_accept_changes"] === true,
      });
    }
    case "test_organization_summary":
      return ok({
        name: "Firma „Ľ“",
        is_test: db.isTest,
        protected: db.protectedOrg,
        users: 2,
        punches: 3,
        devices: 1,
      });
    default:
      return { data: null, error: { message: `neznáma funkcia ${fn}` } };
  }
}

const downloads: { name: string; blob: Blob }[] = [];

function mount() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <OrganizationTransfer />
    </QueryClientProvider>,
  );
}

const pass = () => screen.getByLabelText(/^Heslo súboru \(aspoň/) as HTMLInputElement;
const repeat = () => screen.getByLabelText("Heslo ešte raz") as HTMLInputElement;

async function fillAndExport(password = PW, again = PW) {
  fireEvent.change(await screen.findByLabelText(/^Heslo súboru \(aspoň/), {
    target: { value: password },
  });
  fireEvent.change(repeat(), { target: { value: again } });
  fireEvent.click(screen.getByRole("button", { name: "Vyexportovať organizáciu" }));
}

describe("OrganizationTransfer (prenos organizácie)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    localStorage.clear();
    downloads.length = 0;
    db = {
      state: "none",
      isTest: false,
      locked: false,
      protectedOrg: false,
      changes: {},
      markedTest: false,
      deleted: false,
      failPage: false,
      receipt: "ABCD-1234",
    };
    mocks.rpc.mockImplementation(async (fn: string, args?: Record<string, unknown>) =>
      handle(fn, args),
    );
    mocks.signOut.mockResolvedValue({ error: null });
    let lastBlob: Blob | null = null;
    URL.createObjectURL = vi.fn((b: Blob) => {
      lastBlob = b;
      return "blob:test";
    });
    URL.revokeObjectURL = vi.fn();
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(function (
      this: HTMLAnchorElement,
    ) {
      if (lastBlob) downloads.push({ name: this.download, blob: lastBlob });
    });
    vi.spyOn(window, "alert").mockImplementation(() => undefined);
  });
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("bez migrácie 0016 ukáže, čo treba spustiť, a nič nenavrhuje", async () => {
    mocks.rpc.mockResolvedValue({
      data: null,
      error: {
        code: "PGRST202",
        message: "Could not find the function public.org_transfer_status in the schema cache",
      },
    });
    mount();
    expect((await screen.findByRole("alert")).textContent).toContain("migráciu 0016");
    expect(screen.queryByRole("button", { name: "Vyexportovať organizáciu" })).toBeNull();
  });

  it("ukáže formulár exportu so zamknutím razení predvybraným a odmietne krátke a rôzne heslá", async () => {
    mount();
    await screen.findByRole("button", { name: "Vyexportovať organizáciu" });
    expect((screen.getByLabelText(/Zamknúť razenia/) as HTMLInputElement).checked).toBe(true);
    await fillAndExport("krátke", "krátke");
    expect((await screen.findByRole("alert")).textContent).toContain("aspoň 12 znakov");
    fireEvent.change(pass(), { target: { value: PW } });
    fireEvent.change(repeat(), { target: { value: PW + "x" } });
    fireEvent.click(screen.getByRole("button", { name: "Vyexportovať organizáciu" }));
    await waitFor(() =>
      expect(screen.getByRole("alert").textContent).toContain("Heslá sa nezhodujú"),
    );
    expect(mocks.rpc.mock.calls.some(([fn]) => fn === "org_export_begin")).toBe(false);
  });

  it("export vytvorí šifrovaný súbor s nezmenenými riadkami, stiahne ho a skontroluje; heslo zmizne z formulára", async () => {
    mount();
    await fillAndExport();
    expect(await screen.findByText(/Export organizácie „Firma „Ľ““ je hotový/)).toBeTruthy();
    const begin = mocks.rpc.mock.calls.find(([fn]) => fn === "org_export_begin");
    expect(begin?.[1]).toEqual({ _lock: true });
    const finish = mocks.rpc.mock.calls.find(([fn]) => fn === "org_export_finish");
    expect(finish?.[1]).toEqual({
      _transfer: TID,
      _received: { "public.profiles": 2, "public.punches": 3 },
    });

    expect(downloads).toHaveLength(1);
    expect(downloads[0]?.name).toMatch(/^prenos-11111111-\d{8}-\d{4}\.dochs-enc$/);
    const text = await decryptToText(downloads[0]!.blob, PW);
    expect(text).toContain('"daily_fund": 7.50');
    expect(text).toContain('"daily_fund": 8.0}');
    await screen.findByText(/Súbor je skontrolovaný/);
    expect(screen.getAllByText(/5 riadkov/)).toHaveLength(2);
    expect(screen.getByText(/označená ako testovacia/)).toBeTruthy();
    expect(screen.queryByLabelText(/^Heslo súboru \(aspoň/)).toBeNull();
    expect(screen.getByRole("button", { name: "Stiahnuť súbor znova" })).toBeTruthy();
  });

  it("zamknutie razení sa dá vypnúť", async () => {
    mount();
    fireEvent.click(await screen.findByLabelText(/Zamknúť razenia/));
    await fillAndExport();
    await screen.findByText(/je hotový/);
    expect(mocks.rpc.mock.calls.find(([fn]) => fn === "org_export_begin")?.[1]).toEqual({
      _lock: false,
    });
  });

  it("po chybe pri čítaní údajov sa prenos sám zruší, razenia sa odomknú a správca dostane vysvetlenie", async () => {
    db.failPage = true;
    mount();
    await fillAndExport();
    await waitFor(() =>
      expect(screen.getByRole("alert").textContent).toContain("chyba databázy pri čítaní"),
    );
    expect(screen.getByRole("alert").textContent).toContain(
      "Prenos bol zrušený a razenia sú odomknuté",
    );
    expect(mocks.rpc.mock.calls.some(([fn]) => fn === "org_transfer_cancel")).toBe(true);
    expect(db.state).toBe("none");
    expect(downloads).toHaveLength(0);
    // formulár je zasa k dispozícii
    expect(await screen.findByRole("button", { name: "Vyexportovať organizáciu" })).toBeTruthy();
  });

  it("rozpracovaný prenos (stránka sa medzitým znova načítala) sa dá zrušiť", async () => {
    db.state = "ready";
    db.locked = true;
    mount();
    expect(
      (await screen.findByText(/Export tejto organizácie je rozpracovaný/)).textContent,
    ).toContain("razenia sú zamknuté");
    fireEvent.click(screen.getByRole("button", { name: "Zrušiť rozpracovaný prenos" }));
    expect((await screen.findByRole("status")).textContent).toContain(
      "Prenos je zrušený, razenia sú odomknuté",
    );
    expect(db.state).toBe("none");
    expect(await screen.findByRole("button", { name: "Vyexportovať organizáciu" })).toBeTruthy();
  });

  describe("okno na zrušenie po exporte", () => {
    beforeEach(() => {
      db.state = "exported";
      db.isTest = true;
      db.markedTest = true;
      db.locked = true;
    });

    const fillForm = (receipt = "abcd 1234", name = "Firma „Ľ“") => {
      fireEvent.change(screen.getByLabelText("Kód potvrdenia z cieľového servera"), {
        target: { value: receipt },
      });
      fireEvent.change(screen.getByLabelText(/Na potvrdenie napíšte názov/), {
        target: { value: name },
      });
    };
    const openButton = () =>
      screen.getByRole("button", { name: "Zrušiť pôvodnú organizáciu…" }) as HTMLButtonElement;

    it("po opätovnom načítaní stránky povie, že súbor tu už nie je, a ponúkne kontrolu a zrušenie prenosu", async () => {
      mount();
      expect((await screen.findByText(/už nemá/)).textContent).toContain(
        "zrušte prenos a export zopakujte",
      );
      expect(screen.queryByRole("button", { name: "Stiahnuť súbor znova" })).toBeNull();
      expect(screen.getByText("Skontrolovať uložený súbor")).toBeTruthy();
      expect(
        screen.getByRole("button", { name: "Zrušiť prenos (organizácia ostane tu)" }),
      ).toBeTruthy();
    });

    it("kontrola uloženého súboru: správne heslo potvrdí obsah, nesprávne heslo a súbor z inej organizácie sa ohlásia", async () => {
      const content = (name: string) =>
        JSON.stringify({
          meta: { ...meta, organization: { ...meta.organization, name } },
          tables: { "public.profiles": [{}, {}], "public.punches": [{}, {}, {}] },
        });
      const good = await encryptText(content("Firma „Ľ“"), PW, { iterations: 100_000 });
      const other = await encryptText(content("Iná firma"), PW, { iterations: 100_000 });
      mount();
      const input = await screen.findByLabelText("Súbor");
      const checkButton = () =>
        screen.getByRole("button", { name: "Skontrolovať" }) as HTMLButtonElement;
      expect(checkButton().disabled).toBe(true);
      fireEvent.change(input, { target: { files: [good] } });
      fireEvent.change(screen.getByLabelText("Heslo súboru"), {
        target: { value: "iné-heslo-123456" },
      });
      fireEvent.click(checkButton());
      expect((await screen.findByRole("alert")).textContent).toContain("nesprávne heslo");
      fireEvent.change(screen.getByLabelText("Heslo súboru"), { target: { value: PW } });
      fireEvent.click(checkButton());
      await waitFor(() =>
        expect(screen.getByRole("status").textContent).toContain(
          "Súbor je v poriadku: organizácia „Firma „Ľ““, 5 riadkov v 2 tabuľkách.",
        ),
      );
      expect(screen.queryByText(/súbor je z inej organizácie/)).toBeNull();
      fireEvent.change(input, { target: { files: [other] } });
      fireEvent.click(checkButton());
      await waitFor(() => expect(screen.getByText(/súbor je z inej organizácie/)).toBeTruthy());
    });

    it("tlačidlo na zrušenie čaká na kód z cieľového servera aj na presný názov organizácie", async () => {
      mount();
      await screen.findByLabelText("Kód potvrdenia z cieľového servera");
      expect(openButton().disabled).toBe(true);
      fillForm("zlý", "Firma „Ľ“");
      expect(openButton().disabled).toBe(true);
      fillForm("abcd 1234", "firma");
      expect(openButton().disabled).toBe(true);
      fillForm("abcd 1234", "Firma „Ľ“");
      expect(openButton().disabled).toBe(false);
    });

    it("zrušenie vyžaduje ešte potvrdenie v dialógu (prázdne fronty terminálov), potom zruší organizáciu a odhlási", async () => {
      mount();
      await screen.findByLabelText("Kód potvrdenia z cieľového servera");
      fillForm();
      fireEvent.click(openButton());
      const dialog = await screen.findByRole("alertdialog");
      expect(dialog.textContent).toContain("2 účty, 3 razenia a 1 zariadenie");
      expect(dialog.textContent).toContain("čakajú vo fronte");
      const confirm = within(dialog).getByRole("button", {
        name: "Zrušiť organizáciu natrvalo",
      }) as HTMLButtonElement;
      expect(confirm.disabled).toBe(true);
      expect(mocks.rpc.mock.calls.some(([fn]) => fn === "org_transfer_confirm_and_delete")).toBe(
        false,
      );
      fireEvent.click(within(dialog).getByLabelText(/čaká na odoslanie: 0/));
      expect(confirm.disabled).toBe(false);
      fireEvent.click(confirm);
      await waitFor(() =>
        expect(mocks.navigate).toHaveBeenCalledWith({ to: "/auth", replace: true }),
      );
      const call = mocks.rpc.mock.calls.find(([fn]) => fn === "org_transfer_confirm_and_delete");
      expect(call?.[1]).toEqual({
        _receipt: "ABCD-1234",
        _confirm_name: "Firma „Ľ“",
        _accept_changes: false,
      });
      expect(db.deleted).toBe(true);
      expect(mocks.signOut).toHaveBeenCalledWith({ scope: "local" });
      expect(window.alert).toHaveBeenCalledWith(
        expect.stringContaining("bola zrušená: 2 účty, 3 razenia a 1 zariadenie"),
      );
    });

    it("chybný kód z databázy ukáže chybu v dialógu a nič nezruší ani neodhlási", async () => {
      db.receipt = "FFFF-0000";
      mount();
      await screen.findByLabelText("Kód potvrdenia z cieľového servera");
      fillForm();
      fireEvent.click(openButton());
      const dialog = await screen.findByRole("alertdialog");
      fireEvent.click(within(dialog).getByLabelText(/čaká na odoslanie: 0/));
      fireEvent.click(within(dialog).getByRole("button", { name: "Zrušiť organizáciu natrvalo" }));
      expect((await within(dialog).findByRole("alert")).textContent).toContain(
        "Kód potvrdenia prenosu nesedí",
      );
      expect(db.deleted).toBe(false);
      expect(mocks.signOut).not.toHaveBeenCalled();
      expect(mocks.navigate).not.toHaveBeenCalled();
    });

    it("zmeny od exportu treba výslovne potvrdiť a ukážu sa v prehľade", async () => {
      db.changes = { "public.punches": { then: 120, now: 123 } };
      mount();
      await screen.findByLabelText("Kód potvrdenia z cieľového servera");
      expect(screen.getByText(/razenia: 120 → 123/)).toBeTruthy();
      fillForm();
      expect(openButton().disabled).toBe(true);
      fireEvent.click(screen.getByLabelText(/Rozumiem, že tieto zmeny sa stratia/));
      expect(openButton().disabled).toBe(false);
      fireEvent.click(openButton());
      const dialog = await screen.findByRole("alertdialog");
      fireEvent.click(within(dialog).getByLabelText(/čaká na odoslanie: 0/));
      fireEvent.click(within(dialog).getByRole("button", { name: "Zrušiť organizáciu natrvalo" }));
      await waitFor(() => expect(mocks.navigate).toHaveBeenCalled());
      expect(
        mocks.rpc.mock.calls.find(([fn]) => fn === "org_transfer_confirm_and_delete")?.[1],
      ).toMatchObject({ _accept_changes: true });
    });

    it("zrušenie prenosu vráti organizáciu do pôvodného stavu a ukáže formulár exportu", async () => {
      mount();
      fireEvent.click(
        await screen.findByRole("button", { name: "Zrušiť prenos (organizácia ostane tu)" }),
      );
      expect((await screen.findByRole("status")).textContent).toContain(
        "označenie testovacia sa vrátilo",
      );
      expect(db.isTest).toBe(false);
      expect(await screen.findByRole("button", { name: "Vyexportovať organizáciu" })).toBeTruthy();
      expect(mocks.navigate).not.toHaveBeenCalled();
    });

    it("pôvodnú organizáciu nemožno zrušiť: ponúkne len ukončenie prenosu", async () => {
      db.protectedOrg = true;
      db.isTest = false;
      db.markedTest = false;
      mount();
      await screen.findByText(/je hotový/);
      expect(screen.queryByLabelText("Kód potvrdenia z cieľového servera")).toBeNull();
      expect(screen.queryByRole("button", { name: "Zrušiť pôvodnú organizáciu…" })).toBeNull();
      expect(screen.getByText(/nemožno zrušiť/)).toBeTruthy();
      fireEvent.click(screen.getByRole("button", { name: "Ukončiť prenos" }));
      expect((await screen.findByRole("status")).textContent).toContain("Prenos je zrušený");
    });
  });
});
