import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

vi.mock("@/integrations/supabase/client", () => ({ supabase: {} }));
import { ServerMoveView, type ServerMoveViewProps } from "./ServerMoveNotice";
import type { QueuedPunch } from "@/lib/offline-queue";

const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";
const punch = (n: number, user = A): QueuedPunch => ({
  client_uuid: `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`,
  user_id: user,
  code: "WORK",
  direction: "IN",
  client_time: `2026-11-12T06:00:0${n}.000Z`,
  device: "d",
});
const PW = "správne-heslo-12345";

function view(over: Partial<ServerMoveViewProps> = {}) {
  const props: ServerMoveViewProps = {
    moved: [punch(1), punch(2), punch(3, B)],
    locked: [],
    url: "https://novy.example.test",
    exported: null,
    done: null,
    onExport: vi.fn(async () => undefined),
    onDownloadAgain: null,
    onCleanup: vi.fn(async () => undefined),
    onRecheck: vi.fn(),
    ...over,
  };
  return { props, ...render(<ServerMoveView {...props} />) };
}
const fill = (first: string, second = first) => {
  fireEvent.change(screen.getByLabelText(/Heslo súboru/), { target: { value: first } });
  fireEvent.change(screen.getByLabelText("Heslo znova"), { target: { value: second } });
};

describe("oznam o presťahovaní organizácie", () => {
  it("bez razení dotknutých účtov sa neukáže nič", () => {
    const { container } = view({ moved: [], locked: [] });
    expect(container.textContent).toBe("");
  });

  it("počas prenosu: jasné hlásenie, že razenia sú uložené a nič sa nestratilo; nič sa neponúka zmazať", () => {
    view({ moved: [], locked: [punch(1), punch(2)] });
    const status = screen.getByRole("status");
    expect(status.textContent).toContain("Organizácia sa práve sťahuje na iný server");
    expect(status.textContent).toContain("čaká 2 razení");
    expect(status.textContent).toContain("nič sa nestratilo");
    expect(screen.getByRole("link", { name: "https://novy.example.test" })).toBeTruthy();
    expect(screen.queryAllByRole("button")).toHaveLength(0);
  });

  it("po presťahovaní: počet razení, nová adresa a tri kroky; zmazanie sa pred uložením súboru neponúka", () => {
    view();
    const alert = screen.getByRole("alert");
    expect(alert.textContent).toContain("Server bol presťahovaný");
    expect(alert.textContent).toContain("ostalo 3 razení");
    expect(alert.textContent).toContain("nič sa nezmaže samo");
    expect(alert.textContent).toContain("Neskoré razenia");
    expect(
      screen.getByRole("link", { name: "https://novy.example.test" }).getAttribute("href"),
    ).toBe("https://novy.example.test");
    expect(screen.getByText(/Zmazanie sa ponúkne až po uložení súboru/)).toBeTruthy();
    expect(screen.queryByRole("checkbox")).toBeNull();
    expect(screen.queryByRole("button", { name: /Zmazať/ })).toBeNull();
    expect(screen.queryByRole("button", { name: /zmazať/i })).toBeNull();
  });

  it("súbor sa uloží len s heslom aspoň 12 znakov zadaným dvakrát rovnako", async () => {
    const { props } = view();
    const save = screen.getByRole("button", { name: "Uložiť súbor" }) as HTMLButtonElement;
    expect(save.disabled).toBe(true);
    fill("krátke");
    expect(screen.getByText(/aspoň 12 znakov\./)).toBeTruthy();
    expect(save.disabled).toBe(true);
    fill(PW, `${PW}x`);
    expect(screen.getByText("Heslá sa nezhodujú.")).toBeTruthy();
    expect(save.disabled).toBe(true);
    fill(PW);
    expect(save.disabled).toBe(false);
    fireEvent.click(save);
    await waitFor(() => expect(props.onExport).toHaveBeenCalledWith(PW));
    expect(props.onCleanup).not.toHaveBeenCalled();
    // heslo sa po uložení z poľa vymaže
    await waitFor(() =>
      expect((screen.getByLabelText(/Heslo súboru/) as HTMLInputElement).value).toBe(""),
    );
  });

  it("chyba pri ukladaní súboru sa ukáže a zmazanie sa stále neponúka", async () => {
    view({
      onExport: vi.fn(async () => {
        throw new Error("Kontrola vytvoreného súboru zlyhala, súbor sa neuložil.");
      }),
    });
    fill(PW);
    fireEvent.click(screen.getByRole("button", { name: "Uložiť súbor" }));
    expect(await screen.findByText(/súbor sa neuložil/)).toBeTruthy();
    expect(screen.queryByRole("checkbox")).toBeNull();
  });

  it("po uložení súboru: zmazanie vyžaduje zaškrtnutie aj druhé potvrdenie s počtom", async () => {
    const { props } = view({
      exported: {
        fingerprint: "f",
        count: 3,
        name: "razenia-zo-zariadenia-20261113-0705-3.dochs-enc",
      },
    });
    expect(screen.getByRole("status").textContent).toContain(
      "razenia-zo-zariadenia-20261113-0705-3.dochs-enc",
    );
    const del = screen.getByRole("button", {
      name: "Zmazať 3 razení a upratať",
    }) as HTMLButtonElement;
    expect(del.disabled).toBe(true);
    fireEvent.click(del);
    expect(props.onCleanup).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("checkbox"));
    expect(del.disabled).toBe(false);
    fireEvent.click(del);
    expect(props.onCleanup).not.toHaveBeenCalled();
    expect(screen.getByText("Naozaj zmazať 3 razení z tohto zariadenia?")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Nie, ponechať" }));
    expect(props.onCleanup).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Zmazať 3 razení a upratať" }));
    fireEvent.click(screen.getByRole("button", { name: "Áno, zmazať" }));
    await waitFor(() => expect(props.onCleanup).toHaveBeenCalledTimes(1));
    expect(props.onExport).not.toHaveBeenCalled();
  });

  it("chyba pri mazaní sa ukáže (napr. pribudli razenia, ktoré v súbore nie sú)", async () => {
    view({
      exported: { fingerprint: "f", count: 3, name: "x.dochs-enc" },
      onCleanup: vi.fn(async () => {
        throw new Error(
          "V zariadení pribudli razenia, ktoré v uloženom súbore nie sú. Uložte súbor znova.",
        );
      }),
    });
    fireEvent.click(screen.getByRole("checkbox"));
    fireEvent.click(screen.getByRole("button", { name: /Zmazať 3 razení/ }));
    fireEvent.click(screen.getByRole("button", { name: "Áno, zmazať" }));
    expect(await screen.findByText(/Uložte súbor znova/)).toBeTruthy();
  });

  it("stiahnuť znova a skontrolovať znova", () => {
    const again = vi.fn();
    const { props } = view({
      exported: { fingerprint: "f", count: 3, name: "x.dochs-enc" },
      onDownloadAgain: again,
    });
    fireEvent.click(screen.getByRole("button", { name: "Stiahnuť znova" }));
    expect(again).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByRole("button", { name: "Skontrolovať znova" }));
    expect(props.onRecheck).toHaveBeenCalledTimes(1);
  });

  it("viac než 2000 razení sa do jedného súboru neukladá", () => {
    view({
      moved: Array.from({ length: 2001 }, (_, i) => ({ ...punch(1), client_uuid: `x${i}` })),
    });
    expect(screen.getByText(/viac než 2000 razení/)).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Uložiť súbor" })).toBeNull();
  });

  it("po uprataní: úplné aj čiastočné, s adresou a vypísanými problémami", () => {
    const { rerender, props } = view({
      done: { removed: 3, remaining: 0, full: true, problems: [] },
    });
    expect(screen.getByRole("status").textContent).toContain("Zariadenie je upratané.");
    expect(screen.getByRole("status").textContent).toContain("Zmazaných razení: 3");
    expect(screen.getByRole("link", { name: "https://novy.example.test" })).toBeTruthy();
    rerender(
      <ServerMoveView
        {...props}
        done={{ removed: 2, remaining: 1, full: false, problems: ["service worker"] }}
      />,
    );
    expect(screen.getByRole("status").textContent).toContain("V zariadení ostalo 1 razení");
    expect(screen.getByRole("alert").textContent).toContain("service worker");
  });

  it("adresa, ktorá neprešla kontrolou (null), sa neukáže", () => {
    view({ url: null });
    expect(screen.queryByRole("link")).toBeNull();
  });
});
