// Offline-first punch queue stored in IndexedDB. Punches are written locally first,
// then sent to the server; client_uuid makes resending idempotent.
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
async function tx<T>(mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await openDb();
  return new Promise((res, rej) => {
    const transaction = db.transaction(STORE, mode);
    const req = fn(transaction.objectStore(STORE));
    transaction.oncomplete = () => { db.close(); res(req.result); };
    transaction.onerror = () => { db.close(); rej(transaction.error ?? req.error); };
    transaction.onabort = () => { db.close(); rej(transaction.error ?? new Error('Uloženie záznamu zlyhalo.')); };
  });
}

let snapshot: QueuedPunch[] = [];
const listeners = new Set<() => void>();
async function refresh() {
  snapshot = (await tx<QueuedPunch[]>("readonly", (s) => s.getAll())).sort((a, b) => a.client_time.localeCompare(b.client_time));
  listeners.forEach((l) => l());
}

export async function enqueue(p: Omit<QueuedPunch, "client_uuid" | "client_time" | "device" | "device_token">) {
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
  void syncQueue();
  return item;
}

let syncing = false;
export async function syncQueue() {
  if (syncing || typeof navigator === "undefined" || !navigator.onLine) return;
  syncing = true;
  try {
    const { data, error: authError } = await supabase.auth.getUser();
    if (authError || !data.user) return;
    const uid = data.user.id;
    await refresh();
    for (const item of snapshot.filter(p => p.user_id === uid)) {
      if (!navigator.onLine) break;
      const current = await supabase.auth.getSession();
      if (current.data.session?.user.id !== uid) break;
      const { error } = await supabase.from("punches").insert({
        client_uuid: item.client_uuid,
        user_id: item.user_id,
        code: item.code,
        direction: item.direction,
        client_time: item.client_time,
        device: item.device,
        ...(item.device_token ? { device_token: item.device_token } : {}),
      });
      if (error && error.code !== '23505') {
        if (/fetch|network|jwt|token|unauthorized/i.test(error.message) || error.code === '42501') break;
        await tx("readwrite", (s) => s.put({ ...item, error: error.message }));
        break; // Do not send later events out of order after rejection.
      }
      // Read back exact owner and payload before deleting the durable local copy.
      // A generic unique violation is never evidence that this punch was accepted.
      const accepted = await supabase.from('punches')
        .select('client_uuid, user_id, code, direction, client_time, device')
        .eq('client_uuid', item.client_uuid).eq('user_id', uid).maybeSingle();
      const row = accepted.data;
      if (accepted.error || !row) break;
      if (row.code !== item.code || row.direction !== item.direction || row.device !== item.device ||
        new Date(row.client_time).getTime() !== new Date(item.client_time).getTime()) {
        await tx('readwrite', s => s.put({ ...item, error: 'Konflikt záznamu – záznam zostáva uložený v zariadení.' }));
        break;
      }
      await tx('readwrite', s => s.delete(item.client_uuid));
    }
  } catch {
    // Network or auth failure: retain all unacknowledged events for the next retry.
  } finally {
    syncing = false;
    await refresh();
    listeners.forEach((l) => l());
  }
}

export async function discard(uuid: string) {
  await tx("readwrite", (s) => s.delete(uuid));
  await refresh();
}

export function useQueue(userId?: string) {
  const items = useSyncExternalStore(
    (l) => { listeners.add(l); return () => listeners.delete(l); },
    () => snapshot,
    () => snapshot,
  );
  const [online, setOnline] = useState(true);
  useEffect(() => {
    setOnline(navigator.onLine);
    void refresh().then(syncQueue);
    const on = () => { setOnline(true); void syncQueue(); };
    const off = () => setOnline(false);
    window.addEventListener("online", on);
    window.addEventListener("offline", off);
    const iv = setInterval(() => void syncQueue(), 30_000);
    return () => { window.removeEventListener("online", on); window.removeEventListener("offline", off); clearInterval(iv); };
  }, []);
  return { items: items.filter(item => item.user_id === userId), online };
}
