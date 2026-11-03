// Referenčná implementácia exportu razení pre Access (kontrakt v1).
// Čistý modul bez závislostí na Supabase/React – dá sa testovať vo Vitest aj spustiť na serveri.
// Použi ho vo funkcii/route pre export; zdroj dát: punches + profiles.sap_id (SELECT cez RLS správcu organizácie).
export const CONTRACT_VERSION = 1;
export const TIME_ZONE = "Europe/Bratislava";

export interface PunchDbRow {
  id: number; // punches.id (bigserial)
  organization_id: string;
  client_uuid: string; // idempotentný kľúč z offline fronty -> external_id
  sap_id: string; // osobné číslo SAP (7–8 číslic, môže mať vedúce nuly)
  code: string; // WORK | TRIP | DOCTOR | FAMILY | LEAVE | SICK | PRIV
  direction: "IN" | "OUT";
  client_time: string; // ISO UTC
  server_time: string; // ISO UTC
  drift_minutes: number;
  source: "terminal" | "correction";
  device_verification: "verified" | "unverified" | "confirmed";
  device_id: string | null;
  user_id: string;
  prev_hash: string;
  record_hash: string;
}

export const HEADER = [
  "contract_version",
  "organization_id",
  "punch_id",
  "external_id",
  "personnel_number",
  "code",
  "direction",
  "client_time_local",
  "client_time_utc",
  "server_time_utc",
  "drift_minutes",
  "source",
  "device_verification",
  "device_id",
  "user_uuid",
  "prev_hash",
  "record_hash",
] as const;
const NUMERIC = new Set<string>(["contract_version", "punch_id", "drift_minutes"]);

const q = (v: unknown) => `"${String(v ?? "").replace(/"/g, '""')}"`;
const utcSec = (iso: string) => new Date(iso).toISOString().slice(0, 19) + "Z";

export function localTime(iso: string, tz = TIME_ZONE): string {
  // sv-SE dáva tvar "2026-11-02 05:58:12"
  return new Intl.DateTimeFormat("sv-SE", {
    timeZone: tz,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).format(new Date(iso));
}

export async function sha256Hex(text: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Rovnaký vzorec ako trigger punches_chain (drizzle/migrations/0003_device_verification.sql). */
export function chainInput(
  r: Pick<
    PunchDbRow,
    | "prev_hash"
    | "user_id"
    | "code"
    | "direction"
    | "client_time"
    | "server_time"
    | "client_uuid"
    | "device_id"
  >,
): string {
  return (
    [
      r.prev_hash,
      r.user_id,
      r.code,
      r.direction,
      utcSec(r.client_time).slice(0, 19),
      utcSec(r.server_time).slice(0, 19),
      r.client_uuid,
    ].join("|") + (r.device_id ? `|${r.device_id}` : "")
  );
}

export async function buildPunchExportCsv(rows: PunchDbRow[]): Promise<string> {
  const sorted = [...rows].sort((a, b) => a.id - b.id);
  const lines = [HEADER.join(";")];
  for (const r of sorted) {
    const rec: Record<(typeof HEADER)[number], string | number> = {
      contract_version: CONTRACT_VERSION,
      organization_id: r.organization_id,
      punch_id: r.id,
      external_id: r.client_uuid,
      personnel_number: r.sap_id,
      code: r.code,
      direction: r.direction,
      client_time_local: localTime(r.client_time),
      client_time_utc: utcSec(r.client_time),
      server_time_utc: utcSec(r.server_time),
      drift_minutes: r.drift_minutes,
      source: r.source,
      device_verification: r.device_verification,
      device_id: r.device_id ?? "",
      user_uuid: r.user_id,
      prev_hash: r.prev_hash,
      record_hash: r.record_hash,
    };
    lines.push(HEADER.map((h) => (NUMERIC.has(h) ? String(rec[h]) : q(rec[h]))).join(";"));
  }
  const body = lines.join("\r\n") + "\r\n";
  const digest = await sha256Hex(body);
  return "﻿" + body + `#END;rows=${sorted.length};sha256=${digest}\r\n`;
}
