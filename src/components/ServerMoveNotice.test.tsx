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

describe("správa od správcu a organizácia zrušená bez presunu (migrácia 0020)", () => {
  const MSG = "Testovanie sa po upozornení SOC ukončilo. Ďakujeme.";
  const ended = (n = 2) => Array.from({ length: n }, (_, i) => punch(i + 1));

  it("správa sa ukazuje vo všetkých troch oknách ako obyčajný text, aj s HTML znakmi", () => {
    const { rerender, props, container } = view({ moved: [], locked: [punch(1)], message: MSG });
    expect(screen.getByRole("status").textContent).toContain(`Správa od správcu: ${MSG}`);
    rerender(<ServerMoveView {...props} moved={[punch(1)]} locked={[]} message={MSG} />);
    expect(screen.getByRole("alert").textContent).toContain(`Správa od správcu: ${MSG}`);
    rerender(
      <ServerMoveView
        {...props}
        moved={[]}
        done={{ removed: 1, remaining: 0, full: true, problems: [] }}
        message={MSG}
      />,
    );
    expect(screen.getByRole("status").textContent).toContain(`Správa od správcu: ${MSG}`);
    rerender(
      <ServerMoveView
        {...props}
        moved={[punch(1)]}
        message={'<img src=x onerror=alert(1)> <a href="https://zly.example.test">klik</a>'}
      />,
    );
    // zobrazí sa doslova ako text, nevznikne z neho prvok ani odkaz
    expect(container.querySelector("img")).toBeNull();
    expect(screen.queryByRole("link", { name: "klik" })).toBeNull();
    expect(screen.getByRole("alert").textContent).toContain("<img src=x onerror=alert(1)>");
  });

  it("bez správy sa riadok „Správa od správcu“ neukáže", () => {
    view({ message: null });
    expect(screen.getByRole("alert").textContent).not.toContain("Správa od správcu");
  });

  it("zrušená organizácia: vlastný nadpis, text bez presunu a nepovinný súbor", () => {
    view({ moved: [], ended: ended(), url: null, message: MSG, onDiscard: vi.fn() });
    const alert = screen.getByRole("alert");
    expect(alert.getAttribute("aria-label")).toBe("Organizácia bola zrušená");
    expect(alert.textContent).toContain("Organizácia bola zrušená");
    expect(alert.textContent).toContain("nikam sa nepresťahovala");
    expect(alert.textContent).toContain("ostalo 2 razení");
    expect(alert.textContent).toContain("nepovinné");
    expect(alert.textContent).toContain(`Správa od správcu: ${MSG}`);
    expect(alert.textContent).not.toContain("Server bol presťahovaný");
    expect(screen.queryByRole("link")).toBeNull();
  });

  it("zrušená organizácia: súbor sa dá uložiť rovnako ako pri presťahovaní", async () => {
    const { props } = view({ moved: [], ended: ended(), onDiscard: vi.fn() });
    fill(PW);
    fireEvent.click(screen.getByRole("button", { name: "Uložiť súbor" }));
    await waitFor(() => expect(props.onExport).toHaveBeenCalledWith(PW));
  });

  it("zahodenie bez súboru vyžaduje zaškrtnutie aj druhé potvrdenie a zavolá sa až po „Áno, zahodiť“", async () => {
    const onDiscard = vi.fn(async () => undefined);
    const { props } = view({ moved: [], ended: ended(), onDiscard });
    const discard = screen.getByRole("button", {
      name: "Zahodiť 2 razení a upratať",
    }) as HTMLButtonElement;
    expect(discard.disabled).toBe(true);
    fireEvent.click(discard);
    expect(screen.queryByText(/Naozaj zahodiť/)).toBeNull();
    fireEvent.click(screen.getByRole("checkbox"));
    expect(discard.disabled).toBe(false);
    fireEvent.click(discard);
    expect(screen.getByText("Naozaj zahodiť 2 razení z tohto zariadenia?")).toBeTruthy();
    expect(screen.getByText(/Nie je uložená žiadna kópia/)).toBeTruthy();
    expect(onDiscard).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Nie, ponechať" }));
    expect(onDiscard).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Zahodiť 2 razení a upratať" }));
    fireEvent.click(screen.getByRole("button", { name: "Áno, zahodiť" }));
    await waitFor(() => expect(onDiscard).toHaveBeenCalledTimes(1));
    expect(props.onCleanup).not.toHaveBeenCalled();
    expect(props.onExport).not.toHaveBeenCalled();
  });

  it("chyba pri zahodení (zmenil sa počet razení) sa ukáže", async () => {
    view({
      moved: [],
      ended: ended(),
      onDiscard: vi.fn(async () => {
        throw new Error("V zariadení sa počet razení zmenil. Skontrolujte ho a skúste znova.");
      }),
    });
    fireEvent.click(screen.getByRole("checkbox"));
    fireEvent.click(screen.getByRole("button", { name: /Zahodiť 2 razení/ }));
    fireEvent.click(screen.getByRole("button", { name: "Áno, zahodiť" }));
    expect(await screen.findByText(/počet razení zmenil/)).toBeTruthy();
  });

  it("po uložení súboru sa pri zrušenej organizácii ponúka zmazanie so súborom, nie zahodenie bez neho", () => {
    view({
      moved: [],
      ended: ended(),
      onDiscard: vi.fn(),
      exported: { fingerprint: "f", count: 2, name: "x.dochs-enc" },
    });
    expect(screen.getByRole("button", { name: "Zmazať 2 razení a upratať" })).toBeTruthy();
    expect(screen.queryByRole("button", { name: /Zahodiť/ })).toBeNull();
  });

  it("pri presťahovaní sa zahodenie bez súboru NEPONÚKA, ani keď je onDiscard k dispozícii", () => {
    view({ onDiscard: vi.fn() });
    expect(screen.queryByRole("button", { name: /Zahodiť/ })).toBeNull();
    expect(screen.queryByText(/bez uloženia/)).toBeNull();
    expect(screen.queryByRole("checkbox")).toBeNull();
  });

  it("bez onDiscard sa zahodenie neponúka ani pri zrušenej organizácii", () => {
    view({ moved: [], ended: ended() });
    expect(screen.queryByRole("button", { name: /Zahodiť/ })).toBeNull();
    expect(screen.queryByRole("checkbox")).toBeNull();
  });

  it("presťahované razenia majú prednosť pred zrušenými", () => {
    view({ moved: [punch(1)], ended: [punch(2, B), punch(3, B)], onDiscard: vi.fn() });
    expect(screen.getByRole("alert").textContent).toContain("Server bol presťahovaný");
    expect(screen.getByRole("alert").textContent).toContain("ostalo 1 razenie");
    expect(screen.queryByRole("button", { name: /Zahodiť/ })).toBeNull();
  });

  it("počas prenosu sa nič neponúka zmazať ani zahodiť, aj keď je správa", () => {
    view({ moved: [], locked: [punch(1)], message: MSG, onDiscard: vi.fn() });
    expect(screen.queryAllByRole("button")).toHaveLength(0);
  });
});
