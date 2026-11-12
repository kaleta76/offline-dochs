#!/usr/bin/env node
// Dešifrovanie súboru s prenosom organizácie (`*.dochs-enc`, formát DOCHSENC v1, docs/PRENOS-ORGANIZACIE.md) na počítači operátora.
// Bez závislostí, len Node.js 18 a novší. Formát je definovaný v src/lib/org-transfer-crypto.ts; tento nástroj ho číta nezávisle (iná
// implementácia: node:crypto), takže slúži aj ako kontrola, že súbor nezávisí od prehliadača.
//
// Použitie:
//   node tools/prenos-desifruj.mjs prenos-XXXXXXXX-20261112-1530.dochs-enc [vystup.json] [--prepisat]
// Heslo sa pýta bez zobrazenia na obrazovke; pre skripty ho možno dať do premennej prostredia PRENOS_HESLO (nie do príkazového riadka).
// Výstup je JSON (formát 2: { meta, tables }), ktorý importuje balík 0015 (prenos_import.cmd). Obsahuje hashe hesiel a osobné čísla:
// po importe ho zmažte. Nástroj nikdy neprepíše existujúci výstup bez --prepisat; píše do dočasného súboru a premenuje ho až po
// úspešnom overení všetkých blokov, takže pri zlom hesle alebo poškodenom súbore nezostane polovičný výstup ani sa nestratí starý.
import { createDecipheriv, createHash, pbkdf2Sync } from "node:crypto";
import {
  closeSync,
  existsSync,
  fstatSync,
  openSync,
  readSync,
  renameSync,
  unlinkSync,
  writeSync,
} from "node:fs";
import { fileURLToPath } from "node:url";

export const MAGIC = "DOCHSENC";
const HEADER_BYTES = 41;
const TAG_BYTES = 16;
const MIN_ITERATIONS = 100_000;
const MAX_ITERATIONS = 10_000_000;
const MAX_CHUNK_BYTES = 16 * 1024 * 1024;

export class DesifrovanieError extends Error {}

export const ZLE_HESLO = "Súbor sa nepodarilo dešifrovať: nesprávne heslo alebo poškodený súbor.";

function readExact(fd, position, length) {
  const buffer = Buffer.alloc(length);
  let done = 0;
  while (done < length) {
    const n = readSync(fd, buffer, done, length - done, position + done);
    if (n === 0) break;
    done += n;
  }
  return done === length ? buffer : null;
}

function nonceFor(prefix, index, last) {
  const nonce = Buffer.alloc(12);
  prefix.copy(nonce, 0);
  nonce.writeUInt32BE(index, 7);
  nonce[11] = last ? 1 : 0;
  return nonce;
}

/**
 * Dešifruje otvorený súbor po blokoch; každý blok odovzdá funkcii `zapis(Buffer)`.
 * Vráti { bloky, bajty }. Chyba: DesifrovanieError.
 */
export function desifruj(fd, heslo, zapis) {
  const size = fstatSync(fd).size;
  const header = readExact(fd, 0, HEADER_BYTES);
  if (!header || header.subarray(0, 8).toString("latin1") !== MAGIC) {
    throw new DesifrovanieError("Nie je to šifrovaný súbor s prenosom organizácie.");
  }
  if (header[8] !== 1 || header[9] !== 1) {
    throw new DesifrovanieError("Súbor je v novšom formáte, ktorý tento nástroj nepozná.");
  }
  const iterations = header.readUInt32BE(10);
  const chunkBytes = header.readUInt32BE(37);
  if (
    iterations < MIN_ITERATIONS ||
    iterations > MAX_ITERATIONS ||
    chunkBytes < 1 ||
    chunkBytes > MAX_CHUNK_BYTES
  ) {
    throw new DesifrovanieError("Hlavička súboru je neplatná.");
  }
  const salt = header.subarray(14, 30);
  const noncePrefix = header.subarray(30, 37);
  const key = pbkdf2Sync(heslo.normalize("NFC"), salt, iterations, 32, "sha256");
  const maxCipher = chunkBytes + TAG_BYTES;
  let pos = HEADER_BYTES;
  let index = 0;
  let bytes = 0;
  for (;;) {
    if (pos + 4 > size) throw new DesifrovanieError("Súbor je neúplný.");
    const len = readExact(fd, pos, 4).readUInt32BE(0);
    if (len < TAG_BYTES || len > maxCipher) throw new DesifrovanieError("Súbor je poškodený.");
    if (pos + 4 + len > size) throw new DesifrovanieError("Súbor je neúplný.");
    const cipher = readExact(fd, pos + 4, len);
    pos += 4 + len;
    const last = pos === size;
    let plain;
    try {
      const d = createDecipheriv("aes-256-gcm", key, nonceFor(noncePrefix, index, last), {
        authTagLength: TAG_BYTES,
      });
      d.setAAD(header);
      d.setAuthTag(cipher.subarray(len - TAG_BYTES));
      plain = Buffer.concat([d.update(cipher.subarray(0, len - TAG_BYTES)), d.final()]);
    } catch {
      throw new DesifrovanieError(ZLE_HESLO);
    }
    zapis(plain);
    bytes += plain.length;
    index += 1;
    if (last) return { bloky: index, bajty: bytes };
  }
}

function pytajHeslo(otazka) {
  return new Promise((resolve, reject) => {
    const stdin = process.stdin;
    process.stderr.write(otazka);
    if (!stdin.isTTY) {
      let data = "";
      stdin.setEncoding("utf8");
      stdin.on("data", (c) => (data += c));
      stdin.on("end", () => resolve(data.split(/\r?\n/)[0] ?? ""));
      stdin.on("error", reject);
      return;
    }
    stdin.setRawMode(true);
    stdin.resume();
    stdin.setEncoding("utf8");
    let heslo = "";
    const onData = (ch) => {
      for (const c of ch) {
        if (c === "\r" || c === "\n" || c === "\u0004") {
          stdin.setRawMode(false);
          stdin.pause();
          stdin.removeListener("data", onData);
          process.stderr.write("\n");
          resolve(heslo);
          return;
        }
        if (c === "\u0003") {
          stdin.setRawMode(false);
          process.stderr.write("\n");
          process.exit(130);
        }
        if (c === "\u007f" || c === "\b") heslo = heslo.slice(0, -1);
        else heslo += c;
      }
    };
    stdin.on("data", onData);
  });
}

async function main(argv) {
  const prepisat = argv.includes("--prepisat");
  const args = argv.filter((a) => !a.startsWith("--"));
  if (args.length < 1 || args.length > 2 || argv.includes("--help")) {
    console.error(
      "Použitie: node tools/prenos-desifruj.mjs subor.dochs-enc [vystup.json] [--prepisat]",
    );
    return args.length < 1 && !argv.includes("--help") ? 2 : 0;
  }
  const vstup = args[0];
  const vystup = args[1] ?? vstup.replace(/\.dochs-enc$/i, "") + ".json";
  if (!existsSync(vstup)) {
    console.error(`Súbor ${vstup} neexistuje.`);
    return 2;
  }
  if (vystup === vstup) {
    console.error("Výstup musí byť iný súbor než vstup.");
    return 2;
  }
  if (existsSync(vystup) && !prepisat) {
    console.error(`Výstup ${vystup} už existuje (použite --prepisat, ak ho chcete nahradiť).`);
    return 2;
  }
  const heslo = process.env.PRENOS_HESLO ?? (await pytajHeslo("Heslo súboru: "));
  if (!heslo) {
    console.error("Heslo je prázdne.");
    return 2;
  }
  const docasny = `${vystup}.${process.pid}.tmp`;
  const in_fd = openSync(vstup, "r");
  const out_fd = openSync(docasny, "wx", 0o600);
  const hash = createHash("sha256");
  let prvy = null;
  let uspech = false;
  let out_zavrety = false;
  try {
    const t0 = Date.now();
    const r = desifruj(in_fd, heslo, (chunk) => {
      if (prvy === null) prvy = chunk.subarray(0, 1).toString("latin1");
      hash.update(chunk);
      let done = 0;
      while (done < chunk.length) done += writeSync(out_fd, chunk, done, chunk.length - done);
    });
    if (prvy !== "{") throw new DesifrovanieError("Dešifrovaný obsah nie je JSON súbor prenosu.");
    closeSync(out_fd);
    out_zavrety = true;
    renameSync(docasny, vystup);
    uspech = true;
    console.error(
      `Hotovo: ${r.bajty} bajtov v ${r.bloky} blokoch, ${Date.now() - t0} ms.\n` +
        `Výstup: ${vystup}\nSHA-256 výstupu: ${hash.digest("hex")}\n` +
        "Výstup obsahuje hashe hesiel a osobné čísla: po importe ho zmažte.",
    );
    return 0;
  } catch (e) {
    if (e instanceof DesifrovanieError) {
      console.error(e.message);
      return 1;
    }
    throw e;
  } finally {
    closeSync(in_fd);
    if (!out_zavrety) closeSync(out_fd);
    if (!uspech) {
      try {
        unlinkSync(docasny);
      } catch {
        // výstup sa nepodarilo zmazať, nič viac sa nedá robiť
      }
    }
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main(process.argv.slice(2)).then(
    (kod) => process.exit(kod),
    (e) => {
      console.error(e instanceof Error ? e.message : e);
      process.exit(1);
    },
  );
}
