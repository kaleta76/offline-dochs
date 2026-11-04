import 'fake-indexeddb/auto';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { createDeviceKey, ensurePersistent, generateToken, getDeviceKey, getOrCreateDeviceKey, saveDeviceKey, sha256Hex } from './device';

describe('device key', () => {
  it('generates 256-bit hex tokens that differ each time', () => {
    const a = generateToken();
    expect(a).toMatch(/^[0-9a-f]{64}$/);
    expect(generateToken()).not.toBe(a);
  });
  it('hashes with SHA-256', async () => {
    expect(await sha256Hex('abc')).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });
  it('stores the key per user in IndexedDB', async () => {
    const { key } = await createDeviceKey('user-a');
    expect((await getDeviceKey('user-a'))?.token).toBe(key.token);
    expect(key.hash).toBe(await sha256Hex(key.token));
    expect(await getDeviceKey('user-b')).toBeUndefined();
  });
});

describe('persistent storage request', () => {
  const setStorage = (storage: unknown) => Object.defineProperty(navigator, 'storage', { value: storage, configurable: true });
  afterEach(() => { Reflect.deleteProperty(navigator, 'storage'); });

  it('is false when the browser has no storage API', async () => {
    setStorage(undefined);
    expect(await ensurePersistent()).toBe(false);
  });
  it('does not ask again when storage is already persistent', async () => {
    const persist = vi.fn();
    setStorage({ persisted: async () => true, persist });
    expect(await ensurePersistent()).toBe(true);
    expect(persist).not.toHaveBeenCalled();
  });
  it('asks the browser and reports its answer', async () => {
    setStorage({ persisted: async () => false, persist: async () => true });
    expect(await ensurePersistent()).toBe(true);
    setStorage({ persisted: async () => false, persist: async () => false });
    expect(await ensurePersistent()).toBe(false);
  });
  it('can succeed on a later attempt after an earlier denial (Chrome re-evaluates its heuristics)', async () => {
    const persist = vi.fn().mockResolvedValueOnce(false).mockResolvedValueOnce(true);
    setStorage({ persisted: async () => false, persist });
    expect(await ensurePersistent()).toBe(false);
    expect(await ensurePersistent()).toBe(true);
    expect(persist).toHaveBeenCalledTimes(2);
  });
  it('treats a throwing or rejecting API as not persistent', async () => {
    setStorage({ persisted: async () => { throw new Error('blocked'); }, persist: async () => true });
    expect(await ensurePersistent()).toBe(false);
    setStorage({ persisted: async () => false, persist: () => Promise.reject(new Error('blocked')) });
    expect(await ensurePersistent()).toBe(false);
  });
  it('re-asks for an existing key, so a bookmark or install made later is picked up', async () => {
    setStorage({ persisted: async () => false, persist: async () => false });
    const first = await getOrCreateDeviceKey('user-p');
    expect(first.persisted).toBe(false);
    setStorage({ persisted: async () => false, persist: async () => true });
    const again = await getOrCreateDeviceKey('user-p');
    expect(again.key.token).toBe(first.key.token);
    expect(again.persisted).toBe(true);
  });
  it('reports persistence when a replacement key is saved', async () => {
    setStorage({ persisted: async () => false, persist: async () => true });
    expect(await saveDeviceKey({ user_id: 'user-q', token: 't', hash: 'h', created_at: '2026-11-04T00:00:00Z' })).toBe(true);
    expect((await getDeviceKey('user-q'))?.token).toBe('t');
  });
});
