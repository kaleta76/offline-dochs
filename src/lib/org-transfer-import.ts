// Prenos organizácie na iný server: strana IMPORTU v prehliadači (migrácia 0017, docs/PRENOS-ORGANIZACIE.md).
//
// Správca čerstvej prázdnej organizácie vyberie súbor z exportu a zadá heslo. Súbor sa dešifruje v prehliadači (heslo sa nikam
// neposiela), po častiach sa nahrá do odkladacej tabuľky v databáze, databáza ho skontroluje a až po výslovnom potvrdení správcu
// čerstvú organizáciu nahradí organizáciou zo súboru. Databáza súboru neverí: všetky bezpečnostné kontroly robí ona, nie tento kód.
//
// DÔLEŽITÉ: riadky tabuliek sa na server posielajú ako text, presne tak, ako sú v súbore. Súbor sa preto NEčíta cez JSON.parse
// (čísla by stratili zápis, 7.50 → 7.5, odtlačok riadku by sa nezhodoval a import by sa odmietol), ale krája sa podľa zátvoriek.
import { z } from "zod";
import { decryptToText, TransferCryptoError } from "./org-transfer-crypto";
import { call, TransferError, type CallOptions, type TransferClient } from "./org-transfer";

export const IMPORT_MISSING_MESSAGE =
  "Import ešte nie je v databáze. Najprv treba spustiť migráciu 0017 (docs/migracie/0017_prenos_organizacie_import.sql).";
export const NOT_A_TRANSFER_MESSAGE =
  "Súbor sa dešifroval, ale nie je to platný prenos organizácie (formát 2).";
export const COMMIT_UNKNOWN_MESSAGE =
  "Spojenie sa prerušilo počas zápisu, výsledok nie je istý. Obnovte stránku: ak vás aplikácia odhlási alebo sa už nedá prihlásiť týmto účtom, import prebehol. Prihláste sa potom účtom správcu prenesenej organizácie, kód potvrdenia nájdete v tejto karte.";
const TIMEOUT_MESSAGE =
  "Databáza operáciu nestihla v časovom limite. Organizácia je na import tlačidlom príliš veľká alebo je server zaneprázdnený; nič sa nezmenilo. Skúste to neskôr alebo použite operátorský postup.";

/** Najviac riadkov a znakov v jednej časti (server má vlastné, vyššie hranice; menšie časti prejdú aj cez proxy). */
export const DEFAULT_CHUNK_ROWS = 1000;
export const DEFAULT_CHUNK_CHARS = 1_000_000;
const CHUNK_RETRIES = 3;

// ---------------------------------------------------------------------------------------------
// Krájanie súboru bez prevodu cez JSON.parse
// ---------------------------------------------------------------------------------------------

export interface SplitFile {
  /** Hlavička súboru (časť „meta“) presne tak, ako je v súbore. */
  metaText: string;
  /** Tabuľky v poradí zo súboru; `rows` sú dvojice [začiatok, koniec) každého riadku v texte súboru. */
  tables: { rel: string; rows: number[] }[];
}

function notTransfer(): never {
  throw new TransferError("invalid", NOT_A_TRANSFER_MESSAGE);
}

const isWs = (c: number) => c === 0x20 || c === 0x0a || c === 0x0d || c === 0x09;

function skipWs(t: string, i: number): number {
  while (i < t.length && isWs(t.charCodeAt(i))) i += 1;
  return i;
}

/** Koniec reťazca, ktorý začína úvodzovkou na pozícii `i` (pozícia za koncovou úvodzovkou). */
function stringEnd(t: string, i: number): number {
  for (let j = i + 1; j < t.length; j += 1) {
    const c = t.charCodeAt(j);
    if (c === 0x5c) j += 1;
    else if (c === 0x22) return j + 1;
  }
  return notTransfer();
}

/** Koniec hodnoty JSON, ktorá začína na pozícii `i` (objekt, pole, reťazec, číslo, true/false/null). */
function valueEnd(t: string, i: number): number {
  const first = t.charCodeAt(i);
  if (first === 0x22) return stringEnd(t, i);
  if (first === 0x7b || first === 0x5b) {
    let depth = 0;
    for (let j = i; j < t.length; j += 1) {
      const c = t.charCodeAt(j);
      if (c === 0x22) j = stringEnd(t, j) - 1;
      else if (c === 0x7b || c === 0x5b) depth += 1;
      else if (c === 0x7d || c === 0x5d) {
        depth -= 1;
        if (depth === 0) return j + 1;
      }
    }
    return notTransfer();
  }
  let j = i;
  while (j < t.length) {
    const c = t.charCodeAt(j);
    if (c === 0x2c || c === 0x7d || c === 0x5d || isWs(c)) break;
    j += 1;
  }
  return j === i ? notTransfer() : j;
}

/** Prejde členy objektu, ktorý začína na pozícii `i`; vráti pozíciu za jeho koncom. */
function eachMember(
  t: string,
  i: number,
  visit: (key: string, valueStart: number) => number,
): number {
  if (t.charCodeAt(i) !== 0x7b) notTransfer();
  let j = skipWs(t, i + 1);
  if (t.charCodeAt(j) === 0x7d) return j + 1;
  for (;;) {
    if (t.charCodeAt(j) !== 0x22) notTransfer();
    const keyEnd = stringEnd(t, j);
    let key: unknown;
    try {
      key = JSON.parse(t.slice(j, keyEnd));
    } catch {
      notTransfer();
    }
    j = skipWs(t, keyEnd);
    if (t.charCodeAt(j) !== 0x3a) notTransfer();
    j = skipWs(t, visit(key as string, skipWs(t, j + 1)));
    const c = t.charCodeAt(j);
    if (c === 0x7d) return j + 1;
    if (c !== 0x2c) notTransfer();
    j = skipWs(t, j + 1);
  }
}

/** Rozdelí dešifrovaný text súboru na hlavičku a riadky tabuliek; riadky ostávajú v pôvodnom zápise. */
export function splitTransferText(text: string): SplitFile {
  let metaText: string | null = null;
  let tables: SplitFile["tables"] | null = null;
  const end = eachMember(text, skipWs(text, 0), (key, start) => {
    if (key === "meta") {
      if (metaText !== null || text.charCodeAt(start) !== 0x7b) notTransfer();
      const e = valueEnd(text, start);
      metaText = text.slice(start, e);
      return e;
    }
    if (key === "tables") {
      if (tables !== null) notTransfer();
      const list: SplitFile["tables"] = [];
      const e = eachMember(text, start, (rel, arrayStart) => {
        if (text.charCodeAt(arrayStart) !== 0x5b || list.some((x) => x.rel === rel)) notTransfer();
        const rows: number[] = [];
        let j = skipWs(text, arrayStart + 1);
        if (text.charCodeAt(j) !== 0x5d) {
          for (;;) {
            if (text.charCodeAt(j) !== 0x7b) notTransfer();
            const rowEnd = valueEnd(text, j);
            rows.push(j, rowEnd);
            j = skipWs(text, rowEnd);
            const c = text.charCodeAt(j);
            if (c === 0x5d) break;
            if (c !== 0x2c) notTransfer();
            j = skipWs(text, j + 1);
          }
        }
        list.push({ rel, rows });
        return j + 1;
      });
      tables = list;
      return e;
    }
    return valueEnd(text, start);
  });
  if (skipWs(text, end) !== text.length || metaText === null || tables === null) notTransfer();
  return { metaText, tables };
}

/** Rozdelí riadky jednej tabuľky na časti (text poľa JSON) podľa najväčšieho počtu riadkov a znakov. */
export function* chunkRows(
  text: string,
  rows: number[],
  maxRows: number,
  maxChars: number,
): Generator<{ rows: string; count: number }> {
  let parts: string[] = [];
  let chars = 2;
  for (let k = 0; k < rows.length; k += 2) {
    const row = text.slice(rows[k], rows[k + 1]);
    if (parts.length > 0 && (parts.length >= maxRows || chars + row.length + 1 > maxChars)) {
      yield { rows: `[${parts.join(",")}]`, count: parts.length };
      parts = [];
      chars = 2;
    }
    parts.push(row);
    chars += row.length + 1;
  }
  if (parts.length > 0) yield { rows: `[${parts.join(",")}]`, count: parts.length };
}

// ---------------------------------------------------------------------------------------------
// Odpovede databázy
// ---------------------------------------------------------------------------------------------

function invalid(what: string): never {
  throw new TransferError(
    "invalid",
    `Neočakávaná odpoveď databázy (${what}). Skontrolujte, že je nasadená aktuálna migrácia 0017.`,
  );
}

// zod 4: `.uuid()` je prísne na verziu a variant; `z.guid()` prijíma každý tvar 8-4-4-4-12 ako zod 3 (pozri org-transfer.ts).
const orgSchema = z.object({ id: z.guid(), name: z.string(), code: z.string() });

const statusSchema = z.object({
  eligible: z.boolean(),
  reasons: z.array(z.string()),
  name: z.string().optional(),
  code: z.string().optional(),
  active: z
    .object({
      import_id: z.guid(),
      state: z.enum(["uploading", "checked"]),
      organization: orgSchema,
      rows: z.number(),
      received: z.number(),
    })
    .passthrough()
    .nullable()
    .optional(),
  last_import: z
    .object({
      finished_at: z.string().nullable().optional(),
      receipt: z.string(),
      rows: z.number(),
    })
    .nullable()
    .optional(),
});

export interface ImportStatus {
  /** Organizácia prihláseného správcu sa dá nahradiť importom (je čerstvá a prázdna). */
  eligible: boolean;
  reasons: string[];
  name: string;
  code: string;
  /** Rozpracovaný import (nahrané riadky čakajú v databáze). */
  active: {
    importId: string;
    state: "uploading" | "checked";
    organizationName: string;
    organizationCode: string;
    rows: number;
    received: number;
  } | null;
  /** Táto organizácia sem bola importovaná: kód potvrdenia pre pôvodný server. */
  lastImport: { finishedAt: string | null; receipt: string; rows: number } | null;
}

export function parseImportStatus(value: unknown): ImportStatus {
  const r = statusSchema.safeParse(value);
  if (!r.success) invalid("stav importu");
  const d = r.data;
  return {
    eligible: d.eligible,
    reasons: d.reasons,
    name: d.name ?? "",
    code: d.code ?? "",
    active: d.active
      ? {
          importId: d.active.import_id,
          state: d.active.state,
          organizationName: d.active.organization.name,
          organizationCode: d.active.organization.code,
          rows: d.active.rows,
          received: d.active.received,
        }
      : null,
    lastImport: d.last_import
      ? {
          finishedAt: d.last_import.finished_at ?? null,
          receipt: d.last_import.receipt,
          rows: d.last_import.rows,
        }
      : null,
  };
}

const beginSchema = z.object({
  import_id: z.guid(),
  organization: orgSchema,
  tables: z.array(z.object({ rel: z.string().min(1), n: z.number().int().nonnegative() })).min(1),
  rows: z.number().int().nonnegative(),
  max_chunk_rows: z.number().int().positive(),
  max_chunk_chars: z.number().int().positive(),
});

const chunkSchema = z.object({
  rel: z.string(),
  seq: z.number().int(),
  count: z.number().int(),
  received: z.number().int(),
});

const checkSchema = z.object({
  state: z.literal("checked"),
  import_id: z.guid(),
  organization: orgSchema,
  counts: z.record(z.string(), z.number()),
  rows: z.number(),
  exported_at: z.string().nullable().optional(),
  warnings: z.array(z.string()),
  replaces: z.object({ name: z.string(), code: z.string() }).passthrough(),
});

export interface CheckedImport {
  importId: string;
  organizationName: string;
  organizationCode: string;
  exportedAt: string | null;
  counts: Record<string, number>;
  rows: number;
  warnings: string[];
  /** Čerstvá organizácia, ktorá importom zanikne (jej názov správca opíše na potvrdenie). */
  replacesName: string;
  replacesCode: string;
}

const commitSchema = z.object({
  state: z.literal("done"),
  organization: orgSchema,
  receipt: z.string().regex(/^[0-9A-F]{4}-[0-9A-F]{4}$/),
  rows: z.number(),
  ids_mode: z.enum(["keep", "renumber"]),
  warnings: z.array(z.string()).optional(),
});

export interface ImportDone {
  organizationName: string;
  organizationCode: string;
  /** Kód potvrdenia prenosu pre pôvodný server. */
  receipt: string;
  rows: number;
  renumbered: boolean;
  warnings: string[];
}

// ---------------------------------------------------------------------------------------------
// Volania
// ---------------------------------------------------------------------------------------------

const base: CallOptions = { missingMessage: IMPORT_MISSING_MESSAGE };

function friendly(e: unknown): unknown {
  if (e instanceof TransferError && e.kind === "database" && /statement timeout/i.test(e.message)) {
    return new TransferError("database", TIMEOUT_MESSAGE);
  }
  return e;
}

export async function getImportStatus(client: TransferClient): Promise<ImportStatus> {
  return parseImportStatus(await call(client, "org_import_status", {}, base));
}

export async function cancelImport(client: TransferClient): Promise<boolean> {
  const v = await call(client, "org_import_cancel", {}, base);
  return !!v && typeof v === "object" && (v as Record<string, unknown>)["state"] === "cancelled";
}

export interface ImportProgress {
  phase: "decrypt" | "begin" | "upload" | "check";
  rel?: string;
  rows: number;
  total: number;
}

export interface UploadOptions {
  file: Blob;
  password: string;
  chunkRows?: number;
  chunkChars?: number;
  signal?: AbortSignal;
  onProgress?: (p: ImportProgress) => void;
  sleep?: (ms: number) => Promise<void>;
}

/**
 * Dešifruje súbor, nahrá ho po častiach a nechá ho databázu skontrolovať. V aplikácii sa tým nič nemení: zápis urobí až
 * `commitImport` po potvrdení správcu. Po chybe po začiatku nahrávania nesie chyba `transferId` (id importu): nahrané riadky
 * ostávajú v odkladacej tabuľke, kým sa import nezahodí (`cancelImport`) alebo kým ho nenahradí nový.
 */
export async function uploadImport(
  client: TransferClient,
  options: UploadOptions,
): Promise<CheckedImport> {
  const progress = (p: ImportProgress) => options.onProgress?.(p);
  const opts: CallOptions = { ...base, signal: options.signal, sleep: options.sleep };
  const aborted = () => {
    if (options.signal?.aborted) throw new TransferError("aborted", "Import bol prerušený.");
  };

  progress({ phase: "decrypt", rows: 0, total: 0 });
  let text: string;
  try {
    text = await decryptToText(options.file, options.password);
  } catch (e) {
    if (e instanceof TransferCryptoError) throw new TransferError("invalid", e.message);
    throw e;
  }
  const split = splitTransferText(text);
  aborted();

  progress({ phase: "begin", rows: 0, total: 0 });
  let begun: unknown;
  try {
    begun = await call(client, "org_import_begin", { _meta: split.metaText }, opts);
  } catch (e) {
    throw friendly(e);
  }
  const parsedBegin = beginSchema.safeParse(begun);
  if (!parsedBegin.success) invalid("začiatok importu");
  const b = parsedBegin.data;

  try {
    const known = new Set(b.tables.map((t) => t.rel));
    const extra = split.tables.find((t) => !known.has(t.rel));
    if (extra) {
      throw new TransferError(
        "invalid",
        `Súbor obsahuje tabuľku ${extra.rel}, ktorú tento server nepozná (iná verzia aplikácie).`,
      );
    }
    const maxRows = Math.max(
      1,
      Math.min(options.chunkRows ?? DEFAULT_CHUNK_ROWS, b.max_chunk_rows),
    );
    const maxChars = Math.min(options.chunkChars ?? DEFAULT_CHUNK_CHARS, b.max_chunk_chars);
    let sent = 0;
    for (const table of b.tables) {
      const rows = split.tables.find((t) => t.rel === table.rel)?.rows ?? [];
      if (rows.length / 2 !== table.n) {
        throw new TransferError(
          "incomplete",
          `Súbor je neúplný: tabuľka ${table.rel} má ${rows.length / 2} riadkov namiesto ${table.n}.`,
        );
      }
      let seq = 0;
      for (const chunk of chunkRows(text, rows, maxRows, maxChars)) {
        aborted();
        if (chunk.rows.length > b.max_chunk_chars) {
          throw new TransferError(
            "invalid",
            `Tabuľka ${table.rel} má riadok, ktorý je na import tlačidlom príliš veľký.`,
          );
        }
        // Tá istá časť sa dá poslať znova (server ju nahradí), preto sa pri zlyhaní spojenia opakuje.
        const v = await call(
          client,
          "org_import_chunk",
          { _import: b.import_id, _rel: table.rel, _seq: seq, _rows: chunk.rows },
          { ...opts, retries: CHUNK_RETRIES },
        );
        const r = chunkSchema.safeParse(v);
        if (
          !r.success ||
          r.data.rel !== table.rel ||
          r.data.seq !== seq ||
          r.data.count !== chunk.count
        )
          invalid("časť tabuľky");
        seq += 1;
        sent += chunk.count;
        progress({ phase: "upload", rel: table.rel, rows: sent, total: b.rows });
      }
    }
    aborted();
    progress({ phase: "check", rows: sent, total: b.rows });
    // Kontrola nič nemení a dá sa zopakovať.
    const v = await call(
      client,
      "org_import_check",
      { _import: b.import_id },
      { ...opts, retries: 1 },
    );
    const r = checkSchema.safeParse(v);
    if (!r.success) invalid("kontrola importu");
    const d = r.data;
    return {
      importId: d.import_id,
      organizationName: d.organization.name,
      organizationCode: d.organization.code,
      exportedAt: d.exported_at ?? null,
      counts: d.counts,
      rows: d.rows,
      warnings: d.warnings,
      replacesName: d.replaces.name,
      replacesCode: d.replaces.code,
    };
  } catch (e) {
    const f = friendly(e);
    const err =
      f instanceof TransferError
        ? f
        : new TransferError("invalid", f instanceof Error ? f.message : String(f));
    err.transferId = b.import_id;
    throw err;
  }
}

/**
 * Zápis: čerstvá organizácia správcu (aj jeho účet) zanikne a nahradí ju organizácia zo súboru. Neopakuje sa nikdy; po zlyhaní
 * spojenia nie je výsledok istý (`COMMIT_UNKNOWN_MESSAGE`).
 */
export async function commitImport(
  client: TransferClient,
  input: { importId: string; confirmName: string },
): Promise<ImportDone> {
  let v: unknown;
  try {
    v = await call(
      client,
      "org_import_commit",
      { _import: input.importId, _confirm_name: input.confirmName },
      base,
    );
  } catch (e) {
    if (e instanceof TransferError && e.kind === "transport")
      throw new TransferError("transport", COMMIT_UNKNOWN_MESSAGE);
    throw friendly(e);
  }
  const r = commitSchema.safeParse(v);
  if (!r.success) invalid("zápis importu");
  const d = r.data;
  return {
    organizationName: d.organization.name,
    organizationCode: d.organization.code,
    receipt: d.receipt,
    rows: d.rows,
    renumbered: d.ids_mode === "renumber",
    warnings: d.warnings ?? [],
  };
}
