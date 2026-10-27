// @lovable.dev/vite-tanstack-config already includes the following — do NOT add them manually
// or the app will break with duplicate plugins:
//   - TanStack devtools (dev-only, first), tanstackStart, viteReact, tailwindcss, tsConfigPaths,
//     nitro (build-only using cloudflare as a default target), VITE_* env injection, @ path alias,
//     React/TanStack dedupe, error logger plugins, and sandbox detection (port/host/strictPort).
// You can pass additional config via defineConfig({ vite: { ... }, etc... }) if needed.
import { defineConfig } from "@lovable.dev/vite-tanstack-config";
import { VitePWA } from "vite-plugin-pwa";

const pwa = VitePWA({
  strategies: 'generateSW',
  filename: 'sw.js',
  outDir: 'dist/client',
  injectRegister: null,
  registerType: 'autoUpdate',
  manifest: false,
  devOptions: { enabled: false },
  workbox: {
    globDirectory: 'dist/client',
    globPatterns: ['**/*.{js,css,woff,woff2,ico,png,webmanifest}', '_shell.html'],
    maximumFileSizeToCacheInBytes: 8 * 1024 * 1024,
    navigateFallback: '/_shell.html',
    navigateFallbackAllowlist: [/^\/(?:$|terminal\/?$|auth\/?$|mesiac\/?$|tim\/?$|admin\/?$|vykaz\/)/],
    navigateFallbackDenylist: [/^\/api\//, /^\/~oauth/],
    cleanupOutdatedCaches: true,
    runtimeCaching: [{
      urlPattern: ({ request, url }) => request.mode === 'navigate' && url.origin === self.location.origin && /^\/(?:$|terminal\/?$|auth\/?$|mesiac\/?$|tim\/?$|admin\/?$|vykaz\/)/.test(url.pathname),
      handler: 'NetworkFirst',
      options: { cacheName: 'dochadzka-navigation', networkTimeoutSeconds: 4, cacheableResponse: { statuses: [200] }, expiration: { maxEntries: 15, maxAgeSeconds: 7 * 86400 } },
    }],
  },
});
// Start prerenders after the client bundle closes: generate the worker after all
// environments finish so its precache includes the actual shell and route chunks.
const pwaBuild = pwa.find(plugin => plugin.name === 'vite-plugin-pwa:build');
if (pwaBuild) pwaBuild.closeBundle = undefined;

export default defineConfig({
  tanstackStart: {
    // Redirect TanStack Start's bundled server entry to src/server.ts (our SSR error wrapper).
    // nitro/vite builds from this
    server: { entry: "server" },
    spa: { enabled: true },
    prerender: { enabled: true, autoStaticPathsDiscovery: false },
    pages: [],
  },
  vite: { plugins: [...pwa, {
    name: 'dochadzka:offline-after-prerender',
    apply: 'build',
    buildApp: { order: 'post', async handler() {
      const api = pwa.find(plugin => plugin.name === 'vite-plugin-pwa')?.api;
      await api?.generateSW();
    } },
  }] },
});
