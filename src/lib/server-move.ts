// Oznam o presťahovaní organizácie na iný server (migrácia 0019, docs/PRENOS-ORGANIZACIE.md).
//
// Fronta razení (offline-queue.ts) o prenose organizácie nevie: počas exportu so zámkom databáza razenie odmietne a po zrušení pôvodnej
// organizácie účet zanikne a odoslanie už nikdy neprejde. Tento modul zistí, čo sa stalo, aby zariadenie vedelo človeku povedať pravdu
// a ponúknuť uloženie razení do súboru (ServerMoveNotice).
//
// Zásada „žiadne zbytočné dopyty“ ostáva:
//   * zámok prenosu (SQLSTATE 55000) sa pozná z odpovede na samotné razenie, bez ďalšieho dopytu,
//   * funkcia punch_move_notice sa volá len vtedy, keď sú vo fronte razenia A ZÁROVEŇ server razenie neprijal, alebo razenia patria
//     účtu, ktorý nie je prihlásený (po zrušení organizácie sa prihlásiť nedá), a najviac raz za CHECK_INTERVAL_MS,
//   * pri prázdnej fronte sa neposiela nič.
// Dopyt ide bez prihlásenia a posiela len id účtov z fronty; odpoveď je stav, voliteľná nová adresa a voliteľná správa od správcu
// (migrácia 0020), žiadne osobné údaje.
import { z } from "zod";

/** transferring = organizácia sa práve prenáša; moved = presťahovaná na iný server; ended = zrušená bez presunu (migrácia 0020). */
export type MoveState = "transferring" | "moved" | "ended";

export interface MoveInfo {
  state: MoveState;
  /** Nová adresa aplikácie, ak ju správca pri prenose uložil (len http/https, bez mena a hesla). */
  url: string | null;
  /** Správa od správcu (jeden riadok čistého textu), ak ju uložil. Ukazuje sa vždy ako text, nikdy ako HTML ani odkaz. */
  message: string | null;
}

export type MoveMap = Readonly<Record<string, MoveInfo>>;

export const MOVE_STORAGE_KEY = "server-move:v1";
/** Najkratší odstup dvoch dopytov na oznam (ručné „Skontrolovať znova“ ho obchádza). */
export const CHECK_INTERVAL_MS = 10 * 60 * 1000;
/** Rovnaký limit ako org_transfer.move_limits() v migrácii 0019. */
export const MAX_NOTICE_USERS = 50;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** Rovnaký limit ako org_transfer.valid_message v migrácii 0020 (tá rozhoduje). */
export const MAX_MESSAGE_LENGTH = 300;
// Riadiace znaky, znaky skrývajúce text a znaky meniace smer písma (zero-width, bidi, oddeľovače riadkov).
/* eslint-disable no-control-regex */
const MESSAGE_FORBIDDEN =
  /[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2066-\u2069\ufeff]/;
/* eslint-enable no-control-regex */

/** Správa z oznamu sa ukazuje ľuďom: prejde len čistý jednoriadkový text bez okrajových medzier. Inak null. */
export function safeMessage(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const length = [...value].length;
  if (length < 1 || length > MAX_MESSAGE_LENGTH) return null;
  if (value !== value.trim() || MESSAGE_FORBIDDEN.test(value)) return null;
  return value;
}

/** Adresa z oznamu sa ukazuje ľuďom ako odkaz: prejde len čisté http(s) bez mena, hesla, dopytu a kotvy. Inak null. */
export function safeDestination(value: unknown): string | null {
  if (typeof value !== "string" || value.length < 10 || value.length > 200) return null;
  if (
    !/^https?:\/\/[A-Za-z0-9]([A-Za-z0-9.-]{0,150}[A-Za-z0-9])?(:[0-9]{1,5})?(\/[A-Za-z0-9._~/-]{0,100})?$/.test(
      value,
    )
  )
    return null;
  try {
    const url = new URL(value);
    if (
      (url.protocol !== "https:" && url.protocol !== "http:") ||
      url.username ||
      url.password ||
      url.search ||
      url.hash
    )
      return null;
    return value;
  } catch {
    return null;
  }
}

const noticeSchema = z.object({
  users: z.record(
    z.string(),
    z
      .object({
        state: z.enum(["transferring", "moved", "ended"]),
        url: z.unknown().optional(),
        message: z.unknown().optional(),
      })
      .passthrough(),
  ),
});

/** Odpoveď funkcie punch_move_notice → stav podľa účtu. Neznámy tvar je chyba (null), nie „nič sa nedeje“. */
export function parseNotice(value: unknown): Record<string, MoveInfo> | null {
  const parsed = noticeSchema.safeParse(value);
  if (!parsed.success) return null;
  const out: Record<string, MoveInfo> = {};
  for (const [id, info] of Object.entries(parsed.data.users)) {
    if (UUID.test(id))
      out[id] = {
        state: info.state,
        url: safeDestination(info.url),
        message: safeMessage(info.message),
      };
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// Stav (jeden na stránku, kópia v localStorage, aby oznam „presťahované“ prežil nové načítanie aj prácu bez siete)
// ---------------------------------------------------------------------------------------------

type Store = Pick<Storage, "getItem" | "setItem" | "removeItem">;

function browserStore(): Store | null {
  try {
    return typeof window === "undefined" ? null : window.localStorage;
  } catch {
    return null;
  }
}

const storedSchema = z.object({
  checkedAt: z.number().nonnegative(),
  users: z.record(
    z.string(),
    z.object({
      state: z.enum(["transferring", "moved", "ended"]),
      url: z.string().nullable(),
      // kópia z verzie pred migráciou 0020 správu nemá
      message: z.string().nullable().optional(),
    }),
  ),
});

let users: MoveMap = {};
let checkedAt = 0;
let loaded = false;
let inFlight: Promise<void> | null = null;
const listeners = new Set<() => void>();

function load(store: Store | null) {
  if (loaded) return;
  loaded = true;
  try {
    const parsed = storedSchema.safeParse(JSON.parse(store?.getItem(MOVE_STORAGE_KEY) ?? "null"));
    if (!parsed.success) return;
    checkedAt = parsed.data.checkedAt;
    const next: Record<string, MoveInfo> = {};
    for (const [id, info] of Object.entries(parsed.data.users))
      if (UUID.test(id))
        next[id] = {
          state: info.state,
          url: safeDestination(info.url),
          message: safeMessage(info.message),
        };
    users = next;
  } catch {
    // poškodená kópia: začína sa odznova
  }
}

function commit(next: Record<string, MoveInfo>, store: Store | null) {
  const same =
    Object.keys(next).length === Object.keys(users).length &&
    Object.entries(next).every(
      ([id, i]) =>
        users[id]?.state === i.state &&
        users[id]?.url === i.url &&
        users[id]?.message === i.message,
    );
  if (!same) users = next;
  try {
    if (Object.keys(next).length === 0 && checkedAt === 0) store?.removeItem(MOVE_STORAGE_KEY);
    else store?.setItem(MOVE_STORAGE_KEY, JSON.stringify({ checkedAt, users: next }));
  } catch {
    // bez úložiska platí stav len do zatvorenia stránky
  }
  if (!same) listeners.forEach((l) => l());
}

export function subscribeMove(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export function getMoveSnapshot(store: Store | null = browserStore()): MoveMap {
  load(store);
  return users;
}

/** Zámok prenosu poznaný z odpovede na razenie (bez dopytu). Stav „moved“ sa ním neprepíše. */
export function noteTransferLock(userId: string, store: Store | null = browserStore()): void {
  load(store);
  if (!UUID.test(userId) || users[userId]) return;
  commit({ ...users, [userId]: { state: "transferring", url: null, message: null } }, store);
}

/** Server razenie účtu prijal: organizácia sa neprenáša ani nepresťahovala. */
export function noteAccepted(userId: string, store: Store | null = browserStore()): void {
  load(store);
  if (!users[userId]) return;
  const next = { ...users };
  delete next[userId];
  commit(next, store);
}

/** Zabudne stav vymenovaných účtov (po uprataní zariadenia). */
export function forgetMove(userIds: string[], store: Store | null = browserStore()): void {
  load(store);
  const next = { ...users };
  for (const id of userIds) delete next[id];
  commit(next, store);
}

export interface NoticeClient {
  rpc(
    fn: string,
    args?: Record<string, unknown>,
  ): PromiseLike<{ data: unknown; error: { message: string; code?: string | null } | null }>;
}

export interface CheckOptions {
  /** Ručná kontrola: obíde odstup medzi dopytmi. */
  force?: boolean | undefined;
  now?: (() => number) | undefined;
  store?: Store | null | undefined;
  online?: (() => boolean) | undefined;
}

export type CheckResult = "checked" | "skipped" | "failed";

/**
 * Opýta sa servera na stav účtov z fronty. Odpoveď nahradí doterajší stav týchto účtov (účet, ktorý v odpovedi nie je, sa neprenáša).
 * Pri chybe spojenia alebo chýbajúcej funkcii (nespustená migrácia 0019) sa stav NEMENÍ: nevedieť nie je to isté ako „nič sa nedeje“.
 */
export async function checkMoveNotice(
  client: NoticeClient,
  userIds: string[],
  options: CheckOptions = {},
): Promise<CheckResult> {
  const store = options.store === undefined ? browserStore() : options.store;
  const now = options.now ?? Date.now;
  load(store);
  const ids = [...new Set(userIds.filter((id) => UUID.test(id)))].sort().slice(0, MAX_NOTICE_USERS);
  if (ids.length === 0) return "skipped";
  const online = options.online ?? (() => typeof navigator === "undefined" || navigator.onLine);
  if (!online()) return "skipped";
  if (!options.force && now() - checkedAt < CHECK_INTERVAL_MS) return "skipped";
  if (inFlight) {
    await inFlight;
    return "skipped";
  }
  let result: CheckResult = "failed";
  // Čas pokusu sa zapíše vopred: ani chyba nesmie viesť k dopytu pri každom pokuse o odoslanie.
  checkedAt = now();
  inFlight = (async () => {
    try {
      const res = await client.rpc("punch_move_notice", { _users: ids });
      const parsed = res.error ? null : parseNotice(res.data);
      if (!parsed) {
        commit({ ...users }, store);
        return;
      }
      const next = { ...users };
      for (const id of ids) {
        const info = parsed[id];
        if (info) next[id] = info;
        else delete next[id];
      }
      commit(next, store);
      result = "checked";
    } catch {
      commit({ ...users }, store);
    }
  })();
  try {
    await inFlight;
  } finally {
    inFlight = null;
  }
  return result;
}

/** Len pre testy: vráti modul do stavu po načítaní stránky. */
export function resetMoveStateForTests(): void {
  users = {};
  checkedAt = 0;
  loaded = false;
  inFlight = null;
  listeners.clear();
}
