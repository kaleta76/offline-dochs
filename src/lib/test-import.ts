// Testovací import razení z CSV (len pre organizáciu v testovacej prevádzke) a export denných saldách na porovnanie
// s Accessom. Čisté funkcie bez Supabase a Reactu, aby sa dali testovať.
import { chainInput, sha256Hex, TIME_ZONE } from "./punch-export";
import { localToUtc } from "./zone-time";

/** Kľúč v organization_settings: "1" = testovacia prevádzka zapnutá. */
export const TEST_MODE_KEY = "TESTOVACIA_PREVADZKA";
export const MAX_TEST_ROWS = 1500;
export const MAX_TEST_CSV_CHARS = 400_000;
/** Hodnota stĺpca punches.device pre razenia z testovacieho importu. */
export const TEST_DEVICE = "testovací import";

export interface TestPunchRow {
  line: number;
  sap: string;
  code: string;
  direction: "IN" | "OUT";
  /** miestny čas "RRRR-MM-DD HH:MM:SS" (Europe/Bratislava) */
  local: string;
  utc: Date;
}

export interface TestIssue {
  line: number;
  text: string;
}

export interface TestParseResult {
  rows: TestPunchRow[];
  issues: TestIssue[];
  /** riadky, ktoré sa v súbore opakujú (rovnaká osoba, kód, smer a čas) a vynechali sa */
  duplicatesInFile: number;
}

const strip = (s: string) =>
  s
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .trim()
    .toLowerCase()
    .replace(/[\s-]+/g, "_");

const HEADER_ALIASES: Record<string, string> = {
  osobne_cislo: "sap",
  osobnecislo: "sap",
  osobne_cislo_sap: "sap",
  sap: "sap",
  sap_id: "sap",
  cislo: "sap",
  datum: "date",
  date: "date",
  cas: "time",
  time: "time",
  kod: "code",
  code: "code",
  smer: "direction",
  direction: "direction",
};

const pad = (n: number) => String(n).padStart(2, "0");

function unquote(cell: string): string {
  const t = cell.trim();
  return t.length >= 2 && t.startsWith('"') && t.endsWith('"') ? t.slice(1, -1).trim() : t;
}

/**
 * Prečíta testovacie razenia. Očakávané stĺpce (poradie ľubovoľné): osobne_cislo, datum, cas, kod, smer.
 * Dátum RRRR-MM-DD alebo D.M.RRRR, čas HH:MM alebo HH:MM:SS (miestny čas Europe/Bratislava), smer IN / OUT,
 * kód z číselníka organizácie. Oddeľovač `;`, `,` alebo tabulátor. Riadky začínajúce `#` sa preskočia.
 */
export function parseTestCsv(text: string, validCodes: ReadonlySet<string>): TestParseResult {
  const issues: TestIssue[] = [];
  const rows: TestPunchRow[] = [];
  let duplicatesInFile = 0;
  if (text.length > MAX_TEST_CSV_CHARS) {
    return {
      rows,
      issues: [{ line: 0, text: `Súbor je príliš veľký (najviac ${MAX_TEST_CSV_CHARS} znakov).` }],
      duplicatesInFile,
    };
  }
  const lines = text
    .replace(/^﻿/, "")
    .split(/\r\n|\n|\r/)
    .map((raw, i) => ({ raw, line: i + 1 }))
    .filter((l) => l.raw.trim() !== "" && !l.raw.trim().startsWith("#"));
  if (lines.length === 0) {
    return { rows, issues: [{ line: 0, text: "Súbor je prázdny." }], duplicatesInFile };
  }
  const head = lines[0]!;
  const delimiter = head.raw.includes(";") ? ";" : head.raw.includes("\t") ? "\t" : ",";
  const columns = new Map<string, number>();
  head.raw.split(delimiter).forEach((cell, index) => {
    const key = HEADER_ALIASES[strip(unquote(cell))];
    if (key && !columns.has(key)) columns.set(key, index);
  });
  const missing = ["sap", "date", "time", "code", "direction"].filter((k) => !columns.has(k));
  if (missing.length > 0) {
    const names: Record<string, string> = {
      sap: "osobne_cislo",
      date: "datum",
      time: "cas",
      code: "kod",
      direction: "smer",
    };
    return {
      rows,
      issues: [
        {
          line: head.line,
          text: `V hlavičke chýbajú stĺpce: ${missing.map((k) => names[k]).join(", ")}.`,
        },
      ],
      duplicatesInFile,
    };
  }
  const body = lines.slice(1);
  if (body.length === 0) {
    return { rows, issues: [{ line: 0, text: "Súbor neobsahuje žiadne razenia." }], duplicatesInFile };
  }
  if (body.length > MAX_TEST_ROWS) {
    return {
      rows,
      issues: [{ line: 0, text: `Súbor má ${body.length} riadkov, najviac je ${MAX_TEST_ROWS}.` }],
      duplicatesInFile,
    };
  }
  const seen = new Set<string>();
  for (const { raw, line } of body) {
    const cells = raw.split(delimiter).map(unquote);
    const cell = (k: string) => cells[columns.get(k)!] ?? "";
    const problems: string[] = [];

    const sap = cell("sap");
    if (!/^[0-9]{7,8}$/.test(sap)) problems.push("osobné číslo musí mať 7 alebo 8 číslic");

    const dateText = cell("date");
    let y = 0;
    let mo = 0;
    let d = 0;
    const iso = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(dateText);
    const sk = /^(\d{1,2})\.\s*(\d{1,2})\.\s*(\d{4})$/.exec(dateText);
    if (iso) [y, mo, d] = [Number(iso[1]), Number(iso[2]), Number(iso[3])];
    else if (sk) [d, mo, y] = [Number(sk[1]), Number(sk[2]), Number(sk[3])];
    const calendar = new Date(Date.UTC(y, mo - 1, d));
    const dateOk =
      (iso || sk) &&
      y >= 2020 &&
      y <= 2100 &&
      calendar.getUTCFullYear() === y &&
      calendar.getUTCMonth() === mo - 1 &&
      calendar.getUTCDate() === d;
    if (!dateOk) problems.push("dátum má byť RRRR-MM-DD alebo D.M.RRRR");

    const timeMatch = /^(\d{1,2}):(\d{2})(?::(\d{2}))?$/.exec(cell("time"));
    const h = timeMatch ? Number(timeMatch[1]) : -1;
    const mi = timeMatch ? Number(timeMatch[2]) : -1;
    const s = timeMatch?.[3] !== undefined ? Number(timeMatch[3]) : 0;
    const timeOk = timeMatch !== null && h <= 23 && mi <= 59 && s <= 59;
    if (!timeOk) problems.push("čas má byť HH:MM alebo HH:MM:SS");

    const code = cell("code").toUpperCase();
    if (!validCodes.has(code)) problems.push(`kód „${cell("code")}“ nie je v číselníku`);

    const direction = cell("direction").toUpperCase();
    if (direction !== "IN" && direction !== "OUT") problems.push("smer musí byť IN alebo OUT");

    let utc: Date | null = null;
    if (dateOk && timeOk) {
      utc = localToUtc(y, mo, d, h, mi, s, TIME_ZONE);
      if (!utc) problems.push("tento čas v pásme Europe/Bratislava neexistuje (prechod na letný čas)");
    }
    if (problems.length > 0 || !utc) {
      issues.push({ line, text: problems.join("; ") });
      continue;
    }
    const key = `${sap}|${code}|${direction}|${utc.toISOString()}`;
    if (seen.has(key)) {
      duplicatesInFile += 1;
      continue;
    }
    seen.add(key);
    rows.push({
      line,
      sap,
      code,
      direction: direction as "IN" | "OUT",
      local: `${y}-${pad(mo)}-${pad(d)} ${pad(h)}:${pad(mi)}:${pad(s)}`,
      utc,
    });
  }
  return { rows, issues, duplicatesInFile };
}

/**
 * Stály identifikátor razenia z testovacieho importu: ten istý riadok dá vždy to isté UUID, takže opakovaný
 * import rovnakého súboru nevytvorí duplicity (stĺpec punches.client_uuid je jedinečný).
 */
export async function testPunchUuid(r: Pick<TestPunchRow, "sap" | "code" | "direction" | "utc">) {
  const h = await sha256Hex(`testimport|${r.sap}|${r.code}|${r.direction}|${r.utc.toISOString()}`);
  const variant = ((parseInt(h[16]!, 16) & 0x3) | 0x8).toString(16);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-${variant}${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

export interface ChainRow {
  id: number;
  user_id: string;
  code: string;
  direction: string;
  client_time: string;
  server_time: string;
  client_uuid: string;
  device_id: string | null;
  prev_hash: string;
  record_hash: string;
}

/** Overí hash reťaz razení jedného používateľa (zoradených podľa id od prvého). */
export async function verifyChain(
  rows: ChainRow[],
): Promise<{ ok: true } | { ok: false; id: number; reason: string }> {
  let prev = "GENESIS";
  for (const r of rows) {
    if (r.prev_hash !== prev) {
      return { ok: false, id: r.id, reason: "prev_hash nenadväzuje na predchádzajúci záznam" };
    }
    const expected = await sha256Hex(
      chainInput({
        prev_hash: r.prev_hash,
        user_id: r.user_id,
        code: r.code,
        direction: r.direction as "IN" | "OUT",
        client_time: r.client_time,
        server_time: r.server_time,
        client_uuid: r.client_uuid,
        device_id: r.device_id,
      }),
    );
    if (expected !== r.record_hash) {
      return { ok: false, id: r.id, reason: "record_hash nezodpovedá obsahu záznamu" };
    }
    prev = r.record_hash;
  }
  return { ok: true };
}

export interface BalanceDay {
  sap: string;
  key: string; // RRRR-MM-DD
  weekend: boolean;
  holiday: boolean;
  expectedMin: number;
  totalMin: number;
  balanceMin: number;
  workMin: number;
  creditMin: number;
  breakMin: number;
  open: boolean;
  byCode: Record<string, number>;
}

export const BALANCE_HEADER = [
  "osobne_cislo",
  "datum",
  "typ_dna",
  "fond_min",
  "odpracovane_min",
  "saldo_min",
  "praca_min",
  "kredit_min",
  "prestavka_min",
  "otvoreny",
  "rozpis",
] as const;

/**
 * CSV so saldami za deň zo zobrazenia terminálu. Stĺpce fond_min, odpracovane_min a saldo_min majú rovnaké mená
 * ako v súbore terminal_test_access_vysledky.csv z Accessu, takže ich porovná skript testy/terminal/porovnaj.py.
 * odpracovane_min = celkom (práca + kredit doplnenia - prestávka), saldo_min = odpracovane_min - fond_min.
 */
export function buildBalanceCsv(days: BalanceDay[]): string {
  const sorted = [...days].sort((a, b) =>
    a.sap === b.sap ? a.key.localeCompare(b.key) : a.sap.localeCompare(b.sap),
  );
  const lines: string[] = [BALANCE_HEADER.join(";")];
  for (const d of sorted) {
    lines.push(
      [
        d.sap,
        d.key,
        d.weekend || d.holiday ? "VO" : "PP",
        d.expectedMin,
        d.totalMin,
        d.balanceMin,
        d.workMin,
        d.creditMin,
        d.breakMin,
        d.open ? 1 : 0,
        Object.entries(d.byCode)
          .map(([k, v]) => `${k}:${v}`)
          .join(","),
      ].join(";"),
    );
  }
  return "﻿" + lines.join("\r\n") + "\r\n";
}
