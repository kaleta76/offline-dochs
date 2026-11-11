import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { Route } from "./diagnostika";

vi.mock("@/components/ConnectionDiagnostics", () => ({
  ConnectionDiagnostics: () => <div>panel diagnostiky</div>,
}));

describe("Stránka Diagnostika spojenia", () => {
  it("je dostupná každému prihlásenému: nadpis, vysvetlenie a panel", () => {
    const Component = Route.options.component;
    if (!Component) throw new Error("Diagnostika component missing");
    render(<Component />);
    expect(screen.getByRole("heading", { name: "Diagnostika spojenia" })).toBeTruthy();
    expect(screen.getByText(/Nič nemení/)).toBeTruthy();
    expect(screen.getByText("panel diagnostiky")).toBeTruthy();
  });
});
