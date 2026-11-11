import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { AdminTabs } from "./AdminTabs";

function Probe({ label, log }: { label: string; log: string[] }) {
  log.push(`mount:${label}`);
  return <p>{label}</p>;
}

const mount = (props: { showService: boolean; openService: boolean }, log: string[] = []) =>
  render(
    <AdminTabs
      {...props}
      operation={<Probe label="obsah prevádzky" log={log} />}
      service={<Probe label="obsah servisu" log={log} />}
    />,
  );

describe("AdminTabs", () => {
  it("bez odkrytia sa nevykreslí záložka ani servisný obsah, prevádzka funguje ako doteraz", () => {
    const log: string[] = [];
    mount({ showService: false, openService: false }, log);
    expect(screen.getByText("obsah prevádzky")).toBeTruthy();
    expect(screen.queryByText("obsah servisu")).toBeNull();
    expect(screen.queryByRole("tab")).toBeNull();
    expect(log).not.toContain("mount:obsah servisu");
  });

  it("po odkrytí sú dve záložky, otvorená je Prevádzka a servisný obsah sa ešte nenačíta", () => {
    const log: string[] = [];
    mount({ showService: true, openService: false }, log);
    expect(screen.getAllByRole("tab")).toHaveLength(2);
    expect(screen.getByRole("tab", { name: "Prevádzka" }).getAttribute("aria-selected")).toBe(
      "true",
    );
    expect(screen.getByText("obsah prevádzky")).toBeTruthy();
    expect(screen.queryByText("obsah servisu")).toBeNull();
    expect(log).not.toContain("mount:obsah servisu");
  });

  it("prepnutie na Servis ukáže varovanie a servisný obsah; prevádzka ostane načítaná, len skrytá", () => {
    mount({ showService: true, openService: false });
    fireEvent.mouseDown(screen.getByRole("tab", { name: "Servis a testovanie" }), { button: 0 });
    expect(screen.getByText("obsah servisu")).toBeTruthy();
    expect(screen.getByText(/Nie je pre bežnú prevádzku/)).toBeTruthy();
    const operation = screen.getByText("obsah prevádzky");
    expect(operation.closest("[hidden]")).not.toBeNull();
  });

  it("?servis=1: karta Servis sa otvorí sama a dá sa vrátiť na Prevádzku", () => {
    mount({ showService: true, openService: true });
    expect(screen.getByText("obsah servisu")).toBeTruthy();
    fireEvent.mouseDown(screen.getByRole("tab", { name: "Prevádzka" }), { button: 0 });
    expect(screen.queryByText("obsah servisu")).toBeNull();
    expect(screen.getByText("obsah prevádzky")).toBeTruthy();
  });

  it("adresa sa načíta až po prvom vykreslení: karta sa otvorí aj vtedy, keď sa odkrytie príde neskôr", () => {
    const view = mount({ showService: false, openService: false });
    view.rerender(
      <AdminTabs
        showService
        openService
        operation={<p>obsah prevádzky</p>}
        service={<p>obsah servisu</p>}
      />,
    );
    expect(screen.getByText("obsah servisu")).toBeTruthy();
  });

  it("vlastný výber človeka sa neprepíše neskoršou zmenou predvolenia", () => {
    const view = mount({ showService: true, openService: false });
    fireEvent.mouseDown(screen.getByRole("tab", { name: "Servis a testovanie" }), { button: 0 });
    view.rerender(
      <AdminTabs
        showService
        openService={false}
        operation={<p>obsah prevádzky</p>}
        service={<p>obsah servisu</p>}
      />,
    );
    expect(screen.getByText("obsah servisu")).toBeTruthy();
  });
});
