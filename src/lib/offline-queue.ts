// Offline-first punch queue stored in IndexedDB. Punches are written locally first,
// then sent to the server; client_uuid makes resending idempotent.
//
// Network behaviour is tuned for strict corporate networks (proxy, SSL inspection, captive portals):
// - zero beaconing: nothing is sent while the local queue is empty, and the session is read locally;
// - server_inserted state: an accepted insert is never repeated, only re-verified;
// - two-phase verification: a select on punches first, the verify_punch_synced RPC only after a
//   transport failure (closed connection, HTML page from a proxy, 403/502/504);
// - certificate failures are logged visibly and are not retried silently in a loop;
// - exponential backoff with jitter; the "online" event and manual triggers reset it.
import { useEffect, useState, useSyncExternalStore } from "react";
import { supabase } from "@/integrations/supabase/client";
import { getDeviceKey } from "@/lib/device";

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

export type SyncErrorKind = "certificate" | "transport" | "other";

interface ErrorLike {
  message?: string | null;
  code?: string | null;
  status?: number | null;
}

const CERTIFICATE_PATTERNS: RegExp[] = [
  /ERR_CERT_/i,
  /ERR_SSL_/i,
  /SEC_ERROR_/i,
  /SSL_ERROR_/i,
  /certificate/i,
  /self[- ]signed/i,
  /unable to verify the first certificate/i,
  /UNABLE_TO_GET_ISSUER_CERT/i,
  /DEPTH_ZERO_SELF_SIGNED_CERT/i,
];

const TRANSPORT_PATTERNS: RegExp[] = [
  /failed to fetch/i, // Chrome / Edge
  /networkerror when attempting to fetch/i, // Firefox
  /load failed/i, // Safari
  /network request failed/i,
  /fetch failed/i,
  /unexpected token '<'/i, // HTML page parsed as JSON
  /<!doctype html/i, // proxy / captive-portal page returned as error body
  /<html[\s>]/i,
  /connection (was )?(closed|reset|aborted)/i,
  /ERR_CONNECTION_(CLOSED|RESET|ABORTED)/i,
  /ERR_EMPTY_RESPONSE/i,
  /ECONNRESET/i,
  /socket hang up/i,
];

const TRANSPORT_STATUSES = new Set([502, 504]);

/** Classifies a failed request. Certificate errors are never treated as an ordinary outage. */
export function classifySyncError(error: unknown, status?: number | null): SyncErrorKind {
  const e = (error ?? {}) as ErrorLike;
  const message =
    typeof error === "string"
      ? error
      : String(e.message ?? (error instanceof Error ? error.message : ""));
  const code = e.code ?? "";
  const httpStatus = status ?? e.status ?? null;
  if (CERTIFICATE_PATTERNS.some((p) => p.test(message))) return "certificate";
  if (TRANSPORT_PATTERNS.some((p) => p.test(message))) return "transport";
  if (httpStatus != null && TRANSPORT_STATUSES.has(httpStatus)) return "transport";
  // A 403 without a database error code comes from a proxy / gateway, not from RLS or grants.
  if (httpStatus === 403 && !code) return "transport";
  return "other";
}

const CERTIFICATE_MESSAGE =
  "Zabezpečené spojenie odmietnuté (certifikát). Záznam zostáva v zariadení – kontaktujte IT.";

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
  blockedBy: "certificate" | null;
}
const state: SyncState = { failures: 0, nextAttemptAt: 0, blockedBy: null };
let retryTimer: ReturnType<typeof setTimeout> | null = null;

export function getSyncStatus(): Readonly<SyncState> & { retryScheduled: boolean } {
  return { ...state, retryScheduled: retryTimer !== null };
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

type ItemOutcome = "done" | "retry" | "certificate";

async function save(item: QueuedPunch) {
  await tx("readwrite", (s) => s.put(item));
}

async function syncItem(item: QueuedPunch, uid: string): Promise<ItemOutcome> {
  let current = item;
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
      if (/jwt|token|unauthorized/i.test(error.message) || error.code === "42501") return "retry";
      await save({ ...current, error: error.message });
      return "retry"; // Do not send later events out of order after rejection.
    }
    // Accepted, or this client_uuid already exists: never insert it again, only verify.
    // A generic unique violation is never evidence that this punch was accepted.
    current = { ...current, server_inserted: true };
    await save(current);
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
      return "retry";
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
  if (readKind !== "transport") return "retry"; // auth / RLS / conflict: unchanged behaviour, flag kept.

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
    return "retry";
  }
  if (verified.data === true) {
    await tx("readwrite", (s) => s.delete(current.client_uuid));
    return "done";
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
  else if (state.blockedBy === "certificate") return;
  else if (trigger === "auto" && (retryTimer !== null || Date.now() < state.nextAttemptAt)) return;

  if (syncing) {
    if (trigger === "manual" || trigger === "online") rerunRequested = true;
    return;
  }
  if (typeof navigator === "undefined" || !navigator.onLine) return;

  syncing = true;
  let outcome: ItemOutcome | "idle" = "idle";
  try {
    // Zero beaconing: decide from local data only; no request when nothing is waiting.
    await refresh();
    if (snapshot.length === 0) return;
    const { data } = await supabase.auth.getSession();
    const uid = data.session?.user.id;
    const own = uid ? snapshot.filter((p) => p.user_id === uid) : [];
    if (!uid || own.length === 0) return;

    outcome = "done";
    for (const item of own) {
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

export function useQueue(userId?: string) {
  const items = useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    () => snapshot,
    () => snapshot,
  );
  const [online, setOnline] = useState(true);
  useEffect(() => {
    setOnline(navigator.onLine);
    void refresh().then(() => syncQueue("auto"));
    const on = () => {
      setOnline(true);
      void syncQueue("online");
    };
    const off = () => setOnline(false);
    window.addEventListener("online", on);
    window.addEventListener("offline", off);
    const iv = setInterval(() => void syncQueue("auto"), 30_000);
    return () => {
      window.removeEventListener("online", on);
      window.removeEventListener("offline", off);
      clearInterval(iv);
    };
  }, []);
  return { items: items.filter((item) => item.user_id === userId), online };
}
