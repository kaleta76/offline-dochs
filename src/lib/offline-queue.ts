// Offline-first punch queue stored in IndexedDB. Punches are written locally first,
// then sent to the server; client_uuid makes resending idempotent.
//
// Network behaviour is tuned for strict corporate networks (proxy, SSL inspection, captive portals):
// - zero beaconing: nothing is sent while the local queue is empty, and the session is read locally;
// - server_inserted state: an accepted insert is never repeated, only re-verified;
// - two-phase verification: a select on punches first, the verify_punch_synced RPC only after a
//   transport failure (closed connection, HTML page from a proxy, 403/502/504);
// - certificate failures are logged visibly and are not retried silently in a loop;
// - a punch the database definitely rejects (closed month, constraint, unconfirmed by the server) is parked: no timer,
//   no periodic retry, one attempt only on "Odoslať teraz" or the "online" event; it stays on the device until resolved;
// - exponential backoff with jitter for everything else; the "online" event and manual triggers reset it;
// - one module-level runtime (listeners, 30 s check) shared by every useQueue instance;
// - the queue itself never asks whether the organization moved to another server: it only reports what happened to
//   observers (observeQueue), and src/lib/server-move.ts decides whether one small request is worth sending.
import { useEffect, useState, useSyncExternalStore } from "react";
import { supabase } from "@/integrations/supabase/client";
import { getDeviceKey } from "@/lib/device";
import { classifySyncError, isDefiniteRejection, isMissingFunction } from "./sync-error";

export interface QueuedPunch {
  client_uuid: string;
  user_id: string;
  code: string;
  direction: "IN" | "OUT";
  client_time: string;
  device: string;
  /** Raw device key; server hashes it to mark the punch verified, then discards it. */
  device_token?: string;
  /** The server accepted the insert (or reported this client_uuid as duplicate); only verification remains. */
  server_inserted?: boolean;
  error?: string;
}

const DB = "dochadzka";
const STORE = "queue";

function openDb(): Promise<IDBDatabase> {
  return new Promise((res, rej) => {
    const r = indexedDB.open(DB, 1);
    r.onupgradeneeded = () => r.result.createObjectStore(STORE, { keyPath: "client_uuid" });
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
}
async function tx<T>(
  mode: IDBTransactionMode,
  fn: (s: IDBObjectStore) => IDBRequest<T>,
): Promise<T> {
  const db = await openDb();
  return new Promise((res, rej) => {
    const transaction = db.transaction(STORE, mode);
    const req = fn(transaction.objectStore(STORE));
    transaction.oncomplete = () => {
      db.close();
      res(req.result);
    };
    transaction.onerror = () => {
      db.close();
      rej(transaction.error ?? req.error);
    };
    transaction.onabort = () => {
      db.close();
      rej(transaction.error ?? new Error("Uloženie záznamu zlyhalo."));
    };
  });
}

let snapshot: QueuedPunch[] = [];
const listeners = new Set<() => void>();
async function refresh() {
  snapshot = (await tx<QueuedPunch[]>("readonly", (s) => s.getAll())).sort((a, b) =>
    a.client_time.localeCompare(b.client_time),
  );
  listeners.forEach((l) => l());
}

/**
 * Čo sa pri odosielaní stalo, pre oznam o presťahovaní organizácie (src/lib/server-move.ts). Fronta sama nič navyše neposiela.
 * transfer-lock: databáza razenie odmietla, lebo organizáciu práve prenášajú (SQLSTATE 55000); accepted: server razenie prijal;
 * refused: server odpovedal, ale razenie neprijal (prihlásenie, oprávnenie, odmietnutie); unsent: vo fronte sú razenia účtov,
 * ktoré teraz nie sú prihlásené.
 */
export type QueueEvent =
  | { type: "transfer-lock" | "accepted" | "refused"; userId: string }
  | { type: "unsent"; userIds: string[] };

const observers = new Set<(event: QueueEvent) => void>();

/** Prihlási pozorovateľa udalostí fronty; vrátená funkcia ho odhlási. Chyba pozorovateľa odosielanie nikdy nezastaví. */
export function observeQueue(observer: (event: QueueEvent) => void): () => void {
  observers.add(observer);
  return () => {
    observers.delete(observer);
  };
}

function emit(event: QueueEvent) {
  observers.forEach((observer) => {
    try {
      observer(event);
    } catch {
      // pozorovateľ je len doplnok; razenia sa odosielajú ďalej
    }
  });
}

/** SQLSTATE zámku razení počas prenosu organizácie (migrácia 0016, punches_transfer_lock). */
export const TRANSFER_LOCK_CODE = "55000";

export async function enqueue(
  p: Omit<
    QueuedPunch,
    "client_uuid" | "client_time" | "device" | "device_token" | "server_inserted" | "error"
  >,
) {
  const key = await getDeviceKey(p.user_id);
  const item: QueuedPunch = {
    ...p,
    ...(key ? { device_token: key.token } : {}),
    client_uuid: crypto.randomUUID(),
    client_time: new Date().toISOString(),
    device: navigator.userAgent.slice(0, 60),
  };
  await tx("readwrite", (s) => s.put(item));
  await refresh();
  void syncQueue("manual");
  return item;
}

// ---------------------------------------------------------------------------------------------
// Error classification (explicit, no catch-all)
// ---------------------------------------------------------------------------------------------

export { classifySyncError };
export type { SyncErrorKind } from "./sync-error";

/** Neutral text shown whenever sending or confirming fails (network, offline, blocked connection). */
export const SYNC_FAILED_MESSAGE =
  "Odoslanie sa nepodarilo potvrdiť, razenia sú uložené v zariadení.";
// The certificate cause is logged to the console only; the screen stays neutral.
const CERTIFICATE_MESSAGE = SYNC_FAILED_MESSAGE;
const UNCONFIRMED_MESSAGE = "Server toto razenie nepotvrdil. Razenie ostáva uložené v zariadení.";
const MISSING_VERIFY_MESSAGE =
  "Záložné overenie nie je v databáze dostupné. Razenie ostáva uložené v zariadení.";

function logCertificate(context: string, error: unknown) {
  console.error(
    `[offline-queue] Chyba certifikátu (${context}) – automatické opakovanie je pozastavené.`,
    error,
  );
}

// ---------------------------------------------------------------------------------------------
// Backoff with jitter
// ---------------------------------------------------------------------------------------------

export const BACKOFF_STEPS_MS = [2_000, 5_000, 15_000, 30_000, 60_000] as const;
export const BACKOFF_MAX_MS = 60_000;

/** Delay for the n-th consecutive failure (1-based), with ±25 % jitter, never above 60 s. */
export function backoffDelay(failures: number, random: () => number = Math.random): number {
  if (failures <= 0) return 0;
  const base = BACKOFF_STEPS_MS[Math.min(failures, BACKOFF_STEPS_MS.length) - 1] ?? BACKOFF_MAX_MS;
  return Math.min(BACKOFF_MAX_MS, Math.max(0, Math.round(base * (0.75 + random() * 0.5))));
}

export type SyncTrigger = "manual" | "online" | "auto" | "retry";

interface SyncState {
  failures: number;
  nextAttemptAt: number;
  /** certificate: pauses automatic retries; rejected: the oldest punch was refused for good (parked). */
  blockedBy: "certificate" | "rejected" | null;
  /** client_uuid of the parked punch while blockedBy is "rejected". */
  blockedItem: string | null;
}
const state: SyncState = { failures: 0, nextAttemptAt: 0, blockedBy: null, blockedItem: null };
let retryTimer: ReturnType<typeof setTimeout> | null = null;

export function getSyncStatus(): Readonly<SyncState> & { retryScheduled: boolean } {
  return { ...state, retryScheduled: retryTimer !== null };
}

/** True after a failed send or confirmation until the next successful synchronization. */
export function hasSyncFailed(): boolean {
  return state.failures > 0 || state.blockedBy !== null;
}

function clearRetry() {
  if (retryTimer !== null) clearTimeout(retryTimer);
  retryTimer = null;
}

export function resetBackoff() {
  clearRetry();
  state.failures = 0;
  state.nextAttemptAt = 0;
  state.blockedBy = null;
  state.blockedItem = null;
}

function scheduleRetry() {
  clearRetry();
  state.failures += 1;
  const delay = backoffDelay(state.failures);
  state.nextAttemptAt = Date.now() + delay;
  retryTimer = setTimeout(() => {
    retryTimer = null;
    void syncQueue("retry");
  }, delay);
}

// ---------------------------------------------------------------------------------------------
// Synchronization
// ---------------------------------------------------------------------------------------------

type ItemOutcome = "done" | "retry" | "certificate" | "parked";

async function save(item: QueuedPunch) {
  await tx("readwrite", (s) => s.put(item));
}

async function syncItem(item: QueuedPunch, uid: string): Promise<ItemOutcome> {
  let current = item;
  let duplicateReported = false;
  if (!current.server_inserted) {
    const { error, status } = await supabase.from("punches").insert({
      client_uuid: current.client_uuid,
      user_id: current.user_id,
      code: current.code,
      direction: current.direction,
      client_time: current.client_time,
      device: current.device,
      ...(current.device_token ? { device_token: current.device_token } : {}),
    });
    if (error && error.code !== "23505") {
      const kind = classifySyncError(error, status);
      if (kind === "certificate") {
        logCertificate("odoslanie", error);
        await save({ ...current, error: CERTIFICATE_MESSAGE });
        return "certificate";
      }
      if (kind === "transport") return "retry";
      // The server answered and did not take the punch: let the observer find out whether the organization moved.
      emit({
        type: error.code === TRANSFER_LOCK_CODE ? "transfer-lock" : "refused",
        userId: current.user_id,
      });
      if (/jwt|token|unauthorized/i.test(error.message) || error.code === "42501") return "retry";
      await save({ ...current, error: error.message });
      // A definite refusal (closed month, constraint, invalid value) never succeeds by waiting: park it.
      // Later events are still not sent out of order, and nothing is discarded automatically.
      return isDefiniteRejection(error, status) ? "parked" : "retry";
    }
    duplicateReported = error?.code === "23505";
    // Accepted, or this client_uuid already exists: never insert it again, only verify.
    // A generic unique violation is never evidence that this punch was accepted.
    current = { ...current, server_inserted: true };
    await save(current);
    emit({ type: "accepted", userId: current.user_id });
  }

  // Phase 1: read back exact owner and payload before deleting the durable local copy.
  const accepted = await supabase
    .from("punches")
    .select("client_uuid, user_id, code, direction, client_time, device")
    .eq("client_uuid", current.client_uuid)
    .eq("user_id", uid)
    .maybeSingle();

  if (!accepted.error) {
    const row = accepted.data;
    if (!row) {
      // Confirmed missing: the insert must be repeated on the next attempt.
      if (duplicateReported) {
        // The server reports a duplicate but shows no such punch of this user: waiting does not resolve it.
        await save({ ...current, server_inserted: false, error: UNCONFIRMED_MESSAGE });
        return "parked";
      }
      await save({ ...current, server_inserted: false });
      return "retry";
    }
    if (
      row.code !== current.code ||
      row.direction !== current.direction ||
      row.device !== current.device ||
      new Date(row.client_time).getTime() !== new Date(current.client_time).getTime()
    ) {
      await save({ ...current, error: "Konflikt záznamu – záznam zostáva uložený v zariadení." });
      return "parked";
    }
    await tx("readwrite", (s) => s.delete(current.client_uuid));
    return "done";
  }

  const readKind = classifySyncError(accepted.error, accepted.status);
  if (readKind === "certificate") {
    logCertificate("overenie", accepted.error);
    await save({ ...current, error: CERTIFICATE_MESSAGE });
    return "certificate";
  }
  if (readKind !== "transport") {
    // auth / RLS: unchanged behaviour, flag kept. Only a definite database refusal is parked.
    if (isDefiniteRejection(accepted.error, accepted.status)) {
      await save({ ...current, error: accepted.error.message });
      return "parked";
    }
    return "retry";
  }

  // Phase 2 (fallback only after a transport failure): ownership is checked server-side via auth.uid().
  const verified = await supabase.rpc("verify_punch_synced", {
    p_client_uuid: current.client_uuid,
    p_code: current.code,
    p_direction: current.direction,
    p_client_time: current.client_time,
    p_device: current.device,
  });
  if (verified.error) {
    if (classifySyncError(verified.error, verified.status) === "certificate") {
      logCertificate("overenie RPC", verified.error);
      await save({ ...current, error: CERTIFICATE_MESSAGE });
      return "certificate";
    }
    if (isMissingFunction(verified.error)) {
      // The fallback function is not installed in this database; repeating it every minute cannot help.
      await save({ ...current, error: MISSING_VERIFY_MESSAGE });
      return "parked";
    }
    return "retry";
  }
  if (verified.data === true) {
    await tx("readwrite", (s) => s.delete(current.client_uuid));
    return "done";
  }
  if (verified.data === false) {
    // The server answered and does not hold this exact punch. Clear the flag so that the next manual attempt
    // inserts again (idempotent by client_uuid); until then nothing is repeated automatically.
    await save({ ...current, server_inserted: false, error: UNCONFIRMED_MESSAGE });
    return "parked";
  }
  return "retry";
}

let syncing = false;
let rerunRequested = false;

/**
 * Sends pending punches. "manual" and "online" reset the backoff; "auto" (periodic check) respects
 * the backoff and a certificate block; "retry" is the scheduled backoff attempt.
 */
export async function syncQueue(trigger: SyncTrigger = "manual") {
  if (trigger === "manual" || trigger === "online") resetBackoff();
  else if (state.blockedBy !== null) return; // certificate or parked punch: only manual / online attempts
  else if (trigger === "auto" && (retryTimer !== null || Date.now() < state.nextAttemptAt)) return;

  if (syncing) {
    if (trigger === "manual" || trigger === "online") rerunRequested = true;
    return;
  }
  if (typeof navigator === "undefined" || !navigator.onLine) return;

  syncing = true;
  let outcome: ItemOutcome | "idle" = "idle";
  let lastItem: string | null = null;
  try {
    // Zero beaconing: decide from local data only; no request when nothing is waiting.
    await refresh();
    if (snapshot.length === 0) return;
    const { data } = await supabase.auth.getSession();
    const uid = data.session?.user.id;
    const own = uid ? snapshot.filter((p) => p.user_id === uid) : [];
    const others = [...new Set(snapshot.filter((p) => p.user_id !== uid).map((p) => p.user_id))];
    if (others.length > 0) emit({ type: "unsent", userIds: others });
    if (!uid || own.length === 0) return;

    outcome = "done";
    for (const item of own) {
      lastItem = item.client_uuid;
      if (!navigator.onLine) {
        outcome = "retry";
        break;
      }
      const current = await supabase.auth.getSession();
      if (current.data.session?.user.id !== uid) {
        outcome = "retry";
        break;
      }
      outcome = await syncItem(item, uid);
      if (outcome !== "done") break;
    }
  } catch (error) {
    // Network or auth failure: retain all unacknowledged events for the next retry.
    if (classifySyncError(error) === "certificate") {
      logCertificate("synchronizácia", error);
      outcome = "certificate";
    } else {
      outcome = "retry";
    }
  } finally {
    syncing = false;
    await refresh().catch(() => undefined);
    if (outcome === "done") resetBackoff();
    else if (outcome === "certificate") {
      clearRetry();
      state.blockedBy = "certificate";
    } else if (outcome === "parked") {
      clearRetry();
      state.blockedBy = "rejected";
      state.blockedItem = lastItem;
    } else if (outcome === "retry") scheduleRetry();
    listeners.forEach((l) => l());
    if (rerunRequested) {
      rerunRequested = false;
      void syncQueue("manual");
    }
  }
}

/** Manual trigger: resets the backoff (and a certificate block) and syncs immediately. */
export function syncNow() {
  return syncQueue("manual");
}

export async function discard(uuid: string) {
  await tx("readwrite", (s) => s.delete(uuid));
  await refresh();
}

/** Všetky razenia vo fronte bez ohľadu na účet, v poradí času (čerstvo prečítané zo zariadenia). */
export async function listAllQueued(): Promise<QueuedPunch[]> {
  await refresh();
  return snapshot;
}

/**
 * Odstráni vymenované razenia zo zariadenia jednou transakciou. Volá sa len po výslovnom potvrdení človekom (upratanie po
 * presťahovaní organizácie, src/lib/device-cleanup.ts); nič iné razenia hromadne nemaže.
 */
export async function removeQueued(uuids: string[]): Promise<void> {
  if (uuids.length > 0) {
    const db = await openDb();
    await new Promise<void>((res, rej) => {
      const transaction = db.transaction(STORE, "readwrite");
      const store = transaction.objectStore(STORE);
      for (const uuid of uuids) store.delete(uuid);
      transaction.oncomplete = () => {
        db.close();
        res();
      };
      const fail = () => {
        db.close();
        rej(transaction.error ?? new Error("Zmazanie razení zlyhalo."));
      };
      transaction.onerror = fail;
      transaction.onabort = fail;
    });
  }
  await refresh();
}

/**
 * Explicit, user-confirmed removal of a parked punch from this device, then an immediate attempt with the
 * remaining punches. The server never accepted the discarded punch; nothing is removed automatically.
 */
export async function discardParked(uuid: string) {
  await discard(uuid);
  await syncQueue("manual");
}

/**
 * A punch parked for one account must not pause synchronization for another account on the same device:
 * when a different user is signed in (or the parked punch is gone), the parked state is released.
 */
export function releaseParkedFor(userId: string) {
  if (state.blockedBy !== "rejected") return;
  const parked = snapshot.find((item) => item.client_uuid === state.blockedItem);
  if (parked && parked.user_id === userId) return;
  resetBackoff();
  listeners.forEach((l) => l());
}

/** client_uuid of the punch parked after a definite refusal, or null. */
export function getParkedUuid(): string | null {
  return state.blockedBy === "rejected" ? state.blockedItem : null;
}

function subscribe(l: () => void) {
  listeners.add(l);
  return () => {
    listeners.delete(l);
  };
}
const getSnapshot = () => snapshot;

// ---------------------------------------------------------------------------------------------
// One shared runtime: the "online" listener and the 30 s check exist once per page, however many
// components use useQueue (AppShell and the terminal). Two copies would repeat every online event.
// ---------------------------------------------------------------------------------------------

let runtimeUsers = 0;
let stopRuntime: (() => void) | null = null;

/** Starts the shared runtime on the first call; the returned function stops it after the last user left. */
export function startQueueRuntime(): () => void {
  runtimeUsers += 1;
  if (runtimeUsers === 1) {
    void refresh().then(() => syncQueue("auto"));
    const onOnline = () => void syncQueue("online");
    window.addEventListener("online", onOnline);
    const interval = setInterval(() => void syncQueue("auto"), 30_000);
    stopRuntime = () => {
      window.removeEventListener("online", onOnline);
      clearInterval(interval);
    };
  }
  let released = false;
  return () => {
    if (released) return;
    released = true;
    runtimeUsers -= 1;
    if (runtimeUsers === 0) {
      stopRuntime?.();
      stopRuntime = null;
    }
  };
}

const getParked = () => getParkedUuid();

/** Všetky razenia vo fronte bez ohľadu na účet (pre oznam o presťahovaní organizácie, ktorý sa ukazuje aj neprihlásenému). */
export function useAllQueued(): QueuedPunch[] {
  const items = useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
  useEffect(() => {
    void refresh().catch(() => undefined);
  }, []);
  return items;
}

export function useQueue(userId?: string) {
  const items = useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
  const syncFailed = useSyncExternalStore(subscribe, hasSyncFailed, () => false);
  const parkedUuid = useSyncExternalStore(subscribe, getParked, () => null);
  const [online, setOnline] = useState(true);
  useEffect(() => {
    if (userId) releaseParkedFor(userId);
  }, [userId]);
  useEffect(() => {
    setOnline(navigator.onLine);
    void refresh();
    const release = startQueueRuntime();
    const on = () => setOnline(true);
    const off = () => setOnline(false);
    window.addEventListener("online", on);
    window.addEventListener("offline", off);
    return () => {
      window.removeEventListener("online", on);
      window.removeEventListener("offline", off);
      release();
    };
  }, []);
  const own = items.filter((item) => item.user_id === userId);
  const parked = parkedUuid ? (own.find((item) => item.client_uuid === parkedUuid) ?? null) : null;
  return { items: own, online, syncFailed, parked };
}
