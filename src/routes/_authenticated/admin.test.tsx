import { render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { Route } from "./admin";

const mocks = vi.hoisted(() => ({
  isTest: false,
}));

function chain() {
  const result = { data: [], error: null };
  const query: Record<string, unknown> = {};
  for (const m of ["select", "order", "eq", "neq", "in", "limit", "maybeSingle", "gte"]) {
    query[m] = () => query;
  }
  query["then"] = (resolve: (v: typeof result) => unknown, reject?: (e: unknown) => unknown) =>
    Promise.resolve(result).then(resolve, reject);
  return query;
}
vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    from: () => chain(),
    rpc: () => Promise.resolve({ data: null, error: { message: "mock" } }),
    auth: { signOut: () => Promise.resolve({ error: null }) },
  },
}));
vi.mock("@/lib/auth", () => ({
  useAuth: () => ({
    roles: ["admin"],
    session: { user: { id: "u1" } },
    organization: { id: "org1", name: "Skúšobná firma", is_test: mocks.isTest },
    refetchMe: () => Promise.resolve(),
  }),
}));
vi.mock("@/lib/admin-overview", () => ({
  loadAdminOverview: () => Promise.resolve({ inviteCode: "ABC123", people: [] }),
}));
vi.mock("@tanstack/react-router", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@tanstack/react-router")>()),
  useNavigate: () => () => undefined,
}));

const OPERATION = [
  "Pozývací kód pre zamestnancov",
  "Export pre mzdovú účtáreň (SAP)",
  "Export pre dochádzkový systém (Access)",
  "Prístup zamestnancov (osobné čísla a PIN)",
  "Zamestnanci",
  "Sviatky",
];
const SERVICE_TOOLS = [
  "Konfigurácia z Accessu",
  "Pravidlá výpočtu",
  "Číselník prerušení",
  "Odhlásenie pri nečinnosti",
  "Testovacia prevádzka a porovnanie s Accessom",
  "Testovacia organizácia",
];
const DIAGNOSTICS = "Diagnostika spojenia";

function mount(search = "") {
  window.history.replaceState(null, "", `/admin${search}`);
  const Component = Route.options.component;
  if (!Component) throw new Error("Admin component missing");
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <Component />
    </QueryClientProvider>,
  );
}

const has = (text: string) =>
  screen.queryByText((_, el) => el?.tagName === "H2" && (el.textContent ?? "").trim() === text) !==
    null ||
  screen.queryByText(text) !== null ||
  screen.queryByLabelText(text) !== null;

describe("Správa: karty Prevádzka a Servis a testovanie", () => {
  beforeEach(() => {
    mocks.isTest = false;
  });

  it("ostrá organizácia: len bežná prevádzka, žiadna záložka, servisné voľby nikde", async () => {
    mount();
    await waitFor(() => expect(has(OPERATION[0] as string)).toBe(true));
    for (const heading of OPERATION) expect(has(heading), heading).toBe(true);
    for (const heading of [...SERVICE_TOOLS, DIAGNOSTICS])
      expect(has(heading), heading).toBe(false);
    expect(screen.queryByRole("tab")).toBeNull();
  });

  it("?servis=1: záložky sú dve, Servis sa otvorí a má všetky servisné voľby aj diagnostiku", async () => {
    mount("?servis=1");
    await waitFor(() => expect(screen.getAllByRole("tab")).toHaveLength(2));
    for (const heading of [...SERVICE_TOOLS, DIAGNOSTICS]) expect(has(heading), heading).toBe(true);
    // Bežné voľby ostávajú v druhej karte, v Servise sa neukazujú.
    expect(
      screen.getByRole("tab", { name: "Servis a testovanie" }).getAttribute("aria-selected"),
    ).toBe("true");
    const operationHeading = screen.getByText("Export pre mzdovú účtáreň (SAP)");
    expect(operationHeading.closest("[hidden]")).not.toBeNull();
  });

  it("?diagnostika=1: karta Servis obsahuje len diagnostiku spojenia", async () => {
    mount("?diagnostika=1");
    await waitFor(() => expect(has(DIAGNOSTICS)).toBe(true));
    for (const heading of SERVICE_TOOLS) expect(has(heading), heading).toBe(false);
  });

  it("testovacia organizácia: záložka je vždy, ale otvorená je Prevádzka", async () => {
    mocks.isTest = true;
    mount();
    await waitFor(() => expect(screen.getAllByRole("tab")).toHaveLength(2));
    expect(screen.getByRole("tab", { name: "Prevádzka" }).getAttribute("aria-selected")).toBe(
      "true",
    );
    for (const heading of OPERATION) expect(has(heading), heading).toBe(true);
  });
});
