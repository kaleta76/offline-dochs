import { describe, expect, it } from 'vitest';
import { refuseOfflineWorker } from './pwa';

describe('Offline registration safety', () => {
  it('never registers in development or an embedded preview', () => {
    expect(refuseOfflineWorker(false, 'localhost', false, '')).toBe(true);
    expect(refuseOfflineWorker(true, 'offline-dochs.lovable.app', true, '')).toBe(true);
  });
  it('excludes all preview host families but allows published custom domains', () => {
    for (const host of ['id-preview--abc.lovable.app', 'preview-v2--abc.gpt-eng.com', 'project--abc-dev.gptengineer.run', 'abc.lovableproject.com', 'beta.lovable.dev']) {
      expect(refuseOfflineWorker(true, host, false, '')).toBe(true);
    }
    expect(refuseOfflineWorker(true, 'offline-dochs.lovable.app', false, '')).toBe(false);
    expect(refuseOfflineWorker(true, 'preview-v2--shop.example.com', false, '')).toBe(false);
  });
  it('honors the sw=off kill switch', () => {
    expect(refuseOfflineWorker(true, 'offline-dochs.lovable.app', false, '?sw=off')).toBe(true);
  });
});