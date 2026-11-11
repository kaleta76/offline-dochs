import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ConnectionDiagnostics } from "./ConnectionDiagnostics";

vi.mock("@/lib/auth", () => ({ useAuth: () => ({ session: null, roles: [] }) }));

describe("Diagnostika spojenia: text o dostupnosti", () => {
  it("hovorí, že panel je dostupný každému prihlásenému a kde ho nájde správca", () => {
    render(<ConnectionDiagnostics />);
    expect(screen.getByText(/dostupný každému prihlásenému/)).toBeTruthy();
    expect(screen.getByText("/diagnostika")).toBeTruthy();
    expect(screen.getByText("?servis=1")).toBeTruthy();
    expect(screen.getByText("?diagnostika=1")).toBeTruthy();
  });

  it("netvrdí, že je panel určený len pre IT", () => {
    render(<ConnectionDiagnostics />);
    expect(screen.queryByText(/určený pre IT/)).toBeNull();
  });
});
