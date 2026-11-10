// Záznam zlyhaných dopytov na server: diagnostika spojenia cez firemný proxy.
//
// Firemný proxy (Fortinet so SSL inšpekciou) niekedy zatvorí spojenie alebo vráti vlastnú stránku. Prehliadač hlási len
// "Failed to fetch", takže bez záznamu sa nedá povedať, ČO a KEDY zlyhalo. Tento modul obalí window.fetch (aplikácia aj
// klient databázy volajú globálne `fetch` až pri každom dopyte, pozri src/integrations/supabase/client.ts) a zapisuje:
//   - počty dopytov po hodinách (úspešné, zlyhané, chyby aplikácie),
//   - posledných 100 zlyhaní: čas, metóda, cesta, tvar dopytu, HTTP stav, druh chyby, trvanie.
// Nezapisuje sa nič osobné: hodnoty filtrov sa nahradia hviezdičkou (`id=eq.*`), neukladá sa telo odpovede (len <title> HTML
// stránky proxy), hlavičky ani tokeny. Záznam je len v tomto prehliadači (localStorage) a dá sa vymazať.
import { z } from "zod";
import { classifySyncError } from "./sync-error";

export const NET_LOG_KEY = "net-log:v1";
export const MAX_FAILURES = 100;
export const MAX_HOURS = 168;

// ---------------------------------------------------------------------------------------------
// Klasifikácia výsledku dopytu
// ---------------------------------------------------------------------------------------------

/** Zlyhanie siete alebo brány; chyby aplikácie (4xx z databázy) sa len počítajú. */
export type FailureKind = "certificate" | "network" | "offline" | "proxy" | "server";
export type Outcome = "ok" | "app" | FailureKind;

export const FAILURE_KINDS: readonly FailureKind[] = ["certificate", "network", "offline", "proxy", "server"];

export const OUTCOME_LABEL: Record<Outcome, string> = {
  ok: "v poriadku",
  app: "chyba aplikácie alebo databázy (nie siete)",
  certificate: "certifikát",
  network: "spojenie zatvorené alebo zlyhalo",
  offline: "prehliadač je offline",
  proxy: "odpoveď proxy alebo brány",
  server: "chyba servera (5xx)",
};

export interface OutcomeInput {
  /** HTTP stav; null alebo 0, ak dopyt vôbec nedostal odpoveď */
  status: number | null;
  /** kód chyby z tela odpovede (PostgREST `code`, auth `error_code`) alebo "json", ak telo je JSON bez kódu */
  code?: string | null;
  /** text chyby (pri odpovedi len z HTML alebo textu, nie z JSON) */
  message?: string | null;
  contentType?: string | null;
  /** dopyt skončil výnimkou (Failed to fetch…) */
  thrown?: boolean;
  offline?: boolean;
}

/**
 * Určí, či dopyt uspel a ak nie, kto ho zrejme zrušil. Odpoveď s JSON telom pochádza z databázy (aj 403), preto sa nepovažuje
 * za proxy. 403 bez kódu, 502, 504 a HTML stránka pri úspešnom dopyte sú typické znaky brány alebo proxy.
 */
export function classifyOutcome(input: OutcomeInput): Outcome {
  const message = (input.message ?? "").slice(0, 300);
  const code = input.code ?? null;
  if (input.thrown || input.status == null || input.status === 0) {
    if (input.offline) return "offline";
    return classifySyncError({ message, code }) === "certificate" ? "certificate" : "network";
  }
  if (input.status < 400) return /text\/html/i.test(input.contentType ?? "") ? "proxy" : "ok";
  const kind = classifySyncError({ message, code }, input.status);
  if (kind === "certificate") return "certificate";
  if (kind === "transport") return "proxy";
  return input.status >= 500 ? "server" : "app";
}

export interface BodyInfo {
  code: string | null;
  json: boolean;
  /** <title> HTML stránky (napr. blokovacej stránky proxy), najviac 80 znakov */
  title: string | null;
}

/** Z tela chybovej odpovede vyberie len kód chyby a názov HTML stránky; nič iné sa neuchováva. */
export function readBodyInfo(text: string): BodyInfo {
  const trimmed = text.trim();
  if (trimmed.startsWith("{")) {
    try {
      const value: unknown = JSON.parse(trimmed);
      if (value && typeof value === "object") {
        const o = value as Record<string, unknown>;
        const raw = [o["code"], o["error_code"]].find((v) => typeof v === "string" || typeof v === "number");
        return { code: raw == null ? "json" : String(raw).slice(0, 40), json: true, title: null };
      }
    } catch {
      /* nie je JSON */
    }
  }
  const m = /<title[^>]*>([^<]{1,200})<\/title>/i.exec(trimmed);
  return { code: null, json: false, title: m?.[1] ? m[1].replace(/\s+/g, " ").trim().slice(0, 80) : null };
}

// ---------------------------------------------------------------------------------------------
// Popis dopytu bez hodnôt
// ---------------------------------------------------------------------------------------------

export interface RequestShape {
  method: string;
  host: "db" | "app";
  path: string;
  query: string;
}

// Hodnoty týchto parametrov sú názvy stĺpcov alebo čísla, nie údaje; ostatné sa nahradia hviezdičkou.
const KEEP_VALUE = new Set(["select", "order", "limit", "offset", "columns", "on_conflict", "grant_type"]);
const OPERATORS = new Set([
  "eq", "neq", "gt", "gte", "lt", "lte", "like", "ilike", "match", "imatch", "in", "is", "isdistinct",
  "fts", "plfts", "phfts", "wfts", "cs", "cd", "ov", "sl", "sr", "nxr", "nxl", "adj", "not", "and", "or",
]);

const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;

/** Tvar dopytu: `select=id,code&client_time=gte.*&order=client_time` (hodnoty filtrov sú nahradené hviezdičkou). */
export function maskQuery(params: URLSearchParams): string {
  const parts: string[] = [];
  params.forEach((value, rawKey) => {
    const key = rawKey.slice(0, 40);
    if (KEEP_VALUE.has(rawKey)) {
      parts.push(`${key}=${value.slice(0, 160)}`);
      return;
    }
    const dot = value.indexOf(".");
    const op = dot > 0 ? value.slice(0, dot) : "";
    parts.push(OPERATORS.has(op) ? `${key}=${op}.*` : `${key}=*`);
  });
  return parts.join("&");
}

/** Popíše dopyt na adresu aplikácie alebo databázy; iné adresy (písma, cudzie servery) sa nesledujú (null). */
export function describeRequest(
  rawUrl: string,
  method: string,
  hosts: { db?: string | undefined; app?: string | undefined },
): RequestShape | null {
  let url: URL;
  try {
    url = new URL(rawUrl, `https://${hosts.app || "localhost"}`);
  } catch {
    return null;
  }
  const host = hosts.db && url.host === hosts.db ? "db" : hosts.app && url.host === hosts.app ? "app" : null;
  if (!host) return null;
  const path = url.pathname.replace(UUID, ":id").replace(/\d{4,}/g, ":n").slice(0, 80);
  return { method: method.toUpperCase(), host, path, query: maskQuery(url.searchParams) };
}

// ---------------------------------------------------------------------------------------------
// Stav záznamu
// ---------------------------------------------------------------------------------------------

const failureSchema = z.object({
  t: z.number(),
  method: z.string(),
  host: z.enum(["db", "app"]),
  path: z.string(),
  query: z.string(),
  status: z.number().nullable(),
  kind: z.enum(["certificate", "network", "offline", "proxy", "server"]),
  ms: z.number(),
  note: z.string().optional(),
});
const hourSchema = z.object({ ok: z.number(), failed: z.number(), app: z.number() });
const stateSchema = z.object({
  v: z.literal(1),
  hours: z.record(z.string(), hourSchema),
  failures: z.array(failureSchema),
});

export type NetFailure = z.infer<typeof failureSchema>;
export type HourCounters = z.infer<typeof hourSchema>;
export type NetLogState = z.infer<typeof stateSchema>;
export interface NetLogDelta {
  hours: Record<string, HourCounters>;
  failures: NetFailure[];
}

export const emptyState = (): NetLogState => ({ v: 1, hours: {}, failures: [] });
const emptyDelta = (): NetLogDelta => ({ hours: {}, failures: [] });
const isEmptyDelta = (d: NetLogDelta) => d.failures.length === 0 && Object.keys(d.hours).length === 0;

/** Načíta uložený záznam; poškodený alebo cudzí obsah sa zahodí a začne sa odznova. */
export function parseState(raw: string | null | undefined): NetLogState {
  if (!raw) return emptyState();
  try {
    const parsed = stateSchema.safeParse(JSON.parse(raw));
    return parsed.success ? parsed.data : emptyState();
  } catch {
    return emptyState();
  }
}

const two = (n: number) => String(n).padStart(2, "0");

/** Kľúč hodiny v miestnom čase: `2026-11-10T13`. */
export function hourKey(t: number): string {
  const d = new Date(t);
  return `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())}T${two(d.getHours())}`;
}

/** Miestny čas `2026-11-10 13:45:12`. */
export function formatTime(t: number): string {
  const d = new Date(t);
  return `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())} ${two(d.getHours())}:${two(d.getMinutes())}:${two(d.getSeconds())}`;
}

/** Pripočíta zmeny k stavu a ohraničí veľkosť (posledných 100 zlyhaní, 168 hodín). */
export function addToState(state: NetLogState, delta: NetLogDelta): NetLogState {
  const hours: Record<string, HourCounters> = {};
  for (const [k, v] of Object.entries(state.hours)) hours[k] = { ...v };
  for (const [k, v] of Object.entries(delta.hours)) {
    const cur = hours[k] ?? { ok: 0, failed: 0, app: 0 };
    hours[k] = { ok: cur.ok + v.ok, failed: cur.failed + v.failed, app: cur.app + v.app };
  }
  const keep = Object.keys(hours).sort().slice(-MAX_HOURS);
  const trimmedHours: Record<string, HourCounters> = {};
  for (const k of keep) {
    const v = hours[k];
    if (v) trimmedHours[k] = v;
  }
  const failures = [...state.failures, ...delta.failures].sort((a, b) => a.t - b.t).slice(-MAX_FAILURES);
  return { v: 1, hours: trimmedHours, failures };
}

export interface NetSummary {
  total: number;
  ok: number;
  failed: number;
  app: number;
  /** počty podľa druhu zo zachovaných posledných zlyhaní */
  byKind: Record<FailureKind, number>;
  /** od prvej zachovanej hodiny, alebo null */
  since: string | null;
}

export function summarize(state: NetLogState): NetSummary {
  let ok = 0;
  let failed = 0;
  let app = 0;
  for (const h of Object.values(state.hours)) {
    ok += h.ok;
    failed += h.failed;
    app += h.app;
  }
  const byKind: Record<FailureKind, number> = { certificate: 0, network: 0, offline: 0, proxy: 0, server: 0 };
  for (const f of state.failures) byKind[f.kind] += 1;
  const first = Object.keys(state.hours).sort()[0] ?? null;
  return { total: ok + failed + app, ok, failed, app, byKind, since: first };
}

// ---------------------------------------------------------------------------------------------
// Záznamník (ukladá do localStorage, spája zmeny z viacerých kariet)
// ---------------------------------------------------------------------------------------------

export interface NetLogStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

export interface NetLog {
  recordOk(): void;
  recordApp(): void;
  recordFailure(f: Omit<NetFailure, "t">): void;
  /** zapíše čakajúce zmeny do úložiska */
  flush(): void;
  /** aktuálny záznam (po zapísaní čakajúcich zmien) */
  read(): NetLogState;
  clear(): void;
}

export interface NetLogOptions {
  storage?: NetLogStorage | undefined;
  now?: () => number;
  /** naplánuje oneskorený zápis počítadiel (úspešné dopyty sa nezapisujú po jednom) */
  schedule?: (fn: () => void) => void;
}

export function createNetLog(opts: NetLogOptions = {}): NetLog {
  const now = opts.now ?? Date.now;
  let pending = emptyDelta();
  let memory = emptyState();
  let scheduled = false;

  function readStored(): NetLogState {
    try {
      if (opts.storage) return parseState(opts.storage.getItem(NET_LOG_KEY));
    } catch {
      /* úložisko nie je dostupné: pracuje sa len v pamäti */
    }
    return memory;
  }

  function flush(): void {
    scheduled = false;
    if (isEmptyDelta(pending)) return;
    const delta = pending;
    pending = emptyDelta();
    const next = addToState(readStored(), delta);
    memory = next;
    try {
      opts.storage?.setItem(NET_LOG_KEY, JSON.stringify(next));
    } catch {
      /* plné alebo zakázané úložisko: záznam ostane aspoň v pamäti stránky */
    }
  }

  function count(kind: keyof HourCounters): void {
    const key = hourKey(now());
    const cur = pending.hours[key] ?? { ok: 0, failed: 0, app: 0 };
    pending.hours[key] = { ...cur, [kind]: cur[kind] + 1 };
    if (opts.schedule && !scheduled) {
      scheduled = true;
      opts.schedule(flush);
    }
  }

  return {
    recordOk: () => count("ok"),
    recordApp: () => count("app"),
    recordFailure(f) {
      count("failed");
      pending.failures.push({ ...f, t: now() });
      flush();
    },
    flush,
    read() {
      flush();
      return readStored();
    },
    clear() {
      pending = emptyDelta();
      memory = emptyState();
      try {
        opts.storage?.removeItem(NET_LOG_KEY);
      } catch {
        /* nič */
      }
    },
  };
}

// ---------------------------------------------------------------------------------------------
// Obalenie fetch
// ---------------------------------------------------------------------------------------------

export interface NetWindow {
  fetch: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;
  location: { host: string };
  navigator?: { onLine?: boolean };
  addEventListener(type: string, listener: () => void): void;
}

export interface InstallOptions {
  win?: NetWindow | undefined;
  /** adresa databázy (VITE_SUPABASE_URL) */
  backendUrl?: string | undefined;
  storage?: NetLogStorage | undefined;
  now?: () => number;
  clock?: () => number;
}

export interface NetLogHandle {
  log: NetLog;
  uninstall(): void;
}

const WRAPPED = Symbol.for("dochadzka.net-log");
let current: NetLogHandle | undefined;

function safeLocalStorage(): NetLogStorage | undefined {
  try {
    return typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
}

/** Záznamník tejto stránky; pred inštaláciou (alebo na serveri) číta len uložený záznam. */
export function getNetLog(): NetLog {
  if (current) return current.log;
  return createNetLog({ storage: safeLocalStorage() });
}

export function backendHostOf(url: string | undefined): string | undefined {
  try {
    return url ? new URL(url).host : undefined;
  } catch {
    return undefined;
  }
}

const urlOf = (input: RequestInfo | URL): string =>
  typeof input === "string" ? input : input instanceof URL ? input.href : input.url;

const methodOf = (input: RequestInfo | URL, init?: RequestInit): string =>
  init?.method ?? (typeof input === "object" && "method" in input ? input.method : "GET");

/**
 * Obalí window.fetch: výsledok dopytu sa zapíše a odovzdá sa volajúcemu nezmenený (rovnaká odpoveď, rovnaká výnimka).
 * Záznam nikdy nesmie zhoršiť samotný dopyt, preto je každý krok záznamu v try/catch. Opakované volanie nič nezdvojí.
 */
export function installNetworkLog(opts: InstallOptions = {}): NetLogHandle {
  const win: NetWindow | undefined = opts.win ?? (typeof window === "undefined" ? undefined : (window as unknown as NetWindow));
  if (!win || typeof win.fetch !== "function") return { log: getNetLog(), uninstall: () => undefined };
  const existing = win.fetch as unknown as Record<symbol, unknown>;
  if (existing[WRAPPED] && current) return current;

  const now = opts.now ?? Date.now;
  const clock = opts.clock ?? (() => (typeof performance === "undefined" ? Date.now() : performance.now()));
  const log = createNetLog({
    storage: opts.storage ?? safeLocalStorage(),
    now,
    schedule: (fn) => {
      setTimeout(fn, 2000);
    },
  });
  const hosts = { db: backendHostOf(opts.backendUrl), app: win.location.host };
  const original = win.fetch;
  let unloading = false;
  try {
    win.addEventListener("pagehide", () => {
      unloading = true;
      log.flush();
    });
    win.addEventListener("visibilitychange", () => log.flush());
  } catch {
    /* nič */
  }

  const fail = (info: RequestShape, outcome: FailureKind, status: number | null, ms: number, note?: string) => {
    log.recordFailure({
      method: info.method,
      host: info.host,
      path: info.path,
      query: info.query,
      status,
      kind: outcome,
      ms,
      ...(note ? { note } : {}),
    });
  };

  const onResponse = (res: Response, info: RequestShape, started: number) => {
    const ms = Math.round(clock() - started);
    const contentType = res.headers.get("content-type");
    if (res.status < 400) {
      if (info.host === "db" && /text\/html/i.test(contentType ?? "")) fail(info, "proxy", res.status, ms, "HTML namiesto odpovede databázy");
      else log.recordOk();
      return;
    }
    const finish = (text: string) => {
      const body = readBodyInfo(text);
      const outcome = classifyOutcome({
        status: res.status,
        code: body.code,
        message: body.json ? "" : text,
        contentType,
      });
      if (outcome === "ok") log.recordOk();
      else if (outcome === "app") log.recordApp();
      else fail(info, outcome, res.status, ms, body.title ? `title: ${body.title}` : undefined);
    };
    // Telo sa číta z kópie, pôvodná odpoveď ide volajúcemu bez zmeny.
    const copy = res.clone();
    copy.text().then(finish, () => finish(""));
  };

  const onError = (error: unknown, info: RequestShape, started: number) => {
    const name = (error as { name?: unknown } | null)?.name;
    if (name === "AbortError" || unloading) return;
    const ms = Math.round(clock() - started);
    const message = String((error as { message?: unknown } | null)?.message ?? error).slice(0, 80);
    const outcome = classifyOutcome({ status: null, thrown: true, message, offline: win.navigator?.onLine === false });
    // Pri vypnutej sieti zlyháva každý dopyt (aj opakované pokusy fronty razení); to nie je porucha, preto sa nezapisuje.
    if (outcome === "ok" || outcome === "app" || outcome === "offline") return;
    fail(info, outcome, null, ms, message);
  };

  const wrapped = function (input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
    let info: RequestShape | null = null;
    try {
      info = describeRequest(urlOf(input), methodOf(input, init), hosts);
    } catch {
      info = null;
    }
    if (!info) return original.call(win, input, init);
    const target = info;
    const started = clock();
    return original.call(win, input, init).then(
      (res) => {
        try {
          onResponse(res, target, started);
        } catch {
          /* záznam nesmie zhodiť dopyt */
        }
        return res;
      },
      (error: unknown) => {
        try {
          onError(error, target, started);
        } catch {
          /* záznam nesmie zhodiť dopyt */
        }
        throw error;
      },
    );
  };
  (wrapped as unknown as Record<symbol, unknown>)[WRAPPED] = true;
  win.fetch = wrapped;

  const handle: NetLogHandle = {
    log,
    uninstall() {
      if (win.fetch === wrapped) win.fetch = original;
      if (current === handle) current = undefined;
    },
  };
  current = handle;
  return handle;
}

// ---------------------------------------------------------------------------------------------
// Test spojenia (súbor známych dopytov; samotné dopyty definuje connection-probes.ts)
// ---------------------------------------------------------------------------------------------

export interface ProbeResponse {
  status: number | null;
  code?: string | null;
  message?: string | null;
  contentType?: string | null;
  /** dopyt skončil výnimkou */
  thrown?: boolean;
  /** krátka poznámka bez osobných údajov (napr. počet riadkov) */
  note?: string;
}

export interface ProbeDef {
  id: string;
  label: string;
  method: "GET" | "POST";
  /** tvar dopytu na zobrazenie (bez hodnôt) */
  request: string;
  run: () => Promise<ProbeResponse>;
}

export interface ProbeResult {
  id: string;
  label: string;
  method: string;
  request: string;
  at: number;
  status: number | null;
  ms: number;
  outcome: Outcome;
  note?: string;
}

export interface ProbeClock {
  now?: () => number;
  clock?: () => number;
  offline?: () => boolean;
}

/** Vykoná jeden dopyt testu; výnimka sa zmení na výsledok, test nikdy nespadne. */
export async function runProbe(def: ProbeDef, c: ProbeClock = {}): Promise<ProbeResult> {
  const now = c.now ?? Date.now;
  const clock = c.clock ?? (() => (typeof performance === "undefined" ? Date.now() : performance.now()));
  const at = now();
  const started = clock();
  let res: ProbeResponse;
  try {
    res = await def.run();
  } catch (error) {
    res = { status: null, thrown: true, message: String((error as { message?: unknown } | null)?.message ?? error).slice(0, 80) };
  }
  const ms = Math.round(clock() - started);
  const outcome = classifyOutcome({
    status: res.status,
    code: res.code ?? null,
    message: res.message ?? null,
    contentType: res.contentType ?? null,
    thrown: res.thrown ?? false,
    offline: c.offline ? c.offline() : false,
  });
  const note = res.note ?? (outcome === "ok" || outcome === "app" ? undefined : (res.message ?? "").slice(0, 80));
  return {
    id: def.id,
    label: def.label,
    method: def.method,
    request: def.request,
    at,
    status: res.status,
    ms,
    outcome,
    ...(note ? { note } : {}),
  };
}

/** Vykoná dopyty jeden po druhom s krátkou pauzou (ako konzolový test); `shouldStop` preruší beh. */
export async function runProbes(
  defs: readonly ProbeDef[],
  opts: {
    pauseMs?: number;
    sleep?: (ms: number) => Promise<void>;
    onResult?: (r: ProbeResult) => void;
    shouldStop?: () => boolean;
  } & ProbeClock = {},
): Promise<ProbeResult[]> {
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const results: ProbeResult[] = [];
  for (const def of defs) {
    if (opts.shouldStop?.()) break;
    const r = await runProbe(def, opts);
    results.push(r);
    opts.onResult?.(r);
    if ((opts.pauseMs ?? 0) > 0) await sleep(opts.pauseMs ?? 0);
  }
  return results;
}

// ---------------------------------------------------------------------------------------------
// Správa pre kybernetické oddelenie (SOC)
// ---------------------------------------------------------------------------------------------

export interface ReportEnv {
  now: number;
  userAgent: string;
  appHost: string;
  dbHost: string;
  online?: boolean | undefined;
}

const MARK: Record<Outcome, string> = { ok: ".", app: "a", certificate: "C", network: "X", offline: "O", proxy: "P", server: "S" };

/** Jeden riadok na dopyt: `user_roles  ..X.P...` (. v poriadku, X spojenie zatvorené, P proxy, C certifikát, a chyba databázy). */
export function probeHistoryLines(runs: readonly (readonly ProbeResult[])[]): string[] {
  const order: string[] = [];
  const byId = new Map<string, { label: string; marks: string }>();
  for (const run of runs) {
    for (const r of run) {
      let e = byId.get(r.id);
      if (!e) {
        e = { label: r.label, marks: "" };
        byId.set(r.id, e);
        order.push(r.id);
      }
      e.marks += MARK[r.outcome];
    }
  }
  return order.map((id) => {
    const e = byId.get(id);
    return `${(e?.label ?? id).padEnd(34)} ${e?.marks ?? ""}`;
  });
}

function offsetText(t: number): string {
  const min = -new Date(t).getTimezoneOffset();
  const sign = min < 0 ? "-" : "+";
  const abs = Math.abs(min);
  return `UTC${sign}${two(Math.floor(abs / 60))}:${two(abs % 60)}`;
}

/** Text na odoslanie kybernetickému oddeleniu: bez osobných údajov, tokenov a hodnôt filtrov. */
export function buildReport(
  state: NetLogState,
  runs: readonly (readonly ProbeResult[])[],
  env: ReportEnv,
  opts: { maxFailures?: number; maxHours?: number } = {},
): string {
  const maxFailures = opts.maxFailures ?? 40;
  const maxHours = opts.maxHours ?? 24;
  const s = summarize(state);
  const lines: string[] = [];
  lines.push("DIAGNOSTIKA SPOJENIA: aplikácia Dochádzka");
  lines.push(`Vytvorené: ${formatTime(env.now)} (${offsetText(env.now)})`);
  lines.push(`Prehliadač: ${env.userAgent.slice(0, 160)}`);
  if (env.online !== undefined) lines.push(`Stav siete podľa prehliadača: ${env.online ? "online" : "offline"}`);
  lines.push(`Adresa aplikácie: ${env.appHost}`);
  lines.push(`Adresa databázy: ${env.dbHost || "neznáma"}`);
  lines.push("Záznam neobsahuje osobné údaje, tokeny ani hodnoty filtrov (hodnoty sú nahradené *).");
  lines.push("");
  lines.push(`SÚHRN${s.since ? ` (od ${s.since.replace("T", " ")}:00, miestny čas)` : ""}`);
  lines.push(`Dopytov: ${s.total}, zlyhalo: ${s.failed}, chyby aplikácie alebo databázy (nie siete): ${s.app}`);
  const kinds = FAILURE_KINDS.filter((k) => s.byKind[k] > 0).map((k) => `${OUTCOME_LABEL[k]} ${s.byKind[k]}`);
  lines.push(`Zlyhania podľa druhu (zo zachovaných posledných ${state.failures.length}): ${kinds.length ? kinds.join(", ") : "žiadne"}`);

  const hours = Object.entries(state.hours)
    .filter(([, v]) => v.failed > 0)
    .sort(([a], [b]) => (a < b ? 1 : -1));
  lines.push("");
  lines.push("HODINY SO ZLYHANÍM (najnovšie hore)");
  if (hours.length === 0) lines.push("žiadne");
  for (const [k, v] of hours.slice(0, maxHours)) {
    lines.push(`${k.replace("T", " ")}:00  dopytov ${v.ok + v.failed + v.app}, zlyhalo ${v.failed}`);
  }

  lines.push("");
  lines.push(`POSLEDNÉ ZLYHANIA (najnovšie hore, najviac ${maxFailures})`);
  const failures = [...state.failures].sort((a, b) => b.t - a.t);
  if (failures.length === 0) lines.push("žiadne");
  failures.slice(0, maxFailures).forEach((f, i) => {
    const older = failures[i + 1];
    const delta = older ? f.t - older.t : null;
    const gap =
      delta !== null && delta < 60_000
        ? `, +${delta < 1000 ? `${delta} ms` : `${Math.round(delta / 1000)} s`} po predchádzajúcom`
        : "";
    const where = f.host === "db" ? "databáza" : "aplikácia";
    const status = f.status == null ? "bez odpovede" : `HTTP ${f.status}`;
    const query = f.query ? `?${f.query}` : "";
    const note = f.note ? ` [${f.note}]` : "";
    lines.push(`${formatTime(f.t)}  ${f.method.padEnd(5)} ${where} ${f.path}${query}  → ${OUTCOME_LABEL[f.kind]} (${status}, ${f.ms} ms${gap})${note}`);
  });

  const last = runs[runs.length - 1];
  if (last && last.length > 0) {
    lines.push("");
    lines.push(`TEST SPOJENIA (posledný beh ${formatTime(last[0]?.at ?? env.now)})`);
    for (const r of last) {
      const status = r.status == null ? "bez odpovede" : `HTTP ${r.status}`;
      const query = r.request ? ` ${r.request}` : "";
      lines.push(`${r.method.padEnd(5)} ${r.label}${query}: ${OUTCOME_LABEL[r.outcome]} (${status}, ${r.ms} ms)${r.note ? ` [${r.note}]` : ""}`);
    }
    if (runs.length > 1) {
      lines.push("");
      lines.push(`PRIEBEH TESTU (${runs.length} behov, . v poriadku, X spojenie zatvorené, P proxy, C certifikát, a chyba databázy)`);
      lines.push(...probeHistoryLines(runs));
    }
  }
  return lines.join("\n") + "\n";
}
