// Písma sú súčasťou aplikácie. Test zaručí, že sa nevrátia odkazy na Google Fonts (firemný proxy ich môže blokovať
// a bez spojenia by sa písmo nenačítalo) a že súbory písiem, na ktoré sa odkazuje štýl, existujú a sú WOFF2.
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = process.cwd();
const css = readFileSync(join(ROOT, "src", "styles.css"), "utf-8");
const root = readFileSync(join(ROOT, "src", "routes", "__root.tsx"), "utf-8");

describe("vlastné písma", () => {
  it("štýl deklaruje Archivo a JetBrains Mono zo súborov v public/fonts", () => {
    for (const [family, file] of [
      ["Archivo", "archivo-latin.woff2"],
      ["JetBrains Mono", "jetbrains-mono-latin.woff2"],
    ] as const) {
      expect(css.includes(`font-family: "${family}"`)).toBe(true);
      expect(css.includes(`url("/fonts/${file}")`)).toBe(true);
      const path = join(ROOT, "public", "fonts", file);
      expect(existsSync(path)).toBe(true);
      // súbor WOFF2 začína podpisom „wOF2“
      expect(readFileSync(path).subarray(0, 4).toString("latin1")).toBe("wOF2");
    }
  });

  it("písma sa zobrazia aj počas načítania a pri chýbajúcom súbore", () => {
    expect((css.match(/font-display: swap/g) ?? []).length).toBe(2);
  });

  it("aplikácia nesťahuje nič z Google Fonts", () => {
    expect(css.includes("fonts.googleapis.com")).toBe(false);
    expect(css.includes("fonts.gstatic.com")).toBe(false);
    expect(root.includes("fonts.googleapis.com")).toBe(false);
    expect(root.includes("fonts.gstatic.com")).toBe(false);
  });

  it("licencie písiem sú priložené", () => {
    expect(existsSync(join(ROOT, "public", "fonts", "OFL-Archivo.txt"))).toBe(true);
    expect(existsSync(join(ROOT, "public", "fonts", "OFL-JetBrainsMono.txt"))).toBe(true);
  });
});
