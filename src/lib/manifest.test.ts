// Ochrana inštalovateľnosti aplikácie: Chrome a Edge ponúknu „Inštalovať“ len vtedy, keď manifest obsahuje PNG ikony 192 a 512 px.
// Samotná ikona favicon.ico (48 px) nestačí, preto test pri zmene manifestu zaručí, že ikony ostanú a súbory existujú v správnej veľkosti.
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const PUBLIC = join(process.cwd(), "public");

interface Icon {
  src: string;
  sizes: string;
  type?: string;
  purpose?: string;
}
interface Manifest {
  id?: string;
  name?: string;
  short_name?: string;
  start_url?: string;
  display?: string;
  icons?: Icon[];
}

const manifest = JSON.parse(readFileSync(join(PUBLIC, "manifest.webmanifest"), "utf-8")) as Manifest;

/** Rozmery z hlavičky PNG (IHDR). */
function pngSize(file: string): { width: number; height: number } {
  const b = readFileSync(file);
  expect(b.subarray(1, 4).toString("ascii")).toBe("PNG");
  return { width: b.readUInt32BE(16), height: b.readUInt32BE(20) };
}

describe("manifest.webmanifest", () => {
  it("má názov, štartovaciu adresu a samostatné okno", () => {
    expect(manifest.name).toBe("Dochádzka");
    expect(manifest.short_name).toBeTruthy();
    expect(manifest.start_url).toBe("/terminal");
    expect(manifest.display).toBe("standalone");
    expect(manifest.id).toBe(manifest.start_url);
  });

  it("obsahuje PNG ikony 192 a 512 px a maskovateľnú 512 px", () => {
    const icons = manifest.icons ?? [];
    const has = (size: string, purpose: string) =>
      icons.some((i) => i.type === "image/png" && i.sizes === size && (i.purpose ?? "any") === purpose);
    expect(has("192x192", "any")).toBe(true);
    expect(has("512x512", "any")).toBe(true);
    expect(has("512x512", "maskable")).toBe(true);
  });

  it("každá PNG ikona existuje a má deklarovanú veľkosť", () => {
    const pngs = (manifest.icons ?? []).filter((i) => i.type === "image/png");
    expect(pngs.length).toBeGreaterThan(2);
    for (const icon of pngs) {
      const file = join(PUBLIC, icon.src.replace(/^\//, ""));
      expect(existsSync(file)).toBe(true);
      const [w, h] = icon.sizes.split("x").map(Number);
      const actual = pngSize(file);
      expect(actual.width).toBe(w);
      expect(actual.height).toBe(h);
    }
  });
});
