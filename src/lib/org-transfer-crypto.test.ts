import { Blob as NodeBlob } from "node:buffer";
import { webcrypto } from "node:crypto";
import { beforeAll, describe, expect, it, vi } from "vitest";
import {
  DEFAULT_ITERATIONS,
  MIN_PASSWORD_LENGTH,
  TransferCryptoError,
  WRONG_PASSWORD_MESSAGE,
  createEncryptedWriter,
  decryptToChunks,
  decryptToText,
  encryptText,
  passwordProblem,
} from "./org-transfer-crypto";

// Prostredie jsdom nemá Blob.arrayBuffer ani WebCrypto; skutočný prehliadač ich má, preto sa doplnia z Node.
beforeAll(() => {
  vi.stubGlobal("Blob", NodeBlob);
  vi.stubGlobal("crypto", webcrypto);
});

const PW = "správne-heslo-12345";
const FAST = { iterations: 100_000 };
const bytesOf = async (b: Blob) => new Uint8Array(await b.arrayBuffer());
const asBlob = (u: Uint8Array) => new Blob([u as BufferSource]);

/** Rozloženie súboru: hlavička 41 B, potom bloky (dĺžka u32 + šifrový text). */
function frames(file: Uint8Array): { start: number; end: number }[] {
  const out: { start: number; end: number }[] = [];
  let pos = 41;
  const v = new DataView(file.buffer, file.byteOffset, file.byteLength);
  while (pos < file.length) {
    const len = v.getUint32(pos);
    out.push({ start: pos, end: pos + 4 + len });
    pos += 4 + len;
  }
  return out;
}

async function expectFails(file: Uint8Array | Blob, password = PW) {
  const blob = file instanceof Blob ? file : asBlob(file);
  await expect(decryptToText(blob, password)).rejects.toBeInstanceOf(TransferCryptoError);
}

describe("passwordProblem", () => {
  it("vyžaduje aspoň minimálnu dĺžku (počíta znaky, nie bajty)", () => {
    expect(passwordProblem("x".repeat(MIN_PASSWORD_LENGTH - 1))).toMatch(/aspoň 12 znakov/);
    expect(passwordProblem("x".repeat(MIN_PASSWORD_LENGTH))).toBeNull();
    expect(passwordProblem("ľščťžýáíé1")).toMatch(/aspoň 12 znakov/); // 10 znakov, hoci viac bajtov
    expect(passwordProblem("")).not.toBeNull();
  });
});

describe("šifrovanie a dešifrovanie", () => {
  it("okružná cesta zachová text vrátane diakritiky a znakov mimo základnej roviny", async () => {
    const text = JSON.stringify({
      meno: "Ľudmila Šťastná",
      pozn: "čiarka, „úvodzovky“ 🙂 emoji",
      n: 7.5,
    });
    const file = await encryptText(text, PW, FAST);
    expect(await decryptToText(file, PW)).toBe(text);
  });

  it("zachová prázdny text a text presne na hranici bloku aj viacblokový text", async () => {
    for (const len of [0, 1, 15, 16, 17, 32, 33, 160]) {
      const text = "a".repeat(len);
      const file = await encryptText(text, PW, { ...FAST, chunkBytes: 16 });
      expect(await decryptToText(file, PW), `dĺžka ${len}`).toBe(text);
      // prázdny aj plný posledný blok vždy existuje a nesie príznak „posledný“
      expect(frames(await bytesOf(file)).length, `bloky ${len}`).toBe(
        Math.max(1, Math.ceil(len / 16)),
      );
    }
  });

  it("viac zápisov dá rovnaký výsledok ako jeden a viacbajtový znak môže ležať na hranici bloku", async () => {
    const text = "Ž".repeat(40) + "🙂".repeat(10);
    const w = await createEncryptedWriter(PW, { ...FAST, chunkBytes: 7 });
    for (const piece of [text.slice(0, 3), text.slice(3, 4), text.slice(4, 50), text.slice(50)])
      await w.write(piece);
    const file = await w.finish();
    expect(await decryptToText(file, PW)).toBe(text);
    expect(w.plainBytes).toBe(new TextEncoder().encode(text).length);
  });

  it("dve zašifrovania toho istého textu sa líšia (náhodná soľ a nonce)", async () => {
    const a = await bytesOf(await encryptText("rovnaký text", PW, FAST));
    const b = await bytesOf(await encryptText("rovnaký text", PW, FAST));
    expect(Buffer.from(a).equals(Buffer.from(b))).toBe(false);
  });

  it("výsledok neobsahuje čitateľný text", async () => {
    const file = await bytesOf(await encryptText("TAJNÝ-OBSAH-ORGANIZÁCIE", PW, FAST));
    expect(Buffer.from(file).includes(Buffer.from("TAJNÝ"))).toBe(false);
    expect(new TextDecoder().decode(file.subarray(0, 8))).toBe("DOCHSENC");
  });

  it("predvolený počet iterácií je 600 000 a zapisuje sa do hlavičky", async () => {
    expect(DEFAULT_ITERATIONS).toBe(600_000);
    const file = await bytesOf(await encryptText("x", PW, FAST));
    expect(new DataView(file.buffer, file.byteOffset).getUint32(10)).toBe(100_000);
  });

  it("heslo sa normalizuje (NFC): rovnaké heslo napísané rozloženými znakmi funguje", async () => {
    const composed = "príliš-žltý-kôň-1";
    const decomposed = composed.normalize("NFD");
    expect(decomposed).not.toBe(composed);
    const file = await encryptText("obsah", composed, FAST);
    expect(await decryptToText(file, decomposed)).toBe("obsah");
  });

  it("šifrovať s krátkym heslom sa odmietne", async () => {
    await expect(encryptText("x", "krátke", FAST)).rejects.toThrow(/aspoň 12 znakov/);
  });

  it("hlási priebeh dešifrovania", async () => {
    const file = await encryptText("a".repeat(100), PW, { ...FAST, chunkBytes: 30 });
    const seen: number[] = [];
    await decryptToChunks(file, PW, (done) => seen.push(done));
    expect(seen.length).toBe(4);
    expect(seen[seen.length - 1]).toBe(file.size);
  });
});

describe("ochrana pred nesprávnym heslom, poškodením a úpravou", () => {
  const sample = "a".repeat(100);
  const make = async () => bytesOf(await encryptText(sample, PW, { ...FAST, chunkBytes: 30 }));

  it("nesprávne heslo zlyhá so spoločnou správou", async () => {
    const file = asBlob(await make());
    await expect(decryptToText(file, "nesprávne-heslo-1")).rejects.toThrow(WRONG_PASSWORD_MESSAGE);
  });

  it("zmena ktoréhokoľvek bajtu hlavičky, dĺžky alebo šifrového textu sa odhalí", async () => {
    const file = await make();
    const fr = frames(file);
    const positions = [
      0, // magic
      8, // verzia
      9, // KDF
      13, // iterácie (nižší bajt)
      14, // soľ
      30, // predpona nonce
      40, // veľkosť bloku
      fr[0]!.start + 3, // dĺžka bloku
      fr[0]!.start + 5, // šifrový text prvého bloku
      fr[fr.length - 1]!.end - 1, // značka posledného bloku
    ];
    for (const p of positions) {
      const copy = file.slice();
      copy[p] = (copy[p] ?? 0) ^ 0x01;
      await expectFails(copy);
    }
  });

  it("odstránenie posledného bloku (useknutie na hranici bloku) sa odhalí", async () => {
    const file = await make();
    const fr = frames(file);
    expect(fr.length).toBeGreaterThan(2);
    await expectFails(file.slice(0, fr[fr.length - 1]!.start));
  });

  it("useknutie uprostred bloku, uprostred dĺžky a pripojené bajty sa odhalia", async () => {
    const file = await make();
    const fr = frames(file);
    await expectFails(file.slice(0, file.length - 5));
    await expectFails(file.slice(0, fr[1]!.start + 2));
    await expectFails(file.slice(0, 41));
    await expectFails(file.slice(0, 20));
    const extended = new Uint8Array(file.length + 3);
    extended.set(file);
    await expectFails(extended);
  });

  it("zámena a zdvojenie blokov sa odhalí", async () => {
    const file = await make();
    const fr = frames(file);
    const part = (i: number) => file.slice(fr[i]!.start, fr[i]!.end);
    const swap = new Uint8Array(file.length);
    swap.set(file.slice(0, 41));
    let pos = 41;
    for (const i of [1, 0, ...fr.slice(2).map((_, k) => k + 2)]) {
      const p = part(i);
      swap.set(p, pos);
      pos += p.length;
    }
    await expectFails(swap);
    const dup = new Uint8Array(file.length + (fr[0]!.end - fr[0]!.start));
    dup.set(file.slice(0, fr[0]!.end));
    dup.set(file.slice(fr[0]!.start), fr[0]!.end);
    await expectFails(dup);
  });

  it("cudzí súbor, nová verzia a neplatné parametre hlavičky sa odmietnu s vysvetlením", async () => {
    await expect(
      decryptToText(new Blob(["toto nie je šifrovaný súbor, len text na skúšku....."]), PW),
    ).rejects.toThrow(/Nie je to šifrovaný súbor/);
    const file = await make();
    const newer = file.slice();
    newer[8] = 2;
    await expect(decryptToText(asBlob(newer), PW)).rejects.toThrow(/novšom formáte/);
    const weak = file.slice();
    new DataView(weak.buffer).setUint32(10, 1);
    await expect(decryptToText(asBlob(weak), PW)).rejects.toThrow(/Hlavička súboru je neplatná/);
    const huge = file.slice();
    new DataView(huge.buffer).setUint32(37, 0x7fffffff);
    await expect(decryptToText(asBlob(huge), PW)).rejects.toThrow(/Hlavička súboru je neplatná/);
  });

  it("obrovská deklarovaná dĺžka bloku sa odmietne bez čítania", async () => {
    const file = await make();
    const copy = file.slice();
    new DataView(copy.buffer).setUint32(41, 0x7fffffff);
    await expect(decryptToText(asBlob(copy), PW)).rejects.toThrow(/poškodený/);
  });

  it("uzavretý zapisovač už nič neprijme", async () => {
    const w = await createEncryptedWriter(PW, FAST);
    await w.write("x");
    await w.finish();
    await expect(w.write("y")).rejects.toThrow(/uzavretý/);
    await expect(w.finish()).rejects.toThrow(/uzavretý/);
  });
});
