// Prenos organizácie na iný server: strana prehliadača (migrácia 0016, docs/PRENOS-ORGANIZACIE.md).
//
// Export ide po stránkach (databáza dáva jednému príkazu len niekoľko sekúnd), údaje sa zapisujú rovno do šifrovaného súboru
// (heslo, ktoré zadá správca, nikdy neopustí prehliadač) a na konci sa prenos uzavrie na serveri: databáza vtedy overí, že súbor
// je úplný a že sa údaje počas exportu nezmenili, a organizáciu označí ako testovaciu.
//
// DÔLEŽITÉ: riadky tabuliek sa do súboru vkladajú ako text, presne tak, ako ich vrátila databáza (`org_export_page` ich vracia ako
// reťazec). Nikdy sa nesmú prevádzať cez JSON.parse a JSON.stringify: čísla by sa stratili (7.50 → 7.5, 8.0 → 8 vo vnorenom jsonb),
// odtlačok riadku na cieľovom serveri by sa nezhodoval a import by sa odmietol.
import { z } from "zod";
import { parseDeleteResult, type TestOrganizationSummary } from "./organization-delete";
import {
  createEncryptedWriter,
  decryptToText,
  passwordProblem,
  TransferCryptoError,
  type EncryptOptions,
} from "./org-transfer-crypto";
import { isMissingFunction } from "./rpc-helpers";
import { classifySyncError } from "./sync-error";

export interface RpcError {
  code?: string | null;
  message: string;
  status?: number | null;
}
export interface RpcResponse {
  data: unknown;
  error: RpcError | null;
  status?: number;
}
/** Najmenšie rozhranie klienta databázy, ktoré prenos potrebuje (skutočný klient aj skúšobný). */
export interface TransferClient {
  rpc(fn: string, args?: Record<string, unknown>): PromiseLike<RpcResponse>;
}

export type TransferErrorKind =
  "missing" | "database" | "transport" | "invalid" | "incomplete" | "aborted";

export class TransferError extends Error {
  readonly kind: TransferErrorKind;
  /** Prenos, ktorý už na serveri vznikol (po `org_export_begin`); ostáva zamknutý, kým sa neukončí alebo nezruší. */
  transferId: string | null = null;
  constructor(kind: TransferErrorKind, message: string) {
    super(message);
    this.name = "TransferError";
    this.kind = kind;
  }
}

export const MISSING_MESSAGE =
  "Táto funkcia ešte nie je v databáze. Najprv treba spustiť migráciu 0016 (docs/migracie/0016_prenos_organizacie_export.sql).";
export const TRANSPORT_MESSAGE =
  "Spojenie so serverom zlyhalo alebo ho prerušil firemný proxy. Skúste to znova; rozpracovaný prenos je potrebné zrušiť, aby sa odomkli razenia.";

export const DEFAULT_PAGE_SIZE = 2000;
export const MAX_PAGE_SIZE = 5000;
const PAGE_RETRIES = 3;

export interface CallOptions {
  retries?: number | undefined;
  signal?: AbortSignal | undefined;
  sleep?: ((ms: number) => Promise<void>) | undefined;
  /** Text chyby, keď funkcia v databáze chýba (iná migrácia než 0016). */
  missingMessage?: string | undefined;
}

const defaultSleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

function abortError() {
  return new TransferError("aborted", "Prenos bol prerušený.");
}

/** Jedno volanie databázovej funkcie. Opakujú sa (pri zlyhaní spojenia) len volania, ktoré o to požiadajú cez `retries`. */
export async function call(
  client: TransferClient,
  fn: string,
  args: Record<string, unknown>,
  options: CallOptions = {},
): Promise<unknown> {
  const retries = options.retries ?? 0;
  const sleep = options.sleep ?? defaultSleep;
  for (let attempt = 0; ; attempt += 1) {
    if (options.signal?.aborted) throw abortError();
    let res: RpcResponse;
    try {
      res = await client.rpc(fn, args);
    } catch (e) {
      res = { data: null, error: { message: e instanceof Error ? e.message : String(e) } };
    }
    if (!res.error) return res.data;
    if (isMissingFunction(res.error))
      throw new TransferError("missing", options.missingMessage ?? MISSING_MESSAGE);
    const kind = classifySyncError(res.error, res.status ?? res.error.status);
    if (kind === "transport" || kind === "certificate") {
      if (kind === "transport" && attempt < retries) {
        await sleep(1000 * 2 ** attempt);
        continue;
      }
      throw new TransferError("transport", TRANSPORT_MESSAGE);
    }
    throw new TransferError("database", res.error.message);
  }
}

// ---------------------------------------------------------------------------------------------
// Odpovede databázy
// ---------------------------------------------------------------------------------------------

// zod 4: `.uuid()` kontroluje verziu a variant (odmietne napr. 00000000-0000-0000-0000-000000000001); `z.guid()` prijíma každý tvar 8-4-4-4-12 ako zod 3 a Postgres uuid.
const beginSchema = z.object({
  transfer_id: z.guid(),
  locked: z.boolean(),
  meta: z
    .object({
      format: z.literal(2),
      organization: z
        .object({ id: z.guid(), name: z.string(), code: z.string() })
        .passthrough(),
    })
    .passthrough(),
  tables: z.array(z.object({ rel: z.string().min(1), n: z.number().int().nonnegative() })).min(1),
  page_size: z.number().int().positive().optional(),
});
export type BeginResult = z.infer<typeof beginSchema>;

const pageSchema = z.object({
  rel: z.string(),
  offset: z.number().int().nonnegative(),
  count: z.number().int().nonnegative(),
  rows: z.string(),
});

const finishSchema = z.object({
  state: z.literal("exported"),
  transfer_id: z.guid(),
  locked: z.boolean(),
  is_test: z.boolean(),
  protected: z.boolean(),
});

function invalid(what: string): never {
  throw new TransferError(
    "invalid",
    `Neočakávaná odpoveď databázy (${what}). Skontrolujte, že je nasadená aktuálna migrácia 0016.`,
  );
}

export function parseBegin(value: unknown): BeginResult {
  const r = beginSchema.safeParse(value);
  return r.success ? r.data : invalid("začiatok prenosu");
}

export function parsePage(
  value: unknown,
  rel: string,
  offset: number,
): { count: number; rows: string } {
  const r = pageSchema.safeParse(value);
  if (!r.success || r.data.rel !== rel || r.data.offset !== offset) invalid("stránka tabuľky");
  const { count, rows } = r.data;
  if (!rows.startsWith("[") || !rows.endsWith("]")) invalid("riadky tabuľky");
  let length: number;
  try {
    const parsed: unknown = JSON.parse(rows);
    length = Array.isArray(parsed) ? parsed.length : -1;
  } catch {
    length = -1;
  }
  // Rozbor slúži len na kontrolu: do súboru ide pôvodný text.
  if (length !== count) invalid("počet riadkov stránky");
  return { count, rows };
}

export function parseFinish(value: unknown) {
  const r = finishSchema.safeParse(value);
  return r.success ? r.data : invalid("dokončenie prenosu");
}

export type TransferState = "none" | "ready" | "exported";

export interface TransferChange {
  rel: string;
  then: number;
  now: number;
}

export interface TransferStatus {
  name: string;
  isTest: boolean;
  /** Pôvodná organizácia: dá sa exportovať, ale nedá sa označiť ako testovacia ani zrušiť. */
  protectedOrganization: boolean;
  state: TransferState;
  transferId: string | null;
  locked: boolean;
  lockActive: boolean;
  startedAt: string | null;
  exportedAt: string | null;
  markedTest: boolean;
  hasChanges: boolean;
  changes: TransferChange[];
}

const statusSchema = z.object({
  name: z.string(),
  is_test: z.boolean(),
  protected: z.boolean(),
  state: z.enum(["none", "ready", "exported"]),
  transfer_id: z.string().nullable().optional(),
  locked: z.boolean(),
  lock_active: z.boolean(),
  started_at: z.string().nullable().optional(),
  exported_at: z.string().nullable().optional(),
  marked_test: z.boolean(),
  has_changes: z.boolean(),
  changes: z
    .record(z.string(), z.object({ then: z.number(), now: z.number() }).passthrough())
    .optional(),
});

export function parseStatus(value: unknown): TransferStatus | null {
  const r = statusSchema.safeParse(value);
  if (!r.success) return null;
  const d = r.data;
  return {
    name: d.name,
    isTest: d.is_test,
    protectedOrganization: d.protected,
    state: d.state,
    transferId: d.transfer_id ?? null,
    locked: d.locked,
    lockActive: d.lock_active,
    startedAt: d.started_at ?? null,
    exportedAt: d.exported_at ?? null,
    markedTest: d.marked_test,
    hasChanges: d.has_changes,
    changes: Object.entries(d.changes ?? {}).map(([rel, v]) => ({ rel, then: v.then, now: v.now })),
  };
}

const TABLE_LABELS: Record<string, string> = {
  "public.punches": "razenia",
  "public.profiles": "účty",
  "public.devices": "zariadenia",
  "public.corrections": "žiadosti o opravu",
  "public.audit_log": "záznamy auditu",
  "public.user_roles": "roly",
  "public.month_closures": "uzávierky mesiaca",
};

/**
 * Veta o zmenách od exportu, napr. „razenia: 120 → 123, účty: 5 → 6“. Pri rovnakom počte (zmenil sa obsah riadkov, nie ich počet) by
 * „8 → 8“ vyzeralo ako chyba, preto sa píše „zmenil sa obsah (počet 8)“.
 */
export function describeChanges(changes: TransferChange[]): string {
  return changes
    .map((c) => {
      const label = TABLE_LABELS[c.rel] ?? c.rel.replace(/^public\./, "");
      return c.then === c.now
        ? `${label}: zmenil sa obsah (počet ${c.now})`
        : `${label}: ${c.then} → ${c.now}`;
    })
    .join(", ");
}

/** Kód potvrdenia z cieľového servera v tvare XXXX-XXXX; z iného zápisu (bez pomlčky, malé písmená, medzery) vyrobí správny tvar alebo `null`. */
export function normalizeReceipt(input: string): string | null {
  const s = input.replace(/[^0-9a-z]/gi, "").toUpperCase();
  return /^[0-9A-F]{8}$/.test(s) ? `${s.slice(0, 4)}-${s.slice(4)}` : null;
}

// ---------------------------------------------------------------------------------------------
// Volania
// ---------------------------------------------------------------------------------------------

export async function getTransferStatus(client: TransferClient): Promise<TransferStatus> {
  const status = parseStatus(await call(client, "org_transfer_status", {}));
  if (!status) invalid("stav prenosu");
  return status;
}

export async function cancelTransfer(
  client: TransferClient,
): Promise<{ unlocked: boolean; testFlagReverted: boolean; hadTransfer: boolean }> {
  const v = await call(client, "org_transfer_cancel", {});
  const o = v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
  return {
    hadTransfer: o["state"] === "cancelled",
    unlocked: o["unlocked"] === true,
    testFlagReverted: o["test_flag_reverted"] === true,
  };
}

export async function confirmTransferAndDelete(
  client: TransferClient,
  input: { receipt: string; name: string; acceptChanges: boolean },
): Promise<Pick<TestOrganizationSummary, "users" | "punches" | "devices">> {
  const receipt = normalizeReceipt(input.receipt);
  if (!receipt)
    throw new TransferError(
      "invalid",
      "Kód potvrdenia má tvar XXXX-XXXX (osem znakov 0 až 9 a A až F).",
    );
  const v = await call(client, "org_transfer_confirm_and_delete", {
    _receipt: receipt,
    _confirm_name: input.name,
    _accept_changes: input.acceptChanges,
  });
  return parseDeleteResult(v);
}

// ---------------------------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------------------------

export interface ExportProgress {
  phase: "key" | "begin" | "read" | "seal" | "finish";
  rel?: string;
  /** Prečítané riadky všetkých tabuliek a ich celkový počet. */
  rows: number;
  total: number;
}

export interface ExportOptions {
  /** Zamknúť razenia organizácie na čas prenosu (odporúčané). */
  lock: boolean;
  password: string;
  pageSize?: number;
  signal?: AbortSignal;
  onProgress?: (p: ExportProgress) => void;
  encrypt?: EncryptOptions;
  sleep?: (ms: number) => Promise<void>;
  now?: () => Date;
}

export interface ExportResult {
  blob: Blob;
  fileName: string;
  transferId: string;
  organizationName: string;
  organizationCode: string;
  counts: Record<string, number>;
  rows: number;
  /** Veľkosť nezašifrovaného obsahu v bajtoch. */
  plainBytes: number;
  locked: boolean;
  isTest: boolean;
  protectedOrganization: boolean;
}

const pad = (n: number) => String(n).padStart(2, "0");

export function transferFileName(code: string, at: Date): string {
  const safe = code.replace(/[^A-Za-z0-9]/g, "").slice(0, 16) || "organizacia";
  const stamp = `${at.getFullYear()}${pad(at.getMonth() + 1)}${pad(at.getDate())}-${pad(at.getHours())}${pad(at.getMinutes())}`;
  return `prenos-${safe}-${stamp}.dochs-enc`;
}

/**
 * Vyexportuje organizáciu prihláseného správcu do šifrovaného súboru. Po chybe po začiatku prenosu nesie chyba `transferId`:
 * prenos (a prípadný zámok razení) ostáva na serveri, kým ho správca nezruší (`cancelTransfer`) alebo kým zámok nevyprší (2 hodiny).
 */
export async function exportOrganization(
  client: TransferClient,
  options: ExportOptions,
): Promise<ExportResult> {
  const problem = passwordProblem(options.password);
  if (problem) throw new TransferError("invalid", problem);
  const pageSize = Math.min(
    Math.max(1, Math.floor(options.pageSize ?? DEFAULT_PAGE_SIZE)),
    MAX_PAGE_SIZE,
  );
  const progress = (p: ExportProgress) => options.onProgress?.(p);
  const callOptions: CallOptions = { signal: options.signal, sleep: options.sleep };

  // Kľúč sa odvodí PRED začiatkom prenosu, aby zámok razení netrval dlhšie, než treba.
  progress({ phase: "key", rows: 0, total: 0 });
  const writer = await createEncryptedWriter(options.password, options.encrypt);
  if (options.signal?.aborted) throw abortError();

  progress({ phase: "begin", rows: 0, total: 0 });
  const begin = parseBegin(
    await call(client, "org_export_begin", { _lock: options.lock }, callOptions),
  );
  const total = begin.tables.reduce((sum, t) => sum + t.n, 0);
  const received: Record<string, number> = {};
  let rows = 0;

  try {
    await writer.write(`{"meta":${JSON.stringify(begin.meta)},"tables":{`);
    for (const [i, table] of begin.tables.entries()) {
      await writer.write(`${i > 0 ? "," : ""}${JSON.stringify(table.rel)}:[`);
      let offset = 0;
      let first = true;
      while (offset < table.n) {
        const page = parsePage(
          await call(
            client,
            "org_export_page",
            { _transfer: begin.transfer_id, _rel: table.rel, _offset: offset, _limit: pageSize },
            { ...callOptions, retries: PAGE_RETRIES },
          ),
          table.rel,
          offset,
        );
        if (page.count === 0) {
          throw new TransferError(
            "incomplete",
            `Tabuľka ${table.rel} skončila skôr (${offset} z ${table.n} riadkov). Údaje sa počas exportu zmenili, export zopakujte.`,
          );
        }
        // Text stránky je pole `[…]`: do súboru ide jeho obsah bez hranatých zátvoriek, nezmenený.
        await writer.write(`${first ? "" : ","}${page.rows.slice(1, -1)}`);
        first = false;
        offset += page.count;
        rows += page.count;
        progress({ phase: "read", rel: table.rel, rows, total });
      }
      await writer.write("]");
      received[table.rel] = offset;
    }
    await writer.write("}}");
    progress({ phase: "seal", rows, total });
    const blob = await writer.finish();

    progress({ phase: "finish", rows, total });
    const done = parseFinish(
      await call(
        client,
        "org_export_finish",
        { _transfer: begin.transfer_id, _received: received },
        callOptions,
      ),
    );
    const org = begin.meta.organization;
    return {
      blob,
      fileName: transferFileName(org.code, (options.now ?? (() => new Date()))()),
      transferId: begin.transfer_id,
      organizationName: org.name,
      organizationCode: org.code,
      counts: received,
      rows,
      plainBytes: writer.plainBytes,
      locked: done.locked,
      isTest: done.is_test,
      protectedOrganization: done.protected,
    };
  } catch (e) {
    const err =
      e instanceof TransferError
        ? e
        : new TransferError("invalid", e instanceof Error ? e.message : String(e));
    err.transferId = begin.transfer_id;
    throw err;
  }
}

// ---------------------------------------------------------------------------------------------
// Kontrola stiahnutého súboru (pred zrušením pôvodnej organizácie)
// ---------------------------------------------------------------------------------------------

export interface VerifiedFile {
  organizationName: string;
  organizationCode: string;
  exportedAt: string | null;
  counts: Record<string, number>;
  rows: number;
}

const fileSchema = z.object({
  meta: z
    .object({
      format: z.literal(2),
      exported_at: z.string().optional(),
      organization: z.object({ name: z.string(), code: z.string() }).passthrough(),
      counts: z.record(z.string(), z.number().int().nonnegative()),
    })
    .passthrough(),
  tables: z.record(z.string(), z.array(z.unknown())),
});

/**
 * Otvorí šifrovaný súbor heslom a skontroluje, že je to úplný prenos: počet riadkov každej tabuľky sa zhoduje s hlavičkou.
 * Slúži na to, aby sa pôvodná organizácia nezrušila na základe poškodeného alebo nesprávne uloženého súboru. Súbor sa nikam neposiela.
 * (Obsah sa tu prevádza cez JSON.parse len na počítanie riadkov; do súboru ani na server sa takto upravené údaje nedostanú.)
 */
export async function verifyTransferFile(file: Blob, password: string): Promise<VerifiedFile> {
  let text: string;
  try {
    text = await decryptToText(file, password);
  } catch (e) {
    if (e instanceof TransferCryptoError) throw new TransferError("invalid", e.message);
    throw e;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = null;
  }
  const r = fileSchema.safeParse(parsed);
  if (!r.success) {
    throw new TransferError(
      "invalid",
      "Súbor sa dešifroval, ale nie je to platný prenos organizácie (formát 2).",
    );
  }
  const { meta, tables } = r.data;
  let rows = 0;
  for (const [rel, n] of Object.entries(meta.counts)) {
    const have = tables[rel]?.length;
    if (have !== n) {
      throw new TransferError(
        "incomplete",
        `Súbor je neúplný: tabuľka ${rel} má ${have ?? 0} riadkov namiesto ${n}.`,
      );
    }
    rows += n;
  }
  return {
    organizationName: meta.organization.name,
    organizationCode: meta.organization.code,
    exportedAt: meta.exported_at ?? null,
    counts: meta.counts,
    rows,
  };
}
