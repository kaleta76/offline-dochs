import { render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, expect, it, vi } from "vitest";
import { Route } from "./vykaz.$userId.$ym";

vi.mock("@tanstack/react-router", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@tanstack/react-router")>()),
  Link: ({ children }: { children?: React.ReactNode }) => <a href="#tim">{children}</a>,
  useNavigate: () => () => undefined,
}));
vi.mock("@/lib/month", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/month")>()),
  loadMonth: () =>
    Promise.resolve({
      profile: { id: "u1", sap_id: "9000002", department: "Oddelenie A" },
      closedAt: null,
      days: [],
    }),
}));
vi.mock("@/components/MonthTable", () => ({
  MonthPicker: () => <div>výber mesiaca</div>,
  MonthTable: () => <div>tabuľka mesiaca</div>,
}));
vi.mock("@/components/VoidRequest", () => ({
  useVoidRequest: () => ({ panel: null, open: () => undefined }),
}));

describe("Mesačný výkaz", () => {
  it("má osobné číslo a riadok na ručné doplnenie mena a priezviska, ale žiadne meno", async () => {
    vi.spyOn(Route, "useParams").mockReturnValue({ userId: "u1", ym: "2026-10" });
    const Component = Route.options.component;
    if (!Component) throw new Error("Report component missing");
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    render(
      <QueryClientProvider client={client}>
        <Component />
      </QueryClientProvider>,
    );
    expect(await screen.findByText("9000002")).toBeTruthy();
    expect(screen.getByText(/Meno a priezvisko:/)).toBeTruthy();
    expect(screen.getByText("Podpis zamestnanca")).toBeTruthy();
    expect(screen.getByText("Podpis vedúceho")).toBeTruthy();
  });
});
