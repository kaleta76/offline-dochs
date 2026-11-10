import { describe, expect, it } from "vitest";
import {
  MAX_FAILURES,
  MAX_HOURS,
  NET_LOG_KEY,
  addToState,
  buildReport,
  classifyOutcome,
  createNetLog,
  describeRequest,
  emptyState,
  formatTime,
  hourKey,
  installNetworkLog,
  maskQuery,
  parseState,
  probeHistoryLines,
  readBodyInfo,
  runProbe,
  runProbes,
  summarize,
  type NetFailure,
  type NetLogStorage,
  type NetWindow,
  type ProbeDef,
  type ProbeResult,
} from "./net-log";

const T0 = new Date(2026, 10, 10, 13, 45, 12).getTime();
const DB = "https://db.example.test";
const SAP = "9000001";
const UID = "11111111-1111-4111-8111-111111111111";

function memoryStorage(): NetLogStorage & { data: Map<string, string>; writes: number } {
  const data = new Map<string, string>();
  const s = {
    data,
    writes: 0,
    getItem: (k: string) => data.get(k) ?? null,
    setItem(k: string, v: string) {
      s.writes += 1;
      data.set(k, v);
    },
    removeItem: (k: string) => void data.delete(k),
  };
  return s;
}

const failure = (over: Partial<NetFailure> = {}): NetFailure => ({
  t: T0,
  method: "GET",
  host: "db",
  path: "/rest/v1/user_roles",
  query: "select=user_id,role",
  status: null,
  kind: "network",
  ms: 7,
  ...over,
});

describe("classifyOutcome", () => {
  it("výnimka fetch je zlyhanie spojenia, bez siete offline, certifikát osobitne", () => {
    expect(classifyOutcome({ status: null, thrown: true, message: "TypeError: Failed to fetch" })).toBe("network");
    expect(classifyOutcome({ status: 0, message: "TypeError: Failed to fetch" })).toBe("network");
    expect(classifyOutcome({ status: null, thrown: true, message: "Failed to fetch", offline: true })).toBe("offline");
    expect(classifyOutcome({ status: null, thrown: true, message: "net::ERR_CERT_AUTHORITY_INVALID" })).toBe("certificate");
  });

  it("úspech je ok, HTML stránka namiesto odpovede je proxy", () => {
    expect(classifyOutcome({ status: 200, contentType: "application/json; charset=utf-8" })).toBe("ok");
    expect(classifyOutcome({ status: 204 })).toBe("ok");
    expect(classifyOutcome({ status: 200, contentType: "text/html; charset=utf-8" })).toBe("proxy");
  });

  it("403 bez kódu databázy je proxy, 403 s kódom alebo s JSON telom je databáza", () => {
    expect(classifyOutcome({ status: 403, code: null, message: "<html><title>Blocked</title></html>" })).toBe("proxy");
    expect(classifyOutcome({ status: 403 })).toBe("proxy");
    expect(classifyOutcome({ status: 403, code: "42501" })).toBe("app");
    expect(classifyOutcome({ status: 403, code: "json" })).toBe("app");
    expect(classifyOutcome({ status: 403, code: "session_not_found" })).toBe("app");
  });

  it("502 a 504 sú brána, ostatné 5xx server, 4xx s kódom chyba aplikácie", () => {
    expect(classifyOutcome({ status: 502 })).toBe("proxy");
    expect(classifyOutcome({ status: 504 })).toBe("proxy");
    expect(classifyOutcome({ status: 500, code: "XX000" })).toBe("server");
    expect(classifyOutcome({ status: 503 })).toBe("server");
    expect(classifyOutcome({ status: 401, code: "bad_jwt" })).toBe("app");
    expect(classifyOutcome({ status: 404, code: "PGRST202" })).toBe("app");
    expect(classifyOutcome({ status: 409, code: "23505" })).toBe("app");
  });

  it("HTML v chybovej odpovedi je proxy aj pri inom stave 4xx", () => {
    expect(classifyOutcome({ status: 400, message: "<!DOCTYPE html><html><body>x</body></html>" })).toBe("proxy");
  });
});

describe("readBodyInfo", () => {
  it("z JSON vyberie len kód", () => {
    expect(readBodyInfo('{"code":"42501","message":"permission denied for table profiles","details":null}')).toEqual({
      code: "42501",
      json: true,
      title: null,
    });
    expect(readBodyInfo('{"code":403,"error_code":"session_not_found","msg":"x"}').code).toBe("403");
    expect(readBodyInfo('{"error_code":"bad_jwt","msg":"x"}').code).toBe("bad_jwt");
    expect(readBodyInfo('{"message":"x"}')).toEqual({ code: "json", json: true, title: null });
  });

  it("z HTML vyberie len názov stránky, najviac 80 znakov", () => {
    const html = `<html><head><title>  Web Page   Blocked  </title></head><body>Reason: user ${SAP} ${UID}</body></html>`;
    const info = readBodyInfo(html);
    expect(info).toEqual({ code: null, json: false, title: "Web Page Blocked" });
    expect(readBodyInfo(`<title>${"x".repeat(150)}</title>`).title).toHaveLength(80);
  });

  it("text bez názvu ani JSON nedá nič", () => {
    expect(readBodyInfo("Forbidden")).toEqual({ code: null, json: false, title: null });
    expect(readBodyInfo("{not json")).toEqual({ code: null, json: false, title: null });
    expect(readBodyInfo("")).toEqual({ code: null, json: false, title: null });
  });
});

describe("describeRequest", () => {
  const hosts = { db: "db.example.test", app: "app.example.test" };

  it("nahradí hodnoty filtrov hviezdičkou, názvy stĺpcov ponechá", () => {
    const info = describeRequest(
      `${DB}/rest/v1/profiles?select=id,sap_id&id=eq.${UID}&sap_id=eq.${SAP}&client_time=gte.2026-11-01T00:00:00.000Z&order=sap_id&limit=5`,
      "get",
      hosts,
    );
    expect(info).toEqual({
      method: "GET",
      host: "db",
      path: "/rest/v1/profiles",
      query: "select=id,sap_id&id=eq.*&sap_id=eq.*&client_time=gte.*&order=sap_id&limit=5",
    });
  });

  it("zoznamy a zložené filtre sa zamaskujú celé", () => {
    expect(maskQuery(new URLSearchParams(`punch_id=in.(1,2,3)&or=(sap_id.eq.${SAP},id.eq.${UID})&status=eq.pending`))).toBe(
      "punch_id=in.*&or=*&status=eq.*",
    );
    expect(maskQuery(new URLSearchParams(`email=${"a".repeat(20)}@firma.sk&token=abc`))).toBe("email=*&token=*");
  });

  it("identifikátory v ceste sa zamaskujú", () => {
    const info = describeRequest(`${DB}/storage/v1/object/${UID}/12345678.png`, "POST", hosts);
    expect(info?.path).toBe("/storage/v1/object/:id/:n.png");
  });

  it("odlišuje databázu a aplikáciu, iné adresy nesleduje, relatívna adresa patrí aplikácii", () => {
    expect(describeRequest("https://app.example.test/_serverFn/abc", "POST", hosts)?.host).toBe("app");
    expect(describeRequest("/manifest.webmanifest", "GET", hosts)?.host).toBe("app");
    expect(describeRequest("https://fonts.googleapis.com/css2?family=Archivo", "GET", hosts)).toBeNull();
    expect(describeRequest("http://", "GET", hosts)).toBeNull();
  });

  it("výstup neobsahuje osobné číslo ani identifikátor používateľa", () => {
    const info = describeRequest(`${DB}/rest/v1/punches?user_id=eq.${UID}&sap_id=eq.${SAP}`, "GET", hosts);
    const text = JSON.stringify(info);
    expect(text.includes(SAP)).toBe(false);
    expect(text.includes(UID)).toBe(false);
  });
});

describe("stav záznamu", () => {
  it("pripočíta počítadlá a zoradí zlyhania", () => {
    const a = addToState(emptyState(), {
      hours: { "2026-11-10T11": { ok: 5, failed: 1, app: 0 } },
      failures: [failure({ t: T0 + 10 })],
    });
    const b = addToState(a, {
      hours: { "2026-11-10T11": { ok: 2, failed: 0, app: 1 }, "2026-11-10T12": { ok: 1, failed: 0, app: 0 } },
      failures: [failure({ t: T0 })],
    });
    expect(b.hours["2026-11-10T11"]).toEqual({ ok: 7, failed: 1, app: 1 });
    expect(b.hours["2026-11-10T12"]).toEqual({ ok: 1, failed: 0, app: 0 });
    expect(b.failures.map((f) => f.t)).toEqual([T0, T0 + 10]);
  });

  it("ponechá len posledných 100 zlyhaní a 168 hodín", () => {
    const failures = Array.from({ length: MAX_FAILURES + 20 }, (_, i) => failure({ t: T0 + i }));
    const hours: Record<string, { ok: number; failed: number; app: number }> = {};
    for (let i = 0; i < MAX_HOURS + 5; i++) hours[`2026-01-01T00-${String(i).padStart(4, "0")}`] = { ok: 1, failed: 0, app: 0 };
    const s = addToState(emptyState(), { hours, failures });
    expect(s.failures).toHaveLength(MAX_FAILURES);
    expect(s.failures[0]?.t).toBe(T0 + 20);
    expect(Object.keys(s.hours)).toHaveLength(MAX_HOURS);
  });

  it("poškodený alebo cudzí obsah úložiska sa zahodí", () => {
    expect(parseState(null)).toEqual(emptyState());
    expect(parseState("")).toEqual(emptyState());
    expect(parseState("{nie json")).toEqual(emptyState());
    expect(parseState(JSON.stringify({ v: 2, hours: {}, failures: [] }))).toEqual(emptyState());
    expect(parseState(JSON.stringify({ v: 1, hours: {}, failures: [{ t: "zle" }] }))).toEqual(emptyState());
    const ok = addToState(emptyState(), { hours: { "2026-11-10T11": { ok: 1, failed: 1, app: 0 } }, failures: [failure()] });
    expect(parseState(JSON.stringify(ok))).toEqual(ok);
  });

  it("súhrn spočíta počítadlá a druhy zlyhaní", () => {
    const s = addToState(emptyState(), {
      hours: { "2026-11-10T11": { ok: 8, failed: 2, app: 1 }, "2026-11-10T12": { ok: 2, failed: 0, app: 0 } },
      failures: [failure({ kind: "network" }), failure({ t: T0 + 1, kind: "proxy", status: 403 })],
    });
    const sum = summarize(s);
    expect(sum.total).toBe(13);
    expect(sum.ok).toBe(10);
    expect(sum.failed).toBe(2);
    expect(sum.app).toBe(1);
    expect(sum.byKind.network).toBe(1);
    expect(sum.byKind.proxy).toBe(1);
    expect(sum.since).toBe("2026-11-10T11");
  });

  it("čas a kľúč hodiny v miestnom čase", () => {
    expect(hourKey(T0)).toBe("2026-11-10T13");
    expect(formatTime(T0)).toBe("2026-11-10 13:45:12");
  });
});

describe("createNetLog", () => {
  it("úspešné dopyty sa nezapisujú po jednom, zlyhanie zapíše aj čakajúce počítadlá", () => {
    const storage = memoryStorage();
    const log = createNetLog({ storage, now: () => T0 });
    log.recordOk();
    log.recordOk();
    log.recordApp();
    expect(storage.writes).toBe(0);
    log.recordFailure({ method: "GET", host: "db", path: "/rest/v1/user_roles", query: "select=user_id,role", status: null, kind: "network", ms: 7 });
    expect(storage.writes).toBe(1);
    const s = parseState(storage.data.get(NET_LOG_KEY));
    expect(s.hours["2026-11-10T13"]).toEqual({ ok: 2, failed: 1, app: 1 });
    expect(s.failures).toHaveLength(1);
    expect(s.failures[0]?.t).toBe(T0);
  });

  it("naplánovaný zápis počítadiel a čítanie ich zapíše", () => {
    const storage = memoryStorage();
    const queue: (() => void)[] = [];
    const log = createNetLog({ storage, now: () => T0, schedule: (fn) => void queue.push(fn) });
    log.recordOk();
    log.recordOk();
    expect(queue).toHaveLength(1);
    expect(storage.writes).toBe(0);
    queue[0]?.();
    expect(storage.writes).toBe(1);
    log.recordOk();
    expect(log.read().hours["2026-11-10T13"]).toEqual({ ok: 3, failed: 0, app: 0 });
  });

  it("dve karty so spoločným úložiskom o seba neprídu", () => {
    const storage = memoryStorage();
    let ta = T0;
    const a = createNetLog({ storage, now: () => ta });
    const b = createNetLog({ storage, now: () => T0 + 5 });
    a.recordFailure({ method: "GET", host: "db", path: "/a", query: "", status: null, kind: "network", ms: 1 });
    b.recordFailure({ method: "GET", host: "db", path: "/b", query: "", status: 403, kind: "proxy", ms: 2 });
    ta = T0 + 10;
    a.recordFailure({ method: "POST", host: "db", path: "/c", query: "", status: null, kind: "network", ms: 3 });
    const s = a.read();
    expect(s.failures.map((f) => f.path)).toEqual(["/a", "/b", "/c"]);
    expect(summarize(s).failed).toBe(3);
  });

  it("nedostupné úložisko nezhodí nič a záznam ostane v pamäti", () => {
    const broken: NetLogStorage = {
      getItem() {
        throw new Error("zakázané");
      },
      setItem() {
        throw new Error("plné");
      },
      removeItem() {
        throw new Error("zakázané");
      },
    };
    const log = createNetLog({ storage: broken, now: () => T0 });
    log.recordFailure({ method: "GET", host: "db", path: "/a", query: "", status: null, kind: "network", ms: 1 });
    log.recordFailure({ method: "GET", host: "db", path: "/b", query: "", status: null, kind: "network", ms: 1 });
    expect(log.read().failures).toHaveLength(2);
    log.clear();
    expect(log.read().failures).toHaveLength(0);
  });

  it("vymazanie odstráni záznam z úložiska", () => {
    const storage = memoryStorage();
    const log = createNetLog({ storage, now: () => T0 });
    log.recordFailure({ method: "GET", host: "db", path: "/a", query: "", status: null, kind: "network", ms: 1 });
    expect(storage.data.has(NET_LOG_KEY)).toBe(true);
    log.clear();
    expect(storage.data.has(NET_LOG_KEY)).toBe(false);
    expect(log.read().failures).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------------------------
// fetch
// ---------------------------------------------------------------------------------------------

type FetchFn = NetWindow["fetch"];

function fakeWin(impl: FetchFn, onLine = true) {
  const listeners: Record<string, (() => void)[]> = {};
  const win = {
    fetch: impl,
    location: { host: "app.example.test" },
    navigator: { onLine },
    addEventListener(type: string, listener: () => void) {
      (listeners[type] ??= []).push(listener);
    },
  };
  return { win, listeners };
}

const tick = () => new Promise<void>((r) => setTimeout(r, 0));

function setup(impl: FetchFn, onLine = true) {
  const storage = memoryStorage();
  const { win, listeners } = fakeWin(impl, onLine);
  const original = win.fetch;
  let clock = 0;
  const handle = installNetworkLog({ win, backendUrl: DB, storage, now: () => T0, clock: () => (clock += 7) });
  return { win, listeners, storage, handle, original };
}

describe("installNetworkLog", () => {
  it("úspešnú odpoveď vráti nezmenenú a len ju započíta", async () => {
    const response = new Response('[{"user_id":"x"}]', { status: 200, headers: { "content-type": "application/json" } });
    const { win, handle } = setup(async () => response);
    try {
      const res = await win.fetch(`${DB}/rest/v1/user_roles?select=user_id,role`);
      expect(res === response).toBe(true);
      expect(await res.text()).toBe('[{"user_id":"x"}]');
      const s = handle.log.read();
      expect(s.hours["2026-11-10T13"]).toEqual({ ok: 1, failed: 0, app: 0 });
      expect(s.failures).toHaveLength(0);
    } finally {
      handle.uninstall();
    }
  });

  it("zlyhanie spojenia zapíše tvar dopytu bez hodnôt a vyhodí tú istú chybu", async () => {
    const boom = new TypeError("Failed to fetch");
    const { win, handle } = setup(async () => {
      throw boom;
    });
    try {
      let caught: unknown = null;
      try {
        await win.fetch(`${DB}/rest/v1/profiles?select=id,sap_id&id=eq.${UID}&sap_id=eq.${SAP}`, { method: "GET" });
      } catch (e) {
        caught = e;
      }
      expect(caught === boom).toBe(true);
      const s = handle.log.read();
      expect(s.failures).toHaveLength(1);
      const f = s.failures[0];
      expect(f?.kind).toBe("network");
      expect(f?.status).toBeNull();
      expect(f?.method).toBe("GET");
      expect(f?.path).toBe("/rest/v1/profiles");
      expect(f?.query).toBe("select=id,sap_id&id=eq.*&sap_id=eq.*");
      expect(f?.ms).toBe(7);
      expect(f?.note).toBe("Failed to fetch");
      const stored = storageText(s);
      expect(stored.includes(SAP)).toBe(false);
      expect(stored.includes(UID)).toBe(false);
    } finally {
      handle.uninstall();
    }
  });

  it("zrušený dopyt, odpojená sieť a cudzie adresy sa nezapisujú", async () => {
    const abort = Object.assign(new Error("The operation was aborted."), { name: "AbortError" });
    let mode: "abort" | "fail" | "ok" = "abort";
    const { win, handle } = setup(async () => {
      if (mode === "abort") throw abort;
      if (mode === "fail") throw new TypeError("Failed to fetch");
      return new Response("x");
    });
    const offline = setup(async () => {
      throw new TypeError("Failed to fetch");
    }, false);
    try {
      await win.fetch(`${DB}/rest/v1/user_roles`).catch(() => undefined);
      mode = "fail";
      await win.fetch("https://fonts.googleapis.com/css2?family=Archivo").catch(() => undefined);
      mode = "ok";
      await win.fetch("https://fonts.googleapis.com/css2?family=Archivo");
      expect(summarize(handle.log.read()).total).toBe(0);
      await offline.win.fetch(`${DB}/rest/v1/user_roles`).catch(() => undefined);
      expect(summarize(offline.handle.log.read()).total).toBe(0);
    } finally {
      handle.uninstall();
      offline.handle.uninstall();
    }
  });

  it("403 s JSON telom je chyba databázy, nie proxy", async () => {
    const { win, handle } = setup(
      async () => new Response('{"code":"42501","message":"permission denied for table profiles"}', { status: 403, headers: { "content-type": "application/json" } }),
    );
    try {
      const res = await win.fetch(`${DB}/rest/v1/profiles?id=eq.${UID}`);
      expect(res.status).toBe(403);
      expect(await res.text()).toBe('{"code":"42501","message":"permission denied for table profiles"}');
      await tick();
      const s = handle.log.read();
      expect(s.failures).toHaveLength(0);
      expect(s.hours["2026-11-10T13"]).toEqual({ ok: 0, failed: 0, app: 1 });
    } finally {
      handle.uninstall();
    }
  });

  it("403 s HTML stránkou je proxy a zapíše sa názov stránky, telo ostane čitateľné pre volajúceho", async () => {
    const html = `<html><head><title>Web Page Blocked</title></head><body>${SAP}</body></html>`;
    const { win, handle } = setup(async () => new Response(html, { status: 403, headers: { "content-type": "text/html" } }));
    try {
      const res = await win.fetch(`${DB}/rest/v1/user_roles?select=user_id,role`);
      expect(await res.text()).toBe(html);
      await tick();
      const s = handle.log.read();
      expect(s.failures).toHaveLength(1);
      expect(s.failures[0]?.kind).toBe("proxy");
      expect(s.failures[0]?.status).toBe(403);
      expect(s.failures[0]?.note).toBe("title: Web Page Blocked");
      expect(storageText(s).includes(SAP)).toBe(false);
    } finally {
      handle.uninstall();
    }
  });

  it("HTML namiesto odpovede databázy pri stave 200 je proxy", async () => {
    const { win, handle } = setup(async () => new Response("<html></html>", { status: 200, headers: { "content-type": "text/html" } }));
    try {
      await win.fetch(`${DB}/rest/v1/rpc/get_my_profile`, { method: "POST", body: "{}" });
      const s = handle.log.read();
      expect(s.failures).toHaveLength(1);
      expect(s.failures[0]?.kind).toBe("proxy");
      expect(s.failures[0]?.method).toBe("POST");
      expect(s.failures[0]?.path).toBe("/rest/v1/rpc/get_my_profile");
    } finally {
      handle.uninstall();
    }
  });

  it("502 je proxy, 500 server", async () => {
    let status = 502;
    const { win, handle } = setup(async () => new Response("Bad Gateway", { status }));
    try {
      await win.fetch(`${DB}/rest/v1/rpc/calc_settings`, { method: "POST" });
      await tick();
      status = 500;
      await win.fetch(`${DB}/rest/v1/rpc/calc_settings`, { method: "POST" });
      await tick();
      expect(handle.log.read().failures.map((f) => f.kind)).toEqual(["proxy", "server"]);
    } finally {
      handle.uninstall();
    }
  });

  it("po zatvorení stránky sa zlyhania nezapisujú", async () => {
    const { win, listeners, handle } = setup(async () => {
      throw new TypeError("Failed to fetch");
    });
    try {
      await win.fetch(`${DB}/rest/v1/user_roles`).catch(() => undefined);
      listeners["pagehide"]?.forEach((fn) => fn());
      await win.fetch(`${DB}/rest/v1/user_roles`).catch(() => undefined);
      expect(handle.log.read().failures).toHaveLength(1);
    } finally {
      handle.uninstall();
    }
  });

  it("opakovaná inštalácia nič nezdvojí a odinštalovanie vráti pôvodný fetch", async () => {
    let calls = 0;
    const { win, handle, original } = setup(async () => {
      calls += 1;
      return new Response("[]", { status: 200 });
    });
    try {
      const again = installNetworkLog({ win, backendUrl: DB, storage: memoryStorage() });
      expect(again === handle).toBe(true);
      await win.fetch(`${DB}/rest/v1/user_roles`);
      expect(calls).toBe(1);
      expect(handle.log.read().hours["2026-11-10T13"]).toEqual({ ok: 1, failed: 0, app: 0 });
    } finally {
      handle.uninstall();
    }
    expect(win.fetch === original).toBe(true);
  });

  it("chyba pri zápise záznamu nezhorší dopyt", async () => {
    const response = new Response("[]", { status: 200 });
    const broken: NetLogStorage = {
      getItem() {
        throw new Error("zakázané");
      },
      setItem() {
        throw new Error("plné");
      },
      removeItem() {
        throw new Error("zakázané");
      },
    };
    const { win } = fakeWin(async () => response);
    const handle = installNetworkLog({ win, backendUrl: DB, storage: broken, now: () => T0 });
    try {
      const res = await win.fetch(`${DB}/rest/v1/user_roles`);
      expect(res === response).toBe(true);
    } finally {
      handle.uninstall();
    }
  });
});

function storageText(s: ReturnType<typeof parseState>): string {
  return JSON.stringify(s);
}

// ---------------------------------------------------------------------------------------------
// Test spojenia a správa
// ---------------------------------------------------------------------------------------------

const probe = (id: string, run: ProbeDef["run"]): ProbeDef => ({ id, label: `Dopyt ${id}`, method: "GET", request: `/rest/v1/${id}`, run });

describe("runProbe a runProbes", () => {
  it("úspech, chyba spojenia, proxy a certifikát sa rozlíšia, výnimka test nezhodí", async () => {
    let clock = 0;
    const c = { now: () => T0, clock: () => (clock += 10) };
    const ok = await runProbe(probe("a", async () => ({ status: 200, note: "riadkov: 55" })), c);
    expect(ok.outcome).toBe("ok");
    expect(ok.ms).toBe(10);
    expect(ok.note).toBe("riadkov: 55");
    expect(ok.at).toBe(T0);

    const closed = await runProbe(probe("b", async () => ({ status: 0, thrown: true, message: "TypeError: Failed to fetch" })), c);
    expect(closed.outcome).toBe("network");
    expect(closed.status).toBe(0);
    expect(closed.note).toBe("TypeError: Failed to fetch");

    const thrown = await runProbe(
      probe("c", async () => {
        throw new TypeError("net::ERR_CERT_AUTHORITY_INVALID");
      }),
      c,
    );
    expect(thrown.outcome).toBe("certificate");

    const blocked = await runProbe(probe("d", async () => ({ status: 403, code: null, message: "<html>blocked</html>" })), c);
    expect(blocked.outcome).toBe("proxy");

    const db = await runProbe(probe("e", async () => ({ status: 403, code: "42501", message: "permission denied" })), c);
    expect(db.outcome).toBe("app");
    expect(db.note).toBeUndefined();

    const off = await runProbe(probe("f", async () => ({ status: 0, thrown: true, message: "Failed to fetch" })), { ...c, offline: () => true });
    expect(off.outcome).toBe("offline");
  });

  it("dopyty bežia po jednom s pauzou a dajú sa prerušiť", async () => {
    const order: string[] = [];
    const sleeps: number[] = [];
    const defs = ["a", "b", "c"].map((id) =>
      probe(id, async () => {
        order.push(id);
        return { status: 200 };
      }),
    );
    const seen: string[] = [];
    const results = await runProbes(defs, {
      pauseMs: 400,
      sleep: async (ms) => void sleeps.push(ms),
      onResult: (r) => void seen.push(r.id),
    });
    expect(results.map((r) => r.id)).toEqual(["a", "b", "c"]);
    expect(order).toEqual(["a", "b", "c"]);
    expect(seen).toEqual(["a", "b", "c"]);
    expect(sleeps).toEqual([400, 400, 400]);

    let n = 0;
    const stopped = await runProbes(defs, { sleep: async () => undefined, shouldStop: () => n++ >= 1 });
    expect(stopped.map((r) => r.id)).toEqual(["a"]);
  });
});

describe("správa pre SOC", () => {
  const result = (id: string, outcome: ProbeResult["outcome"], at = T0): ProbeResult => ({
    id,
    label: `Dopyt ${id}`,
    method: "GET",
    request: `/rest/v1/${id}`,
    at,
    status: outcome === "ok" ? 200 : null,
    ms: 5,
    outcome,
  });

  it("história testu je jeden riadok na dopyt", () => {
    const lines = probeHistoryLines([
      [result("a", "ok"), result("b", "ok")],
      [result("a", "network"), result("b", "ok")],
      [result("a", "ok"), result("b", "proxy")],
    ]);
    expect(lines).toHaveLength(2);
    expect(lines[0]).toMatch(/Dopyt a\s+\.X\.$/);
    expect(lines[1]).toMatch(/Dopyt b\s+\.\.P$/);
  });

  it("správa obsahuje súhrn, hodiny, zlyhania s odstupom a test, bez osobných údajov", () => {
    const state = addToState(emptyState(), {
      hours: { "2026-11-10T11": { ok: 120, failed: 3, app: 2 }, "2026-11-10T12": { ok: 90, failed: 0, app: 0 } },
      failures: [
        failure({ t: T0 }),
        failure({ t: T0 + 4_000, path: "/rest/v1/profiles", query: "select=id,sap_id&id=eq.*", status: 403, kind: "proxy", note: "title: Web Page Blocked" }),
        failure({ t: T0 + 3_600_000, kind: "certificate" }),
      ],
    });
    const text = buildReport(
      state,
      [[result("a", "ok"), result("b", "network")]],
      { now: T0, userAgent: "Mozilla/5.0 (test)", appHost: "app.example.test", dbHost: "db.example.test", online: true },
    );
    expect(text).toContain("DIAGNOSTIKA SPOJENIA");
    expect(text).toContain("Vytvorené: 2026-11-10 13:45:12 (UTC");
    expect(text).toContain("Adresa aplikácie: app.example.test");
    expect(text).toContain("Adresa databázy: db.example.test");
    expect(text).toContain("Dopytov: 215, zlyhalo: 3, chyby aplikácie alebo databázy (nie siete): 2");
    expect(text).toContain("2026-11-10 11:00  dopytov 125, zlyhalo 3");
    expect(text).toContain("?select=id,sap_id&id=eq.*");
    expect(text).toContain("odpoveď proxy alebo brány (HTTP 403, 7 ms, +4 s po predchádzajúcom) [title: Web Page Blocked]");
    expect(text).toContain("certifikát");
    expect(text).toContain("TEST SPOJENIA");
    expect(text).toContain("spojenie zatvorené alebo zlyhalo");
    expect(text.includes(SAP)).toBe(false);
    expect(text.includes(UID)).toBe(false);
  });

  it("odstup pod sekundu sa ukáže v milisekundách", () => {
    const state = addToState(emptyState(), { hours: {}, failures: [failure({ t: T0 }), failure({ t: T0 + 250 })] });
    const text = buildReport(state, [], { now: T0, userAgent: "x", appHost: "a", dbHost: "d" });
    expect(text).toContain(", +250 ms po predchádzajúcom)");
  });

  it("prázdny záznam to povie", () => {
    const text = buildReport(emptyState(), [], { now: T0, userAgent: "x", appHost: "a", dbHost: "" });
    expect(text).toContain("Dopytov: 0, zlyhalo: 0");
    expect(text).toContain("Zlyhania podľa druhu (zo zachovaných posledných 0): žiadne");
    expect(text).toContain("Adresa databázy: neznáma");
    expect(text.includes("TEST SPOJENIA")).toBe(false);
  });
});
