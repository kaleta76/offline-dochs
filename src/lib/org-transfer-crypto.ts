// Šifrovanie súboru s prenosom organizácie (docs/PRENOS-ORGANIZACIE.md). Beží len v prehliadači (WebCrypto), heslo sa nikam neposiela.
//
// Formát „DOCHSENC“ verzia 1 (všetky čísla big-endian):
//   hlavička (41 B): "DOCHSENC" (8) · verzia (1) · KDF (1: PBKDF2-HMAC-SHA256) · počet iterácií (u32) · soľ (16) · predpona nonce (7) · veľkosť bloku v bajtoch (u32)
//   bloky:           dĺžka šifrového textu (u32) · šifrový text (AES-256-GCM, vrátane 16 B značky)
// Nonce bloku i = predpona nonce (7) · i (u32) · príznak posledného bloku (1: 1 = posledný). Dodatočne overované údaje (AAD) = celá hlavička.
// Príznak posledného bloku a poradové číslo v nonce zaručia, že odstránenie, vloženie alebo zámena blokov sa pri dešifrovaní odhalí;
// AAD viaže parametre. Súbor sa šifruje po blokoch, takže veľká organizácia nezaberie v pamäti dvojnásobok svojej veľkosti.
// Nesprávne heslo a poškodený súbor sa nedajú rozlíšiť (obe zlyhajú pri overení značky), preto je chyba spoločná.

export const MAGIC = "DOCHSENC";
export const FORMAT_VERSION = 1;
export const KDF_PBKDF2_SHA256 = 1;
/** OWASP (2023): 600 000 iterácií pre PBKDF2-HMAC-SHA256. */
export const DEFAULT_ITERATIONS = 600_000;
export const DEFAULT_CHUNK_BYTES = 1024 * 1024;
export const MIN_PASSWORD_LENGTH = 12;

const HEADER_BYTES = 41;
const SALT_BYTES = 16;
const NONCE_PREFIX_BYTES = 7;
const TAG_BYTES = 16;
const MAX_CHUNK_BYTES = 16 * 1024 * 1024;
const MIN_ITERATIONS = 100_000;
const MAX_ITERATIONS = 10_000_000;

export class TransferCryptoError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "TransferCryptoError";
  }
}

export const WRONG_PASSWORD_MESSAGE =
  "Súbor sa nepodarilo dešifrovať: nesprávne heslo alebo poškodený súbor.";

/** Text problému s heslom, alebo null, ak je v poriadku. Silu hesla nehodnotí, len minimálnu dĺžku. */
export function passwordProblem(password: string): string | null {
  if ([...password].length < MIN_PASSWORD_LENGTH) {
    return `Heslo musí mať aspoň ${MIN_PASSWORD_LENGTH} znakov.`;
  }
  return null;
}

const subtle = (): SubtleCrypto => {
  const s = globalThis.crypto?.subtle;
  if (!s)
    throw new TransferCryptoError(
      "Prehliadač nemá šifrovanie (WebCrypto). Použite aktuálny prehliadač cez HTTPS.",
    );
  return s;
};

function buildHeader(params: {
  iterations: number;
  salt: Uint8Array;
  noncePrefix: Uint8Array;
  chunkBytes: number;
}): Uint8Array {
  const h = new Uint8Array(HEADER_BYTES);
  const v = new DataView(h.buffer);
  h.set(new TextEncoder().encode(MAGIC), 0);
  h[8] = FORMAT_VERSION;
  h[9] = KDF_PBKDF2_SHA256;
  v.setUint32(10, params.iterations);
  h.set(params.salt, 14);
  h.set(params.noncePrefix, 30);
  v.setUint32(37, params.chunkBytes);
  return h;
}

interface ParsedHeader {
  iterations: number;
  salt: Uint8Array;
  noncePrefix: Uint8Array;
  chunkBytes: number;
  bytes: Uint8Array;
}

function parseHeader(bytes: Uint8Array): ParsedHeader {
  if (bytes.length < HEADER_BYTES || new TextDecoder().decode(bytes.subarray(0, 8)) !== MAGIC) {
    throw new TransferCryptoError("Nie je to šifrovaný súbor s prenosom organizácie.");
  }
  if (bytes[8] !== FORMAT_VERSION || bytes[9] !== KDF_PBKDF2_SHA256) {
    throw new TransferCryptoError(
      "Súbor je v novšom formáte, ktorý táto verzia aplikácie nepozná.",
    );
  }
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const iterations = v.getUint32(10);
  const chunkBytes = v.getUint32(37);
  if (
    iterations < MIN_ITERATIONS ||
    iterations > MAX_ITERATIONS ||
    chunkBytes < 1 ||
    chunkBytes > MAX_CHUNK_BYTES
  ) {
    throw new TransferCryptoError("Hlavička súboru je neplatná.");
  }
  return {
    iterations,
    chunkBytes,
    salt: bytes.slice(14, 14 + SALT_BYTES),
    noncePrefix: bytes.slice(30, 30 + NONCE_PREFIX_BYTES),
    bytes: bytes.slice(0, HEADER_BYTES),
  };
}

async function deriveKey(
  password: string,
  salt: Uint8Array,
  iterations: number,
): Promise<CryptoKey> {
  const material = await subtle().importKey(
    "raw",
    new TextEncoder().encode(password.normalize("NFC")),
    "PBKDF2",
    false,
    ["deriveKey"],
  );
  return subtle().deriveKey(
    { name: "PBKDF2", hash: "SHA-256", salt: salt as BufferSource, iterations },
    material,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

function nonceFor(prefix: Uint8Array, index: number, last: boolean): Uint8Array {
  const n = new Uint8Array(12);
  n.set(prefix, 0);
  new DataView(n.buffer).setUint32(7, index);
  n[11] = last ? 1 : 0;
  return n;
}

export interface EncryptOptions {
  iterations?: number;
  chunkBytes?: number;
}

/** Zapisovač šifrovaného súboru: `write` prijíma text, `finish` vráti hotový súbor. Pamäť drží len jeden nezašifrovaný blok. */
export interface EncryptedWriter {
  write(text: string): Promise<void>;
  finish(): Promise<Blob>;
  /** Počet bajtov nezašifrovaného obsahu doteraz. */
  readonly plainBytes: number;
}

export async function createEncryptedWriter(
  password: string,
  options: EncryptOptions = {},
): Promise<EncryptedWriter> {
  const problem = passwordProblem(password);
  if (problem) throw new TransferCryptoError(problem);
  const iterations = options.iterations ?? DEFAULT_ITERATIONS;
  const chunkBytes = options.chunkBytes ?? DEFAULT_CHUNK_BYTES;
  if (iterations < MIN_ITERATIONS || chunkBytes < 1 || chunkBytes > MAX_CHUNK_BYTES)
    throw new TransferCryptoError("Neplatné parametre šifrovania.");
  const salt = crypto.getRandomValues(new Uint8Array(SALT_BYTES));
  const noncePrefix = crypto.getRandomValues(new Uint8Array(NONCE_PREFIX_BYTES));
  const header = buildHeader({ iterations, salt, noncePrefix, chunkBytes });
  const key = await deriveKey(password, salt, iterations);

  const parts: BlobPart[] = [header as BufferSource];
  const encoder = new TextEncoder();
  let buffer = new Uint8Array(chunkBytes);
  let filled = 0;
  let index = 0;
  let plainBytes = 0;
  let finished = false;

  async function seal(plain: Uint8Array, last: boolean) {
    const cipher = new Uint8Array(
      await subtle().encrypt(
        {
          name: "AES-GCM",
          iv: nonceFor(noncePrefix, index, last) as BufferSource,
          additionalData: header as BufferSource,
          tagLength: TAG_BYTES * 8,
        },
        key,
        plain as BufferSource,
      ),
    );
    const len = new Uint8Array(4);
    new DataView(len.buffer).setUint32(0, cipher.length);
    parts.push(len as BufferSource, cipher as BufferSource);
    index += 1;
  }

  return {
    get plainBytes() {
      return plainBytes;
    },
    async write(text: string) {
      if (finished) throw new TransferCryptoError("Súbor je už uzavretý.");
      const bytes = encoder.encode(text);
      plainBytes += bytes.length;
      let offset = 0;
      while (offset < bytes.length) {
        // Plný blok sa zapečatí až keď príde ďalší obsah: posledný blok musí niesť príznak „posledný“, aj keď je plný.
        if (filled === chunkBytes) {
          await seal(buffer, false);
          buffer = new Uint8Array(chunkBytes);
          filled = 0;
        }
        const take = Math.min(bytes.length - offset, chunkBytes - filled);
        buffer.set(bytes.subarray(offset, offset + take), filled);
        filled += take;
        offset += take;
      }
    },
    async finish() {
      if (finished) throw new TransferCryptoError("Súbor je už uzavretý.");
      finished = true;
      await seal(buffer.subarray(0, filled), true);
      return new Blob(parts, { type: "application/octet-stream" });
    },
  };
}

/** Zašifruje celý text naraz (pomôcka pre menšie vstupy a testy). */
export async function encryptText(
  text: string,
  password: string,
  options: EncryptOptions = {},
): Promise<Blob> {
  const w = await createEncryptedWriter(password, options);
  await w.write(text);
  return w.finish();
}

async function readBytes(blob: Blob, start: number, end: number): Promise<Uint8Array> {
  return new Uint8Array(await blob.slice(start, end).arrayBuffer());
}

/** Dešifruje súbor po blokoch a vráti nezašifrovaný obsah ako bloky bajtov (v poradí). Chyba: `TransferCryptoError`. */
export async function decryptToChunks(
  file: Blob,
  password: string,
  onProgress?: (doneBytes: number, totalBytes: number) => void,
): Promise<Uint8Array[]> {
  const header = parseHeader(await readBytes(file, 0, HEADER_BYTES));
  const key = await deriveKey(password, header.salt, header.iterations);
  const out: Uint8Array[] = [];
  let pos = HEADER_BYTES;
  let index = 0;
  const maxCipher = header.chunkBytes + TAG_BYTES;
  for (;;) {
    if (pos + 4 > file.size) throw new TransferCryptoError("Súbor je neúplný.");
    const len = new DataView((await readBytes(file, pos, pos + 4)).buffer).getUint32(0);
    if (len < TAG_BYTES || len > maxCipher) throw new TransferCryptoError("Súbor je poškodený.");
    if (pos + 4 + len > file.size) throw new TransferCryptoError("Súbor je neúplný.");
    const cipher = await readBytes(file, pos + 4, pos + 4 + len);
    pos += 4 + len;
    const last = pos === file.size;
    let plain: ArrayBuffer;
    try {
      plain = await subtle().decrypt(
        {
          name: "AES-GCM",
          iv: nonceFor(header.noncePrefix, index, last) as BufferSource,
          additionalData: header.bytes as BufferSource,
          tagLength: TAG_BYTES * 8,
        },
        key,
        cipher as BufferSource,
      );
    } catch {
      throw new TransferCryptoError(WRONG_PASSWORD_MESSAGE);
    }
    out.push(new Uint8Array(plain));
    index += 1;
    onProgress?.(pos, file.size);
    if (last) return out;
  }
}

/** Dešifruje súbor na text (pomôcka pre menšie vstupy a testy; veľké súbory spracujte po blokoch cez `decryptToChunks`). */
export async function decryptToText(file: Blob, password: string): Promise<string> {
  const chunks = await decryptToChunks(file, password);
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let text = "";
  for (let i = 0; i < chunks.length; i += 1) {
    const chunk = chunks[i];
    if (!chunk) continue;
    // Blok sa môže skončiť uprostred viacbajtového znaku, preto sa dekóduje postupne so zachovaním zvyšku.
    text += decoder.decode(chunk, { stream: i < chunks.length - 1 });
  }
  return text;
}
