// Razenia, ktoré ostali v zariadení po presťahovaní organizácie na iný server (migrácia 0019, docs/PRENOS-ORGANIZACIE.md).
//
// Zariadenie ich uloží do šifrovaného súboru (rovnaký formát šifrovania ako prenos organizácie, heslo nikdy neopustí prehliadač) a správca
// ho nahrá na novom serveri. Súbor obsahuje len to, čo server potrebuje na zápis razenia: client_uuid, user_id, code, direction,
// client_time, device. Kľúč zariadenia (device_token), príznaky fronty ani text chyby sa do súboru NIKDY nedostanú: razenie zo súboru je
// na novom serveri vždy neoverené a potvrdzuje ho vedúci.
//
// Súboru sa na serveri neverí (všetky kontroly robí databáza vo funkcii late_punches_import). Odtlačok v súbore slúži len na to, aby
// zariadenie aj správca vedeli, že sa súbor po ceste nepoškodil a že obsahuje presne tie razenia, ktoré boli vo fronte.
import { z } from "zod";
import {
  decryptToText,
  encryptText,
  TransferCryptoError,
  WRONG_PASSWORD_MESSAGE,
  type EncryptOptions,
} from "./org-transfer-crypto";
import { call, TransferError, type CallOptions, type TransferClient } from "./org-transfer";

export const LATE_FORMAT = "dochs-late-punches";
export const LATE_VERSION = 1;
/** Rovnaké limity ako org_transfer.move_limits() v migrácii 0019. */
export const MAX_LATE_PUNCHES = 2000;
/** Šifrovaný súbor s 2 000 razeniami má pod 1 MB; väčší súbor sa ani nezačne dešifrovať. */
export const MAX_LATE_FILE_BYTES = 4 * 1024 * 1024;

export const LATE_MISSING_MESSAGE =
  "Táto funkcia ešte nie je v databáze. Najprv treba spustiť migráciu 0019 (docs/migracie/0019_razenia_po_prestahovani.sql).";
export const NOT_LATE_FILE_MESSAGE = "Toto nie je súbor s razeniami zo zariadenia.";

export interface LatePunch {
  client_uuid: string;
  user_id: string;
  code: string;
  direction: "IN" | "OUT";
  client_time: string;
  device: string;
}

/** Tvar záznamu fronty, z ktorého sa berú len polia súboru (zvyšok sa zámerne zahodí). */
export interface QueuedLike extends LatePunch {
  device_token?: string | undefined;
  server_inserted?: boolean | undefined;
  error?: string | undefined;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/;

const punchSchema = z
  .object({
    client_uuid: z.string().regex(UUID),
    user_id: z.string().regex(UUID),
    code: z.string().min(1).max(40),
    direction: z.enum(["IN", "OUT"]),
    client_time: z.string().regex(TIME),
    device: z.string().max(60),
  })
  .strict();

const fileSchema = z.object({
  format: z.literal(LATE_FORMAT),
  version: z.literal(LATE_VERSION),
  created_at: z.string().max(40),
  origin: z.string().max(200),
  count: z.number().int().nonnegative(),
  fingerprint: z.string().regex(/^[0-9a-f]{64}$/),
  punches: z.array(punchSchema).max(MAX_LATE_PUNCHES),
});

/** Záznam fronty → riadok súboru. Vymenované polia, nikdy `...item`: kľúč zariadenia by sa inak dostal do súboru. */
export function toLatePunch(item: QueuedLike): LatePunch {
  return {
    client_uuid: item.client_uuid,
    user_id: item.user_id,
    code: item.code,
    direction: item.direction,
    client_time: item.client_time,
    device: item.device.slice(0, 60),
  };
}

/** Poradie v súbore: čas zariadenia, pri zhode client_uuid (rovnaké poradie, v akom ich server zapíše). */
export function sortLatePunches(punches: LatePunch[]): LatePunch[] {
  return [...punches].sort(
    (a, b) =>
      a.client_time.localeCompare(b.client_time) || a.client_uuid.localeCompare(b.client_uuid),
  );
}

const line = (p: LatePunch) =>
  [p.client_uuid, p.user_id, p.code, p.direction, p.client_time, p.device]
    .map((v) => v.replace(/[\\|\n]/g, (c) => (c === "\n" ? "\\n" : `\\${c}`)))
    .join("|");

/** SHA-256 obsahu razení (nezávisí od poradia v poli). Rovnaké razenia = rovnaký odtlačok. */
export async function fingerprintPunches(punches: LatePunch[]): Promise<string> {
  const text = sortLatePunches(punches).map(line).join("\n");
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(hash), (b) => b.toString(16).padStart(2, "0")).join("");
}

export interface LateFile {
  createdAt: string;
  origin: string;
  fingerprint: string;
  punches: LatePunch[];
  /** Počet rôznych účtov v súbore (id účtu nie je osobný údaj, ale na obrazovke sa neukazuje). */
  accounts: number;
  from: string | null;
  to: string | null;
}

function describe(
  punches: LatePunch[],
  createdAt: string,
  origin: string,
  fingerprint: string,
): LateFile {
  const sorted = sortLatePunches(punches);
  return {
    createdAt,
    origin,
    fingerprint,
    punches: sorted,
    accounts: new Set(sorted.map((p) => p.user_id)).size,
    from: sorted[0]?.client_time ?? null,
    to: sorted[sorted.length - 1]?.client_time ?? null,
  };
}

export interface BuildOptions {
  origin: string;
  now?: Date | undefined;
}

/** Nezašifrovaný text súboru. Razenia sa zoradia; rovnaké client_uuid dvakrát je chyba volajúceho. */
export async function buildLateFileText(
  items: QueuedLike[],
  options: BuildOptions,
): Promise<string> {
  if (items.length === 0)
    throw new TransferError("invalid", "V zariadení nie sú žiadne razenia na uloženie.");
  if (items.length > MAX_LATE_PUNCHES)
    throw new TransferError(
      "invalid",
      `V zariadení je viac než ${MAX_LATE_PUNCHES} razení. Do jedného súboru sa nezmestia.`,
    );
  const punches = sortLatePunches(items.map(toLatePunch));
  if (new Set(punches.map((p) => p.client_uuid)).size !== punches.length)
    throw new TransferError("invalid", "Vo fronte je to isté razenie dvakrát.");
  const parsed = z.array(punchSchema).safeParse(punches);
  if (!parsed.success)
    throw new TransferError(
      "invalid",
      "Razenie vo fronte má neplatný tvar, súbor sa nedá vytvoriť.",
    );
  return JSON.stringify({
    format: LATE_FORMAT,
    version: LATE_VERSION,
    created_at: (options.now ?? new Date()).toISOString(),
    origin: options.origin.slice(0, 200),
    count: punches.length,
    fingerprint: await fingerprintPunches(punches),
    punches,
  });
}

/** Prečíta nezašifrovaný text súboru a overí počet aj odtlačok. Chyba: `TransferError` (kind „invalid“). */
export async function parseLateFileText(text: string): Promise<LateFile> {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    throw new TransferError("invalid", NOT_LATE_FILE_MESSAGE);
  }
  const head = z.object({ format: z.unknown(), version: z.unknown() }).safeParse(raw);
  if (!head.success || head.data.format !== LATE_FORMAT)
    throw new TransferError("invalid", NOT_LATE_FILE_MESSAGE);
  if (head.data.version !== LATE_VERSION)
    throw new TransferError(
      "invalid",
      "Súbor je v novšom formáte, ktorý táto verzia aplikácie nepozná.",
    );
  const parsed = fileSchema.safeParse(raw);
  if (!parsed.success)
    throw new TransferError("invalid", "Súbor s razeniami je poškodený alebo upravený.");
  const file = parsed.data;
  const punches: LatePunch[] = file.punches;
  if (punches.length === 0) throw new TransferError("invalid", "Súbor neobsahuje žiadne razenia.");
  if (
    file.count !== punches.length ||
    new Set(punches.map((p) => p.client_uuid)).size !== punches.length ||
    (await fingerprintPunches(punches)) !== file.fingerprint
  )
    throw new TransferError(
      "invalid",
      "Súbor s razeniami je poškodený alebo upravený (odtlačok nesedí).",
    );
  return describe(punches, file.created_at, file.origin, file.fingerprint);
}

/** Šifrovaný súbor z razení fronty. Heslo ostáva v prehliadači. */
export async function encryptLateFile(
  items: QueuedLike[],
  password: string,
  options: BuildOptions & { encrypt?: EncryptOptions | undefined },
): Promise<{ blob: Blob; file: LateFile }> {
  const text = await buildLateFileText(items, options);
  const blob = await encryptText(text, password, options.encrypt);
  // Kontrola hotového súboru: musí sa dať dešifrovať tým istým heslom a obsahovať presne tie isté razenia.
  const file = await readLateFile(blob, password);
  const expected = await fingerprintPunches(items.map(toLatePunch));
  if (file.fingerprint !== expected || file.punches.length !== items.length)
    throw new TransferError("invalid", "Kontrola vytvoreného súboru zlyhala, súbor sa neuložil.");
  return { blob, file };
}

/** Dešifruje a prečíta súbor. Zlé heslo (alebo poškodený šifrový text): `TransferCryptoError`; iný súbor alebo obsah: `TransferError`. */
export async function readLateFile(file: Blob, password: string): Promise<LateFile> {
  if (file.size > MAX_LATE_FILE_BYTES)
    throw new TransferError("invalid", "Súbor je príliš veľký na súbor s razeniami zo zariadenia.");
  let text: string;
  try {
    text = await decryptToText(file, password);
  } catch (e) {
    // Zlé heslo sa od poškodeného súboru nedá rozlíšiť; všetko ostatné (iný druh súboru, useknutý súbor) nie je súbor s razeniami.
    if (e instanceof TransferCryptoError && e.message === WRONG_PASSWORD_MESSAGE) throw e;
    throw new TransferError("invalid", NOT_LATE_FILE_MESSAGE);
  }
  return parseLateFileText(text);
}

export function lateFileName(at: Date, count: number): string {
  const p = (n: number) => String(n).padStart(2, "0");
  const stamp = `${at.getFullYear()}${p(at.getMonth() + 1)}${p(at.getDate())}-${p(at.getHours())}${p(at.getMinutes())}`;
  return `razenia-zo-zariadenia-${stamp}-${count}.dochs-enc`;
}

// ---------------------------------------------------------------------------------------------
// Nahratie na novom serveri (správca, karta Servis)
// ---------------------------------------------------------------------------------------------

export type LateReason =
  | "invalid"
  | "duplicate_in_file"
  | "unknown_account"
  | "unknown_code"
  | "future"
  | "too_old"
  | "closed_month"
  | "conflict"
  | "refused";

export const LATE_REASON_TEXT: Record<LateReason, string> = {
  invalid: "neplatný tvar razenia",
  duplicate_in_file: "to isté razenie je v súbore dvakrát",
  unknown_account: "účet v tejto organizácii neexistuje",
  unknown_code: "neznámy kód prerušenia",
  future: "čas je v budúcnosti",
  too_old: "razenie je staršie než 120 dní",
  closed_month: "mesiac je uzavretý",
  conflict: "na serveri už je razenie s rovnakým označením, ale iným obsahom",
  refused: "databáza razenie odmietla",
};

export const lateReasonText = (reason: string): string =>
  (LATE_REASON_TEXT as Record<string, string | undefined>)[reason] ?? reason;

const reportSchema = z.object({
  dry_run: z.boolean(),
  total: z.number().int().nonnegative(),
  acceptable: z.number().int().nonnegative(),
  inserted: z.number().int().nonnegative(),
  already: z.number().int().nonnegative(),
  rejected: z.number().int().nonnegative(),
  reasons: z.record(z.string(), z.number().int().nonnegative()),
  items: z.array(
    z.object({
      n: z.number().int(),
      reason: z.string(),
      client_time: z.string().nullable().optional(),
      code: z.string().nullable().optional(),
      direction: z.string().nullable().optional(),
      message: z.string().nullable().optional(),
    }),
  ),
  accounts: z.number().int().nonnegative(),
  // Rozpis po účtoch pridala migrácia 0020; starší server ho nevracia.
  by_account: z
    .array(
      z.object({
        sap_id: z.string().nullable().optional(),
        count: z.number().int().nonnegative(),
        from: z.string().nullable().optional(),
        to: z.string().nullable().optional(),
      }),
    )
    .optional(),
});

/** Rozpis zapísateľných razení podľa účtu (osobné číslo SAP, nikdy meno ani e-mail). */
export interface LateAccountLine {
  sapId: string | null;
  count: number;
  from: string | null;
  to: string | null;
}

export interface LateReport {
  dryRun: boolean;
  total: number;
  acceptable: number;
  inserted: number;
  already: number;
  rejected: number;
  reasons: { reason: string; text: string; count: number }[];
  items: {
    n: number;
    reason: string;
    text: string;
    clientTime: string | null;
    code: string | null;
    direction: string | null;
    message: string | null;
  }[];
  accounts: number;
  /** null = server rozpis nevracia (databáza bez migrácie 0020). */
  byAccount: LateAccountLine[] | null;
}

/** Slovenské skloňovanie „razenie“ podľa počtu (1 razenie, 2–4 razenia, 5 a viac razení). */
export function razeniaText(n: number): string {
  if (n === 1) return "1 razenie";
  if (n >= 2 && n <= 4) return `${n} razenia`;
  return `${n} razení`;
}

export function parseLateReport(value: unknown): LateReport {
  const parsed = reportSchema.safeParse(value);
  if (!parsed.success) throw new TransferError("invalid", "Server vrátil neočakávanú odpoveď.");
  const r = parsed.data;
  return {
    dryRun: r.dry_run,
    total: r.total,
    acceptable: r.acceptable,
    inserted: r.inserted,
    already: r.already,
    rejected: r.rejected,
    reasons: Object.entries(r.reasons)
      .map(([reason, count]) => ({ reason, text: lateReasonText(reason), count }))
      .sort((a, b) => b.count - a.count || a.reason.localeCompare(b.reason)),
    items: r.items.map((i) => ({
      n: i.n,
      reason: i.reason,
      text: lateReasonText(i.reason),
      clientTime: i.client_time ?? null,
      code: i.code ?? null,
      direction: i.direction ?? null,
      message: i.message ?? null,
    })),
    accounts: r.accounts,
    byAccount: r.by_account
      ? r.by_account.map((a) => ({
          sapId: a.sap_id ?? null,
          count: a.count,
          from: a.from ?? null,
          to: a.to ?? null,
        }))
      : null,
  };
}

/**
 * Pošle razenia zo súboru databáze. `dryRun` = skúška (nič sa nezapíše). Ostrý zápis sa po chybe spojenia NEopakuje sám: nevieme, či
 * prebehol. Opakovať ho ručne je bezpečné (to isté razenie sa druhý raz nezapíše, server ho vráti ako „už nahraté“).
 */
export async function importLatePunches(
  client: TransferClient,
  file: LateFile,
  dryRun: boolean,
  options: CallOptions = {},
): Promise<LateReport> {
  const payload = {
    format: LATE_FORMAT,
    version: LATE_VERSION,
    created_at: file.createdAt,
    origin: file.origin,
    count: file.punches.length,
    punches: file.punches,
  };
  const data = await call(
    client,
    "late_punches_import",
    { _payload: payload, _dry_run: dryRun },
    {
      ...options,
      retries: dryRun ? (options.retries ?? 2) : 0,
      missingMessage: LATE_MISSING_MESSAGE,
    },
  );
  return parseLateReport(data);
}
