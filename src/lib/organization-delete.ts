// Zrušenie testovacej organizácie (migrácia 0007, docs/migracie/0007_zrusenie_testovacej_organizacie.sql).
// Čistá logika obrazovky Správa → Testovacia organizácia: prehľad z databázy a kontrola potvrdenia. Nič sa tu nikam nezapisuje.

export interface TestOrganizationSummary {
  name: string;
  isTest: boolean;
  /** Pôvodná organizácia z migrácie 0002: nedá sa označiť ani zrušiť. */
  protectedOrganization: boolean;
  users: number;
  punches: number;
  devices: number;
}

const count = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : 0);

/** Odpoveď databázovej funkcie test_organization_summary na bezpečný tvar (neznáme hodnoty sa nezmenia na nesprávne čísla). */
export function parseSummary(value: unknown): TestOrganizationSummary | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const v = value as Record<string, unknown>;
  if (typeof v.name !== "string") return null;
  return {
    name: v.name,
    isTest: v.is_test === true,
    protectedOrganization: v.protected === true,
    users: count(v.users),
    punches: count(v.punches),
    devices: count(v.devices),
  };
}

/** Potvrdenie musí byť presný názov organizácie (okrajové medzery sa ignorujú, veľkosť písmen a pomlčky sa rozlišujú). */
export function confirmationMatches(name: string, typed: string): boolean {
  const expected = name.trim();
  return expected.length > 0 && typed.trim() === expected;
}

function plural(n: number, one: string, few: string, many: string): string {
  if (n === 1) return one;
  if (n >= 2 && n <= 4) return few;
  return many;
}

/** Veta pre potvrdzovaciu obrazovku, napr. „3 zamestnancov, 120 razení a 3 zariadení“. */
export function describeContents(s: Pick<TestOrganizationSummary, "users" | "punches" | "devices">): string {
  const u = `${s.users} ${plural(s.users, "účet", "účty", "účtov")}`;
  const p = `${s.punches} ${plural(s.punches, "razenie", "razenia", "razení")}`;
  const d = `${s.devices} ${plural(s.devices, "zariadenie", "zariadenia", "zariadení")}`;
  return `${u}, ${p} a ${d}`;
}

/** Odpoveď po zrušení: počty, ktoré vrátila databáza. */
export function parseDeleteResult(value: unknown): Pick<TestOrganizationSummary, "users" | "punches" | "devices"> {
  const v = value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
  return { users: count(v.users), punches: count(v.punches), devices: count(v.devices) };
}
