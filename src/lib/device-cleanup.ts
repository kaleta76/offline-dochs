// Upratanie zariadenia po presťahovaní organizácie na iný server (docs/PRENOS-ORGANIZACIE.md).
//
// Volá sa LEN po výslovnom potvrdení človekom a až potom, čo si razenia uložil do súboru (ServerMoveNotice). Nič sa nemaže samo.
// Maže sa presne to, čo bolo v súbore (podľa client_uuid): razenie, ktoré medzitým pribudlo, v zariadení ostane.
//
// Čo aplikácia v prehliadači drží (stav k migrácii 0019):
//   IndexedDB  „dochadzka“ (fronta razení), „dochadzka-device“ (kľúče zariadenia podľa účtu),
//   localStorage  me-cache[:účet], terminal-buttons:účet:organizácia, org-code, personnel-number, idle_limit_hours, last_activity_at,
//                 idle_signout_pending, net-log:v1, server-move:v1, late-export:v1 a prihlásenie (sb-…-auth-token),
//   Cache Storage a service worker (offline obal aplikácie).
// Úplné upratanie (zmaže všetko vyššie) sa urobí len vtedy, keď v zariadení neostali žiadne iné razenia a nie je prihlásený účet,
// ktorého sa presťahovanie netýka. Inak sa zmažú len razenia zo súboru a údaje presťahovaných účtov, aby iný človek na spoločnom
// zariadení neprišiel o svoje razenia ani o overené zariadenie.

export const QUEUE_DB = "dochadzka";
export const DEVICE_DB = "dochadzka-device";

export interface CleanupDeps {
  removeQueued(uuids: string[]): Promise<void>;
  listAllQueued(): Promise<{ client_uuid: string; user_id: string }[]>;
  deleteDeviceKey(userId: string): Promise<void>;
  forgetMove(userIds: string[]): void;
  /** Id prihláseného účtu podľa lokálnej relácie (bez dopytu na server), alebo null. */
  sessionUserId(): Promise<string | null>;
  /** Zruší lokálnu reláciu (bez dopytu na server). */
  signOutLocal(): Promise<void>;
  storage: Pick<Storage, "removeItem" | "clear" | "key" | "length"> | null;
  sessionStorage: Pick<Storage, "clear"> | null;
  deleteDatabase(name: string): Promise<void>;
  cacheNames(): Promise<string[]>;
  deleteCache(name: string): Promise<boolean>;
  unregisterWorkers(): Promise<number>;
}

export interface CleanupRequest {
  /** client_uuid razení, ktoré sú v uloženom súbore. */
  uuids: string[];
  /** Účty presťahovanej organizácie, ktorým tieto razenia patria. */
  userIds: string[];
}

export interface CleanupResult {
  /** Koľko razení zo súboru sa zo zariadenia zmazalo. */
  removed: number;
  /** Koľko razení v zariadení ostalo (iné účty alebo razenia, ktoré v súbore neboli). */
  remaining: number;
  /** true = zmazané bolo všetko, čo aplikácia v prehliadači drží. */
  full: boolean;
  /** Kroky, ktoré sa nepodarili (upratanie pokračuje ďalej; razenia zo súboru sú zmazané vždy ako prvé). */
  problems: string[];
}

function keysOf(storage: Pick<Storage, "key" | "length">): string[] {
  const keys: string[] = [];
  for (let i = 0; i < storage.length; i += 1) {
    const k = storage.key(i);
    if (k !== null) keys.push(k);
  }
  return keys;
}

export async function cleanupAfterMove(
  request: CleanupRequest,
  deps: CleanupDeps,
): Promise<CleanupResult> {
  const problems: string[] = [];
  const attempt = async (label: string, step: () => Promise<unknown> | unknown) => {
    try {
      await step();
    } catch {
      problems.push(label);
    }
  };

  const wanted = new Set(request.uuids);
  const before = await deps.listAllQueued();
  const present = before.filter((p) => wanted.has(p.client_uuid)).map((p) => p.client_uuid);
  // Prvý a jediný krok, ktorý nesmie zlyhať potichu: ak sa razenia nepodarí zmazať, ďalej sa nič nemaže.
  await deps.removeQueued(present);
  const after = await deps.listAllQueued();
  const moved = new Set(request.userIds);
  // Účet, ktorému v zariadení ostalo razenie mimo súboru, si kľúč zariadenia a stav ponechá: ešte ich bude potrebovať.
  const done = request.userIds.filter((id) => !after.some((p) => p.user_id === id));

  for (const id of done) await attempt("kľúč zariadenia", () => deps.deleteDeviceKey(id));
  const storage = deps.storage;
  if (storage) {
    await attempt("uložené údaje účtu", () => {
      for (const key of keysOf(storage)) {
        if (
          done.some((id) => key === `me-cache:${id}` || key.startsWith(`terminal-buttons:${id}:`))
        )
          storage.removeItem(key);
      }
    });
  }
  await attempt("stav oznamu", () => deps.forgetMove(done));

  let sessionUser: string | null = null;
  await attempt("lokálne prihlásenie", async () => {
    sessionUser = await deps.sessionUserId();
  });
  const full = after.length === 0 && (sessionUser === null || moved.has(sessionUser));
  if (full) {
    await attempt("lokálne prihlásenie", () => deps.signOutLocal());
    await attempt("úložisko prehliadača", () => {
      deps.storage?.clear();
      deps.sessionStorage?.clear();
    });
    await attempt("fronta razení", () => deps.deleteDatabase(QUEUE_DB));
    await attempt("kľúče zariadenia", () => deps.deleteDatabase(DEVICE_DB));
    await attempt("offline obal aplikácie", async () => {
      for (const name of await deps.cacheNames()) await deps.deleteCache(name);
    });
    await attempt("service worker", () => deps.unregisterWorkers());
  }
  return {
    removed: present.length,
    remaining: after.length,
    full,
    problems: [...new Set(problems)],
  };
}

/** Zmazanie databázy IndexedDB; „blocked“ (otvorená v inej karte) je chyba, aby sa o nej človek dozvedel. */
export function deleteIndexedDb(name: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.deleteDatabase(name);
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error ?? new Error("Zmazanie databázy zlyhalo."));
    request.onblocked = () => reject(new Error("Databáza je otvorená v inej karte."));
  });
}
