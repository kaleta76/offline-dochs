// Offline-first punch queue stored in IndexedDB. Punches are written locally first,
// then sent to the server; client_uuid makes resending idempotent.
import { useEffect, useState, useSyncExternalStore } from "react";
import { supabase } from "@/integrations/supabase/client";

export interface QueuedPunch {
  client_uuid: string;
  user_id: string;
  code: string;
  direction: "IN" | "OUT";
  client_time: string;
  device: string;
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
    const req = fn(db.transaction(STORE, mode).objectStore(STORE));
    req.onsuccess = () => res(req.result);
    req.onerror = () => rej(req.error);
  });
}

let snapshot: QueuedPunch[] = [];
const listeners = new Set<() => void>();
async function refresh() {
  snapshot = (await tx<QueuedPunch[]>("readonly", (s) => s.getAll())).sort((a, b) => a.client_time.localeCompare(b.client_time));
  listeners.forEach((l) => l());
}

export async function enqueue(p: Omit<QueuedPunch, "client_uuid" | "client_time" | "device">) {
  const item: QueuedPunch = {
    ...p,
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
    await refresh();
    for (const item of snapshot) {
      const { error } = await supabase.from("punches").insert({
        client_uuid: item.client_uuid,
        user_id: item.user_id,
        code: item.code,
        direction: item.direction,
        client_time: item.client_time,
        device: item.device,
      });
      if (!error || error.code === "23505") {
        await tx("readwrite", (s) => s.delete(item.client_uuid));
      } else if (/fetch|network/i.test(error.message)) {
        break; // still offline
      } else {
        await tx("readwrite", (s) => s.put({ ...item, error: error.message }));
      }
    }
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

export function useQueue() {
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
  return { items, online };
}
