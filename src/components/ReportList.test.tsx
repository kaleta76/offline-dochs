import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ReportList } from "./ReportList";

vi.mock("@tanstack/react-router", () => ({
  Link: ({
    to,
    params,
    children,
    ...rest
  }: {
    to: string;
    params: Record<string, string>;
    children: React.ReactNode;
  }) => (
    <a
      href={to.replace("$userId", params["userId"] ?? "").replace("$ym", params["ym"] ?? "")}
      {...rest}
    >
      {children}
    </a>
  ),
}));

const P1 = { id: "aaaaaaaa-0000-4000-8000-000000000001", sap_id: "9000010" };
const P2 = { id: "aaaaaaaa-0000-4000-8000-000000000002", sap_id: "9000002" };
const P3 = { id: "aaaaaaaa-0000-4000-8000-000000000003", sap_id: null };

describe("ReportList", () => {
  it("zoradí osobné čísla a každé odkazuje na výkaz zvoleného mesiaca", () => {
    render(<ReportList people={[P1, P2]} loading={false} failed={false} />);
    const links = screen.getAllByRole("link");
    expect(links.map((l) => l.textContent)).toEqual(["9000002", "9000010"]);
    const now = new Date();
    const ym = `${now.getFullYear()}-${now.getMonth() + 1}`;
    expect(links[0]?.getAttribute("href")).toBe(`/vykaz/${P2.id}/${ym}`);
  });

  it("zmena mesiaca zmení odkazy (rovnaký formát ako výkaz z Môj tím)", () => {
    render(<ReportList people={[P2]} loading={false} failed={false} />);
    fireEvent.click(screen.getByRole("button", { name: "Predchádzajúci mesiac" }));
    const dt = new Date(new Date().getFullYear(), new Date().getMonth() - 1, 1);
    expect(screen.getByRole("link").getAttribute("href")).toBe(
      `/vykaz/${P2.id}/${dt.getFullYear()}-${dt.getMonth() + 1}`,
    );
  });

  it("zamestnanec bez osobného čísla sa ukáže ako taký, nie s menom ani prázdne", () => {
    render(<ReportList people={[P3]} loading={false} failed={false} />);
    expect(screen.getByRole("link").textContent).toContain("Bez osobného čísla");
  });

  it("načítavanie, chyba a prázdny zoznam sa ohlásia", () => {
    const { rerender } = render(<ReportList people={[]} loading failed={false} />);
    expect(screen.getByText("Načítavam…")).toBeTruthy();
    rerender(<ReportList people={[]} loading={false} failed />);
    expect(screen.getByRole("alert").textContent).toContain("nepodarilo načítať");
    rerender(<ReportList people={[]} loading={false} failed={false} />);
    expect(screen.getByText("Zatiaľ nie sú žiadni zamestnanci.")).toBeTruthy();
  });
});
