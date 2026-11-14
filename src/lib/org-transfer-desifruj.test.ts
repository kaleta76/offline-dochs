import { Blob as NodeBlob } from "node:buffer";
import { spawnSync } from "node:child_process";
import { webcrypto } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { WRONG_PASSWORD_MESSAGE, encryptText } from "./org-transfer-crypto";

// Nástroj tools/prenos-desifruj.mjs číta súbor nezávislou implementáciou (node:crypto), preto sa tu overuje na súboroch,
// ktoré vyrobil kód aplikácie (WebCrypto): ak by sa formáty rozišli, súbor z aplikácie by sa nedal dešifrovať.
const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), "../../tools/prenos-desifruj.mjs");
const PW = "správne-heslo-12345";
const FAST = { iterations: 100_000 };

let dir: string;
beforeAll(() => {
  // Prostredie jsdom nemá Blob.arrayBuffer ani WebCrypto; skutočný prehliadač ich má, preto sa doplnia z Node.
  vi.stubGlobal("Blob", NodeBlob);
  vi.stubGlobal("crypto", webcrypto);
  dir = mkdtempSync(join(tmpdir(), "prenos-desifruj-"));
});
afterAll(() => {
  rmSync(dir, { recursive: true, force: true });
});

let counter = 0;
const path = (name: string) => join(dir, `${(counter += 1)}-${name}`);

async function sifrovany(text: string, options: { chunkBytes?: number } = {}) {
  const file = path("prenos.dochs-enc");
  const blob = await encryptText(text, PW, { ...FAST, ...options });
  writeFileSync(file, new Uint8Array(await blob.arrayBuffer()));
  return file;
}

function spusti(args: string[], heslo: string | null = PW) {
  const env: Record<string, string | undefined> = {
    ...process.env,
    PRENOS_HESLO: heslo ?? undefined,
  };
  const r = spawnSync(process.execPath, [SCRIPT, ...args], { env, encoding: "utf8", input: "" });
  return { kod: r.status, chyba: r.stderr };
}

const PRENOS = JSON.stringify({
  meta: { format: 2, organizacia: "Škola č. 1 – žltá" },
  tables: { employees: [{ osobne_cislo: "9000001", meno: "Ľubomír Štefánik 😀" }] },
});

describe("tools/prenos-desifruj.mjs", () => {
  it("dešifruje súbor z aplikácie na identický JSON (aj s diakritikou a viacerými blokmi)", async () => {
    const vstup = await sifrovany(PRENOS, { chunkBytes: 32 });
    const vystup = path("vystup.json");
    const r = spusti([vstup, vystup]);
    expect(r.chyba).toContain("Hotovo");
    expect(r.chyba).toContain("SHA-256 výstupu");
    expect(r.kod).toBe(0);
    expect(readFileSync(vystup, "utf8")).toBe(PRENOS);
  });

  it("zvláda obsah, ktorý presne zaplní posledný blok", async () => {
    const text = JSON.stringify({ a: "x".repeat(22) }); // 30 bajtov
    expect(Buffer.byteLength(text)).toBe(30);
    for (const chunkBytes of [10, 15, 30]) {
      const vstup = await sifrovany(text, { chunkBytes });
      const vystup = path("vystup.json");
      expect(spusti([vstup, vystup]).kod).toBe(0);
      expect(readFileSync(vystup, "utf8")).toBe(text);
    }
  });

  it("heslo v inej forme normalizácie Unicode (NFD) dešifruje tiež", async () => {
    const vstup = await sifrovany(PRENOS);
    const vystup = path("vystup.json");
    expect(spusti([vstup, vystup], PW.normalize("NFD")).kod).toBe(0);
    expect(readFileSync(vystup, "utf8")).toBe(PRENOS);
  });

  it("pri nesprávnom hesle skončí chybou a nenechá po sebe výstup", async () => {
    const vstup = await sifrovany(PRENOS);
    const vystup = path("vystup.json");
    const r = spusti([vstup, vystup], "iné-heslo-12345");
    expect(r.kod).toBe(1);
    expect(r.chyba).toContain(WRONG_PASSWORD_MESSAGE);
    expect(existsSync(vystup)).toBe(false);
  });

  it("odhalí orezaný súbor (chýba posledný blok) a nenechá výstup", async () => {
    const vstup = await sifrovany(PRENOS, { chunkBytes: 32 });
    const bytes = readFileSync(vstup);
    // odstráni posledný blok: nájde jeho začiatok prechodom po blokoch
    let pos = 41;
    let lastStart = pos;
    while (pos < bytes.length) {
      lastStart = pos;
      pos += 4 + bytes.readUInt32BE(pos);
    }
    const orezany = path("orezany.dochs-enc");
    writeFileSync(orezany, bytes.subarray(0, lastStart));
    const vystup = path("vystup.json");
    const r = spusti([orezany, vystup]);
    expect(r.kod).toBe(1);
    expect(existsSync(vystup)).toBe(false);
  });

  it("odhalí poškodený bajt", async () => {
    const vstup = await sifrovany(PRENOS);
    const bytes = readFileSync(vstup);
    bytes[bytes.length - 20] = (bytes[bytes.length - 20] ?? 0) ^ 0x01;
    const poskodeny = path("poskodeny.dochs-enc");
    writeFileSync(poskodeny, bytes);
    const vystup = path("vystup.json");
    expect(spusti([poskodeny, vystup]).kod).toBe(1);
    expect(existsSync(vystup)).toBe(false);
  });

  it("odmietne súbor, ktorý nie je prenos organizácie", () => {
    const cudzi = path("cudzi.bin");
    writeFileSync(cudzi, Buffer.from("toto nie je šifrovaný súbor, len text".repeat(3)));
    const vystup = path("vystup.json");
    const r = spusti([cudzi, vystup]);
    expect(r.kod).toBe(1);
    expect(r.chyba).toContain("Nie je to šifrovaný súbor");
    expect(existsSync(vystup)).toBe(false);
  });

  it("odmietne obsah, ktorý po dešifrovaní nie je JSON prenosu", async () => {
    const vstup = await sifrovany("obyčajný text");
    const vystup = path("vystup.json");
    const r = spusti([vstup, vystup]);
    expect(r.kod).toBe(1);
    expect(existsSync(vystup)).toBe(false);
  });

  it("neprepíše existujúci výstup bez --prepisat", async () => {
    const vstup = await sifrovany(PRENOS);
    const vystup = path("vystup.json");
    writeFileSync(vystup, "pôvodný obsah");
    const r = spusti([vstup, vystup]);
    expect(r.kod).toBe(2);
    expect(readFileSync(vystup, "utf8")).toBe("pôvodný obsah");
    expect(spusti([vstup, vystup, "--prepisat"]).kod).toBe(0);
    expect(readFileSync(vystup, "utf8")).toBe(PRENOS);
  });

  it("pri nesprávnom hesle ponechá existujúci výstup nedotknutý, aj s --prepisat", async () => {
    const vstup = await sifrovany(PRENOS);
    const vystup = path("vystup.json");
    writeFileSync(vystup, "pôvodný obsah");
    expect(spusti([vstup, vystup, "--prepisat"], "iné-heslo-12345").kod).toBe(1);
    expect(readFileSync(vystup, "utf8")).toBe("pôvodný obsah");
    expect(readdirSync(dir).filter((n) => n.endsWith(".tmp"))).toEqual([]);
  });

  it("výstup nesmie byť rovnaký súbor ako vstup", async () => {
    const vstup = await sifrovany(PRENOS);
    expect(spusti([vstup, vstup, "--prepisat"]).kod).toBe(2);
    expect(existsSync(vstup)).toBe(true);
  });
});
