// REFERENČNÁ implementácia (zmrazená kópia src/lib/void-export.ts, kontrakt v1.1)
// Zoznam zneplatnených razení pre Access: samostatný súbor voids_RRRRMM.csv vo rovnakom tvare ako
// export razení (BOM, `;`, CRLF, pätička #END;rows=N;sha256=...). Razenia samotné ostávajú v exporte nezmenené (v1),
// zneplatnenie sa nepremieta do record_hash. Dôvod zneplatnenia sa neexportuje (voľný text môže obsahovať osobné údaje).
import { CONTRACT_VERSION, sha256Hex } from "./punch-export";

export const VOID_HEADER = [
  "contract_version",
  "organization_id",
  "punch_id",
  "external_id",
  "personnel_number",
  "user_uuid",
  "voided_at_utc",
  "record_hash",
] as const;

export interface VoidRow {
  id: number; // punches.id
  organization_id: string;
  client_uuid: string; // = external_id v exporte razení
  sap_id: string;
  user_id: string;
  voided_at: string; // ISO
  record_hash: string; // hash zneplatneného razenia (Access ním overí, že ide o to isté razenie)
}

const q = (v: unknown) => `"${String(v ?? "").replace(/"/g, '""')}"`;
const utcSec = (iso: string) => new Date(iso).toISOString().slice(0, 19) + "Z";

export async function buildVoidExportCsv(rows: VoidRow[]): Promise<string> {
  const sorted = [...rows].sort((a, b) => a.id - b.id);
  const lines: string[] = [VOID_HEADER.join(";")];
  for (const r of sorted) {
    lines.push(
      [
        String(CONTRACT_VERSION),
        q(r.organization_id),
        String(r.id),
        q(r.client_uuid),
        q(r.sap_id),
        q(r.user_id),
        q(utcSec(r.voided_at)),
        q(r.record_hash),
      ].join(";"),
    );
  }
  const body = lines.join("\r\n") + "\r\n";
  const digest = await sha256Hex(body);
  return "﻿" + body + `#END;rows=${sorted.length};sha256=${digest}\r\n`;
}

export const voidFileName = (year: number, month: number) =>
  `voids_${year}${String(month).padStart(2, "0")}.csv`;
