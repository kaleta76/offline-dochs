import 'fake-indexeddb/auto';
import { describe, expect, it } from 'vitest';
import { createDeviceKey, generateToken, getDeviceKey, sha256Hex } from './device';

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
