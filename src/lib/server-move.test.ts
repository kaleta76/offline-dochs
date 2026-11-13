import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  CHECK_INTERVAL_MS,
  checkMoveNotice,
  forgetMove,
  getMoveSnapshot,
  MAX_NOTICE_USERS,
  MOVE_STORAGE_KEY,
  noteAccepted,
  noteTransferLock,
  parseNotice,
  MAX_MESSAGE_LENGTH,
  resetMoveStateForTests,
  safeDestination,
  safeMessage,
  subscribeMove,
  type NoticeClient,
} from "./server-move";

const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";
const C = "33333333-3333-4333-8333-333333333333";

function memory(initial: Record<string, string> = {}) {
  const data = new Map(Object.entries(initial));
  return {
    data,
    getItem: (k: string) => data.get(k) ?? null,
    setItem: (k: string, v: string) => void data.set(k, v),
    removeItem: (k: string) => void data.delete(k),
  };
}
const answer = (users: Record<string, unknown>) => ({ data: { version: 1, users }, error: null });
const online = () => true;

beforeEach(() => resetMoveStateForTests());

describe("safeDestination (adresa z oznamu sa ukazuje ľuďom)", () => {
  it("prejde len čisté http(s)", () => {
    expect(safeDestination("https://novy.example.test")).toBe("https://novy.example.test");
    expect(safeDestination("http://localhost:8080")).toBe("http://localhost:8080");
    expect(safeDestination("https://novy.example.test/dochadzka")).toBe(
      "https://novy.example.test/dochadzka",
    );
  });
  it.each([
    "javascript:alert(1)",
    "data:text/html,x",
    "ftp://novy.example.test",
    "//novy.example.test",
    "https://meno:heslo@novy.example.test",
    "https://novy.example.test/?x=1",
    "https://novy.example.test/#a",
    "https://novy example.test",
    "https://novy.example.test/<script>",
    " https://novy.example.test",
    "https://",
    `https://${"a".repeat(220)}.test`,
  ])("odmietne %s", (value) => expect(safeDestination(value)).toBeNull());
  it("odmietne iný typ", () => {
    expect(safeDestination(null)).toBeNull();
    expect(safeDestination(42)).toBeNull();
    expect(safeDestination({ toString: () => "https://novy.example.test" })).toBeNull();
  });
});

describe("safeMessage (správa od správcu sa ukazuje ľuďom)", () => {
  it("prejde jednoriadkový čistý text vrátane diakritiky a emoji", () => {
    expect(safeMessage("Testovanie sa po upozornení SOC ukončilo.")).toBe(
      "Testovanie sa po upozornení SOC ukončilo.",
    );
    expect(safeMessage("Ďakujeme 🙂")).toBe("Ďakujeme 🙂");
    expect(safeMessage("a".repeat(MAX_MESSAGE_LENGTH))).toHaveLength(MAX_MESSAGE_LENGTH);
    // emoji je jeden znak, nie dva (dĺžka sa počíta v znakoch, rovnako ako v databáze)
    expect(safeMessage("🙂".repeat(MAX_MESSAGE_LENGTH))).not.toBeNull();
  });
  it("odmietne prázdne, príliš dlhé, viacriadkové, riadiace a skryté znaky, okrajové medzery a iný typ", () => {
    expect(safeMessage("")).toBeNull();
    expect(safeMessage("a".repeat(MAX_MESSAGE_LENGTH + 1))).toBeNull();
    expect(safeMessage("riadok 1\nriadok 2")).toBeNull();
    expect(safeMessage("tab\tznak")).toBeNull();
    expect(safeMessage("skrytý\u200bznak")).toBeNull();
    expect(safeMessage("obrátené \u202epísmo")).toBeNull();
    expect(safeMessage("\u0085začiatok")).toBeNull();
    expect(safeMessage(" medzera")).toBeNull();
    expect(safeMessage("medzera ")).toBeNull();
    expect(safeMessage(null)).toBeNull();
    expect(safeMessage(42)).toBeNull();
    expect(safeMessage({ toString: () => "text" })).toBeNull();
  });
  it("HTML a odkaz prejdú ako obyčajný text (zobrazí sa doslova), nič sa nevykoná", () => {
    expect(safeMessage("<script>alert(1)</script>")).toBe("<script>alert(1)</script>");
  });
});

describe("parseNotice", () => {
  it("prečíta stavy a nebezpečnú adresu zahodí, stav ponechá", () => {
    expect(
      parseNotice({
        version: 1,
        users: {
          [A]: { state: "moved", url: "https://novy.example.test", since: "x" },
          [B]: { state: "transferring", url: "javascript:alert(1)" },
        },
      }),
    ).toEqual({
      [A]: { state: "moved", url: "https://novy.example.test", message: null },
      [B]: { state: "transferring", url: null, message: null },
    });
  });
  it("stav ended a správa (migrácia 0020); nebezpečná správa sa zahodí, stav ostane", () => {
    expect(
      parseNotice({
        version: 1,
        users: {
          [A]: { state: "ended", url: null, message: "Testovanie sa ukončilo.", since: "x" },
          [B]: { state: "ended", message: "dva\nriadky" },
          [C]: { state: "moved", url: "https://novy.example.test", message: 42 },
        },
      }),
    ).toEqual({
      [A]: { state: "ended", url: null, message: "Testovanie sa ukončilo." },
      [B]: { state: "ended", url: null, message: null },
      [C]: { state: "moved", url: "https://novy.example.test", message: null },
    });
  });
  it("odpoveď servera bez migrácie 0020 (bez poľa message) sa číta ako bez správy", () => {
    expect(
      parseNotice({ users: { [A]: { state: "transferring", url: "https://novy.example.test" } } }),
    ).toEqual({ [A]: { state: "transferring", url: "https://novy.example.test", message: null } });
  });
  it("neznámy tvar je chyba, nie prázdny oznam", () => {
    expect(parseNotice(null)).toBeNull();
    expect(parseNotice({})).toBeNull();
    expect(parseNotice({ users: { [A]: { state: "deleted" } } })).toBeNull();
    expect(parseNotice("<html>proxy</html>")).toBeNull();
  });
  it("kľúč, ktorý nie je id účtu, sa vynechá", () => {
    expect(parseNotice({ users: { __proto__x: { state: "moved" } } })).toEqual({});
  });
});

describe("stav prenosu podľa účtu", () => {
  it("zámok poznaný z odpovede na razenie nastaví transferring bez dopytu; prijatie ho zruší", () => {
    const store = memory();
    const seen = vi.fn();
    subscribeMove(seen);
    noteTransferLock(A, store);
    expect(getMoveSnapshot(store)).toEqual({
      [A]: { state: "transferring", url: null, message: null },
    });
    expect(seen).toHaveBeenCalledTimes(1);
    noteTransferLock(A, store);
    expect(seen).toHaveBeenCalledTimes(1);
    noteAccepted(B, store);
    expect(seen).toHaveBeenCalledTimes(1);
    noteAccepted(A, store);
    expect(getMoveSnapshot(store)).toEqual({});
    expect(seen).toHaveBeenCalledTimes(2);
  });

  it("stav moved sa zámkom neprepíše", async () => {
    const store = memory();
    const rpc = vi
      .fn()
      .mockResolvedValue(answer({ [A]: { state: "moved", url: "https://novy.example.test" } }));
    await checkMoveNotice({ rpc } as NoticeClient, [A], { store, online });
    noteTransferLock(A, store);
    expect(getMoveSnapshot(store)[A]).toEqual({
      state: "moved",
      url: "https://novy.example.test",
      message: null,
    });
  });

  it("dopyt pošle len id účtov (zoradené, bez duplicít a neplatných) a odpoveď nahradí stav práve týchto účtov", async () => {
    const store = memory();
    noteTransferLock(C, store);
    const rpc = vi.fn().mockResolvedValue(answer({ [A]: { state: "moved", url: null } }));
    expect(
      await checkMoveNotice({ rpc } as NoticeClient, [B, A, B, "user-a", ""], { store, online }),
    ).toBe("checked");
    expect(rpc).toHaveBeenCalledWith("punch_move_notice", { _users: [A, B] });
    expect(getMoveSnapshot(store)).toEqual({
      [A]: { state: "moved", url: null, message: null },
      [C]: { state: "transferring", url: null, message: null },
    });
  });

  it("účet, ktorý v odpovedi nie je, sa prestane hlásiť (organizácia sa vrátila alebo prenos zrušili)", async () => {
    const store = memory();
    let t = 1_000_000;
    const now = () => t;
    const rpc = vi
      .fn()
      .mockResolvedValueOnce(answer({ [A]: { state: "moved", url: null } }))
      .mockResolvedValue(answer({}));
    await checkMoveNotice({ rpc } as NoticeClient, [A], { store, online, now });
    expect(getMoveSnapshot(store)[A]?.state).toBe("moved");
    t += CHECK_INTERVAL_MS + 1;
    await checkMoveNotice({ rpc } as NoticeClient, [A], { store, online, now });
    expect(getMoveSnapshot(store)).toEqual({});
  });

  it("žiadne zbytočné dopyty: prázdny zoznam, bez siete a v odstupe sa neposiela nič; ručná kontrola odstup obíde", async () => {
    const store = memory();
    let t = 5_000_000;
    const now = () => t;
    const rpc = vi.fn().mockResolvedValue(answer({}));
    expect(await checkMoveNotice({ rpc } as NoticeClient, [], { store, online, now })).toBe(
      "skipped",
    );
    expect(
      await checkMoveNotice({ rpc } as NoticeClient, [A], { store, online: () => false, now }),
    ).toBe("skipped");
    expect(rpc).not.toHaveBeenCalled();
    expect(await checkMoveNotice({ rpc } as NoticeClient, [A], { store, online, now })).toBe(
      "checked",
    );
    t += CHECK_INTERVAL_MS - 1;
    expect(await checkMoveNotice({ rpc } as NoticeClient, [A], { store, online, now })).toBe(
      "skipped",
    );
    expect(await checkMoveNotice({ rpc } as NoticeClient, [B], { store, online, now })).toBe(
      "skipped",
    );
    expect(rpc).toHaveBeenCalledTimes(1);
    expect(
      await checkMoveNotice({ rpc } as NoticeClient, [A], { store, online, now, force: true }),
    ).toBe("checked");
    t += CHECK_INTERVAL_MS + 1;
    expect(await checkMoveNotice({ rpc } as NoticeClient, [A], { store, online, now })).toBe(
      "checked",
    );
    expect(rpc).toHaveBeenCalledTimes(3);
  });

  it("chyba spojenia, chýbajúca funkcia alebo stránka proxy stav nemení a ďalší pokus je až po odstupe", async () => {
    const store = memory();
    let t = 9_000_000;
    const now = () => t;
    const ok = vi.fn().mockResolvedValue(answer({ [A]: { state: "moved", url: null } }));
    await checkMoveNotice({ rpc: ok } as NoticeClient, [A], { store, online, now });
    const failing = [
      vi.fn().mockRejectedValue(new TypeError("Failed to fetch")),
      vi.fn().mockResolvedValue({
        data: null,
        error: { code: "PGRST202", message: "Could not find the function" },
      }),
      vi.fn().mockResolvedValue({ data: "<html>proxy</html>", error: null }),
    ];
    for (const rpc of failing) {
      t += CHECK_INTERVAL_MS + 1;
      expect(await checkMoveNotice({ rpc } as NoticeClient, [A], { store, online, now })).toBe(
        "failed",
      );
      expect(getMoveSnapshot(store)[A]?.state).toBe("moved");
      expect(await checkMoveNotice({ rpc } as NoticeClient, [A], { store, online, now })).toBe(
        "skipped",
      );
      expect(rpc).toHaveBeenCalledTimes(1);
    }
  });

  it("najviac 50 účtov v jednom dopyte", async () => {
    const store = memory();
    const ids = Array.from(
      { length: 70 },
      (_, i) => `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`,
    );
    const rpc = vi.fn().mockResolvedValue(answer({}));
    await checkMoveNotice({ rpc } as NoticeClient, ids, { store, online });
    expect((rpc.mock.calls[0]![1] as { _users: string[] })._users).toHaveLength(MAX_NOTICE_USERS);
  });

  it("stav aj čas poslednej kontroly prežijú nové načítanie stránky; poškodená kópia sa zahodí", async () => {
    const store = memory();
    const t = 7_000_000;
    const rpc = vi
      .fn()
      .mockResolvedValue(answer({ [A]: { state: "moved", url: "https://novy.example.test" } }));
    await checkMoveNotice({ rpc } as NoticeClient, [A], { store, online, now: () => t });
    expect(JSON.parse(store.data.get(MOVE_STORAGE_KEY)!)).toEqual({
      checkedAt: t,
      users: { [A]: { state: "moved", url: "https://novy.example.test", message: null } },
    });
    resetMoveStateForTests();
    expect(getMoveSnapshot(store)).toEqual({
      [A]: { state: "moved", url: "https://novy.example.test", message: null },
    });
    expect(
      await checkMoveNotice({ rpc } as NoticeClient, [A], { store, online, now: () => t + 1000 }),
    ).toBe("skipped");
    resetMoveStateForTests();
    expect(getMoveSnapshot(memory({ [MOVE_STORAGE_KEY]: "{zle" }))).toEqual({});
    resetMoveStateForTests();
    // podvrhnutá adresa v úložisku sa neukáže
    expect(
      getMoveSnapshot(
        memory({
          [MOVE_STORAGE_KEY]: JSON.stringify({
            checkedAt: 1,
            users: { [A]: { state: "moved", url: "javascript:alert(1)" } },
          }),
        }),
      ),
    ).toEqual({ [A]: { state: "moved", url: null, message: null } });
  });

  it("stav ended a správa prežijú nové načítanie; kópia z verzie pred 0020 (bez správy) sa načíta a nebezpečná správa v úložisku sa neukáže", () => {
    const store = memory({
      [MOVE_STORAGE_KEY]: JSON.stringify({
        checkedAt: 1,
        users: {
          [A]: { state: "ended", url: null, message: "Testovanie sa ukončilo." },
          [B]: { state: "moved", url: "https://novy.example.test" },
          [C]: { state: "ended", url: null, message: "zlé\u202e" },
        },
      }),
    });
    expect(getMoveSnapshot(store)).toEqual({
      [A]: { state: "ended", url: null, message: "Testovanie sa ukončilo." },
      [B]: { state: "moved", url: "https://novy.example.test", message: null },
      [C]: { state: "ended", url: null, message: null },
    });
  });

  it("odpoveď so zmenenou len správou sa zapíše (porovnanie berie do úvahy aj správu)", async () => {
    const store = memory();
    const rpc = vi
      .fn()
      .mockResolvedValueOnce(answer({ [A]: { state: "ended", message: "prvá" } }))
      .mockResolvedValueOnce(answer({ [A]: { state: "ended", message: "druhá" } }));
    await checkMoveNotice({ rpc } as NoticeClient, [A], {
      store,
      online,
      now: () => CHECK_INTERVAL_MS + 10,
    });
    expect(getMoveSnapshot(store)[A]?.message).toBe("prvá");
    await checkMoveNotice({ rpc } as NoticeClient, [A], {
      store,
      online,
      now: () => 2 * CHECK_INTERVAL_MS + 20,
    });
    expect(getMoveSnapshot(store)[A]?.message).toBe("druhá");
  });

  it("forgetMove zabudne len vymenované účty", () => {
    const store = memory();
    noteTransferLock(A, store);
    noteTransferLock(B, store);
    forgetMove([A], store);
    expect(Object.keys(getMoveSnapshot(store))).toEqual([B]);
  });
});
