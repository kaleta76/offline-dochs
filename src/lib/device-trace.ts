// Čistá logika prehľadu zariadení: štítok, typ zariadenia podľa user-agent, zmeny zariadení
// a počet neoverených razení. Bez siete a databázy, testy sú v device-trace.test.ts.
// Súvisí s docs/OVERENIE-ZARIADENI.md.

export type DeviceVerification = "verified" | "unverified" | "confirmed";

const VERIFICATIONS: readonly string[] = ["verified", "unverified", "confirmed"];

/** Neznáma hodnota sa berie ako neoverená (bezpečnejšia chyba než tichý predpoklad, že je v poriadku). */
export function asVerification(value: string | null | undefined): DeviceVerification {
  return value && VERIFICATIONS.includes(value) ? (value as DeviceVerification) : "unverified";
}

/** Krátky štítok zariadenia z jeho id (4 hexadecimálne znaky). Nie je tajný ani jedinečný, len pomáha pri priraďovaní. */
export function deviceLabel(id: string | null | undefined): string {
  const hex = (id ?? "")
    .replace(/[^0-9a-fA-F]/g, "")
    .slice(0, 4)
    .toUpperCase();
  return hex.length === 4 ? hex : "";
}

export type DeviceKind = "Windows" | "Android" | "iPhone/iPad" | "Mac" | "Linux" | "iné";

/** Typ zariadenia z `user_agent_hint` (databáza ukladá prvých 80 znakov). Poradie je dôležité: Android obsahuje „Linux“, iPhone „Mac OS X“. */
export function deviceKind(ua: string | null | undefined): DeviceKind {
  const s = ua ?? "";
  if (/Android/i.test(s)) return "Android";
  if (/iPhone|iPad|iPod/i.test(s)) return "iPhone/iPad";
  if (/Windows/i.test(s)) return "Windows";
  if (/Macintosh|Mac OS X/i.test(s)) return "Mac";
  if (/Linux|X11/i.test(s)) return "Linux";
  return "iné";
}

/** Text, ktorý `recover_device` zapíše pri zrušení pôvodného zariadenia (drizzle/migrations/0003_device_verification.sql). */
export const RECOVERY_REVOKE_REASON = "Obnova záchranným kódom";

export interface DeviceRow {
  id: string;
  user_id: string;
  status: string;
  created_at: string;
  approved_by: string | null;
  approved_at: string | null;
  revoked_at: string | null;
  revoke_reason: string | null;
  replaces_device_id: string | null;
  user_agent_hint: string | null;
}

export type ChangeKind =
  /** nové zariadenie vzniklo záchranným kódom, bez schválenia vedúceho */
  | "recovered"
  /** zariadenie schválil ten istý používateľ (správca u seba) */
  | "self_approved"
  /** náhrada zariadenia schválená iným človekom */
  | "replacement"
  /** žiadosť o náhradu čaká na schválenie */
  | "replacement_pending";

export interface DeviceChange {
  device: DeviceRow;
  kind: ChangeKind;
  /** čas zmeny (ISO) */
  at: string;
  /** pôvodné zariadenie, ak ho poznáme */
  replaced: DeviceRow | null;
  from: DeviceKind | null;
  to: DeviceKind;
  /** pôvodné aj nové zariadenie poznáme a líšia sa typom (napr. Windows → Android) */
  typeChanged: boolean;
}

/**
 * Zmeny zariadení za posledných `days` dní, od najnovšej. Berie sa len to, čo nie je bežné prvé schválenie:
 * obnova záchranným kódom, schválenie samým sebou, náhrada zariadenia a čakajúca žiadosť o náhradu.
 */
export function deviceChanges(
  devices: readonly DeviceRow[],
  now: Date = new Date(),
  days = 90,
): DeviceChange[] {
  const byId = new Map(devices.map((d) => [d.id, d]));
  const since = now.getTime() - days * 86_400_000;
  const out: DeviceChange[] = [];
  for (const d of devices) {
    const replaced = d.replaces_device_id ? (byId.get(d.replaces_device_id) ?? null) : null;
    const selfApproved = !!d.approved_by && d.approved_by === d.user_id;
    let kind: ChangeKind | null = null;
    if (d.status === "pending" && d.replaces_device_id) kind = "replacement_pending";
    else if (replaced?.revoke_reason === RECOVERY_REVOKE_REASON) kind = "recovered";
    else if (selfApproved) kind = "self_approved";
    else if (d.replaces_device_id) kind = "replacement";
    if (!kind) continue;
    const at = kind === "replacement_pending" ? d.created_at : (d.approved_at ?? d.created_at);
    if (new Date(at).getTime() < since) continue;
    const from = replaced ? deviceKind(replaced.user_agent_hint) : null;
    const to = deviceKind(d.user_agent_hint);
    out.push({
      device: d,
      kind,
      at,
      replaced,
      from,
      to,
      typeChanged: from !== null && from !== to,
    });
  }
  return out.sort((a, b) => new Date(b.at).getTime() - new Date(a.at).getTime());
}

/** Počet razení z neschválených zariadení, ktoré sa započítavajú (zneplatnené sa nerátajú). */
export function countUnverified(
  punches: readonly { verification?: string | null; voided?: boolean }[],
): number {
  return punches.filter((p) => !p.voided && p.verification === "unverified").length;
}

/** Veta pre pruh nad tabuľkou mesiaca, so správnym sklonovaním (1 razenie je, 2 až 4 razenia sú, 5 a viac razení je). */
export function unverifiedSummary(n: number): string {
  const base = n === 1 ? "1 razenie je" : n >= 2 && n <= 4 ? `${n} razenia sú` : `${n} razení je`;
  return `${base} z neschváleného zariadenia (označené „neoverené“). Počítajú sa, kým ich vedúci nepotvrdí v Môj tím → Zariadenia.`;
}
