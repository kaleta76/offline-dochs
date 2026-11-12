import { Blob as NodeBlob } from "node:buffer";
import { webcrypto } from "node:crypto";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { encryptText } from "@/lib/org-transfer-crypto";

type Rpc = { data: unknown; error: { code?: string; message: string } | null };

const IID = "7b0f7f4e-3d1c-4a69-9f0e-0a1b2c3d4e5f";
const ORG = "11111111-2222-4333-8444-555555555555";
const PW = "správne-heslo-12345";
const ORGANIZATION = { id: ORG, name: "Firma „Ľ“", code: "11111111" };

const mocks = vi.hoisted(() => ({
  rpc: vi.fn(),
  signOut: vi.fn(),
  navigate: vi.fn(),
}));
vi.mock("@/integrations/supabase/client", () => ({
  supabase: { rpc: mocks.rpc, auth: { signOut: mocks.signOut } },
}));
vi.mock("@/lib/auth", () => ({
  useAuth: () => ({
    organization: { id: "o1", name: "Nová firma" },
    session: { user: { id: "u1" } },
  }),
}));
vi.mock("@tanstack/react-router", () => ({ useNavigate: () => mocks.navigate }));

import { OrganizationImport } from "./OrganizationImport";

beforeAll(() => {
  vi.stubGlobal("Blob", NodeBlob);
  vi.stubGlobal("crypto", webcrypto);
});

const META = `{"format": 2, "organization": {"id": "${ORG}", "name": "Firma „Ľ“"}}`;
const TEXT = `{"meta":${META},"tables":{"public.profiles":[{"id": "u9", "daily_fund": 7.50}],"public.punches":[{"id": 1},{"id": 2}]}}`;

interface Db {
  eligible: boolean;
  missing: boolean;
  lastReceipt: string | null;
  staged: number;
  cancelled: number;
  failCheck: string | null;
  failCommit: string | null;
  committedWith: string | null;
  chunks: string[];
}
let db: Db;

function handle(fn: string, args: Record<string, unknown> | undefined): Rpc {
  const ok = (data: unknown): Rpc => ({ data, error: null });
  if (db.missing)
    return { data: null, error: { code: "PGRST202", message: "Could not find the function" } };
  switch (fn) {
    case "org_import_status":
      return ok({
        eligible: db.eligible,
        reasons: db.eligible ? [] : ["Organizácia už má údaje (razenia: 3)."],
        name: "Nová firma",
        code: "AAAAAAAA",
        active: null,
        last_import: db.lastReceipt
          ? { finished_at: null, receipt: db.lastReceipt, rows: 3 }
          : null,
      });
    case "org_import_begin":
      return ok({
        import_id: IID,
        organization: ORGANIZATION,
        tables: [
          { rel: "public.profiles", n: 1 },
          { rel: "public.punches", n: 2 },
        ],
        rows: 3,
        max_chunk_rows: 5000,
        max_chunk_chars: 6_000_000,
      });
    case "org_import_chunk": {
      const rows = String(args?.["_rows"]);
      db.chunks.push(rows);
      const count = (JSON.parse(rows) as unknown[]).length;
      db.staged += count;
      return ok({ rel: args?.["_rel"], seq: args?.["_seq"], count, received: count });
    }
    case "org_import_check":
      if (db.failCheck) return { data: null, error: { code: "P0001", message: db.failCheck } };
      return ok({
        state: "checked",
        import_id: IID,
        organization: ORGANIZATION,
        counts: { "public.profiles": 1, "public.punches": 2 },
        rows: 3,
        exported_at: null,
        warnings: [],
        replaces: { name: "Nová firma", code: "AAAAAAAA" },
      });
    case "org_import_commit":
      if (db.failCommit) return { data: null, error: { code: "P0001", message: db.failCommit } };
      db.committedWith = String(args?.["_confirm_name"]);
      return ok({
        state: "done",
        organization: ORGANIZATION,
        receipt: "AB12-CD34",
        rows: 3,
        ids_mode: "keep",
        warnings: [],
      });
    case "org_import_cancel":
      db.cancelled += 1;
      db.staged = 0;
      return ok({ state: "cancelled" });
    default:
      return { data: null, error: { message: `nečakané volanie ${fn}` } };
  }
}

function renderCard() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <OrganizationImport />
    </QueryClientProvider>,
  );
}

async function chooseFileAndUpload(password = PW) {
  const blob = await encryptText(TEXT, PW, { iterations: 100_000 });
  const file = blob as unknown as File;
  fireEvent.change(await screen.findByLabelText("Súbor prenosu"), { target: { files: [file] } });
  fireEvent.change(screen.getByLabelText("Heslo súboru"), { target: { value: password } });
  fireEvent.click(screen.getByRole("button", { name: "Nahrať a skontrolovať" }));
}

beforeEach(() => {
  db = {
    eligible: true,
    missing: false,
    lastReceipt: null,
    staged: 0,
    cancelled: 0,
    failCheck: null,
    failCommit: null,
    committedWith: null,
    chunks: [],
  };
  mocks.rpc.mockImplementation((fn: string, args?: Record<string, unknown>) =>
    Promise.resolve(handle(fn, args)),
  );
  mocks.signOut.mockResolvedValue({ error: null });
});
afterEach(() => {
  vi.clearAllMocks();
});

describe("OrganizationImport", () => {
  it("bez migrácie 0017 povie, čo treba spustiť", async () => {
    db.missing = true;
    renderCard();
    expect(await screen.findByRole("alert")).toHaveTextContent("migráciu 0017");
    expect(screen.queryByLabelText("Súbor prenosu")).toBeNull();
  });

  it("organizácia s údajmi: vypíše dôvody a formulár neponúkne", async () => {
    db.eligible = false;
    renderCard();
    expect(await screen.findByText("Organizácia už má údaje (razenia: 3).")).toBeInTheDocument();
    expect(screen.queryByLabelText("Súbor prenosu")).toBeNull();
  });

  it("importovaná organizácia ukáže kód potvrdenia pre pôvodný server", async () => {
    db.eligible = false;
    db.lastReceipt = "12AB-34CD";
    renderCard();
    expect(await screen.findByText("12AB-34CD")).toBeInTheDocument();
  });

  it("celý postup: nahratie, kontrola, potvrdenie v dialógu, kód potvrdenia a odhlásenie", async () => {
    renderCard();
    await chooseFileAndUpload();
    expect(await screen.findByText(/Súbor je v poriadku/)).toHaveTextContent("Firma „Ľ“");
    // riadky idú na server ako nezmenený text (7.50 ostáva 7.50)
    expect(db.chunks).toEqual(['[{"id": "u9", "daily_fund": 7.50}]', '[{"id": 1},{"id": 2}]']);
    expect(db.committedWith).toBeNull();

    fireEvent.click(screen.getByRole("button", { name: "Importovať a nahradiť túto organizáciu" }));
    const submit = await screen.findByRole("button", { name: "Importovať" });
    expect(submit).toBeDisabled();
    fireEvent.change(screen.getByLabelText(/Na potvrdenie opíšte názov/), {
      target: { value: "Nová firma" },
    });
    expect(submit).toBeDisabled(); // ešte chýba súhlas
    fireEvent.click(screen.getByLabelText(/Rozumiem, že táto prázdna organizácia/));
    expect(submit).toBeEnabled();
    fireEvent.click(submit);

    expect(await screen.findByTestId("import-receipt")).toHaveTextContent("AB12-CD34");
    expect(db.committedWith).toBe("Nová firma");
    fireEvent.click(screen.getByRole("button", { name: "Odhlásiť sa" }));
    await waitFor(() => expect(mocks.signOut).toHaveBeenCalledWith({ scope: "local" }));
    expect(mocks.navigate).toHaveBeenCalledWith({ to: "/auth", replace: true });
  });

  it("nesprávny názov v dialógu zápis nepovolí", async () => {
    renderCard();
    await chooseFileAndUpload();
    fireEvent.click(
      await screen.findByRole("button", { name: "Importovať a nahradiť túto organizáciu" }),
    );
    fireEvent.click(await screen.findByLabelText(/Rozumiem, že táto prázdna organizácia/));
    fireEvent.change(screen.getByLabelText(/Na potvrdenie opíšte názov/), {
      target: { value: "Firma „Ľ“" },
    });
    expect(screen.getByRole("button", { name: "Importovať" })).toBeDisabled();
    expect(db.committedWith).toBeNull();
  });

  it("zlé heslo: nič sa nenahrá", async () => {
    renderCard();
    await chooseFileAndUpload("zlé-heslo-1234567");
    expect(await screen.findByRole("alert")).toHaveTextContent("nesprávne heslo");
    expect(db.staged).toBe(0);
    expect(mocks.rpc.mock.calls.some((c) => c[0] === "org_import_begin")).toBe(false);
  });

  it("súbor, ktorý kontrola odmietne: nahrané údaje sa zahodia", async () => {
    db.failCheck = "Súbor nevyhovuje:\n - 1 prihlasovacích účtov má neštandardnú rolu";
    renderCard();
    await chooseFileAndUpload();
    const alert = await screen.findByRole("alert");
    expect(alert).toHaveTextContent("neštandardnú rolu");
    expect(alert).toHaveTextContent("Nahrané údaje boli zahodené");
    expect(db.cancelled).toBe(1);
    expect(
      screen.queryByRole("button", { name: "Importovať a nahradiť túto organizáciu" }),
    ).toBeNull();
  });

  it("zápis, ktorý databáza vráti späť: chyba ostane v dialógu a organizácia ostáva", async () => {
    db.failCommit = "Import sa vrátil späť, overenie zlyhalo";
    renderCard();
    await chooseFileAndUpload();
    fireEvent.click(
      await screen.findByRole("button", { name: "Importovať a nahradiť túto organizáciu" }),
    );
    fireEvent.click(await screen.findByLabelText(/Rozumiem, že táto prázdna organizácia/));
    fireEvent.change(screen.getByLabelText(/Na potvrdenie opíšte názov/), {
      target: { value: "Nová firma" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Importovať" }));
    expect(await screen.findByText(/Import sa vrátil späť/)).toBeInTheDocument();
    expect(screen.queryByTestId("import-receipt")).toBeNull();
    expect(mocks.signOut).not.toHaveBeenCalled();
  });
});
