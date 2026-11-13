// Device key: a 256-bit random secret kept only in this browser (IndexedDB).
// The server stores only its SHA-256 hash; device status is decided by the DB trigger.
const DB = "dochadzka-device";
const STORE = "keys";

export interface DeviceKey { user_id: string; token: string; hash: string; created_at: string }

function openDb(): Promise<IDBDatabase> {
  return new Promise((res, rej) => {
    const r = indexedDB.open(DB, 1);
    r.onupgradeneeded = () => r.result.createObjectStore(STORE, { keyPath: "user_id" });
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
}
async function run<T>(mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await openDb();
  return new Promise((res, rej) => {
    const t = db.transaction(STORE, mode);
    const req = fn(t.objectStore(STORE));
    t.oncomplete = () => { db.close(); res(req.result); };
    t.onerror = () => { db.close(); rej(t.error ?? req.error); };
    t.onabort = () => { db.close(); rej(t.error ?? new Error("Uloženie kľúča zlyhalo.")); };
  });
}

const hex = (b: ArrayBuffer | Uint8Array) => Array.from(new Uint8Array(b), (x) => x.toString(16).padStart(2, "0")).join("");

export function generateToken(): string {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  return hex(b);
}
export async function sha256Hex(s: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
}

export async function getDeviceKey(userId: string): Promise<DeviceKey | undefined> {
  try { return await run<DeviceKey | undefined>("readonly", (s) => s.get(userId)); } catch { return undefined; }
}

/** Zmaže kľúč zariadenia účtu z tohto prehliadača (upratanie po presťahovaní organizácie; na serveri sa nič nemení). */
export async function deleteDeviceKey(userId: string): Promise<void> {
  await run("readwrite", (s) => s.delete(userId));
}

/**
 * Asks the browser to keep this site's data (the device key) instead of evicting it when disk space runs low.
 * Chrome decides silently from bookmark, installed app, site engagement and notification permission, and the answer
 * changes over time, so asking again later can succeed; Firefox asks the user, so callers must not ask more often than needed.
 */
export async function ensurePersistent(): Promise<boolean> {
  try {
    const s = typeof navigator === "undefined" ? undefined : navigator.storage;
    if (!s) return false;
    if (s.persisted && (await s.persisted())) return true;
    if (s.persist) return Boolean(await s.persist());
  } catch { /* unsupported or blocked */ }
  return false;
}

/** Creates a fresh key (replacing any old one for this user). Returns key + persistence result. */
export async function createDeviceKey(userId: string): Promise<{ key: DeviceKey; persisted: boolean }> {
  const token = generateToken();
  const key: DeviceKey = { user_id: userId, token, hash: await sha256Hex(token), created_at: new Date().toISOString() };
  await run("readwrite", (s) => s.put(key));
  return { key, persisted: await ensurePersistent() };
}

export async function getOrCreateDeviceKey(userId: string) {
  const existing = await getDeviceKey(userId);
  if (existing) return { key: existing, persisted: await ensurePersistent() };
  return createDeviceKey(userId);
}

export async function saveDeviceKey(key: DeviceKey): Promise<boolean> {
  await run("readwrite", (s) => s.put(key));
  return ensurePersistent();
}
export async function newDeviceKey(userId: string): Promise<DeviceKey> {
  const token = generateToken();
  return { user_id: userId, token, hash: await sha256Hex(token), created_at: new Date().toISOString() };
}
