export function refuseOfflineWorker(production: boolean, hostname: string, framed: boolean, search: string) {
  const host = hostname.toLowerCase();
  const lovableHost = /\.(lovable\.app|gpt-eng\.com|gptengineer\.run)$/.test(host);
  const label = host.split('.')[0] ?? '';
  return !production || framed || new URLSearchParams(search).get('sw') === 'off' ||
    (lovableHost && (/^(?:id-preview|preview)(?:-[a-z0-9]+)?--.+$/.test(label) || /^project--.+-dev$/.test(label))) ||
    /(^|\.)(lovableproject\.com|lovableproject-dev\.com|beta\.lovable\.dev)$/.test(host);
}

export async function prepareOfflineApp() {
  if (!('serviceWorker' in navigator)) return;
  if (refuseOfflineWorker(import.meta.env.PROD, window.location.hostname, window.self !== window.top, window.location.search)) {
    const registrations = await navigator.serviceWorker.getRegistrations();
    await Promise.all(registrations.filter(r => [r.active, r.waiting, r.installing].some(w => w && new URL(w.scriptURL).pathname === '/sw.js')).map(r => r.unregister()));
    return;
  }
  // Generated Workbox worker only. Never cache RPCs, auth, or database responses.
  await navigator.serviceWorker.register('/sw.js', { scope: '/' });
}