// Tajné kódy bez závislostí: generovanie, normalizácia, hashovanie a porovnanie.
// Beží v prehliadači, na serveri (Workers) aj v Node (testy). Nič sa tu nikam neukladá.

// Crockford base32: 32 znakov, bez I, L, O, U (nedajú sa zameniť pri prepisovaní).
const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

export const PIN_LENGTH = 12; // 60 bitov, platí 24 hodín a po 5 omyloch zhasne
export const RECOVERY_LENGTH = 20; // 100 bitov
export const PBKDF2_ITERATIONS = 100_000; // maximum, ktoré Cloudflare Workers povoľujú

/** Náhodný kód z abecedy Crockford. 256 je násobok 32, takže výber nie je skreslený. */
export function randomCode(length: number): string {
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  let out = "";
  for (const b of bytes) out += ALPHABET.charAt(b % 32);
  return out;
}

/** Veľké písmená, bez medzier a pomlčiek, O→0 a I/L→1 (bežné preklepy pri prepisovaní). */
export function normalizeCode(input: string): string {
  return input.toUpperCase().replace(/[\s-]/g, "").replace(/O/g, "0").replace(/[IL]/g, "1");
}

/** Skupiny po štyri znaky, napr. ABCD-EFGH-JKMN. */
export function formatCode(code: string): string {
  return code.replace(/(.{4})(?=.)/g, "$1-");
}

/** Kód má presne danú dĺžku a obsahuje len znaky abecedy. */
export function isWellFormedCode(input: string, length: number): boolean {
  const code = normalizeCode(input);
  return code.length === length && /^[0-9A-HJKMNP-TV-Z]+$/.test(code);
}

function toHex(buf: ArrayBuffer | Uint8Array): string {
  return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, "0")).join("");
}

function fromHex(hex: string) {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(2 * i, 2 * i + 2), 16);
  return out;
}

export async function sha256Hex(text: string): Promise<string> {
  return toHex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

export function randomSalt(): string {
  return toHex(crypto.getRandomValues(new Uint8Array(16)));
}

/** PBKDF2-SHA256 so soľou. Používa sa pre PIN a obnovovací kód (v databáze je len výsledok). */
export async function hashSecret(
  secret: string,
  saltHex: string,
  iterations: number = PBKDF2_ITERATIONS,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    "PBKDF2",
    false,
    ["deriveBits"],
  );
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt: fromHex(saltHex), iterations },
    key,
    256,
  );
  return toHex(bits);
}

/** Porovnanie reťazcov bez predčasného ukončenia pri prvom rozdiele. */
export function safeEqualHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Kód organizácie pre zamestnancov: prvých 8 hexadecimálnych znakov jej UUID (nie je tajný). */
export function orgCodeOf(orgId: string): string {
  return orgId.replace(/-/g, "").slice(0, 8).toUpperCase();
}

/** Rozsah UUID, do ktorého patrí kód organizácie (na efektívne vyhľadanie v databáze). */
export function orgPrefixRange(code: string): { lo: string; hi: string } | null {
  const p = normalizeCode(code).toLowerCase();
  if (!/^[0-9a-f]{8}$/.test(p)) return null;
  return { lo: `${p}-0000-0000-0000-000000000000`, hi: `${p}-ffff-ffff-ffff-ffffffffffff` };
}
