import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({ insert: vi.fn(), read: vi.fn(), uid: 'user-a', sends: [] as unknown[] }));
vi.mock('@/integrations/supabase/client', () => ({ supabase: {
  auth: { getUser: async () => ({ data: { user: { id: mocks.uid } }, error: null }), getSession: async () => ({ data: { session: { user: { id: mocks.uid } } } }) },
  from: () => ({ insert: (p: unknown) => { mocks.sends.push(p); return mocks.insert(p); }, select: () => ({ eq: () => ({ eq: () => ({ maybeSingle: mocks.read }) }) }) }),
} }));
import { enqueue, syncQueue } from './offline-queue';
import { createDeviceKey } from './device';

async function rows() {
  const db = await new Promise<IDBDatabase>((resolve) => { const r = indexedDB.open('dochadzka', 1); r.onsuccess = () => resolve(r.result); });
  return new Promise<any[]>((resolve) => { const t = db.transaction('queue', 'readonly'); const r = t.objectStore('queue').getAll(); t.oncomplete = () => { db.close(); resolve(r.result); }; });
}
async function clear() {
  const db = await new Promise<IDBDatabase>((resolve) => { const r = indexedDB.open('dochadzka', 1); r.onupgradeneeded = () => r.result.createObjectStore('queue', { keyPath: 'client_uuid' }); r.onsuccess = () => resolve(r.result); });
  await new Promise<void>((resolve) => { const t = db.transaction('queue', 'readwrite'); t.objectStore('queue').clear(); t.oncomplete = () => { db.close(); resolve(); }; });
}
describe('Durable owner-scoped synchronization', () => {
  beforeEach(async () => {
    Object.defineProperty(navigator, 'onLine', { configurable: true, value: false });
    mocks.uid = 'user-a'; mocks.sends = []; mocks.insert.mockReset(); mocks.read.mockReset(); await clear();
  });
  it('attaches the device key when this browser has one, and omits it otherwise', async () => {
    const plain = await enqueue({ user_id: 'user-a', code: 'WORK', direction: 'IN' });
    expect(plain.device_token).toBeUndefined();
    const { key } = await createDeviceKey('user-c');
    const keyed = await enqueue({ user_id: 'user-c', code: 'WORK', direction: 'IN' });
    expect(keyed.device_token).toBe(key.token);
  });
  it('commits punches locally without a network connection', async () => {
    const p = await enqueue({ user_id: 'user-a', code: 'WORK', direction: 'IN' });
    expect((await rows())[0].client_uuid).toBe(p.client_uuid);
    expect(mocks.sends).toHaveLength(0);
  });
  it('reconnects safely and leaves another account’s records untouched', async () => {
    const a = await enqueue({ user_id: 'user-a', code: 'WORK', direction: 'IN' });
    const b = await enqueue({ user_id: 'user-b', code: 'WORK', direction: 'OUT' });
    mocks.insert.mockResolvedValue({ error: null }); mocks.read.mockResolvedValue({ error: null, data: a });
    Object.defineProperty(navigator, 'onLine', { configurable: true, value: true }); await syncQueue();
    expect(mocks.sends).toHaveLength(1); expect(mocks.sends[0]).toMatchObject({ user_id: 'user-a', client_uuid: a.client_uuid });
    expect((await rows()).map(p => p.client_uuid)).toEqual([b.client_uuid]);
  });
  it('retains a successful write when read-back is unavailable and verifies the duplicate on retry', async () => {
    const p = await enqueue({ user_id: 'user-a', code: 'WORK', direction: 'IN' });
    mocks.insert.mockResolvedValueOnce({ error: null }).mockResolvedValueOnce({ error: { code: '23505', message: 'duplicate' } });
    mocks.read.mockResolvedValueOnce({ error: { message: 'network' }, data: null }).mockResolvedValueOnce({ error: null, data: p });
    Object.defineProperty(navigator, 'onLine', { configurable: true, value: true });
    await syncQueue(); expect(await rows()).toHaveLength(1);
    await syncQueue(); expect(await rows()).toHaveLength(0);
    expect(mocks.sends).toHaveLength(2); expect(mocks.sends[0]).toEqual(mocks.sends[1]);
  });
  it('never discards a conflicting duplicate', async () => {
    const p = await enqueue({ user_id: 'user-a', code: 'WORK', direction: 'IN' });
    mocks.insert.mockResolvedValue({ error: { code: '23505', message: 'duplicate' } });
    mocks.read.mockResolvedValue({ error: null, data: { ...p, direction: 'OUT' } });
    Object.defineProperty(navigator, 'onLine', { configurable: true, value: true }); await syncQueue();
    expect(await rows()).toHaveLength(1); expect((await rows())[0].error).toContain('Konflikt');
  });
  it('retains queued events on authentication and network failures', async () => {
    await enqueue({ user_id: 'user-a', code: 'WORK', direction: 'IN' });
    mocks.insert.mockRejectedValue(new Error('network unavailable'));
    Object.defineProperty(navigator, 'onLine', { configurable: true, value: true }); await syncQueue();
    expect(await rows()).toHaveLength(1);
  });
  it('never sends another user’s events when the session changes', async () => {
    const p = await enqueue({ user_id: 'user-a', code: 'WORK', direction: 'IN' });
    mocks.uid = 'user-b';
    Object.defineProperty(navigator, 'onLine', { configurable: true, value: true }); await syncQueue();
    expect(mocks.sends).toHaveLength(0);
    expect((await rows())[0].client_uuid).toBe(p.client_uuid);
  });
  it('retains an unverified duplicate and retries permission failures later', async () => {
    await enqueue({ user_id: 'user-a', code: 'WORK', direction: 'IN' });
    mocks.insert.mockResolvedValueOnce({ error: { code: '23505', message: 'duplicate' } }).mockResolvedValueOnce({ error: { code: '42501', message: 'permission denied' } });
    mocks.read.mockResolvedValue({ error: null, data: null });
    Object.defineProperty(navigator, 'onLine', { configurable: true, value: true });
    await syncQueue(); expect(await rows()).toHaveLength(1);
    await syncQueue(); expect(await rows()).toHaveLength(1);
  });
});